//! The `web_push` channel: browser push through `spider.push.WebPush`
//! (VAPID). A user's addresses are the subscriptions their browsers gave,
//! each stored as the JSON of `PushSubscription.toJSON()`
//! (`{"endpoint": "...", "keys": {"p256dh": "...", "auth": "..."}}`).
//! A subscription the push service says is gone (410) or that was made with
//! other VAPID keys (403) is removed from the address book. Without VAPID
//! keys every delivery is skipped (`not_configured`).

const std = @import("std");
const spider = @import("spider");
const ch = @import("../channel.zig");
const fanout = @import("fanout.zig");

/// The state behind a `web_push` channel: keep it alive as long as the app.
pub const WebPush = struct {
    /// The sender, with the app's VAPID keys.
    client: spider.push.WebPush,
    /// How long the push service keeps a message for an offline browser, in
    /// seconds.
    ttl_s: u32 = 24 * 60 * 60,

    /// The channel, named `web_push`.
    ///
    /// ```zig
    /// var push_state: notify.channels.WebPush = .{ .client = spider.push.WebPush.initFromEnv() };
    /// // ...
    /// .channels = &.{ push_state.channel(), ... },
    /// ```
    pub fn channel(self: *WebPush) ch.Channel {
        return .{ .name = "web_push", .ptr = self, .deliver = deliver };
    }
};

/// The message the service worker receives, as JSON: `title`, `body`,
/// `url`, `icon`, and `tag` (the notification id, so a repeat replaces
/// instead of stacking). Pure, for tests.
pub fn payload(arena: std.mem.Allocator, job: *const ch.Job) ![]const u8 {
    const n = job.notification;
    return std.json.Stringify.valueAlloc(arena, .{
        .title = n.title,
        .body = n.body,
        .url = n.url,
        .icon = n.icon,
        .tag = job.message_id,
    }, .{});
}

/// A subscription JSON as `spider.push` takes it. Null when it is not one.
pub fn parseSubscription(arena: std.mem.Allocator, json: []const u8) ?spider.push.PushSubscription {
    const S = struct {
        endpoint: []const u8,
        keys: struct { p256dh: []const u8, auth: []const u8 },
    };
    const parsed = std.json.parseFromSliceLeaky(S, arena, json, .{ .ignore_unknown_fields = true }) catch return null;
    if (parsed.endpoint.len == 0 or parsed.keys.p256dh.len == 0 or parsed.keys.auth.len == 0) return null;
    return .{ .endpoint = parsed.endpoint, .p256dh = parsed.keys.p256dh, .auth = parsed.keys.auth };
}

fn deliver(ptr: ?*anyopaque, ctx: *const ch.DeliveryContext, job: *const ch.Job) ch.Outcome {
    const self: *WebPush = @ptrCast(@alignCast(ptr.?));
    // Without VAPID keys nothing can go out: skip instead of retrying.
    if (self.client.config.private_key.len == 0 or self.client.config.public_key.len == 0) return .{ .skipped = "not_configured" };
    return fanout.deliver(WebPush, self, ctx, job, "web_push", sendOne);
}

fn sendOne(self: *WebPush, ctx: *const ch.DeliveryContext, job: *const ch.Job, value: []const u8) fanout.Result {
    // A stored value that is not a subscription can never work: remove it.
    const sub = parseSubscription(ctx.arena, value) orelse return .gone;
    const body = payload(ctx.arena, job) catch return .{ .transient = .{ .reason = "out_of_memory" } };
    self.client.sendRaw(ctx.arena, ctx.io, sub, body, self.ttl_s) catch |err| return switch (err) {
        error.PushSubscriptionExpired, error.PushForbidden => .gone,
        error.PayloadTooLarge => .{ .permanent = .{ .reason = "payload_too_large" } },
        error.PushSendFailed => .{ .transient = .{ .reason = "push_service_refused" } },
        else => .{ .transient = .{ .reason = @errorName(err) } },
    };
    return .ok;
}

test "parseSubscription: the browser's JSON, and refusals" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const s = parseSubscription(a,
        \\{"endpoint":"https://push.example/abc","expirationTime":null,"keys":{"p256dh":"BP","auth":"au"}}
    ).?;
    try std.testing.expectEqualStrings("https://push.example/abc", s.endpoint);
    try std.testing.expectEqualStrings("BP", s.p256dh);
    try std.testing.expectEqualStrings("au", s.auth);
    try std.testing.expect(parseSubscription(a, "not json") == null);
    try std.testing.expect(parseSubscription(a, "{\"endpoint\":\"\",\"keys\":{\"p256dh\":\"x\",\"auth\":\"y\"}}") == null);
    try std.testing.expect(parseSubscription(a, "{\"endpoint\":\"https://x\"}") == null);
}

test "payload: the service worker's fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const job: ch.Job = .{ .delivery_id = "d", .message_id = "m1", .attempt = 1, .recipient = .{ .user = "1" }, .notification = .{ .kind = "k", .title = "T", .body = "B", .url = "/u" } };
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try payload(a, &job), .{});
    try std.testing.expectEqualStrings("T", v.object.get("title").?.string);
    try std.testing.expectEqualStrings("/u", v.object.get("url").?.string);
    try std.testing.expectEqualStrings("m1", v.object.get("tag").?.string);
}

test "web_push: a channel that validates; without keys it skips" {
    var state: WebPush = .{ .client = spider.push.WebPush.init(.{ .subject = "mailto:a@b.c", .private_key = "", .public_key = "" }) };
    const c = state.channel();
    try ch.validate(c);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx: ch.DeliveryContext = .{ .arena = arena_state.allocator(), .io = undefined, .hub = null, .address_book = @import("../address_book.zig").empty };
    const job: ch.Job = .{ .delivery_id = "d", .message_id = "m", .attempt = 1, .recipient = .{ .user = "1" }, .notification = .{ .kind = "k", .title = "t" } };
    try std.testing.expectEqualStrings("not_configured", c.deliver.?(c.ptr, &ctx, &job).skipped);
}
