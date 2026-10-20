//! Images for the PDF: PNG and JPEG, made ready to embed.
//!
//! JPEG goes in as it is: PDF readers decode it themselves (`DCTDecode`),
//! so only its header is read here (size and color model). PNG is decoded
//! (the inflate is in `std`; what is left is undoing the per-row filters
//! and the color formats) and its pixels compressed again with `FlateDecode`.
//! A PNG with transparency keeps it: the alpha channel becomes a soft mask,
//! so a logo with a transparent background sits on whatever is under it.
//!
//! Refused with a named error instead of drawing garbage: interlaced PNGs
//! and PNGs with 16 bits per channel (no logo exporter writes those by
//! default), and images larger than `max_side` pixels on a side, which an
//! uploaded file could claim in its header to make the decoder allocate
//! gigabytes before finding out the data is not there.

const std = @import("std");

pub const Error = error{
    UnknownImageFormat,
    InvalidImage,
    ImageTooLarge,
    InterlacedPngNotSupported,
    PngBitDepthNotSupported,
    PngColorTypeNotSupported,
};

/// The largest width or height accepted, in pixels.
pub const max_side: u32 = 10_000;

pub const ColorSpace = enum {
    gray,
    rgb,
    cmyk,

    /// The PDF name of the color space.
    pub fn pdfName(self: ColorSpace) []const u8 {
        return switch (self) {
            .gray => "/DeviceGray",
            .rgb => "/DeviceRGB",
            .cmyk => "/DeviceCMYK",
        };
    }
};

pub const Filter = enum { flate, dct };

/// An image ready to be written as a PDF image object.
pub const Encoded = struct {
    width: u32,
    height: u32,
    color_space: ColorSpace,
    filter: Filter,
    /// The pixel data as the PDF stores it: a JPEG file, or zlib-compressed
    /// samples, 8 bits each, row by row from the top.
    data: []const u8,
    /// zlib-compressed alpha samples (8 bits, one per pixel), when the image
    /// has transparency.
    alpha: ?[]const u8 = null,
    /// An Adobe CMYK JPEG stores its values inverted: the PDF needs a
    /// `/Decode` array to read them right.
    inverted_cmyk: bool = false,
};

/// Reads a PNG or JPEG file. The result's buffers are allocated with
/// `allocator`, except a JPEG's data, which is `bytes` itself.
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !Encoded {
    if (std.mem.startsWith(u8, bytes, &png_signature)) return loadPng(allocator, bytes);
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return loadJpeg(bytes);
    return Error.UnknownImageFormat;
}

// ── JPEG ────────────────────────────────────────────────────────────────

/// Reads a JPEG's header: size and number of color components.
pub fn loadJpeg(bytes: []const u8) !Encoded {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return Error.InvalidImage;
    var adobe = false;
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF) return Error.InvalidImage;
        const marker = bytes[i + 1];
        if (marker == 0xFF) { // fill byte
            i += 1;
            continue;
        }
        // Markers without a length.
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) {
            i += 2;
            continue;
        }
        const len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (len < 2 or i + 2 + len > bytes.len) return Error.InvalidImage;
        const seg = bytes[i + 4 .. i + 2 + len];

        if (marker == 0xEE and std.mem.startsWith(u8, seg, "Adobe")) adobe = true;
        const is_sof = marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
        if (is_sof) {
            if (seg.len < 6) return Error.InvalidImage;
            const height = std.mem.readInt(u16, seg[1..3], .big);
            const width = std.mem.readInt(u16, seg[3..5], .big);
            if (width == 0 or height == 0) return Error.InvalidImage;
            if (width > max_side or height > max_side) return Error.ImageTooLarge;
            const space: ColorSpace = switch (seg[5]) {
                1 => .gray,
                3 => .rgb,
                4 => .cmyk,
                else => return Error.InvalidImage,
            };
            // The Adobe marker comes before the frame in practice; look ahead
            // in case it does not.
            if (!adobe) adobe = std.mem.indexOf(u8, bytes[i..@min(bytes.len, i + 4096)], "Adobe") != null;
            return .{
                .width = width,
                .height = height,
                .color_space = space,
                .filter = .dct,
                .data = bytes,
                .inverted_cmyk = space == .cmyk and adobe,
            };
        }
        if (marker == 0xDA) break; // scan data, no frame header before it
        i += 2 + len;
    }
    return Error.InvalidImage;
}

// ── PNG ─────────────────────────────────────────────────────────────────

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    palette = 3,
    gray_alpha = 4,
    rgba = 6,

    fn bytesPerPixel(self: ColorType) usize {
        return switch (self) {
            .gray, .palette => 1,
            .gray_alpha => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

/// Decodes a PNG and compresses its pixels (and alpha) for the PDF.
pub fn loadPng(allocator: std.mem.Allocator, bytes: []const u8) !Encoded {
    const img = try decodePng(allocator, bytes);
    defer allocator.free(img.pixels);
    defer if (img.alpha) |a| allocator.free(a);
    const data = try zlibCompress(allocator, img.pixels);
    errdefer allocator.free(data);
    const alpha = if (img.alpha) |a| try zlibCompress(allocator, a) else null;
    return .{
        .width = img.width,
        .height = img.height,
        .color_space = img.color_space,
        .filter = .flate,
        .data = data,
        .alpha = alpha,
    };
}

/// A decoded PNG: 8-bit samples, gray or RGB, plus alpha when any pixel is
/// not fully opaque.
pub const Decoded = struct {
    width: u32,
    height: u32,
    color_space: ColorSpace,
    pixels: []u8,
    alpha: ?[]u8,
};

pub fn decodePng(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (!std.mem.startsWith(u8, bytes, &png_signature)) return Error.UnknownImageFormat;

    var width: u32 = 0;
    var height: u32 = 0;
    var color_type: ColorType = .rgb;
    var palette: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);

    var i: usize = png_signature.len;
    while (i + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const name = bytes[i + 4 .. i + 8];
        const start = i + 8;
        if (len > bytes.len or start + len + 4 > bytes.len) return Error.InvalidImage;
        const data = bytes[start .. start + len];

        if (std.mem.eql(u8, name, "IHDR")) {
            if (len < 13) return Error.InvalidImage;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (width == 0 or height == 0) return Error.InvalidImage;
            if (width > max_side or height > max_side) return Error.ImageTooLarge;
            if (data[8] != 8) return Error.PngBitDepthNotSupported;
            color_type = std.enums.fromInt(ColorType, data[9]) orelse return Error.PngColorTypeNotSupported;
            if (data[12] != 0) return Error.InterlacedPngNotSupported;
        } else if (std.mem.eql(u8, name, "PLTE")) {
            palette = data;
        } else if (std.mem.eql(u8, name, "tRNS")) {
            trns = data;
        } else if (std.mem.eql(u8, name, "IDAT")) {
            // The image data may be split over several IDAT chunks: it is one
            // zlib stream.
            try compressed.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, name, "IEND")) {
            break;
        }
        i = start + len + 4; // skip the CRC
    }
    if (width == 0 or compressed.items.len == 0) return Error.InvalidImage;
    if (color_type == .palette and palette.len < 3) return Error.InvalidImage;

    const bpp = color_type.bytesPerPixel();
    const row_len = @as(usize, width) * bpp;
    const raw_len = (row_len + 1) * height;

    const raw = try zlibDecompress(allocator, compressed.items, raw_len);
    defer allocator.free(raw);
    if (raw.len < raw_len) return Error.InvalidImage;

    const out_space: ColorSpace = switch (color_type) {
        .gray, .gray_alpha => .gray,
        else => .rgb,
    };
    const channels: usize = if (out_space == .gray) 1 else 3;
    const pixel_count = @as(usize, width) * height;
    const pixels = try allocator.alloc(u8, pixel_count * channels);
    errdefer allocator.free(pixels);
    const alpha = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(alpha);
    var opaque_everywhere = true;

    const zeros = try allocator.alloc(u8, row_len);
    defer allocator.free(zeros);
    @memset(zeros, 0);
    var previous: []const u8 = zeros;

    for (0..height) |y| {
        const base = y * (row_len + 1);
        const row = raw[base + 1 .. base + 1 + row_len];
        try unfilter(raw[base], row, previous, bpp);
        for (0..width) |x| {
            const p = x * bpp;
            const n = y * width + x;
            const o = n * channels;
            var a: u8 = 255;
            switch (color_type) {
                .gray => pixels[o] = row[p],
                .gray_alpha => {
                    pixels[o] = row[p];
                    a = row[p + 1];
                },
                .rgb => @memcpy(pixels[o .. o + 3], row[p .. p + 3]),
                .rgba => {
                    @memcpy(pixels[o .. o + 3], row[p .. p + 3]);
                    a = row[p + 3];
                },
                .palette => {
                    const idx = @as(usize, row[p]);
                    if (idx * 3 + 2 >= palette.len) return Error.InvalidImage;
                    @memcpy(pixels[o .. o + 3], palette[idx * 3 .. idx * 3 + 3]);
                    if (idx < trns.len) a = trns[idx];
                },
            }
            alpha[n] = a;
            if (a != 255) opaque_everywhere = false;
        }
        previous = row;
    }

    if (opaque_everywhere) {
        allocator.free(alpha);
        return .{ .width = width, .height = height, .color_space = out_space, .pixels = pixels, .alpha = null };
    }
    return .{ .width = width, .height = height, .color_space = out_space, .pixels = pixels, .alpha = alpha };
}

/// Undoes one row's PNG filter. Skipping it, or getting the order wrong,
/// gives an image of noise, which is still a valid image: nothing would
/// report the error, so the filters are tested one by one.
fn unfilter(kind: u8, row: []u8, previous: []const u8, bpp: usize) !void {
    switch (kind) {
        0 => {},
        1 => for (row, 0..) |*b, i| {
            if (i >= bpp) b.* +%= row[i - bpp];
        },
        2 => for (row, 0..) |*b, i| {
            b.* +%= previous[i];
        },
        3 => for (row, 0..) |*b, i| {
            const left: u16 = if (i >= bpp) row[i - bpp] else 0;
            b.* +%= @intCast((left + previous[i]) / 2);
        },
        4 => for (row, 0..) |*b, i| {
            const a: i32 = if (i >= bpp) row[i - bpp] else 0;
            const c: i32 = previous[i];
            const d: i32 = if (i >= bpp) previous[i - bpp] else 0;
            b.* +%= @intCast(paeth(a, c, d));
        },
        else => return Error.InvalidImage,
    }
}

fn paeth(a: i32, b: i32, c: i32) i32 {
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

// ── zlib ────────────────────────────────────────────────────────────────

/// zlib-compresses `data` (the PDF `FlateDecode` format).
pub fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, data.len / 2 + 64);
    errdefer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&out.writer, &window, .zlib, .default);
    try c.writer.writeAll(data);
    try c.finish();
    return out.toOwnedSlice();
}

/// Inflates a zlib stream. More than `limit` bytes is refused
/// (`error.InvalidImage`): a small file that inflates to gigabytes never
/// gets the memory.
pub fn zlibDecompress(allocator: std.mem.Allocator, data: []const u8, limit: usize) ![]u8 {
    var reader = std.Io.Reader.fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var d = std.compress.flate.Decompress.init(&reader, .zlib, &window);
    return d.reader.allocRemaining(allocator, .limited(limit)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => Error.InvalidImage,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

/// Builds a real PNG: `rows` are the filtered rows (filter byte first).
fn testPng(allocator: std.mem.Allocator, width: u32, height: u32, color_type: u8, rows: []const u8, extra: []const [2][]const u8) ![]u8 {
    const comp = try zlibCompress(allocator, rows);
    defer allocator.free(comp);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, &png_signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = color_type;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(allocator, &out, "IHDR", &ihdr);
    for (extra) |e| try chunk(allocator, &out, e[0], e[1]);
    try chunk(allocator, &out, "IDAT", comp);
    try chunk(allocator, &out, "IEND", "");
    return out.toOwnedSlice(allocator);
}

fn chunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(allocator, &len);
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, data);
    try out.appendSlice(allocator, &.{ 0, 0, 0, 0 }); // CRC, not checked
}

test "an RGB PNG decodes to its pixels, with no alpha" {
    const png = try testPng(t.allocator, 2, 1, 2, &.{ 0, 10, 20, 30, 40, 50, 60 }, &.{});
    defer t.allocator.free(png);
    const img = try decodePng(t.allocator, png);
    defer t.allocator.free(img.pixels);
    try t.expectEqual(@as(u32, 2), img.width);
    try t.expectEqual(ColorSpace.rgb, img.color_space);
    try t.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, img.pixels);
    try t.expect(img.alpha == null);
}

test "an RGBA PNG keeps its alpha apart" {
    const png = try testPng(t.allocator, 2, 1, 6, &.{ 0, 1, 2, 3, 255, 4, 5, 6, 0 }, &.{});
    defer t.allocator.free(png);
    const img = try decodePng(t.allocator, png);
    defer t.allocator.free(img.pixels);
    defer t.allocator.free(img.alpha.?);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, img.pixels);
    try t.expectEqualSlices(u8, &.{ 255, 0 }, img.alpha.?);
}

test "an RGBA PNG that is opaque everywhere gets no alpha" {
    const png = try testPng(t.allocator, 1, 1, 6, &.{ 0, 1, 2, 3, 255 }, &.{});
    defer t.allocator.free(png);
    const img = try decodePng(t.allocator, png);
    defer t.allocator.free(img.pixels);
    try t.expect(img.alpha == null);
}

test "gray and gray+alpha PNGs stay gray" {
    const png = try testPng(t.allocator, 2, 1, 4, &.{ 0, 100, 255, 200, 128 }, &.{});
    defer t.allocator.free(png);
    const img = try decodePng(t.allocator, png);
    defer t.allocator.free(img.pixels);
    defer t.allocator.free(img.alpha.?);
    try t.expectEqual(ColorSpace.gray, img.color_space);
    try t.expectEqualSlices(u8, &.{ 100, 200 }, img.pixels);
    try t.expectEqualSlices(u8, &.{ 255, 128 }, img.alpha.?);
}

test "a palette PNG looks its colors up, and tRNS gives them alpha" {
    const plte = &[_]u8{ 255, 0, 0, 0, 0, 255 };
    const trns = &[_]u8{ 255, 0 };
    const png = try testPng(t.allocator, 2, 1, 3, &.{ 0, 1, 0 }, &.{ .{ "PLTE", plte }, .{ "tRNS", trns } });
    defer t.allocator.free(png);
    const img = try decodePng(t.allocator, png);
    defer t.allocator.free(img.pixels);
    defer t.allocator.free(img.alpha.?);
    try t.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 0 }, img.pixels);
    try t.expectEqualSlices(u8, &.{ 0, 255 }, img.alpha.?);
}

test "each PNG row filter is undone" {
    // Two gray rows of two pixels. Row 2 is written with filter `kind`
    // against row 1 = {10, 20}; every case must give {30, 50}.
    const cases = [_]struct { kind: u8, row: [2]u8 }{
        .{ .kind = 0, .row = .{ 30, 50 } },
        .{ .kind = 1, .row = .{ 30, 20 } }, // sub: 50 - 30
        .{ .kind = 2, .row = .{ 20, 30 } }, // up: 30-10, 50-20
        .{ .kind = 3, .row = .{ 25, 50 - (30 + 20) / 2 } }, // average
        .{ .kind = 4, .row = .{ 20, 20 } }, // paeth: up for x=0 (10), left 30/up 20/ul 10 → p=40 → closest 30
    };
    for (cases) |c| {
        const rows = [_]u8{ 0, 10, 20, c.kind, c.row[0], c.row[1] };
        const png = try testPng(t.allocator, 2, 2, 0, &rows, &.{});
        defer t.allocator.free(png);
        const img = try decodePng(t.allocator, png);
        defer t.allocator.free(img.pixels);
        try t.expectEqualSlices(u8, &.{ 10, 20, 30, 50 }, img.pixels);
    }
}

test "PNGs this decoder does not handle are refused by name" {
    var png = try testPng(t.allocator, 2, 2, 2, &.{ 0, 1, 2, 3, 4, 5, 6, 0, 1, 2, 3, 4, 5, 6 }, &.{});
    defer t.allocator.free(png);
    png[8 + 8 + 12] = 1; // interlace
    try t.expectError(Error.InterlacedPngNotSupported, decodePng(t.allocator, png));
    png[8 + 8 + 12] = 0;
    png[8 + 8 + 8] = 16; // bit depth
    try t.expectError(Error.PngBitDepthNotSupported, decodePng(t.allocator, png));
    png[8 + 8 + 8] = 8;
    std.mem.writeInt(u32, png[16..20], 100_000, .big); // width
    try t.expectError(Error.ImageTooLarge, decodePng(t.allocator, png));
}

test "truncated and foreign files are refused" {
    try t.expectError(Error.UnknownImageFormat, load(t.allocator, "not an image"));
    try t.expectError(Error.InvalidImage, decodePng(t.allocator, &png_signature));
    try t.expectError(Error.InvalidImage, loadJpeg(&.{ 0xFF, 0xD8, 0xFF, 0xD9 }));
}

/// A JPEG header: SOI, an APP14 Adobe segment when asked, SOF0.
fn testJpeg(components: u8, adobe: bool) [32]u8 {
    var b: [32]u8 = @splat(0);
    var n: usize = 0;
    for ([_]u8{ 0xFF, 0xD8 }) |x| {
        b[n] = x;
        n += 1;
    }
    if (adobe) {
        for ([_]u8{ 0xFF, 0xEE, 0, 7, 'A', 'd', 'o', 'b', 'e' }) |x| {
            b[n] = x;
            n += 1;
        }
    }
    // SOF0: length 11, precision 8, height 300, width 400, components.
    for ([_]u8{ 0xFF, 0xC0, 0, 11, 8, 0x01, 0x2C, 0x01, 0x90, components, 1, 0x11, 0 }) |x| {
        b[n] = x;
        n += 1;
    }
    return b;
}

test "a JPEG's size and color model come from its frame header" {
    const rgb = testJpeg(3, false);
    const img = try load(t.allocator, &rgb);
    try t.expectEqual(@as(u32, 400), img.width);
    try t.expectEqual(@as(u32, 300), img.height);
    try t.expectEqual(ColorSpace.rgb, img.color_space);
    try t.expectEqual(Filter.dct, img.filter);
    try t.expectEqual(@as([*]const u8, &rgb), img.data.ptr); // embedded as it is

    const gray = testJpeg(1, false);
    try t.expectEqual(ColorSpace.gray, (try loadJpeg(&gray)).color_space);
}

test "an Adobe CMYK JPEG is marked inverted" {
    const plain = testJpeg(4, false);
    try t.expect(!(try loadJpeg(&plain)).inverted_cmyk);
    const adobe = testJpeg(4, true);
    const img = try loadJpeg(&adobe);
    try t.expectEqual(ColorSpace.cmyk, img.color_space);
    try t.expect(img.inverted_cmyk);
}

test "zlib round trip" {
    const data = "PDF streams are zlib streams";
    const c = try zlibCompress(t.allocator, data);
    defer t.allocator.free(c);
    const d = try zlibDecompress(t.allocator, c, 1000);
    defer t.allocator.free(d);
    try t.expectEqualStrings(data, d);
}

test "a zlib stream larger than the limit is refused" {
    const zeros: [4096]u8 = @splat(0);
    const c = try zlibCompress(t.allocator, &zeros);
    defer t.allocator.free(c);
    try t.expectError(Error.InvalidImage, zlibDecompress(t.allocator, c, 100));
}
