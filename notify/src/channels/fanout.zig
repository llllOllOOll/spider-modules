//! Internal: delivery to every address of a user (a user may have several
//! browsers subscribed and two phones with the app) and the rule that
//! turns the per-address results into one `Outcome`:
//!
//!   - no address                     → skipped "no_address"
//!   - delivered to at least one      → sent
//!   - none, and some failure is transient → retry (the first such reason)
//!   - all addresses gone             → skipped "addresses_gone" (removed)
//!   - otherwise                      → failed (the first reason)
//!
//! Addresses the provider says are gone are removed from the address book.

const std = @import("std");
const channel = @import("../channel.zig");
const address_book = @import("../address_book.zig");

pub const Result = union(enum) {
    ok,
    /// The address no longer exists (410 from a push service, an
    /// unregistered token): remove it.
    gone,
    transient: channel.Failure,
    permanent: channel.Failure,
};

pub const Tally = struct {
    total: usize = 0,
    ok: usize = 0,
    gone: usize = 0,
    first_transient: ?channel.Failure = null,
    first_permanent: ?channel.Failure = null,

    pub fn add(self: *Tally, r: Result) void {
        self.total += 1;
        switch (r) {
            .ok => self.ok += 1,
            .gone => self.gone += 1,
            .transient => |f| {
                if (self.first_transient == null) self.first_transient = f;
            },
            .permanent => |f| {
                if (self.first_permanent == null) self.first_permanent = f;
            },
        }
    }

    pub fn outcome(self: Tally) channel.Outcome {
        if (self.total == 0) return .{ .skipped = "no_address" };
        if (self.ok > 0) return .sent;
        if (self.first_transient) |f| return .{ .retry = f };
        if (self.gone == self.total) return .{ .skipped = "addresses_gone" };
        return .{ .failed = self.first_permanent orelse .{ .reason = "failed" } };
    }
};

/// Calls `sendOne` for each address of the job's user on `channel_name`,
/// removes the gone ones, and tallies. A job for a bare address delivers to
/// that one address. `State` is the channel's state type.
pub fn deliver(
    comptime State: type,
    state: *State,
    ctx: *const channel.DeliveryContext,
    job: *const channel.Job,
    channel_name: []const u8,
    comptime sendOne: fn (*State, *const channel.DeliveryContext, *const channel.Job, []const u8) Result,
) channel.Outcome {
    var tally: Tally = .{};
    switch (job.recipient) {
        .address => |a| tally.add(sendOne(state, ctx, job, a.value)),
        .user => |user_id| {
            const entries = ctx.address_book.find(ctx.arena, channel_name, user_id) catch |err| {
                std.log.warn("notify: {s}: address book failed ({s})", .{ channel_name, @errorName(err) });
                return .{ .retry = .{ .reason = "address_book_failed" } };
            };
            for (entries) |e| {
                const r = sendOne(state, ctx, job, e.value);
                if (r == .gone) {
                    ctx.address_book.remove(ctx.arena, channel_name, e.value) catch |err| {
                        std.log.warn("notify: {s}: could not remove a gone address ({s})", .{ channel_name, @errorName(err) });
                    };
                }
                tally.add(r);
            }
        },
    }
    return tally.outcome();
}

test "Tally: the rules" {
    var t: Tally = .{};
    try std.testing.expectEqualStrings("no_address", t.outcome().skipped);

    t = .{};
    t.add(.{ .transient = .{ .reason = "http_503" } });
    t.add(.ok);
    try std.testing.expect(t.outcome() == .sent);

    t = .{};
    t.add(.{ .permanent = .{ .reason = "http_400" } });
    t.add(.{ .transient = .{ .reason = "http_503" } });
    try std.testing.expectEqualStrings("http_503", t.outcome().retry.reason);

    t = .{};
    t.add(.gone);
    t.add(.gone);
    try std.testing.expectEqualStrings("addresses_gone", t.outcome().skipped);

    t = .{};
    t.add(.gone);
    t.add(.{ .permanent = .{ .reason = "http_400" } });
    try std.testing.expectEqualStrings("http_400", t.outcome().failed.reason);
}

const Fake = struct {
    removed: usize = 0,
    sent_to: std.ArrayList([]const u8) = .empty,

    fn lookup(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) anyerror![]const address_book.Entry {
        return &.{ .{ .value = "a" }, .{ .value = "gone" }, .{ .value = "b" } };
    }
    fn forget(ptr: ?*anyopaque, _: std.mem.Allocator, _: []const u8, value: []const u8) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ptr.?));
        std.debug.assert(std.mem.eql(u8, value, "gone"));
        self.removed += 1;
    }
    fn sendOne(self: *Fake, ctx: *const channel.DeliveryContext, _: *const channel.Job, value: []const u8) Result {
        self.sent_to.append(ctx.arena, value) catch {};
        if (std.mem.eql(u8, value, "gone")) return .gone;
        return .ok;
    }
};

test "deliver: every address of the user, gone ones removed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var fake: Fake = .{};
    const ctx: channel.DeliveryContext = .{
        .arena = arena_state.allocator(),
        .io = undefined,
        .hub = null,
        .address_book = .{ .ptr = &fake, .lookup = Fake.lookup, .forget = Fake.forget },
    };
    const job: channel.Job = .{ .delivery_id = "d", .message_id = "m", .attempt = 1, .recipient = .{ .user = "1" }, .notification = .{ .kind = "k", .title = "t" } };
    const out = deliver(Fake, &fake, &ctx, &job, "web_push", Fake.sendOne);
    try std.testing.expect(out == .sent);
    try std.testing.expectEqual(@as(usize, 3), fake.sent_to.items.len);
    try std.testing.expectEqual(@as(usize, 1), fake.removed);

    // A bare address: only that one, no lookup.
    fake.sent_to = .empty;
    const direct: channel.Job = .{ .delivery_id = "d", .message_id = "m", .attempt = 1, .recipient = .{ .address = .{ .channel = "web_push", .value = "x" } }, .notification = .{ .kind = "k", .title = "t" } };
    _ = deliver(Fake, &fake, &ctx, &direct, "web_push", Fake.sendOne);
    try std.testing.expectEqual(@as(usize, 1), fake.sent_to.items.len);
    try std.testing.expectEqualStrings("x", fake.sent_to.items[0]);
}
