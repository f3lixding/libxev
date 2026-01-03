const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("explore", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const test_exe = test_exe: {
        const test_filter = b.option([]const u8, "test-filter", "Filter for test");
        const test_exe = b.addTest(.{
            .name = "explore test",
            .filters = if (test_filter) |filter| &.{filter} else &.{},
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        break :test_exe test_exe;
    };

    {
        const tests_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }
}
