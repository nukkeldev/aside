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

// Mouse wheel state
mouse_wheel_delta: f32,

// Debug state
debug_windows_enabled: bool,

// Sidebar state
sidebar_collapsed: bool,
sidebar_width: f32,
current_tab: enum { homepage, link_finder, canvas, fractals },

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
        .should_quit = false,
        .mouse_wheel_delta = 0.0,
        .debug_windows_enabled = false,
        .sidebar_collapsed = false,
        .sidebar_width = 250.0,
        .current_tab = .homepage,
        .last_update_ns = 0,
        .next_update_ns = 0,
        .last_render_ns = 0,
        .next_render_ns = 0,
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

    // Reset wheel delta each frame
    self.mouse_wheel_delta = 0.0;

    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        // Process wheel events before passing to ImGui to avoid conflicts
        if (event.type == c.SDL_EVENT_MOUSE_WHEEL) {
            // Accumulate wheel delta - use a more reasonable scaling
            self.mouse_wheel_delta += @floatCast(event.wheel.y);
        }

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
            c.SDL_EVENT_KEY_DOWN => {
                // Toggle debug windows with grave key (`)
                if (event.key.key == c.SDLK_GRAVE) {
                    self.debug_windows_enabled = !self.debug_windows_enabled;
                }
            },
            c.SDL_EVENT_WINDOW_RESIZED => {
                self.current_window_size[0] = @floatFromInt(event.window.data1);
                self.current_window_size[1] = @floatFromInt(event.window.data2);
            },
            else => {},
        }
    }
}

// Helper method to get mouse wheel delta for this frame
fn getMouseWheelDelta(self: *const App) f32 {
    return self.mouse_wheel_delta;
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

    // Render debug windows if enabled
    if (self.debug_windows_enabled) {
        try self.renderDebugWindows();
    }

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

            // Information Section
            if (zgui.collapsingHeader("Information", .{ .default_open = true })) {
                if (zgui.selectable("Homepage", .{ .selected = self.current_tab == .homepage })) {
                    self.current_tab = .homepage;
                }
            }

            zgui.spacing();

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
            .homepage => self.renderHomepageContent(),
            .link_finder => try self.link_finder_gui.render(),
            .canvas => try self.canvas_gui.render(self.getMouseWheelDelta()),
            .fractals => try self.fractals_gui.render(self.getMouseWheelDelta()),
        }
    }
}

fn renderHomepageContent(_: *App) void {
    // Welcome header
    zgui.text("Welcome to Aside", .{});
    zgui.separator();

    zgui.spacing();
    zgui.text("A multipurpose analysis and creative tool built with Zig and ImGui", .{});

    zgui.spacing();
    zgui.spacing();

    zgui.separator();
    zgui.spacing();

    // Feature overview
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

// -- Debug Windows -- //

fn renderDebugWindows(self: *App) !void {
    // Main App debug window - always show, positioned at top-right
    zgui.setNextWindowPos(.{ .x = self.current_window_size[0] - 350, .y = 10, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = 340, .h = 400, .cond = .first_use_ever });

    const main_debug_flags = zgui.WindowFlags{
        .no_bring_to_front_on_focus = false, // Allow bringing to front
    };

    if (zgui.begin("App Debug", .{ .popen = &self.debug_windows_enabled, .flags = main_debug_flags })) {
        defer zgui.end();

        // Bring debug window to front when first opened
        if (zgui.isWindowAppearing()) {
            zgui.setWindowFocus(null);
        }

        zgui.text("Application State", .{});
        zgui.separator();

        zgui.text("Window Size: {d:.1} x {d:.1}", .{ self.current_window_size[0], self.current_window_size[1] });
        zgui.text("Current Tab: {s}", .{@tagName(self.current_tab)});
        zgui.text("Sidebar Collapsed: {}", .{self.sidebar_collapsed});
        zgui.text("Sidebar Width: {d:.1}", .{self.sidebar_width});
        zgui.text("Mouse Wheel Delta: {d:.3}", .{self.mouse_wheel_delta});

        zgui.spacing();
        zgui.text("Performance", .{});
        zgui.separator();

        const current_ns: u64 = @intCast(c.SDL_GetTicksNS());
        const update_delta = if (self.last_update_ns > 0) current_ns - self.last_update_ns else 0;
        const render_delta = if (self.last_render_ns > 0) current_ns - self.last_render_ns else 0;

        zgui.text("Last Update Delta: {d:.2}ms", .{@as(f64, @floatFromInt(update_delta)) / std.time.ns_per_ms});
        zgui.text("Last Render Delta: {d:.2}ms", .{@as(f64, @floatFromInt(render_delta)) / std.time.ns_per_ms});
        zgui.text("Target Update Time: {d:.2}ms", .{@as(f64, TARGET_UPDATE_TIME_NS) / std.time.ns_per_ms});
        zgui.text("Target Frame Time: {d:.2}ms", .{@as(f64, TARGET_FRAMETIME_NS) / std.time.ns_per_ms});

        zgui.spacing();
        if (zgui.button("Close Debug Windows", .{})) {
            self.debug_windows_enabled = false;
        }
    }

    // Individual GUI debug windows - only show relevant to current tab
    try self.renderGuiDebugWindows();
}

fn renderGuiDebugWindows(self: *App) !void {
    const gui_debug_flags = zgui.WindowFlags{
        .no_bring_to_front_on_focus = false, // Allow bringing to front
    };

    // LinkFinder GUI Debug - only show when on link_finder tab
    if (self.current_tab == .link_finder) {
        // Position to the left, avoiding the main debug window
        zgui.setNextWindowPos(.{ .x = 10, .y = 10, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 320, .h = 380, .cond = .first_use_ever });

        if (zgui.begin("LinkFinder Debug", .{ .flags = gui_debug_flags })) {
            defer zgui.end();

            // Bring to front when first appearing
            if (zgui.isWindowAppearing()) {
                zgui.setWindowFocus(null);
            }

            zgui.text("LinkFinder GUI State", .{});
            zgui.separator();

            zgui.text("Debug Mode: {}", .{self.link_finder_gui.debug});
            zgui.text("URL Buffer: '{s}'", .{std.mem.sliceTo(&self.link_finder_gui.url_buffer, 0)});
            zgui.text("Filter Buffer: '{s}'", .{std.mem.sliceTo(&self.link_finder_gui.filter_buffer, 0)});
            zgui.text("Recursive: {}", .{self.link_finder_gui.recursive});
            zgui.text("Recursion Limit: {d}", .{self.link_finder_gui.recursion_limit});
            zgui.text("Worker Count: {d}", .{self.link_finder_gui.worker_count});
            zgui.text("Has LinkFinder Instance: {}", .{self.link_finder_gui.link_finder != null});
            zgui.text("Has Processing State: {}", .{self.link_finder_gui.processing_state != null});

            if (self.link_finder_gui.processing_state) |state| {
                zgui.spacing();
                zgui.text("Processing State", .{});
                zgui.separator();
                zgui.text("Is Running: {}", .{state.is_running});
                zgui.text("Has Results: {}", .{state.has_results});
                zgui.text("Has Error: {}", .{state.has_error});
                zgui.text("Total Found: {d}", .{state.total_found.load(.acquire)});
                zgui.text("Total Processed: {d}", .{state.total_processed.load(.acquire)});
                zgui.text("Results Count: {d}", .{state.results.items.len});
                zgui.text("Work Queue Count: {d}", .{state.work_queue.items.len});
                if (state.error_message) |err_msg| {
                    zgui.textColored(.{ 1.0, 0.5, 0.5, 1.0 }, "Error: {s}", .{err_msg});
                }
            }
        }
    }

    // Canvas GUI Debug - only show when on canvas tab
    if (self.current_tab == .canvas) {
        // Position to the left, avoiding the main debug window
        zgui.setNextWindowPos(.{ .x = 10, .y = 10, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 320, .h = 320, .cond = .first_use_ever });

        if (zgui.begin("Canvas Debug", .{ .flags = gui_debug_flags })) {
            defer zgui.end();

            // Bring to front when first appearing
            if (zgui.isWindowAppearing()) {
                zgui.setWindowFocus(null);
            }

            zgui.text("Canvas GUI State", .{});
            zgui.separator();

            zgui.text("Drawing: {}", .{self.canvas_gui.drawing});
            zgui.text("Panning: {}", .{self.canvas_gui.panning});
            zgui.text("Last Mouse Pos: {d:.1}, {d:.1}", .{ self.canvas_gui.last_mouse_pos[0], self.canvas_gui.last_mouse_pos[1] });
            zgui.text("Pan Start Pos: {d:.1}, {d:.1}", .{ self.canvas_gui.pan_start_pos[0], self.canvas_gui.pan_start_pos[1] });
            zgui.text("Brush Size: {d:.1}", .{self.canvas_gui.brush_size});
            zgui.text("Brush Color: {d:.3}, {d:.3}, {d:.3}, {d:.3}", .{ self.canvas_gui.brush_color[0], self.canvas_gui.brush_color[1], self.canvas_gui.brush_color[2], self.canvas_gui.brush_color[3] });
            zgui.text("Canvas Size: {d:.1} x {d:.1}", .{ self.canvas_gui.canvas_size[0], self.canvas_gui.canvas_size[1] });
            zgui.text("Zoom: {d:.3}", .{self.canvas_gui.zoom});
            zgui.text("Pan Offset: {d:.1}, {d:.1}", .{ self.canvas_gui.pan_offset[0], self.canvas_gui.pan_offset[1] });
            zgui.text("Draw Commands Count: {d}", .{self.canvas_gui.draw_commands.items.len});
        }
    }

    // Fractals GUI Debug - only show when on fractals tab
    if (self.current_tab == .fractals) {
        // Position to the left, avoiding the main debug window
        zgui.setNextWindowPos(.{ .x = 10, .y = 10, .cond = .first_use_ever });
        zgui.setNextWindowSize(.{ .w = 320, .h = 420, .cond = .first_use_ever });

        if (zgui.begin("Fractals Debug", .{ .flags = gui_debug_flags })) {
            defer zgui.end();

            // Bring to front when first appearing
            if (zgui.isWindowAppearing()) {
                zgui.setWindowFocus(null);
            }

            zgui.text("Fractals GUI State", .{});
            zgui.separator();

            zgui.text("Fractal Type: {s}", .{@tagName(self.fractals_gui.fractal_type)});
            zgui.text("Image Size: {d} x {d}", .{ self.fractals_gui.image_size[0], self.fractals_gui.image_size[1] });
            zgui.text("Has Texture: {}", .{self.fractals_gui.texture_id != null});
            zgui.text("Needs Update: {}", .{self.fractals_gui.needs_update});
            zgui.text("Panning: {}", .{self.fractals_gui.panning});
            zgui.text("Last Mouse Pos: {d:.1}, {d:.1}", .{ self.fractals_gui.last_mouse_pos[0], self.fractals_gui.last_mouse_pos[1] });

            zgui.spacing();
            zgui.text("Fractal Parameters", .{});
            zgui.separator();
            zgui.text("Zoom: {d:.6}", .{self.fractals_gui.zoom});
            zgui.text("Center: {d:.6}, {d:.6}", .{ self.fractals_gui.center[0], self.fractals_gui.center[1] });
            zgui.text("Max Iterations: {d}", .{self.fractals_gui.max_iterations});
            zgui.text("Julia C: {d:.6}, {d:.6}", .{ self.fractals_gui.julia_c[0], self.fractals_gui.julia_c[1] });
            zgui.text("Sierpinski Iterations: {d}", .{self.fractals_gui.sierpinski_iterations});
            zgui.text("Color Scheme: {d}", .{self.fractals_gui.color_scheme});
            zgui.text("Resolution: {d}", .{self.fractals_gui.resolution});
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
