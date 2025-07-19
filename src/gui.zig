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

// -- LinkFinder GUI State -- //

const LinkFinderState = struct {
    // Input fields
    url_buffer: [512:0]u8 = [_:0]u8{0} ** 512,
    filter_buffer: [256:0]u8 = [_:0]u8{0} ** 256,
    recursive: bool = false,
    debug: bool = false,
    recursion_limit: i32 = 2,
    worker_count: i32 = 4,

    // LinkFinder instance and processing state
    link_finder: ?LinkFinder = null,
    processing_state: ?LinkFinder.ProcessingState = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LinkFinderState {
        return LinkFinderState{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LinkFinderState) void {
        if (self.processing_state) |*state| {
            state.deinit();
        }
        if (self.link_finder) |*lf| {
            lf.deinit();
        }
    }

    pub fn clearResults(self: *LinkFinderState) void {
        if (self.processing_state) |*state| {
            state.clearResults();
        }
    }

    pub fn isRunning(self: *const LinkFinderState) bool {
        if (self.processing_state) |*state| {
            return state.is_running;
        }
        return false;
    }

    pub fn hasResults(self: *const LinkFinderState) bool {
        if (self.processing_state) |*state| {
            return state.has_results;
        }
        return false;
    }

    pub fn hasError(self: *const LinkFinderState) bool {
        if (self.processing_state) |*state| {
            return state.has_error;
        }
        return false;
    }

    pub fn getErrorMessage(self: *const LinkFinderState) ?[]const u8 {
        if (self.processing_state) |*state| {
            return state.error_message;
        }
        return null;
    }

    pub fn getResults(self: *const LinkFinderState) []const []const u8 {
        if (self.processing_state) |*state| {
            return state.results.items;
        }
        return &[_][]const u8{};
    }

    pub fn getStats(self: *LinkFinderState) struct {
        found: u32,
        processed: u32,
        queue_size: usize,
        worker_count: usize,
        start_time: i64,
        last_activity_time: i64,
    } {
        if (self.processing_state) |*state| {
            state.work_mutex.lock();
            const queue_size = state.work_queue.items.len;
            state.work_mutex.unlock();

            return .{
                .found = state.total_found.load(.acquire),
                .processed = state.total_processed.load(.acquire),
                .queue_size = queue_size,
                .worker_count = state.worker_threads.items.len,
                .start_time = state.start_time,
                .last_activity_time = state.last_activity_time,
            };
        }
        return .{
            .found = 0,
            .processed = 0,
            .queue_size = 0,
            .worker_count = 0,
            .start_time = 0,
            .last_activity_time = 0,
        };
    }
};

// -- Helpers -- //

// Helper function to format duration
fn formatDuration(allocator: std.mem.Allocator, duration_ms: i64) ![]const u8 {
    const seconds = @divFloor(duration_ms, 1000);
    const minutes = @divFloor(seconds, 60);
    const hours = @divFloor(minutes, 60);
    const milliseconds = @rem(duration_ms, 1000);

    if (hours > 0) {
        return try std.fmt.allocPrint(allocator, "{}h {}m {}s {}ms", .{ hours, @rem(minutes, 60), @rem(seconds, 60), milliseconds });
    } else if (minutes > 0) {
        return try std.fmt.allocPrint(allocator, "{}m {}s {}ms", .{ minutes, @rem(seconds, 60), milliseconds });
    } else if (seconds > 0) {
        return try std.fmt.allocPrint(allocator, "{}s {}ms", .{ seconds, milliseconds });
    } else {
        return try std.fmt.allocPrint(allocator, "{}ms", .{milliseconds});
    }
}

// Helper function to save results to a text file
fn saveResultsToFile(state: *LinkFinderState) void {
    const results = state.getResults();
    if (results.len == 0) return;

    // Generate filename with timestamp
    const timestamp = std.time.timestamp();
    const filename = std.fmt.allocPrint(state.allocator, "links_{}.txt", .{timestamp}) catch {
        // If we can't allocate for the filename, use a default
        const file = std.fs.cwd().createFile("links_export.txt", .{}) catch return;
        defer file.close();

        // Write header
        const stats = state.getStats();
        file.writer().print("Link Export\n", .{}) catch return;
        file.writer().print("Generated: {}\n", .{timestamp}) catch return;
        file.writer().print("Total Links: {}\n", .{results.len}) catch return;
        file.writer().print("Pages Processed: {}\n", .{stats.processed}) catch return;
        file.writer().print("\n", .{}) catch return;

        // Write all links
        for (results, 1..) |link, index| {
            file.writer().print("{}: {s}\n", .{ index, link }) catch return;
        }
        return;
    };
    defer state.allocator.free(filename);

    // Create and write to file
    const file = std.fs.cwd().createFile(filename, .{}) catch return;
    defer file.close();

    // Write header information
    const stats = state.getStats();
    const total_duration = stats.last_activity_time - stats.start_time;

    file.writer().print("Link Export\n", .{}) catch return;
    file.writer().print("Generated: {}\n", .{timestamp}) catch return;
    file.writer().print("Total Links: {}\n", .{results.len}) catch return;
    file.writer().print("Pages Processed: {}\n", .{stats.processed}) catch return;

    if (total_duration > 0) {
        var arena = std.heap.ArenaAllocator.init(state.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        const duration_str = formatDuration(arena_allocator, total_duration) catch "N/A";
        file.writer().print("Processing Time: {s}\n", .{duration_str}) catch return;
    }

    file.writer().print("\n", .{}) catch return;

    // Write all links
    for (results, 1..) |link, index| {
        file.writer().print("{}: {s}\n", .{ index, link }) catch return;
    }
}

fn renderLinkFinderTab(state: *LinkFinderState) void {
    // Input fields
    zgui.text("URL:", .{});
    _ = zgui.inputText("##url", .{ .buf = &state.url_buffer });

    zgui.text("Filter (regex):", .{});
    _ = zgui.inputText("##filter", .{ .buf = &state.filter_buffer });

    _ = zgui.checkbox("Recursive", .{ .v = &state.recursive });
    _ = zgui.checkbox("Debug", .{ .v = &state.debug });

    if (state.recursive) {
        _ = zgui.sliderInt("Recursion Limit", .{ .v = &state.recursion_limit, .min = 1, .max = 10 });
    }

    _ = zgui.sliderInt("Worker Threads", .{ .v = &state.worker_count, .min = 1, .max = 16 });

    zgui.separator();

    // Control buttons
    const url_len = std.mem.indexOfScalar(u8, &state.url_buffer, 0) orelse state.url_buffer.len;
    const has_url = url_len > 0 and
        (std.mem.startsWith(u8, state.url_buffer[0..url_len], "http://") or
            std.mem.startsWith(u8, state.url_buffer[0..url_len], "https://"));

    zgui.beginDisabled(.{ .disabled = !has_url or state.isRunning() });
    if (zgui.button("Find Links", .{})) {
        // Ensure we're not already running
        if (state.isRunning()) {
            return;
        }

        // Clear previous results
        state.clearResults();

        // Prepare filters
        var filters = std.ArrayList([]const u8).init(state.allocator);
        defer filters.deinit();

        const filter_len = std.mem.indexOfScalar(u8, &state.filter_buffer, 0) orelse state.filter_buffer.len;
        if (filter_len > 0) {
            const filter = state.allocator.dupe(u8, state.filter_buffer[0..filter_len]) catch {
                // Handle error - could set error state here
                return;
            };
            defer state.allocator.free(filter);
            filters.append(filter) catch {
                return;
            };
        }

        // Create LinkFinder instance
        state.link_finder = LinkFinder.init(state.allocator, state.debug, filters.items) catch {
            // Handle error - could set error state here
            return;
        };

        // Create processing state
        state.processing_state = LinkFinder.ProcessingState.init(state.allocator);

        // Start processing
        const config = LinkFinder.MultiThreadedConfig{
            .recursive = state.recursive,
            .recursion_limit = @intCast(state.recursion_limit),
            .worker_count = @intCast(state.worker_count),
        };

        const url = state.url_buffer[0..url_len];
        if (state.link_finder) |*lf| {
            if (state.processing_state) |*ps| {
                lf.findLinksMultiThreaded(ps, url, config) catch {
                    // Handle error - could set error state here
                    return;
                };
            }
        }
    }
    zgui.endDisabled();

    zgui.sameLine(.{});

    // Stop button (only shown when running)
    if (state.isRunning()) {
        if (zgui.button("Stop", .{})) {
            state.clearResults();
        }
        zgui.sameLine(.{});
    }

    if (zgui.button("Clear Results", .{})) {
        state.clearResults();
    }

    zgui.sameLine(.{});

    // Save results button
    zgui.beginDisabled(.{ .disabled = !state.hasResults() or state.getResults().len == 0 });
    if (zgui.button("Save Results", .{})) {
        saveResultsToFile(state);
    }
    zgui.endDisabled();

    // Status display
    if (state.isRunning()) {
        zgui.text("Finding links...", .{});
        zgui.sameLine(.{});

        // Simple spinning indicator
        const time = @as(f32, @floatFromInt(@rem(std.time.milliTimestamp(), 2000))) / 2000.0;
        const spinner_chars = [_][]const u8{ "|", "/", "-", "\\" };
        const char_idx = @as(usize, @intFromFloat(time * 4)) % 4;
        zgui.text("{s}", .{spinner_chars[char_idx]});

        // Real-time statistics
        const stats = state.getStats();

        // Calculate timing information
        const current_time = std.time.milliTimestamp();
        const elapsed_ms = current_time - stats.start_time;
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        // Calculate processing rate
        var links_per_second: f64 = 0.0;
        if (elapsed_seconds > 0) {
            links_per_second = @as(f64, @floatFromInt(stats.found)) / elapsed_seconds;
        }

        // Display main statistics
        zgui.text("Found: {} | Processed: {} | Queue: {} | Workers: {}", .{ stats.found, stats.processed, stats.queue_size, stats.worker_count });

        // Display timing information
        if (elapsed_ms > 0) {
            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const duration_str = formatDuration(arena_allocator, elapsed_ms) catch "N/A";
            zgui.text("Duration: {s} | Rate: {d:.1} links/sec", .{ duration_str, links_per_second });

            // Estimate time remaining (rough estimate based on queue size and processing rate)
            if (stats.queue_size > 0 and stats.processed > 0 and elapsed_seconds > 1.0) {
                // Calculate pages processed per second instead of links per second for ETA
                const pages_per_second = @as(f64, @floatFromInt(stats.processed)) / elapsed_seconds;
                if (pages_per_second > 0.01) {
                    const estimated_remaining_seconds = @as(f64, @floatFromInt(stats.queue_size)) / pages_per_second;
                    const estimated_remaining_ms = @as(i64, @intFromFloat(estimated_remaining_seconds * 1000.0));
                    const eta_str = formatDuration(arena_allocator, estimated_remaining_ms) catch "N/A";
                    zgui.text("Estimated time remaining: {s} (based on {d:.2} pages/sec)", .{ eta_str, pages_per_second });
                }
            }

            // Progress indicator for recursive searches
            if (state.recursive and stats.processed > 0) {
                const progress_ratio = if (stats.queue_size == 0) 1.0 else @as(f32, @floatFromInt(stats.processed)) / @as(f32, @floatFromInt(stats.processed + stats.queue_size));
                zgui.progressBar(.{ .fraction = progress_ratio });
            }
        }
    }

    if (state.hasError()) {
        zgui.textColored(themes.CatppuccinMocha.red, "Error: {s}", .{state.getErrorMessage() orelse "Unknown error"});
    }

    // Results display
    const results = state.getResults();
    if (state.hasResults() and results.len > 0) {
        zgui.separator();

        // Show completion summary if not running
        if (!state.isRunning()) {
            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const stats = state.getStats();
            const total_duration = stats.last_activity_time - stats.start_time;
            const duration_str = formatDuration(arena_allocator, total_duration) catch "N/A";

            zgui.textColored(themes.CatppuccinMocha.green, "Completed in {s}", .{duration_str});
            zgui.text("Final stats: {} links found, {} pages processed", .{ stats.found, stats.processed });

            if (total_duration > 0) {
                const final_rate = @as(f64, @floatFromInt(stats.found)) / (@as(f64, @floatFromInt(total_duration)) / 1000.0);
                zgui.text("Average rate: {d:.1} links/sec", .{final_rate});
            }
        }

        zgui.text("Found {} links:", .{results.len});

        // Calculate remaining height for results
        const available_height = zgui.getContentRegionAvail()[1] - 20; // Leave some padding
        if (zgui.beginChild("results", .{ .w = 0, .h = available_height, .child_flags = .{ .border = true } })) {
            for (results, 0..) |result, i| {
                zgui.text("{}: {s}", .{ i + 1, result });
            }
        }
        zgui.endChild();
    } else if (state.hasResults()) {
        zgui.separator();

        // Show completion summary even when no results
        if (!state.isRunning()) {
            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const stats = state.getStats();
            const total_duration = stats.last_activity_time - stats.start_time;
            const duration_str = formatDuration(arena_allocator, total_duration) catch "N/A";

            zgui.textColored(themes.CatppuccinMocha.yellow, "Completed in {s}", .{duration_str});
            zgui.text("Final stats: {} pages processed", .{stats.processed});
        }

        zgui.text("No links found.", .{});
    }
}

fn renderMainWindow(linkfinder_state: *LinkFinderState, window_size: [2]f32) void {
    // Create fullscreen window
    zgui.setNextWindowPos(.{ .x = 0, .y = 0 });
    zgui.setNextWindowSize(.{ .w = window_size[0], .h = window_size[1] });

    const window_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
        .no_scrollbar = false,
        .no_scroll_with_mouse = false,
    };

    if (zgui.begin("Main", .{ .flags = window_flags })) {
        defer zgui.end();

        // Create tab bar
        if (zgui.beginTabBar("MainTabBar", .{})) {
            defer zgui.endTabBar();

            // LinkFinder tab
            if (zgui.beginTabItem("LinkFinder", .{})) {
                defer zgui.endTabItem();
                renderLinkFinderTab(linkfinder_state);
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
    var linkfinder_state = LinkFinderState.init(allocator);
    defer linkfinder_state.deinit();

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
                if (linkfinder_state.isRunning()) {
                    linkfinder_state.clearResults();
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
        renderMainWindow(&linkfinder_state, current_window_size);

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
