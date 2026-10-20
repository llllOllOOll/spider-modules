//! A PDF document drawn page by page: text, wrapped text, tables, lines,
//! rectangles, ellipses, PNG and JPEG images and links, written out as a
//! PDF 1.4 file with compressed page contents.
//!
//! Coordinates are points (1/72 inch) from the TOP-LEFT corner of the
//! page, the way screens and HTML measure: `y` grows downwards. The PDF's
//! own bottom-up coordinates are dealt with when the operators are
//! written.
//!
//! Two ways to place things, freely mixed:
//!
//! - absolute: `text(x, y, ...)`, `rect(...)`, `image(...)` at given points;
//! - flowing: `paragraph(...)` and `table(...)` write at the cursor
//!   (`doc.y`, starting at the top margin), move it down, and start a new
//!   page when the next line or row does not fit above the bottom margin.
//!
//! Everything the document holds lives in its own arena: `deinit` frees it
//! all at once. `toBytes` returns the finished file in memory the caller
//! owns.

const std = @import("std");
const fonts = @import("fonts.zig");
const text_mod = @import("text.zig");
const truetype = @import("truetype.zig");
const codec = @import("image.zig");
const table_mod = @import("table.zig");

/// A font to write with: one of the standard fonts every PDF reader has
/// (`.helvetica`, `.courier_bold`...), or a TrueType font added with
/// `Document.addFont`.
pub const Font = union(enum) {
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,
    /// A font from `Document.addFont` (its index in the document).
    embedded: u16,

    /// The standard font, or null for an embedded one.
    pub fn standard(self: Font) ?fonts.Standard {
        return switch (self) {
            .embedded => null,
            inline else => |_, tag| @field(fonts.Standard, @tagName(tag)),
        };
    }
};
pub const Column = table_mod.Column;
pub const TableOptions = table_mod.TableOptions;

/// A page size in points.
pub const Size = struct {
    width: f32,
    height: f32,

    pub const a4: Size = .{ .width = 595.28, .height = 841.89 };
    pub const a5: Size = .{ .width = 419.53, .height = 595.28 };
    pub const letter: Size = .{ .width = 612, .height = 792 };
    pub const legal: Size = .{ .width = 612, .height = 1008 };

    /// The same size turned sideways.
    pub fn landscape(self: Size) Size {
        return .{ .width = @max(self.width, self.height), .height = @min(self.width, self.height) };
    }
};

/// An RGB color.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    pub const gray: Color = .{ .r = 0x6b, .g = 0x72, .b = 0x80 };
    pub const light_gray: Color = .{ .r = 0xe5, .g = 0xe7, .b = 0xeb };

    /// A color from "#rrggbb" (or "rrggbb"), checked at compile time.
    pub fn hex(comptime s: []const u8) Color {
        return comptime blk: {
            const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
            if (h.len != 6) @compileError("Color.hex wants \"#rrggbb\", got \"" ++ s ++ "\"");
            const v = std.fmt.parseInt(u24, h, 16) catch @compileError("Color.hex: not hex digits: \"" ++ s ++ "\"");
            break :blk .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
        };
    }
};

pub const Align = enum { left, center, right };

/// The document's properties, shown by PDF readers (File > Properties).
pub const Info = struct {
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    keywords: ?[]const u8 = null,
    /// The application that made the document.
    creator: ?[]const u8 = null,
};

pub const Options = struct {
    size: Size = Size.a4,
    /// Space kept free on every side by the flowing calls (`paragraph`,
    /// `table`) and where the cursor starts on each page.
    margin: f32 = 40,
    /// Compress the page contents (FlateDecode). Off only to read the
    /// operators while debugging.
    compress: bool = true,
    info: Info = .{},
};

pub const TextOptions = struct {
    font: Font = .helvetica,
    size: f32 = 11,
    color: Color = Color.black,
    /// For `text`: which side of the text `x` is. For boxes: where each
    /// line sits in the box.
    @"align": Align = .left,
    /// Distance between baselines in wrapped text, as a multiple of `size`.
    line_height: f32 = 1.25,
    /// 1 is opaque, 0 invisible (a watermark is around 0.15).
    opacity: f32 = 1,
    /// Degrees counterclockwise, around the anchor point (`x` and the
    /// baseline): 45 writes a line going up to the right. For `text` only;
    /// boxes and paragraphs ignore it.
    rotate: f32 = 0,
};

pub const LineOptions = struct {
    color: Color = Color.black,
    width: f32 = 1,
    /// Dash and gap lengths, e.g. `.{ 3, 2 }`; null draws a solid line.
    dash: ?[2]f32 = null,
    /// 1 is opaque, 0 invisible.
    opacity: f32 = 1,
};

pub const ShapeOptions = struct {
    fill: ?Color = null,
    /// When neither `fill` nor `stroke` is given, the outline is drawn in
    /// black.
    stroke: ?Color = null,
    line_width: f32 = 1,
    /// Corner radius of a rectangle.
    radius: f32 = 0,
    /// 1 is opaque, 0 invisible; applies to the fill and the outline.
    opacity: f32 = 1,
};

pub const ImageOptions = struct {
    /// Given one of the two, the other follows the image's proportions;
    /// given neither, one pixel is one point.
    width: ?f32 = null,
    height: ?f32 = null,
    /// 1 is opaque, 0 invisible.
    opacity: f32 = 1,
    /// Degrees counterclockwise, around the image's center.
    rotate: f32 = 0,
};

/// An image added to the document, drawn with `Document.image` as many
/// times as needed: its bytes are stored once.
pub const Image = struct {
    index: usize,
    /// Size in pixels.
    width: u32,
    height: u32,
};

pub const Error = error{
    /// `setPage` with an index past the last page.
    NoSuchPage,
    /// A link address with characters outside printable ASCII
    /// (percent-encode them first).
    InvalidUrl,
    /// An image that does not belong to this document.
    UnknownImage,
};

const Link = struct { rect: [4]f32, url: []const u8 };

const Page = struct {
    size: Size,
    content: std.ArrayList(u8) = .empty,
    links: std.ArrayList(Link) = .empty,
};

const EmbeddedFont = struct {
    tt: truetype.TrueType,
    hash: u64,
    /// Glyphs drawn so far (one entry per glyph of the font).
    used: []bool,
    /// The character each drawn glyph stands for, for copy and paste.
    unicode: []u21,

    fn isUsed(self: EmbeddedFont) bool {
        return std.mem.indexOfScalar(bool, self.used, true) != null;
    }
};

const StoredImage = struct {
    encoded: codec.Encoded,
    hash: u64,
    len: usize,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    options: Options,
    pages: std.ArrayList(Page) = .empty,
    current: usize = 0,
    images: std.ArrayList(StoredImage) = .empty,
    fonts_used: std.EnumSet(fonts.Standard) = .empty,
    embedded: std.ArrayList(EmbeddedFont) = .empty,
    /// Opacities in use, in thousandths: ExtGState /GS{index}.
    alphas: std.ArrayList(u16) = .empty,
    /// The flowing cursor: where the next `paragraph` or `table` starts,
    /// in points from the top of the current page.
    y: f32 = 0,

    /// A document with one empty page.
    ///
    /// ```zig
    /// var doc = try pdf.Document.init(allocator, .{ .info = .{ .title = "Invoice 42" } });
    /// defer doc.deinit();
    /// try doc.text(40, 60, "Invoice 42", .{ .font = .helvetica_bold, .size = 18 });
    /// try doc.paragraph("Thank you for your order.", .{});
    /// const bytes = try doc.toBytes(allocator);
    /// defer allocator.free(bytes);
    /// ```
    pub fn init(allocator: std.mem.Allocator, options: Options) !Document {
        var doc: Document = .{ .arena = .init(allocator), .options = options };
        errdefer doc.arena.deinit();
        try doc.addPage();
        return doc;
    }

    /// Frees everything the document holds.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    fn alloc(self: *Document) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn page(self: *Document) *Page {
        return &self.pages.items[self.current];
    }

    // ── Pages and the cursor ────────────────────────────────────────────

    /// Adds a page of the document's size and makes it current; the
    /// cursor goes to its top margin.
    pub fn addPage(self: *Document) !void {
        return self.addPageSized(self.options.size);
    }

    /// Adds a page of another size (a landscape page in a portrait
    /// document, say) and makes it current.
    pub fn addPageSized(self: *Document, size: Size) !void {
        try self.pages.append(self.alloc(), .{ .size = size });
        self.current = self.pages.items.len - 1;
        self.y = self.options.margin;
    }

    pub fn pageCount(self: *const Document) usize {
        return self.pages.items.len;
    }

    /// Makes page `index` (from 0) current, to draw on it again: page
    /// numbers in a footer once the page count is known, for one. The
    /// cursor goes to its top margin.
    pub fn setPage(self: *Document, index: usize) Error!void {
        if (index >= self.pages.items.len) return Error.NoSuchPage;
        self.current = index;
        self.y = self.options.margin;
    }

    /// Width of the current page.
    pub fn width(self: *Document) f32 {
        return self.page().size.width;
    }

    /// Height of the current page.
    pub fn height(self: *Document) f32 {
        return self.page().size.height;
    }

    /// Width between the left and right margins.
    pub fn contentWidth(self: *Document) f32 {
        return self.width() - 2 * self.options.margin;
    }

    /// Where the flowing content of the current page must end.
    pub fn bottom(self: *Document) f32 {
        return self.height() - self.options.margin;
    }

    /// Moves the cursor down by `dy` points.
    pub fn moveDown(self: *Document, dy: f32) void {
        self.y += dy;
    }

    /// Starts a new page unless `h` more points fit above the bottom margin.
    pub fn ensureSpace(self: *Document, h: f32) !void {
        if (self.y + h > self.bottom()) try self.addPage();
    }

    // ── Fonts and text ──────────────────────────────────────────────────

    /// Adds a TrueType font (.ttf) and returns it as a `Font` to write
    /// with: any character the font has, in any script. Only the glyphs the
    /// document uses are embedded. The same bytes added twice give the same
    /// font. `bytes` must outlive the document (an `@embedFile`, or memory
    /// freed after `toBytes`).
    ///
    /// Fails with `error.UnsupportedFont` for OpenType fonts with
    /// PostScript outlines (.otf with CFF) and collections (.ttc),
    /// `error.FontNotEmbeddable` when the font's license forbids embedding,
    /// `error.InvalidFont` for anything else that is not a TrueType font.
    pub fn addFont(self: *Document, bytes: []const u8) !Font {
        const hash = std.hash.Wyhash.hash(0, bytes);
        for (self.embedded.items, 0..) |e, i| {
            if (e.hash == hash and e.tt.data.len == bytes.len) return .{ .embedded = @intCast(i) };
        }
        const tt = try truetype.TrueType.parse(bytes);
        const used = try self.alloc().alloc(bool, tt.num_glyphs);
        @memset(used, false);
        const unicode = try self.alloc().alloc(u21, tt.num_glyphs);
        @memset(unicode, 0);
        try self.embedded.append(self.alloc(), .{ .tt = tt, .hash = hash, .used = used, .unicode = unicode });
        return .{ .embedded = @intCast(self.embedded.items.len - 1) };
    }

    /// The width of `str` (UTF-8) in points.
    pub fn textWidth(self: *Document, str: []const u8, font: Font, size: f32) f32 {
        var units: i32 = 0;
        var i: usize = 0;
        var prev: ?u16 = null;
        const tt: ?*const truetype.TrueType = if (font.standard() == null) &self.embedded.items[font.embedded].tt else null;
        while (i < str.len) {
            const cp = nextCodepoint(str, &i);
            const e = self.encodeChar(font, cp);
            units += e.width;
            if (tt) |f| {
                if (prev) |p| units += self.kern(f, p, e.code, cp);
            }
            prev = e.code;
        }
        return @as(f32, @floatFromInt(units)) / 1000.0 * size;
    }

    /// Writes one line of text with its baseline at `y`. `opts.align`
    /// says where `x` is: the left end, the middle or the right end. Line
    /// breaks in `str` become spaces (see `textBox` for several lines).
    pub fn text(self: *Document, x: f32, y: f32, str: []const u8, opts: TextOptions) !void {
        const run = try self.encodeRun(str, opts.font, true);
        try self.writeLine(x, y, run, .{ .start = 0, .end = run.codes.len }, opts);
    }

    fn writeLine(self: *Document, x: f32, y: f32, run: text_mod.Run, ln: text_mod.Line, opts: TextOptions) !void {
        const w = run.width(ln.start, ln.end, opts.size);
        const left = switch (opts.@"align") {
            .left => x,
            .center => x - w / 2,
            .right => x - w,
        };
        const a = self.alloc();
        const c = &self.page().content;
        const translucent = opts.opacity < 1;
        if (translucent) {
            try c.appendSlice(a, "q ");
            try self.setOpacity(opts.opacity);
        }
        if (opts.font.standard()) |std_font| {
            self.fonts_used.insert(std_font);
            try c.print(a, "BT /F{d} {d:.2} Tf ", .{ @backingInt(std_font), opts.size });
        } else {
            try c.print(a, "BT /E{d} {d:.2} Tf ", .{ opts.font.embedded, opts.size });
        }
        try self.color(opts.color, "rg");
        if (opts.rotate == 0) {
            try c.print(a, "{d:.2} {d:.2} Td ", .{ left, self.height() - y });
        } else {
            // The alignment moves the text along its own, turned, baseline.
            const rad = opts.rotate * std.math.pi / 180;
            const cos = @cos(rad);
            const sin = @sin(rad);
            const dx = left - x;
            try c.print(a, "{d:.4} {d:.4} {d:.4} {d:.4} {d:.2} {d:.2} Tm ", .{ cos, sin, -sin, cos, x + dx * cos, self.height() - y + dx * sin });
        }
        if (opts.font.standard() != null) {
            const bytes = try a.alloc(u8, ln.end - ln.start);
            for (run.codes[ln.start..ln.end], bytes) |code, *b| b.* = @intCast(code);
            try writeLiteral(a, c, bytes);
        } else {
            // Two bytes per glyph number (Identity-H), in hex; with kerning,
            // a TJ array whose numbers move the next glyph (positive: left).
            const e = &self.embedded.items[opts.font.embedded];
            const kerned = run.kerns.len > 0 and ln.end > ln.start and
                std.mem.indexOfNone(i16, run.kerns[ln.start .. ln.end - 1], &.{0}) != null;
            if (kerned) try c.append(a, '[');
            try c.append(a, '<');
            for (ln.start..ln.end) |i| {
                const gid = run.codes[i];
                e.used[gid] = true;
                if (e.unicode[gid] == 0) e.unicode[gid] = run.cps[i];
                try c.print(a, "{X:0>4}", .{gid});
                if (kerned and i + 1 < ln.end and run.kerns[i] != 0) try c.print(a, "> {d} <", .{-@as(i32, run.kerns[i])});
            }
            try c.append(a, '>');
            if (kerned) {
                try c.appendSlice(a, if (translucent) "] TJ ET Q\n" else "] TJ ET\n");
                return;
            }
        }
        try c.appendSlice(a, if (translucent) " Tj ET Q\n" else " Tj ET\n");
    }

    /// Sets the opacity for what follows (inside a q/Q): an ExtGState shared
    /// by every drawing with the same opacity.
    fn setOpacity(self: *Document, opacity: f32) !void {
        const v = std.math.clamp(opacity, 0, 1);
        const key: u16 = @intFromFloat(@round(v * 1000));
        const index = for (self.alphas.items, 0..) |k, i| {
            if (k == key) break i;
        } else blk: {
            try self.alphas.append(self.alloc(), key);
            break :blk self.alphas.items.len - 1;
        };
        try self.page().content.print(self.alloc(), "/GS{d} gs ", .{index});
    }

    fn ascent(self: *Document, font: Font) f32 {
        if (font.standard()) |f| return f.ascent();
        const tt = &self.embedded.items[font.embedded].tt;
        return @as(f32, @floatFromInt(tt.ascent)) / @as(f32, @floatFromInt(tt.units_per_em));
    }

    /// Writes `str` wrapped to `box_width`, its first line's top at `y`
    /// (the box's top, not a baseline). Returns the height the lines take.
    pub fn textBox(self: *Document, x: f32, y: f32, box_width: f32, str: []const u8, opts: TextOptions) !f32 {
        const run = try self.encodeRun(str, opts.font, false);
        const lines = try text_mod.wrap(self.alloc(), run, box_width, opts.size);
        const step = opts.size * opts.line_height;
        const top = opts.size * self.ascent(opts.font);
        for (lines, 0..) |ln, i| {
            const baseline = y + top + @as(f32, @floatFromInt(i)) * step;
            const anchor = switch (opts.@"align") {
                .left => x,
                .center => x + box_width / 2,
                .right => x + box_width,
            };
            try self.writeLine(anchor, baseline, run, ln, opts);
        }
        return @as(f32, @floatFromInt(lines.len)) * step;
    }

    /// The height `textBox` would take for `str` at `box_width`.
    pub fn measureText(self: *Document, str: []const u8, box_width: f32, opts: TextOptions) !f32 {
        const run = try self.encodeRun(str, opts.font, false);
        const lines = try text_mod.wrap(self.alloc(), run, box_width, opts.size);
        return @as(f32, @floatFromInt(lines.len)) * opts.size * opts.line_height;
    }

    /// Writes `str` wrapped between the margins at the cursor, one line at
    /// a time: a line that does not fit above the bottom margin goes to a
    /// new page. Moves the cursor below the text.
    pub fn paragraph(self: *Document, str: []const u8, opts: TextOptions) !void {
        const left = self.options.margin;
        const run = try self.encodeRun(str, opts.font, false);
        const lines = try text_mod.wrap(self.alloc(), run, self.contentWidth(), opts.size);
        const step = opts.size * opts.line_height;
        for (lines) |ln| {
            try self.ensureSpace(step);
            const anchor = switch (opts.@"align") {
                .left => left,
                .center => left + self.contentWidth() / 2,
                .right => left + self.contentWidth(),
            };
            try self.writeLine(anchor, self.y + opts.size * self.ascent(opts.font), run, ln, opts);
            self.y += step;
        }
    }

    const Encoded = struct { code: u16, width: u16 };

    /// One character in `font`: its code and width. A character the font
    /// lacks is written as `?` (or the font's missing glyph when it has no
    /// `?` either). A line break has no width; a tab is a space.
    fn encodeChar(self: *Document, font: Font, cp_in: u21) Encoded {
        const cp: u21 = if (cp_in == '\t') ' ' else cp_in;
        if (font.standard()) |f| {
            if (cp == '\n') return .{ .code = '\n', .width = 0 };
            const b = fonts.winAnsi(cp) orelse '?';
            return .{ .code = b, .width = fonts.charWidth(b, f) };
        }
        const tt = &self.embedded.items[font.embedded].tt;
        if (cp == '\n') return .{ .code = 0, .width = 0 };
        var gid = tt.glyphIndex(cp);
        if (gid == 0) gid = tt.glyphIndex('?');
        return .{ .code = gid, .width = tt.advance1000(gid) };
    }

    /// `str` as a run of codes in `font`; `flat` turns line breaks into
    /// spaces (for a single line).
    fn encodeRun(self: *Document, str: []const u8, font: Font, flat: bool) !text_mod.Run {
        const a = self.alloc();
        var codes: std.ArrayList(u16) = .empty;
        var widths: std.ArrayList(u16) = .empty;
        var cps: std.ArrayList(u21) = .empty;
        var i: usize = 0;
        while (i < str.len) {
            var cp = nextCodepoint(str, &i);
            if (flat and (cp == '\n' or cp == '\r')) cp = ' ';
            if (cp == '\r') continue;
            const e = self.encodeChar(font, cp);
            try codes.append(a, e.code);
            try widths.append(a, e.width);
            try cps.append(a, cp);
        }
        var kerns: []i16 = &.{};
        if (font.standard() == null and codes.items.len > 1) {
            const tt = &self.embedded.items[font.embedded].tt;
            if (tt.kern_lookup_count > 0 or tt.kern != null) {
                kerns = try a.alloc(i16, codes.items.len);
                kerns[kerns.len - 1] = 0;
                for (0..codes.items.len - 1) |k| kerns[k] = self.kern(tt, codes.items[k], codes.items[k + 1], cps.items[k + 1]);
            }
        }
        return .{ .codes = codes.items, .widths = widths.items, .cps = cps.items, .kerns = kerns };
    }

    /// The kerning between two glyphs in thousandths of the size; none
    /// across a line break.
    fn kern(self: *Document, tt: *const truetype.TrueType, left: u16, right: u16, right_cp: u21) i16 {
        _ = self;
        if (right_cp == '\n') return 0;
        return @intCast(std.math.clamp(tt.scale(tt.kerning(left, right)), -1000, 1000));
    }

    // ── Shapes ──────────────────────────────────────────────────────────

    /// A straight line between two points.
    pub fn line(self: *Document, x1: f32, y1: f32, x2: f32, y2: f32, opts: LineOptions) !void {
        const c = &self.page().content;
        try c.print(self.alloc(), "q {d:.2} w ", .{opts.width});
        if (opts.opacity < 1) try self.setOpacity(opts.opacity);
        if (opts.dash) |d| try c.print(self.alloc(), "[{d:.2} {d:.2}] 0 d ", .{ d[0], d[1] });
        try self.color(opts.color, "RG");
        try c.print(self.alloc(), "{d:.2} {d:.2} m {d:.2} {d:.2} l S Q\n", .{ x1, self.height() - y1, x2, self.height() - y2 });
    }

    /// A rectangle with its top-left corner at (x, y), filled, outlined or
    /// both, with rounded corners when `opts.radius` is set.
    pub fn rect(self: *Document, x: f32, y: f32, w: f32, h: f32, opts: ShapeOptions) !void {
        try self.beginShape(opts);
        const c = &self.page().content;
        const bottom_y = self.height() - y - h;
        const r = @min(opts.radius, @min(w, h) / 2);
        if (r <= 0) {
            try c.print(self.alloc(), "{d:.2} {d:.2} {d:.2} {d:.2} re ", .{ x, bottom_y, w, h });
        } else {
            // Four sides joined by quarter circles (Bezier, kappa ≈ 0.5523).
            const k = r * kappa;
            const x2 = x + w;
            const y2 = bottom_y + h;
            const a = self.alloc();
            try c.print(a, "{d:.2} {d:.2} m ", .{ x + r, bottom_y });
            try c.print(a, "{d:.2} {d:.2} l ", .{ x2 - r, bottom_y });
            try c.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ x2 - r + k, bottom_y, x2, bottom_y + r - k, x2, bottom_y + r });
            try c.print(a, "{d:.2} {d:.2} l ", .{ x2, y2 - r });
            try c.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ x2, y2 - r + k, x2 - r + k, y2, x2 - r, y2 });
            try c.print(a, "{d:.2} {d:.2} l ", .{ x + r, y2 });
            try c.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ x + r - k, y2, x, y2 - r + k, x, y2 - r });
            try c.print(a, "{d:.2} {d:.2} l ", .{ x, bottom_y + r });
            try c.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c h ", .{ x, bottom_y + r - k, x + r - k, bottom_y, x + r, bottom_y });
        }
        try self.endShape(opts);
    }

    /// An ellipse centered on (cx, cy).
    pub fn ellipse(self: *Document, cx: f32, cy: f32, rx: f32, ry: f32, opts: ShapeOptions) !void {
        try self.beginShape(opts);
        const c = &self.page().content;
        const a = self.alloc();
        const y = self.height() - cy;
        const kx = rx * kappa;
        const ky = ry * kappa;
        try c.print(a, "{d:.2} {d:.2} m ", .{ cx + rx, y });
        try c.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ cx + rx, y + ky, cx + kx, y + ry, cx, y + ry });
        try c.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ cx - kx, y + ry, cx - rx, y + ky, cx - rx, y });
        try c.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ cx - rx, y - ky, cx - kx, y - ry, cx, y - ry });
        try c.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c h ", .{ cx + kx, y - ry, cx + rx, y - ky, cx + rx, y });
        try self.endShape(opts);
    }

    /// A circle centered on (cx, cy).
    pub fn circle(self: *Document, cx: f32, cy: f32, r: f32, opts: ShapeOptions) !void {
        return self.ellipse(cx, cy, r, r, opts);
    }

    const kappa: f32 = 0.5522848;

    fn beginShape(self: *Document, opts: ShapeOptions) !void {
        const c = &self.page().content;
        try c.print(self.alloc(), "q {d:.2} w ", .{opts.line_width});
        if (opts.opacity < 1) try self.setOpacity(opts.opacity);
        if (opts.fill) |f| try self.color(f, "rg");
        try self.color(opts.stroke orelse Color.black, "RG");
    }

    fn endShape(self: *Document, opts: ShapeOptions) !void {
        const op: []const u8 = if (opts.fill != null and opts.stroke != null) "B" else if (opts.fill != null) "f" else "S";
        try self.page().content.print(self.alloc(), "{s} Q\n", .{op});
    }

    fn color(self: *Document, c: Color, op: []const u8) !void {
        try self.page().content.print(self.alloc(), "{d:.3} {d:.3} {d:.3} {s} ", .{
            @as(f32, @floatFromInt(c.r)) / 255,
            @as(f32, @floatFromInt(c.g)) / 255,
            @as(f32, @floatFromInt(c.b)) / 255,
            op,
        });
    }

    // ── Images and links ────────────────────────────────────────────────

    /// Adds a PNG or JPEG file. The same bytes added twice are stored once.
    /// A JPEG's bytes are kept as they are: they must outlive the document
    /// (an `@embedFile`, or memory freed after `toBytes`).
    pub fn addImage(self: *Document, bytes: []const u8) !Image {
        const hash = std.hash.Wyhash.hash(0, bytes);
        for (self.images.items, 0..) |stored, i| {
            if (stored.hash == hash and stored.len == bytes.len) {
                return .{ .index = i, .width = stored.encoded.width, .height = stored.encoded.height };
            }
        }
        const encoded = try codec.load(self.alloc(), bytes);
        try self.images.append(self.alloc(), .{ .encoded = encoded, .hash = hash, .len = bytes.len });
        return .{ .index = self.images.items.len - 1, .width = encoded.width, .height = encoded.height };
    }

    /// Draws an image with its top-left corner at (x, y).
    pub fn image(self: *Document, img: Image, x: f32, y: f32, opts: ImageOptions) !void {
        if (img.index >= self.images.items.len) return Error.UnknownImage;
        const pw: f32 = @floatFromInt(img.width);
        const ph: f32 = @floatFromInt(img.height);
        const w = opts.width orelse if (opts.height) |h| h * pw / ph else pw;
        const h = opts.height orelse if (opts.width) |ow| ow * ph / pw else ph;
        const c = &self.page().content;
        const a = self.alloc();
        try c.appendSlice(a, "q ");
        if (opts.opacity < 1) try self.setOpacity(opts.opacity);
        if (opts.rotate == 0) {
            try c.print(a, "{d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm /Im{d} Do Q\n", .{ w, h, x, self.height() - y - h, img.index });
        } else {
            // Move to the center, turn, then place the image around it.
            const rad = opts.rotate * std.math.pi / 180;
            const cx = x + w / 2;
            const cy = self.height() - y - h / 2;
            try c.print(a, "1 0 0 1 {d:.2} {d:.2} cm {d:.4} {d:.4} {d:.4} {d:.4} 0 0 cm {d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm /Im{d} Do Q\n", .{ cx, cy, @cos(rad), @sin(rad), -@sin(rad), @cos(rad), w, h, -w / 2, -h / 2, img.index });
        }
    }

    /// Makes the rectangle at (x, y) a link to `url`: a click opens it.
    pub fn link(self: *Document, x: f32, y: f32, w: f32, h: f32, url: []const u8) !void {
        for (url) |b| {
            if (b < 0x21 or b > 0x7E) return Error.InvalidUrl;
        }
        const page_h = self.height();
        try self.page().links.append(self.alloc(), .{
            .rect = .{ x, page_h - y - h, x + w, page_h - y },
            .url = try self.alloc().dupe(u8, url),
        });
    }

    // ── Tables ──────────────────────────────────────────────────────────

    /// A table at the cursor, between the margins (see table.zig).
    pub fn table(self: *Document, columns: []const Column, rows: []const []const []const u8, opts: TableOptions) !void {
        return table_mod.draw(self, columns, rows, opts);
    }

    // ── Output ──────────────────────────────────────────────────────────

    /// The finished PDF file, allocated with `allocator`.
    pub fn toBytes(self: *Document, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try self.write(&out);
        return out.toOwnedSlice();
    }

    fn write(self: *Document, out: *std.Io.Writer.Allocating) !void {
        const a = self.alloc();
        const w = &out.writer;

        // Object numbers, decided before anything is written: the page
        // tree lists its pages, and pages name their fonts and images.
        const catalog_id = 1;
        const pages_id = 2;
        const info_id = 3;
        var next: usize = 4;

        var font_ids: std.EnumArray(fonts.Standard, usize) = .initFill(0);
        var it = self.fonts_used.iterator();
        while (it.next()) |f| {
            font_ids.set(f, next);
            next += 1;
        }
        // An embedded font is five objects (Type0 font, CIDFont, descriptor,
        // font file, ToUnicode map); one never drawn with is left out.
        const embedded_ids = try a.alloc(usize, self.embedded.items.len);
        for (self.embedded.items, 0..) |e, i| {
            embedded_ids[i] = 0;
            if (!e.isUsed()) continue;
            embedded_ids[i] = next;
            next += 5;
        }
        const image_ids = try a.alloc(usize, self.images.items.len);
        const mask_ids = try a.alloc(usize, self.images.items.len);
        for (self.images.items, 0..) |img, i| {
            image_ids[i] = next;
            next += 1;
            mask_ids[i] = 0;
            if (img.encoded.alpha != null) {
                mask_ids[i] = next;
                next += 1;
            }
        }
        const first_gs_id = next;
        next += self.alphas.items.len;
        const content_ids = try a.alloc(usize, self.pages.items.len);
        const page_ids = try a.alloc(usize, self.pages.items.len);
        const first_link_ids = try a.alloc(usize, self.pages.items.len);
        for (self.pages.items, 0..) |p, i| {
            content_ids[i] = next;
            page_ids[i] = next + 1;
            first_link_ids[i] = next + 2;
            next += 2 + p.links.items.len;
        }
        const object_count = next - 1;
        const offsets = try a.alloc(usize, object_count + 1);

        try w.writeAll("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n");

        offsets[catalog_id] = out.written().len;
        try w.print("{d} 0 obj\n<< /Type /Catalog /Pages {d} 0 R >>\nendobj\n", .{ catalog_id, pages_id });

        offsets[pages_id] = out.written().len;
        try w.print("{d} 0 obj\n<< /Type /Pages /Kids [", .{pages_id});
        for (page_ids) |id| try w.print("{d} 0 R ", .{id});
        try w.print("] /Count {d} >>\nendobj\n", .{self.pages.items.len});

        offsets[info_id] = out.written().len;
        try w.print("{d} 0 obj\n<< /Producer (Spider PDF)", .{info_id});
        const info = self.options.info;
        inline for (.{ .{ "Title", info.title }, .{ "Author", info.author }, .{ "Subject", info.subject }, .{ "Keywords", info.keywords }, .{ "Creator", info.creator } }) |entry| {
            if (entry[1]) |value| {
                try w.print(" /{s} ", .{entry[0]});
                try writeTextString(w, value);
            }
        }
        try w.writeAll(" >>\nendobj\n");

        it = self.fonts_used.iterator();
        while (it.next()) |f| {
            offsets[font_ids.get(f)] = out.written().len;
            try w.print("{d} 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /{s} /Encoding /WinAnsiEncoding >>\nendobj\n", .{ font_ids.get(f), f.baseName() });
        }

        for (self.embedded.items, embedded_ids) |e, id| {
            if (id != 0) try writeEmbeddedFont(a, out, offsets, e, id);
        }

        for (self.alphas.items, 0..) |key, i| {
            const v = @as(f32, @floatFromInt(key)) / 1000;
            offsets[first_gs_id + i] = out.written().len;
            try w.print("{d} 0 obj\n<< /Type /ExtGState /ca {d:.3} /CA {d:.3} >>\nendobj\n", .{ first_gs_id + i, v, v });
        }

        for (self.images.items, 0..) |stored, i| {
            const img = stored.encoded;
            offsets[image_ids[i]] = out.written().len;
            try w.print("{d} 0 obj\n<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace {s} /BitsPerComponent 8 /Filter {s}", .{
                image_ids[i],                                             img.width, img.height, img.color_space.pdfName(),
                if (img.filter == .dct) "/DCTDecode" else "/FlateDecode",
            });
            if (img.inverted_cmyk) try w.writeAll(" /Decode [1 0 1 0 1 0 1 0]");
            if (mask_ids[i] != 0) try w.print(" /SMask {d} 0 R", .{mask_ids[i]});
            try w.print(" /Length {d} >>\nstream\n", .{img.data.len});
            try w.writeAll(img.data);
            try w.writeAll("\nendstream\nendobj\n");
            if (img.alpha) |alpha| {
                offsets[mask_ids[i]] = out.written().len;
                try w.print("{d} 0 obj\n<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode /Length {d} >>\nstream\n", .{ mask_ids[i], img.width, img.height, alpha.len });
                try w.writeAll(alpha);
                try w.writeAll("\nendstream\nendobj\n");
            }
        }

        for (self.pages.items, 0..) |p, i| {
            const raw = p.content.items;
            const data = if (self.options.compress) try codec.zlibCompress(a, raw) else raw;
            offsets[content_ids[i]] = out.written().len;
            try w.print("{d} 0 obj\n<< /Length {d}{s} >>\nstream\n", .{ content_ids[i], data.len, if (self.options.compress) " /Filter /FlateDecode" else "" });
            try w.writeAll(data);
            try w.writeAll("\nendstream\nendobj\n");

            offsets[page_ids[i]] = out.written().len;
            try w.print("{d} 0 obj\n<< /Type /Page /Parent {d} 0 R /MediaBox [0 0 {d:.2} {d:.2}] /Contents {d} 0 R /Resources <<", .{ page_ids[i], pages_id, p.size.width, p.size.height, content_ids[i] });
            const any_embedded = for (embedded_ids) |id| {
                if (id != 0) break true;
            } else false;
            if (self.fonts_used.count() > 0 or any_embedded) {
                try w.writeAll(" /Font <<");
                it = self.fonts_used.iterator();
                while (it.next()) |f| try w.print(" /F{d} {d} 0 R", .{ @backingInt(f), font_ids.get(f) });
                for (embedded_ids, 0..) |id, n| {
                    if (id != 0) try w.print(" /E{d} {d} 0 R", .{ n, id });
                }
                try w.writeAll(" >>");
            }
            if (self.alphas.items.len > 0) {
                try w.writeAll(" /ExtGState <<");
                for (0..self.alphas.items.len) |n| try w.print(" /GS{d} {d} 0 R", .{ n, first_gs_id + n });
                try w.writeAll(" >>");
            }
            if (self.images.items.len > 0) {
                try w.writeAll(" /XObject <<");
                for (image_ids, 0..) |id, n| try w.print(" /Im{d} {d} 0 R", .{ n, id });
                try w.writeAll(" >>");
            }
            try w.writeAll(" >>");
            if (p.links.items.len > 0) {
                try w.writeAll(" /Annots [");
                for (0..p.links.items.len) |n| try w.print("{d} 0 R ", .{first_link_ids[i] + n});
                try w.writeAll("]");
            }
            try w.writeAll(" >>\nendobj\n");

            for (p.links.items, 0..) |l, n| {
                offsets[first_link_ids[i] + n] = out.written().len;
                try w.print("{d} 0 obj\n<< /Type /Annot /Subtype /Link /Rect [{d:.2} {d:.2} {d:.2} {d:.2}] /Border [0 0 0] /A << /S /URI /URI ", .{ first_link_ids[i] + n, l.rect[0], l.rect[1], l.rect[2], l.rect[3] });
                try writeLiteralTo(w, l.url);
                try w.writeAll(" >> >>\nendobj\n");
            }
        }

        const xref = out.written().len;
        try w.print("xref\n0 {d}\n0000000000 65535 f \n", .{object_count + 1});
        for (offsets[1..]) |off| try w.print("{d:0>10} 00000 n \n", .{off});
        try w.print("trailer\n<< /Size {d} /Root {d} 0 R /Info {d} 0 R >>\nstartxref\n{d}\n%%EOF\n", .{ object_count + 1, catalog_id, info_id, xref });
    }
};

/// Writes the five objects of an embedded TrueType font, numbered from
/// `id`: a Type0 font (Identity-H: two-byte codes that are glyph numbers),
/// its CIDFont with the widths of the glyphs used, the font descriptor,
/// the subset font file, and a ToUnicode map so that copying the text or
/// extracting it gives the characters back.
fn writeEmbeddedFont(a: std.mem.Allocator, out: *std.Io.Writer.Allocating, offsets: []usize, e: EmbeddedFont, id: usize) !void {
    const w = &out.writer;
    const tt = &e.tt;

    // A subset is named with six capital letters and "+", from the set of
    // glyphs it holds: two subsets of one font never share a name.
    var hasher = std.hash.Wyhash.init(e.hash);
    hasher.update(std.mem.sliceAsBytes(e.used));
    var h = hasher.final();
    var tag: [6]u8 = undefined;
    for (&tag) |*ch| {
        ch.* = 'A' + @as(u8, @intCast(h % 26));
        h /= 26;
    }
    const name = try std.fmt.allocPrint(a, "{s}+{s}", .{ &tag, tt.postScriptName() });

    offsets[id] = out.written().len;
    try w.print("{d} 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /{s} /Encoding /Identity-H /DescendantFonts [{d} 0 R] /ToUnicode {d} 0 R >>\nendobj\n", .{ id, name, id + 1, id + 4 });

    offsets[id + 1] = out.written().len;
    try w.print("{d} 0 obj\n<< /Type /Font /Subtype /CIDFontType2 /BaseFont /{s} /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /FontDescriptor {d} 0 R /CIDToGIDMap /Identity /DW 1000 /W [", .{ id + 1, name, id + 2 });
    // Runs of consecutive glyphs: `first [w1 w2 ...]`.
    var gid: usize = 0;
    while (gid < e.used.len) {
        if (!e.used[gid]) {
            gid += 1;
            continue;
        }
        try w.print(" {d} [", .{gid});
        while (gid < e.used.len and e.used[gid]) : (gid += 1) try w.print(" {d}", .{tt.advance1000(@intCast(gid))});
        try w.writeAll(" ]");
    }
    try w.writeAll(" ] >>\nendobj\n");

    var flags: u32 = 4; // symbolic: the codes are glyph numbers, not a standard encoding
    if (tt.fixed_pitch) flags |= 1;
    if (tt.italic_angle != 0) flags |= 64;
    offsets[id + 2] = out.written().len;
    try w.print("{d} 0 obj\n<< /Type /FontDescriptor /FontName /{s} /Flags {d} /FontBBox [{d} {d} {d} {d}] /ItalicAngle {d:.2} /Ascent {d} /Descent {d} /CapHeight {d} /StemV 80 /FontFile2 {d} 0 R >>\nendobj\n", .{
        id + 2,                  name,
        flags,                   tt.scale(tt.bbox[0]),
        tt.scale(tt.bbox[1]),    tt.scale(tt.bbox[2]),
        tt.scale(tt.bbox[3]),    tt.italic_angle,
        tt.scale(tt.ascent),     tt.scale(tt.descent),
        tt.scale(tt.cap_height), id + 3,
    });

    const font_file = try tt.subset(a, e.used);
    const compressed = try codec.zlibCompress(a, font_file);
    offsets[id + 3] = out.written().len;
    try w.print("{d} 0 obj\n<< /Length {d} /Length1 {d} /Filter /FlateDecode >>\nstream\n", .{ id + 3, compressed.len, font_file.len });
    try w.writeAll(compressed);
    try w.writeAll("\nendstream\nendobj\n");

    var cmap: std.ArrayList(u8) = .empty;
    try cmap.appendSlice(a,
        \\/CIDInit /ProcSet findresource begin
        \\12 dict begin
        \\begincmap
        \\/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        \\/CMapName /Adobe-Identity-UCS def
        \\/CMapType 2 def
        \\1 begincodespacerange
        \\<0000> <FFFF>
        \\endcodespacerange
        \\
    );
    // At most 100 entries per bfchar block.
    var pending: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    for (e.unicode, 0..) |cp, g| {
        if (cp == 0) continue;
        try pending.print(a, "<{X:0>4}> <", .{g});
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try pending.print(a, "{X:0>4}{X:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
        } else {
            try pending.print(a, "{X:0>4}", .{cp});
        }
        try pending.appendSlice(a, ">\n");
        count += 1;
        if (count == 100) {
            try cmap.print(a, "100 beginbfchar\n{s}endbfchar\n", .{pending.items});
            pending.clearRetainingCapacity();
            count = 0;
        }
    }
    if (count > 0) try cmap.print(a, "{d} beginbfchar\n{s}endbfchar\n", .{ count, pending.items });
    try cmap.appendSlice(a,
        \\endcmap
        \\CMapName currentdict /CMapResource defineresource pop
        \\end
        \\end
        \\
    );
    const cmap_z = try codec.zlibCompress(a, cmap.items);
    offsets[id + 4] = out.written().len;
    try w.print("{d} 0 obj\n<< /Length {d} /Filter /FlateDecode >>\nstream\n", .{ id + 4, cmap_z.len });
    try w.writeAll(cmap_z);
    try w.writeAll("\nendstream\nendobj\n");
}

/// Decodes the UTF-8 character at `i.*` and moves past it; invalid bytes
/// give U+FFFD, one byte at a time.
fn nextCodepoint(str: []const u8, i: *usize) u21 {
    const len = std.unicode.utf8ByteSequenceLength(str[i.*]) catch {
        i.* += 1;
        return 0xFFFD;
    };
    if (i.* + len > str.len) {
        i.* = str.len;
        return 0xFFFD;
    }
    const cp = std.unicode.utf8Decode(str[i.* .. i.* + len]) catch 0xFFFD;
    i.* += len;
    return cp;
}

/// A PDF literal string: `(...)` with `(`, `)` and `\` escaped and the
/// line-break bytes written as escapes, so the string stays on one line.
fn writeLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bytes: []const u8) !void {
    try out.append(allocator, '(');
    for (bytes) |b| switch (b) {
        '(', ')', '\\' => {
            try out.append(allocator, '\\');
            try out.append(allocator, b);
        },
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        else => try out.append(allocator, b),
    };
    try out.append(allocator, ')');
}

fn writeLiteralTo(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('(');
    for (bytes) |b| switch (b) {
        '(', ')', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(b);
        },
        '\r' => try w.writeAll("\\r"),
        '\n' => try w.writeAll("\\n"),
        else => try w.writeByte(b),
    };
    try w.writeByte(')');
}

/// A PDF text string for the document properties: plain ASCII as a
/// literal; anything else as UTF-16BE with a byte order mark, in hex, which
/// every reader shows with its accents.
fn writeTextString(w: *std.Io.Writer, utf8: []const u8) !void {
    for (utf8) |b| {
        if (b < 0x20 or b > 0x7E) break;
    } else return writeLiteralTo(w, utf8);

    try w.writeAll("<FEFF");
    var i: usize = 0;
    while (i < utf8.len) {
        const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch 1;
        const cp: u21 = if (i + len <= utf8.len) std.unicode.utf8Decode(utf8[i .. i + len]) catch 0xFFFD else 0xFFFD;
        i += len;
        if (cp >= 0x10000) {
            const v = cp - 0x10000;
            try w.print("{X:0>4}{X:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) });
        } else {
            try w.print("{X:0>4}", .{cp});
        }
    }
    try w.writeByte('>');
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn render(doc: *Document) ![]u8 {
    return doc.toBytes(t.allocator);
}

/// Every xref entry must point at the start of its "N 0 obj": the check a
/// reader does first, and the one a hand-built PDF gets wrong most.
fn expectValidXref(pdf: []const u8) !void {
    try t.expect(std.mem.startsWith(u8, pdf, "%PDF-1.4\n"));
    try t.expect(std.mem.endsWith(u8, pdf, "%%EOF\n"));
    const sx = std.mem.lastIndexOf(u8, pdf, "startxref\n").?;
    const xref_at = try std.fmt.parseInt(usize, std.mem.trim(u8, pdf[sx + 10 .. pdf.len - 6], "\n"), 10);
    try t.expect(std.mem.startsWith(u8, pdf[xref_at..], "xref\n0 "));
    var lines = std.mem.splitScalar(u8, pdf[xref_at..], '\n');
    _ = lines.next();
    const header = lines.next().?;
    const count = try std.fmt.parseInt(usize, header[2..], 10);
    _ = lines.next(); // the free entry
    for (1..count) |id| {
        const entry = lines.next().?;
        try t.expectEqual(@as(usize, 19), entry.len); // 20 bytes with the \n
        const off = try std.fmt.parseInt(usize, entry[0..10], 10);
        var buf: [32]u8 = undefined;
        const want = try std.fmt.bufPrint(&buf, "{d} 0 obj\n", .{id});
        try t.expect(std.mem.startsWith(u8, pdf[off..], want));
    }
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "an empty document is a valid one-page PDF" {
    var doc = try Document.init(t.allocator, .{});
    defer doc.deinit();
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(contains(pdf, "/Count 1"));
    try t.expect(contains(pdf, "/MediaBox [0 0 595.28 841.89]"));
    try t.expect(!contains(pdf, "/Font"));
}

test "text is written in WinAnsi at PDF coordinates, with its font declared" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    try doc.text(50, 100, "Olá (1)", .{ .font = .helvetica_bold, .size = 12 });
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    // y 100 from the top of an 841.89-point page is 741.89 from the bottom.
    try t.expect(contains(pdf, "BT /F1 12.00 Tf 0.000 0.000 0.000 rg 50.00 741.89 Td (Ol\xe1 \\(1\\)) Tj ET"));
    try t.expect(contains(pdf, "/BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding"));
    try t.expect(contains(pdf, "/Font << /F1 "));
    try t.expect(!contains(pdf, "/BaseFont /Helvetica "));
}

test "aligned text is placed by its measured width" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    // "Hi" in Helvetica 10 is 9.44 points wide.
    try doc.text(100, 10, "Hi", .{ .size = 10, .@"align" = .right });
    try doc.text(100, 10, "Hi", .{ .size = 10, .@"align" = .center });
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try t.expect(contains(pdf, "90.56 831.89 Td"));
    try t.expect(contains(pdf, "95.28 831.89 Td"));
}

test "page contents are compressed by default" {
    var doc = try Document.init(t.allocator, .{});
    defer doc.deinit();
    try doc.text(10, 10, "compressed", .{});
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(contains(pdf, "/Filter /FlateDecode"));
    try t.expect(!contains(pdf, "(compressed)"));
    // The stream inflates back to the operators.
    const start = std.mem.indexOf(u8, pdf, "/Filter /FlateDecode >>\nstream\n").? + "/Filter /FlateDecode >>\nstream\n".len;
    const end = std.mem.indexOfPos(u8, pdf, start, "\nendstream").?;
    const raw = try codec.zlibDecompress(t.allocator, pdf[start..end], 10_000);
    defer t.allocator.free(raw);
    try t.expect(contains(raw, "(compressed) Tj"));
}

test "textBox wraps, and returns the height of its lines" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    const h = try doc.textBox(40, 40, 60, "hello world again", .{ .font = .courier, .size = 10 });
    // Courier 10: 6 points a character; 60 points hold "hello" and "world".
    try t.expectApproxEqAbs(@as(f32, 3 * 12.5), h, 0.001);
    try t.expectEqual(h, try doc.measureText("hello world again", 60, .{ .font = .courier, .size = 10 }));
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try t.expect(contains(pdf, "(hello) Tj"));
    try t.expect(contains(pdf, "(world) Tj"));
    try t.expect(contains(pdf, "(again) Tj"));
}

test "paragraph flows to new pages and moves the cursor" {
    var doc = try Document.init(t.allocator, .{ .size = .{ .width = 200, .height = 200 }, .margin = 20 });
    defer doc.deinit();
    const start = doc.y;
    try doc.paragraph("one line", .{ .size = 10 });
    try t.expectApproxEqAbs(start + 12.5, doc.y, 0.001);
    // 160 points of room at 12.5 a line: 12 lines a page.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(t.allocator);
    for (0..30) |_| try many.appendSlice(t.allocator, "line\n");
    try doc.paragraph(many.items, .{ .size = 10 });
    try t.expectEqual(@as(usize, 3), doc.pageCount());
    try t.expect(doc.y <= doc.bottom());
}

test "setPage draws on an earlier page and refuses one that does not exist" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    try doc.addPage();
    try doc.setPage(0);
    try doc.text(10, 10, "back on page one", .{});
    try t.expectError(Error.NoSuchPage, doc.setPage(2));
    try t.expectEqual(@as(usize, 2), doc.pageCount());
    try t.expect(contains(doc.pages.items[0].content.items, "back on page one"));
    try t.expectEqual(@as(usize, 0), doc.pages.items[1].content.items.len);
}

test "shapes: fill, stroke, both, dashes and curves" {
    var doc = try Document.init(t.allocator, .{ .compress = false, .size = .{ .width = 100, .height = 100 } });
    defer doc.deinit();
    try doc.rect(10, 10, 20, 30, .{});
    try doc.rect(10, 10, 20, 30, .{ .fill = Color.hex("#ff0000") });
    try doc.rect(10, 10, 20, 30, .{ .fill = Color.white, .stroke = Color.black, .radius = 4 });
    try doc.line(0, 0, 100, 100, .{ .width = 0.5, .dash = .{ 3, 2 } });
    try doc.circle(50, 50, 10, .{ .fill = Color.black });
    const c = doc.pages.items[0].content.items;
    try t.expect(contains(c, "10.00 60.00 20.00 30.00 re S Q")); // outline by default
    try t.expect(contains(c, "1.000 0.000 0.000 rg 0.000 0.000 0.000 RG 10.00 60.00 20.00 30.00 re f Q"));
    try t.expect(contains(c, " c h B Q")); // rounded and filled+stroked
    try t.expect(contains(c, "q 0.50 w [3.00 2.00] 0 d"));
    try t.expect(contains(c, "0.00 100.00 m 100.00 0.00 l S Q"));
    try t.expect(contains(c, "60.00 50.00 m ")); // circle starts at its right end
}

test "images: stored once, drawn with their proportions, with a soft mask for alpha" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    // A 2x1 RGBA PNG with a transparent pixel.
    const rows = [_]u8{ 0, 255, 0, 0, 255, 0, 0, 255, 0 };
    const png = try testPng(t.allocator, 2, 1, &rows);
    defer t.allocator.free(png);
    const a = try doc.addImage(png);
    const b = try doc.addImage(png);
    try t.expectEqual(a.index, b.index);
    try doc.image(a, 10, 10, .{ .width = 100 });
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(contains(pdf, "q 100.00 0 0 50.00 10.00 781.89 cm /Im0 Do Q"));
    try t.expect(contains(pdf, "/Width 2 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /SMask "));
    try t.expect(contains(pdf, "/ColorSpace /DeviceGray"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, pdf, "/ColorSpace /DeviceRGB"));
    try t.expectError(Error.UnknownImage, doc.image(.{ .index = 9, .width = 1, .height = 1 }, 0, 0, .{}));
}

fn testPng(allocator: std.mem.Allocator, width_px: u32, height_px: u32, rows: []const u8) ![]u8 {
    const comp = try codec.zlibCompress(allocator, rows);
    defer allocator.free(comp);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, &.{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A });
    var ihdr: [13]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 8, 6, 0, 0, 0 };
    std.mem.writeInt(u32, ihdr[0..4], width_px, .big);
    std.mem.writeInt(u32, ihdr[4..8], height_px, .big);
    inline for (.{ .{ "IHDR", @as([]const u8, &ihdr) }, .{ "IDAT", @as([]const u8, comp) }, .{ "IEND", @as([]const u8, "") } }) |ch| {
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(ch[1].len), .big);
        try out.appendSlice(allocator, &len);
        try out.appendSlice(allocator, ch[0]);
        try out.appendSlice(allocator, ch[1]);
        try out.appendSlice(allocator, &.{ 0, 0, 0, 0 });
    }
    return out.toOwnedSlice(allocator);
}

test "links become URI annotations on their page" {
    var doc = try Document.init(t.allocator, .{ .size = .{ .width = 100, .height = 100 } });
    defer doc.deinit();
    try doc.link(10, 20, 30, 10, "https://spiderme.org/docs?a=(1)");
    try t.expectError(Error.InvalidUrl, doc.link(0, 0, 1, 1, "https://exemplo.com/ação"));
    try t.expectError(Error.InvalidUrl, doc.link(0, 0, 1, 1, "https://a b"));
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(contains(pdf, "/Annots ["));
    try t.expect(contains(pdf, "/Rect [10.00 70.00 40.00 80.00]"));
    try t.expect(contains(pdf, "/URI (https://spiderme.org/docs?a=\\(1\\))"));
}

test "document properties: ASCII as literals, accents as UTF-16" {
    var doc = try Document.init(t.allocator, .{ .info = .{ .title = "Invoice", .author = "José" } });
    defer doc.deinit();
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(contains(pdf, "/Producer (Spider PDF)"));
    try t.expect(contains(pdf, "/Title (Invoice)"));
    try t.expect(contains(pdf, "/Author <FEFF004A006F007300E9>"));
    try t.expect(contains(pdf, "/Info 3 0 R"));
}

test "pages of different sizes keep their own MediaBox" {
    var doc = try Document.init(t.allocator, .{});
    defer doc.deinit();
    try doc.addPageSized(Size.a4.landscape());
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(contains(pdf, "/MediaBox [0 0 595.28 841.89]"));
    try t.expect(contains(pdf, "/MediaBox [0 0 841.89 595.28]"));
    try t.expect(contains(pdf, "/Count 2"));
}

test "opacity: one ExtGState per value, shared, and applied inside q/Q" {
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    try doc.text(10, 10, "faint", .{ .opacity = 0.2 });
    try doc.rect(0, 0, 10, 10, .{ .fill = Color.black, .opacity = 0.2 });
    try doc.line(0, 0, 5, 5, .{ .opacity = 0.5 });
    try doc.text(10, 30, "solid", .{});
    const c = doc.pages.items[0].content.items;
    try t.expect(contains(c, "q /GS0 gs BT /F0"));
    try t.expect(contains(c, "(faint) Tj ET Q"));
    try t.expect(contains(c, "q 1.00 w /GS0 gs"));
    try t.expect(contains(c, "/GS1 gs"));
    try t.expect(contains(c, "BT /F0 11.00 Tf 0.000 0.000 0.000 rg 10.00 811.89 Td (solid) Tj ET\n"));
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, pdf, "/Type /ExtGState"));
    try t.expect(contains(pdf, "/ca 0.200 /CA 0.200"));
    try t.expect(contains(pdf, "/ExtGState << /GS0 "));
}

test "rotated text uses a text matrix, aligned along its baseline" {
    var doc = try Document.init(t.allocator, .{ .compress = false, .size = .{ .width = 100, .height = 100 } });
    defer doc.deinit();
    try doc.text(50, 50, "Hi", .{ .size = 10, .rotate = 90 });
    // Centered at 90°: the 9.44-point line runs upwards, half below (50, 50).
    try doc.text(50, 50, "Hi", .{ .size = 10, .rotate = 90, .@"align" = .center });
    const c = doc.pages.items[0].content.items;
    try t.expect(contains(c, "-0.0000 1.0000 -1.0000 -0.0000 50.00 50.00 Tm (Hi) Tj") or contains(c, "0.0000 1.0000 -1.0000 0.0000 50.00 50.00 Tm (Hi) Tj"));
    try t.expect(contains(c, "50.00 45.28 Tm (Hi) Tj"));
}

test "a rotated, translucent image turns around its center" {
    var doc = try Document.init(t.allocator, .{ .compress = false, .size = .{ .width = 100, .height = 100 } });
    defer doc.deinit();
    const rows = [_]u8{ 0, 255, 0, 0, 255 };
    const png = try testPng(t.allocator, 1, 1, &rows);
    defer t.allocator.free(png);
    const img = try doc.addImage(png);
    try doc.image(img, 10, 10, .{ .width = 20, .height = 10, .rotate = 180, .opacity = 0.5 });
    const c = doc.pages.items[0].content.items;
    try t.expect(contains(c, "q /GS0 gs 1 0 0 1 20.00 85.00 cm -1.0000"));
    try t.expect(contains(c, "20.00 0 0 10.00 -10.00 -5.00 cm /Im0 Do Q"));
}

test "Color.hex reads #rrggbb" {
    try t.expectEqual(Color{ .r = 0x12, .g = 0xab, .b = 0xff }, Color.hex("#12abff"));
    try t.expectEqual(Color.hex("#000000"), Color.hex("000000"));
}

test "line breaks in a literal string are escaped" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(t.allocator);
    try writeLiteral(t.allocator, &list, "a\\b\r\n(c)");
    try t.expectEqualStrings("(a\\\\b\\r\\n\\(c\\))", list.items);
}

// ── Embedded fonts ──────────────────────────────────────────────────────

/// The decompressed data of the first stream whose dictionary contains
/// `marker`.
fn streamAfter(pdf: []const u8, marker: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, pdf, marker) orelse return error.TestUnexpectedResult;
    const start = std.mem.indexOfPos(u8, pdf, at, ">>\nstream\n").? + ">>\nstream\n".len;
    const end = std.mem.indexOfPos(u8, pdf, start, "\nendstream").?;
    return codec.zlibDecompress(t.allocator, pdf[start..end], 1 << 20);
}

test "text in an embedded font is written as glyph numbers, with the font embedded" {
    const font_bytes = try truetype.testing.font(t.allocator, .{});
    defer t.allocator.free(font_bytes);
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    const f = try doc.addFont(font_bytes);
    try doc.text(10, 20, "AB", .{ .font = f, .size = 10 });
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(contains(pdf, "BT /E0 10.00 Tf"));
    try t.expect(contains(pdf, "<00010002> Tj"));
    try t.expect(contains(pdf, "/Subtype /Type0"));
    try t.expect(contains(pdf, "/Encoding /Identity-H"));
    try t.expect(contains(pdf, "/Subtype /CIDFontType2"));
    try t.expect(contains(pdf, "/CIDToGIDMap /Identity"));
    try t.expect(contains(pdf, "/W [ 1 [ 550 600 ] ]"));
    try t.expect(contains(pdf, "/Font << /E0 "));
    // Capital letters, a plus and the PostScript name.
    const at = std.mem.indexOf(u8, pdf, "/BaseFont /").? + "/BaseFont /".len;
    for (pdf[at .. at + 6]) |ch| try t.expect(std.ascii.isUpper(ch));
    try t.expect(std.mem.startsWith(u8, pdf[at + 6 ..], "+Test-Sans "));
    // The descriptor in thousandths of the size.
    try t.expect(contains(pdf, "/FontBBox [-50 -200 950 900] /ItalicAngle -12.00 /Ascent 800 /Descent -200 /CapHeight 700"));
    try t.expect(contains(pdf, "/Flags 68"));
}

test "the embedded font file is a valid subset holding only the glyphs drawn" {
    const font_bytes = try truetype.testing.font(t.allocator, .{});
    defer t.allocator.free(font_bytes);
    var doc = try Document.init(t.allocator, .{});
    defer doc.deinit();
    try doc.text(10, 20, "A", .{ .font = try doc.addFont(font_bytes) });
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    const file = try streamAfter(pdf, "/Length1 ");
    defer t.allocator.free(file);
    const len1_at = std.mem.indexOf(u8, pdf, "/Length1 ").? + "/Length1 ".len;
    const len1 = try std.fmt.parseInt(usize, pdf[len1_at..std.mem.indexOfScalarPos(u8, pdf, len1_at, ' ').?], 10);
    try t.expectEqual(len1, file.len);
    try t.expectEqual(@as(u32, 0xB1B0AFBA), truetype.checksum(file));
    try t.expect(file.len < font_bytes.len + 64);
    // Glyph B (2) had its outline dropped: its filler bytes are gone, A's stay.
    const a_filler: [6]u8 = @splat(0xA1);
    const b_filler: [6]u8 = @splat(0xA2);
    try t.expect(std.mem.indexOf(u8, file, &a_filler) != null);
    try t.expect(std.mem.indexOf(u8, file, &b_filler) == null);
}

test "ToUnicode maps the glyphs back to their characters, beyond the BMP too" {
    const font_bytes = try truetype.testing.font(t.allocator, .{});
    defer t.allocator.free(font_bytes);
    var doc = try Document.init(t.allocator, .{});
    defer doc.deinit();
    try doc.text(10, 20, "AÁЖ😀", .{ .font = try doc.addFont(font_bytes) });
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    // The object /ToUnicode names.
    const ref_at = std.mem.indexOf(u8, pdf, "/ToUnicode ").? + "/ToUnicode ".len;
    const id = pdf[ref_at..std.mem.indexOfScalarPos(u8, pdf, ref_at, ' ').?];
    var buf: [32]u8 = undefined;
    const cmap = try streamAfter(pdf, try std.fmt.bufPrint(&buf, "\n{s} 0 obj\n", .{id}));
    defer t.allocator.free(cmap);
    try t.expect(contains(cmap, "4 beginbfchar"));
    try t.expect(contains(cmap, "<0001> <0041>"));
    try t.expect(contains(cmap, "<0003> <00C1>"));
    try t.expect(contains(cmap, "<0007> <0416>"));
    try t.expect(contains(cmap, "<0008> <D83DDE00>"));
}

test "a character the embedded font lacks is written as its question mark" {
    const font_bytes = try truetype.testing.font(t.allocator, .{});
    defer t.allocator.free(font_bytes);
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    const f = try doc.addFont(font_bytes);
    try doc.text(10, 20, "AZ", .{ .font = f });
    try t.expect(contains(doc.pages.items[0].content.items, "<00010005> Tj"));
}

test "embedded fonts: measured, wrapped, added once, and left out when unused" {
    const font_bytes = try truetype.testing.font(t.allocator, .{});
    defer t.allocator.free(font_bytes);
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    const f = try doc.addFont(font_bytes);
    try t.expectEqual(f, try doc.addFont(font_bytes));
    try t.expectApproxEqAbs(@as(f32, 11.5), doc.textWidth("AB", f, 10), 0.001);
    // "AB AB" at 10 points: each "AB" is 11.5 wide, the space 8.
    const h = try doc.textBox(0, 0, 20, "AB AB", .{ .font = f, .size = 10 });
    try t.expectApproxEqAbs(@as(f32, 2 * 12.5), h, 0.001);

    var unused = try Document.init(t.allocator, .{});
    defer unused.deinit();
    _ = try unused.addFont(font_bytes);
    const pdf = try render(&unused);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(!contains(pdf, "/Type0"));
}

test "standard and embedded fonts in one document, and in a table" {
    const font_bytes = try truetype.testing.font(t.allocator, .{});
    defer t.allocator.free(font_bytes);
    var doc = try Document.init(t.allocator, .{});
    defer doc.deinit();
    const f = try doc.addFont(font_bytes);
    try doc.text(10, 20, "Helvetica", .{});
    try doc.table(&.{.{ .header = "AB", .width = 100 }}, &.{&.{"BA"}}, .{ .font = f, .header_font = f });
    const pdf = try render(&doc);
    defer t.allocator.free(pdf);
    try expectValidXref(pdf);
    try t.expect(contains(pdf, "/Font << /F0 "));
    try t.expect(contains(pdf, " /E0 "));
}

test "kerning from an embedded font: TJ adjustments, in widths and wrapping" {
    const font_bytes = try truetype.testing.font(t.allocator, .{ .kerning = .gpos_pairs });
    defer t.allocator.free(font_bytes);
    var doc = try Document.init(t.allocator, .{ .compress = false });
    defer doc.deinit();
    const f = try doc.addFont(font_bytes);
    try doc.text(10, 20, "ABBA", .{ .font = f, .size = 10 });
    try doc.text(10, 40, "BB", .{ .font = f, .size = 10 });
    const c = doc.pages.items[0].content.items;
    // A then B is -80: the B moves 80 thousandths left.
    try t.expect(contains(c, "[<0001> 80 <000200020001>] TJ"));
    try t.expect(contains(c, "<00020002> Tj")); // nothing to kern: a plain Tj
    // "AB": 550 + 600 - 80 thousandths at 10 points.
    try t.expectApproxEqAbs(@as(f32, 10.7), doc.textWidth("AB", f, 10), 0.001);
    try t.expectApproxEqAbs(@as(f32, 11.5), doc.textWidth("BA", f, 10), 0.001);
    // Right alignment uses the kerned width.
    try doc.text(100, 60, "AB", .{ .font = f, .size = 10, .@"align" = .right });
    try t.expect(contains(doc.pages.items[0].content.items, "89.30 "));
}

test "addFont refuses what it cannot embed" {
    var doc = try Document.init(t.allocator, .{});
    defer doc.deinit();
    try t.expectError(error.InvalidFont, doc.addFont("not a font"));
    const restricted = try truetype.testing.font(t.allocator, .{ .fs_type = 2 });
    defer t.allocator.free(restricted);
    try t.expectError(error.FontNotEmbeddable, doc.addFont(restricted));
}
