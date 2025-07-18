const std = @import("std");

pub fn build(b: *std.Build) void {
    // ---

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "aside",
        .root_module = mod,
    });

    b.installArtifact(exe);

    // ---

    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("mvzr", mvzr.module("mvzr"));

    // ---

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ---

    const check = b.step("check", "Compiles without installation.");
    check.dependOn(&exe.step);

    // ---

    const tests = b.addTest(.{
        .root_module = mod,
        .filters = b.args orelse &.{},
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
