const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module consumers import as @import("ziglib").
    // Sub-namespaces are exposed by src/root.zig (e.g. ziglib.otel).
    const ziglib_mod = b.addModule("ziglib", .{
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
    const test_step = b.step("test", "Run ziglib unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Integration test step: runs ziglib.xlsx against the public-dataset
    // corpus in tests/corpus/. Fetch with scripts/fetch_test_corpus.sh.
    // Tests skip gracefully when a corpus file is missing so CI and dev
    // setups don't have to keep the bytes checked in if they'd rather
    // pull them on demand.
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("tests/xlsx_corpus.zig"),
        .target = target,
        .optimize = optimize,
    });
    corpus_mod.addImport("ziglib", ziglib_mod);
    const corpus_tests = b.addTest(.{ .root_module = corpus_mod });
    const corpus_step = b.step("test-corpus", "Run xlsx integration tests against tests/corpus/ public datasets");
    corpus_step.dependOn(&b.addRunArtifact(corpus_tests).step);
}
