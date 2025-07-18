const std = @import("std");

// Taken mostly from nukkeldev/garden
// ---

/// Non-standard options specified by the user when invoking `zig build`.
const RawBuildOptions = struct {
    enable_tracy: bool,
    enable_tracy_callstack: bool,
};

// Standard Build Options
var target: std.Build.ResolvedTarget = undefined;
var optimize: std.builtin.OptimizeMode = undefined;

var raw_build_opts: RawBuildOptions = undefined;
var build_opts_mod: *std.Build.Module = undefined;

// -- Functions -- //

/// Turns the raw build options to an import-able module.
pub fn createBuildOptions(b: *std.Build) void {
    const options = b.addOptions();

    options.addOption(bool, "enable_tracy", raw_build_opts.enable_tracy);
    options.addOption(bool, "enable_tracy_callstack", raw_build_opts.enable_tracy_callstack);

    build_opts_mod = options.createModule();
}

pub fn build(b: *std.Build) void {
    // ---

    target = b.standardTargetOptions(.{});
    optimize = b.standardOptimizeOption(.{});

    raw_build_opts = RawBuildOptions{
        .enable_tracy = b.option(
            bool,
            "enable-tracy",
            "Whether to enable tracy profiling (low overhead) [default = false]",
        ) orelse false,
        .enable_tracy_callstack = b.option(
            bool,
            "enable-tracy-callstack",
            "Enforce callstack collection for tracy regions [default = false]",
        ) orelse false,
    };
    createBuildOptions(b);

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

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gui_exe = b.addExecutable(.{
        .name = "aside-gui",
        .root_module = gui_mod,
    });

    b.installArtifact(gui_exe);

    // ---

    cli_mod.addImport("build-opts", build_opts_mod);
    gui_mod.addImport("build-opts", build_opts_mod);

    const mvzr = b.dependency("mvzr", .{
        .target = target,
        .optimize = optimize,
    });

    cli_mod.addImport("mvzr", mvzr.module("mvzr"));
    gui_mod.addImport("mvzr", mvzr.module("mvzr"));

    gui_mod.linkLibrary(b.dependency("sdl", .{
        .target = target,
        .optimize = .ReleaseFast,
    }).artifact("SDL3"));

    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = .ReleaseFast,
        .backend = .sdl3_gpu,
    });
    gui_mod.addImport("zgui", zgui.module("root"));
    gui_mod.linkLibrary(zgui.artifact("imgui"));

    if (raw_build_opts.enable_tracy) {
        const src = b.dependency("tracy", .{}).path(".");
        const mod_ = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libcpp = true,
        });

        mod_.addCMacro("TRACY_ENABLE", "");
        mod_.addIncludePath(src.path(b, "public"));
        mod_.addCSourceFile(.{ .file = src.path(b, "public/TracyClient.cpp") });

        if (target.result.os.tag == .windows) {
            mod_.linkSystemLibrary("dbghelp", .{ .needed = true });
            mod_.linkSystemLibrary("ws2_32", .{ .needed = true });
        }

        const lib = b.addLibrary(.{
            .name = "tracy",
            .root_module = mod_,
            .linkage = .static,
        });
        lib.installHeadersDirectory(src.path(b, "public"), "", .{ .include_extensions = &.{".h"} });

        cli_mod.linkLibrary(lib);
        gui_mod.linkLibrary(lib);
    }

    // ---

    const run_cli_step = b.step("run-cli", "Run the cli");

    const run_cli_cmd = b.addRunArtifact(cli_exe);
    run_cli_step.dependOn(&run_cli_cmd.step);

    run_cli_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cli_cmd.addArgs(args);
    }

    // ---

    const run_gui_step = b.step("run-gui", "Run the gui");

    const run_gui_cmd = b.addRunArtifact(gui_exe);
    run_gui_step.dependOn(&run_gui_cmd.step);

    run_gui_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_gui_cmd.addArgs(args);
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
