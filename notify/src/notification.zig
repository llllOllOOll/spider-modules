//! What a notification is (`Notification`), who receives it (`Recipient`),
//! and the checks `send` runs on both before anything reaches the database.
//! The limits are the same as the CHECK constraints of `src/sql/0001_init.sql`, so a
//! notification that passes `validate` is never refused by Postgres.

const std = @import("std");

/// The content of a notification, shared by all its deliveries. The strings
/// are not copied by `send` until it writes them: they must stay valid for
/// the call.
pub const Notification = struct {
    /// What the app calls this kind of notification, such as
    /// `"ai.quota_95"`: 1 to 64 of `a-z 0-9 _ . -`. Preferences and the
    /// delivery log are by kind.
    kind: []const u8,
    /// The short line a person sees first: 1 to 200 bytes of UTF-8.
    title: []const u8,
    /// The text: up to 2000 bytes of UTF-8.
    body: []const u8 = "",
    /// Where tapping the notification leads, usually a path of the app
    /// (`"/admin/ia/consumo"`): up to 1000 bytes.
    url: []const u8 = "",
    /// An icon name the app's views understand: up to 64 bytes.
    icon: []const u8 = "",
    /// The app's partition (a tenant, an organization): 1 to 64 bytes, or
    /// null. Only stored, for the app's own queries.
    scope: ?[]const u8 = null,
    /// Extra data for the channels and the app, as a JSON object. Stored as
    /// `jsonb`.
    data_json: []const u8 = "{}",
    /// At most one notification is ever recorded per key: a second `send`
    /// with the same key records nothing and returns `.duplicate`. 1 to 200
    /// bytes, or null for no deduplication. Make it say what happened and
    /// when (`"quota_95:<tenant>:2026-10"`).
    dedup_key: ?[]const u8 = null,
};

/// A bare address of one channel, for a recipient who is not a user of the
/// app (an on-call phone, a team mailbox).
pub const Address = struct {
    /// The channel that delivers to it.
    channel: []const u8,
    /// What that channel understands: a phone in international digits, an
    /// email address. 1 to 320 bytes.
    value: []const u8,
};

/// Who receives a notification.
pub const Recipient = union(enum) {
    /// A user of the app, by the app's own id (1 to 64 bytes). Each channel
    /// of the request delivers to them, finding their addresses in the
    /// address book.
    user: []const u8,
    /// A bare address: only its own channel delivers to it, whatever channels
    /// the request names.
    address: Address,
};

/// Why `validate` refused a notification.
pub const Invalid = error{
    /// `kind` is empty, longer than 64 bytes, or has a byte outside
    /// `a-z 0-9 _ . -`.
    InvalidKind,
    /// `title` is empty, longer than 200 bytes, or not UTF-8.
    InvalidTitle,
    /// `body` is longer than 2000 bytes or not UTF-8.
    InvalidBody,
    /// `url` is longer than 1000 bytes or not UTF-8.
    InvalidUrl,
    /// `icon` is longer than 64 bytes or not UTF-8.
    InvalidIcon,
    /// `scope` is empty or longer than 64 bytes.
    InvalidScope,
    /// `data_json` is not a JSON object.
    InvalidData,
    /// `dedup_key` is empty or longer than 200 bytes.
    InvalidDedupKey,
    /// A user id is empty or longer than 64 bytes.
    InvalidRecipient,
    /// An address is empty or longer than 320 bytes.
    InvalidAddress,
    /// A channel name is empty, longer than 32 bytes, or has a byte outside
    /// `a-z 0-9 _`.
    InvalidChannelName,
};

fn utf8Within(s: []const u8, min: usize, max: usize) bool {
    return s.len >= min and s.len <= max and std.unicode.utf8ValidateSlice(s);
}

/// True when `name` can name a channel: 1 to 32 of `a-z 0-9 _`.
pub fn validChannelName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

fn validKind(kind: []const u8) bool {
    if (kind.len == 0 or kind.len > 64) return false;
    for (kind) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '.' or ch == '-')) return false;
    return true;
}

/// Checks `n` against the limits of the tables. `scratch` is used only to
/// parse `data_json` and can be any allocator; nothing is kept.
pub fn validate(scratch: std.mem.Allocator, n: Notification) (Invalid || std.mem.Allocator.Error)!void {
    if (!validKind(n.kind)) return error.InvalidKind;
    if (!utf8Within(n.title, 1, 200)) return error.InvalidTitle;
    if (!utf8Within(n.body, 0, 2000)) return error.InvalidBody;
    if (!utf8Within(n.url, 0, 1000)) return error.InvalidUrl;
    if (!utf8Within(n.icon, 0, 64)) return error.InvalidIcon;
    if (n.scope) |s| if (!utf8Within(s, 1, 64)) return error.InvalidScope;
    if (n.dedup_key) |k| if (!utf8Within(k, 1, 200)) return error.InvalidDedupKey;
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, n.data_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidData,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidData;
}

/// Checks one recipient. An address's channel name is checked here; whether
/// that channel is registered is `send`'s business.
pub fn validateRecipient(r: Recipient) Invalid!void {
    switch (r) {
        .user => |id| if (!utf8Within(id, 1, 64)) return error.InvalidRecipient,
        .address => |a| {
            if (!validChannelName(a.channel)) return error.InvalidChannelName;
            if (!utf8Within(a.value, 1, 320)) return error.InvalidAddress;
        },
    }
}

const long33: [33]u8 = @splat('x');
const long65: [65]u8 = @splat('x');
const long1001: [1001]u8 = @splat('x');
const long2001: [2001]u8 = @splat('x');

test "validate: accepts a full notification and the minimal one" {
    try validate(std.testing.allocator, .{ .kind = "ai.quota_95", .title = "Quota at 95%" });
    try validate(std.testing.allocator, .{
        .kind = "ai.quota-95",
        .title = "Cota de IA em 95%",
        .body = "Faltam 5% da cota do mês.",
        .url = "/admin/ia/consumo",
        .icon = "ti-alert-triangle",
        .scope = "8b5ff81b-823a-411c-95b9-d3d952b9a669",
        .data_json = "{\"percent\":95}",
        .dedup_key = "quota_95:8b5ff81b:2026-10",
    });
}

test "validate: refuses each field out of its limits" {
    const a = std.testing.allocator;
    const ok: Notification = .{ .kind = "k", .title = "t" };
    var n = ok;
    n.kind = "";
    try std.testing.expectError(error.InvalidKind, validate(a, n));
    n.kind = "Upper";
    try std.testing.expectError(error.InvalidKind, validate(a, n));
    n.kind = &long65;
    try std.testing.expectError(error.InvalidKind, validate(a, n));

    n = ok;
    n.title = "";
    try std.testing.expectError(error.InvalidTitle, validate(a, n));
    n.title = "\xff";
    try std.testing.expectError(error.InvalidTitle, validate(a, n));

    n = ok;
    n.body = &long2001;
    try std.testing.expectError(error.InvalidBody, validate(a, n));
    n = ok;
    n.url = &long1001;
    try std.testing.expectError(error.InvalidUrl, validate(a, n));
    n = ok;
    n.icon = &long65;
    try std.testing.expectError(error.InvalidIcon, validate(a, n));
    n = ok;
    n.scope = "";
    try std.testing.expectError(error.InvalidScope, validate(a, n));
    n = ok;
    n.dedup_key = "";
    try std.testing.expectError(error.InvalidDedupKey, validate(a, n));
}

test "validate: data must be a JSON object" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidData, validate(a, .{ .kind = "k", .title = "t", .data_json = "[1]" }));
    try std.testing.expectError(error.InvalidData, validate(a, .{ .kind = "k", .title = "t", .data_json = "{" }));
    try std.testing.expectError(error.InvalidData, validate(a, .{ .kind = "k", .title = "t", .data_json = "" }));
}

test "validateRecipient: users and addresses" {
    try validateRecipient(.{ .user = "42" });
    try validateRecipient(.{ .address = .{ .channel = "whatsapp", .value = "5511999998888" } });
    try std.testing.expectError(error.InvalidRecipient, validateRecipient(.{ .user = "" }));
    try std.testing.expectError(error.InvalidRecipient, validateRecipient(.{ .user = &long65 }));
    try std.testing.expectError(error.InvalidChannelName, validateRecipient(.{ .address = .{ .channel = "Whats App", .value = "1" } }));
    try std.testing.expectError(error.InvalidAddress, validateRecipient(.{ .address = .{ .channel = "email", .value = "" } }));
}

test "validChannelName" {
    try std.testing.expect(validChannelName("web_push"));
    try std.testing.expect(!validChannelName(""));
    try std.testing.expect(!validChannelName("web-push"));
    try std.testing.expect(!validChannelName(&long33));
}
