//! Reading a PDF file into its objects.
//!
//! The cross-reference data says where each object is: a classic `xref`
//! table or a cross-reference stream (PDF 1.5), possibly several of them
//! chained by `/Prev` when the file was saved incrementally (the newest
//! entry of an object wins), and objects packed in object streams. Every
//! object is then read, so the file is not needed afterwards except for
//! the bytes the objects point into.
//!
//! When the cross-reference data is missing or wrong, as in files cut short
//! or edited by hand, the file is scanned for `N G obj` and the objects are
//! read from where they really are, the way PDF readers repair a file.
//!
//! Encrypted files are refused (`error.EncryptedPdf`).

const std = @import("std");
const syntax = @import("syntax.zig");
const filters = @import("filters.zig");

const Object = syntax.Object;
const Dict = syntax.Dict;
const Ref = syntax.Ref;

pub const Error = error{
    /// Not a PDF, or damaged beyond repair.
    InvalidPdf,
    /// The file is encrypted (password protected, or with permissions).
    EncryptedPdf,
    UnsupportedFilter,
    OutOfMemory,
};

/// The largest object number accepted: a file claiming more would make
/// the object table take gigabytes.
const max_objects = 10_000_000;

const XrefEntry = union(enum) {
    free,
    /// At this byte offset in the file.
    offset: usize,
    /// The `index`-th object of the object stream `stream`.
    compressed: struct { stream: u32, index: u32 },
};

/// The objects of a PDF file, by object number.
pub const File = struct {
    /// Object `n` is `objects[n]`, null when the file does not have it.
    objects: []?Object,
    trailer: Dict,
    /// The file was repaired: its cross-reference data could not be used.
    repaired: bool = false,

    pub fn get(self: *const File, num: u32) ?Object {
        if (num >= self.objects.len) return null;
        return self.objects[num];
    }

    /// Follows a reference (once, or a chain of them); other objects come
    /// back as they are. A reference to a missing object is null.
    pub fn resolve(self: *const File, obj: Object) Object {
        var o = obj;
        var hops: usize = 0;
        while (o == .ref and hops < 32) : (hops += 1) o = self.get(o.ref.num) orelse return .null;
        return o;
    }
};

/// Reads every object of `data`, in `arena`. Strings and stream data
/// point into `data` or the arena: both must outlive the result.
pub fn load(arena: std.mem.Allocator, data: []const u8) Error!File {
    // A missing "%PDF-" header is tolerated, as readers do: the objects
    // decide whether this is a PDF.

    var xref: std.AutoHashMap(u32, XrefEntry) = .init(arena);
    var trailer: ?Dict = null;
    var repaired = false;
    if (readXrefChain(arena, data, &xref)) |tr| {
        trailer = tr;
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {},
    }

    var file: File = undefined;
    if (trailer) |tr| {
        if (readObjects(arena, data, &xref, tr)) |f| {
            file = f;
        } else |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EncryptedPdf => return error.EncryptedPdf,
            else => trailer = null,
        }
    }
    if (trailer == null) {
        file = try reconstruct(arena, data);
        repaired = true;
    }
    if (file.trailer.get("Encrypt") != null) return Error.EncryptedPdf;
    if (file.resolve(file.trailer.get("Root") orelse return Error.InvalidPdf) != .dict) return Error.InvalidPdf;
    file.repaired = repaired;
    return file;
}

fn findStartxref(data: []const u8) Error!usize {
    const tail_start = data.len -| 2048;
    const at = std.mem.lastIndexOf(u8, data[tail_start..], "startxref") orelse return Error.InvalidPdf;
    var p = syntax.Parser.init(undefined, data, tail_start + at + "startxref".len);
    const off = try p.unsigned();
    if (off >= data.len) return Error.InvalidPdf;
    return @intCast(off);
}

/// Walks the cross-reference sections from the newest; returns the newest
/// trailer, with the entries of all sections merged (newest first wins).
fn readXrefChain(arena: std.mem.Allocator, data: []const u8, xref: *std.AutoHashMap(u32, XrefEntry)) Error!Dict {
    var offset: ?usize = try findStartxref(data);
    var newest: ?Dict = null;
    var seen: std.AutoHashMap(usize, void) = .init(arena);
    while (offset) |off| {
        if (try seen.fetchPut(off, {}) != null) break; // a /Prev loop
        if (seen.count() > 1024) return Error.InvalidPdf;
        const tr = try readXrefSection(arena, data, off, xref);
        if (newest == null) newest = tr;
        // A hybrid file: a classic table with a stream for the newer entries.
        if (tr.get("XRefStm")) |s| {
            if (s == .integer and s.integer >= 0 and s.integer < data.len) _ = try readXrefSection(arena, data, @intCast(s.integer), xref);
        }
        offset = null;
        if (tr.get("Prev")) |prev| {
            if (prev == .integer and prev.integer >= 0 and prev.integer < data.len) offset = @intCast(prev.integer);
        }
    }
    return newest orelse Error.InvalidPdf;
}

fn readXrefSection(arena: std.mem.Allocator, data: []const u8, offset: usize, xref: *std.AutoHashMap(u32, XrefEntry)) Error!Dict {
    var p = syntax.Parser.init(arena, data, offset);
    p.skipWhitespace();
    if (std.mem.startsWith(u8, data[p.pos..], "xref")) {
        _ = p.keyword();
        while (true) {
            const save = p.pos;
            if (p.keyword()) |k| {
                if (std.mem.eql(u8, k, "trailer")) break;
                return Error.InvalidPdf;
            }
            p.pos = save;
            const first = try p.unsigned();
            const count = try p.unsigned();
            if (count > 10_000_000 or first + count > std.math.maxInt(u32)) return Error.InvalidPdf;
            for (0..count) |i| {
                const off = try p.unsigned();
                _ = try p.unsigned(); // generation
                const kind = p.keyword() orelse return Error.InvalidPdf;
                const num: u32 = @intCast(first + i);
                if (xref.contains(num)) continue;
                if (std.mem.eql(u8, kind, "n")) {
                    try xref.put(num, if (off == 0) .free else .{ .offset = @intCast(off) });
                } else {
                    try xref.put(num, .free);
                }
            }
        }
        const tr = try p.object();
        return if (tr == .dict) tr.dict else Error.InvalidPdf;
    }

    // A cross-reference stream.
    const ind = try p.indirect();
    if (ind.object != .stream) return Error.InvalidPdf;
    const s = ind.object.stream;
    if (!s.dict.hasName("Type", "XRef")) return Error.InvalidPdf;
    const decoded = try filters.decode(arena, s);
    const w = s.dict.get("W") orelse return Error.InvalidPdf;
    if (w != .array or w.array.len != 3) return Error.InvalidPdf;
    var widths: [3]usize = undefined;
    for (w.array, 0..) |x, i| {
        if (x != .integer or x.integer < 0 or x.integer > 8) return Error.InvalidPdf;
        widths[i] = @intCast(x.integer);
    }
    const row = widths[0] + widths[1] + widths[2];
    if (row == 0) return Error.InvalidPdf;
    const size = (s.dict.get("Size") orelse return Error.InvalidPdf);
    if (size != .integer or size.integer < 0) return Error.InvalidPdf;
    var index_buf = [_]Object{ .{ .integer = 0 }, size };
    const index: []const Object = if (s.dict.get("Index")) |ix| (if (ix == .array) ix.array else return Error.InvalidPdf) else &index_buf;
    if (index.len % 2 != 0) return Error.InvalidPdf;

    var pos: usize = 0;
    var i: usize = 0;
    while (i < index.len) : (i += 2) {
        if (index[i] != .integer or index[i + 1] != .integer) return Error.InvalidPdf;
        const first = index[i].integer;
        const count = index[i + 1].integer;
        if (first < 0 or count < 0 or first + count > std.math.maxInt(u32)) return Error.InvalidPdf;
        for (0..@intCast(count)) |n| {
            if (pos + row > decoded.len) return Error.InvalidPdf;
            const f0 = if (widths[0] == 0) 1 else field(decoded[pos..][0..widths[0]]);
            const f1 = field(decoded[pos + widths[0] ..][0..widths[1]]);
            const f2 = field(decoded[pos + widths[0] + widths[1] ..][0..widths[2]]);
            pos += row;
            const num: u32 = @intCast(@as(u64, @intCast(first)) + n);
            if (xref.contains(num)) continue;
            const entry: XrefEntry = switch (f0) {
                1 => if (f1 < data.len) .{ .offset = @intCast(f1) } else .free,
                2 => if (f1 <= std.math.maxInt(u32) and f2 <= std.math.maxInt(u32)) .{ .compressed = .{ .stream = @intCast(f1), .index = @intCast(f2) } } else .free,
                else => .free,
            };
            try xref.put(num, entry);
        }
    }
    return s.dict;
}

fn field(bytes: []const u8) u64 {
    var v: u64 = 0;
    for (bytes) |b| v = (v << 8) | b;
    return v;
}

const LoadContext = struct {
    arena: std.mem.Allocator,
    data: []const u8,
    xref: *std.AutoHashMap(u32, XrefEntry),

    /// A stream's /Length given as a reference: the integer at that object.
    fn length(ctx_ptr: *anyopaque, ref: Ref) ?i64 {
        const ctx: *LoadContext = @ptrCast(@alignCast(ctx_ptr));
        const entry = ctx.xref.get(ref.num) orelse return null;
        if (entry != .offset) return null;
        var p = syntax.Parser.init(ctx.arena, ctx.data, entry.offset);
        const r = p.indirect() catch return null;
        return if (r.object == .integer) r.object.integer else null;
    }
};

fn readObjects(arena: std.mem.Allocator, data: []const u8, xref: *std.AutoHashMap(u32, XrefEntry), trailer: Dict) Error!File {
    if (trailer.get("Encrypt") != null) return Error.EncryptedPdf;
    var max: u32 = 0;
    var it = xref.keyIterator();
    while (it.next()) |k| max = @max(max, k.*);
    if (trailer.get("Size")) |s| {
        if (s == .integer and s.integer > 0 and s.integer <= max_objects) max = @max(max, @as(u32, @intCast(s.integer - 1)));
    }
    if (max > max_objects) return Error.InvalidPdf;
    const objects = try arena.alloc(?Object, @as(usize, max) + 1);
    @memset(objects, null);

    var ctx: LoadContext = .{ .arena = arena, .data = data, .xref = xref };
    var streams: std.AutoHashMap(u32, ObjStm) = .init(arena);

    var entries = xref.iterator();
    while (entries.next()) |e| {
        switch (e.value_ptr.*) {
            .free => {},
            .offset => |off| {
                var p = syntax.Parser.init(arena, data, off);
                p.lengths = .{ .ctx = &ctx, .resolve = LoadContext.length };
                const r = try p.indirect();
                // An offset pointing at another object means a stale table.
                if (r.ref.num != e.key_ptr.*) return Error.InvalidPdf;
                objects[r.ref.num] = r.object;
            },
            .compressed => {},
        }
    }
    entries = xref.iterator();
    while (entries.next()) |e| {
        switch (e.value_ptr.*) {
            .compressed => |c| {
                const stm = try objectStream(arena, objects, &streams, c.stream);
                objects[e.key_ptr.*] = try stm.objectFor(arena, e.key_ptr.*, c.index);
            },
            else => {},
        }
    }
    return .{ .objects = objects, .trailer = trailer };
}

/// A decoded object stream: `/N` objects after a header of number/offset
/// pairs.
const ObjStm = struct {
    data: []const u8,
    first: usize,
    nums: []u32,
    offsets: []usize,

    /// Object `num`, expected at `index`. The header's number decides when
    /// the two disagree: the index field of a cross-reference stream can be
    /// too narrow and wrap around in streams of many objects.
    fn objectFor(self: ObjStm, arena: std.mem.Allocator, num: u32, index: u32) Error!Object {
        if (index < self.nums.len and self.nums[index] == num) return self.objectAt(arena, index);
        for (self.nums, 0..) |n, i| {
            if (n == num) return self.objectAt(arena, @intCast(i));
        }
        return self.objectAt(arena, index);
    }

    fn objectAt(self: ObjStm, arena: std.mem.Allocator, index: u32) Error!Object {
        if (index >= self.offsets.len) return Error.InvalidPdf;
        const at = self.first + self.offsets[index];
        if (at > self.data.len) return Error.InvalidPdf;
        var p = syntax.Parser.init(arena, self.data, at);
        return p.object();
    }
};

fn objectStream(arena: std.mem.Allocator, objects: []?Object, cache: *std.AutoHashMap(u32, ObjStm), num: u32) Error!ObjStm {
    if (cache.get(num)) |s| return s;
    if (num >= objects.len) return Error.InvalidPdf;
    const obj = objects[num] orelse return Error.InvalidPdf;
    if (obj != .stream) return Error.InvalidPdf;
    const n = obj.stream.dict.get("N") orelse return Error.InvalidPdf;
    const first = obj.stream.dict.get("First") orelse return Error.InvalidPdf;
    if (n != .integer or first != .integer or n.integer < 0 or n.integer > 1_000_000 or first.integer < 0) return Error.InvalidPdf;
    const data = try filters.decode(arena, obj.stream);
    var p = syntax.Parser.init(arena, data, 0);
    const offsets = try arena.alloc(usize, @intCast(n.integer));
    const nums = try arena.alloc(u32, @intCast(n.integer));
    for (offsets, nums) |*o, *num_out| {
        const objnum = try p.unsigned();
        num_out.* = if (objnum <= std.math.maxInt(u32)) @intCast(objnum) else 0;
        o.* = @intCast(try p.unsigned());
    }
    const stm: ObjStm = .{ .data = data, .first = @intCast(first.integer), .nums = nums, .offsets = offsets };
    try cache.put(num, stm);
    return stm;
}

/// Rebuilds the objects of a file whose cross-reference data cannot be
/// used: every `N G obj` found in the file (the last of a number wins, as
/// later updates come later), then the objects of the object streams found,
/// and a trailer from the last `trailer` dictionary or cross-reference
/// stream, or one made up around the document catalog.
fn reconstruct(arena: std.mem.Allocator, data: []const u8) Error!File {
    var found: std.AutoHashMap(u32, Object) = .init(arena);
    var max: u32 = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, "obj")) |at| {
        i = at + 3;
        if (at + 3 < data.len and syntax.isRegular(data[at + 3])) continue; // "objects", "obj1"...
        // Back over "N G " before "obj".
        var s = at;
        var fields: usize = 0;
        while (fields < 2) : (fields += 1) {
            while (s > 0 and syntax.isWhitespace(data[s - 1])) s -= 1;
            const end = s;
            while (s > 0 and std.ascii.isDigit(data[s - 1])) s -= 1;
            if (s == end) break;
        }
        if (fields < 2) continue;
        if (s > 0 and syntax.isRegular(data[s - 1])) continue;
        var p = syntax.Parser.init(arena, data, s);
        const r = p.indirect() catch continue;
        if (r.ref.num > max_objects) continue; // an impossibly large number
        try found.put(r.ref.num, r.object);
        max = @max(max, r.ref.num);
        i = p.pos;
    }
    if (found.count() == 0) return Error.InvalidPdf;

    const objects = try arena.alloc(?Object, @as(usize, max) + 1);
    @memset(objects, null);
    var it = found.iterator();
    while (it.next()) |e| objects[e.key_ptr.*] = e.value_ptr.*;

    // Objects packed in object streams (they have no "obj" of their own).
    var streams: std.AutoHashMap(u32, ObjStm) = .init(arena);
    var trailer: ?Dict = null;
    for (objects, 0..) |o, num| {
        const obj = o orelse continue;
        if (obj != .stream) continue;
        const ty = obj.stream.dict.get("Type") orelse continue;
        if (ty.isName("XRef") and obj.stream.dict.get("Root") != null) trailer = obj.stream.dict;
        if (!ty.isName("ObjStm")) continue;
        const stm = objectStream(arena, objects, &streams, @intCast(num)) catch continue;
        for (stm.nums, 0..) |objnum, k| {
            if (objnum >= objects.len or objects[objnum] != null) continue;
            objects[objnum] = stm.objectAt(arena, @intCast(k)) catch continue;
        }
    }

    if (std.mem.lastIndexOf(u8, data, "trailer")) |at| {
        var p = syntax.Parser.init(arena, data, at + "trailer".len);
        if (p.object()) |tr| {
            if (tr == .dict and tr.dict.get("Root") != null) trailer = tr.dict;
        } else |_| {}
    }
    var tr = trailer orelse Dict{};
    const root_ok = if (tr.get("Root")) |r| r == .ref and r.ref.num < objects.len and objects[r.ref.num] != null else false;
    if (!root_ok) {
        // No usable trailer: find the catalog.
        for (objects, 0..) |o, num| {
            const d = (o orelse continue).dictionary() orelse continue;
            if (d.hasName("Type", "Catalog")) {
                tr = .{};
                try tr.put(arena, "Root", .{ .ref = .{ .num = @intCast(num) } });
                break;
            }
        } else return Error.InvalidPdf;
    }
    return .{ .objects = objects, .trailer = tr, .repaired = true };
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

/// Builds a PDF from object bodies, with a correct classic xref table:
/// object i+1 is bodies[i].
fn classicPdf(allocator: std.mem.Allocator, bodies: []const []const u8, trailer_extra: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "%PDF-1.4\n");
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(allocator);
    for (bodies, 1..) |b, n| {
        try offsets.append(allocator, out.items.len);
        try out.print(allocator, "{d} 0 obj\n{s}\nendobj\n", .{ n, b });
    }
    const xref = out.items.len;
    try out.print(allocator, "xref\n0 {d}\n0000000000 65535 f \n", .{bodies.len + 1});
    for (offsets.items) |o| try out.print(allocator, "{d:0>10} 00000 n \n", .{o});
    try out.print(allocator, "trailer\n<< /Size {d} /Root 1 0 R {s}>>\nstartxref\n{d}\n%%EOF\n", .{ bodies.len + 1, trailer_extra, xref });
    return out.toOwnedSlice(allocator);
}

const minimal = [_][]const u8{
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R >>",
    "<< /Length 4 0 R >>\nstream\nBT ET\nendstream",
};

test "a classic xref table, with a stream whose Length is a reference" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var bodies = minimal;
    bodies[3] = "<< /Length 5 0 R >>\nstream\nBT ET\nendstream";
    const all = bodies ++ [_][]const u8{"5"};
    const pdf = try classicPdf(arena.allocator(), &all, "");
    const f = try load(arena.allocator(), pdf);
    try t.expect(!f.repaired);
    try t.expect(f.get(1).?.dict.get("Type").?.isName("Catalog"));
    try t.expectEqualStrings("BT ET", f.get(4).?.stream.data);
    try t.expectEqual(@as(i64, 5), f.get(5).?.integer);
}

test "an incremental update: the newer section wins, the older still counts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try classicPdf(a, &minimal, "");
    const first_xref = std.mem.lastIndexOf(u8, base, "\nxref\n").? + 1;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, base);
    const new_obj = out.items.len;
    try out.appendSlice(a, "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Contents 4 0 R >>\nendobj\n");
    const xref2 = out.items.len;
    try out.print(a, "xref\n3 1\n{d:0>10} 00000 n \ntrailer\n<< /Size 5 /Root 1 0 R /Prev {d} >>\nstartxref\n{d}\n%%EOF\n", .{ new_obj, first_xref, xref2 });
    const f = try load(a, out.items);
    try t.expect(!f.repaired);
    const box = f.get(3).?.dict.get("MediaBox").?.array;
    try t.expectEqual(@as(i64, 300), box[2].integer);
    try t.expect(f.get(2) != null); // from the older section
}

test "a cross-reference stream with a PNG predictor, and an object stream" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "%PDF-1.5\n");
    // Objects 2 and 3 live in object stream 4.
    const pages_obj = "<< /Type /Pages /Kids [3 0 R] /Count 1 >> ";
    const header = std.fmt.comptimePrint("2 0 3 {d} ", .{pages_obj.len});
    const objstm_body = header ++ pages_obj ++ "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 10 10] >>";
    const header_len = header.len;
    const off1 = out.items.len;
    try out.appendSlice(a, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
    const off4 = out.items.len;
    try out.print(a, "4 0 obj\n<< /Type /ObjStm /N 2 /First {d} /Length {d} >>\nstream\n{s}\nendstream\nendobj\n", .{ header_len, objstm_body.len, objstm_body });
    // The xref stream (object 5): W [1 2 1], rows for objects 0..5, PNG Up.
    const off5 = out.items.len;
    const rows = [_][4]u8{
        .{ 0, 0, 0, 0 },
        .{ 1, @intCast(off1 >> 8), @truncate(off1), 0 },
        .{ 2, 0, 4, 0 },
        .{ 2, 0, 4, 1 },
        .{ 1, @intCast(off4 >> 8), @truncate(off4), 0 },
        .{ 1, @intCast(off5 >> 8), @truncate(off5), 0 },
    };
    var raw: std.ArrayList(u8) = .empty;
    var prev: [4]u8 = @splat(0);
    for (rows) |r| {
        try raw.append(a, 2); // Up
        for (r, prev) |b, p| try raw.append(a, b -% p);
        prev = r;
    }
    var z = try std.Io.Writer.Allocating.initCapacity(a, 64);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&z.writer, &window, .zlib, .default);
    try c.writer.writeAll(raw.items);
    try c.finish();
    try out.print(a, "5 0 obj\n<< /Type /XRef /Size 6 /W [1 2 1] /Root 1 0 R /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 4 >> /Length {d} >>\nstream\n", .{z.written().len});
    try out.appendSlice(a, z.written());
    try out.print(a, "\nendstream\nendobj\nstartxref\n{d}\n%%EOF\n", .{off5});

    const f = try load(a, out.items);
    try t.expect(!f.repaired);
    try t.expect(f.get(2).?.dict.get("Type").?.isName("Pages"));
    try t.expect(f.get(3).?.dict.get("Type").?.isName("Page"));
    try t.expect(f.resolve(f.trailer.get("Root").?) == .dict);
}

test "a file with a broken xref is repaired by scanning for objects" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try classicPdf(a, &minimal, "");
    // Shift every object by inserting junk after the header: the table is stale.
    const broken = try std.mem.concat(a, u8, &.{ good[0..9], "% junk junk junk\n", good[9..] });
    const f = try load(a, broken);
    try t.expect(f.repaired);
    try t.expect(f.get(3).?.dict.get("Type").?.isName("Page"));

    // No xref or trailer at all: the catalog is found by its type.
    const cut = good[0..std.mem.indexOf(u8, good, "xref\n").?];
    const g = try load(a, cut);
    try t.expect(g.repaired);
    try t.expectEqual(@as(u32, 1), g.trailer.get("Root").?.ref.num);
}

test "an object stream entry whose index wrapped is found by its number" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = syntax.Parser.init(a, "<< /Type /ObjStm /N 2 /First 8 /Length 13 >>", 0);
    const d = (try p.object()).dict;
    var objects = [_]?Object{ null, null, null, null, null, null, null, null, null, null };
    objects[9] = .{ .stream = .{ .dict = d, .data = "5 0 6 2 11 22" } };
    var cache: std.AutoHashMap(u32, ObjStm) = .init(a);
    const stm = try objectStream(a, &objects, &cache, 9);
    // Object 6 is at index 1 although the entry said 0.
    try t.expectEqual(@as(i64, 22), (try stm.objectFor(a, 6, 0)).integer);
    try t.expectEqual(@as(i64, 11), (try stm.objectFor(a, 5, 0)).integer);
}

test "a file without its %PDF- header, and an impossibly large object number" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try classicPdf(a, &minimal, "");
    const f = try load(a, good[9..]);
    try t.expect(f.get(3) != null);
    const huge = try std.mem.concat(a, u8, &.{ good[0..std.mem.indexOf(u8, good, "xref\n").?], "2147483647 0 obj << /Root 1 0 R >> endobj\n" });
    const g = try load(a, huge);
    try t.expect(g.objects.len < 100);
}

test "encrypted files and non-PDFs are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const enc = try classicPdf(a, &minimal, "/Encrypt << /Filter /Standard >> ");
    try t.expectError(Error.EncryptedPdf, load(a, enc));
    try t.expectError(Error.InvalidPdf, load(a, "hello"));
    try t.expectError(Error.InvalidPdf, load(a, "%PDF-1.4\nnothing here\n"));
    try t.expectError(Error.InvalidPdf, load(a, ""));
}

test "resolve follows references and gives null for missing objects" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const pdf = try classicPdf(arena.allocator(), &minimal, "");
    const f = try load(arena.allocator(), pdf);
    try t.expect(f.resolve(.{ .ref = .{ .num = 2 } }) == .dict);
    try t.expect(f.resolve(.{ .ref = .{ .num = 99 } }) == .null);
    try t.expectEqual(@as(i64, 7), f.resolve(.{ .integer = 7 }).integer);
}
