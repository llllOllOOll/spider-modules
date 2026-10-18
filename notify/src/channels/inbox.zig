//! The `inbox` channel: the in-app notification list (a bell), in the
//! module's `notify_inbox` table. Inline: the row is written inside `send`,
//! in the caller's transaction. Reading and marking as read are functions of
//! this file, for the app's views.

const std = @import("std");
const spider = @import("spider");
const channel = @import("../channel.zig");

const pg = spider.pg;

/// The `inbox` channel. Users only: a bare-address recipient makes `send`
/// fail with `error.InboxNeedsUser`.
///
/// ```zig
/// .channels = &.{ notify.channels.inbox(), ... },
/// ```
pub fn inbox() channel.Channel {
    return .{ .name = "inbox", .mode = .inline_write, .write_inline = write };
}

fn write(_: ?*anyopaque, tx: *pg.Transaction, arena: std.mem.Allocator, job: *const channel.Job) anyerror!void {
    const user_id = switch (job.recipient) {
        .user => |id| id,
        .address => return error.InboxNeedsUser,
    };
    try tx.query(void, arena,
        \\INSERT INTO notify_inbox (user_id, message_id) VALUES ($1, $2::uuid)
        \\ON CONFLICT (user_id, message_id) DO NOTHING
    , .{ user_id, job.message_id });
}

/// One notification of a user's inbox.
pub const Item = struct {
    /// The inbox row's id: what `markRead` takes.
    id: []const u8,
    kind: []const u8,
    title: []const u8,
    body: []const u8,
    url: []const u8,
    icon: []const u8,
    /// The notification's `data_json`.
    data: []const u8,
    /// ISO 8601, in the database's time zone.
    created_at: []const u8,
    /// Null while unread.
    read_at: ?[]const u8,
};

/// The latest `limit` (1 to 200) notifications of a user, newest first,
/// read or not, from the last `days` days.
pub fn recent(arena: std.mem.Allocator, user_id: []const u8, limit: u32, days: u32) ![]const Item {
    return pg.query(Item, arena,
        \\SELECT i.id::text AS id, m.kind, m.title, m.body, m.url, m.icon, m.data::text AS data,
        \\       to_char(i.created_at, 'YYYY-MM-DD"T"HH24:MI:SSOF') AS created_at,
        \\       to_char(i.read_at, 'YYYY-MM-DD"T"HH24:MI:SSOF') AS read_at
        \\  FROM notify_inbox i
        \\  JOIN notify_messages m ON m.id = i.message_id
        \\ WHERE i.user_id = $1 AND i.created_at > now() - make_interval(days => $3)
        \\ ORDER BY i.created_at DESC, i.id
        \\ LIMIT $2
    , .{ user_id, @as(i64, std.math.clamp(limit, 1, 200)), @as(i32, @intCast(@min(days, 3650))) });
}

/// How many unread notifications a user has.
pub fn unreadCount(arena: std.mem.Allocator, user_id: []const u8) !i64 {
    return pg.query(i64, arena,
        \\SELECT count(*) FROM notify_inbox WHERE user_id = $1 AND read_at IS NULL
    , .{user_id});
}

/// Marks one notification of the user read. False when it is not theirs or
/// does not exist.
pub fn markRead(arena: std.mem.Allocator, user_id: []const u8, item_id: []const u8) !bool {
    const row = try pg.queryOne(struct { id: []const u8 }, arena,
        \\UPDATE notify_inbox SET read_at = coalesce(read_at, now())
        \\ WHERE id = $2::uuid AND user_id = $1
        \\RETURNING id::text AS id
    , .{ user_id, item_id });
    return row != null;
}

/// Marks every notification of the user read. Returns how many were unread.
pub fn markAllRead(arena: std.mem.Allocator, user_id: []const u8) !usize {
    const rows = try pg.query(struct { id: []const u8 }, arena,
        \\UPDATE notify_inbox SET read_at = now()
        \\ WHERE user_id = $1 AND read_at IS NULL
        \\RETURNING id::text AS id
    , .{user_id});
    return rows.len;
}

test "inbox: an inline channel that validates" {
    try channel.validate(inbox());
}
