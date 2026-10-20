//! Breaking text into lines that fit a width.
//!
//! Works on WinAnsi bytes (see fonts.zig), where one byte is one
//! character, so a line is a slice of the encoded text. Lines break at
//! spaces; a `\n` always starts a new line; a word wider than the whole
//! line is cut between characters rather than spilling out of the box.

const std = @import("std");
const fonts = @import("fonts.zig");

/// The lines of `text` (WinAnsi) that fit `max_width` points in `font` at
/// `size`. The slices point into `text`; the list is allocated with
/// `allocator`. Spaces at a break are dropped. Empty text gives no lines;
/// an empty line between two `\n` stays (as an empty slice).
pub fn wrap(allocator: std.mem.Allocator, text: []const u8, max_width: f32, font: fonts.Font, size: f32) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    if (text.len == 0) return lines.toOwnedSlice(allocator);

    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |para| {
        try wrapParagraph(allocator, &lines, para, max_width, font, size);
    }
    return lines.toOwnedSlice(allocator);
}

fn wrapParagraph(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), para: []const u8, max_width: f32, font: fonts.Font, size: f32) !void {
    // The current line is para[line_start..line_end]; null while empty.
    var line_start: ?usize = null;
    var line_end: usize = 0;

    var i: usize = 0;
    while (i < para.len) {
        if (para[i] == ' ') {
            i += 1;
            continue;
        }
        const word_start = i;
        while (i < para.len and para[i] != ' ') : (i += 1) {}
        const word_end = i;

        if (line_start) |ls| {
            if (fonts.width(para[ls..word_end], font, size) <= max_width) {
                line_end = word_end;
                continue;
            }
            try lines.append(allocator, para[ls..line_end]);
        }
        // The word starts a line: cut it first if it is wider than one.
        line_start = try cutWord(allocator, lines, para, word_start, word_end, max_width, font, size);
        line_end = word_end;
    }
    if (line_start) |ls| {
        try lines.append(allocator, para[ls..line_end]);
    } else {
        try lines.append(allocator, "");
    }
}

/// Emits the full-width pieces of an overlong word and returns where its
/// last piece (which stays on the current line) starts.
fn cutWord(allocator: std.mem.Allocator, lines: *std.ArrayList([]const u8), para: []const u8, from: usize, to: usize, max_width: f32, font: fonts.Font, size: f32) !usize {
    var piece_start = from;
    var w: f32 = 0;
    var j = from;
    while (j < to) : (j += 1) {
        const cw = @as(f32, @floatFromInt(fonts.charWidth(para[j], font))) / 1000.0 * size;
        if (w + cw > max_width and j > piece_start) {
            try lines.append(allocator, para[piece_start..j]);
            piece_start = j;
            w = 0;
        }
        w += cw;
    }
    return piece_start;
}

const t = std.testing;

fn expectLines(expected: []const []const u8, text: []const u8, max_width: f32) !void {
    const lines = try wrap(t.allocator, text, max_width, .courier, 10);
    defer t.allocator.free(lines);
    if (lines.len != expected.len) {
        std.debug.print("got {d} lines:\n", .{lines.len});
        for (lines) |l| std.debug.print("  [{s}]\n", .{l});
    }
    try t.expectEqual(expected.len, lines.len);
    for (expected, lines) |e, l| try t.expectEqualStrings(e, l);
}

// Courier at 10 pt: every character is 6 points wide.

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

test "a line is never wider than the box" {
    const text = "The quick brown fox jumps over the lazy dog, again and again, until the page ends.";
    const lines = try wrap(t.allocator, text, 90, .helvetica, 11);
    defer t.allocator.free(lines);
    try t.expect(lines.len > 1);
    for (lines) |l| try t.expect(fonts.width(l, .helvetica, 11) <= 90);
}
