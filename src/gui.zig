// -- Imports -- //

const std = @import("std");

const c = @import("ffi.zig").c;
const SDL = @import("ffi.zig").SDL;
const zgui = @import("zgui");
const tracy = @import("perf/tracy.zig");

const themes = @import("gui/themes.zig");

// Aliases

const FZ = tracy.FnZone;
const LinkFinder = @import("tools/LinkFinder.zig");

// ---

var link_finder_gui: @import("gui/LinkFinderGui.zig") = undefined;

// ---

fn renderMainWindow(window_size: [2]f32) !void {
    // Create fullscreen window
    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = window_size[0], .h = window_size[1] });

    const window_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
    };

    if (zgui.begin("Main", .{ .flags = window_flags })) {
        defer zgui.end();

        // Create tab bar
        if (zgui.beginTabBar("MainTabBar", .{})) {
            defer zgui.endTabBar();

            // LinkFinder tab
            if (zgui.beginTabItem("LinkFinder", .{})) {
                defer zgui.endTabItem();
                try link_finder_gui.render();
            }

            // Add more tabs here in the future
            if (zgui.beginTabItem("About", .{})) {
                defer zgui.endTabItem();
                zgui.text("Aside - Web Link Analysis Tool", .{});
                zgui.separator();
                zgui.text("Built with Zig and ImGui", .{});
                zgui.text("Features:", .{});
                zgui.bulletText("Extract links from web pages", .{});
                zgui.bulletText("Recursive link following", .{});
                zgui.bulletText("Regex filtering", .{});
                zgui.bulletText("Multi-threaded processing", .{});
            }
        }
    }
}

pub fn main() !void {
    var fz = FZ.init(@src(), "main");
    defer fz.end();

    var da = std.heap.DebugAllocator(.{}).init;
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

    // Initialize LinkFinder state
    link_finder_gui = .init(allocator);
    defer link_finder_gui.deinit();

    // Initialize SDL.
    fz.push(@src(), "sdl init");
    try SDL.initialize(c.SDL_INIT_VIDEO);

    // Create the window and device.
    fz.replace(@src(), "create window");
    const window = try SDL.Window.create(allocator, "Aside - Web Link Analysis Tool", [2]u32{ 1280, 720 }, [2]u32{ c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED });

    fz.replace(@src(), "create device");
    const device = try SDL.GPUDevice.createAndClaimForWindow(allocator, c.SDL_GPU_SHADERFORMAT_SPIRV, false, null, &window);
    try device.setSwapchainParameters(&window, .{ .present_mode = .MAILBOX });
    try device.setAllowedFramesInFlight(3);

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.backend.init(window.handle, .{
        .device = device.handle,
        // Keep in-sync with Swapchain format.
        .color_target_format = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
        .msaa_samples = c.SDL_GPU_SAMPLECOUNT_1,
    });
    defer zgui.backend.deinit();

    // Apply Catppuccin Mocha theme
    themes.applyImGuiTheme(themes.CatppuccinMocha);

    fz.replace(@src(), "loop");
    var current_window_size: [2]f32 = .{ 1280, 720 };

    outer: while (true) {
        fz.push(@src(), "poll events");
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            _ = zgui.backend.processEvent(&event);
            if (event.type == c.SDL_EVENT_QUIT) {
                // Ensure LinkFinder cleanup before exiting
                if (link_finder_gui.isRunning()) {
                    link_finder_gui.clearResults();
                    // Give threads more time to stop properly
                    std.time.sleep(500 * std.time.ns_per_ms);
                }
                break :outer;
            }

            // Handle window resize
            if (event.type == c.SDL_EVENT_WINDOW_RESIZED) {
                current_window_size[0] = @floatFromInt(event.window.data1);
                current_window_size[1] = @floatFromInt(event.window.data2);
            }
        }

        fz.replace(@src(), "render");
        tracy.frameMark();

        fz.push(@src(), "acquire");
        const cmd = try SDL.GPUCommandBuffer.acquire(&device);
        const swapchain_texture: ?*c.SDL_GPUTexture = try cmd.waitAndAcquireSwapchainTexture(&window);
        if (swapchain_texture == null) return;

        const tex = swapchain_texture.?;

        // SDL Rendering

        fz.replace(@src(), "begin render pass");
        const color_target_info = c.SDL_GPUColorTargetInfo{
            .clear_color = .{ .r = themes.CatppuccinMocha.base[0], .g = themes.CatppuccinMocha.base[1], .b = themes.CatppuccinMocha.base[2], .a = themes.CatppuccinMocha.base[3] },
            .texture = tex,
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        };

        const rpass = try SDL.GPURenderPass.begin(&cmd, &.{color_target_info}, null);

        zgui.backend.newFrame(@intFromFloat(current_window_size[0]), @intFromFloat(current_window_size[1]), 1.0);

        // Render main window with tabs
        try renderMainWindow(current_window_size);

        zgui.render();
        zgui.backend.prepareDrawData(cmd.handle);
        zgui.backend.renderDrawData(cmd.handle, rpass.handle, null);

        fz.replace(@src(), "submit");
        rpass.end();
        try cmd.submit();

        fz.pop();
        fz.pop();
    }
}
