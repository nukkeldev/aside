const std = @import("std");

pub fn build(b: *std.Build) void {
    // ---

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cli_exe = b.addExecutable(.{
        .name = "aside",
        .root_module = cli_mod,
    });

    b.installArtifact(cli_exe);

    // ---

    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });

    cli_mod.addImport("mvzr", mvzr.module("mvzr"));

    // ---

    const run_cli_step = b.step("run-cli", "Run the cli");

    const run_cli_cmd = b.addRunArtifact(cli_exe);
    run_cli_step.dependOn(&run_cli_cmd.step);

    run_cli_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cli_cmd.addArgs(args);
    }

    // ---

    const check = b.step("check", "Compiles without installation.");
    check.dependOn(&cli_exe.step);

    // ---
    // TODO: Need a better entrypoint for tests.

    const cli_tests = b.addTest(.{
        .root_module = cli_mod,
        .filters = b.args orelse &.{},
    });

    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_cli_step = b.step("test", "Run tests");
    test_cli_step.dependOn(&run_cli_tests.step);
}
