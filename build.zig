const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module consumers import as @import("ziglib").
    // Sub-namespaces are exposed by src/root.zig (e.g. ziglib.otel).
    _ = b.addModule("ziglib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Test step: runs tests for every module reachable from root.zig.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run ziglib tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
