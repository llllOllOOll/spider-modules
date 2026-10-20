const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("spider_pdf", .{
        .root_source_file = b.path("src/pdf.zig"),
        .target = target,
        .optimize = optimize,
        // spider injected by the parent build.zig (the module manifest and
        // `send` use it; the drawing code is std only)
    });
}
