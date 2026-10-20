//! The standard PDF fonts this module draws with: Helvetica and Courier,
//! regular, bold, oblique and bold oblique. Every PDF reader has them, so
//! nothing is embedded and a page of text costs a few hundred bytes.
//!
//! Text goes in as UTF-8 and is written as WinAnsi (Windows-1252), the
//! encoding these fonts use: it covers the Latin-1 letters (Portuguese,
//! Spanish, French, German...) plus curly quotes, dashes, the bullet and
//! the euro sign. A character outside it is written as `?`.
//!
//! Widths come from the fonts' AFM files: the same numbers a PDF reader
//! uses to place the glyphs, so measured text lines up with drawn text.

const std = @import("std");

pub const Font = enum {
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    helvetica_bold_oblique,
    courier,
    courier_bold,
    courier_oblique,
    courier_bold_oblique,

    /// The font's PostScript name, as the PDF names it.
    pub fn baseName(self: Font) []const u8 {
        return switch (self) {
            .helvetica => "Helvetica",
            .helvetica_bold => "Helvetica-Bold",
            .helvetica_oblique => "Helvetica-Oblique",
            .helvetica_bold_oblique => "Helvetica-BoldOblique",
            .courier => "Courier",
            .courier_bold => "Courier-Bold",
            .courier_oblique => "Courier-Oblique",
            .courier_bold_oblique => "Courier-BoldOblique",
        };
    }

    /// How far the capital letters rise above the baseline, in units of
    /// the font size (from the AFM files' Ascender).
    pub fn ascent(self: Font) f32 {
        return switch (self) {
            .helvetica, .helvetica_bold, .helvetica_oblique, .helvetica_bold_oblique => 0.718,
            else => 0.629,
        };
    }

    fn isBold(self: Font) bool {
        return switch (self) {
            .helvetica_bold, .helvetica_bold_oblique, .courier_bold, .courier_bold_oblique => true,
            else => false,
        };
    }

    fn isCourier(self: Font) bool {
        return @backingInt(self) >= @backingInt(Font.courier);
    }
};

/// Appends `utf8` to `out` as WinAnsi bytes. Invalid UTF-8 and characters
/// WinAnsi lacks become `?`, so a bad byte never breaks the document.
pub fn encode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), utf8: []const u8) !void {
    var i: usize = 0;
    while (i < utf8.len) {
        const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch {
            try out.append(allocator, '?');
            i += 1;
            continue;
        };
        if (i + len > utf8.len) {
            try out.append(allocator, '?');
            break;
        }
        const cp = std.unicode.utf8Decode(utf8[i .. i + len]) catch {
            try out.append(allocator, '?');
            i += len;
            continue;
        };
        i += len;
        try out.append(allocator, winAnsi(cp) orelse '?');
    }
}

/// The WinAnsi byte of a Unicode code point, or null when it has none.
pub fn winAnsi(cp: u21) ?u8 {
    if (cp == '\t') return ' ';
    if (cp < 0x20) return if (cp == '\n') '\n' else null;
    if (cp < 0x7F) return @intCast(cp);
    if (cp >= 0xA0 and cp <= 0xFF) return @intCast(cp);
    return switch (cp) {
        0x20AC => 0x80, // euro
        0x201A => 0x82,
        0x0192 => 0x83,
        0x201E => 0x84,
        0x2026 => 0x85, // ellipsis
        0x2020 => 0x86,
        0x2021 => 0x87,
        0x02C6 => 0x88,
        0x2030 => 0x89,
        0x0160 => 0x8A,
        0x2039 => 0x8B,
        0x0152 => 0x8C,
        0x017D => 0x8E,
        0x2018 => 0x91,
        0x2019 => 0x92,
        0x201C => 0x93,
        0x201D => 0x94,
        0x2022 => 0x95, // bullet
        0x2013 => 0x96, // en dash
        0x2014 => 0x97, // em dash
        0x02DC => 0x98,
        0x2122 => 0x99, // trademark
        0x0161 => 0x9A,
        0x203A => 0x9B,
        0x0153 => 0x9C,
        0x017E => 0x9E,
        0x0178 => 0x9F,
        else => null,
    };
}

/// The width of WinAnsi-encoded `text` in points, at `size`.
pub fn width(text: []const u8, font: Font, size: f32) f32 {
    var units: u32 = 0;
    for (text) |b| units += charWidth(b, font);
    return @as(f32, @floatFromInt(units)) / 1000.0 * size;
}

/// The width of UTF-8 `text` in points, at `size`.
pub fn widthUtf8(text: []const u8, font: Font, size: f32) f32 {
    var units: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = if (i + len <= text.len) std.unicode.utf8Decode(text[i .. i + len]) catch '?' else '?';
        i += len;
        units += charWidth(winAnsi(cp) orelse '?', font);
    }
    return @as(f32, @floatFromInt(units)) / 1000.0 * size;
}

/// The width of one WinAnsi byte, in thousandths of the font size.
pub fn charWidth(b: u8, font: Font) u16 {
    if (font.isCourier()) return 600;
    const bold = font.isBold();
    if (b >= 32 and b <= 126) return if (bold) helvetica_bold[b - 32] else helvetica[b - 32];
    if (b == '\n') return 0;
    return switch (b) {
        0x80 => 556, // euro
        0x85, 0x97, 0x89 => 1000, // ellipsis, em dash, per mille
        0x95 => 350, // bullet
        0x96 => 556, // en dash
        0x91, 0x92, 0x82 => if (bold) 278 else 222,
        0x93, 0x94, 0x84 => if (bold) 500 else 333,
        0x99 => 1000,
        0xA0 => 278, // no-break space
        0xB0 => 400, // degree
        0xAA => 370,
        0xBA => 365,
        0xA7 => 556, // section
        0xA9, 0xAE => 737,
        0xAB, 0xBB => 556,
        0xB7 => 278,
        0xDF => 611, // sharp s
        0xC6 => 1000,
        0xE6 => 889,
        else => if (baseLetter(b)) |base| charWidth(base, font) else 556,
    };
}

/// An accented Latin-1 letter is as wide as its base letter in these fonts.
fn baseLetter(b: u8) ?u8 {
    return switch (b) {
        0xC0...0xC5 => 'A',
        0xC7 => 'C',
        0xC8...0xCB => 'E',
        0xCC...0xCF => 'I',
        0xD0 => 'D',
        0xD1 => 'N',
        0xD2...0xD6, 0xD8 => 'O',
        0xD9...0xDC => 'U',
        0xDD => 'Y',
        0xE0...0xE5 => 'a',
        0xE7 => 'c',
        0xE8...0xEB => 'e',
        0xEC...0xEF => 'i',
        0xF1 => 'n',
        0xF2...0xF6, 0xF8 => 'o',
        0xF9...0xFC => 'u',
        0xFD, 0xFF => 'y',
        0x8A => 'S',
        0x9A => 's',
        0x8E => 'Z',
        0x9E => 'z',
        0x9F => 'Y',
        else => null,
    };
}

// Helvetica and Helvetica-Bold, characters 32 to 126 (the AFM files).
// The oblique faces have the same widths.
const helvetica = [_]u16{
    278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, // 32-47
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, // 48-63
    1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, // 64-79
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, // 80-95
    333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, // 96-111
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584, // 112-126
};

const helvetica_bold = [_]u16{
    278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, // 32-47
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, // 48-63
    975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, // 64-79
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, // 80-95
    333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, // 96-111
    611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584, // 112-126
};

const t = std.testing;

fn encoded(text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try encode(t.allocator, &out, text);
    return out.toOwnedSlice(t.allocator);
}

test "encode keeps ASCII and maps Latin-1 letters to one byte each" {
    const e = try encoded("Olá, ação!");
    defer t.allocator.free(e);
    try t.expectEqualSlices(u8, "Ol\xe1, a\xe7\xe3o!", e);
}

test "encode maps quotes, dashes, the bullet and the euro to WinAnsi" {
    const e = try encoded("\u{201C}a\u{201D} \u{2013} \u{2014} \u{2022} \u{20AC}");
    defer t.allocator.free(e);
    try t.expectEqualSlices(u8, "\x93a\x94 \x96 \x97 \x95 \x80", e);
}

test "encode writes ? for characters WinAnsi lacks and for bad UTF-8" {
    const e = try encoded("a\u{4E2D}b\xffc\xe2");
    defer t.allocator.free(e);
    try t.expectEqualSlices(u8, "a?b?c?", e);
}

test "encode turns a tab into a space and keeps line breaks" {
    const e = try encoded("a\tb\nc\r");
    defer t.allocator.free(e);
    try t.expectEqualSlices(u8, "a b\nc?", e);
}

test "widths are the AFM ones" {
    // "Hi" in Helvetica: H 722 + i 222.
    try t.expectApproxEqAbs(@as(f32, 9.44), width("Hi", .helvetica, 10), 0.001);
    // Bold i is wider: 722 + 278.
    try t.expectApproxEqAbs(@as(f32, 10.0), width("Hi", .helvetica_bold, 10), 0.001);
    // Oblique shares the regular widths; Courier is monospaced.
    try t.expectEqual(width("Hi", .helvetica, 10), width("Hi", .helvetica_oblique, 10));
    try t.expectApproxEqAbs(@as(f32, 12.0), width("Hi", .courier, 10), 0.001);
}

test "an accented letter is as wide as its base letter" {
    try t.expectEqual(charWidth('a', .helvetica), charWidth(0xE1, .helvetica));
    try t.expectEqual(charWidth('C', .helvetica_bold), charWidth(0xC7, .helvetica_bold));
}

test "widthUtf8 counts characters, not bytes" {
    try t.expectEqual(width("a\xe7a", .helvetica, 12), widthUtf8("aça", .helvetica, 12));
}
