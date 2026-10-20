//! Opening encrypted PDF files: the standard security handler.
//!
//! Most "protected" PDFs open without a password: they have an empty user
//! password and only an owner password that restricts printing, copying or
//! changing them. Their strings and streams are still encrypted, with a key
//! anyone can compute. This file computes it (or the key of a given user or
//! owner password), checks it, and decrypts objects.
//!
//! Revisions 2 to 6 of the handler: RC4 with 40 to 128-bit keys (R2-R4),
//! AES-128 (R4, AESV2) and AES-256 (R5 and R6, AESV3), crypt filters
//! (`/CF`, `/StmF`, `/StrF`, `Identity`), and unencrypted metadata.
//! Public-key security handlers are refused (`error.UnsupportedEncryption`).
//!
//! The permissions the file grants (`/P`) are reported, not enforced: the
//! application that holds the file decides what to allow.

const std = @import("std");
const syntax = @import("syntax.zig");

const Object = syntax.Object;
const Dict = syntax.Dict;
const Ref = syntax.Ref;
const Md5 = std.crypto.hash.Md5;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Aes128 = std.crypto.core.aes.Aes128;
const Aes256 = std.crypto.core.aes.Aes256;

pub const Error = error{
    /// The file needs a password (its user password is not empty).
    EncryptedPdf,
    /// The password given is neither the user nor the owner password.
    WrongPassword,
    /// A security handler or revision this reader does not know.
    UnsupportedEncryption,
    InvalidPdf,
    OutOfMemory,
};

pub const Method = enum { none, rc4, aes128, aes256 };

/// The padding of passwords in revisions 2 to 4 (ISO 32000, 7.6.4.3).
const padding = [32]u8{
    0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
    0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
};

pub const Decryptor = struct {
    key: [32]u8 = @splat(0),
    key_len: usize = 0,
    streams: Method,
    strings: Method,
    encrypt_metadata: bool,
    /// The /P flags (bit 3 print, 4 modify, 5 copy, 6 annotate, 9 fill
    /// forms, 10 extract, 11 assemble, 12 print in high quality).
    permissions: i32,

    /// Finds the file key from the /Encrypt dictionary, the first string of
    /// the trailer's /ID, and `password` (tried as the user password, then
    /// as the owner password; empty for files that open without one).
    pub fn init(enc: Dict, id0: []const u8, password: []const u8) Error!Decryptor {
        if (!enc.hasName("Filter", "Standard")) return Error.UnsupportedEncryption;
        const v = intOf(enc.get("V")) orelse 0;
        const r = intOf(enc.get("R")) orelse return Error.InvalidPdf;
        const o = stringOf(enc.get("O")) orelse return Error.InvalidPdf;
        const u = stringOf(enc.get("U")) orelse return Error.InvalidPdf;
        const p: i32 = @truncate(intOf(enc.get("P")) orelse 0);
        const encrypt_metadata = if (enc.get("EncryptMetadata")) |m| !(m == .boolean and !m.boolean) else true;

        var d: Decryptor = .{ .streams = .rc4, .strings = .rc4, .encrypt_metadata = encrypt_metadata, .permissions = p };
        switch (v) {
            1, 2 => {},
            4, 5 => {
                d.streams = try cryptFilter(enc, "StmF");
                d.strings = try cryptFilter(enc, "StrF");
            },
            else => return Error.UnsupportedEncryption,
        }

        switch (r) {
            2, 3, 4 => {
                if (o.len < 32 or u.len < 32) return Error.InvalidPdf;
                d.key_len = if (r == 2) 5 else blk: {
                    const bits = intOf(enc.get("Length")) orelse 40;
                    if (bits < 40 or bits > 128 or @mod(bits, 8) != 0) return Error.InvalidPdf;
                    break :blk @intCast(@divExact(bits, 8));
                };
                if (d.streams == .aes128 or d.strings == .aes128) d.key_len = 16;
                const pw = password[0..@min(password.len, 32)];
                if (d.tryUserR4(pw, o, u, id0, r)) return d;
                // The owner password decrypts /O into the user password.
                const user_pw = ownerToUser(pw, o, r, d.key_len);
                if (d.tryUserR4(&user_pw, o, u, id0, r)) return d;
            },
            5, 6 => {
                if (o.len < 48 or u.len < 48) return Error.InvalidPdf;
                const ue = stringOf(enc.get("UE")) orelse return Error.InvalidPdf;
                const oe = stringOf(enc.get("OE")) orelse return Error.InvalidPdf;
                if (ue.len < 32 or oe.len < 32) return Error.InvalidPdf;
                d.key_len = 32;
                const pw = password[0..@min(password.len, 127)];
                // User: hash(password, validation salt) == U[0..32].
                if (std.mem.eql(u8, &hashR6(r, pw, u[32..40], ""), u[0..32])) {
                    d.key = aes256DecryptNoIv(hashR6(r, pw, u[40..48], ""), ue[0..32].*);
                    return d;
                }
                if (std.mem.eql(u8, &hashR6(r, pw, o[32..40], u[0..48]), o[0..32])) {
                    d.key = aes256DecryptNoIv(hashR6(r, pw, o[40..48], u[0..48]), oe[0..32].*);
                    return d;
                }
            },
            else => return Error.UnsupportedEncryption,
        }
        return if (password.len == 0) Error.EncryptedPdf else Error.WrongPassword;
    }

    /// Algorithms 2 and 6: the key from a user password, kept when the
    /// password checks against /U.
    fn tryUserR4(self: *Decryptor, pw: []const u8, o: []const u8, u: []const u8, id0: []const u8, r: i64) bool {
        var h = Md5.init(.{});
        var padded: [32]u8 = undefined;
        padPassword(pw, &padded);
        h.update(&padded);
        h.update(o[0..32]);
        var pbytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &pbytes, self.permissions, .little);
        h.update(&pbytes);
        h.update(id0);
        if (r >= 4 and !self.encrypt_metadata) h.update(&.{ 0xFF, 0xFF, 0xFF, 0xFF });
        var digest: [16]u8 = undefined;
        h.final(&digest);
        if (r >= 3) {
            for (0..50) |_| Md5.hash(digest[0..self.key_len], &digest, .{});
        }
        const key = digest[0..self.key_len];

        if (r == 2) {
            var check = padding;
            rc4(key, &check);
            if (!std.mem.eql(u8, &check, u[0..32])) return false;
        } else {
            var check: [16]u8 = undefined;
            var h2 = Md5.init(.{});
            h2.update(&padding);
            h2.update(id0);
            h2.final(&check);
            rc4(key, &check);
            var k: [16]u8 = undefined;
            for (1..20) |i| {
                for (key, 0..) |b, j| k[j] = b ^ @as(u8, @intCast(i));
                rc4(k[0..self.key_len], &check);
            }
            if (!std.mem.eql(u8, &check, u[0..16])) return false;
        }
        @memcpy(self.key[0..self.key_len], key);
        return true;
    }

    /// `obj` (object `ref`) with its strings and stream data decrypted.
    /// Cross-reference streams are not encrypted; neither is the metadata
    /// stream when /EncryptMetadata is false.
    pub fn decryptObject(self: Decryptor, arena: std.mem.Allocator, ref: Ref, obj: Object) Error!Object {
        return switch (obj) {
            .string => |s| .{ .string = try self.decrypt(arena, self.strings, ref, s) },
            .array => |items| blk: {
                const out = try arena.alloc(Object, items.len);
                for (items, out) |item, *o| o.* = try self.decryptObject(arena, ref, item);
                break :blk .{ .array = out };
            },
            .dict => |d| .{ .dict = try self.decryptDict(arena, ref, d) },
            .stream => |s| blk: {
                const dict = try self.decryptDict(arena, ref, s.dict);
                const skip = s.dict.hasName("Type", "XRef") or
                    (!self.encrypt_metadata and s.dict.hasName("Type", "Metadata")) or
                    usesIdentityCrypt(s.dict);
                const data = if (skip) s.data else try self.decrypt(arena, self.streams, ref, s.data);
                break :blk .{ .stream = .{ .dict = dict, .data = data } };
            },
            else => obj,
        };
    }

    fn decryptDict(self: Decryptor, arena: std.mem.Allocator, ref: Ref, d: Dict) Error!Dict {
        const entries = try arena.alloc(syntax.Entry, d.entries.len);
        for (d.entries, entries) |e, *o| o.* = .{ .key = e.key, .value = try self.decryptObject(arena, ref, e.value) };
        return .{ .entries = entries };
    }

    fn decrypt(self: Decryptor, arena: std.mem.Allocator, method: Method, ref: Ref, data: []const u8) Error![]const u8 {
        switch (method) {
            .none => return data,
            .aes256 => return aesCbcDecrypt(Aes256, arena, self.key, data),
            .rc4, .aes128 => {
                // Algorithm 1: a key of its own for each object.
                var h = Md5.init(.{});
                h.update(self.key[0..self.key_len]);
                h.update(&.{ @truncate(ref.num), @truncate(ref.num >> 8), @truncate(ref.num >> 16), @truncate(ref.gen), @truncate(ref.gen >> 8) });
                if (method == .aes128) h.update("sAlT");
                var digest: [16]u8 = undefined;
                h.final(&digest);
                const n = @min(self.key_len + 5, 16);
                if (method == .aes128) return aesCbcDecrypt(Aes128, arena, digest, data);
                const out = try arena.dupe(u8, data);
                rc4(digest[0..n], out);
                return out;
            },
        }
    }
};

/// `/Filter [/Crypt] /DecodeParms << /Name /Identity >>`: a stream left
/// unencrypted on purpose.
fn usesIdentityCrypt(d: Dict) bool {
    const f = d.get("Filter") orelse return false;
    const crypt = switch (f) {
        .name => |n| std.mem.eql(u8, n, "Crypt"),
        .array => |a| a.len > 0 and a[0].isName("Crypt"),
        else => false,
    };
    if (!crypt) return false;
    const parms = d.get("DecodeParms") orelse return true;
    const pd = switch (parms) {
        .dict => |pd| pd,
        .array => |a| if (a.len > 0 and a[0] == .dict) a[0].dict else return true,
        else => return true,
    };
    return if (pd.get("Name")) |n| n.isName("Identity") else true;
}

fn cryptFilter(enc: Dict, key: []const u8) Error!Method {
    const name = (enc.get(key) orelse return .none);
    if (name != .name) return Error.InvalidPdf;
    if (std.mem.eql(u8, name.name, "Identity")) return .none;
    const cf = enc.get("CF") orelse return Error.InvalidPdf;
    if (cf != .dict) return Error.InvalidPdf;
    const filter = cf.dict.get(name.name) orelse return Error.InvalidPdf;
    if (filter != .dict) return Error.InvalidPdf;
    const cfm = filter.dict.get("CFM") orelse return .none;
    if (cfm.isName("V2")) return .rc4;
    if (cfm.isName("AESV2")) return .aes128;
    if (cfm.isName("AESV3")) return .aes256;
    if (cfm.isName("None")) return .none;
    return Error.UnsupportedEncryption;
}

fn intOf(o: ?Object) ?i64 {
    const v = o orelse return null;
    return if (v == .integer) v.integer else null;
}

fn stringOf(o: ?Object) ?[]const u8 {
    const v = o orelse return null;
    return if (v == .string) v.string else null;
}

fn padPassword(pw: []const u8, out: *[32]u8) void {
    const n = @min(pw.len, 32);
    @memcpy(out[0..n], pw[0..n]);
    @memcpy(out[n..], padding[0 .. 32 - n]);
}

/// Algorithm 7, the other way: the owner password's key decrypts /O into
/// the padded user password.
fn ownerToUser(owner: []const u8, o: []const u8, r: i64, key_len: usize) [32]u8 {
    var padded: [32]u8 = undefined;
    padPassword(owner, &padded);
    var digest: [16]u8 = undefined;
    Md5.hash(&padded, &digest, .{});
    if (r >= 3) {
        for (0..50) |_| Md5.hash(&digest, &digest, .{});
    }
    const key = digest[0..key_len];
    var user: [32]u8 = o[0..32].*;
    if (r == 2) {
        rc4(key, &user);
    } else {
        var k: [16]u8 = undefined;
        var i: u8 = 19;
        while (true) : (i -= 1) {
            for (key, 0..) |b, j| k[j] = b ^ i;
            rc4(k[0..key_len], &user);
            if (i == 0) break;
        }
    }
    return user;
}

/// The hash of revision 6 (Algorithm 2.B), or plain SHA-256 for the
/// deprecated revision 5. `udata` is the 48 bytes of /U for the owner
/// password, empty for the user password.
fn hashR6(r: i64, pw: []const u8, salt: []const u8, udata: []const u8) [32]u8 {
    var k: [64]u8 = undefined;
    var k_len: usize = 32;
    var h = Sha256.init(.{});
    h.update(pw);
    h.update(salt);
    h.update(udata);
    h.final(k[0..32]);
    if (r == 5) return k[0..32].*;

    var round: usize = 0;
    var buf: [64 * (127 + 64 + 48)]u8 = undefined;
    while (true) {
        // K1: (password, K, udata) 64 times; E: AES-128-CBC of K1.
        const unit = pw.len + k_len + udata.len;
        var n: usize = 0;
        for (0..64) |_| {
            @memcpy(buf[n..][0..pw.len], pw);
            @memcpy(buf[n + pw.len ..][0..k_len], k[0..k_len]);
            @memcpy(buf[n + pw.len + k_len ..][0..udata.len], udata);
            n += unit;
        }
        const e = buf[0..n];
        const enc = Aes128.initEnc(k[0..16].*);
        var iv: [16]u8 = k[16..32].*;
        var i: usize = 0;
        while (i < n) : (i += 16) {
            var block: [16]u8 = undefined;
            for (0..16) |j| block[j] = e[i + j] ^ iv[j];
            enc.encrypt(&block, &block);
            @memcpy(e[i..][0..16], &block);
            iv = block;
        }
        var sum: u32 = 0;
        for (e[0..16]) |b| sum += b;
        switch (sum % 3) {
            0 => {
                Sha256.hash(e, k[0..32], .{});
                k_len = 32;
            },
            1 => {
                Sha384.hash(e, k[0..48], .{});
                k_len = 48;
            },
            else => {
                Sha512.hash(e, k[0..64], .{});
                k_len = 64;
            },
        }
        round += 1;
        if (round >= 64 and e[n - 1] <= round - 32) break;
    }
    return k[0..32].*;
}

/// AES-256 in CBC mode with a zero IV and no padding, over two blocks: how
/// /UE and /OE hold the file key.
fn aes256DecryptNoIv(key: [32]u8, data: [32]u8) [32]u8 {
    const dec = Aes256.initDec(key);
    var out: [32]u8 = undefined;
    var prev: [16]u8 = @splat(0);
    for (0..2) |b| {
        const block: [16]u8 = data[b * 16 ..][0..16].*;
        var plain: [16]u8 = undefined;
        dec.decrypt(&plain, &block);
        for (0..16) |j| out[b * 16 + j] = plain[j] ^ prev[j];
        prev = block;
    }
    return out;
}

/// AES-CBC with the IV in the first 16 bytes and PKCS#5 padding. Data
/// shorter than an IV decrypts to nothing; a bad padding is left in place.
fn aesCbcDecrypt(comptime Aes: type, arena: std.mem.Allocator, key: anytype, data: []const u8) Error![]const u8 {
    if (data.len < 32) return "";
    const key_bytes: [Aes.key_bits / 8]u8 = key[0 .. Aes.key_bits / 8].*;
    const dec = Aes.initDec(key_bytes);
    const body = data[16 .. 16 + (data.len - 16) / 16 * 16];
    const out = try arena.alloc(u8, body.len);
    var prev: [16]u8 = data[0..16].*;
    var i: usize = 0;
    while (i < body.len) : (i += 16) {
        const block: [16]u8 = body[i..][0..16].*;
        var plain: [16]u8 = undefined;
        dec.decrypt(&plain, &block);
        for (0..16) |j| out[i + j] = plain[j] ^ prev[j];
        prev = block;
    }
    const pad = out[out.len - 1];
    if (pad >= 1 and pad <= 16 and pad <= out.len) return out[0 .. out.len - pad];
    return out;
}

fn rc4(key: []const u8, data: []u8) void {
    var s: [256]u8 = undefined;
    for (&s, 0..) |*b, i| b.* = @intCast(i);
    var j: u8 = 0;
    for (0..256) |i| {
        j +%= s[i] +% key[i % key.len];
        std.mem.swap(u8, &s[i], &s[j]);
    }
    var i: u8 = 0;
    j = 0;
    for (data) |*b| {
        i +%= 1;
        j +%= s[i];
        std.mem.swap(u8, &s[i], &s[j]);
        b.* ^= s[s[i] +% s[j]];
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

const t = std.testing;

test "RC4 matches the published test vector" {
    var data = "Plaintext".*;
    rc4("Key", &data);
    try t.expectEqualSlices(u8, &.{ 0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3 }, &data);
}

test "AES-CBC decrypts what it encrypted, and strips the padding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const key: [16]u8 = @splat(7);
    const iv: [16]u8 = @splat(1);
    // "hello" padded with 11 bytes of 11, encrypted by hand.
    var block: [16]u8 = "hello".* ++ @as([11]u8, @splat(11));
    for (&block, iv) |*b, v| b.* ^= v;
    Aes128.initEnc(key).encrypt(&block, &block);
    const out = try aesCbcDecrypt(Aes128, arena.allocator(), key, &(iv ++ block));
    try t.expectEqualStrings("hello", out);
    try t.expectEqualStrings("", try aesCbcDecrypt(Aes128, arena.allocator(), key, "short"));
}

test "a public-key handler and unknown revisions are refused by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var p = syntax.Parser.init(arena.allocator(), "<< /Filter /Adobe.PubSec /V 4 /R 4 >>", 0);
    try t.expectError(Error.UnsupportedEncryption, Decryptor.init((try p.object()).dict, "", ""));
    var q = syntax.Parser.init(arena.allocator(), "<< /Filter /Standard /V 9 /R 9 /O () /U () >>", 0);
    try t.expectError(Error.UnsupportedEncryption, Decryptor.init((try q.object()).dict, "", ""));
}
