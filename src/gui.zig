const std = @import("std");

const SDL = @import("ffi.zig").SDL;
const c = @import("ffi.zig").c;
const zgui = @import("zgui");
const tracy = @import("perf/tracy.zig");

const FZ = tracy.FnZone;
const LinkFinder = @import("tools/LinkFinder.zig");

// -- Catppuccin Mocha Colors -- //
const CatppuccinMocha = struct {
    // Base colors
    const base = [4]f32{ 30.0 / 255.0, 30.0 / 255.0, 46.0 / 255.0, 1.0 }; // #1e1e2e
    const mantle = [4]f32{ 24.0 / 255.0, 24.0 / 255.0, 37.0 / 255.0, 1.0 }; // #181825
    const crust = [4]f32{ 17.0 / 255.0, 17.0 / 255.0, 27.0 / 255.0, 1.0 }; // #11111b

    // Text colors
    const text = [4]f32{ 205.0 / 255.0, 214.0 / 255.0, 244.0 / 255.0, 1.0 }; // #cdd6f4
    const subtext1 = [4]f32{ 186.0 / 255.0, 194.0 / 255.0, 222.0 / 255.0, 1.0 }; // #bac2de
    const subtext0 = [4]f32{ 166.0 / 255.0, 173.0 / 255.0, 200.0 / 255.0, 1.0 }; // #a6adc8
    const overlay2 = [4]f32{ 147.0 / 255.0, 153.0 / 255.0, 178.0 / 255.0, 1.0 }; // #9399b2
    const overlay1 = [4]f32{ 127.0 / 255.0, 132.0 / 255.0, 156.0 / 255.0, 1.0 }; // #7f849c
    const overlay0 = [4]f32{ 108.0 / 255.0, 112.0 / 255.0, 134.0 / 255.0, 1.0 }; // #6c7086
    const surface2 = [4]f32{ 88.0 / 255.0, 91.0 / 255.0, 112.0 / 255.0, 1.0 }; // #585b70
    const surface1 = [4]f32{ 69.0 / 255.0, 71.0 / 255.0, 90.0 / 255.0, 1.0 }; // #45475a
    const surface0 = [4]f32{ 49.0 / 255.0, 50.0 / 255.0, 68.0 / 255.0, 1.0 }; // #313244

    // Accent colors
    const rosewater = [4]f32{ 245.0 / 255.0, 224.0 / 255.0, 220.0 / 255.0, 1.0 }; // #f5e0dc
    const flamingo = [4]f32{ 242.0 / 255.0, 205.0 / 255.0, 205.0 / 255.0, 1.0 }; // #f2cdcd
    const pink = [4]f32{ 245.0 / 255.0, 194.0 / 255.0, 231.0 / 255.0, 1.0 }; // #f5c2e7
    const mauve = [4]f32{ 203.0 / 255.0, 166.0 / 255.0, 247.0 / 255.0, 1.0 }; // #cba6f7
    const red = [4]f32{ 243.0 / 255.0, 139.0 / 255.0, 168.0 / 255.0, 1.0 }; // #f38ba8
    const maroon = [4]f32{ 235.0 / 255.0, 160.0 / 255.0, 172.0 / 255.0, 1.0 }; // #eba0ac
    const peach = [4]f32{ 250.0 / 255.0, 179.0 / 255.0, 135.0 / 255.0, 1.0 }; // #fab387
    const yellow = [4]f32{ 249.0 / 255.0, 226.0 / 255.0, 175.0 / 255.0, 1.0 }; // #f9e2af
    const green = [4]f32{ 166.0 / 255.0, 227.0 / 255.0, 161.0 / 255.0, 1.0 }; // #a6e3a1
    const teal = [4]f32{ 148.0 / 255.0, 226.0 / 255.0, 213.0 / 255.0, 1.0 }; // #94e2d5
    const sky = [4]f32{ 137.0 / 255.0, 220.0 / 255.0, 235.0 / 255.0, 1.0 }; // #89dceb
    const sapphire = [4]f32{ 116.0 / 255.0, 199.0 / 255.0, 236.0 / 255.0, 1.0 }; // #74c7ec
    const blue = [4]f32{ 137.0 / 255.0, 180.0 / 255.0, 250.0 / 255.0, 1.0 }; // #89b4fa
    const lavender = [4]f32{ 180.0 / 255.0, 190.0 / 255.0, 254.0 / 255.0, 1.0 }; // #b4befe
};

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

// Apply Catppuccin Mocha theme to ImGui
fn applyCatppuccinMochaTheme() void {
    const style = zgui.getStyle();

    // Window colors
    style.setColor(.window_bg, CatppuccinMocha.base);
    style.setColor(.child_bg, CatppuccinMocha.mantle);
    style.setColor(.popup_bg, CatppuccinMocha.surface0);

    // Border colors
    style.setColor(.border, CatppuccinMocha.surface1);
    style.setColor(.border_shadow, CatppuccinMocha.crust);

    // Frame colors (buttons, checkboxes, etc.)
    style.setColor(.frame_bg, CatppuccinMocha.surface0);
    style.setColor(.frame_bg_hovered, CatppuccinMocha.surface1);
    style.setColor(.frame_bg_active, CatppuccinMocha.surface2);

    // Title colors
    style.setColor(.title_bg, CatppuccinMocha.mantle);
    style.setColor(.title_bg_active, CatppuccinMocha.surface0);
    style.setColor(.title_bg_collapsed, CatppuccinMocha.surface0);

    // Menu colors
    style.setColor(.menu_bar_bg, CatppuccinMocha.surface0);

    // Scrollbar colors
    style.setColor(.scrollbar_bg, CatppuccinMocha.surface0);
    style.setColor(.scrollbar_grab, CatppuccinMocha.surface1);
    style.setColor(.scrollbar_grab_hovered, CatppuccinMocha.surface2);
    style.setColor(.scrollbar_grab_active, CatppuccinMocha.overlay0);

    // Checkbox colors
    style.setColor(.check_mark, CatppuccinMocha.green);

    // Slider colors
    style.setColor(.slider_grab, CatppuccinMocha.blue);
    style.setColor(.slider_grab_active, CatppuccinMocha.sapphire);

    // Button colors
    style.setColor(.button, CatppuccinMocha.surface0);
    style.setColor(.button_hovered, CatppuccinMocha.surface1);
    style.setColor(.button_active, CatppuccinMocha.surface2);

    // Header colors (for tabs)
    style.setColor(.header, CatppuccinMocha.surface0);
    style.setColor(.header_hovered, CatppuccinMocha.surface1);
    style.setColor(.header_active, CatppuccinMocha.surface2);

    // Separator colors
    style.setColor(.separator, CatppuccinMocha.surface1);
    style.setColor(.separator_hovered, CatppuccinMocha.surface2);
    style.setColor(.separator_active, CatppuccinMocha.overlay0);

    // Resize grip colors
    style.setColor(.resize_grip, CatppuccinMocha.surface1);
    style.setColor(.resize_grip_hovered, CatppuccinMocha.surface2);
    style.setColor(.resize_grip_active, CatppuccinMocha.overlay0);

    // Tab colors
    style.setColor(.tab, CatppuccinMocha.surface0);
    style.setColor(.tab_hovered, CatppuccinMocha.surface1);
    style.setColor(.tab_selected, CatppuccinMocha.surface2);
    style.setColor(.tab_dimmed, CatppuccinMocha.surface0);
    style.setColor(.tab_dimmed_selected, CatppuccinMocha.surface1);

    // Text colors
    style.setColor(.text, CatppuccinMocha.text);
    style.setColor(.text_disabled, CatppuccinMocha.overlay0);

    // Plot colors
    style.setColor(.plot_lines, CatppuccinMocha.blue);
    style.setColor(.plot_lines_hovered, CatppuccinMocha.sapphire);
    style.setColor(.plot_histogram, CatppuccinMocha.green);
    style.setColor(.plot_histogram_hovered, CatppuccinMocha.teal);

    // Table colors
    style.setColor(.table_header_bg, CatppuccinMocha.surface0);
    style.setColor(.table_border_strong, CatppuccinMocha.surface1);
    style.setColor(.table_border_light, CatppuccinMocha.surface0);
    style.setColor(.table_row_bg, CatppuccinMocha.surface0);
    style.setColor(.table_row_bg_alt, CatppuccinMocha.surface1);

    // Progress bar colors
    style.setColor(.plot_lines, CatppuccinMocha.blue);

    // Drag and drop colors
    style.setColor(.drag_drop_target, CatppuccinMocha.yellow);

    // Navigation colors
    style.setColor(.nav_highlight, CatppuccinMocha.blue);
    style.setColor(.nav_windowing_highlight, CatppuccinMocha.blue);
    style.setColor(.nav_windowing_dim_bg, CatppuccinMocha.overlay0);

    // Modal colors
    style.setColor(.modal_window_dim_bg, CatppuccinMocha.overlay0);
}

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
        zgui.textColored(CatppuccinMocha.red, "Error: {s}", .{state.getErrorMessage() orelse "Unknown error"});
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

            zgui.textColored(CatppuccinMocha.green, "Completed in {s}", .{duration_str});
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

            zgui.textColored(CatppuccinMocha.yellow, "Completed in {s}", .{duration_str});
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
        .color_target_format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_INT,
        .msaa_samples = c.SDL_GPU_SAMPLECOUNT_4,
    });
    defer zgui.backend.deinit();

    // Apply Catppuccin Mocha theme
    applyCatppuccinMochaTheme();

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
            .clear_color = .{ .r = CatppuccinMocha.base[0], .g = CatppuccinMocha.base[1], .b = CatppuccinMocha.base[2], .a = CatppuccinMocha.base[3] },
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
