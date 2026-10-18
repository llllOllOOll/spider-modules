//! notify as a Spider module, end to end against a DISPOSABLE Postgres with
//! no tables at all (scripts/test-db.sh): the server says it is not ready
//! while `notify/0001_init` is pending, `migrateModules` applies it once,
//! the server is then ready, and notify's own check fails when one of its
//! tables cannot be read. Runs before db_test.zig, which uses the tables
//! this migration creates.
//!
//! Connection: NOTIFY_PG_HOST/PORT/USER/PASSWORD/DB (the database must be
//! named `notify_test`).

const std = @import("std");
const spider = @import("spider");
const notify = @import("spider_notify");

const pg = spider.pg;

fn envOr(key: [:0]const u8, default: []const u8) []const u8 {
    const v = std.c.getenv(key) orelse return default;
    return std.mem.span(v);
}

var threaded: ?std.Io.Threaded = null;

fn connect() !void {
    if (pg.isInitialized()) return;
    const db = envOr("NOTIFY_PG_DB", "notify_test");
    if (!std.mem.eql(u8, db, "notify_test")) return error.NotADisposableDatabase;
    threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    try pg.init(std.heap.smp_allocator, threaded.?.io(), .{
        .host = envOr("NOTIFY_PG_HOST", "127.0.0.1"),
        .port = std.fmt.parseInt(u16, envOr("NOTIFY_PG_PORT", "5437"), 10) catch 5437,
        .user = envOr("NOTIFY_PG_USER", "notify"),
        .password = envOr("NOTIFY_PG_PASSWORD", "notify"),
        .database = db,
        .pool_size = 4,
    });
}

fn messages(report: spider.ModuleReport, arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try report.write(&out.writer);
    return out.written();
}

test "notify module: not ready until spider migrates it, then ready; migrating again does nothing" {
    try connect();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var server = spider.app(.{});
    defer server.deinit();
    _ = server.mountModules(.{notify});

    const before = server.checkModules(a, threaded.?.io());
    try std.testing.expect(!before.ok());
    try std.testing.expect(std.mem.indexOf(u8, try messages(before, a), "migration notify/0001_init is not applied") != null);

    try std.testing.expectEqual(@as(usize, 1), try server.migrateModules(a));
    const after = server.checkModules(a, threaded.?.io());
    if (!after.ok()) std.debug.print("{s}", .{try messages(after, a)});
    try std.testing.expect(after.ok());

    try std.testing.expectEqual(@as(usize, 0), try server.migrateModules(a));
    const recorded = try pg.queryOne(struct { version: []const u8, checksum: []const u8 }, a,
        \\SELECT version, checksum FROM schema_migrations WHERE version = 'notify/0001_init'
    , .{});
    try std.testing.expect(recorded != null);
    try std.testing.expectEqual(@as(usize, 64), recorded.?.checksum.len);
}

test "notify module: its own check fails when a table cannot be read" {
    try connect();
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var server = spider.app(.{});
    defer server.deinit();
    _ = server.mountModules(.{notify});
    _ = try server.migrateModules(a);

    try pg.query(void, a, "ALTER TABLE notify_inbox RENAME TO notify_inbox_away", .{});
    defer pg.query(void, a, "ALTER TABLE notify_inbox_away RENAME TO notify_inbox", .{}) catch {};

    const report = server.checkModules(a, threaded.?.io());
    try std.testing.expect(!report.ok());
    const text = try messages(report, a);
    try std.testing.expect(std.mem.indexOf(u8, text, "notify: cannot read its tables") != null);
}
