//! Decoding stream data: what is needed to read the structure of a PDF
//! (cross-reference streams and object streams) and to copy page contents
//! that must be joined.
//!
//! FlateDecode (zlib, and raw deflate as written by some broken tools),
//! with the PNG and TIFF predictors cross-reference streams use;
//! ASCIIHexDecode; ASCII85Decode. Image filters (DCT, JPX, JBIG2, CCITT)
//! are never decoded here: images are copied as they are.

const std = @import("std");
const syntax = @import("syntax.zig");

pub const Error = error{
    /// A filter this reader does not decode.
    UnsupportedFilter,
    /// The data does not decode with its filter.
    InvalidPdf,
    OutOfMemory,
};

/// Nothing decodes to more than this: a few kilobytes of deflate can claim
/// gigabytes.
pub const max_decoded: usize = 256 << 20;

/// The decoded data of `stream`, allocated in `arena` (or the data itself
/// when it has no filter).
pub fn decode(arena: std.mem.Allocator, stream: syntax.Stream) Error![]const u8 {
    const filter = stream.dict.get("Filter") orelse return stream.data;
    const parms = stream.dict.get("DecodeParms") orelse stream.dict.get("DP");
    var data = stream.data;
    switch (filter) {
        .name => |n| data = try apply(arena, n, data, parmsDict(parms, 0)),
        .array => |names| for (names, 0..) |f, i| {
            if (f != .name) return Error.InvalidPdf;
            data = try apply(arena, f.name, data, parmsDict(parms, i));
        },
        else => return Error.InvalidPdf,
    }
    return data;
}

fn parmsDict(parms: ?syntax.Object, i: usize) ?syntax.Dict {
    const p = parms orelse return null;
    return switch (p) {
        .dict => |d| if (i == 0) d else null,
        .array => |a| if (i < a.len and a[i] == .dict) a[i].dict else null,
        else => null,
    };
}

fn apply(arena: std.mem.Allocator, name: []const u8, data: []const u8, parms: ?syntax.Dict) Error![]const u8 {
    if (std.mem.eql(u8, name, "FlateDecode") or std.mem.eql(u8, name, "Fl")) {
        const raw = try inflate(arena, data);
        return predict(arena, raw, parms);
    }
    if (std.mem.eql(u8, name, "ASCIIHexDecode") or std.mem.eql(u8, name, "AHx")) return asciiHex(arena, data);
    if (std.mem.eql(u8, name, "ASCII85Decode") or std.mem.eql(u8, name, "A85")) return ascii85(arena, data);
    return Error.UnsupportedFilter;
}

/// zlib first; raw deflate when the zlib header is missing.
pub fn inflate(arena: std.mem.Allocator, data: []const u8) Error![]u8 {
    return inflateAs(arena, data, .zlib) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => inflateAs(arena, data, .raw) catch |e2| switch (e2) {
            error.OutOfMemory => error.OutOfMemory,
            else => Error.InvalidPdf,
        },
    };
}

fn inflateAs(arena: std.mem.Allocator, data: []const u8, container: std.compress.flate.Container) ![]u8 {
    var reader = std.Io.Reader.fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d = std.compress.flate.Decompress.init(&reader, container, &window);
    return d.reader.allocRemaining(arena, .limited(max_decoded));
}

fn intParm(parms: ?syntax.Dict, key: []const u8, default: i64) i64 {
    const d = parms orelse return default;
    const v = d.get(key) orelse return default;
    return if (v == .integer) v.integer else default;
}

/// Undoes the predictor of Flate-encoded data (cross-reference streams use
/// PNG "Up" with 4 or 5 columns).
fn predict(arena: std.mem.Allocator, data: []u8, parms: ?syntax.Dict) Error![]const u8 {
    const predictor = intParm(parms, "Predictor", 1);
    if (predictor == 1) return data;
    const colors = intParm(parms, "Colors", 1);
    const bpc = intParm(parms, "BitsPerComponent", 8);
    const columns = intParm(parms, "Columns", 1);
    if (colors < 1 or colors > 32 or columns < 1 or columns > 1 << 20) return Error.InvalidPdf;
    if (bpc != 1 and bpc != 2 and bpc != 4 and bpc != 8 and bpc != 16) return Error.InvalidPdf;
    const bpp: usize = @max(1, @as(usize, @intCast(colors * bpc)) / 8);
    const row_len: usize = (@as(usize, @intCast(colors * bpc * columns)) + 7) / 8;

    if (predictor == 2) {
        if (bpc != 8) return Error.UnsupportedFilter;
        var i: usize = 0;
        while (i + row_len <= data.len) : (i += row_len) {
            const row = data[i .. i + row_len];
            for (bpp..row.len) |j| row[j] +%= row[j - bpp];
        }
        return data;
    }
    if (predictor < 10) return Error.UnsupportedFilter;

    // PNG: each row starts with its filter type.
    const rows = data.len / (row_len + 1);
    const out = try arena.alloc(u8, rows * row_len);
    var prev = try arena.alloc(u8, row_len);
    @memset(prev, 0);
    for (0..rows) |r| {
        const kind = data[r * (row_len + 1)];
        const src = data[r * (row_len + 1) + 1 ..][0..row_len];
        const row = out[r * row_len ..][0..row_len];
        for (row, 0..) |*b, j| {
            const left: u8 = if (j >= bpp) row[j - bpp] else 0;
            const up = prev[j];
            const up_left: u8 = if (j >= bpp) prev[j - bpp] else 0;
            b.* = src[j] +% switch (kind) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @as(u8, @intCast((@as(u16, left) + up) / 2)),
                4 => paeth(left, up, up_left),
                else => return Error.InvalidPdf,
            };
        }
        prev = row;
    }
    return out;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

fn asciiHex(arena: std.mem.Allocator, data: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var high: ?u8 = null;
    for (data) |c| {
        if (c == '>') break;
        if (syntax.isWhitespace(c)) continue;
        const v = std.fmt.charToDigit(c, 16) catch return Error.InvalidPdf;
        if (high) |h| {
            try out.append(arena, h * 16 + v);
            high = null;
        } else high = v;
    }
    if (high) |h| try out.append(arena, h * 16);
    return out.items;
}

fn ascii85(arena: std.mem.Allocator, data: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var group: [5]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    if (std.mem.startsWith(u8, data, "<~")) i = 2;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c == '~') break;
        if (syntax.isWhitespace(c)) continue;
        if (c == 'z' and n == 0) {
            try out.appendSlice(arena, &.{ 0, 0, 0, 0 });
            continue;
        }
        if (c < '!' or c > 'u') return Error.InvalidPdf;
        group[n] = c - '!';
        n += 1;
        if (n == 5) {
            try out.appendSlice(arena, &groupBytes(group));
            n = 0;
        }
    }
    if (n == 1) return Error.InvalidPdf;
    if (n > 1) {
        // A short last group is padded with 'u' and cut back.
        for (n..5) |j| group[j] = 'u' - '!';
        const b = groupBytes(group);
        try out.appendSlice(arena, b[0 .. n - 1]);
    }
    return out.items;
}

fn groupBytes(g: [5]u8) [4]u8 {
    var v: u64 = 0;
    for (g) |d| v = v * 85 + d;
    const x: u32 = @truncate(v);
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, x, .big);
    return b;
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn zlib(allocator: std.mem.Allocator, data: []const u8, container: std.compress.flate.Container) ![]u8 {
    // The compressor wants room for its header in the output buffer.
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, 64);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&out.writer, &window, container, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

fn dictOf(arena: std.mem.Allocator, src: []const u8) !syntax.Dict {
    var p = syntax.Parser.init(arena, src, 0);
    return (try p.object()).dict;
}

test "Flate, in zlib and raw deflate" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]std.compress.flate.Container{ .zlib, .raw }) |container| {
        const z = try zlib(a, "BT /F1 12 Tf (Hi) Tj ET", container);
        const d = try decode(a, .{ .dict = try dictOf(a, "<< /Filter /FlateDecode >>"), .data = z });
        try t.expectEqualStrings("BT /F1 12 Tf (Hi) Tj ET", d);
    }
}

test "the PNG Up predictor of cross-reference streams" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two rows of 3 columns, both with filter 2 (Up): {1,2,3}, {1,2,3}+{1,1,1}.
    const z = try zlib(a, &.{ 2, 1, 2, 3, 2, 1, 1, 1 }, .zlib);
    const d = try decode(a, .{ .dict = try dictOf(a, "<< /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 3 >> >>"), .data = z });
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 2, 3, 4 }, d);
}

test "filter chains, ASCIIHex and ASCII85" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("Hi!", try decode(a, .{ .dict = try dictOf(a, "<< /Filter /ASCIIHexDecode >>"), .data = "48 69 21>" }));
    // "Man " in ASCII85 is "9jqo^"; "z" is four zero bytes; a short group.
    try t.expectEqualSlices(u8, "Man \x00\x00\x00\x00Ma", try decode(a, .{ .dict = try dictOf(a, "<< /Filter /A85 >>"), .data = "<~9jqo^z9jn~>" }));
    // ASCIIHex of a Flate stream.
    const z = try zlib(a, "chained", .zlib);
    var hex: std.ArrayList(u8) = .empty;
    for (z) |b| try hex.print(a, "{X:0>2}", .{b});
    try t.expectEqualStrings("chained", try decode(a, .{ .dict = try dictOf(a, "<< /Filter [/ASCIIHexDecode /FlateDecode] >>"), .data = hex.items }));
}

test "unknown filters and broken data are refused by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(Error.UnsupportedFilter, decode(a, .{ .dict = try dictOf(a, "<< /Filter /DCTDecode >>"), .data = "x" }));
    try t.expectError(Error.InvalidPdf, decode(a, .{ .dict = try dictOf(a, "<< /Filter /FlateDecode >>"), .data = "not deflate" }));
    try t.expectEqualStrings("plain", try decode(a, .{ .dict = .{}, .data = "plain" }));
}
