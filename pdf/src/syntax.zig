//! The PDF object syntax: the values a PDF file is made of, reading them
//! from bytes, and writing them back.
//!
//! Objects: null, booleans, integers, reals, strings, names, arrays,
//! dictionaries, streams and references to indirect objects (`12 0 R`).
//! Strings and names are kept decoded (escapes and `#xx` undone) and
//! encoded again when written. Everything read lives in the arena given to
//! the parser.
//!
//! The parser is lenient where real files are sloppy (comments anywhere,
//! any whitespace, a stream `/Length` that is wrong) and strict where a
//! mistake would make it read past the data: every position is checked,
//! and nesting is capped.

const std = @import("std");

pub const Error = error{
    /// The bytes are not a well-formed PDF object.
    InvalidPdf,
    OutOfMemory,
};

pub const Ref = struct {
    num: u32,
    gen: u16 = 0,
};

pub const Entry = struct { key: []const u8, value: Object };

/// A dictionary: keys (names, without the slash) and values, in file order.
pub const Dict = struct {
    entries: []Entry = &.{},

    /// The value of `key`, or null when absent.
    pub fn get(self: Dict, key: []const u8) ?Object {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    /// Whether `key` holds the name `name` (`/Type /Page`, say).
    pub fn hasName(self: Dict, key: []const u8, name: []const u8) bool {
        const v = self.get(key) orelse return false;
        return v.isName(name);
    }

    /// Sets `key` (replacing its value, or adding it).
    pub fn put(self: *Dict, arena: std.mem.Allocator, key: []const u8, value: Object) !void {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.key, key)) {
                e.value = value;
                return;
            }
        }
        const grown = try arena.alloc(Entry, self.entries.len + 1);
        @memcpy(grown[0..self.entries.len], self.entries);
        grown[self.entries.len] = .{ .key = try arena.dupe(u8, key), .value = value };
        self.entries = grown;
    }

    /// Removes `key` when present.
    pub fn remove(self: *Dict, key: []const u8) void {
        for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                std.mem.copyForwards(Entry, self.entries[i..], self.entries[i + 1 ..]);
                self.entries = self.entries[0 .. self.entries.len - 1];
                return;
            }
        }
    }

    /// A copy whose entries can be changed without touching this one.
    pub fn clone(self: Dict, arena: std.mem.Allocator) !Dict {
        return .{ .entries = try arena.dupe(Entry, self.entries) };
    }
};

pub const Stream = struct {
    dict: Dict,
    /// The data as stored in the file (still encoded by its /Filter).
    data: []const u8,
};

pub const Object = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    real: f64,
    /// The string's bytes, escapes undone.
    string: []const u8,
    /// The name without its slash, `#xx` escapes undone.
    name: []const u8,
    array: []Object,
    dict: Dict,
    stream: Stream,
    ref: Ref,

    /// The value as a number, for an integer or a real.
    pub fn number(self: Object) ?f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .real => |r| r,
            else => null,
        };
    }

    /// The dictionary of a dictionary or of a stream.
    pub fn dictionary(self: Object) ?Dict {
        return switch (self) {
            .dict => |d| d,
            .stream => |s| s.dict,
            else => null,
        };
    }

    pub fn isName(self: Object, name: []const u8) bool {
        return self == .name and std.mem.eql(u8, self.name, name);
    }
};

/// Reads the length of a stream whose /Length is an indirect object.
pub const LengthResolver = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, ref: Ref) ?i64,
};

const max_depth = 128;

pub const Parser = struct {
    data: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    depth: usize = 0,
    lengths: ?LengthResolver = null,

    pub fn init(arena: std.mem.Allocator, data: []const u8, pos: usize) Parser {
        return .{ .data = data, .pos = pos, .arena = arena };
    }

    pub fn atEnd(self: *Parser) bool {
        self.skipWhitespace();
        return self.pos >= self.data.len;
    }

    /// Skips whitespace and comments.
    pub fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isWhitespace(c)) {
                self.pos += 1;
            } else if (c == '%') {
                while (self.pos < self.data.len and self.data[self.pos] != '\n' and self.data[self.pos] != '\r') self.pos += 1;
            } else break;
        }
    }

    /// Reads a bare keyword (`obj`, `stream`, `trailer`, `R`...) when one
    /// comes next; returns null and stays put otherwise.
    pub fn keyword(self: *Parser) ?[]const u8 {
        self.skipWhitespace();
        const start = self.pos;
        var end = start;
        while (end < self.data.len and isRegular(self.data[end])) end += 1;
        if (end == start or !std.ascii.isAlphabetic(self.data[start])) return null;
        self.pos = end;
        return self.data[start..end];
    }

    /// Reads the keyword `want`, or fails.
    pub fn expectKeyword(self: *Parser, want: []const u8) Error!void {
        const k = self.keyword() orelse return Error.InvalidPdf;
        if (!std.mem.eql(u8, k, want)) return Error.InvalidPdf;
    }

    /// Reads an unsigned integer, or fails.
    pub fn unsigned(self: *Parser) Error!u64 {
        self.skipWhitespace();
        const start = self.pos;
        while (self.pos < self.data.len and std.ascii.isDigit(self.data[self.pos])) self.pos += 1;
        if (self.pos == start or self.pos - start > 15) return Error.InvalidPdf;
        return std.fmt.parseInt(u64, self.data[start..self.pos], 10) catch Error.InvalidPdf;
    }

    /// Reads one object. A number followed by a number and `R` is read as
    /// a reference.
    pub fn object(self: *Parser) Error!Object {
        self.skipWhitespace();
        if (self.pos >= self.data.len) return Error.InvalidPdf;
        if (self.depth >= max_depth) return Error.InvalidPdf;
        const c = self.data[self.pos];
        switch (c) {
            '/' => return .{ .name = try self.name() },
            '(' => return .{ .string = try self.literalString() },
            '[' => {
                self.pos += 1;
                self.depth += 1;
                defer self.depth -= 1;
                var items: std.ArrayList(Object) = .empty;
                while (true) {
                    self.skipWhitespace();
                    if (self.pos >= self.data.len) return Error.InvalidPdf;
                    if (self.data[self.pos] == ']') {
                        self.pos += 1;
                        break;
                    }
                    if (self.data[self.pos] == ')' or self.data[self.pos] == '}' or self.data[self.pos] == '{') {
                        self.pos += 1; // a stray delimiter
                        continue;
                    }
                    try items.append(self.arena, try self.object());
                }
                return .{ .array = items.items };
            },
            '<' => {
                if (self.pos + 1 < self.data.len and self.data[self.pos + 1] == '<') return .{ .dict = try self.dictionary() };
                return .{ .string = try self.hexString() };
            },
            '0'...'9', '+', '-', '.' => return self.numberOrRef(),
            else => {
                const k = self.keyword() orelse return Error.InvalidPdf;
                if (std.mem.eql(u8, k, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, k, "false")) return .{ .boolean = false };
                if (std.mem.eql(u8, k, "null")) return .null;
                return Error.InvalidPdf;
            },
        }
    }

    fn dictionary(self: *Parser) Error!Dict {
        self.pos += 2;
        self.depth += 1;
        defer self.depth -= 1;
        var entries: std.ArrayList(Entry) = .empty;
        while (true) {
            self.skipWhitespace();
            if (self.pos + 1 >= self.data.len) return Error.InvalidPdf;
            if (self.data[self.pos] == '>' and self.data[self.pos + 1] == '>') {
                self.pos += 2;
                break;
            }
            if (self.data[self.pos] != '/') {
                // Sloppy writers leave stray tokens where a key belongs
                // (`/Contents 5 0 R ) >>`): skip them, as readers do.
                switch (self.data[self.pos]) {
                    ')', '}', ']', '>', '{' => self.pos += 1,
                    else => _ = try self.object(),
                }
                continue;
            }
            const key = try self.name();
            const value = try self.object();
            // A key given twice: the last one wins, as readers do.
            for (entries.items) |*e| {
                if (std.mem.eql(u8, e.key, key)) {
                    e.value = value;
                    break;
                }
            } else try entries.append(self.arena, .{ .key = key, .value = value });
        }
        return .{ .entries = entries.items };
    }

    fn numberOrRef(self: *Parser) Error!Object {
        const start = self.pos;
        if (self.data[self.pos] == '+' or self.data[self.pos] == '-') self.pos += 1;
        var dot = false;
        while (self.pos < self.data.len) : (self.pos += 1) {
            const ch = self.data[self.pos];
            if (ch == '.') {
                if (dot) break;
                dot = true;
            } else if (!std.ascii.isDigit(ch)) break;
        }
        const text = self.data[start..self.pos];
        if (dot) {
            // "-.5", "4.": all valid; a lone "." or "-" is not.
            const v = std.fmt.parseFloat(f64, text) catch return Error.InvalidPdf;
            return .{ .real = v };
        }
        const v = std.fmt.parseInt(i64, text, 10) catch {
            // Integers too large for 64 bits: read as reals.
            const r = std.fmt.parseFloat(f64, text) catch return Error.InvalidPdf;
            return .{ .real = r };
        };
        // "12 0 R"?
        if (v >= 0 and text[0] != '+') {
            const save = self.pos;
            self.skipWhitespace();
            const gen_start = self.pos;
            while (self.pos < self.data.len and std.ascii.isDigit(self.data[self.pos])) self.pos += 1;
            if (self.pos > gen_start and self.pos - gen_start <= 5) {
                const gen = std.fmt.parseInt(u32, self.data[gen_start..self.pos], 10) catch 0x10000;
                self.skipWhitespace();
                if (gen <= 0xFFFF and v <= std.math.maxInt(u32) and self.pos < self.data.len and self.data[self.pos] == 'R' and
                    (self.pos + 1 >= self.data.len or !isRegular(self.data[self.pos + 1])))
                {
                    self.pos += 1;
                    return .{ .ref = .{ .num = @intCast(v), .gen = @intCast(gen) } };
                }
            }
            self.pos = save;
        }
        return .{ .integer = v };
    }

    fn name(self: *Parser) Error![]const u8 {
        self.pos += 1; // the slash
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < self.data.len and isRegular(self.data[self.pos])) {
            const ch = self.data[self.pos];
            if (ch == '#' and self.pos + 2 < self.data.len) {
                if (std.fmt.parseInt(u8, self.data[self.pos + 1 .. self.pos + 3], 16)) |b| {
                    try out.append(self.arena, b);
                    self.pos += 3;
                    continue;
                } else |_| {}
            }
            try out.append(self.arena, ch);
            self.pos += 1;
        }
        return out.items;
    }

    fn literalString(self: *Parser) Error![]const u8 {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        var nesting: usize = 0;
        while (true) {
            if (self.pos >= self.data.len) return Error.InvalidPdf;
            const ch = self.data[self.pos];
            self.pos += 1;
            switch (ch) {
                '(' => {
                    nesting += 1;
                    try out.append(self.arena, ch);
                },
                ')' => {
                    if (nesting == 0) break;
                    nesting -= 1;
                    try out.append(self.arena, ch);
                },
                '\\' => {
                    if (self.pos >= self.data.len) return Error.InvalidPdf;
                    const e = self.data[self.pos];
                    self.pos += 1;
                    switch (e) {
                        'n' => try out.append(self.arena, '\n'),
                        'r' => try out.append(self.arena, '\r'),
                        't' => try out.append(self.arena, '\t'),
                        'b' => try out.append(self.arena, 8),
                        'f' => try out.append(self.arena, 12),
                        '0'...'7' => {
                            var v: u32 = e - '0';
                            var n: usize = 1;
                            while (n < 3 and self.pos < self.data.len and self.data[self.pos] >= '0' and self.data[self.pos] <= '7') : (n += 1) {
                                v = v * 8 + (self.data[self.pos] - '0');
                                self.pos += 1;
                            }
                            try out.append(self.arena, @truncate(v));
                        },
                        '\r' => { // a line continuation
                            if (self.pos < self.data.len and self.data[self.pos] == '\n') self.pos += 1;
                        },
                        '\n' => {},
                        else => try out.append(self.arena, e), // \( \) \\ and unknown escapes
                    }
                },
                '\r' => { // an end of line inside a string is a \n
                    if (self.pos < self.data.len and self.data[self.pos] == '\n') self.pos += 1;
                    try out.append(self.arena, '\n');
                },
                else => try out.append(self.arena, ch),
            }
        }
        return out.items;
    }

    fn hexString(self: *Parser) Error![]const u8 {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        var high: ?u8 = null;
        while (true) {
            if (self.pos >= self.data.len) return Error.InvalidPdf;
            const ch = self.data[self.pos];
            self.pos += 1;
            if (ch == '>') break;
            if (isWhitespace(ch)) continue;
            const v = std.fmt.charToDigit(ch, 16) catch return Error.InvalidPdf;
            if (high) |h| {
                try out.append(self.arena, h * 16 + v);
                high = null;
            } else high = v;
        }
        if (high) |h| try out.append(self.arena, h * 16); // an odd digit count: pad with 0
        return out.items;
    }

    /// Reads `num gen obj <object> [stream] endobj` at the parser's position.
    /// A stream's data runs for its /Length; when that is missing or wrong
    /// (the bytes after it are not `endstream`), up to the next `endstream`.
    pub fn indirect(self: *Parser) Error!struct { ref: Ref, object: Object } {
        const num = try self.unsigned();
        const gen = try self.unsigned();
        if (num > std.math.maxInt(u32) or gen > 0xFFFF) return Error.InvalidPdf;
        try self.expectKeyword("obj");
        const obj = try self.object();
        const ref: Ref = .{ .num = @intCast(num), .gen = @intCast(gen) };
        if (obj != .dict) return .{ .ref = ref, .object = obj };

        const save = self.pos;
        const k = self.keyword();
        if (k == null or !std.mem.eql(u8, k.?, "stream")) {
            self.pos = save;
            return .{ .ref = ref, .object = obj };
        }
        // The data starts after the end of line that follows "stream".
        if (self.pos < self.data.len and self.data[self.pos] == '\r') self.pos += 1;
        if (self.pos < self.data.len and self.data[self.pos] == '\n') self.pos += 1;
        const start = self.pos;

        var length: ?usize = null;
        if (obj.dict.get("Length")) |l| switch (l) {
            .integer => |i| if (i >= 0) {
                length = @intCast(i);
            },
            .ref => |r| if (self.lengths) |res| {
                if (res.resolve(res.ctx, r)) |i| {
                    if (i >= 0) length = @intCast(i);
                }
            },
            else => {},
        };
        var end: usize = 0;
        if (length) |len| {
            if (start + len <= self.data.len and endsAtEndstream(self.data, start + len)) end = start + len;
        }
        if (end == 0) {
            const found = std.mem.indexOfPos(u8, self.data, start, "endstream") orelse return Error.InvalidPdf;
            end = found;
            // The end of line before "endstream" is not part of the data.
            if (end > start and self.data[end - 1] == '\n') end -= 1;
            if (end > start and self.data[end - 1] == '\r') end -= 1;
        }
        self.pos = end;
        _ = self.keyword(); // endstream
        return .{ .ref = ref, .object = .{ .stream = .{ .dict = obj.dict, .data = self.data[start..end] } } };
    }
};

fn endsAtEndstream(data: []const u8, at: usize) bool {
    var i = at;
    while (i < data.len and isWhitespace(data[i])) i += 1;
    return std.mem.startsWith(u8, data[i..], "endstream");
}

pub fn isWhitespace(c: u8) bool {
    return switch (c) {
        0, '\t', '\n', 12, '\r', ' ' => true,
        else => false,
    };
}

fn isDelimiter(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

/// Neither whitespace nor a delimiter: part of a name, number or keyword.
pub fn isRegular(c: u8) bool {
    return !isWhitespace(c) and !isDelimiter(c);
}

// ── Writing ─────────────────────────────────────────────────────────────

/// Writes `obj`; references go through `remap` (`fn (ctx, Ref) ?u32`):
/// the object's new number, or null to write `null` instead (an object
/// left out of the file). Streams are written by the caller: here they
/// give their dictionary only.
pub fn write(w: *std.Io.Writer, obj: Object, remap: anytype) std.Io.Writer.Error!void {
    switch (obj) {
        .null => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .real => |r| try writeReal(w, r),
        .string => |s| try writeString(w, s),
        .name => |n| try writeName(w, n),
        .array => |items| {
            try w.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try w.writeByte(' ');
                try write(w, item, remap);
            }
            try w.writeByte(']');
        },
        .dict => |d| try writeDict(w, d, remap),
        .stream => |s| try writeDict(w, s.dict, remap),
        .ref => |r| if (remap.map(r)) |n| try w.print("{d} 0 R", .{n}) else try w.writeAll("null"),
    }
}

pub fn writeDict(w: *std.Io.Writer, d: Dict, remap: anytype) std.Io.Writer.Error!void {
    try w.writeAll("<<");
    for (d.entries) |e| {
        try w.writeByte(' ');
        try writeName(w, e.key);
        try w.writeByte(' ');
        try write(w, e.value, remap);
    }
    try w.writeAll(" >>");
}

/// A real number without an exponent (PDF has none), trailing zeros cut.
fn writeReal(w: *std.Io.Writer, r: f64) !void {
    if (!std.math.isFinite(r)) return w.writeAll("0");
    if (r == @trunc(r) and @abs(r) < 1e15) return w.print("{d}", .{@as(i64, @intFromFloat(r))});
    var buf: [64]u8 = undefined;
    var s: []const u8 = std.fmt.bufPrint(&buf, "{d:.6}", .{r}) catch return w.writeAll("0");
    s = std.mem.trimEnd(u8, s, "0");
    s = std.mem.trimEnd(u8, s, ".");
    if (s.len == 0 or std.mem.eql(u8, s, "-")) return w.writeAll("0");
    try w.writeAll(s);
}

/// Printable ASCII as a literal string, anything else in hex.
fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |b| {
        if (b < 0x20 or b > 0x7E) break;
    } else {
        try w.writeByte('(');
        for (s) |b| {
            if (b == '(' or b == ')' or b == '\\') try w.writeByte('\\');
            try w.writeByte(b);
        }
        return w.writeByte(')');
    }
    try w.writeByte('<');
    for (s) |b| try w.print("{X:0>2}", .{b});
    try w.writeByte('>');
}

fn writeName(w: *std.Io.Writer, n: []const u8) !void {
    try w.writeByte('/');
    for (n) |b| {
        if (b < 0x21 or b > 0x7E or b == '#' or isDelimiter(b)) {
            try w.print("#{X:0>2}", .{b});
        } else try w.writeByte(b);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

fn parseOne(arena: std.mem.Allocator, src: []const u8) !Object {
    var p = Parser.init(arena, src, 0);
    return p.object();
}

test "numbers, booleans, null and references" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(i64, 42), (try parseOne(a, "42")).integer);
    try t.expectEqual(@as(i64, -7), (try parseOne(a, "-7")).integer);
    try t.expectEqual(@as(f64, -0.5), (try parseOne(a, "-.5")).real);
    try t.expectEqual(@as(f64, 4), (try parseOne(a, "4.")).real);
    try t.expect((try parseOne(a, "true")).boolean);
    try t.expect((try parseOne(a, "null")) == .null);
    try t.expectEqual(Ref{ .num = 12, .gen = 3 }, (try parseOne(a, "12 3 R")).ref);
    // Two numbers without R stay numbers.
    const arr = (try parseOne(a, "[1 2 3 0 R 4]")).array;
    try t.expectEqual(@as(usize, 4), arr.len);
    try t.expectEqual(@as(i64, 2), arr[1].integer);
    try t.expectEqual(Ref{ .num = 3 }, arr[2].ref);
    try t.expectError(Error.InvalidPdf, parseOne(a, "-"));
}

test "names undo #xx escapes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("A B#", (try parseOne(arena.allocator(), "/A#20B#23")).name);
}

test "literal strings: nesting, escapes, octal, line continuations" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("a (b) c", (try parseOne(a, "(a (b) c)")).string);
    try t.expectEqualStrings("x\ny)\\", (try parseOne(a, "(x\\ny\\)\\\\)")).string);
    try t.expectEqualStrings("\xe9A", (try parseOne(a, "(\\351\\101)")).string);
    try t.expectEqualStrings("onetwo", (try parseOne(a, "(one\\\ntwo)")).string);
    try t.expectEqualStrings("a\nb", (try parseOne(a, "(a\r\nb)")).string);
    try t.expectError(Error.InvalidPdf, parseOne(a, "(unterminated"));
}

test "hex strings ignore whitespace and pad an odd digit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualSlices(u8, &.{ 0xFE, 0xFF, 0x00, 0x41 }, (try parseOne(a, "<FEFF 0041>")).string);
    try t.expectEqualSlices(u8, &.{ 0xA0, 0x10 }, (try parseOne(a, "<A01>")).string);
}

test "dictionaries, comments, and the last of a repeated key" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const d = (try parseOne(arena.allocator(), "<< /Type /Page % a comment\n /Kids [1 0 R] /N 1 /N 2 >>")).dict;
    try t.expect(d.get("Type").?.isName("Page"));
    try t.expectEqual(@as(i64, 2), d.get("N").?.integer);
    try t.expect(d.get("Missing") == null);
}

test "stray tokens inside a dictionary or an array are skipped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = (try parseOne(a, "<< /Type /Page /Contents 82 0 R ) 7 >>")).dict;
    try t.expect(d.hasName("Type", "Page"));
    try t.expectEqual(@as(u32, 82), d.get("Contents").?.ref.num);
    try t.expectEqual(@as(usize, 2), d.entries.len);
    try t.expectEqual(@as(usize, 2), (try parseOne(a, "[1 ) 2]")).array.len);
}

test "an indirect stream uses its Length, or finds endstream when it is wrong" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, "7 0 obj\n<< /Length 5 >>\nstream\nhello\nendstream\nendobj", 0);
    const r = try p.indirect();
    try t.expectEqual(@as(u32, 7), r.ref.num);
    try t.expectEqualStrings("hello", r.object.stream.data);

    var wrong = Parser.init(a, "7 0 obj << /Length 99 >> stream\r\nhello world\r\nendstream endobj", 0);
    try t.expectEqualStrings("hello world", (try wrong.indirect()).object.stream.data);
}

test "nesting is capped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const deep: [1000]u8 = @splat('[');
    try t.expectError(Error.InvalidPdf, parseOne(arena.allocator(), &deep));
}

const Identity = struct {
    pub fn map(_: Identity, r: Ref) ?u32 {
        return r.num;
    }
};

test "writing gives back what was read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const src = "<< /Type /Page /Name /A#20B /S (a\\(b\\)) /H <00FF> /N [1 -2 0.5 3 0 R true null] >>";
    const obj = try parseOne(arena.allocator(), src);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try write(&out.writer, obj, Identity{});
    try t.expectEqualStrings(src, out.written());
}

test "reals are written without exponents" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    for ([_]f64{ 0.1, 1e-7, 12.5, -3, 1234567.125 }) |r| {
        try writeReal(&out.writer, r);
        try out.writer.writeByte(' ');
    }
    try t.expectEqualStrings("0.1 0 12.5 -3 1234567.125 ", out.written());
}

test "Dict put, remove and clone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = (try parseOne(a, "<< /A 1 /B 2 >>")).dict;
    const copy = try d.clone(a);
    try d.put(a, "C", .{ .integer = 3 });
    try d.put(a, "A", .{ .integer = 9 });
    d.remove("B");
    try t.expectEqual(@as(i64, 9), d.get("A").?.integer);
    try t.expect(d.get("B") == null);
    try t.expectEqual(@as(i64, 3), d.get("C").?.integer);
    try t.expectEqual(@as(i64, 1), copy.get("A").?.integer);
    try t.expectEqual(@as(i64, 2), copy.get("B").?.integer);
}
