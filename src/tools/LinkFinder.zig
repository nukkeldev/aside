const std = @import("std");
const mvzr = @import("mvzr");

// ---

const LinkFinder = @This();

// -- Multi-threaded Processing Types -- //

pub const ProcessingState = struct {
    // Threading
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

    pub fn init(allocator: std.mem.Allocator) ProcessingState {
        return ProcessingState{
            .worker_threads = std.ArrayList(std.Thread).init(allocator),
            .work_queue = std.ArrayList(QueueItem).init(allocator),
            .results = std.ArrayList([]const u8).init(allocator),
            .processed_urls = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProcessingState) void {
        // Stop all threads with more aggressive cleanup
        self.should_stop.store(true, .release);
        self.work_condition.broadcast();

        // Give threads time to exit
        std.time.sleep(300 * std.time.ns_per_ms);

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

    pub fn clearResults(self: *ProcessingState) void {
        self.thread_mutex.lock();
        defer self.thread_mutex.unlock();

        // Only stop threads if they are actually running
        if (self.is_running) {
            // Stop all threads
            self.should_stop.store(true, .release);
            self.work_condition.broadcast();

            // Give threads more time to react to the stop signal
            std.time.sleep(200 * std.time.ns_per_ms);

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

            // Mark as no longer running
            self.is_running = false;
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
        self.should_stop.store(false, .release);
        self.total_found.store(0, .release);
        self.total_processed.store(0, .release);
        self.start_time = 0;
        self.last_activity_time = 0;
    }
};

pub const MultiThreadedConfig = struct {
    recursive: bool = false,
    recursion_limit: usize = 2,
    worker_count: usize = 4,
};

// -- Fields -- //

debug: bool,
filters: []mvzr.Regex,
allocator: std.mem.Allocator,

// -- Types -- //

pub const Source = struct {
    parent: ?[]const u8 = null,
    // children: ?[]*const Source = null,

    depth: usize = 0,
    link: []const u8,

    // ---

    pub fn format(value: *const Source, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("Source(url: {s}, depth: {})", .{ value.link, value.depth });
    }

    pub fn dupe(self: *const Source, allocator: std.mem.Allocator) !Source {
        return Source{
            .parent = if (self.parent) |p| try allocator.dupe(u8, p) else null,
            .depth = self.depth,
            .link = try allocator.dupe(u8, self.link),
        };
    }
};

pub const Sources = struct {
    sources: std.StringHashMap(Source),

    // ---

    pub fn init(allocator: std.mem.Allocator) Sources {
        return Sources{
            .sources = std.StringHashMap(Source).init(allocator),
        };
    }

    pub fn deinit(self: *Sources) void {
        self.sources.deinit();
    }
};

// -- Initialization -- //

pub fn init(allocator: std.mem.Allocator, debug: bool, filter_patterns: []const []const u8) !LinkFinder {
    var filters = try allocator.alloc(mvzr.Regex, filter_patterns.len);

    var i: usize = 0;
    for (filter_patterns) |pattern| {
        filters[i] = mvzr.Regex.compile(pattern) orelse {
            std.log.err("Failed to compiled regex pattern '{s}'! Skipping.", .{pattern});
            continue;
        };
        i += 1;
    }

    return LinkFinder{
        .debug = debug,
        .filters = filters[0..i],
        .allocator = allocator,
    };
}

pub fn deinit(self: *const LinkFinder) void {
    self.allocator.free(self.filters);
}

// -- Link Finding -- //

fn matchesFilter(self: *const LinkFinder, link: []const u8) bool {
    if (self.filters.len == 0) return true;

    for (self.filters) |*regex| {
        if (regex.match(link)) |match| {
            if (self.debug) std.log.debug("Link '{s}' matches filter at {}.", .{ link, match });
            return true;
        }
    }

    if (self.debug) std.log.debug("Link '{s}' does not match any filter", .{link});
    return false;
}

pub fn findLinksLeakyRecurse(
    lf: *const LinkFinder,
    allocator: std.mem.Allocator,
    entrypoint: Source,
    limit: usize,
) !Sources {
    var sources_queue = std.ArrayList([]const u8).init(allocator);
    defer sources_queue.deinit();

    var sources = Sources.init(allocator);
    var first = true;

    while (first or sources_queue.items.len > 0) {
        if (lf.debug) {
            std.log.debug("Queue:", .{});
            for (sources_queue.items) |item| {
                std.log.debug("  - {s}", .{item});
            }
        }

        const source = if (first) entrypoint else sources.sources.get(sources_queue.orderedRemove(0)) orelse unreachable;
        first = false;

        if (lf.debug) std.log.debug("Processing source: {f}", .{source});

        var found_links = try lf.findLinksLeaky(allocator, &source);
        if (lf.debug) std.log.debug("Found {} links in source: {f}", .{ found_links.sources.count(), source });

        var iter = found_links.sources.iterator();
        while (iter.next()) |entry| {
            if (!sources.sources.contains(entry.key_ptr.*)) {
                try sources.sources.put(try sources.sources.allocator.dupe(u8, entry.key_ptr.*), try entry.value_ptr.dupe(sources.sources.allocator));
                if (entry.value_ptr.depth >= limit) {
                    if (lf.debug) std.log.debug("Skipping source {s} due to depth limit.", .{entry.key_ptr.*});
                    continue;
                }
                if (lf.debug) std.log.debug("Adding new source to queue: {s}", .{entry.key_ptr.*});
                try sources_queue.append(try sources.sources.allocator.dupe(u8, entry.key_ptr.*));
            } else {
                std.log.warn("TODO: Merge children", .{});
            }
        }
        found_links.deinit();

        if (lf.debug) std.log.debug("Merged into sources for a total of {} links.", .{sources.sources.count()});
    }

    return sources;
}

/// Finds links in the provided HTML source.
/// TODO: Move recursion into a seperate function, make this one only return the sources on the supplied entrypoint.
pub fn findLinksLeaky(
    lf: *const LinkFinder,
    allocator: std.mem.Allocator,
    source: *const Source,
) !Sources {
    var sources = Sources.init(allocator);
    if (lf.debug) std.log.debug("Finding links for entrypoint: {f}", .{source});

    const src = (fetchHTML(lf, allocator, source.link) catch |e| {
        std.log.err("Failed to retrieve HTML contents due to {}, skipping.", .{e});
        return sources;
    }).items;

    var steps: usize = 0;
    var offset: usize = 0;
    while (offset < src.len and steps < src.len) : (steps += 1) {
        if (std.mem.indexOf(u8, src[offset..], "<a ")) |tag_start| {
            offset += tag_start;
            if (lf.debug) std.log.debug("Found <a> tag at offset {}.", .{offset});

            if (std.mem.indexOf(u8, src[offset..], "href=\"")) |link_start| {
                offset += link_start + "href=\"".len;
                if (lf.debug) std.log.debug("Found href attribute at offset {}.", .{offset});

                if (std.mem.indexOf(u8, src[offset..], "\"")) |link_end| {
                    const link = src[offset .. offset + link_end];
                    offset += link_end;

                    if (lf.debug) {
                        std.log.debug("Found closing quote for href at offset {}.", .{offset});
                        std.log.debug("Found link from {} to {}: \"{s}\".", .{ offset - link_end, offset, link });
                    }

                    const final_link = outer: {
                        const is_absolute = std.mem.startsWith(u8, link, "http://") or std.mem.startsWith(u8, link, "https://");
                        const is_root_relative = std.mem.startsWith(u8, link, "/");

                        if (is_absolute) {
                            if (lf.debug) std.log.debug("Adding absolute link: {s}", .{link});
                            break :outer link;
                        } else {
                            if (is_root_relative) {
                                // Root-relative URL: combine with domain root
                                const domain_root = extractDomainRoot(source.link);
                                const full_link = try std.fmt.allocPrint(allocator, "{s}{s}", .{ domain_root, link });

                                if (lf.debug) std.log.debug("Adding root-relative link: {s}", .{full_link});
                                break :outer full_link;
                            } else {
                                // Path-relative URL: combine with current directory
                                const last_slash = std.mem.lastIndexOf(u8, source.link, "/") orelse source.link.len;
                                const base_dir = source.link[0 .. last_slash + 1];
                                const full_link = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_dir, link });

                                if (lf.debug) std.log.debug("Adding path-relative link: {s}", .{full_link});
                                break :outer full_link;
                            }
                        }
                    };

                    // Only add the link if it matches our filters
                    if (lf.matchesFilter(final_link)) {
                        try sources.sources.put(final_link, .{
                            .depth = source.depth + 1,
                            .link = final_link,
                            .parent = source.link,
                        });
                    }
                } else {
                    std.log.err("No closing quote found for href attribute.", .{});
                    continue;
                }
            } else {
                std.log.err("No href attribute found in <a> tag.", .{});
                continue;
            }

            if (std.mem.indexOf(u8, src[offset..], "</a>")) |tag_end| {
                offset += tag_end + "</a>".len;
                if (lf.debug) {
                    std.log.debug("Found closing </a> tag at offset {}.", .{offset});
                }
            } else {
                std.log.err("No closing tag found for opening <a>.", .{});
                break;
            }
        } else {
            break;
        }
    } else {
        std.log.err("Hit step limit!", .{});
    }

    if (lf.debug) {
        std.log.debug("Found {} links:", .{sources.sources.count()});
        var iter = sources.sources.valueIterator();
        var idx: usize = 1;
        while (iter.next()) |entry| : (idx += 1) {
            std.log.debug("  {}: {f}", .{ idx, entry });
        }
    }

    return sources;
}

// -- Multi-threaded Processing -- //

const WorkerParams = struct {
    link_finder: *const LinkFinder,
    state: *ProcessingState,
    config: MultiThreadedConfig,
    worker_id: usize,
};

fn linkFinderWorker(params: *WorkerParams) void {
    defer params.state.allocator.destroy(params);

    var arena = std.heap.ArenaAllocator.init(params.state.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    while (!params.state.should_stop.load(.acquire)) {
        // Get work item from queue
        var work_item: ?ProcessingState.QueueItem = null;

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
            if (params.link_finder.debug) {
                std.log.debug("Worker {}: Processing {s} at depth {}", .{ params.worker_id, item.url, item.depth });
            }

            // Process the URL
            const entrypoint = Source{
                .link = item.url,
                .depth = item.depth,
                .parent = item.parent,
            };

            const sources = params.link_finder.findLinksLeaky(arena_allocator, &entrypoint) catch |err| {
                if (params.link_finder.debug) {
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
                if (params.link_finder.debug) {
                    std.log.debug("Worker {}: Checking recursion for {s} - current depth: {}, next depth: {}, limit: {}, recursive: {}", .{ params.worker_id, source.link, source.depth, next_depth, params.config.recursion_limit, params.config.recursive });
                }
                if (params.config.recursive and next_depth < params.config.recursion_limit) {
                    // Check if we've already processed this URL
                    if (!params.state.processed_urls.contains(source.link)) {
                        if (params.link_finder.debug) {
                            std.log.debug("Worker {}: Adding {s} to work queue at depth {}", .{ params.worker_id, source.link, next_depth });
                        }
                        params.state.work_mutex.lock();
                        const new_url = params.state.allocator.dupe(u8, source.link) catch {
                            params.state.work_mutex.unlock();
                            continue;
                        };
                        const new_parent = if (source.parent) |p| params.state.allocator.dupe(u8, p) catch null else null;

                        const new_item = ProcessingState.QueueItem{
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
                        if (params.link_finder.debug) {
                            std.log.debug("Worker {}: Skipping {s} - already processed", .{ params.worker_id, source.link });
                        }
                    }
                } else {
                    if (params.link_finder.debug) {
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

            if (params.link_finder.debug) {
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

    // Start worker threads
    for (0..params.config.worker_count) |i| {
        const worker_params = params.state.allocator.create(WorkerParams) catch continue;
        worker_params.* = WorkerParams{
            .link_finder = params.link_finder,
            .state = params.state,
            .config = params.config,
            .worker_id = i,
        };

        const thread = std.Thread.spawn(.{}, linkFinderWorker, .{worker_params}) catch {
            // If thread creation fails, clean up the allocated params
            params.state.allocator.destroy(worker_params);
            continue;
        };
        params.state.worker_threads.append(thread) catch {
            // If we can't add the thread to the list, we have a problem
            // Try to detach it so it can clean up itself
            thread.detach();
            continue;
        };
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

/// Start multi-threaded link finding process
pub fn findLinksMultiThreaded(
    self: *const LinkFinder,
    state: *ProcessingState,
    initial_url: []const u8,
    config: MultiThreadedConfig,
) !void {
    // Ensure we're not already running
    if (state.is_running) {
        return error.AlreadyRunning;
    }

    // Clear previous results (this handles thread cleanup)
    state.clearResults();

    // Reset statistics and timing
    state.total_found.store(0, .release);
    state.total_processed.store(0, .release);
    state.start_time = std.time.milliTimestamp();
    state.last_activity_time = state.start_time;

    // Add initial URL to work queue
    state.work_mutex.lock();
    defer state.work_mutex.unlock();

    const url = state.allocator.dupe(u8, initial_url) catch {
        state.error_message = state.allocator.dupe(u8, "Failed to allocate memory for URL") catch "Memory error";
        state.has_error = true;
        return error.OutOfMemory;
    };

    const initial_item = ProcessingState.QueueItem{
        .url = url,
        .depth = 0,
        .parent = null,
    };

    state.work_queue.append(initial_item) catch {
        state.allocator.free(url);
        state.error_message = state.allocator.dupe(u8, "Failed to add initial URL to work queue") catch "Memory error";
        state.has_error = true;
        return error.OutOfMemory;
    };
    state.processed_urls.put(url, {}) catch {};

    // Create parameters for coordinator thread
    const params = state.allocator.create(WorkerParams) catch {
        state.error_message = state.allocator.dupe(u8, "Failed to allocate memory for parameters") catch "Memory error";
        state.has_error = true;
        return error.OutOfMemory;
    };

    params.* = WorkerParams{
        .link_finder = self,
        .state = state,
        .config = config,
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
        return error.ThreadSpawnFailed;
    };

    // Store the coordinator thread so we can join it later
    state.coordinator_thread = thread;
    state.thread_mutex.unlock();

    // Signal workers to start
    state.work_condition.broadcast();
}

// -- Helpers -- //

fn fetchHTML(link_finder: *const LinkFinder, allocator: std.mem.Allocator, url: []const u8) !std.ArrayList(u8) {
    if (link_finder.debug) std.log.debug("Fetching HTML from: {s}", .{url});

    var response = std.ArrayList(u8).init(allocator);
    errdefer response.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const start_time = std.time.milliTimestamp();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &response },
    });
    if (link_finder.debug) std.log.debug("Fetched {s} in {} ms", .{ url, std.time.milliTimestamp() - start_time });

    if (result.status != .ok) {
        std.log.err("Failed to fetch \"{s}\". Status: {}", .{ url, result.status });
        return error.BadStatus;
    }

    return response;
}

fn cleanLink(allocator: std.mem.Allocator, link: []const u8) ![]const u8 {
    var cleaned = std.mem.trim(u8, link, &std.ascii.whitespace);

    cleaned = std.mem.trimRight(u8, cleaned, &.{ '/', '\\' });

    if (!std.mem.startsWith(u8, cleaned, "http://") and !std.mem.startsWith(u8, cleaned, "https://")) {
        cleaned = try std.fmt.allocPrint(allocator, "https://{s}", .{cleaned});
    }

    return cleaned;
}

fn extractDomainRoot(url: []const u8) []const u8 {
    const scheme_end = if (std.mem.indexOf(u8, url, "://")) |idx| idx + 3 else return url;
    const domain_end = if (std.mem.indexOf(u8, url[scheme_end..], "/")) |idx|
        scheme_end + idx
    else
        url.len;

    return url[0..domain_end];
}

// -- Tests -- //

test "cleanLink" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, "example.com"));
    try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, " https://example.com "));
    try std.testing.expectEqualStrings("https://example.com", try cleanLink(allocator, "https://example.com/"));
}

test "extractDomainRoot" {
    try std.testing.expectEqualStrings(
        "https://example.com",
        extractDomainRoot("https://example.com/path/to/resource"),
    );
}

test "fetchHTML" {
    const allocator = std.testing.allocator;
    const url = "https://example.com/";

    const link_finder = try LinkFinder.init(allocator, false, &.{});
    defer link_finder.deinit();
    const response = try link_finder.fetchHTML(allocator, url);
    defer response.deinit();
}

test "findLinksLeaky" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a LinkFinder with no filters
    const link_finder = try LinkFinder.init(allocator, false, &.{});
    defer link_finder.deinit();

    // Create a test source
    const source = Source{
        .link = "https://example.com/",
        .depth = 0,
    };

    const sources = try link_finder.findLinksLeaky(allocator, &source);

    const expected_links = [_][]const u8{
        "https://www.iana.org/domains/example",
    };

    try std.testing.expectEqual(expected_links.len, sources.sources.count());

    for (expected_links) |expected_link| {
        try std.testing.expect(sources.sources.contains(expected_link));
    }
}

test "findLinksLeakyWithFilter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a LinkFinder with a filter for IANA links
    const filters = [_][]const u8{".*iana\\.org.*"};
    const link_finder = try LinkFinder.init(allocator, false, &filters);
    defer link_finder.deinit();

    // Create a test source
    const source = Source{
        .link = "https://example.com/",
        .depth = 0,
    };

    const sources = try link_finder.findLinksLeaky(allocator, &source);

    const expected_filtered_links = [_][]const u8{
        "https://www.iana.org/domains/example",
    };

    try std.testing.expectEqual(expected_filtered_links.len, sources.sources.count());

    for (expected_filtered_links) |expected_link| {
        try std.testing.expect(sources.sources.contains(expected_link));
        try std.testing.expect(link_finder.matchesFilter(expected_link));
    }
}

test "matchesFilter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test with no filters (should match everything)
    {
        const link_finder = try LinkFinder.init(allocator, false, &.{});
        defer link_finder.deinit();

        try std.testing.expect(link_finder.matchesFilter("https://example.com"));
        try std.testing.expect(link_finder.matchesFilter("https://github.com/test.zip"));
    }

    // Test with PDF filter
    {
        const filters = [_][]const u8{".*\\.pdf$"};
        const link_finder = try LinkFinder.init(allocator, false, &filters);
        defer link_finder.deinit();

        try std.testing.expect(link_finder.matchesFilter("https://example.com/document.pdf"));
        try std.testing.expect(!link_finder.matchesFilter("https://example.com/page.html"));
    }

    // Test with multiple filters
    {
        const filters = [_][]const u8{ ".*github\\.com.*", ".*\\.zip$" };
        const link_finder = try LinkFinder.init(allocator, false, &filters);
        defer link_finder.deinit();

        try std.testing.expect(link_finder.matchesFilter("https://github.com/user/repo"));
        try std.testing.expect(link_finder.matchesFilter("https://example.com/file.zip"));
        try std.testing.expect(!link_finder.matchesFilter("https://example.com/page.html"));
    }
}
