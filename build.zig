//! The official Spider modules, built and tested together against one
//! Spider (the `spider` dependency: `../spider`, a checkout next to this
//! repository, which is also how CI lays them out).
//!
//! Each module is its own package (`<module>/build.zig.zon`) with no
//! dependency on Spider: an app adds it and passes its own `spider` module
//! in. This file only wires them for the tests.
//!
//!   zig build test       unit tests of every module (no database)
//!   zig build test-db    database tests (scripts/ecosystem.sh starts a disposable Postgres)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spider_dep = b.dependency("spider", .{ .target = target, .optimize = optimize, .pg = true });
    const spider_mod = spider_dep.module("spider");
    const db_runner = spider_dep.path("test_runner.zig");

    const test_step = b.step("test", "Unit tests of every module (no database)");
    const test_db_step = b.step("test-db", "Database tests of every module (needs a disposable Postgres; see scripts/ecosystem.sh)");

    // ── notify ──────────────────────────────────────────────────────────
    const notify_mod = b.createModule(.{
        .root_source_file = b.path("notify/src/notify.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "spider", .module = spider_mod }},
    });
    const notify_unit = b.addRunArtifact(b.addTest(.{ .root_module = notify_mod }));
    test_step.dependOn(&notify_unit.step);
    b.step("test-notify", "notify: unit tests").dependOn(&notify_unit.step);

    // The module through Spider: not ready, migrated by spider, ready, its
    // own check. Runs before the database tests, which need its tables.
    const notify_module_test = b.addRunArtifact(dbTest(b, "notify/test/module_test.zig", spider_mod, notify_mod, db_runner, target, optimize));
    notify_module_test.has_side_effects = true;
    const notify_db_test = b.addRunArtifact(dbTest(b, "notify/test/db_test.zig", spider_mod, notify_mod, db_runner, target, optimize));
    notify_db_test.has_side_effects = true;
    notify_db_test.step.dependOn(&notify_module_test.step);
    const notify_db_step = b.step("test-notify-db", "notify: module and database tests");
    notify_db_step.dependOn(&notify_db_test.step);
    test_db_step.dependOn(&notify_db_test.step);
}

fn dbTest(
    b: *std.Build,
    path: []const u8,
    spider_mod: *std.Build.Module,
    module: *std.Build.Module,
    runner: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "spider", .module = spider_mod },
                .{ .name = "spider_notify", .module = module },
            },
        }),
        .test_runner = .{ .path = runner, .mode = .simple },
    });
}
