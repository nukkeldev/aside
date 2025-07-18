const std = @import("std");

const SDL = @import("ffi.zig").SDL;
const c = @import("ffi.zig").c;
const zgui = @import("zgui");
const tracy = @import("perf/tracy.zig");

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

    // Thread state
    worker_threads: std.ArrayList(std.Thread),
    coordinator_thread: ?std.Thread = null,
    is_running: bool = false,
    should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    has_results: bool = false,
    has_error: bool = false,

    // Work queue and results
    work_queue: std.ArrayList(QueueItem),
    results: std.ArrayList([]const u8),
    processed_urls: std.StringHashMap(void), // To avoid duplicate processing
    error_message: ?[]const u8 = null,

    // Statistics
    total_found: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    total_processed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // Timing information
    start_time: i64 = 0,
    last_activity_time: i64 = 0,
    links_per_second: f64 = 0.0,

    // Threading
    allocator: std.mem.Allocator,
    work_mutex: std.Thread.Mutex = .{},
    results_mutex: std.Thread.Mutex = .{},
    work_condition: std.Thread.Condition = .{},
    thread_mutex: std.Thread.Mutex = .{}, // Protect thread management operations

    const QueueItem = struct {
        url: []const u8,
        depth: usize,
        parent: ?[]const u8 = null,
    };

    pub fn init(allocator: std.mem.Allocator) LinkFinderState {
        return LinkFinderState{
            .worker_threads = std.ArrayList(std.Thread).init(allocator),
            .work_queue = std.ArrayList(QueueItem).init(allocator),
            .results = std.ArrayList([]const u8).init(allocator),
            .processed_urls = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LinkFinderState) void {
        // Stop all threads
        self.should_stop.store(true, .release);
        self.work_condition.broadcast();

        // Join coordinator thread
        if (self.coordinator_thread) |thread| {
            thread.join();
        }

        // Join worker threads
        for (self.worker_threads.items) |thread| {
            thread.join();
        }
        self.worker_threads.deinit();

        // Clean up resources
        self.work_mutex.lock();
        for (self.work_queue.items) |item| {
            self.allocator.free(item.url);
            if (item.parent) |parent| {
                self.allocator.free(parent);
            }
        }
        self.work_queue.deinit();
        self.work_mutex.unlock();

        self.results_mutex.lock();
        for (self.results.items) |result| {
            self.allocator.free(result);
        }
        self.results.deinit();
        self.results_mutex.unlock();

        self.processed_urls.deinit();

        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    pub fn clearResults(self: *LinkFinderState) void {
        self.thread_mutex.lock();
        defer self.thread_mutex.unlock();

        // Only stop threads if they are actually running
        if (self.is_running) {
            // Stop all threads
            self.should_stop.store(true, .release);
            self.work_condition.broadcast();

            // Small delay to let threads react to the stop signal
            std.time.sleep(50 * std.time.ns_per_ms);

            // Join coordinator thread if it exists and is joinable
            if (self.coordinator_thread) |thread| {
                thread.join();
                self.coordinator_thread = null;
            }

            // Join worker threads - they should have already finished due to coordinator cleanup
            // But we'll try to join them anyway to be safe
            for (self.worker_threads.items) |thread| {
                thread.join();
            }
            self.worker_threads.clearRetainingCapacity();
        } else {
            // If not running, just clear the thread list
            self.worker_threads.clearRetainingCapacity();
            self.coordinator_thread = null;
        }

        // Clear work queue
        self.work_mutex.lock();
        for (self.work_queue.items) |item| {
            self.allocator.free(item.url);
            if (item.parent) |parent| {
                self.allocator.free(parent);
            }
        }
        self.work_queue.clearRetainingCapacity();
        self.work_mutex.unlock();

        // Clear results
        self.results_mutex.lock();
        for (self.results.items) |result| {
            self.allocator.free(result);
        }
        self.results.clearRetainingCapacity();
        self.results_mutex.unlock();

        // Clear processed URLs
        self.processed_urls.clearRetainingCapacity();

        // Clear error message
        if (self.error_message) |msg| {
            self.allocator.free(msg);
            self.error_message = null;
        }

        // Reset state
        self.has_results = false;
        self.has_error = false;
        self.is_running = false;
        self.should_stop.store(false, .release);
        self.total_found.store(0, .release);
        self.total_processed.store(0, .release);
        self.start_time = 0;
        self.last_activity_time = 0;
        self.links_per_second = 0.0;
    }
};

// -- Multi-threaded LinkFinder Worker -- //

const WorkerParams = struct {
    state: *LinkFinderState,
    filters: []const []const u8,
    debug: bool,
    recursion_limit: usize,
    worker_id: usize,
};

fn linkFinderWorker(params: *WorkerParams) void {
    defer params.state.allocator.destroy(params);

    var arena = std.heap.ArenaAllocator.init(params.state.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Create LinkFinder instance for this worker
    const link_finder = LinkFinder.init(arena_allocator, params.debug, params.filters) catch |err| {
        params.state.results_mutex.lock();
        defer params.state.results_mutex.unlock();

        if (params.state.error_message == null) {
            params.state.error_message = std.fmt.allocPrint(params.state.allocator, "Worker {}: Failed to initialize LinkFinder: {}", .{ params.worker_id, err }) catch "Failed to initialize LinkFinder";
            params.state.has_error = true;
        }
        return;
    };
    defer link_finder.deinit();

    while (!params.state.should_stop.load(.acquire)) {
        // Get work item from queue
        var work_item: ?LinkFinderState.QueueItem = null;

        params.state.work_mutex.lock();
        while (params.state.work_queue.items.len == 0 and !params.state.should_stop.load(.acquire)) {
            params.state.work_condition.wait(&params.state.work_mutex);
        }

        if (params.state.should_stop.load(.acquire)) {
            params.state.work_mutex.unlock();
            break;
        }

        if (params.state.work_queue.items.len > 0) {
            work_item = params.state.work_queue.orderedRemove(0);
        }
        params.state.work_mutex.unlock();

        if (work_item) |item| {
            if (params.debug) {
                std.log.debug("Worker {}: Processing {s} at depth {}", .{ params.worker_id, item.url, item.depth });
            }

            // Process the URL
            const entrypoint = LinkFinder.Source{
                .link = item.url,
                .depth = item.depth,
                .parent = item.parent,
            };

            const sources = link_finder.findLinksLeaky(arena_allocator, &entrypoint) catch |err| {
                if (params.debug) {
                    std.log.debug("Worker {}: Error processing {s}: {}", .{ params.worker_id, item.url, err });
                }

                // Clean up this work item
                params.state.allocator.free(item.url);
                if (item.parent) |parent| {
                    params.state.allocator.free(parent);
                }
                continue;
            };

            // Add results and new work items
            params.state.results_mutex.lock();
            var new_links_found: u32 = 0;
            var iter = sources.sources.valueIterator();
            while (iter.next()) |source| {
                // Add to results
                const result = std.fmt.allocPrint(params.state.allocator, "{s} (depth: {}, found by worker {})", .{ source.link, source.depth, params.worker_id }) catch continue;
                params.state.results.append(result) catch continue;
                new_links_found += 1;

                // Add to work queue if recursive and within depth limit
                // The next depth should be source.depth + 1
                const next_depth = source.depth + 1;
                if (params.debug) {
                    std.log.debug("Worker {}: Checking recursion for {s} - current depth: {}, next depth: {}, limit: {}, recursive: {}", .{ params.worker_id, source.link, source.depth, next_depth, params.recursion_limit, params.state.recursive });
                }
                if (params.state.recursive and next_depth < params.recursion_limit) {
                    // Check if we've already processed this URL
                    if (!params.state.processed_urls.contains(source.link)) {
                        if (params.debug) {
                            std.log.debug("Worker {}: Adding {s} to work queue at depth {}", .{ params.worker_id, source.link, next_depth });
                        }
                        params.state.work_mutex.lock();
                        const new_url = params.state.allocator.dupe(u8, source.link) catch {
                            params.state.work_mutex.unlock();
                            continue;
                        };
                        const new_parent = if (source.parent) |p| params.state.allocator.dupe(u8, p) catch null else null;

                        const new_item = LinkFinderState.QueueItem{
                            .url = new_url,
                            .depth = next_depth,
                            .parent = new_parent,
                        };

                        params.state.work_queue.append(new_item) catch {
                            params.state.allocator.free(new_url);
                            if (new_parent) |p| params.state.allocator.free(p);
                        };
                        params.state.processed_urls.put(new_url, {}) catch {};
                        params.state.work_condition.signal();
                        params.state.work_mutex.unlock();
                    } else {
                        if (params.debug) {
                            std.log.debug("Worker {}: Skipping {s} - already processed", .{ params.worker_id, source.link });
                        }
                    }
                } else {
                    if (params.debug) {
                        std.log.debug("Worker {}: Skipping {s} - recursion check failed", .{ params.worker_id, source.link });
                    }
                }
            }
            params.state.results_mutex.unlock();

            // Update statistics
            _ = params.state.total_found.fetchAdd(new_links_found, .acq_rel);
            _ = params.state.total_processed.fetchAdd(1, .acq_rel);

            // Update activity time for rate calculation
            params.state.last_activity_time = std.time.milliTimestamp();

            if (params.debug) {
                std.log.debug("Worker {}: Found {} links from {s}", .{ params.worker_id, new_links_found, item.url });
            }

            // Clean up this work item
            params.state.allocator.free(item.url);
            if (item.parent) |parent| {
                params.state.allocator.free(parent);
            }
        }
    }
}

// Coordinator thread to manage the overall process
fn linkFinderCoordinator(params: *WorkerParams) void {
    defer params.state.allocator.destroy(params);

    // Make a copy of filters for workers to use
    var filters_copy = std.ArrayList([]const u8).init(params.state.allocator);
    for (params.filters) |filter| {
        const filter_copy = params.state.allocator.dupe(u8, filter) catch filter;
        filters_copy.append(filter_copy) catch {};
    }

    defer {
        // Clean up our copy of filters
        for (filters_copy.items) |filter| {
            params.state.allocator.free(filter);
        }
        filters_copy.deinit();

        // Clean up original filters
        for (params.filters) |filter| {
            params.state.allocator.free(filter);
        }
        params.state.allocator.free(params.filters);
    }

    // Start worker threads
    const worker_count = @as(usize, @intCast(params.state.worker_count));
    for (0..worker_count) |i| {
        const worker_params = params.state.allocator.create(WorkerParams) catch continue;
        worker_params.* = WorkerParams{
            .state = params.state,
            .filters = filters_copy.items,
            .debug = params.debug,
            .recursion_limit = params.recursion_limit,
            .worker_id = i,
        };

        const thread = std.Thread.spawn(.{}, linkFinderWorker, .{worker_params}) catch continue;
        params.state.worker_threads.append(thread) catch continue;
    }

    // Wait for all work to be completed
    var last_queue_size: usize = std.math.maxInt(usize);
    var idle_cycles: u32 = 0;

    while (!params.state.should_stop.load(.acquire)) {
        std.time.sleep(100 * std.time.ns_per_ms); // 100ms

        params.state.work_mutex.lock();
        const current_queue_size = params.state.work_queue.items.len;
        params.state.work_mutex.unlock();

        if (current_queue_size == 0) {
            idle_cycles += 1;
            // If queue has been empty for 500ms, we're probably done
            if (idle_cycles >= 5) {
                break;
            }
        } else {
            idle_cycles = 0;
        }

        if (current_queue_size == last_queue_size and current_queue_size > 0) {
            // Queue isn't changing, might be stuck
            idle_cycles += 1;
            if (idle_cycles >= 10) { // 1 second of no progress
                break;
            }
        }

        last_queue_size = current_queue_size;
    }

    // Signal completion
    params.state.should_stop.store(true, .release);
    params.state.work_condition.broadcast();

    // Wait for all workers to finish
    for (params.state.worker_threads.items) |thread| {
        thread.join();
    }

    // Clear the worker threads list since we've joined them
    params.state.thread_mutex.lock();
    params.state.worker_threads.clearRetainingCapacity();
    params.state.is_running = false;
    params.state.has_results = true;
    params.state.thread_mutex.unlock();
}

// -- Main -- //

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
}fn renderLinkFinderTab(state: *LinkFinderState) void {
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

    zgui.beginDisabled(.{ .disabled = !has_url or state.is_running });
    if (zgui.button("Find Links", .{})) {
        // Ensure we're not already running
        if (state.is_running) {
            return;
        }

        // Clear previous results (this handles thread cleanup)
        state.clearResults();

        // Reset statistics and timing
        state.total_found.store(0, .release);
        state.total_processed.store(0, .release);
        state.start_time = std.time.milliTimestamp();
        state.last_activity_time = state.start_time;
        state.links_per_second = 0.0;

        // Prepare parameters
        const url = state.allocator.dupe(u8, state.url_buffer[0..url_len]) catch {
            state.error_message = state.allocator.dupe(u8, "Failed to allocate memory for URL") catch "Memory error";
            state.has_error = true;
            return;
        };

        var filters = std.ArrayList([]const u8).init(state.allocator);
        defer filters.deinit();

        const filter_len = std.mem.indexOfScalar(u8, &state.filter_buffer, 0) orelse state.filter_buffer.len;
        if (filter_len > 0) {
            const filter = state.allocator.dupe(u8, state.filter_buffer[0..filter_len]) catch {
                state.allocator.free(url);
                state.error_message = state.allocator.dupe(u8, "Failed to allocate memory for filter") catch "Memory error";
                state.has_error = true;
                return;
            };
            filters.append(filter) catch {
                state.allocator.free(url);
                state.allocator.free(filter);
                state.error_message = state.allocator.dupe(u8, "Failed to add filter") catch "Memory error";
                state.has_error = true;
                return;
            };
        }

        // Add initial URL to work queue
        state.work_mutex.lock();
        defer state.work_mutex.unlock();

        const initial_item = LinkFinderState.QueueItem{
            .url = url,
            .depth = 0,
            .parent = null,
        };

        state.work_queue.append(initial_item) catch {
            state.allocator.free(url);
            state.error_message = state.allocator.dupe(u8, "Failed to add initial URL to work queue") catch "Memory error";
            state.has_error = true;
            return;
        };
        state.processed_urls.put(url, {}) catch {};

        // Create parameters for coordinator thread
        const params = state.allocator.create(WorkerParams) catch {
            state.error_message = state.allocator.dupe(u8, "Failed to allocate memory for parameters") catch "Memory error";
            state.has_error = true;
            return;
        };

        params.* = WorkerParams{
            .state = state,
            .filters = filters.toOwnedSlice() catch &[_][]const u8{},
            .debug = state.debug,
            .recursion_limit = @intCast(state.recursion_limit),
            .worker_id = 0, // Coordinator
        };

        // Start coordinator thread
        state.thread_mutex.lock();
        state.is_running = true;
        state.has_error = false;
        state.should_stop.store(false, .release);

        const thread = std.Thread.spawn(.{}, linkFinderCoordinator, .{params}) catch {
            state.is_running = false;
            state.error_message = state.allocator.dupe(u8, "Failed to start coordinator thread") catch "Thread error";
            state.has_error = true;
            state.allocator.destroy(params);
            state.thread_mutex.unlock();
            return;
        };

        // Store the coordinator thread so we can join it later
        state.coordinator_thread = thread;
        state.thread_mutex.unlock();

        // Signal workers to start
        state.work_condition.broadcast();
    }
    zgui.endDisabled();

    zgui.sameLine(.{});

    // Stop button (only shown when running)
    if (state.is_running) {
        if (zgui.button("Stop", .{})) {
            state.clearResults();
        }
        zgui.sameLine(.{});
    }

    if (zgui.button("Clear Results", .{})) {
        state.clearResults();
    }

    // Status display
    if (state.is_running) {
        zgui.text("Finding links...", .{});
        zgui.sameLine(.{});

        // Simple spinning indicator
        const time = @as(f32, @floatFromInt(@rem(std.time.milliTimestamp(), 2000))) / 2000.0;
        const spinner_chars = [_][]const u8{ "|", "/", "-", "\\" };
        const char_idx = @as(usize, @intFromFloat(time * 4)) % 4;
        zgui.text("{s}", .{spinner_chars[char_idx]});

        // Real-time statistics
        const found = state.total_found.load(.acquire);
        const processed = state.total_processed.load(.acquire);

        state.work_mutex.lock();
        const queue_size = state.work_queue.items.len;
        state.work_mutex.unlock();

        // Calculate timing information
        const current_time = std.time.milliTimestamp();
        const elapsed_ms = current_time - state.start_time;
        const elapsed_seconds = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;

        // Calculate processing rate
        if (elapsed_seconds > 0) {
            state.links_per_second = @as(f64, @floatFromInt(found)) / elapsed_seconds;
        }

        // Display main statistics
        zgui.text("Found: {} | Processed: {} | Queue: {} | Workers: {}", .{ found, processed, queue_size, state.worker_threads.items.len });

        // Display timing information
        if (elapsed_ms > 0) {
            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const duration_str = formatDuration(arena_allocator, elapsed_ms) catch "N/A";
            zgui.text("Duration: {s} | Rate: {d:.1} links/sec", .{ duration_str, state.links_per_second });

            // Estimate time remaining (rough estimate based on queue size and processing rate)
            if (queue_size > 0 and processed > 0 and elapsed_seconds > 1.0) {
                // Calculate pages processed per second instead of links per second for ETA
                const pages_per_second = @as(f64, @floatFromInt(processed)) / elapsed_seconds;
                if (pages_per_second > 0.01) {
                    const estimated_remaining_seconds = @as(f64, @floatFromInt(queue_size)) / pages_per_second;
                    const estimated_remaining_ms = @as(i64, @intFromFloat(estimated_remaining_seconds * 1000.0));
                    const eta_str = formatDuration(arena_allocator, estimated_remaining_ms) catch "N/A";
                    zgui.text("Estimated time remaining: {s} (based on {d:.2} pages/sec)", .{ eta_str, pages_per_second });
                }
            }

            // Progress indicator for recursive searches
            if (state.recursive and processed > 0) {
                const progress_ratio = if (queue_size == 0) 1.0 else @as(f32, @floatFromInt(processed)) / @as(f32, @floatFromInt(processed + queue_size));
                zgui.progressBar(.{ .fraction = progress_ratio });
            }
        }
    }

    if (state.has_error) {
        zgui.textColored(.{ 1.0, 0.0, 0.0, 1.0 }, "Error: {s}", .{state.error_message orelse "Unknown error"});
    }

    // Results display
    if (state.has_results and state.results.items.len > 0) {
        zgui.separator();

        // Show completion summary if not running
        if (!state.is_running and state.start_time > 0) {
            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const final_time = state.last_activity_time;
            const total_duration = final_time - state.start_time;
            const duration_str = formatDuration(arena_allocator, total_duration) catch "N/A";

            const found = state.total_found.load(.acquire);
            const processed = state.total_processed.load(.acquire);

            zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Completed in {s}", .{duration_str});
            zgui.text("Final stats: {} links found, {} pages processed", .{ found, processed });

            if (total_duration > 0) {
                const final_rate = @as(f64, @floatFromInt(found)) / (@as(f64, @floatFromInt(total_duration)) / 1000.0);
                zgui.text("Average rate: {d:.1} links/sec", .{final_rate});
            }
        }

        zgui.text("Found {} links:", .{state.results.items.len});

        // Calculate remaining height for results
        const available_height = zgui.getContentRegionAvail()[1] - 20; // Leave some padding
        if (zgui.beginChild("results", .{ .w = 0, .h = available_height, .child_flags = .{ .border = true } })) {
            state.results_mutex.lock();
            defer state.results_mutex.unlock();

            for (state.results.items, 0..) |result, i| {
                zgui.text("{}: {s}", .{ i + 1, result });
            }
        }
        zgui.endChild();
    } else if (state.has_results) {
        zgui.separator();

        // Show completion summary even when no results
        if (!state.is_running and state.start_time > 0) {
            var arena = std.heap.ArenaAllocator.init(state.allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const final_time = state.last_activity_time;
            const total_duration = final_time - state.start_time;
            const duration_str = formatDuration(arena_allocator, total_duration) catch "N/A";

            const processed = state.total_processed.load(.acquire);

            zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Completed in {s}", .{duration_str});
            zgui.text("Final stats: {} pages processed", .{processed});
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

    fz.replace(@src(), "loop");
    var current_window_size: [2]f32 = .{ 1280, 720 };

    outer: while (true) {
        fz.push(@src(), "poll events");
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            _ = zgui.backend.processEvent(&event);
            if (event.type == c.SDL_EVENT_QUIT) {
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
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
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
