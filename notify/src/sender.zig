//! Internal: `send` and `sendNow`. Records one notification and its
//! deliveries in the caller's transaction: inline channels write right away,
//! queued ones get a `pending` row for the worker. Re-exported by
//! `notify.zig`, where the API documentation lives.

const std = @import("std");
const spider = @import("spider");
const notification = @import("notification.zig");
const channel_mod = @import("channel.zig");
const registry = @import("registry.zig");

const pg = spider.pg;
const Notification = notification.Notification;
const Recipient = notification.Recipient;

pub const Request = struct {
    notification: Notification,
    recipients: []const Recipient,
    channels: []const []const u8 = &.{},
};

pub const Recorded = struct {
    message_id: []const u8,
    queued: usize,
    written_inline: usize,
    skipped: usize,
};

pub const Sent = union(enum) {
    recorded: Recorded,
    duplicate,
};

pub const max_recipients = 10_000;

pub const SendError = notification.Invalid || error{
    NotInitialized,
    UnknownChannel,
    NoRecipients,
    TooManyRecipients,
};

/// One delivery row to write, before it has an id.
const Row = struct {
    user: []const u8 = "",
    address: []const u8 = "",
    channel: []const u8,
    status: []const u8,
    reason: []const u8 = "",
};

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The request's channels without repeats, each checked against the
/// registry. Done before touching the database.
fn resolveChannels(arena: std.mem.Allocator, reg: *const registry.Registry, names: []const []const u8) ![]const *const channel_mod.Channel {
    var out: std.ArrayList(*const channel_mod.Channel) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for (names) |name| {
        if (!notification.validChannelName(name)) return error.InvalidChannelName;
        if (containsName(seen.items, name)) continue;
        const c = reg.find(name) orelse return error.UnknownChannel;
        try seen.append(arena, name);
        try out.append(arena, c);
    }
    return out.items;
}

/// Validates the request and plans it, without the database: the channels to
/// use and the recipients without repeats. Pure but for the registry.
pub const Plan = struct {
    channels: []const *const channel_mod.Channel,
    users: []const []const u8,
    addresses: []const notification.Address,
};

pub fn plan(arena: std.mem.Allocator, reg: *const registry.Registry, req: Request) !Plan {
    try notification.validate(arena, req.notification);
    if (req.recipients.len == 0) return error.NoRecipients;
    if (req.recipients.len > max_recipients) return error.TooManyRecipients;

    const channels = try resolveChannels(arena, reg, req.channels);

    var users: std.ArrayList([]const u8) = .empty;
    var addresses: std.ArrayList(notification.Address) = .empty;
    for (req.recipients) |r| {
        try notification.validateRecipient(r);
        switch (r) {
            .user => |id| if (!containsName(users.items, id)) try users.append(arena, id),
            .address => |a| {
                if (reg.find(a.channel) == null) return error.UnknownChannel;
                for (addresses.items) |seen| {
                    if (std.mem.eql(u8, seen.channel, a.channel) and std.mem.eql(u8, seen.value, a.value)) break;
                } else try addresses.append(arena, a);
            },
        }
    }
    if (users.items.len > 0 and channels.len == 0) return error.UnknownChannel;
    return .{ .channels = channels, .users = users.items, .addresses = addresses.items };
}

pub fn send(tx: *pg.Transaction, arena: std.mem.Allocator, req: Request) !Sent {
    const reg = registry.get() orelse return error.NotInitialized;
    const p = try plan(arena, reg, req);
    const n = req.notification;

    const inserted = try tx.queryOne(struct { id: []const u8 }, arena,
        \\INSERT INTO notify_messages (kind, scope, title, body, url, icon, data, dedup_key)
        \\VALUES ($1, NULLIF($2, ''), $3, $4, $5, $6, $7::jsonb, NULLIF($8, ''))
        \\ON CONFLICT (dedup_key) DO NOTHING
        \\RETURNING id::text AS id
    , .{ n.kind, n.scope orelse "", n.title, n.body, n.url, n.icon, n.data_json, n.dedup_key orelse "" });
    const message_id = (inserted orelse return .duplicate).id;

    var rows: std.ArrayList(Row) = .empty;
    var recorded: Recorded = .{ .message_id = message_id, .queued = 0, .written_inline = 0, .skipped = 0 };

    for (p.users) |user| {
        for (p.channels) |c| {
            if (!reg.preferences.check(arena, user, n.kind, c.name)) {
                try rows.append(arena, .{ .user = user, .channel = c.name, .status = "skipped", .reason = "preference" });
                recorded.skipped += 1;
                continue;
            }
            try rows.append(arena, try deliverOrQueue(tx, arena, c, message_id, .{ .user = user }, n, &recorded));
        }
    }
    for (p.addresses) |a| {
        const c = reg.find(a.channel).?;
        try rows.append(arena, try deliverOrQueue(tx, arena, c, message_id, .{ .address = a }, n, &recorded));
    }

    try insertRows(tx, arena, message_id, rows.items);
    return .{ .recorded = recorded };
}

fn deliverOrQueue(
    tx: *pg.Transaction,
    arena: std.mem.Allocator,
    c: *const channel_mod.Channel,
    message_id: []const u8,
    recipient: Recipient,
    n: Notification,
    recorded: *Recorded,
) !Row {
    var row: Row = .{ .channel = c.name, .status = "pending" };
    switch (recipient) {
        .user => |id| row.user = id,
        .address => |a| row.address = a.value,
    }
    switch (c.mode) {
        .queued => recorded.queued += 1,
        .inline_write => {
            const job: channel_mod.Job = .{ .delivery_id = "", .message_id = message_id, .attempt = 1, .recipient = recipient, .notification = n };
            try c.write_inline.?(c.ptr, tx, arena, &job);
            row.status = "sent";
            recorded.written_inline += 1;
        },
    }
    return row;
}

fn insertRows(tx: *pg.Transaction, arena: std.mem.Allocator, message_id: []const u8, rows: []const Row) !void {
    if (rows.len == 0) return;
    const users = try arena.alloc([]const u8, rows.len);
    const addresses = try arena.alloc([]const u8, rows.len);
    const channels = try arena.alloc([]const u8, rows.len);
    const statuses = try arena.alloc([]const u8, rows.len);
    const reasons = try arena.alloc([]const u8, rows.len);
    for (rows, 0..) |r, i| {
        users[i] = r.user;
        addresses[i] = r.address;
        channels[i] = r.channel;
        statuses[i] = r.status;
        reasons[i] = r.reason;
    }
    try tx.query(void, arena,
        \\INSERT INTO notify_deliveries
        \\  (message_id, recipient_user, recipient_address, channel, status, last_error, delivered_at)
        \\SELECT $1::uuid, NULLIF(u, ''), NULLIF(a, ''), c, s, NULLIF(r, ''),
        \\       CASE WHEN s = 'sent' THEN now() END
        \\  FROM unnest($2::text[], $3::text[], $4::text[], $5::text[], $6::text[]) AS t(u, a, c, s, r)
    , .{ message_id, users, addresses, channels, statuses, reasons });
}

pub fn sendNow(arena: std.mem.Allocator, req: Request) !Sent {
    var tx = try pg.begin();
    defer tx.rollback();
    const result = try send(&tx, arena, req);
    try tx.commit();
    return result;
}

// ── tests (no database) ─────────────────────────────────────────────────

fn deliverNothing(_: ?*anyopaque, _: *const channel_mod.DeliveryContext, _: *const channel_mod.Job) channel_mod.Outcome {
    return .sent;
}

fn writeNothing(_: ?*anyopaque, _: *pg.Transaction, _: std.mem.Allocator, _: *const channel_mod.Job) anyerror!void {}

fn testRegistry() !void {
    try registry.init(std.testing.allocator, .{ .channels = &.{
        .{ .name = "inbox", .mode = .inline_write, .write_inline = writeNothing },
        .{ .name = "sse", .deliver = deliverNothing },
        .{ .name = "whatsapp", .deliver = deliverNothing },
    } });
}

test "plan: drops repeated channels and recipients" {
    try testRegistry();
    defer registry.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try plan(arena_state.allocator(), registry.get().?, .{
        .notification = .{ .kind = "k", .title = "t" },
        .recipients = &.{
            .{ .user = "1" },                                            .{ .user = "1" },                                            .{ .user = "2" },
            .{ .address = .{ .channel = "whatsapp", .value = "5511" } }, .{ .address = .{ .channel = "whatsapp", .value = "5511" } },
        },
        .channels = &.{ "sse", "inbox", "sse" },
    });
    try std.testing.expectEqual(@as(usize, 2), p.channels.len);
    try std.testing.expectEqual(@as(usize, 2), p.users.len);
    try std.testing.expectEqual(@as(usize, 1), p.addresses.len);
}

test "plan: refuses unknown channels, no recipients, users without channels" {
    try testRegistry();
    defer registry.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const reg = registry.get().?;
    const n: Notification = .{ .kind = "k", .title = "t" };
    try std.testing.expectError(error.UnknownChannel, plan(a, reg, .{ .notification = n, .recipients = &.{.{ .user = "1" }}, .channels = &.{"email"} }));
    try std.testing.expectError(error.UnknownChannel, plan(a, reg, .{ .notification = n, .recipients = &.{.{ .user = "1" }} }));
    try std.testing.expectError(error.UnknownChannel, plan(a, reg, .{ .notification = n, .recipients = &.{.{ .address = .{ .channel = "sms", .value = "1" } }} }));
    try std.testing.expectError(error.NoRecipients, plan(a, reg, .{ .notification = n, .recipients = &.{}, .channels = &.{"sse"} }));
    try std.testing.expectError(error.InvalidChannelName, plan(a, reg, .{ .notification = n, .recipients = &.{.{ .user = "1" }}, .channels = &.{"Sse"} }));
    try std.testing.expectError(error.InvalidTitle, plan(a, reg, .{ .notification = .{ .kind = "k", .title = "" }, .recipients = &.{.{ .user = "1" }}, .channels = &.{"sse"} }));
    // An address alone needs no channel list.
    _ = try plan(a, reg, .{ .notification = n, .recipients = &.{.{ .address = .{ .channel = "whatsapp", .value = "1" } }} });
}

test "send: refuses before init" {
    try std.testing.expect(registry.get() == null);
}
