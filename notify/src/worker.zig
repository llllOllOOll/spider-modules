//! Internal: the worker. One tick, for each queued channel (or one channel):
//!
//!   1. expire  — pending deliveries older than the channel's `max_age_ms`;
//!   2. reclaim — deliveries whose lease ran out while `sending` (a worker
//!                died mid-delivery) go back to `pending`;
//!   3. exhaust — pending deliveries that already used `max_attempts` fail;
//!   4. claim   — up to `batch` due rows, `FOR UPDATE SKIP LOCKED`, so two
//!                workers (two processes) never take the same row;
//!   5. deliver and record — each outcome is written only if the row is
//!                still this worker's (same attempt number, still
//!                `sending`): a worker whose lease expired cannot overwrite
//!                the one that took over.
//!
//! Re-exported by `notify.zig`, where the API documentation lives.

const std = @import("std");
const spider = @import("spider");
const notification = @import("notification.zig");
const channel_mod = @import("channel.zig");
const backoff = @import("backoff.zig");
const registry = @import("registry.zig");

const pg = spider.pg;
const Channel = channel_mod.Channel;

pub const Stats = struct {
    expired: usize = 0,
    reclaimed: usize = 0,
    exhausted: usize = 0,
    claimed: usize = 0,
    sent: usize = 0,
    retried: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    /// Outcomes not written because the lease had already passed to
    /// another worker.
    lost: usize = 0,

    fn add(self: *Stats, o: Stats) void {
        inline for (@typeInfo(Stats).@"struct".field_names) |f| @field(self, f) += @field(o, f);
    }
};

/// A claimed row, with the content of its notification.
const Claimed = struct {
    id: []const u8,
    message_id: []const u8,
    recipient_user: ?[]const u8,
    recipient_address: ?[]const u8,
    channel: []const u8,
    attempts: i32,
    kind: []const u8,
    scope: ?[]const u8,
    title: []const u8,
    body: []const u8,
    url: []const u8,
    icon: []const u8,
    data: []const u8,
    dedup_key: ?[]const u8,
};

pub const TickError = error{ NotInitialized, UnknownChannel };

/// One tick over every queued channel, or only `only` when given.
pub fn tick(arena: std.mem.Allocator, io: std.Io, hub: ?*spider.Hub, only: ?[]const u8) !Stats {
    const reg = registry.get() orelse return error.NotInitialized;
    var total: Stats = .{};
    if (only) |name| {
        const c = reg.find(name) orelse return error.UnknownChannel;
        if (c.mode == .queued) total.add(try tickChannel(arena, io, hub, reg, c));
        return total;
    }
    for (reg.channels) |*c| {
        if (c.mode != .queued) continue;
        // One channel's database trouble does not stop the others.
        const s = tickChannel(arena, io, hub, reg, c) catch |err| {
            std.log.warn("notify: channel {s}: tick failed ({s})", .{ c.name, @errorName(err) });
            continue;
        };
        total.add(s);
    }
    return total;
}

fn countOf(rows: anytype) usize {
    return rows.len;
}

fn tickChannel(arena: std.mem.Allocator, io: std.Io, hub: ?*spider.Hub, reg: *const registry.Registry, c: *const Channel) !Stats {
    var s: Stats = .{};
    const Id = struct { id: []const u8 };

    s.expired = countOf(try pg.query(Id, arena,
        \\UPDATE notify_deliveries
        \\   SET status = 'expired', last_error = 'expired'
        \\ WHERE channel = $1 AND status = 'pending'
        \\   AND created_at < now() - ($2::bigint * interval '1 millisecond')
        \\RETURNING id::text AS id
    , .{ c.name, @as(i64, @intCast(c.max_age_ms)) }));

    s.reclaimed = countOf(try pg.query(Id, arena,
        \\UPDATE notify_deliveries
        \\   SET status = 'pending', lease_until = NULL, last_error = 'lease_expired'
        \\ WHERE channel = $1 AND status = 'sending' AND lease_until < now()
        \\RETURNING id::text AS id
    , .{c.name}));

    s.exhausted = countOf(try pg.query(Id, arena,
        \\UPDATE notify_deliveries
        \\   SET status = 'failed', last_error = coalesce(last_error, 'attempts_exhausted')
        \\ WHERE channel = $1 AND status = 'pending' AND attempts >= $2
        \\RETURNING id::text AS id
    , .{ c.name, @as(i32, c.max_attempts) }));

    const claimed = try pg.query(Claimed, arena,
        \\WITH due AS (
        \\  SELECT id FROM notify_deliveries
        \\   WHERE channel = $1 AND status = 'pending' AND next_attempt_at <= now() AND attempts < $3
        \\   ORDER BY next_attempt_at
        \\   LIMIT $2
        \\   FOR UPDATE SKIP LOCKED
        \\)
        \\UPDATE notify_deliveries d
        \\   SET status = 'sending', attempts = d.attempts + 1,
        \\       lease_until = now() + ($4::bigint * interval '1 millisecond')
        \\  FROM due, notify_messages m
        \\ WHERE d.id = due.id AND m.id = d.message_id
        \\RETURNING d.id::text AS id, d.message_id::text AS message_id, d.recipient_user, d.recipient_address,
        \\          d.channel, d.attempts, m.kind, m.scope, m.title, m.body, m.url, m.icon,
        \\          m.data::text AS data, m.dedup_key
    , .{ c.name, @as(i32, c.batch), @as(i32, c.max_attempts), @as(i64, @intCast(c.lease_ms)) });
    s.claimed = claimed.len;

    const ctx: channel_mod.DeliveryContext = .{ .arena = arena, .io = io, .hub = hub, .address_book = reg.address_book };
    for (claimed) |row| {
        const job = jobOf(row);
        const outcome = c.deliver.?(c.ptr, &ctx, &job);
        const plan = decide(c, row.id, job.attempt, outcome);
        switch (plan.status) {
            .sent => s.sent += 1,
            .pending => s.retried += 1,
            .failed => s.failed += 1,
            .skipped => s.skipped += 1,
        }
        if (!try record(arena, row.id, job.attempt, plan)) s.lost += 1;
    }
    return s;
}

fn jobOf(row: Claimed) channel_mod.Job {
    const recipient: notification.Recipient = if (row.recipient_user) |u|
        .{ .user = u }
    else
        .{ .address = .{ .channel = row.channel, .value = row.recipient_address orelse "" } };
    return .{
        .delivery_id = row.id,
        .message_id = row.message_id,
        .attempt = @intCast(@max(row.attempts, 1)),
        .recipient = recipient,
        .notification = .{
            .kind = row.kind,
            .title = row.title,
            .body = row.body,
            .url = row.url,
            .icon = row.icon,
            .scope = row.scope,
            .data_json = row.data,
            .dedup_key = row.dedup_key,
        },
    };
}

pub const Status = enum { sent, pending, failed, skipped };

/// What to write for one outcome. Pure: the tests check the schedule here.
pub const Plan = struct {
    status: Status,
    reason: []const u8 = "",
    /// For `pending`: wait this long before the next attempt.
    delay_ms: u64 = 0,
};

/// A number in [0, 1) from the delivery and the attempt: the jitter of the
/// backoff, spread across deliveries but the same for the same retry.
pub fn jitter(delivery_id: []const u8, attempt: u32) f64 {
    var h = std.hash.Wyhash.init(attempt);
    h.update(delivery_id);
    const bits: u53 = @truncate(h.final());
    return @as(f64, @floatFromInt(bits)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

pub fn decide(c: *const Channel, delivery_id: []const u8, attempt: u32, outcome: channel_mod.Outcome) Plan {
    return switch (outcome) {
        .sent => .{ .status = .sent },
        .skipped => |reason| .{ .status = .skipped, .reason = channel_mod.clipReason(reason) },
        .failed => |f| .{ .status = .failed, .reason = channel_mod.clipReason(f.reason) },
        .retry => |f| blk: {
            if (attempt >= c.max_attempts) break :blk .{ .status = .failed, .reason = channel_mod.clipReason(f.reason) };
            const wait = backoff.delayMs(c.backoff, attempt, jitter(delivery_id, attempt));
            break :blk .{
                .status = .pending,
                .reason = channel_mod.clipReason(f.reason),
                .delay_ms = @max(wait, f.retry_after_ms orelse 0),
            };
        },
    };
}

/// Writes the outcome if the row is still this attempt's. False when the
/// lease had passed to another worker.
fn record(arena: std.mem.Allocator, id: []const u8, attempt: u32, plan: Plan) !bool {
    const row = try pg.queryOne(struct { id: []const u8 }, arena,
        \\UPDATE notify_deliveries
        \\   SET status = $3, lease_until = NULL,
        \\       last_error = NULLIF($4, ''),
        \\       delivered_at = CASE WHEN $3 = 'sent' THEN now() ELSE delivered_at END,
        \\       next_attempt_at = CASE WHEN $3 = 'pending'
        \\                              THEN now() + ($5::bigint * interval '1 millisecond')
        \\                              ELSE next_attempt_at END
        \\ WHERE id = $1::uuid AND status = 'sending' AND attempts = $2
        \\RETURNING id::text AS id
    , .{ id, @as(i32, @intCast(attempt)), @tagName(plan.status), plan.reason, @as(i64, @intCast(@min(plan.delay_ms, std.math.maxInt(i64)))) });
    return row != null;
}

/// Runs one tick with its own `Io` and arena, logging instead of failing:
/// what `notify.job` and `notify.jobFor` call from a Spider job.
pub fn runTick(hub: ?*spider.Hub, only: ?[]const u8) void {
    // A real allocator behind the Io: HTTP clients and process spawns
    // allocate through it.
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    _ = tick(arena_state.allocator(), threaded.io(), hub, only) catch |err| {
        std.log.warn("notify: tick failed ({s})", .{@errorName(err)});
    };
}

// ── tests (no database) ─────────────────────────────────────────────────

fn deliverNothing(_: ?*anyopaque, _: *const channel_mod.DeliveryContext, _: *const channel_mod.Job) channel_mod.Outcome {
    return .sent;
}

test "decide: sent, skipped and failed are final" {
    const c: Channel = .{ .name = "sse", .deliver = deliverNothing };
    try std.testing.expectEqual(Status.sent, decide(&c, "d", 1, .sent).status);
    const sk = decide(&c, "d", 1, .{ .skipped = "no_address" });
    try std.testing.expectEqual(Status.skipped, sk.status);
    try std.testing.expectEqualStrings("no_address", sk.reason);
    try std.testing.expectEqual(Status.failed, decide(&c, "d", 1, .{ .failed = .{ .reason = "http_400" } }).status);
}

test "decide: retry backs off, honours retry_after, and fails at max_attempts" {
    const c: Channel = .{ .name = "sse", .deliver = deliverNothing, .max_attempts = 3, .backoff = .{ .base_ms = 1000, .max_ms = 60_000 } };
    const first = decide(&c, "d", 1, .{ .retry = .{ .reason = "http_503" } });
    try std.testing.expectEqual(Status.pending, first.status);
    try std.testing.expect(first.delay_ms >= 500 and first.delay_ms <= 1000);
    const second = decide(&c, "d", 2, .{ .retry = .{ .reason = "http_503" } });
    try std.testing.expect(second.delay_ms >= 1000 and second.delay_ms <= 2000);
    const told = decide(&c, "d", 1, .{ .retry = .{ .reason = "http_429", .retry_after_ms = 45_000 } });
    try std.testing.expectEqual(@as(u64, 45_000), told.delay_ms);
    const last = decide(&c, "d", 3, .{ .retry = .{ .reason = "http_503" } });
    try std.testing.expectEqual(Status.failed, last.status);
    try std.testing.expectEqualStrings("http_503", last.reason);
}

test "jitter: in [0, 1), stable for a retry, different across deliveries" {
    const a = jitter("a", 1);
    try std.testing.expect(a >= 0 and a < 1);
    try std.testing.expectEqual(a, jitter("a", 1));
    try std.testing.expect(a != jitter("b", 1));
    try std.testing.expect(a != jitter("a", 2));
}
