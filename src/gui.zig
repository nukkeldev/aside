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

const App = @This();

// -- Constants -- //

const TARGET_UPDATE_TIME_NS: u64 = std.time.ns_per_s / 1000;
const TARGET_FRAMETIME_NS: u64 = std.time.ns_per_s / 60;

// -- Fields -- //

allocator: std.mem.Allocator,
window: SDL.Window,
device: SDL.GPUDevice,
link_finder_gui: @import("gui/LinkFinderGui.zig"),

current_window_size: [2]f32,
should_quit: bool,

last_update_ns: u64,
next_update_ns: u64,
last_render_ns: u64,
next_render_ns: u64,

// -- Initialization -- //

fn init(allocator: std.mem.Allocator) !App {
    // Initialize SDL
    try SDL.initialize(c.SDL_INIT_VIDEO);

    // Create window and device
    const window = try SDL.Window.create(allocator, "ASIDE", [2]u32{ 1280, 720 }, [2]u32{ c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED });
    const device = try SDL.GPUDevice.createAndClaimForWindow(allocator, c.SDL_GPU_SHADERFORMAT_SPIRV, false, null, &window);
    try device.setSwapchainParameters(&window, .{ .present_mode = .MAILBOX });
    try device.setAllowedFramesInFlight(3);

    // Initialize GUI
    zgui.init(allocator);
    zgui.backend.init(window.handle, .{
        .device = device.handle,
        .color_target_format = c.SDL_GPU_TEXTUREFORMAT_B8G8R8A8_UNORM,
        .msaa_samples = c.SDL_GPU_SAMPLECOUNT_1,
    });

    // Apply theme
    themes.applyImGuiTheme(themes.CatppuccinMocha);

    // Initialize LinkFinder GUI
    const link_finder_gui = @import("gui/LinkFinderGui.zig").init(allocator);

    return App{
        .allocator = allocator,
        .window = window,
        .device = device,
        .link_finder_gui = link_finder_gui,
        .current_window_size = .{ 1280, 720 },
        .last_update_ns = 0,
        .next_update_ns = 0,
        .last_render_ns = 0,
        .next_render_ns = 0,
        .should_quit = false,
    };
}

fn deinit(self: *App) void {
    self.link_finder_gui.deinit();
    zgui.backend.deinit();
    zgui.deinit();
}

// -- Event Polling -- //

fn pollEvents(self: *App) !void {
    var fz = FZ.init(@src(), "poll events");
    defer fz.end();

    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        _ = zgui.backend.processEvent(&event);

        switch (event.type) {
            c.SDL_EVENT_QUIT => {
                // Ensure LinkFinder cleanup before exiting
                if (self.link_finder_gui.isRunning()) {
                    self.link_finder_gui.clearResults();
                    // Give threads time to stop properly
                    std.time.sleep(500 * std.time.ns_per_ms);
                }
                self.should_quit = true;
            },
            c.SDL_EVENT_WINDOW_RESIZED => {
                self.current_window_size[0] = @floatFromInt(event.window.data1);
                self.current_window_size[1] = @floatFromInt(event.window.data2);
            },
            else => {},
        }
    }
}

// -- Rendering -- //

fn render(self: *App) !void {
    var fz = FZ.init(@src(), "render");
    defer fz.end();

    tracy.frameMark();

    fz.push(@src(), "acquire");
    const cmd = try SDL.GPUCommandBuffer.acquire(&self.device);
    const swapchain_texture: ?*c.SDL_GPUTexture = try cmd.waitAndAcquireSwapchainTexture(&self.window);
    if (swapchain_texture == null) return;

    const tex = swapchain_texture.?;

    fz.replace(@src(), "begin render pass");
    const color_target_info = c.SDL_GPUColorTargetInfo{
        .clear_color = .{ .r = themes.CatppuccinMocha.base[0], .g = themes.CatppuccinMocha.base[1], .b = themes.CatppuccinMocha.base[2], .a = themes.CatppuccinMocha.base[3] },
        .texture = tex,
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    };

    const rpass = try SDL.GPURenderPass.begin(&cmd, &.{color_target_info}, null);

    zgui.backend.newFrame(@intFromFloat(self.current_window_size[0]), @intFromFloat(self.current_window_size[1]), 1.0);

    // Render main window with tabs
    try self.renderMainWindow();

    zgui.render();
    zgui.backend.prepareDrawData(cmd.handle);
    zgui.backend.renderDrawData(cmd.handle, rpass.handle, null);

    fz.replace(@src(), "submit");
    rpass.end();
    try cmd.submit();
    fz.pop();
}

fn renderMainWindow(self: *App) !void {
    // Create fullscreen window
    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = self.current_window_size[0], .h = self.current_window_size[1] });

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
                try self.link_finder_gui.render();
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

// -- Main Loop -- //

fn run(self: *App) !void {
    var fz = FZ.init(@src(), "app loop");
    defer fz.end();

    while (!self.should_quit) {
        const ticks_ns: u64 = @intCast(c.SDL_GetTicksNS());

        if (ticks_ns >= self.next_update_ns) {
            try self.pollEvents();
            self.last_update_ns = ticks_ns;
            self.next_update_ns = ticks_ns + TARGET_UPDATE_TIME_NS;
        }

        if (ticks_ns >= self.next_render_ns) {
            try self.render();
            self.last_render_ns = ticks_ns;
            self.next_render_ns = ticks_ns + TARGET_FRAMETIME_NS;
        }
    }

    // TODO: Need to clean up existing working.
}

pub fn main() !void {
    var fz = FZ.init(@src(), "main");
    defer fz.end();

    var da = std.heap.DebugAllocator(.{}).init;
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

    var app = try App.init(allocator);
    defer app.deinit();

    try app.run();
}
