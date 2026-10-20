//! TrueType fonts: what a PDF needs to draw with one and embed it.
//!
//! Reads the metrics (units per em, ascent, descent, bounding box, the
//! advance width of each glyph), maps Unicode characters to glyphs (cmap
//! formats 4 and 12) and writes a subset: a font with the same glyph
//! numbers where every glyph the document does not use is empty, so the
//! embedded file carries only the outlines that are drawn. Keeping the
//! numbers lets the PDF use glyph numbers as character codes
//! (`/CIDToGIDMap /Identity`) with no renumbering.
//!
//! Composite glyphs (an accented letter built from a letter and an accent)
//! pull their components into the subset.
//!
//! Refused with a named error: OpenType fonts with PostScript outlines
//! (CFF, "OTTO"), font collections (.ttc), and fonts whose license forbids
//! embedding (`fsType` restricted, or bitmap-only embedding). Every offset
//! read from the file is checked against its length: a font may be an
//! upload.

const std = @import("std");

pub const Error = error{
    /// Not a TrueType file, or a table points outside the file.
    InvalidFont,
    /// An OpenType font with PostScript (CFF) outlines, or a collection.
    UnsupportedFont,
    /// The font's license (OS/2 fsType) does not allow embedding it.
    FontNotEmbeddable,
};

const Table = struct { offset: u32, len: u32 };

pub const TrueType = struct {
    data: []const u8,
    units_per_em: u16,
    num_glyphs: u16,
    num_hmetrics: u16,
    loca_long: bool,
    /// xMin, yMin, xMax, yMax in font units.
    bbox: [4]i16,
    ascent: i16,
    descent: i16,
    cap_height: i16,
    italic_angle: f32,
    fixed_pitch: bool,
    /// The PostScript name, ASCII only (letters, digits, `-`, `_`).
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,

    head: Table,
    hhea: Table,
    maxp: Table,
    hmtx: Table,
    loca: Table,
    glyf: Table,
    cvt: ?Table,
    fpgm: ?Table,
    prep: ?Table,
    cmap_format: u16,
    cmap_offset: u32,

    /// Reads the font. `data` is borrowed: it must outlive the result.
    pub fn parse(data: []const u8) Error!TrueType {
        if (data.len < 12) return Error.InvalidFont;
        const version = try u32At(data, 0);
        if (version == 0x4F54544F) return Error.UnsupportedFont; // "OTTO": CFF outlines
        if (version == 0x74746366) return Error.UnsupportedFont; // "ttcf": a collection
        if (version != 0x00010000 and version != 0x74727565) return Error.InvalidFont; // 1.0 or "true"

        const num_tables = try u16At(data, 4);
        var head: ?Table = null;
        var hhea: ?Table = null;
        var maxp: ?Table = null;
        var hmtx: ?Table = null;
        var loca: ?Table = null;
        var glyf: ?Table = null;
        var cmap: ?Table = null;
        var os2: ?Table = null;
        var post: ?Table = null;
        var name: ?Table = null;
        var cvt: ?Table = null;
        var fpgm: ?Table = null;
        var prep: ?Table = null;
        for (0..num_tables) |i| {
            const rec = 12 + i * 16;
            const tag = try slice(data, rec, 4);
            const off = try u32At(data, rec + 8);
            const len = try u32At(data, rec + 12);
            if (@as(u64, off) + len > data.len) return Error.InvalidFont;
            const table: Table = .{ .offset = off, .len = len };
            if (std.mem.eql(u8, tag, "head")) head = table else if (std.mem.eql(u8, tag, "hhea")) hhea = table else if (std.mem.eql(u8, tag, "maxp")) maxp = table else if (std.mem.eql(u8, tag, "hmtx")) hmtx = table else if (std.mem.eql(u8, tag, "loca")) loca = table else if (std.mem.eql(u8, tag, "glyf")) glyf = table else if (std.mem.eql(u8, tag, "cmap")) cmap = table else if (std.mem.eql(u8, tag, "OS/2")) os2 = table else if (std.mem.eql(u8, tag, "post")) post = table else if (std.mem.eql(u8, tag, "name")) name = table else if (std.mem.eql(u8, tag, "cvt ")) cvt = table else if (std.mem.eql(u8, tag, "fpgm")) fpgm = table else if (std.mem.eql(u8, tag, "prep")) prep = table;
        }
        const h = head orelse return Error.InvalidFont;
        const hh = hhea orelse return Error.InvalidFont;
        const mp = maxp orelse return Error.InvalidFont;
        if (h.len < 54 or hh.len < 36 or mp.len < 6) return Error.InvalidFont;

        var font: TrueType = .{
            .data = data,
            .units_per_em = try u16At(data, h.offset + 18),
            .bbox = .{ try i16At(data, h.offset + 36), try i16At(data, h.offset + 38), try i16At(data, h.offset + 40), try i16At(data, h.offset + 42) },
            .loca_long = (try i16At(data, h.offset + 50)) != 0,
            .ascent = try i16At(data, hh.offset + 4),
            .descent = try i16At(data, hh.offset + 6),
            .num_hmetrics = try u16At(data, hh.offset + 34),
            .num_glyphs = try u16At(data, mp.offset + 4),
            .cap_height = 0,
            .italic_angle = 0,
            .fixed_pitch = false,
            .head = h,
            .hhea = hh,
            .maxp = mp,
            .hmtx = hmtx orelse return Error.InvalidFont,
            .loca = loca orelse return Error.InvalidFont,
            .glyf = glyf orelse return Error.InvalidFont,
            .cvt = cvt,
            .fpgm = fpgm,
            .prep = prep,
            .cmap_format = 0,
            .cmap_offset = 0,
        };
        if (font.units_per_em < 16 or font.num_glyphs == 0 or font.num_hmetrics == 0) return Error.InvalidFont;
        if (font.num_hmetrics > font.num_glyphs) return Error.InvalidFont;
        if (@as(u64, font.num_hmetrics) * 4 > font.hmtx.len) return Error.InvalidFont;
        const loca_need = (@as(u64, font.num_glyphs) + 1) * @as(u64, if (font.loca_long) 4 else 2);
        if (loca_need > font.loca.len) return Error.InvalidFont;
        font.cap_height = @intFromFloat(@as(f32, @floatFromInt(font.ascent)) * 0.7);

        if (os2) |o| {
            if (o.len >= 10) {
                const fs_type = try u16At(data, o.offset + 8);
                // 0x0002: restricted license embedding; 0x0200: bitmap only.
                if (fs_type & 0x000F == 0x0002 or fs_type & 0x0200 != 0) return Error.FontNotEmbeddable;
            }
            if (o.len >= 90 and try u16At(data, o.offset) >= 2) font.cap_height = try i16At(data, o.offset + 88);
        }
        if (post) |p| {
            if (p.len >= 16) {
                const angle: i32 = @bitCast(try u32At(data, p.offset + 4));
                font.italic_angle = @as(f32, @floatFromInt(angle)) / 65536.0;
                font.fixed_pitch = try u32At(data, p.offset + 12) != 0;
            }
        }
        try font.pickCmap(cmap orelse return Error.InvalidFont);
        if (name) |n| font.readPostScriptName(n);
        if (font.name_len == 0) {
            const fallback = "EmbeddedFont";
            @memcpy(font.name_buf[0..fallback.len], fallback);
            font.name_len = fallback.len;
        }
        return font;
    }

    /// The PostScript name of the font.
    pub fn postScriptName(self: *const TrueType) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// The glyph for a Unicode character; 0 (the "missing" glyph) when the
    /// font has none.
    pub fn glyphIndex(self: *const TrueType, cp: u21) u16 {
        const g = switch (self.cmap_format) {
            4 => self.lookup4(cp),
            12 => self.lookup12(cp),
            else => 0,
        } catch 0;
        return if (g < self.num_glyphs) g else 0;
    }

    /// A glyph's advance width in font units.
    pub fn advance(self: *const TrueType, gid: u16) u16 {
        const i: u32 = if (gid < self.num_hmetrics) gid else self.num_hmetrics - 1;
        return u16At(self.data, self.hmtx.offset + i * 4) catch 0;
    }

    /// A glyph's advance width in thousandths of the font size (PDF text
    /// space units).
    pub fn advance1000(self: *const TrueType, gid: u16) u16 {
        return @intCast(@as(u32, self.advance(gid)) * 1000 / self.units_per_em);
    }

    /// Font units to thousandths of the font size.
    pub fn scale(self: *const TrueType, v: i32) i32 {
        return @divTrunc(v * 1000, @as(i32, self.units_per_em));
    }

    fn glyphRange(self: *const TrueType, gid: u16) Error!struct { start: u32, end: u32 } {
        const start: u32, const end: u32 = if (self.loca_long)
            .{ try u32At(self.data, self.loca.offset + @as(u32, gid) * 4), try u32At(self.data, self.loca.offset + (@as(u32, gid) + 1) * 4) }
        else
            .{ @as(u32, try u16At(self.data, self.loca.offset + @as(u32, gid) * 2)) * 2, @as(u32, try u16At(self.data, self.loca.offset + (@as(u32, gid) + 1) * 2)) * 2 };
        if (end < start or end > self.glyf.len) return Error.InvalidFont;
        return .{ .start = start, .end = end };
    }

    /// The outline data of a glyph (empty for a glyph with no outline,
    /// such as the space).
    pub fn glyphData(self: *const TrueType, gid: u16) Error![]const u8 {
        const r = try self.glyphRange(gid);
        return self.data[self.glyf.offset + r.start .. self.glyf.offset + r.end];
    }

    /// Writes a TrueType file with the same glyph numbers where only the
    /// glyphs set in `used` (plus glyph 0 and the components of composite
    /// glyphs) keep their outlines. `used` has one entry per glyph.
    pub fn subset(self: *const TrueType, allocator: std.mem.Allocator, used: []const bool) ![]u8 {
        var keep = try allocator.alloc(bool, self.num_glyphs);
        defer allocator.free(keep);
        @memset(keep, false);
        keep[0] = true;
        for (used[0..@min(used.len, keep.len)], 0..) |u, i| {
            if (u) keep[i] = true;
        }
        // Components of composite glyphs, transitively (a worklist: a
        // component may itself be composite).
        var work: std.ArrayList(u16) = .empty;
        defer work.deinit(allocator);
        for (keep, 0..) |k, i| {
            if (k) try work.append(allocator, @intCast(i));
        }
        while (work.pop()) |gid| {
            const g = try self.glyphData(gid);
            if (g.len < 10) continue;
            if (std.mem.readInt(i16, g[0..2], .big) >= 0) continue; // simple glyph
            var p: usize = 10;
            while (true) {
                if (p + 4 > g.len) return Error.InvalidFont;
                const flags = std.mem.readInt(u16, g[p..][0..2], .big);
                const comp = std.mem.readInt(u16, g[p + 2 ..][0..2], .big);
                if (comp >= self.num_glyphs) return Error.InvalidFont;
                if (!keep[comp]) {
                    keep[comp] = true;
                    try work.append(allocator, comp);
                }
                p += 4;
                p += if (flags & 0x0001 != 0) 4 else 2; // arguments: words or bytes
                if (flags & 0x0008 != 0) p += 2 // one scale
                else if (flags & 0x0040 != 0) p += 4 // x and y scales
                else if (flags & 0x0080 != 0) p += 8; // a 2x2 matrix
                if (flags & 0x0020 == 0) break; // no more components
            }
        }

        // The new glyf (each kept glyph, padded to 4 bytes) and a long loca.
        var glyf: std.ArrayList(u8) = .empty;
        defer glyf.deinit(allocator);
        const loca = try allocator.alloc(u8, (@as(usize, self.num_glyphs) + 1) * 4);
        defer allocator.free(loca);
        for (0..self.num_glyphs) |i| {
            std.mem.writeInt(u32, loca[i * 4 ..][0..4], @intCast(glyf.items.len), .big);
            if (keep[i]) {
                try glyf.appendSlice(allocator, try self.glyphData(@intCast(i)));
                while (glyf.items.len % 4 != 0) try glyf.append(allocator, 0);
            }
        }
        std.mem.writeInt(u32, loca[@as(usize, self.num_glyphs) * 4 ..][0..4], @intCast(glyf.items.len), .big);

        // head says the loca is long; its checksum adjustment is set last.
        const head = try allocator.dupe(u8, self.tableBytes(self.head));
        defer allocator.free(head);
        std.mem.writeInt(i16, head[50..52], 1, .big);
        std.mem.writeInt(u32, head[8..12], 0, .big);

        const Entry = struct { tag: *const [4]u8, data: []const u8 };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(allocator);
        // In tag order, as the table directory wants them.
        if (self.cvt) |c| try entries.append(allocator, .{ .tag = "cvt ", .data = self.tableBytes(c) });
        if (self.fpgm) |f| try entries.append(allocator, .{ .tag = "fpgm", .data = self.tableBytes(f) });
        try entries.append(allocator, .{ .tag = "glyf", .data = glyf.items });
        try entries.append(allocator, .{ .tag = "head", .data = head });
        try entries.append(allocator, .{ .tag = "hhea", .data = self.tableBytes(self.hhea) });
        try entries.append(allocator, .{ .tag = "hmtx", .data = self.tableBytes(self.hmtx) });
        try entries.append(allocator, .{ .tag = "loca", .data = loca });
        try entries.append(allocator, .{ .tag = "maxp", .data = self.tableBytes(self.maxp) });
        if (self.prep) |p| try entries.append(allocator, .{ .tag = "prep", .data = self.tableBytes(p) });

        const n: u16 = @intCast(entries.items.len);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var hdr: [12]u8 = undefined;
        var pow: u16 = 1;
        var log: u16 = 0;
        while (pow * 2 <= n) : (log += 1) pow *= 2;
        std.mem.writeInt(u32, hdr[0..4], 0x00010000, .big);
        std.mem.writeInt(u16, hdr[4..6], n, .big);
        std.mem.writeInt(u16, hdr[6..8], pow * 16, .big);
        std.mem.writeInt(u16, hdr[8..10], log, .big);
        std.mem.writeInt(u16, hdr[10..12], n * 16 - pow * 16, .big);
        try out.appendSlice(allocator, &hdr);
        try out.appendNTimes(allocator, 0, @as(usize, n) * 16);

        var head_at: usize = 0;
        for (entries.items, 0..) |e, i| {
            const off = out.items.len;
            if (std.mem.eql(u8, e.tag, "head")) head_at = off;
            try out.appendSlice(allocator, e.data);
            while (out.items.len % 4 != 0) try out.append(allocator, 0);
            const rec = out.items[12 + i * 16 ..][0..16];
            @memcpy(rec[0..4], e.tag);
            std.mem.writeInt(u32, rec[4..8], checksum(e.data), .big);
            std.mem.writeInt(u32, rec[8..12], @intCast(off), .big);
            std.mem.writeInt(u32, rec[12..16], @intCast(e.data.len), .big);
        }
        // The whole file's checksum makes 0xB1B0AFBA with the adjustment.
        std.mem.writeInt(u32, out.items[head_at + 8 ..][0..4], 0xB1B0AFBA -% checksum(out.items), .big);
        return out.toOwnedSlice(allocator);
    }

    fn tableBytes(self: *const TrueType, table: Table) []const u8 {
        return self.data[table.offset .. table.offset + table.len];
    }

    fn pickCmap(self: *TrueType, cmap: Table) Error!void {
        const count = try u16At(self.data, cmap.offset + 2);
        var best_score: u8 = 0;
        for (0..count) |i| {
            const rec = cmap.offset + 4 + @as(u32, @intCast(i)) * 8;
            const platform = try u16At(self.data, rec);
            const encoding = try u16At(self.data, rec + 2);
            const sub = cmap.offset + try u32At(self.data, rec + 4);
            const format = try u16At(self.data, sub);
            // Full Unicode (format 12) first, then the BMP (format 4).
            const score: u8 = switch (format) {
                12 => if (platform == 3 and encoding == 10) 6 else if (platform == 0) 5 else 0,
                4 => if (platform == 3 and encoding == 1) 4 else if (platform == 0) 3 else if (platform == 3 and encoding == 0) 1 else 0,
                else => 0,
            };
            if (score > best_score) {
                best_score = score;
                self.cmap_format = format;
                self.cmap_offset = sub;
            }
        }
        if (best_score == 0) return Error.InvalidFont;
    }

    fn lookup4(self: *const TrueType, cp: u21) Error!u16 {
        if (cp > 0xFFFF) return 0;
        const c: u16 = @intCast(cp);
        const base = self.cmap_offset;
        const seg_x2: u32 = try u16At(self.data, base + 6);
        const ends = base + 14;
        const starts = ends + seg_x2 + 2;
        const deltas = starts + seg_x2;
        const ranges = deltas + seg_x2;
        // Binary search on the segment ends.
        var lo: u32 = 0;
        var hi: u32 = seg_x2 / 2;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (try u16At(self.data, ends + mid * 2) < c) lo = mid + 1 else hi = mid;
        }
        if (lo >= seg_x2 / 2) return 0;
        const start = try u16At(self.data, starts + lo * 2);
        if (c < start) return 0;
        const delta = try u16At(self.data, deltas + lo * 2);
        const range_at = ranges + lo * 2;
        const range = try u16At(self.data, range_at);
        if (range == 0) return c +% delta;
        const g = try u16At(self.data, range_at + range + (@as(u32, c) - start) * 2);
        return if (g == 0) 0 else g +% delta;
    }

    fn lookup12(self: *const TrueType, cp: u21) Error!u16 {
        const base = self.cmap_offset;
        const groups = try u32At(self.data, base + 12);
        var lo: u32 = 0;
        var hi: u32 = groups;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const g = base + 16 + mid * 12;
            const start = try u32At(self.data, g);
            const end = try u32At(self.data, g + 4);
            if (cp < start) {
                hi = mid;
            } else if (cp > end) {
                lo = mid + 1;
            } else {
                const glyph = try u32At(self.data, g + 8) + (cp - start);
                return if (glyph > 0xFFFF) 0 else @intCast(glyph);
            }
        }
        return 0;
    }

    fn readPostScriptName(self: *TrueType, name: Table) void {
        const data = self.data;
        const count = u16At(data, name.offset + 2) catch return;
        const strings = name.offset + (u16At(data, name.offset + 4) catch return);
        for (0..count) |i| {
            const rec = name.offset + 6 + @as(u32, @intCast(i)) * 12;
            const platform = u16At(data, rec) catch return;
            const id = u16At(data, rec + 6) catch return;
            if (id != 6) continue;
            const len = u16At(data, rec + 8) catch return;
            const off = u16At(data, rec + 10) catch return;
            const bytes = slice(data, strings + off, len) catch return;
            // Windows names are UTF-16BE; Macintosh ones are single bytes.
            const wide = platform == 3 or platform == 0;
            var n: usize = 0;
            var j: usize = if (wide) 1 else 0;
            while (j < bytes.len and n < self.name_buf.len) : (j += if (wide) 2 else 1) {
                const ch = bytes[j];
                if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') {
                    self.name_buf[n] = ch;
                    n += 1;
                }
            }
            if (n > 0) {
                self.name_len = n;
                return;
            }
        }
    }
};

/// The TrueType table checksum: the sum of its big-endian 32-bit words,
/// the last one padded with zeros.
pub fn checksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) sum +%= std.mem.readInt(u32, data[i..][0..4], .big);
    if (i < data.len) {
        var last: [4]u8 = @splat(0);
        @memcpy(last[0 .. data.len - i], data[i..]);
        sum +%= std.mem.readInt(u32, &last, .big);
    }
    return sum;
}

fn slice(data: []const u8, off: usize, len: usize) Error![]const u8 {
    if (off > data.len or len > data.len - off) return Error.InvalidFont;
    return data[off .. off + len];
}

fn u16At(data: []const u8, off: usize) Error!u16 {
    return std.mem.readInt(u16, (try slice(data, off, 2))[0..2], .big);
}

fn i16At(data: []const u8, off: usize) Error!i16 {
    return std.mem.readInt(i16, (try slice(data, off, 2))[0..2], .big);
}

fn u32At(data: []const u8, off: usize) Error!u32 {
    return std.mem.readInt(u32, (try slice(data, off, 4))[0..4], .big);
}

// ── Tests ───────────────────────────────────────────────────────────────

pub const testing = struct {
    /// A small but real TrueType font for the tests: glyph 0 (missing),
    /// 1 'A', 2 'B', 3 'Á' (composite: 1 + 4), 4 the acute accent, 5 '?',
    /// 6 the space (no outline), 7 'Ж' (U+0416) and 8 '😀' (U+1F600, through
    /// cmap format 12). 1000 units per em; widths 500 + 50 * glyph.
    pub fn font(allocator: std.mem.Allocator, opts: struct { fs_type: u16 = 0, version: u32 = 0x00010000, with_format12: bool = true }) ![]u8 {
        const num_glyphs = 9;
        var glyf: std.ArrayList(u8) = .empty;
        defer glyf.deinit(allocator);
        var loca: [num_glyphs + 1]u32 = undefined;
        for (0..num_glyphs) |g| {
            loca[g] = @intCast(glyf.items.len);
            if (g == 6) continue; // the space has no outline
            if (g == 3) {
                // Composite: numberOfContours -1, bbox, then two components.
                try appendBE(allocator, &glyf, i16, -1);
                for (0..4) |_| try appendBE(allocator, &glyf, i16, 0);
                try appendBE(allocator, &glyf, u16, 0x0001 | 0x0020); // words, more
                try appendBE(allocator, &glyf, u16, 1);
                try appendBE(allocator, &glyf, i16, 0);
                try appendBE(allocator, &glyf, i16, 0);
                try appendBE(allocator, &glyf, u16, 0x0001 | 0x0008); // words, a scale
                try appendBE(allocator, &glyf, u16, 4);
                try appendBE(allocator, &glyf, i16, 100);
                try appendBE(allocator, &glyf, i16, 600);
                try appendBE(allocator, &glyf, u16, 0x4000); // scale 1.0
            } else {
                // A "simple glyph": one contour; the rest is opaque here, so
                // a recognizable filler stands for its instructions/points.
                try appendBE(allocator, &glyf, i16, 1);
                for (0..4) |_| try appendBE(allocator, &glyf, i16, 0);
                for (0..6) |_| try glyf.append(allocator, @intCast(0xA0 + g));
            }
            while (glyf.items.len % 2 != 0) try glyf.append(allocator, 0);
        }
        loca[num_glyphs] = @intCast(glyf.items.len);

        var loca_bytes: [(num_glyphs + 1) * 2]u8 = undefined;
        for (loca, 0..) |o, i| std.mem.writeInt(u16, loca_bytes[i * 2 ..][0..2], @intCast(o / 2), .big);

        var head: [54]u8 = @splat(0);
        std.mem.writeInt(u32, head[0..4], 0x00010000, .big);
        std.mem.writeInt(u32, head[12..16], 0x5F0F3CF5, .big);
        std.mem.writeInt(u16, head[18..20], 1000, .big);
        std.mem.writeInt(i16, head[36..38], -50, .big);
        std.mem.writeInt(i16, head[38..40], -200, .big);
        std.mem.writeInt(i16, head[40..42], 950, .big);
        std.mem.writeInt(i16, head[42..44], 900, .big);
        std.mem.writeInt(i16, head[50..52], 0, .big); // short loca

        var hhea: [36]u8 = @splat(0);
        std.mem.writeInt(u32, hhea[0..4], 0x00010000, .big);
        std.mem.writeInt(i16, hhea[4..6], 800, .big);
        std.mem.writeInt(i16, hhea[6..8], -200, .big);
        std.mem.writeInt(u16, hhea[34..36], num_glyphs, .big);

        var maxp: [6]u8 = undefined;
        std.mem.writeInt(u32, maxp[0..4], 0x00005000, .big);
        std.mem.writeInt(u16, maxp[4..6], num_glyphs, .big);

        var hmtx: [num_glyphs * 4]u8 = undefined;
        for (0..num_glyphs) |g| {
            std.mem.writeInt(u16, hmtx[g * 4 ..][0..2], @intCast(500 + 50 * g), .big);
            std.mem.writeInt(i16, hmtx[g * 4 + 2 ..][0..2], 0, .big);
        }

        var os2: [96]u8 = @splat(0);
        std.mem.writeInt(u16, os2[0..2], 4, .big);
        std.mem.writeInt(u16, os2[8..10], opts.fs_type, .big);
        std.mem.writeInt(i16, os2[88..90], 700, .big);

        var post: [32]u8 = @splat(0);
        std.mem.writeInt(u32, post[0..4], 0x00030000, .big);
        std.mem.writeInt(i32, post[4..8], -12 * 65536, .big);

        // name: one Windows record, id 6, "Test-Sans" in UTF-16BE.
        var name: std.ArrayList(u8) = .empty;
        defer name.deinit(allocator);
        const ps = "Test-Sans";
        try appendBE(allocator, &name, u16, 0);
        try appendBE(allocator, &name, u16, 1);
        try appendBE(allocator, &name, u16, 6 + 12);
        for ([_]u16{ 3, 1, 0x409, 6, ps.len * 2, 0 }) |v| try appendBE(allocator, &name, u16, v);
        for (ps) |ch| try appendBE(allocator, &name, u16, ch);

        // cmap: format 4 for the BMP (with an idRangeOffset segment for
        // 'Á'), format 12 for everything.
        var f4: std.ArrayList(u8) = .empty;
        defer f4.deinit(allocator);
        // Segments: 0x20 (space→6), 0x3F ('?'→5), 0x41-0x42 ('A','B'→1,2),
        // 0xC1 ('Á', through idRangeOffset → 3), 0x416 ('Ж'→7), 0xFFFF.
        const seg_start = [_]u16{ 0x20, 0x3F, 0x41, 0xC1, 0x416, 0xFFFF };
        const seg_end = [_]u16{ 0x20, 0x3F, 0x42, 0xC1, 0x416, 0xFFFF };
        const seg_delta = [_]u16{ @bitCast(@as(i16, 6 - 0x20)), @bitCast(@as(i16, 5 - 0x3F)), @bitCast(@as(i16, 1 - 0x41)), 0, @bitCast(@as(i16, 7 - 0x416)), 1 };
        const segs = seg_start.len;
        try appendBE(allocator, &f4, u16, 4);
        try appendBE(allocator, &f4, u16, 0); // length, set below
        try appendBE(allocator, &f4, u16, 0);
        try appendBE(allocator, &f4, u16, segs * 2);
        for ([_]u16{ 8, 2, segs * 2 - 8 }) |v| try appendBE(allocator, &f4, u16, v);
        for (seg_end) |v| try appendBE(allocator, &f4, u16, v);
        try appendBE(allocator, &f4, u16, 0);
        for (seg_start) |v| try appendBE(allocator, &f4, u16, v);
        for (seg_delta) |v| try appendBE(allocator, &f4, u16, v);
        for (0..segs) |s| {
            // Segment 3 points at the glyph array right after this array.
            try appendBE(allocator, &f4, u16, if (s == 3) @as(u16, @intCast((segs - s) * 2)) else 0);
        }
        try appendBE(allocator, &f4, u16, 3); // glyphIdArray[0]: 'Á' → 3
        std.mem.writeInt(u16, f4.items[2..4], @intCast(f4.items.len), .big);

        var f12: std.ArrayList(u8) = .empty;
        defer f12.deinit(allocator);
        const groups = [_][3]u32{ .{ 0x20, 0x20, 6 }, .{ 0x3F, 0x3F, 5 }, .{ 0x41, 0x42, 1 }, .{ 0xC1, 0xC1, 3 }, .{ 0x416, 0x416, 7 }, .{ 0x1F600, 0x1F600, 8 } };
        try appendBE(allocator, &f12, u16, 12);
        try appendBE(allocator, &f12, u16, 0);
        try appendBE(allocator, &f12, u32, 16 + groups.len * 12);
        try appendBE(allocator, &f12, u32, 0);
        try appendBE(allocator, &f12, u32, groups.len);
        for (groups) |g| for (g) |v| try appendBE(allocator, &f12, u32, v);

        var cmap: std.ArrayList(u8) = .empty;
        defer cmap.deinit(allocator);
        const subtables: u16 = if (opts.with_format12) 2 else 1;
        try appendBE(allocator, &cmap, u16, 0);
        try appendBE(allocator, &cmap, u16, subtables);
        const first: u32 = 4 + @as(u32, subtables) * 8;
        for ([_]u16{ 3, 1 }) |v| try appendBE(allocator, &cmap, u16, v);
        try appendBE(allocator, &cmap, u32, first);
        if (opts.with_format12) {
            for ([_]u16{ 3, 10 }) |v| try appendBE(allocator, &cmap, u16, v);
            try appendBE(allocator, &cmap, u32, first + @as(u32, @intCast(f4.items.len)));
        }
        try cmap.appendSlice(allocator, f4.items);
        if (opts.with_format12) try cmap.appendSlice(allocator, f12.items);

        const Entry = struct { tag: *const [4]u8, data: []const u8 };
        const entries = [_]Entry{
            .{ .tag = "OS/2", .data = &os2 },
            .{ .tag = "cmap", .data = cmap.items },
            .{ .tag = "glyf", .data = glyf.items },
            .{ .tag = "head", .data = &head },
            .{ .tag = "hhea", .data = &hhea },
            .{ .tag = "hmtx", .data = &hmtx },
            .{ .tag = "loca", .data = &loca_bytes },
            .{ .tag = "maxp", .data = &maxp },
            .{ .tag = "name", .data = name.items },
            .{ .tag = "post", .data = &post },
        };
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try appendBE(allocator, &out, u32, opts.version);
        try appendBE(allocator, &out, u16, entries.len);
        for ([_]u16{ 128, 3, entries.len * 16 - 128 }) |v| try appendBE(allocator, &out, u16, v);
        try out.appendNTimes(allocator, 0, entries.len * 16);
        for (entries, 0..) |e, i| {
            const off = out.items.len;
            try out.appendSlice(allocator, e.data);
            while (out.items.len % 4 != 0) try out.append(allocator, 0);
            const rec = out.items[12 + i * 16 ..][0..16];
            @memcpy(rec[0..4], e.tag);
            std.mem.writeInt(u32, rec[4..8], checksum(e.data), .big);
            std.mem.writeInt(u32, rec[8..12], @intCast(off), .big);
            std.mem.writeInt(u32, rec[12..16], @intCast(e.data.len), .big);
        }
        return out.toOwnedSlice(allocator);
    }

    fn appendBE(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .big);
        try list.appendSlice(allocator, &b);
    }
};

const t = std.testing;

test "parse reads the metrics and the PostScript name" {
    const bytes = try testing.font(t.allocator, .{});
    defer t.allocator.free(bytes);
    const f = try TrueType.parse(bytes);
    try t.expectEqual(@as(u16, 1000), f.units_per_em);
    try t.expectEqual(@as(u16, 9), f.num_glyphs);
    try t.expectEqual(@as(i16, 800), f.ascent);
    try t.expectEqual(@as(i16, -200), f.descent);
    try t.expectEqual(@as(i16, 700), f.cap_height);
    try t.expectEqual([4]i16{ -50, -200, 950, 900 }, f.bbox);
    try t.expectApproxEqAbs(@as(f32, -12), f.italic_angle, 0.001);
    try t.expectEqualStrings("Test-Sans", f.postScriptName());
}

test "glyphIndex maps characters through cmap format 12, and format 4 without it" {
    inline for (.{ true, false }) |with12| {
        const bytes = try testing.font(t.allocator, .{ .with_format12 = with12 });
        defer t.allocator.free(bytes);
        const f = try TrueType.parse(bytes);
        try t.expectEqual(@as(u16, if (with12) 12 else 4), f.cmap_format);
        try t.expectEqual(@as(u16, 1), f.glyphIndex('A'));
        try t.expectEqual(@as(u16, 2), f.glyphIndex('B'));
        try t.expectEqual(@as(u16, 3), f.glyphIndex(0xC1)); // Á, through idRangeOffset in format 4
        try t.expectEqual(@as(u16, 6), f.glyphIndex(' '));
        try t.expectEqual(@as(u16, 7), f.glyphIndex(0x416));
        try t.expectEqual(@as(u16, 0), f.glyphIndex('Z'));
        // Beyond the BMP only format 12 has it.
        try t.expectEqual(@as(u16, if (with12) 8 else 0), f.glyphIndex(0x1F600));
    }
}

test "advance widths come from hmtx, scaled to thousandths" {
    const bytes = try testing.font(t.allocator, .{});
    defer t.allocator.free(bytes);
    const f = try TrueType.parse(bytes);
    try t.expectEqual(@as(u16, 550), f.advance(1));
    try t.expectEqual(@as(u16, 550), f.advance1000(1));
    try t.expectEqual(@as(u16, 800), f.advance1000(6));
}

test "a subset keeps used glyphs and their components, empties the rest, and passes the checksum" {
    const bytes = try testing.font(t.allocator, .{});
    defer t.allocator.free(bytes);
    const f = try TrueType.parse(bytes);
    var used: [9]bool = @splat(false);
    used[3] = true;
    const sub = try f.subset(t.allocator, &used);
    defer t.allocator.free(sub);

    // The subset has no cmap (the PDF maps codes to glyphs itself), so it
    // is read here table by table.
    try t.expectEqual(@as(u32, 0xB1B0AFBA), checksum(sub));
    var tables = std.StringHashMap([]const u8).init(t.allocator);
    defer tables.deinit();
    const n = std.mem.readInt(u16, sub[4..6], .big);
    var prev: [4]u8 = @splat(0);
    for (0..n) |i| {
        const rec = sub[12 + i * 16 ..][0..16];
        try t.expect(std.mem.order(u8, &prev, rec[0..4]) == .lt); // sorted tags
        prev = rec[0..4].*;
        const off = std.mem.readInt(u32, rec[8..12], .big);
        const len = std.mem.readInt(u32, rec[12..16], .big);
        try t.expectEqual(off % 4, 0);
        // head's checksum is taken with its checksum adjustment zeroed.
        var copy = try t.allocator.dupe(u8, sub[off .. off + len]);
        defer t.allocator.free(copy);
        if (std.mem.eql(u8, rec[0..4], "head")) @memset(copy[8..12], 0);
        try t.expectEqual(std.mem.readInt(u32, rec[4..8], .big), checksum(copy));
        try tables.put(rec[0..4], sub[off .. off + len]);
    }
    const head = tables.get("head").?;
    try t.expectEqual(@as(i16, 1), std.mem.readInt(i16, head[50..52], .big)); // long loca
    const loca = tables.get("loca").?;
    try t.expectEqual(@as(usize, 10 * 4), loca.len);
    const len_of = struct {
        fn of(l: []const u8, g: usize) u32 {
            return std.mem.readInt(u32, l[(g + 1) * 4 ..][0..4], .big) - std.mem.readInt(u32, l[g * 4 ..][0..4], .big);
        }
    }.of;
    try t.expect(len_of(loca, 0) > 0); // the missing glyph is always kept
    try t.expect(len_of(loca, 1) > 0); // A, a component
    try t.expectEqual(@as(u32, 0), len_of(loca, 2)); // B, unused
    try t.expect(len_of(loca, 3) > 0); // Á
    try t.expect(len_of(loca, 4) > 0); // the accent, a component
    try t.expectEqual(@as(u32, 0), len_of(loca, 5));
    try t.expectEqual(@as(u32, 0), len_of(loca, 7));
    // The outlines kept are the original bytes.
    const glyf = tables.get("glyf").?;
    const a_at = std.mem.readInt(u32, loca[4..8], .big);
    try t.expectEqualSlices(u8, try f.glyphData(1), glyf[a_at .. a_at + (try f.glyphData(1)).len]);
    // hmtx is whole: widths stay where the PDF expects them.
    try t.expectEqual(f.tableBytes(f.hmtx).len, tables.get("hmtx").?.len);
}

test "fonts that cannot be embedded, CFF fonts and broken files are refused" {
    {
        const bytes = try testing.font(t.allocator, .{ .fs_type = 0x0002 });
        defer t.allocator.free(bytes);
        try t.expectError(Error.FontNotEmbeddable, TrueType.parse(bytes));
    }
    {
        const bytes = try testing.font(t.allocator, .{ .fs_type = 0x0200 });
        defer t.allocator.free(bytes);
        try t.expectError(Error.FontNotEmbeddable, TrueType.parse(bytes));
    }
    {
        // Preview & print (0x0004) and editable (0x0008) embedding are fine.
        const bytes = try testing.font(t.allocator, .{ .fs_type = 0x0004 });
        defer t.allocator.free(bytes);
        _ = try TrueType.parse(bytes);
    }
    {
        const bytes = try testing.font(t.allocator, .{ .version = 0x4F54544F });
        defer t.allocator.free(bytes);
        try t.expectError(Error.UnsupportedFont, TrueType.parse(bytes));
    }
    try t.expectError(Error.InvalidFont, TrueType.parse("not a font at all"));
    const bytes = try testing.font(t.allocator, .{});
    defer t.allocator.free(bytes);
    try t.expectError(Error.InvalidFont, TrueType.parse(bytes[0 .. bytes.len / 2]));
}

test "checksum pads the last word with zeros" {
    try t.expectEqual(@as(u32, 0x01020304 +% 0x05000000), checksum(&.{ 1, 2, 3, 4, 5 }));
}
