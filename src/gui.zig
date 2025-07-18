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

    // Thread state
    thread: ?std.Thread = null,
    is_running: bool = false,
    has_results: bool = false,
    has_error: bool = false,

    // Results
    results: std.ArrayList([]const u8),
    error_message: ?[]const u8 = null,

    // Threading
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) LinkFinderState {
        return LinkFinderState{
            .results = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LinkFinderState) void {
        if (self.thread) |thread| {
            thread.join();
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.results.items) |result| {
            self.allocator.free(result);
        }
        self.results.deinit();

        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }

    pub fn clearResults(self: *LinkFinderState) void {
        // Join the existing thread if it's still running
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.results.items) |result| {
            self.allocator.free(result);
        }
        self.results.clearRetainingCapacity();

        if (self.error_message) |msg| {
            self.allocator.free(msg);
            self.error_message = null;
        }

        self.has_results = false;
        self.has_error = false;
        self.is_running = false;
    }
};

// -- LinkFinder Worker Thread -- //

const LinkFinderParams = struct {
    state: *LinkFinderState,
    url: []const u8,
    filters: []const []const u8,
    recursive: bool,
    debug: bool,
    recursion_limit: usize,
};

fn linkFinderWorker(params: *LinkFinderParams) void {
    defer params.state.allocator.destroy(params);

    var arena = std.heap.ArenaAllocator.init(params.state.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    // Create LinkFinder instance
    const link_finder = LinkFinder.init(arena_allocator, params.debug, params.filters) catch |err| {
        params.state.mutex.lock();
        defer params.state.mutex.unlock();

        params.state.error_message = std.fmt.allocPrint(params.state.allocator, "Failed to initialize LinkFinder: {}", .{err}) catch "Failed to initialize LinkFinder";
        params.state.has_error = true;
        params.state.is_running = false;

        // Clean up filters
        for (params.filters) |filter| {
            params.state.allocator.free(filter);
        }
        params.state.allocator.free(params.filters);
        params.state.allocator.free(params.url);
        return;
    };
    defer link_finder.deinit();

    // Create entry point
    const entrypoint = LinkFinder.Source{
        .link = params.url,
        .depth = 0,
    };

    // Find links
    const sources = if (params.recursive)
        link_finder.findLinksLeakyRecurse(arena_allocator, entrypoint, params.recursion_limit) catch |err| {
            params.state.mutex.lock();
            defer params.state.mutex.unlock();

            params.state.error_message = std.fmt.allocPrint(params.state.allocator, "Failed to find links: {}", .{err}) catch "Failed to find links";
            params.state.has_error = true;
            params.state.is_running = false;

            // Clean up filters
            for (params.filters) |filter| {
                params.state.allocator.free(filter);
            }
            params.state.allocator.free(params.filters);
            params.state.allocator.free(params.url);
            return;
        }
    else
        link_finder.findLinksLeaky(arena_allocator, &entrypoint) catch |err| {
            params.state.mutex.lock();
            defer params.state.mutex.unlock();

            params.state.error_message = std.fmt.allocPrint(params.state.allocator, "Failed to find links: {}", .{err}) catch "Failed to find links";
            params.state.has_error = true;
            params.state.is_running = false;

            // Clean up filters
            for (params.filters) |filter| {
                params.state.allocator.free(filter);
            }
            params.state.allocator.free(params.filters);
            params.state.allocator.free(params.url);
            return;
        };

    // Copy results to state
    params.state.mutex.lock();
    defer params.state.mutex.unlock();

    var iter = sources.sources.valueIterator();
    while (iter.next()) |source| {
        const result = std.fmt.allocPrint(params.state.allocator, "{s} (depth: {})", .{ source.link, source.depth }) catch continue;
        params.state.results.append(result) catch continue;
    }

    params.state.has_results = true;
    params.state.is_running = false;

    // Clean up filters and URL
    for (params.filters) |filter| {
        params.state.allocator.free(filter);
    }
    params.state.allocator.free(params.filters);
    params.state.allocator.free(params.url);
}

// -- Main -- //

fn renderLinkFinderWindow(state: *LinkFinderState) void {
    if (zgui.begin("LinkFinder", .{})) {
        defer zgui.end();

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

        zgui.separator();

        // Control buttons
        const url_len = std.mem.indexOfScalar(u8, &state.url_buffer, 0) orelse state.url_buffer.len;
        const has_url = url_len > 0 and
            (std.mem.startsWith(u8, state.url_buffer[0..url_len], "http://") or
                std.mem.startsWith(u8, state.url_buffer[0..url_len], "https://"));

        zgui.beginDisabled(.{ .disabled = !has_url or state.is_running });
        if (zgui.button("Find Links", .{})) {
            // Join any existing thread first
            if (state.thread) |thread| {
                thread.join();
                state.thread = null;
            }

            // Clear previous results
            state.clearResults();

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

            // Create parameters for worker thread
            const params = state.allocator.create(LinkFinderParams) catch {
                state.error_message = state.allocator.dupe(u8, "Failed to allocate memory for parameters") catch "Memory error";
                state.has_error = true;
                return;
            };

            params.* = LinkFinderParams{
                .state = state,
                .url = url,
                .filters = filters.toOwnedSlice() catch &[_][]const u8{},
                .recursive = state.recursive,
                .debug = state.debug,
                .recursion_limit = @intCast(state.recursion_limit),
            };

            // Start worker thread
            state.is_running = true;
            state.thread = std.Thread.spawn(.{}, linkFinderWorker, .{params}) catch {
                state.is_running = false;
                state.error_message = state.allocator.dupe(u8, "Failed to start worker thread") catch "Thread error";
                state.has_error = true;
                state.allocator.destroy(params);
                return;
            };
        }
        zgui.endDisabled();

        zgui.sameLine(.{});

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
        }

        if (state.has_error) {
            zgui.textColored(.{ 1.0, 0.0, 0.0, 1.0 }, "Error: {s}", .{state.error_message orelse "Unknown error"});
        }

        // Results display
        if (state.has_results and state.results.items.len > 0) {
            zgui.separator();
            zgui.text("Found {} links:", .{state.results.items.len});

            if (zgui.beginChild("results", .{ .w = 0, .h = 200, .child_flags = .{ .border = true } })) {
                state.mutex.lock();
                defer state.mutex.unlock();

                for (state.results.items, 0..) |result, i| {
                    zgui.text("{}: {s}", .{ i + 1, result });
                }
            }
            zgui.endChild();
        } else if (state.has_results) {
            zgui.separator();
            zgui.text("No links found.", .{});
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
    const window = try SDL.Window.create(allocator, "Garden Demo", [2]u32{ 1024, 1024 }, [2]u32{ c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED });

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
    outer: while (true) {
        fz.push(@src(), "poll events");
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            _ = zgui.backend.processEvent(&event);
            if (event.type == c.SDL_EVENT_QUIT) {
                break :outer;
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

        zgui.backend.newFrame(1280, 720, 1.0);

        // Render LinkFinder window
        renderLinkFinderWindow(&linkfinder_state);

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
