//! Breaking text into lines that fit a width.
//!
//! Text is first turned into a `Run`: one code per character (a WinAnsi
//! byte for the standard fonts, a glyph number for an embedded font), its
//! width, and the character itself. Lines break at spaces; a `\n` always
//! starts a new line; a word wider than the whole line is cut between
//! characters rather than spilling out of the box. A line is a range of
//! the run.

const std = @import("std");

/// Encoded text: three arrays of the same length.
pub const Run = struct {
    /// What the PDF writes for each character.
    codes: []const u16,
    /// Each character's width, in thousandths of the font size.
    widths: []const u16,
    /// The characters themselves.
    cps: []const u21,
    /// Kerning after each character (before the next one), in thousandths
    /// of the font size; empty when the font has none.
    kerns: []const i16 = &.{},

    /// The width of `codes[start..end]` in points at `size`, with the
    /// kerning between its characters.
    pub fn width(self: Run, start: usize, end: usize, size: f32) f32 {
        var units: i32 = 0;
        for (self.widths[start..end]) |w| units += w;
        if (self.kerns.len > 0 and end > start) {
            for (self.kerns[start .. end - 1]) |k| units += k;
        }
        return @as(f32, @floatFromInt(units)) / 1000.0 * size;
    }
};

/// A line: the range `start..end` of a run.
pub const Line = struct { start: usize, end: usize };

/// The lines of `run` that fit `max_width` points at `size`, allocated with
/// `allocator`. Spaces at a break are dropped. Empty text gives no lines;
/// an empty line between two `\n` stays (as an empty range).
pub fn wrap(allocator: std.mem.Allocator, run: Run, max_width: f32, size: f32) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);
    if (run.cps.len == 0) return lines.toOwnedSlice(allocator);

    var para_start: usize = 0;
    for (run.cps, 0..) |cp, i| {
        if (cp == '\n') {
            try wrapParagraph(allocator, &lines, run, para_start, i, max_width, size);
            para_start = i + 1;
        }
    }
    try wrapParagraph(allocator, &lines, run, para_start, run.cps.len, max_width, size);
    return lines.toOwnedSlice(allocator);
}

fn wrapParagraph(allocator: std.mem.Allocator, lines: *std.ArrayList(Line), run: Run, from: usize, to: usize, max_width: f32, size: f32) !void {
    // The current line is run[line_start..line_end]; null while empty.
    var line_start: ?usize = null;
    var line_end: usize = 0;

    var i = from;
    while (i < to) {
        if (run.cps[i] == ' ') {
            i += 1;
            continue;
        }
        const word_start = i;
        while (i < to and run.cps[i] != ' ') : (i += 1) {}
        const word_end = i;

        if (line_start) |ls| {
            if (run.width(ls, word_end, size) <= max_width) {
                line_end = word_end;
                continue;
            }
            try lines.append(allocator, .{ .start = ls, .end = line_end });
        }
        // The word starts a line: cut it first if it is wider than one.
        line_start = try cutWord(allocator, lines, run, word_start, word_end, max_width, size);
        line_end = word_end;
    }
    if (line_start) |ls| {
        try lines.append(allocator, .{ .start = ls, .end = line_end });
    } else {
        try lines.append(allocator, .{ .start = from, .end = from });
    }
}

/// Emits the full-width pieces of an overlong word and returns where its
/// last piece (which stays on the current line) starts.
fn cutWord(allocator: std.mem.Allocator, lines: *std.ArrayList(Line), run: Run, from: usize, to: usize, max_width: f32, size: f32) !usize {
    var piece_start = from;
    var w: f32 = 0;
    for (from..to) |j| {
        const cw = @as(f32, @floatFromInt(run.widths[j])) / 1000.0 * size;
        if (w + cw > max_width and j > piece_start) {
            try lines.append(allocator, .{ .start = piece_start, .end = j });
            piece_start = j;
            w = 0;
        }
        w += cw;
    }
    return piece_start;
}

const t = std.testing;

/// A run of ASCII text where every character is 600 thousandths wide
/// (Courier): at 10 points, 6 points a character.
fn monospace(allocator: std.mem.Allocator, str: []const u8) !Run {
    const codes = try allocator.alloc(u16, str.len);
    const widths = try allocator.alloc(u16, str.len);
    const cps = try allocator.alloc(u21, str.len);
    for (str, 0..) |c, i| {
        codes[i] = c;
        widths[i] = if (c == '\n') 0 else 600;
        cps[i] = c;
    }
    return .{ .codes = codes, .widths = widths, .cps = cps };
}

fn expectLines(expected: []const []const u8, str: []const u8, max_width: f32) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const run = try monospace(arena.allocator(), str);
    const lines = try wrap(arena.allocator(), run, max_width, 10);
    if (lines.len != expected.len) {
        std.debug.print("got {d} lines:\n", .{lines.len});
        for (lines) |l| std.debug.print("  [{s}]\n", .{str[l.start..l.end]});
    }
    try t.expectEqual(expected.len, lines.len);
    for (expected, lines) |e, l| try t.expectEqualStrings(e, str[l.start..l.end]);
}

test "text that fits stays on one line" {
    try expectLines(&.{"hello world"}, "hello world", 66);
}

test "lines break at spaces and drop the space" {
    try expectLines(&.{ "hello", "world" }, "hello world", 60);
    try expectLines(&.{ "one two", "three four", "five" }, "one two three four five", 60);
}

test "a newline always starts a line, and an empty line stays" {
    try expectLines(&.{ "a", "", "b" }, "a\n\nb", 600);
}

test "a word wider than the line is cut between characters" {
    try expectLines(&.{ "abcde", "fghij", "kl" }, "abcdefghijkl", 30);
    try expectLines(&.{ "go", "abcde", "fghij" }, "go abcdefghij", 30);
}

test "repeated spaces at a break do not start the next line" {
    try expectLines(&.{ "hello", "world" }, "hello     world", 60);
}

test "empty text has no lines" {
    try expectLines(&.{}, "", 100);
}

test "kerning counts in a line's width, but not after its last character" {
    const run: Run = .{ .codes = &.{ 1, 2, 3 }, .widths = &.{ 500, 500, 500 }, .cps = &.{ 'A', 'V', 'A' }, .kerns = &.{ -100, -50, -999 } };
    try t.expectApproxEqAbs(@as(f32, 13.5), run.width(0, 3, 10), 0.001); // (1500 - 150) thousandths of 10
    try t.expectApproxEqAbs(@as(f32, 5), run.width(2, 3, 10), 0.001);
}

test "a line is never wider than the box" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const run = try monospace(arena.allocator(), "The quick brown fox jumps over the lazy dog, again and again, until the page ends.");
    const lines = try wrap(arena.allocator(), run, 90, 11);
    try t.expect(lines.len > 1);
    for (lines) |l| try t.expect(run.width(l.start, l.end, 11) <= 90);
}
