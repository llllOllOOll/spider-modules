//! Database tests of spider_notify: send, deduplication, preferences, the
//! inline inbox, and the worker (claim, retry, backoff, exhaustion, lease
//! expiry, fencing, expiry by age, per-channel isolation, SKIP LOCKED).
//!
//! Needs a DISPOSABLE Postgres with only the module's tables. The tests
//! TRUNCATE them, so they refuse any database not named `notify_test`.
//!
//!   modules/notify/scripts/test-db.sh      # starts one, runs, removes it
//!
//! Connection: NOTIFY_PG_HOST/PORT/USER/PASSWORD/DB.

const std = @import("std");
const spider = @import("spider");
const notify = @import("spider_notify");

const pg = spider.pg;

// ── setup ───────────────────────────────────────────────────────────────

var threaded: ?std.Io.Threaded = null;
var connected = false;

fn envOr(key: [:0]const u8, default: []const u8) []const u8 {
    const v = std.c.getenv(key) orelse return default;
    return std.mem.span(v);
}

fn connect() !void {
    if (connected) return;
    const db = envOr("NOTIFY_PG_DB", "notify_test");
    if (!std.mem.eql(u8, db, "notify_test")) return error.NotADisposableDatabase;
    threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    try pg.init(std.heap.smp_allocator, threaded.?.io(), .{
        .host = envOr("NOTIFY_PG_HOST", "127.0.0.1"),
        .port = std.fmt.parseInt(u16, envOr("NOTIFY_PG_PORT", "5437"), 10) catch 5437,
        .user = envOr("NOTIFY_PG_USER", "notify"),
        .password = envOr("NOTIFY_PG_PASSWORD", "notify"),
        .database = db,
        .pool_size = 6,
    });
    connected = true;
}

/// What the fake channels answer, in order; the last answer repeats.
const Script = struct {
    answers: []const notify.Outcome = &.{.sent},
    calls: usize = 0,
    /// Run inside deliver, before answering (to simulate another worker).
    during: ?*const fn (job: *const notify.Job) void = null,

    fn next(self: *Script) notify.Outcome {
        const i = @min(self.calls, self.answers.len - 1);
        self.calls += 1;
        return self.answers[i];
    }
};

var script_a: Script = .{};
var script_b: Script = .{};

fn deliverA(_: ?*anyopaque, _: *const notify.DeliveryContext, job: *const notify.Job) notify.Outcome {
    if (script_a.during) |f| f(job);
    return script_a.next();
}

fn deliverB(_: ?*anyopaque, _: *const notify.DeliveryContext, _: *const notify.Job) notify.Outcome {
    return script_b.next();
}

var refuse_user: []const u8 = "";

fn prefs(_: ?*anyopaque, _: std.mem.Allocator, user_id: []const u8, _: []const u8, channel: []const u8) anyerror!bool {
    return !(std.mem.eql(u8, user_id, refuse_user) and std.mem.eql(u8, channel, "a"));
}

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,

    fn arena(self: *Fixture) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    fn deinit(self: *Fixture) void {
        notify.deinit();
        self.arena_state.deinit();
    }
};

/// Empty tables, fresh scripts, channels `inbox` (inline), `a` and `b`.
fn fixture(a_limits: notify.Channel) !Fixture {
    try connect();
    var f: Fixture = .{ .arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator) };
    try pg.query(void, f.arena(), "TRUNCATE notify_inbox, notify_deliveries, notify_messages, notify_addresses", .{});
    script_a = .{};
    script_b = .{};
    refuse_user = "";
    var a = a_limits;
    a.name = "a";
    a.deliver = deliverA;
    try notify.init(std.heap.smp_allocator, .{
        .channels = &.{ notify.channels.inbox(), a, .{ .name = "b", .deliver = deliverB } },
        .preferences = .{ .allows = prefs },
    });
    return f;
}

fn tick(f: *Fixture, only: ?[]const u8) !notify.TickStats {
    return notify.tick(f.arena(), threaded.?.io(), null, only);
}

const Row = struct { status: []const u8, attempts: i32, last_error: ?[]const u8 };

fn deliveriesOf(f: *Fixture, channel: []const u8) ![]const Row {
    return pg.query(Row, f.arena(),
        \\SELECT status, attempts, last_error FROM notify_deliveries WHERE channel = $1 ORDER BY created_at, id
    , .{channel});
}

fn count(f: *Fixture, sql: []const u8) !i64 {
    return pg.query(i64, f.arena(), sql, .{});
}

fn simple(kind: []const u8, users: []const notify.Recipient, channels: []const []const u8) notify.Request {
    return .{ .notification = .{ .kind = kind, .title = "Title" }, .recipients = users, .channels = channels };
}

/// Makes every pending delivery due now (instead of waiting the backoff).
fn makeDue(f: *Fixture) !void {
    try pg.query(void, f.arena(), "UPDATE notify_deliveries SET next_attempt_at = now() WHERE status = 'pending'", .{});
}

// ── send ────────────────────────────────────────────────────────────────

test "send: nothing is recorded when the caller's transaction rolls back" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    {
        var tx = try pg.begin();
        defer tx.rollback();
        _ = try notify.send(&tx, f.arena(), simple("k", &.{.{ .user = "1" }}, &.{ "inbox", "a" }));
    }
    try std.testing.expectEqual(@as(i64, 0), try count(&f, "SELECT count(*) FROM notify_messages"));
    try std.testing.expectEqual(@as(i64, 0), try count(&f, "SELECT count(*) FROM notify_inbox"));
}

test "send: inline written and sent, queued pending, per user and channel" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    const r = try notify.sendNow(f.arena(), simple("k", &.{ .{ .user = "1" }, .{ .user = "2" } }, &.{ "inbox", "a", "b" }));
    try std.testing.expectEqual(@as(usize, 2), r.recorded.written_inline);
    try std.testing.expectEqual(@as(usize, 4), r.recorded.queued);
    try std.testing.expectEqual(@as(i64, 2), try count(&f, "SELECT count(*) FROM notify_inbox"));
    try std.testing.expectEqual(@as(i64, 2), try count(&f, "SELECT count(*) FROM notify_deliveries WHERE channel = 'inbox' AND status = 'sent' AND delivered_at IS NOT NULL"));
    try std.testing.expectEqual(@as(i64, 4), try count(&f, "SELECT count(*) FROM notify_deliveries WHERE status = 'pending'"));
}

test "send: an address recipient goes only to its own channel" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    const r = try notify.sendNow(f.arena(), .{
        .notification = .{ .kind = "k", .title = "t" },
        .recipients = &.{.{ .address = .{ .channel = "b", .value = "5511999998888" } }},
        .channels = &.{ "inbox", "a" },
    });
    try std.testing.expectEqual(@as(usize, 1), r.recorded.queued);
    try std.testing.expectEqual(@as(i64, 1), try count(&f, "SELECT count(*) FROM notify_deliveries WHERE channel = 'b' AND recipient_address = '5511999998888' AND recipient_user IS NULL"));
}

test "send: a dedup key records once; the second send is a duplicate" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    var req = simple("k", &.{.{ .user = "1" }}, &.{"a"});
    req.notification.dedup_key = "quota_95:t1:2026-10";
    try std.testing.expect(try notify.sendNow(f.arena(), req) == .recorded);
    try std.testing.expect(try notify.sendNow(f.arena(), req) == .duplicate);
    try std.testing.expectEqual(@as(i64, 1), try count(&f, "SELECT count(*) FROM notify_deliveries"));
}

const RaceArgs = struct { result: ?notify.Sent = null, err: ?anyerror = null };

fn sendInThread(args: *RaceArgs) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    var req = simple("k", &.{.{ .user = "2" }}, &.{"a"});
    req.notification.dedup_key = "race";
    args.result = notify.sendNow(arena_state.allocator(), req) catch |err| {
        args.err = err;
        return;
    };
}

test "send: two concurrent sends with one key — the database lets one through" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    var tx = try pg.begin();
    defer tx.rollback();
    var req = simple("k", &.{.{ .user = "1" }}, &.{"a"});
    req.notification.dedup_key = "race";
    try std.testing.expect(try notify.send(&tx, f.arena(), req) == .recorded);

    // The second send waits on the first transaction's uncommitted key.
    var args: RaceArgs = .{};
    const t = try std.Thread.spawn(.{}, sendInThread, .{&args});
    var io_threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer io_threaded.deinit();
    std.Io.sleep(io_threaded.io(), .fromMilliseconds(300), .awake) catch {};
    try tx.commit();
    t.join();

    try std.testing.expect(args.err == null);
    try std.testing.expect(args.result.? == .duplicate);
    try std.testing.expectEqual(@as(i64, 1), try count(&f, "SELECT count(*) FROM notify_messages"));
}

test "send: a preference refused is recorded as skipped, not queued" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    refuse_user = "1";
    const r = try notify.sendNow(f.arena(), simple("k", &.{ .{ .user = "1" }, .{ .user = "2" } }, &.{"a"}));
    try std.testing.expectEqual(@as(usize, 1), r.recorded.skipped);
    try std.testing.expectEqual(@as(usize, 1), r.recorded.queued);
    try std.testing.expectEqual(@as(i64, 1), try count(&f, "SELECT count(*) FROM notify_deliveries WHERE status = 'skipped' AND last_error = 'preference' AND recipient_user = '1'"));
}

test "send: data and content round-trip to the channel" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    script_a.during = struct {
        fn check(job: *const notify.Job) void {
            std.debug.assert(std.mem.eql(u8, job.notification.title, "Olá \"mundo\""));
            std.debug.assert(std.mem.eql(u8, job.notification.scope.?, "tenant-1"));
            std.debug.assert(std.mem.indexOf(u8, job.notification.data_json, "\"percent\"") != null);
            std.debug.assert(job.attempt == 1);
        }
    }.check;
    _ = try notify.sendNow(f.arena(), .{
        .notification = .{ .kind = "k", .title = "Olá \"mundo\"", .scope = "tenant-1", .data_json = "{\"percent\": 95}" },
        .recipients = &.{.{ .user = "1" }},
        .channels = &.{"a"},
    });
    const s = try tick(&f, "a");
    try std.testing.expectEqual(@as(usize, 1), s.sent);
}

// ── worker ──────────────────────────────────────────────────────────────

test "worker: sent is recorded with delivered_at" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{"a"}));
    const s = try tick(&f, null);
    try std.testing.expectEqual(@as(usize, 1), s.claimed);
    try std.testing.expectEqual(@as(usize, 1), s.sent);
    try std.testing.expectEqual(@as(i64, 1), try count(&f, "SELECT count(*) FROM notify_deliveries WHERE status = 'sent' AND delivered_at IS NOT NULL AND lease_until IS NULL AND attempts = 1"));
    // Nothing left: the next tick claims nothing.
    try std.testing.expectEqual(@as(usize, 0), (try tick(&f, null)).claimed);
}

test "worker: retry waits the backoff, then succeeds" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    script_a.answers = &.{ .{ .retry = .{ .reason = "http_503" } }, .sent };
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{"a"}));

    try std.testing.expectEqual(@as(usize, 1), (try tick(&f, "a")).retried);
    var rows = try deliveriesOf(&f, "a");
    try std.testing.expectEqualStrings("pending", rows[0].status);
    try std.testing.expectEqualStrings("http_503", rows[0].last_error.?);
    try std.testing.expectEqual(@as(i64, 1), try count(&f, "SELECT count(*) FROM notify_deliveries WHERE next_attempt_at > now()"));

    // Not due yet: not claimed.
    try std.testing.expectEqual(@as(usize, 0), (try tick(&f, "a")).claimed);
    try makeDue(&f);
    try std.testing.expectEqual(@as(usize, 1), (try tick(&f, "a")).sent);
    rows = try deliveriesOf(&f, "a");
    try std.testing.expectEqualStrings("sent", rows[0].status);
    try std.testing.expectEqual(@as(i32, 2), rows[0].attempts);
    try std.testing.expect(rows[0].last_error == null);
}

test "worker: retries stop at max_attempts" {
    var f = try fixture(.{ .name = "a", .max_attempts = 3 });
    defer f.deinit();
    script_a.answers = &.{.{ .retry = .{ .reason = "http_503" } }};
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{"a"}));
    for (0..5) |_| {
        _ = try tick(&f, "a");
        try makeDue(&f);
    }
    const rows = try deliveriesOf(&f, "a");
    try std.testing.expectEqualStrings("failed", rows[0].status);
    try std.testing.expectEqual(@as(i32, 3), rows[0].attempts);
    try std.testing.expectEqual(@as(usize, 3), script_a.calls);
}

test "worker: failed and skipped are final" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    script_a.answers = &.{ .{ .failed = .{ .reason = "http_400" } }, .{ .skipped = "no_address" } };
    _ = try notify.sendNow(f.arena(), simple("k", &.{ .{ .user = "1" }, .{ .user = "2" } }, &.{"a"}));
    const s = try tick(&f, "a");
    try std.testing.expectEqual(@as(usize, 1), s.failed);
    try std.testing.expectEqual(@as(usize, 1), s.skipped);
    try makeDue(&f);
    try std.testing.expectEqual(@as(usize, 0), (try tick(&f, "a")).claimed);
}

test "worker: a lease that ran out is taken back and delivered" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{"a"}));
    // A worker claimed it and died.
    try pg.query(void, f.arena(), "UPDATE notify_deliveries SET status = 'sending', attempts = 1, lease_until = now() - interval '1 second'", .{});
    const s = try tick(&f, "a");
    try std.testing.expectEqual(@as(usize, 1), s.reclaimed);
    try std.testing.expectEqual(@as(usize, 1), s.sent);
    const rows = try deliveriesOf(&f, "a");
    try std.testing.expectEqual(@as(i32, 2), rows[0].attempts);
}

test "worker: a live lease is left alone" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{"a"}));
    try pg.query(void, f.arena(), "UPDATE notify_deliveries SET status = 'sending', attempts = 1, lease_until = now() + interval '1 minute'", .{});
    const s = try tick(&f, "a");
    try std.testing.expectEqual(@as(usize, 0), s.reclaimed);
    try std.testing.expectEqual(@as(usize, 0), s.claimed);
}

test "worker: a reclaimed delivery that used every attempt fails" {
    var f = try fixture(.{ .name = "a", .max_attempts = 2 });
    defer f.deinit();
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{"a"}));
    try pg.query(void, f.arena(), "UPDATE notify_deliveries SET status = 'sending', attempts = 2, lease_until = now() - interval '1 second'", .{});
    const s = try tick(&f, "a");
    try std.testing.expectEqual(@as(usize, 1), s.exhausted);
    try std.testing.expectEqual(@as(usize, 0), script_a.calls);
    try std.testing.expectEqualStrings("failed", (try deliveriesOf(&f, "a"))[0].status);
}

test "worker: an outcome is not written over a worker that took over (fencing)" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    script_a.during = struct {
        fn takeOver(job: *const notify.Job) void {
            // Another worker re-claimed this delivery meanwhile (attempt 2).
            var a = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer a.deinit();
            pg.query(void, a.allocator(), "UPDATE notify_deliveries SET attempts = attempts + 1 WHERE id = $1::uuid", .{job.delivery_id}) catch unreachable;
        }
    }.takeOver;
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{"a"}));
    const s = try tick(&f, "a");
    try std.testing.expectEqual(@as(usize, 1), s.lost);
    const rows = try deliveriesOf(&f, "a");
    try std.testing.expectEqualStrings("sending", rows[0].status);
}

test "worker: pending older than max_age_ms expires instead of going out" {
    var f = try fixture(.{ .name = "a", .max_age_ms = 60_000 });
    defer f.deinit();
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{"a"}));
    try pg.query(void, f.arena(), "UPDATE notify_deliveries SET created_at = now() - interval '2 minutes'", .{});
    const s = try tick(&f, "a");
    try std.testing.expectEqual(@as(usize, 1), s.expired);
    try std.testing.expectEqual(@as(usize, 0), script_a.calls);
    try std.testing.expectEqualStrings("expired", (try deliveriesOf(&f, "a"))[0].status);
}

test "worker: channels are isolated — one channel's tick leaves the other's rows" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    script_a.answers = &.{.{ .retry = .{ .reason = "down" } }};
    _ = try notify.sendNow(f.arena(), simple("k", &.{.{ .user = "1" }}, &.{ "a", "b" }));
    const sb = try tick(&f, "b");
    try std.testing.expectEqual(@as(usize, 1), sb.sent);
    try std.testing.expectEqual(@as(usize, 0), script_a.calls);
    try std.testing.expectEqualStrings("pending", (try deliveriesOf(&f, "a"))[0].status);
    // The all-channel tick: a keeps failing, b has nothing left.
    const all = try tick(&f, null);
    try std.testing.expectEqual(@as(usize, 1), all.retried);
    try std.testing.expectEqual(@as(usize, 0), all.sent);
}

test "worker: rows locked by another worker are skipped (SKIP LOCKED)" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    _ = try notify.sendNow(f.arena(), simple("k", &.{ .{ .user = "1" }, .{ .user = "2" } }, &.{"a"}));
    var other = try pg.begin();
    defer other.rollback();
    _ = try other.query(struct { id: []const u8 }, f.arena(),
        \\SELECT id::text AS id FROM notify_deliveries WHERE recipient_user = '1' FOR UPDATE
    , .{});
    const s = try tick(&f, "a");
    try std.testing.expectEqual(@as(usize, 1), s.claimed);
    other.rollback();
    try std.testing.expectEqual(@as(usize, 1), (try tick(&f, "a")).claimed);
}

test "worker: batch limits a tick" {
    var f = try fixture(.{ .name = "a", .batch = 2 });
    defer f.deinit();
    _ = try notify.sendNow(f.arena(), simple("k", &.{ .{ .user = "1" }, .{ .user = "2" }, .{ .user = "3" } }, &.{"a"}));
    try std.testing.expectEqual(@as(usize, 2), (try tick(&f, "a")).claimed);
    try std.testing.expectEqual(@as(usize, 1), (try tick(&f, "a")).claimed);
}

// ── inbox and address book ──────────────────────────────────────────────

test "inbox: recent, unread count, mark read" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    const Inbox = notify.channels.Inbox;
    _ = try notify.sendNow(f.arena(), .{ .notification = .{ .kind = "k", .title = "first" }, .recipients = &.{.{ .user = "1" }}, .channels = &.{"inbox"} });
    _ = try notify.sendNow(f.arena(), .{ .notification = .{ .kind = "k", .title = "second", .url = "/x" }, .recipients = &.{ .{ .user = "1" }, .{ .user = "2" } }, .channels = &.{"inbox"} });
    const items = try Inbox.recent(f.arena(), "1", 10, 30);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("second", items[0].title);
    try std.testing.expectEqual(@as(i64, 2), try Inbox.unreadCount(f.arena(), "1"));
    try std.testing.expect(try Inbox.markRead(f.arena(), "1", items[0].id));
    try std.testing.expect(!try Inbox.markRead(f.arena(), "2", items[1].id)); // not theirs
    try std.testing.expectEqual(@as(i64, 1), try Inbox.unreadCount(f.arena(), "1"));
    try std.testing.expectEqual(@as(usize, 1), try Inbox.markAllRead(f.arena(), "1"));
    try std.testing.expectEqual(@as(i64, 0), try Inbox.unreadCount(f.arena(), "1"));
    try std.testing.expectEqual(@as(i64, 1), try Inbox.unreadCount(f.arena(), "2"));
}

test "inbox: a bare address cannot go to the inbox" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    try std.testing.expectError(error.InboxNeedsUser, notify.sendNow(f.arena(), .{
        .notification = .{ .kind = "k", .title = "t" },
        .recipients = &.{.{ .address = .{ .channel = "inbox", .value = "x" } }},
    }));
    try std.testing.expectEqual(@as(i64, 0), try count(&f, "SELECT count(*) FROM notify_messages"));
}

test "default address book: register, move, lookup, forget" {
    var f = try fixture(.{ .name = "a" });
    defer f.deinit();
    const D = notify.DefaultAddressBook;
    const book = D.book();
    try D.register(f.arena(), "1", "fcm", "tok-1", "Android");
    try D.register(f.arena(), "1", "fcm", "tok-2", "iPhone");
    try std.testing.expectEqual(@as(usize, 2), (try book.find(f.arena(), "fcm", "1")).len);
    // A token that changed hands moves to the new user.
    try D.register(f.arena(), "2", "fcm", "tok-2", "iPhone");
    try std.testing.expectEqual(@as(usize, 1), (try book.find(f.arena(), "fcm", "1")).len);
    try std.testing.expectEqualStrings("tok-2", (try book.find(f.arena(), "fcm", "2"))[0].value);
    try book.remove(f.arena(), "fcm", "tok-1");
    try std.testing.expectEqual(@as(usize, 0), (try book.find(f.arena(), "fcm", "1")).len);
    try D.unregister(f.arena(), "2", "fcm", "tok-2");
    try std.testing.expectEqual(@as(usize, 0), (try book.find(f.arena(), "fcm", "2")).len);
    try std.testing.expectError(error.InvalidChannelName, D.register(f.arena(), "1", "Bad Name", "x", ""));
}
