//! Where channels find a user's addresses: push subscriptions, FCM tokens,
//! phones, email addresses. `AddressBook` is the interface; `Default` keeps
//! them in the module's `notify_addresses` table, and an app that already
//! stores them elsewhere passes its own implementation to `notify.init`.

const std = @import("std");
const spider = @import("spider");
const notification = @import("notification.zig");

const pg = spider.pg;

/// One address of a user on a channel.
pub const Entry = struct {
    /// What the channel understands (a subscription JSON, a token, a phone).
    value: []const u8,
    /// A name the app shows ("Chrome on Windows"); may be empty.
    label: []const u8 = "",
};

/// The address book a channel reads. `forget` removes an address the
/// provider said is gone (an expired push subscription, an unregistered
/// FCM token); implementations that cannot remove may leave it null.
pub const AddressBook = struct {
    /// Handed back to the functions below.
    ptr: ?*anyopaque = null,
    /// The addresses of `user_id` on `channel`, in the arena. Empty when
    /// there are none.
    lookup: *const fn (ptr: ?*anyopaque, arena: std.mem.Allocator, channel: []const u8, user_id: []const u8) anyerror![]const Entry,
    /// Removes one address (by channel and value).
    forget: ?*const fn (ptr: ?*anyopaque, arena: std.mem.Allocator, channel: []const u8, value: []const u8) anyerror!void = null,

    /// The addresses of `user_id` on `channel`.
    pub fn find(self: AddressBook, arena: std.mem.Allocator, channel: []const u8, user_id: []const u8) ![]const Entry {
        return self.lookup(self.ptr, arena, channel, user_id);
    }

    /// Removes an address, when the implementation can. Errors are the
    /// caller's to log: a channel keeps going after a failed removal.
    pub fn remove(self: AddressBook, arena: std.mem.Allocator, channel: []const u8, value: []const u8) !void {
        if (self.forget) |f| try f(self.ptr, arena, channel, value);
    }
};

/// An address book with nothing in it: every lookup is empty. What
/// `notify.init` uses when the app gives none, so that channels needing
/// addresses skip instead of failing.
pub const empty: AddressBook = .{ .lookup = emptyLookup };

fn emptyLookup(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]const Entry {
    return &.{};
}

/// Why `Default.register` refused an address.
pub const RegisterError = error{
    /// The user id is empty or longer than 64 bytes.
    InvalidRecipient,
    /// The channel name is not 1 to 32 of `a-z 0-9 _`.
    InvalidChannelName,
    /// The value is empty or longer than 4000 bytes, or the label longer
    /// than 120.
    InvalidAddress,
};

/// The module's own address book, in `notify_addresses` (`src/sql/0001_init.sql`).
/// An address belongs to one user: registering a value that another user
/// had moves it (a shared browser that changed hands).
pub const Default = struct {
    /// The `AddressBook` to pass to `notify.init`.
    pub fn book() AddressBook {
        return .{ .lookup = lookupFn, .forget = forgetFn };
    }

    /// Adds or moves an address, and marks it used now. The value is what
    /// the channel expects (for `web_push`, the subscription JSON the
    /// browser gives).
    ///
    /// ```zig
    /// try notify.DefaultAddressBook.register(c.arena, user_id, "fcm", token, "Android");
    /// ```
    pub fn register(arena: std.mem.Allocator, user_id: []const u8, channel: []const u8, value: []const u8, label: []const u8) !void {
        if (user_id.len == 0 or user_id.len > 64) return error.InvalidRecipient;
        if (!notification.validChannelName(channel)) return error.InvalidChannelName;
        if (value.len == 0 or value.len > 4000 or label.len > 120) return error.InvalidAddress;
        try pg.query(void, arena,
            \\INSERT INTO notify_addresses (user_id, channel, value, label, last_used_at)
            \\VALUES ($1, $2, $3, $4, now())
            \\ON CONFLICT (channel, value) DO UPDATE
            \\   SET user_id = EXCLUDED.user_id, label = EXCLUDED.label, last_used_at = now()
        , .{ user_id, channel, value, label });
    }

    /// Removes one address of a user (a sign-out on that device). Removing
    /// one that does not exist is not an error.
    pub fn unregister(arena: std.mem.Allocator, user_id: []const u8, channel: []const u8, value: []const u8) !void {
        try pg.query(void, arena,
            \\DELETE FROM notify_addresses WHERE user_id = $1 AND channel = $2 AND value = $3
        , .{ user_id, channel, value });
    }

    fn lookupFn(_: ?*anyopaque, arena: std.mem.Allocator, channel: []const u8, user_id: []const u8) anyerror![]const Entry {
        return pg.query(Entry, arena,
            \\SELECT value, label FROM notify_addresses
            \\ WHERE user_id = $1 AND channel = $2
            \\ ORDER BY last_used_at DESC NULLS LAST, created_at DESC
            \\ LIMIT 20
        , .{ user_id, channel });
    }

    fn forgetFn(_: ?*anyopaque, arena: std.mem.Allocator, channel: []const u8, value: []const u8) anyerror!void {
        try pg.query(void, arena,
            \\DELETE FROM notify_addresses WHERE channel = $1 AND value = $2
        , .{ channel, value });
    }
};

test "empty: every lookup is empty, remove is a no-op" {
    const found = try empty.find(std.testing.allocator, "web_push", "1");
    try std.testing.expectEqual(@as(usize, 0), found.len);
    try empty.remove(std.testing.allocator, "web_push", "x");
}
