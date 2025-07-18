const std = @import("std");

const SDL = @import("ffi.zig").SDL;
const c = @import("ffi.zig").c;
const zgui = @import("zgui");
const tracy = @import("perf/tracy.zig");

const FZ = tracy.FnZone;
const LinkFinder = @import("tools/LinkFinder.zig");

// -- Main -- //

pub fn main() !void {
    var fz = FZ.init(@src(), "main");
    defer fz.end();

    var da = std.heap.DebugAllocator(.{}).init;
    defer _ = da.deinit();
    const allocator = if (@import("builtin").mode == .Debug) da.allocator() else std.heap.smp_allocator;

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
        zgui.text("Hello, {s}!", .{"World"});
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
