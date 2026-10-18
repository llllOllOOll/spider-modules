const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("spider_notify", .{
        .root_source_file = b.path("src/notify.zig"),
        .target = target,
        .optimize = optimize,
        // spider injected by the parent build.zig (it needs spider.pg)
    });
}
