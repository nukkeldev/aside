//! Handles the state and rendering of a GUI for [LinkFinder](../tools/LinkFinder.zig)

// -- Imports -- //

const std = @import("std");
const zgui = @import("zgui");

const themes = @import("themes.zig");
const c = @import("../ffi.zig").c;

const LinkFinder = @import("../tools/LinkFinder.zig");

// ---

/// How long for the loading spinner to complete a full cycle.
const SPINNER_PERIOD_MS: f32 = 2000;
/// Characters used for the loading spinner.
const SPINNER_CHARS: []const []const u8 = &.{ "|", "/", "-", "\\" };

const log = std.log.scoped(.lf);

// ---

allocator: std.mem.Allocator,

/// Whether to enable debug outputs in the console for LinkFinder.
debug: bool = false,

/// Buffer for the URL input.
url_buffer: [512:0]u8 = [_:0]u8{0} ** 512,
// TODO: Need a way to handle multiple filters.
/// Buffer for the filter input (regex).
filter_buffer: [256:0]u8 = [_:0]u8{0} ** 256,

/// Whether to perform recursive link finding.
recursive: bool = false,
/// Recursion limit.
recursion_limit: i32 = 2,

/// Number of worker threads to use for link finding.
worker_count: i32 = 4,

link_finder: ?LinkFinder = null,
processing_state: ?LinkFinder.ProcessingState = null,

// -- Initialization -- //

pub fn init(allocator: std.mem.Allocator) @This() {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *@This()) void {
    // First cleanup processing state (this will stop threads and cleanup resources)
    if (self.processing_state) |*state| {
        state.deinit();
        self.processing_state = null;
    }

    // Then cleanup LinkFinder instance
    if (self.link_finder) |*lf| {
        lf.deinit();
        self.link_finder = null;
    }
}

// -- Usage -- //

/// Clears the results and resets the processing state.
pub fn clearResults(self: *@This()) void {
    if (self.processing_state) |*state| state.clearResults();
}

// -- Getters -- //

pub fn isRunning(self: *const @This()) bool {
    return if (self.processing_state) |*state| state.is_running else false;
}

pub fn hasResults(self: *const @This()) bool {
    return if (self.processing_state) |*state| state.has_results else false;
}

pub fn hasError(self: *const @This()) bool {
    return if (self.processing_state) |*state| state.has_error else false;
}

pub fn getErrorMessage(self: *const @This()) ?[]const u8 {
    return if (self.processing_state) |*state| state.error_message else null;
}

pub fn getResults(self: *const @This()) []const []const u8 {
    return if (self.processing_state) |*state| state.results.items else &[_][]const u8{};
}

pub const Stats = struct {
    found: u32 = 0,
    processed: u32 = 0,
    queue_size: usize = 0,
    worker_count: usize = 0,
    start_time_ms: i64 = 0,
    last_activity_time_ms: i64 = 0,
};

pub fn getStats(self: *@This()) Stats {
    if (self.processing_state) |*state| {
        state.work_mutex.lock();
        const queue_size = state.work_queue.items.len;
        state.work_mutex.unlock();

        return Stats{
            .found = state.total_found.load(.acquire),
            .processed = state.total_processed.load(.acquire),
            .queue_size = queue_size,
            .worker_count = state.worker_threads.items.len,
            .start_time_ms = state.start_time,
            .last_activity_time_ms = state.last_activity_time,
        };
    }
    return Stats{};
}

// -- Usage -- //

/// Starts the link finding process with the current configuration
fn startLinkFinding(state: *@This(), url_len: usize) !void {
    if (state.isRunning()) {
        log.warn("Link finding is already running, stopping current process.", .{});
        state.stopLinkFinding();
    }

    // Clear the previous results and processing state.
    state.clearResults();

    // Prepare a new filters array for the LF.
    var filters = std.ArrayList([]const u8).init(state.allocator);
    defer {
        for (filters.items) |filter| state.allocator.free(filter);
        filters.deinit();
    }

    const filter_len = std.mem.indexOfScalar(u8, &state.filter_buffer, 0) orelse state.filter_buffer.len;
    if (filter_len > 0) {
        const filter = try state.allocator.dupe(u8, state.filter_buffer[0..filter_len]);
        try filters.append(filter);
    }

    // Create the LF and PS.
    state.link_finder = try LinkFinder.init(state.allocator, state.debug, filters.items);
    state.processing_state = LinkFinder.ProcessingState.init(state.allocator);

    // Start finding links.
    const config = LinkFinder.MultiThreadedConfig{
        .recursive = state.recursive,
        .recursion_limit = @intCast(state.recursion_limit),
        .worker_count = @intCast(state.worker_count),
    };

    const url = state.url_buffer[0..url_len];
    try state.link_finder.?.findLinksMultiThreaded(&state.processing_state.?, url, config);
}

// TODO: We need to interrupt the workers properly.
/// Stops the link finding process and cleans up resources
fn stopLinkFinding(state: *@This()) void {
    // Stop the processing by clearing results and cleaning up
    state.clearResults();
    // Also cleanup LinkFinder instance
    if (state.link_finder) |*lf| {
        lf.deinit();
        state.link_finder = null;
    }
}

// -- Rendering -- //

pub fn render(state: *@This()) !void {
    state.renderInputControls();
    zgui.separator();
    try state.renderActionButtons();
    try state.renderStatusDisplay();
    try state.renderResults();
}

/// Renders the input controls section (URL, filter, options)
fn renderInputControls(state: *@This()) void {
    zgui.text("URL:", .{});
    _ = zgui.inputTextWithHint("##url", .{ .buf = &state.url_buffer, .hint = "e.g. https://example.com" });

    zgui.text("Filter (regex):", .{});
    _ = zgui.inputTextWithHint("##filter", .{ .buf = &state.filter_buffer, .hint = "e.g. ^.*\\.pdf$" });

    if (zgui.checkbox("Recursive", .{ .v = &state.recursive })) {
        log.debug("Recursive mode: {}", .{state.recursive});
    }
    if (zgui.checkbox("Debug", .{ .v = &state.debug })) {
        log.debug("Debug mode: {}", .{state.debug});
    }

    if (state.recursive) {
        _ = zgui.sliderInt("Recursion Limit", .{ .v = &state.recursion_limit, .min = 1, .max = 10 });
    }

    _ = zgui.sliderInt("Worker Threads", .{ .v = &state.worker_count, .min = 1, .max = 16 }); // TODO: Retrieve CPU count dynamically
}

/// Renders the action buttons (Find Links, Stop, Clear Results, Save Results)
fn renderActionButtons(state: *@This()) !void {
    const url_len = std.mem.indexOfScalar(u8, &state.url_buffer, 0) orelse state.url_buffer.len;
    const has_url = url_len > 0 and
        (std.mem.startsWith(u8, state.url_buffer[0..url_len], "http://") or
            std.mem.startsWith(u8, state.url_buffer[0..url_len], "https://"));

    // Find Links button
    zgui.beginDisabled(.{ .disabled = !has_url or state.isRunning() });
    if (zgui.button("Find Links", .{})) {
        try state.startLinkFinding(url_len);
    }
    zgui.endDisabled();

    zgui.sameLine(.{});

    // Stop button (only shown when running)
    if (state.isRunning()) {
        if (zgui.button("Stop", .{})) {
            state.stopLinkFinding();
        }
        zgui.sameLine(.{});
    }

    // Clear Results button
    if (zgui.button("Clear Results", .{})) {
        state.clearResults();
        // Also cleanup LinkFinder instance if not running
        if (!state.isRunning() and state.link_finder != null) {
            if (state.link_finder) |*lf| {
                lf.deinit();
                state.link_finder = null;
            }
        }
    }

    zgui.sameLine(.{});

    // Save Results button
    zgui.beginDisabled(.{ .disabled = !state.hasResults() or state.getResults().len == 0 });
    if (zgui.button("Save Results", .{})) {
        try saveResultsToFile(state);
    }
    zgui.endDisabled();
}

/// Renders the status display section (spinner, stats, progress)
fn renderStatusDisplay(state: *@This()) !void {
    if (state.isRunning()) {
        zgui.text("Finding links...", .{});
        zgui.sameLine(.{});

        // Simple spinning indicator
        const time = @as(f32, @floatFromInt(@rem(std.time.milliTimestamp(), @as(i64, @intFromFloat(SPINNER_PERIOD_MS))))) / SPINNER_PERIOD_MS;
        zgui.text("{s}", .{SPINNER_CHARS[@as(usize, @intFromFloat(time * @as(f32, SPINNER_CHARS.len))) % SPINNER_CHARS.len]});

        // Real-time statistics
        const stats = state.getStats();

        // Calculate timing information
        const current_time = std.time.milliTimestamp();
        const elapsed_ms: i64 = current_time - stats.start_time_ms;
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ms)) / std.time.ms_per_s;
        const elapsed_ns: i64 = elapsed_ms * std.time.ns_per_ms;

        // Calculate processing rate
        var links_per_second: f64 = 0.0;
        if (elapsed_s > 0) {
            links_per_second = @as(f64, @floatFromInt(stats.found)) / elapsed_s;
        }

        // Display main statistics
        zgui.text("Found: {} | Processed: {} | Queue: {} | Workers: {}", .{ stats.found, stats.processed, stats.queue_size, stats.worker_count });

        // Display timing information
        if (elapsed_ms > 0) {
            zgui.text("Duration: {s} | Rate: {d:.1} links/sec", .{ std.fmt.fmtDurationSigned(elapsed_ns), links_per_second });

            // Estimate time remaining (rough estimate based on queue size and processing rate)
            if (stats.queue_size > 0 and stats.processed > 0 and elapsed_s > 1.0) {
                // Calculate pages processed per second instead of links per second for ETA
                const pages_per_second = @as(f64, @floatFromInt(stats.processed)) / elapsed_s;
                if (pages_per_second > 0.01) {
                    const estimated_remaining_seconds = @as(f64, @floatFromInt(stats.queue_size)) / pages_per_second;
                    const estimated_remaining_ms = @as(i64, @intFromFloat(estimated_remaining_seconds * 1e3));
                    zgui.text("Estimated time remaining: {} (based on {d:.2} pages/sec)", .{ std.fmt.fmtDurationSigned(estimated_remaining_ms * std.time.ns_per_ms), pages_per_second });
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
}

/// Renders the results section
fn renderResults(state: *@This()) !void {
    const results = state.getResults();
    if (state.hasResults() and results.len > 0) {
        zgui.separator();

        // Show completion summary if not running
        if (!state.isRunning()) {
            const stats = state.getStats();
            const total_duration_ms = stats.last_activity_time_ms - stats.start_time_ms;

            zgui.textColored(themes.CatppuccinMocha.green, "Completed in {}", .{std.fmt.fmtDurationSigned(@intCast(total_duration_ms * std.time.ns_per_ms))});
            zgui.text("Final stats: {} links found, {} pages processed", .{ stats.found, stats.processed });

            if (total_duration_ms > 0) {
                const final_rate = @as(f64, @floatFromInt(stats.found)) / (@as(f64, @floatFromInt(total_duration_ms)) / 1e3);
                zgui.text("Average rate: {d:.1} links/sec", .{final_rate});
            }
        }

        zgui.text("Found {} links:", .{results.len});

        // Calculate remaining height for results
        const available_height = zgui.getContentRegionAvail()[1] - 20; // Leave some padding
        if (zgui.beginChild("results", .{ .w = 0, .h = available_height, .child_flags = .{ .border = true } })) {
            for (results, 0..) |result, i| {
                const index = i + 1;
                zgui.text("{}: ", .{index});
                zgui.sameLine(.{});
                const split = std.mem.indexOfAny(u8, result, &std.ascii.whitespace) orelse result.len;
                const link = try state.allocator.dupeZ(u8, result[0..split]);
                defer state.allocator.free(link);
                if (zgui.textLink(link)) {
                    // Open the link in the default browser
                    const url_z = try state.allocator.dupeZ(u8, result);
                    defer state.allocator.free(url_z);
                    _ = c.SDL_OpenURL(url_z.ptr);
                }
                if (split < result.len) {
                    zgui.sameLine(.{});
                    zgui.text("{s}", .{result[split + 1 ..]}); // Show the rest of the link after whitespace
                }
            }
        }
        zgui.endChild();
    } else if (state.hasResults()) {
        zgui.separator();
        zgui.text("No links found.", .{});
    }
}

// -- Helpers -- //

// TODO: Allow the user to specify a custom file to output to.
/// Saves the current results to a timestamped file in the current directory.
fn saveResultsToFile(state: *@This()) !void {
    const results = state.getResults();
    if (results.len == 0) {
        log.warn("No results to save.", .{});
        return;
    }

    const timestamp = std.time.timestamp();
    const filename = try std.fmt.allocPrint(state.allocator, "links_{}.txt", .{timestamp});
    defer state.allocator.free(filename);

    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    const stats = state.getStats();
    const total_duration_ms = stats.last_activity_time_ms - stats.start_time_ms;

    try file.writer().print("Link Export\n", .{});
    try file.writer().print("Generated: {}\n", .{timestamp});
    try file.writer().print("Total Links: {}\n", .{results.len});
    try file.writer().print("Pages Processed: {}\n", .{stats.processed});

    if (total_duration_ms > 0) {
        try file.writer().print("Processing Time: {}\n", .{std.fmt.fmtDurationSigned(@intCast(total_duration_ms * 1_000_000))});
    }
    try file.writer().print("\n", .{});
    for (results, 1..) |link, index| {
        try file.writer().print("{}: {s}\n", .{ index, link });
    }
}
