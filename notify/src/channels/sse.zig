//! The `sse` channel: tells the user's open pages, through Spider's SSE
//! hub, that a notification arrived (to refresh a bell, play a sound, show
//! a toast). Best effort by nature: an SSE event to nobody is still `sent`;
//! a page that reconnects within the hub's replay window gets it then.

const std = @import("std");
const spider = @import("spider");
const ch = @import("../channel.zig");

/// How the `sse` channel names hub channels and events.
pub const Options = struct {
    /// The SSE event name the pages listen for.
    event: []const u8 = "notification",
    /// The hub channel of a user. Null: `"user:<user id>"`. An app whose
    /// pages join another name (Orbitx joins `"user:<Keycloak sub>"`, while
    /// its notification recipients are database ids) maps it here; an error
    /// counts as a transient failure.
    hub_channel: ?*const fn (arena: std.mem.Allocator, user_id: []const u8) anyerror![]const u8 = null,
    /// Send the content (kind, title, body, url, icon) with the event.
    /// False sends only the ids: the page fetches what it shows.
    with_content: bool = true,
    /// Builds the event's data (a JSON object) instead of the two shapes
    /// above, for pages that already read other fields (an app moving its
    /// existing events onto the notifier). An error counts as a transient
    /// failure.
    payload: ?*const fn (arena: std.mem.Allocator, job: *const ch.Job) anyerror![]const u8 = null,
};

/// The state behind an `sse` channel: keep it alive as long as the app
/// (a global, or a field of a global).
pub const Sse = struct {
    /// The options it was made with.
    options: Options = .{},

    /// The channel, named `sse`.
    ///
    /// ```zig
    /// var sse_state: notify.channels.Sse = .{ .options = .{ .event = "notification_created" } };
    /// // ...
    /// .channels = &.{ sse_state.channel(), ... },
    /// ```
    pub fn channel(self: *Sse) ch.Channel {
        return .{
            .name = "sse",
            .ptr = self,
            .deliver = deliver,
            // An old live event is noise: an hour is plenty.
            .max_age_ms = 60 * 60 * 1000,
            .max_attempts = 3,
            .backoff = .{ .base_ms = 1000, .max_ms = 10_000 },
            .batch = 200,
        };
    }
};

/// The payload of the event, as JSON (pure, for tests).
pub fn payload(arena: std.mem.Allocator, options: Options, job: *const ch.Job) ![]const u8 {
    if (options.payload) |build| return build(arena, job);
    const n = job.notification;
    if (!options.with_content) {
        return std.json.Stringify.valueAlloc(arena, .{ .id = job.message_id, .kind = n.kind }, .{});
    }
    return std.json.Stringify.valueAlloc(arena, .{
        .id = job.message_id,
        .kind = n.kind,
        .title = n.title,
        .body = n.body,
        .url = n.url,
        .icon = n.icon,
    }, .{});
}

fn deliver(ptr: ?*anyopaque, ctx: *const ch.DeliveryContext, job: *const ch.Job) ch.Outcome {
    const self: *Sse = @ptrCast(@alignCast(ptr.?));
    const hub = ctx.hub orelse return .{ .skipped = "no_hub" };
    const user_id = switch (job.recipient) {
        .user => |id| id,
        // A bare address is a hub channel name.
        .address => |a| a.value,
    };
    const hub_channel = if (job.recipient == .address)
        user_id
    else if (self.options.hub_channel) |map|
        map(ctx.arena, user_id) catch |err| return .{ .retry = .{ .reason = @errorName(err) } }
    else
        std.fmt.allocPrint(ctx.arena, "user:{s}", .{user_id}) catch return .{ .retry = .{ .reason = "out_of_memory" } };
    if (hub_channel.len == 0) return .{ .skipped = "no_hub_channel" };
    const body = payload(ctx.arena, self.options, job) catch return .{ .retry = .{ .reason = "out_of_memory" } };
    // The JSON is already built: emitHtmlTo sends it as is. JSON has no raw
    // line breaks, so this is the same single `data:` line emitTo writes.
    hub.emitHtmlTo(hub_channel, self.options.event, body);
    return .sent;
}

test "payload: content or ids only, valid JSON with quotes and new lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const job: ch.Job = .{
        .delivery_id = "d",
        .message_id = "m1",
        .attempt = 1,
        .recipient = .{ .user = "1" },
        .notification = .{ .kind = "k", .title = "Say \"hi\"", .body = "a\nb", .url = "/x" },
    };
    const full = try payload(a, .{}, &job);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, full, .{});
    try std.testing.expectEqualStrings("Say \"hi\"", v.object.get("title").?.string);
    try std.testing.expectEqualStrings("a\nb", v.object.get("body").?.string);
    const ids = try payload(a, .{ .with_content = false }, &job);
    try std.testing.expectEqualStrings("{\"id\":\"m1\",\"kind\":\"k\"}", ids);
}

fn customPayload(arena: std.mem.Allocator, job: *const ch.Job) anyerror![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{ .order_id = job.notification.url }, .{});
}

test "payload: an app's own builder replaces the default shapes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const job: ch.Job = .{ .delivery_id = "d", .message_id = "m1", .attempt = 1, .recipient = .{ .user = "1" }, .notification = .{ .kind = "k", .title = "t", .url = "42" } };
    try std.testing.expectEqualStrings("{\"order_id\":\"42\"}", try payload(arena_state.allocator(), .{ .payload = customPayload }, &job));
}

test "deliver: skipped without a hub" {
    var state: Sse = .{};
    const c = state.channel();
    try ch.validate(c);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const ctx: ch.DeliveryContext = .{ .arena = arena_state.allocator(), .io = undefined, .hub = null, .address_book = @import("../address_book.zig").empty };
    const job: ch.Job = .{ .delivery_id = "d", .message_id = "m", .attempt = 1, .recipient = .{ .user = "1" }, .notification = .{ .kind = "k", .title = "t" } };
    try std.testing.expectEqualStrings("no_hub", c.deliver.?(c.ptr, &ctx, &job).skipped);
}

fn mapToSub(arena: std.mem.Allocator, user_id: []const u8) anyerror![]const u8 {
    return std.fmt.allocPrint(arena, "user:sub-of-{s}", .{user_id});
}

test "deliver: emits on the user's hub channel, recorded for replay" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var hub = spider.Hub.init(std.testing.allocator, threaded.io());
    defer hub.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ctx: ch.DeliveryContext = .{ .arena = a, .io = threaded.io(), .hub = &hub, .address_book = @import("../address_book.zig").empty };
    const job: ch.Job = .{ .delivery_id = "d", .message_id = "m1", .attempt = 1, .recipient = .{ .user = "7" }, .notification = .{ .kind = "k", .title = "T" } };

    var plain: Sse = .{};
    const c1 = plain.channel();
    try std.testing.expect(c1.deliver.?(c1.ptr, &ctx, &job) == .sent);
    const h1 = try hub.historySince(a, "user:7", 0);
    try std.testing.expectEqual(@as(usize, 1), h1.len);
    try std.testing.expectEqualStrings("notification", h1[0].event);
    try std.testing.expect(std.mem.indexOf(u8, h1[0].data, "\"title\":\"T\"") != null);

    var mapped: Sse = .{ .options = .{ .event = "notification_created", .hub_channel = mapToSub } };
    const c2 = mapped.channel();
    try std.testing.expect(c2.deliver.?(c2.ptr, &ctx, &job) == .sent);
    const h2 = try hub.historySince(a, "user:sub-of-7", 0);
    try std.testing.expectEqual(@as(usize, 1), h2.len);
    try std.testing.expectEqualStrings("notification_created", h2[0].event);
}
