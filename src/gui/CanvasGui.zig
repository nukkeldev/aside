const std = @import("std");
const zgui = @import("zgui");

const CanvasGui = @This();

// Canvas state
allocator: std.mem.Allocator,
drawing: bool,
panning: bool,
last_mouse_pos: [2]f32,
pan_start_pos: [2]f32,
brush_size: f32,
brush_color: [4]f32,
canvas_size: [2]f32,
draw_commands: std.ArrayList(DrawCommand),
// Viewport state
zoom: f32,
pan_offset: [2]f32,

// Drawing command structure (stored in canvas coordinates)
const DrawCommand = struct {
    type: enum { line, circle },
    start_pos: [2]f32, // Canvas coordinates
    end_pos: [2]f32, // Canvas coordinates
    color: [4]f32,
    thickness: f32,
};

pub fn init(allocator: std.mem.Allocator) CanvasGui {
    return CanvasGui{
        .allocator = allocator,
        .drawing = false,
        .panning = false,
        .last_mouse_pos = .{ 0, 0 },
        .pan_start_pos = .{ 0, 0 },
        .brush_size = 2.0,
        .brush_color = .{ 1.0, 1.0, 1.0, 1.0 }, // White
        .canvas_size = .{ 800, 600 },
        .draw_commands = std.ArrayList(DrawCommand).init(allocator),
        .zoom = 1.0,
        .pan_offset = .{ 0, 0 },
    };
}

pub fn deinit(self: *CanvasGui) void {
    self.draw_commands.deinit();
}

// Transform screen coordinates to canvas coordinates (accounting for zoom and pan)
fn screenToCanvas(self: *const CanvasGui, screen_pos: [2]f32, canvas_pos: [2]f32) [2]f32 {
    const relative_pos = [2]f32{ screen_pos[0] - canvas_pos[0], screen_pos[1] - canvas_pos[1] };
    return [2]f32{
        (relative_pos[0] - self.pan_offset[0]) / self.zoom,
        (relative_pos[1] - self.pan_offset[1]) / self.zoom,
    };
}

// Transform canvas coordinates to screen coordinates (accounting for zoom and pan)
fn canvasToScreen(self: *const CanvasGui, canvas_coord: [2]f32, canvas_pos: [2]f32) [2]f32 {
    return [2]f32{
        canvas_pos[0] + canvas_coord[0] * self.zoom + self.pan_offset[0],
        canvas_pos[1] + canvas_coord[1] * self.zoom + self.pan_offset[1],
    };
}

pub fn render(self: *CanvasGui, mouse_wheel_delta: f32) !void {
    // Canvas controls
    zgui.text("Canvas Controls", .{});
    zgui.separator();

    // Brush size slider
    _ = zgui.sliderFloat("Brush Size", .{
        .v = &self.brush_size,
        .min = 1.0,
        .max = 10.0,
    });

    // Color picker
    _ = zgui.colorEdit4("Brush Color", .{
        .col = &self.brush_color,
    });

    // Clear canvas button
    if (zgui.button("Clear Canvas", .{})) {
        self.draw_commands.clearRetainingCapacity();
    }

    // Reset view button
    zgui.sameLine(.{});
    if (zgui.button("Reset View", .{})) {
        self.zoom = 1.0;
        self.pan_offset = .{ 0, 0 };
    }

    // Zoom controls
    zgui.sameLine(.{});
    if (zgui.button("Zoom In", .{})) {
        self.zoom *= 1.2;
        self.zoom = @min(10.0, self.zoom);
    }

    zgui.sameLine(.{});
    if (zgui.button("Zoom Out", .{})) {
        self.zoom /= 1.2;
        self.zoom = @max(0.1, self.zoom);
    }

    zgui.separator();

    // Canvas area - fill remaining space
    const content_region = zgui.getContentRegionAvail();
    self.canvas_size[0] = content_region[0];
    self.canvas_size[1] = content_region[1];

    const canvas_pos = zgui.getCursorScreenPos();
    const canvas_end = [2]f32{ canvas_pos[0] + self.canvas_size[0], canvas_pos[1] + self.canvas_size[1] };

    // Draw canvas background
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = canvas_pos,
        .pmax = canvas_end,
        .col = zgui.colorConvertFloat4ToU32(.{ 0.1, 0.1, 0.1, 1.0 }),
    });

    // Draw canvas border
    draw_list.addRect(.{
        .pmin = canvas_pos,
        .pmax = canvas_end,
        .col = zgui.colorConvertFloat4ToU32(.{ 0.5, 0.5, 0.5, 1.0 }),
        .thickness = 1.0,
    });

    // Handle mouse input for canvas interaction
    zgui.setCursorScreenPos(canvas_pos);
    _ = zgui.invisibleButton("canvas", .{ .w = self.canvas_size[0], .h = self.canvas_size[1] });

    const is_hovered = zgui.isItemHovered(.{});
    const mouse_pos = zgui.getMousePos();

    // Mouse wheel zooming
    if (is_hovered and mouse_wheel_delta != 0) {
        // Get canvas coordinates for current mouse position before zoom
        const canvas_mouse_coord_before = self.screenToCanvas(mouse_pos, canvas_pos);

        // Apply zoom
        const zoom_factor: f32 = if (mouse_wheel_delta > 0) 1.2 else 1.0 / 1.2;
        self.zoom *= zoom_factor;
        self.zoom = std.math.clamp(self.zoom, 0.1, 10.0);

        // Get canvas coordinates for current mouse position after zoom
        const canvas_mouse_coord_after = self.screenToCanvas(mouse_pos, canvas_pos);

        // Adjust pan offset to keep the same world point under the mouse
        const coord_diff = [2]f32{
            canvas_mouse_coord_after[0] - canvas_mouse_coord_before[0],
            canvas_mouse_coord_after[1] - canvas_mouse_coord_before[1],
        };

        self.pan_offset[0] += coord_diff[0] * self.zoom;
        self.pan_offset[1] += coord_diff[1] * self.zoom;
    }

    // Get canvas coordinates for current mouse position
    const canvas_mouse_coord = self.screenToCanvas(mouse_pos, canvas_pos);

    // Check if mouse is within canvas bounds
    const mouse_in_canvas = is_hovered;

    // Handle panning with right mouse button
    if (mouse_in_canvas) {
        if (zgui.isMouseClicked(.right)) {
            self.panning = true;
            self.pan_start_pos = mouse_pos;
        }
    }

    if (self.panning) {
        if (zgui.isMouseDown(.right)) {
            const mouse_delta = [2]f32{ mouse_pos[0] - self.pan_start_pos[0], mouse_pos[1] - self.pan_start_pos[1] };
            self.pan_offset[0] += mouse_delta[0];
            self.pan_offset[1] += mouse_delta[1];
            self.pan_start_pos = mouse_pos;
        } else {
            self.panning = false;
        }
    }

    // Handle drawing with left mouse button
    if (mouse_in_canvas and !self.panning) {
        if (zgui.isMouseDown(.left)) {
            if (!self.drawing) {
                // Start drawing
                self.drawing = true;
                self.last_mouse_pos = canvas_mouse_coord;
            } else {
                // Continue drawing - create line from last position to current
                const draw_cmd = DrawCommand{
                    .type = .line,
                    .start_pos = self.last_mouse_pos,
                    .end_pos = canvas_mouse_coord,
                    .color = self.brush_color,
                    .thickness = self.brush_size / self.zoom, // Adjust thickness for zoom
                };

                try self.draw_commands.append(draw_cmd);
                self.last_mouse_pos = canvas_mouse_coord;
            }
        } else {
            self.drawing = false;
        }
    } else {
        self.drawing = false;
    }

    // Render all draw commands (transform from canvas to screen coordinates)
    // Add clipping to prevent drawing outside canvas bounds
    draw_list.pushClipRect(.{
        .pmin = canvas_pos,
        .pmax = canvas_end,
        .intersect_with_current = true,
    });

    for (self.draw_commands.items) |cmd| {
        const screen_start = self.canvasToScreen(cmd.start_pos, canvas_pos);
        const screen_end = self.canvasToScreen(cmd.end_pos, canvas_pos);

        switch (cmd.type) {
            .line => {
                draw_list.addLine(.{
                    .p1 = screen_start,
                    .p2 = screen_end,
                    .col = zgui.colorConvertFloat4ToU32(cmd.color),
                    .thickness = cmd.thickness * self.zoom,
                });
            },
            .circle => {
                draw_list.addCircleFilled(.{
                    .p = screen_start,
                    .r = cmd.thickness * self.zoom,
                    .col = zgui.colorConvertFloat4ToU32(cmd.color),
                });
            },
        }
    }

    // Draw brush preview if hovering over canvas (also clipped)
    if (mouse_in_canvas and !self.drawing and !self.panning) {
        draw_list.addCircle(.{
            .p = mouse_pos,
            .r = (self.brush_size / 2.0) * self.zoom,
            .col = zgui.colorConvertFloat4ToU32(.{ 1.0, 1.0, 1.0, 0.5 }),
            .thickness = 1.0,
        });
    }

    // Pop clipping
    draw_list.popClipRect();

    // Status info at the bottom
    const status_height = 60;
    const status_pos = [2]f32{ canvas_pos[0], canvas_end[1] - status_height };
    draw_list.addRectFilled(.{
        .pmin = status_pos,
        .pmax = [2]f32{ canvas_end[0], canvas_end[1] },
        .col = zgui.colorConvertFloat4ToU32(.{ 0.0, 0.0, 0.0, 0.7 }),
    });

    zgui.setCursorScreenPos([2]f32{ status_pos[0] + 10, status_pos[1] + 5 });
    zgui.text("Canvas: ({d:.1}, {d:.1}) | Zoom: {d:.1}x | Pan: ({d:.0}, {d:.0})", .{ canvas_mouse_coord[0], canvas_mouse_coord[1], self.zoom, self.pan_offset[0], self.pan_offset[1] });
    zgui.setCursorScreenPos([2]f32{ status_pos[0] + 10, status_pos[1] + 25 });
    zgui.text("Commands: {d} | Left: Draw | Right: Pan | Wheel: Zoom", .{self.draw_commands.items.len});
}
