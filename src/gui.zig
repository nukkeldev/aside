const std = @import("std");

const c = @cImport({
    // SDL3
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});
const zgui = @import("zgui");

const LinkFinder = @import("tools/LinkFinder.zig");

// -- Main -- //

pub fn main() void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        std.log.err("Failed to initialize SDL: {s}", .{c.SDL_GetError()});
        return;
    }
    defer c.SDL_Quit();

    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    if (!c.SDL_CreateWindowAndRenderer("Aside", 1280, 720, 0, &window, &renderer)) {
        std.log.err("Failed to create window and renderer: {s}", .{c.SDL_GetError()});
        return;
    }

    if (window == null or renderer == null) {
        std.log.err("Failed to create window or renderer", .{});
        return;
    }

    defer c.SDL_DestroyRenderer(renderer.?);
    defer c.SDL_DestroyWindow(window.?);

    outer: while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                break :outer;
            }
        }

        _ = c.SDL_SetRenderDrawColor(renderer.?, 0, 0, 255, 255);
        _ = c.SDL_RenderClear(renderer.?);
        _ = c.SDL_RenderPresent(renderer.?);
    }
}
