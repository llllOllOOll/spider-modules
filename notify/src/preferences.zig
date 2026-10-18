//! Whether a user wants a kind of notification on a channel. The module
//! asks once per (user, channel) when `send` records a notification; a
//! "no" is recorded as a `skipped` delivery with the reason `preference`,
//! so the log still shows that the user would have been notified.

const std = @import("std");

/// The question `send` asks. Errors count as "yes": a broken preference
/// store must not silence notifications.
pub const Preferences = struct {
    /// Handed back to `allows`.
    ptr: ?*anyopaque = null,
    /// True when `user_id` wants notifications of `kind` on `channel`.
    allows: *const fn (ptr: ?*anyopaque, arena: std.mem.Allocator, user_id: []const u8, kind: []const u8, channel: []const u8) anyerror!bool,

    /// `allows`, with errors read as "yes".
    pub fn check(self: Preferences, arena: std.mem.Allocator, user_id: []const u8, kind: []const u8, channel: []const u8) bool {
        return self.allows(self.ptr, arena, user_id, kind, channel) catch |err| {
            std.log.warn("notify: preferences failed ({s}); delivering anyway", .{@errorName(err)});
            return true;
        };
    }
};

/// Every user wants everything: what `notify.init` uses when the app gives
/// no preferences.
pub const allow_all: Preferences = .{ .allows = allowAll };

fn allowAll(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!bool {
    return true;
}

fn failing(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!bool {
    return error.StoreDown;
}

test "allow_all says yes; a failing store reads as yes" {
    try std.testing.expect(allow_all.check(std.testing.allocator, "1", "k", "sse"));
    const broken: Preferences = .{ .allows = failing };
    try std.testing.expect(broken.check(std.testing.allocator, "1", "k", "sse"));
}
