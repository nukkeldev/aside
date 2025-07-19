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
canvas_gui: @import("gui/CanvasGui.zig"),
fractals_gui: @import("gui/FractalsGui.zig"),

current_window_size: [2]f32,
should_quit: bool,

// Sidebar state
sidebar_collapsed: bool,
sidebar_width: f32,
current_tab: enum { link_finder, canvas, fractals, about },

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

    // Initialize Canvas GUI
    const canvas_gui = @import("gui/CanvasGui.zig").init(allocator);

    // Initialize Fractals GUI
    const fractals_gui = try @import("gui/FractalsGui.zig").init(allocator);

    return App{
        .allocator = allocator,
        .window = window,
        .device = device,
        .link_finder_gui = link_finder_gui,
        .canvas_gui = canvas_gui,
        .fractals_gui = fractals_gui,
        .current_window_size = .{ 1280, 720 },
        .sidebar_collapsed = false,
        .sidebar_width = 250.0,
        .current_tab = .link_finder,
        .last_update_ns = 0,
        .next_update_ns = 0,
        .last_render_ns = 0,
        .next_render_ns = 0,
        .should_quit = false,
    };
}

fn deinit(self: *App) void {
    self.link_finder_gui.deinit();
    self.canvas_gui.deinit();
    self.fractals_gui.deinit();
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

        // Render sidebar
        try self.renderSidebar();

        // Render main content area
        try self.renderMainContent();
    }
}

fn renderSidebar(self: *App) !void {
    // Calculate sidebar position and size
    const actual_sidebar_width = if (self.sidebar_collapsed) 50.0 else self.sidebar_width;

    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = actual_sidebar_width, .h = self.current_window_size[1] });

    const sidebar_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_scrollbar = self.sidebar_collapsed,
    };

    if (zgui.begin("Sidebar", .{ .flags = sidebar_flags })) {
        defer zgui.end();

        // Toggle button
        if (self.sidebar_collapsed) {
            if (zgui.button(">>", .{ .w = 40, .h = 30 })) {
                self.sidebar_collapsed = false;
            }
        } else {
            if (zgui.button("<<", .{ .w = 40, .h = 30 })) {
                self.sidebar_collapsed = true;
            }

            zgui.separator();

            // Analysis Tools Section
            if (zgui.collapsingHeader("Analysis Tools", .{ .default_open = true })) {
                if (zgui.selectable("Link Finder", .{ .selected = self.current_tab == .link_finder })) {
                    self.current_tab = .link_finder;
                }
            }

            zgui.spacing();

            // Creative Tools Section
            if (zgui.collapsingHeader("Creative Tools", .{ .default_open = true })) {
                if (zgui.selectable("Canvas", .{ .selected = self.current_tab == .canvas })) {
                    self.current_tab = .canvas;
                }

                if (zgui.selectable("Fractals", .{ .selected = self.current_tab == .fractals })) {
                    self.current_tab = .fractals;
                }
            }

            zgui.spacing();

            // Information Section
            if (zgui.collapsingHeader("Information", .{ .default_open = false })) {
                if (zgui.selectable("About", .{ .selected = self.current_tab == .about })) {
                    self.current_tab = .about;
                }
            }
        }
    }
}

fn renderMainContent(self: *App) !void {
    // Calculate main content area position and size
    const sidebar_width = if (self.sidebar_collapsed) 50.0 else self.sidebar_width;
    const content_x = sidebar_width;
    const content_width = self.current_window_size[0] - sidebar_width;

    zgui.setNextWindowPos(.{ .x = content_x, .y = 0 });
    zgui.setNextWindowSize(.{ .w = content_width, .h = self.current_window_size[1] });

    const content_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
    };

    if (zgui.begin("MainContent", .{ .flags = content_flags })) {
        defer zgui.end();

        // Render content based on current tab
        switch (self.current_tab) {
            .link_finder => try self.link_finder_gui.render(),
            .canvas => try self.canvas_gui.render(),
            .fractals => try self.fractals_gui.render(),
            .about => self.renderAboutContent(),
        }
    }
}

fn renderAboutContent(self: *App) void {
    _ = self; // suppress unused variable warning

    zgui.text("Aside - Multipurpose Analysis & Creative Tool", .{});
    zgui.separator();

    zgui.spacing();
    zgui.text("Built with Zig and ImGui", .{});

    zgui.spacing();
    zgui.textColored(.{ 0.7, 0.9, 1.0, 1.0 }, "Analysis Tools:", .{});
    zgui.bulletText("Extract links from web pages", .{});
    zgui.bulletText("Recursive link following", .{});
    zgui.bulletText("Regex filtering", .{});
    zgui.bulletText("Multi-threaded processing", .{});

    zgui.spacing();
    zgui.textColored(.{ 1.0, 0.8, 0.6, 1.0 }, "Creative Tools:", .{});
    zgui.bulletText("Digital drawing canvas with zoom & pan", .{});
    zgui.bulletText("Mathematical fractal generation", .{});
    zgui.bulletText("Multiple fractal types (Mandelbrot, Julia, Sierpinski, Burning Ship)", .{});
    zgui.bulletText("Customizable color schemes and parameters", .{});
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
