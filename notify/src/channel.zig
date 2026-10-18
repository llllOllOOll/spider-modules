//! The channel interface: what a way of delivering (inbox, SSE, Web Push,
//! FCM, email, or one the app writes) gives the module, and what the module
//! gives it back (`Job`, `DeliveryContext`), and how it answers (`Outcome`).

const std = @import("std");
const spider = @import("spider");
const notification = @import("notification.zig");
const backoff = @import("backoff.zig");
const AddressBook = @import("address_book.zig").AddressBook;

const Recipient = notification.Recipient;

/// When a channel delivers.
pub const Mode = enum {
    /// Inside `send`, in the caller's transaction (the in-app inbox): the
    /// row it writes commits or rolls back with the cause. Never retried.
    inline_write,
    /// Later, by the worker, with retries (everything that leaves the
    /// database: SSE, push, messages).
    queued,
};

/// One delivery handed to a channel. Every string lives in the worker's
/// arena for the tick (or the caller's arena, for inline channels).
pub const Job = struct {
    /// The delivery's id. Empty for inline channels (the row is written
    /// after them).
    delivery_id: []const u8,
    /// The notification's id: what an inline channel stores to point at it.
    message_id: []const u8,
    /// 1 on the first try.
    attempt: u32,
    /// Who receives it.
    recipient: Recipient,
    /// The content.
    notification: notification.Notification,
};

/// What a queued channel gets to work with.
pub const DeliveryContext = struct {
    /// Freed at the end of the tick.
    arena: std.mem.Allocator,
    /// For network calls and sleeps. Not the server's `Io`: do not write to
    /// sockets the server owns.
    io: std.Io,
    /// The SSE hub, when the worker runs as a Spider job; null in tests and
    /// in tools.
    hub: ?*spider.Hub,
    /// Where the users' addresses are.
    address_book: AddressBook,
};

/// Why a delivery did not go out. Kept as the delivery's `last_error`
/// (cut to 300 bytes): never put a secret, a token or a message body in it.
pub const Failure = struct {
    /// A short machine-readable reason: `"http_503"`, `"no_session"`.
    reason: []const u8,
    /// For `retry`: wait at least this long (a provider's Retry-After).
    /// Null: the channel's backoff decides.
    retry_after_ms: ?u64 = null,
};

/// How a channel answers for one delivery.
pub const Outcome = union(enum) {
    /// Delivered (for a user with several addresses: to at least one).
    sent,
    /// Not now: try again after the backoff, unless the attempts ran out.
    retry: Failure,
    /// Never: stop trying.
    failed: Failure,
    /// Nothing to deliver to (no address, an inactive user). The reason is
    /// kept like a failure's.
    skipped: []const u8,
};

/// A way of delivering. Build one with a constructor of
/// `spider_notify.channels` or fill it in for a channel of the app's own:
///
/// ```zig
/// const my_channel: notify.Channel = .{
///     .name = "whatsapp",
///     .ptr = &state,
///     .deliver = MyWhatsApp.deliver,
/// };
/// ```
pub const Channel = struct {
    /// The name requests use: 1 to 32 of `a-z 0-9 _`, unique among the
    /// registered channels.
    name: []const u8,
    /// Inline channels need `write_inline`; queued ones need `deliver`.
    mode: Mode = .queued,
    /// The most deliveries the worker claims per tick for this channel
    /// (1 to 1000).
    batch: u16 = 50,
    /// After this many attempts a delivery that keeps asking to retry is
    /// `failed` (1 to 50).
    max_attempts: u8 = 6,
    /// A delivery still pending this long after it was recorded is
    /// `expired` instead of sent: a late notice can be worse than none.
    max_age_ms: u64 = 24 * 60 * 60 * 1000,
    /// How long a claimed delivery belongs to the worker that claimed it.
    /// Must cover the slowest `deliver`; after it, another worker may claim
    /// it again (at-least-once).
    lease_ms: u64 = 60_000,
    /// The wait between attempts.
    backoff: backoff.Policy = .{},
    /// Handed back to the functions below.
    ptr: ?*anyopaque = null,
    /// Delivers one queued job. Must not return before it knows the
    /// outcome, and must not panic on bad data.
    deliver: ?*const fn (ptr: ?*anyopaque, ctx: *const DeliveryContext, job: *const Job) Outcome = null,
    /// Writes one inline job in the caller's transaction. An error fails
    /// the whole `send` (the caller's transaction is then aborted).
    write_inline: ?*const fn (ptr: ?*anyopaque, tx: *spider.pg.Transaction, arena: std.mem.Allocator, job: *const Job) anyerror!void = null,
};

/// Why a channel configuration was refused (by `notify.init`).
pub const ConfigError = error{
    /// The name is not 1 to 32 of `a-z 0-9 _`.
    InvalidChannelName,
    /// Two channels have the same name.
    DuplicateChannel,
    /// A queued channel without `deliver`, or an inline one without
    /// `write_inline`.
    MissingChannelFunction,
    /// `batch`, `max_attempts`, `max_age_ms`, `lease_ms` or the backoff is
    /// out of range.
    InvalidChannelLimits,
};

/// Checks one channel's fields (not its uniqueness among others).
pub fn validate(c: Channel) ConfigError!void {
    if (!notification.validChannelName(c.name)) return error.InvalidChannelName;
    switch (c.mode) {
        .queued => if (c.deliver == null) return error.MissingChannelFunction,
        .inline_write => if (c.write_inline == null) return error.MissingChannelFunction,
    }
    if (c.batch == 0 or c.batch > 1000) return error.InvalidChannelLimits;
    if (c.max_attempts == 0 or c.max_attempts > 50) return error.InvalidChannelLimits;
    if (c.max_age_ms < 1000 or c.lease_ms < 1000) return error.InvalidChannelLimits;
    if (c.backoff.base_ms == 0 or c.backoff.max_ms < c.backoff.base_ms) return error.InvalidChannelLimits;
}

/// Cuts a reason to what `last_error` holds (300 bytes), at a UTF-8
/// boundary.
pub fn clipReason(reason: []const u8) []const u8 {
    if (reason.len <= 300) return reason;
    var end: usize = 300;
    while (end > 0 and (reason[end] & 0xC0) == 0x80) end -= 1;
    return reason[0..end];
}

fn noDeliver(_: ?*anyopaque, _: *const DeliveryContext, _: *const Job) Outcome {
    return .sent;
}

test "validate: a queued channel needs deliver, limits in range" {
    try validate(.{ .name = "sse", .deliver = noDeliver });
    try std.testing.expectError(error.MissingChannelFunction, validate(.{ .name = "sse" }));
    try std.testing.expectError(error.MissingChannelFunction, validate(.{ .name = "inbox", .mode = .inline_write }));
    try std.testing.expectError(error.InvalidChannelName, validate(.{ .name = "Web Push", .deliver = noDeliver }));
    try std.testing.expectError(error.InvalidChannelLimits, validate(.{ .name = "a", .deliver = noDeliver, .batch = 0 }));
    try std.testing.expectError(error.InvalidChannelLimits, validate(.{ .name = "a", .deliver = noDeliver, .max_attempts = 0 }));
    try std.testing.expectError(error.InvalidChannelLimits, validate(.{ .name = "a", .deliver = noDeliver, .lease_ms = 10 }));
    try std.testing.expectError(error.InvalidChannelLimits, validate(.{ .name = "a", .deliver = noDeliver, .backoff = .{ .base_ms = 10, .max_ms = 5 } }));
}

test "clipReason: keeps short reasons, cuts long ones at a character boundary" {
    try std.testing.expectEqualStrings("http_503", clipReason("http_503"));
    const long: [299]u8 = @splat('a');
    const with_accent: []const u8 = &long ++ "é"; // 'é' takes bytes 299 and 300
    try std.testing.expectEqual(@as(usize, 299), clipReason(with_accent).len);
}
