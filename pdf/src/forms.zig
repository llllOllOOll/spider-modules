//! Form fields a document creates: text boxes, checkboxes, radio button
//! groups and drop-down lists, with their appearances drawn, so they show
//! filled in every reader and can be filled in by people (or by `Editor`).
//!
//! Each field is a widget annotation on its page (a radio group is one
//! field with a widget per choice), listed in the document's AcroForm with
//! Helvetica (text) and ZapfDingbats (check marks) as its resources.

const std = @import("std");
const document = @import("document.zig");
const fonts = @import("fonts.zig");
const text_mod = @import("text.zig");

const Color = document.Color;
const Align = document.Align;

pub const Kind = enum { text, checkbox, radio, dropdown };

pub const Widget = struct {
    page: usize,
    /// x1, y1, x2, y2 in PDF coordinates.
    rect: [4]f32,
    /// The state name this widget shows when on ("Yes", or the choice of a
    /// radio button).
    on: []const u8,
};

pub const Field = struct {
    name: []const u8,
    kind: Kind,
    /// Ff: 1 read only, 2 required, 4096 multiline, 1 << 17 combo, 1 << 18
    /// editable, 1 << 15 radio, 1 << 14 no toggle to off.
    flags: u32,
    /// Text, the chosen option, the selected radio choice, or "" (off).
    value: []const u8,
    size: f32,
    alignment: Align,
    max_len: ?u32,
    options: []const []const u8 = &.{},
    border: ?Color,
    background: ?Color,
    widgets: std.ArrayList(Widget) = .empty,
};

pub const TextFieldOptions = struct {
    value: []const u8 = "",
    /// Font size; 0 fits the box.
    size: f32 = 0,
    multiline: bool = false,
    max_length: ?u32 = null,
    @"align": Align = .left,
    read_only: bool = false,
    required: bool = false,
    border: ?Color = Color.gray,
    background: ?Color = null,
};

pub const CheckboxOptions = struct {
    checked: bool = false,
    read_only: bool = false,
    required: bool = false,
    border: ?Color = Color.gray,
    background: ?Color = null,
};

/// One button of a radio group: its value and where it sits (top-left).
pub const RadioChoice = struct { value: []const u8, x: f32, y: f32 };

pub const RadioOptions = struct {
    /// The choice selected at first; null: none.
    selected: ?[]const u8 = null,
    read_only: bool = false,
    required: bool = false,
    border: ?Color = Color.gray,
    background: ?Color = null,
};

pub const DropdownOptions = struct {
    /// The option shown at first; null: the first one.
    value: ?[]const u8 = null,
    /// Lets people type a value that is not among the options.
    editable: bool = false,
    size: f32 = 0,
    read_only: bool = false,
    required: bool = false,
    border: ?Color = Color.gray,
    background: ?Color = null,
};

pub fn baseFlags(read_only: bool, required: bool) u32 {
    return (if (read_only) @as(u32, 1) else 0) | (if (required) @as(u32, 2) else 0);
}

// ── Appearances ─────────────────────────────────────────────────────────

const pad: f32 = 2;
/// ZapfDingbats: '4' is a check mark (846 thousandths wide), 'l' a filled
/// circle (791).
const check_char: u8 = '4';
const check_width: f32 = 0.846;
const dot_char: u8 = 'l';
const dot_width: f32 = 0.791;

fn color(out: *std.ArrayList(u8), a: std.mem.Allocator, c: Color, op: []const u8) !void {
    try out.print(a, "{d:.3} {d:.3} {d:.3} {s} ", .{ @as(f32, @floatFromInt(c.r)) / 255, @as(f32, @floatFromInt(c.g)) / 255, @as(f32, @floatFromInt(c.b)) / 255, op });
}

fn frame(out: *std.ArrayList(u8), a: std.mem.Allocator, f: *const Field, w: f32, h: f32, round: bool) !void {
    if (f.background) |bg| {
        try color(out, a, bg, "rg");
        if (round) try circlePath(out, a, w / 2, h / 2, @min(w, h) / 2 - 0.5) else try out.print(a, "0 0 {d:.2} {d:.2} re ", .{ w, h });
        try out.appendSlice(a, "f\n");
    }
    if (f.border) |b| {
        try color(out, a, b, "RG");
        try out.appendSlice(a, "1 w ");
        if (round) try circlePath(out, a, w / 2, h / 2, @min(w, h) / 2 - 0.5) else try out.print(a, "0.5 0.5 {d:.2} {d:.2} re ", .{ w - 1, h - 1 });
        try out.appendSlice(a, "S\n");
    }
}

fn circlePath(out: *std.ArrayList(u8), a: std.mem.Allocator, cx: f32, cy: f32, r: f32) !void {
    const k = r * 0.5522848;
    try out.print(a, "{d:.2} {d:.2} m ", .{ cx + r, cy });
    try out.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ cx + r, cy + k, cx + k, cy + r, cx, cy + r });
    try out.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ cx - k, cy + r, cx - r, cy + k, cx - r, cy });
    try out.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c ", .{ cx - r, cy - k, cx - k, cy - r, cx, cy - r });
    try out.print(a, "{d:.2} {d:.2} {d:.2} {d:.2} {d:.2} {d:.2} c h ", .{ cx + k, cy - r, cx + r, cy - k, cx + r, cy });
}

/// The font size a text field draws with: its own, or one that fits the
/// box (and, on one line, the text).
pub fn fittedSize(f: *const Field, text: []const u8, w: f32, h: f32) f32 {
    if (f.size > 0) return f.size;
    if (f.flags & (1 << 12) != 0) return 10;
    var size = @min(12, @max(4, (h - 2 * pad) * 0.7));
    while (size > 4 and fonts.width(text, .helvetica, size) > w - 2 * pad) size -= 0.5;
    return size;
}

/// The appearance of a text field or a drop-down list showing `value`.
pub fn textAppearance(a: std.mem.Allocator, f: *const Field, w: f32, h: f32) ![]const u8 {
    var encoded: std.ArrayList(u8) = .empty;
    try fonts.encode(a, &encoded, f.value);
    const text = encoded.items;
    const multiline = f.flags & (1 << 12) != 0;
    const size = fittedSize(f, text, w, h);

    var out: std.ArrayList(u8) = .empty;
    try frame(&out, a, f, w, h, false);
    try out.print(a, "/Tx BMC\nq {d:.2} {d:.2} {d:.2} {d:.2} re W n\nBT /Helv {d:.2} Tf 0 g\n", .{ pad / 2, pad / 2, w - pad, h - pad, size });

    // The lines: one, or wrapped to the box.
    var lines: std.ArrayList([]const u8) = .empty;
    if (multiline) {
        const codes = try a.alloc(u16, text.len);
        const widths = try a.alloc(u16, text.len);
        const cps = try a.alloc(u21, text.len);
        for (text, 0..) |b, i| {
            codes[i] = b;
            widths[i] = if (b == '\n') 0 else fonts.charWidth(b, .helvetica);
            cps[i] = b;
        }
        const run: text_mod.Run = .{ .codes = codes, .widths = widths, .cps = cps };
        for (try text_mod.wrap(a, run, w - 2 * pad, size)) |ln| try lines.append(a, text[ln.start..ln.end]);
    } else {
        for (text) |*b| {
            if (b.* == '\n') b.* = ' ';
        }
        try lines.append(a, text);
    }
    for (lines.items, 0..) |line, i| {
        const tw = fonts.width(line, .helvetica, size);
        const x: f32 = switch (f.alignment) {
            .left => pad,
            .center => (w - tw) / 2,
            .right => w - pad - tw,
        };
        const y: f32 = if (multiline) h - pad - size * 0.9 - @as(f32, @floatFromInt(i)) * size * 1.15 else (h - size) / 2 + size * 0.22;
        try out.print(a, "1 0 0 1 {d:.2} {d:.2} Tm (", .{ x, y });
        for (line) |b| {
            if (b == '(' or b == ')' or b == '\\') try out.append(a, '\\');
            try out.append(a, b);
        }
        try out.appendSlice(a, ") Tj\n");
    }
    try out.appendSlice(a, "ET\nQ\nEMC\n");
    return out.items;
}

/// The "on" or "off" appearance of a checkbox (a check mark) or a radio
/// button (a dot in a circle).
pub fn buttonAppearance(a: std.mem.Allocator, f: *const Field, w: f32, h: f32, on: bool) ![]const u8 {
    const radio = f.kind == .radio;
    var out: std.ArrayList(u8) = .empty;
    try frame(&out, a, f, w, h, radio);
    if (on) {
        const size = @min(w, h) * (if (radio) @as(f32, 0.6) else 0.8);
        const cw = (if (radio) dot_width else check_width) * size;
        try out.print(a, "q BT /ZaDb {d:.2} Tf 0 g 1 0 0 1 {d:.2} {d:.2} Tm ({c}) Tj ET Q\n", .{ size, (w - cw) / 2, (h - size * 0.7) / 2, if (radio) dot_char else check_char });
    }
    return out.items;
}

// ── Writing ─────────────────────────────────────────────────────────────

/// A PDF name, with `#xx` for anything that is not a regular character.
pub fn writeName(w: *std.Io.Writer, n: []const u8) !void {
    try w.writeByte('/');
    for (n) |b| {
        const regular = b > 0x20 and b < 0x7F and std.mem.indexOfScalar(u8, "()<>[]{}/%#", b) == null;
        if (regular) try w.writeByte(b) else try w.print("#{X:0>2}", .{b});
    }
}

fn writeColorArray(w: *std.Io.Writer, c: Color) !void {
    try w.print("[{d:.3} {d:.3} {d:.3}]", .{ @as(f32, @floatFromInt(c.r)) / 255, @as(f32, @floatFromInt(c.g)) / 255, @as(f32, @floatFromInt(c.b)) / 255 });
}

/// The entries every field writes: type, name, flags, appearance
/// characteristics.
pub fn writeFieldEntries(w: *std.Io.Writer, f: *const Field, writeText: anytype) !void {
    try w.writeAll(switch (f.kind) {
        .text => " /FT /Tx",
        .checkbox, .radio => " /FT /Btn",
        .dropdown => " /FT /Ch",
    });
    try w.writeAll(" /T ");
    try writeText(w, f.name);
    if (f.flags != 0) try w.print(" /Ff {d}", .{f.flags});
    switch (f.kind) {
        .text, .dropdown => {
            try w.print(" /DA (/Helv {d:.2} Tf 0 g)", .{f.size});
            try w.writeAll(" /V ");
            try writeText(w, f.value);
            if (f.kind == .text) {
                try w.print(" /Q {d}", .{@backingInt(f.alignment)});
                if (f.max_len) |m| try w.print(" /MaxLen {d}", .{m});
            } else {
                try w.writeAll(" /Opt [");
                for (f.options) |o| {
                    try w.writeByte(' ');
                    try writeText(w, o);
                }
                try w.writeAll(" ]");
            }
        },
        .checkbox, .radio => {
            try w.writeAll(" /DA (/ZaDb 0 Tf 0 g) /V ");
            try writeName(w, if (f.value.len == 0) "Off" else f.value);
        },
    }
}

/// The widget's own entries: its box, its page, the state it shows and
/// its appearances (`ap` is the first of its appearance streams).
pub fn writeWidgetEntries(w: *std.Io.Writer, f: *const Field, wd: Widget, page_id: usize, ap: usize) !void {
    try w.print(" /Type /Annot /Subtype /Widget /Rect [{d:.2} {d:.2} {d:.2} {d:.2}] /P {d} 0 R /F 4", .{ wd.rect[0], wd.rect[1], wd.rect[2], wd.rect[3], page_id });
    try w.writeAll(" /MK <<");
    if (f.border) |b| {
        try w.writeAll(" /BC ");
        try writeColorArray(w, b);
    }
    if (f.background) |b| {
        try w.writeAll(" /BG ");
        try writeColorArray(w, b);
    }
    switch (f.kind) {
        .checkbox => try w.writeAll(" /CA (4)"),
        .radio => try w.writeAll(" /CA (l)"),
        else => {},
    }
    try w.writeAll(" >>");
    switch (f.kind) {
        .text, .dropdown => try w.print(" /AP << /N {d} 0 R >>", .{ap}),
        .checkbox, .radio => {
            const on = std.mem.eql(u8, f.value, wd.on);
            try w.writeAll(" /AS ");
            try writeName(w, if (on) wd.on else "Off");
            try w.writeAll(" /AP << /N <<");
            try w.writeByte(' ');
            try writeName(w, wd.on);
            try w.print(" {d} 0 R /Off {d} 0 R >> >>", .{ ap, ap + 1 });
        },
    }
}

/// How many appearance streams a widget of this kind has.
pub fn appearanceCount(kind: Kind) usize {
    return switch (kind) {
        .text, .dropdown => 1,
        .checkbox, .radio => 2,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn testField(kind: Kind, value: []const u8) Field {
    return .{ .name = "f", .kind = kind, .flags = 0, .value = value, .size = 0, .alignment = .left, .max_len = null, .border = Color.gray, .background = Color.white };
}

test "a text appearance fits its value, draws the frame and clips" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const f = testField(.text, "Olá (mundo)");
    const ap = try textAppearance(arena.allocator(), &f, 200, 20);
    try t.expect(std.mem.indexOf(u8, ap, "0 0 200.00 20.00 re f") != null); // background
    try t.expect(std.mem.indexOf(u8, ap, "0.5 0.5 199.00 19.00 re S") != null); // border
    try t.expect(std.mem.indexOf(u8, ap, "re W n") != null);
    try t.expect(std.mem.indexOf(u8, ap, "(Ol\xe1 \\(mundo\\)) Tj") != null);
    try t.expect(std.mem.indexOf(u8, ap, "/Helv 11.20 Tf") != null); // (20 - 4) * 0.7
}

test "a long single-line value shrinks; a multiline one wraps" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = testField(.text, "a long value in a narrow box");
    try t.expect(fittedSize(&f, f.value, 60, 20) < 11.2);
    f.flags = 1 << 12;
    const ap = try textAppearance(a, &f, 60, 80);
    try t.expect(std.mem.count(u8, ap, " Tj") >= 3);
}

test "button appearances: a check mark, a dot in a circle, nothing when off" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const box = testField(.checkbox, "Yes");
    try t.expect(std.mem.indexOf(u8, try buttonAppearance(a, &box, 12, 12, true), "(4) Tj") != null);
    try t.expect(std.mem.indexOf(u8, try buttonAppearance(a, &box, 12, 12, false), "Tj") == null);
    const radio = testField(.radio, "a");
    const on = try buttonAppearance(a, &radio, 12, 12, true);
    try t.expect(std.mem.indexOf(u8, on, "(l) Tj") != null);
    try t.expect(std.mem.indexOf(u8, on, " c h ") != null); // the circle
}

test "names are escaped" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try writeName(&out.writer, "Sim (1)#");
    try t.expectEqualStrings("/Sim#20#281#29#23", out.written());
}
