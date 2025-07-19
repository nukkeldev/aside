const std = @import("std");
const zgui = @import("zgui");

const CanvasGui = @This();

// Canvas state
allocator: std.mem.Allocator,
drawing: bool,
last_mouse_pos: [2]f32,
brush_size: f32,
brush_color: [4]f32,
canvas_size: [2]f32,
draw_commands: std.ArrayList(DrawCommand),

// Drawing command structure
const DrawCommand = struct {
    type: enum { line, circle },
    start_pos: [2]f32,
    end_pos: [2]f32,
    color: [4]f32,
    thickness: f32,
};

pub fn init(allocator: std.mem.Allocator) CanvasGui {
    return CanvasGui{
        .allocator = allocator,
        .drawing = false,
        .last_mouse_pos = .{ 0, 0 },
        .brush_size = 2.0,
        .brush_color = .{ 1.0, 1.0, 1.0, 1.0 }, // White
        .canvas_size = .{ 800, 600 },
        .draw_commands = std.ArrayList(DrawCommand).init(allocator),
    };
}

pub fn deinit(self: *CanvasGui) void {
    self.draw_commands.deinit();
}

pub fn render(self: *CanvasGui) !void {
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

    zgui.separator();

    // Canvas area
    zgui.text("Canvas", .{});

    // Get the available content region
    const content_region = zgui.getContentRegionAvail();
    self.canvas_size[0] = @max(400, content_region[0] - 20);
    self.canvas_size[1] = @max(300, content_region[1] - 100);

    // Canvas background
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

    // Handle mouse input for drawing
    zgui.setCursorScreenPos(canvas_pos);
    _ = zgui.invisibleButton("canvas", .{ .w = self.canvas_size[0], .h = self.canvas_size[1] });

    const is_hovered = zgui.isItemHovered(.{});
    const mouse_pos = zgui.getMousePos();
    const relative_mouse_pos = [2]f32{ mouse_pos[0] - canvas_pos[0], mouse_pos[1] - canvas_pos[1] };

    // Check if mouse is within canvas bounds
    const mouse_in_canvas = is_hovered and
        relative_mouse_pos[0] >= 0 and relative_mouse_pos[0] <= self.canvas_size[0] and
        relative_mouse_pos[1] >= 0 and relative_mouse_pos[1] <= self.canvas_size[1];

    // Handle drawing
    if (mouse_in_canvas) {
        if (zgui.isMouseDown(.left)) {
            if (!self.drawing) {
                // Start drawing
                self.drawing = true;
                self.last_mouse_pos = relative_mouse_pos;
            } else {
                // Continue drawing - create line from last position to current
                const draw_cmd = DrawCommand{
                    .type = .line,
                    .start_pos = .{ canvas_pos[0] + self.last_mouse_pos[0], canvas_pos[1] + self.last_mouse_pos[1] },
                    .end_pos = .{ canvas_pos[0] + relative_mouse_pos[0], canvas_pos[1] + relative_mouse_pos[1] },
                    .color = self.brush_color,
                    .thickness = self.brush_size,
                };

                try self.draw_commands.append(draw_cmd);
                self.last_mouse_pos = relative_mouse_pos;
            }
        } else {
            self.drawing = false;
        }
    } else {
        self.drawing = false;
    }

    // Render all draw commands
    for (self.draw_commands.items) |cmd| {
        switch (cmd.type) {
            .line => {
                draw_list.addLine(.{
                    .p1 = cmd.start_pos,
                    .p2 = cmd.end_pos,
                    .col = zgui.colorConvertFloat4ToU32(cmd.color),
                    .thickness = cmd.thickness,
                });
            },
            .circle => {
                draw_list.addCircleFilled(.{
                    .p = cmd.start_pos,
                    .r = cmd.thickness,
                    .col = zgui.colorConvertFloat4ToU32(cmd.color),
                });
            },
        }
    }

    // Draw brush preview if hovering over canvas
    if (mouse_in_canvas and !self.drawing) {
        draw_list.addCircle(.{
            .p = mouse_pos,
            .r = self.brush_size / 2.0,
            .col = zgui.colorConvertFloat4ToU32(.{ 1.0, 1.0, 1.0, 0.5 }),
            .thickness = 1.0,
        });
    }

    // Status info
    zgui.separator();
    zgui.text("Mouse Position: ({d:.1}, {d:.1})", .{ relative_mouse_pos[0], relative_mouse_pos[1] });
    zgui.text("Drawing Commands: {d}", .{self.draw_commands.items.len});
    if (mouse_in_canvas) {
        zgui.text("Status: Hovering over canvas", .{});
    } else {
        zgui.text("Status: Outside canvas", .{});
    }
}
