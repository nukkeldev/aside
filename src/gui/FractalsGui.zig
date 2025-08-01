const std = @import("std");
const zgui = @import("zgui");

const FractalsGui = @This();

// Fractal types
const FractalType = enum {
    mandelbrot,
    julia,
    sierpinski,
    burning_ship,
};

// Fractal state
allocator: std.mem.Allocator,
fractal_type: FractalType,
image_buffer: []u32,
image_size: [2]u32,
texture_id: ?zgui.TextureIdent,
needs_update: bool,

// Mouse interaction state (similar to CanvasGui)
panning: bool,
last_mouse_pos: [2]f32,
pan_start_pos: [2]f32,

// Mandelbrot/Julia parameters
zoom: f64,
center: [2]f64,
max_iterations: u32,
julia_c: [2]f64, // Julia set constant

// UI temporary variables (f32 for sliders)
zoom_f32: f32,
center_f32: [2]f32,
julia_c_f32: [2]f32,

// Sierpinski parameters
sierpinski_iterations: u32,

// Rendering parameters
color_scheme: u32,
resolution: u32,

pub fn init(allocator: std.mem.Allocator) !FractalsGui {
    const initial_resolution: u32 = 256;
    const image_size = [2]u32{ initial_resolution, initial_resolution };
    const buffer_size = image_size[0] * image_size[1];
    const image_buffer = try allocator.alloc(u32, buffer_size);

    return FractalsGui{
        .allocator = allocator,
        .fractal_type = .mandelbrot,
        .image_buffer = image_buffer,
        .image_size = image_size,
        .texture_id = null,
        .needs_update = true,
        .panning = false,
        .last_mouse_pos = .{ 0, 0 },
        .pan_start_pos = .{ 0, 0 },
        .zoom = 1.0,
        .center = .{ -0.5, 0.0 },
        .max_iterations = 100,
        .julia_c = .{ -0.8, 0.156 },
        .zoom_f32 = 1.0,
        .center_f32 = .{ -0.5, 0.0 },
        .julia_c_f32 = .{ -0.8, 0.156 },
        .sierpinski_iterations = 10000,
        .color_scheme = 0,
        .resolution = initial_resolution,
    };
}

pub fn deinit(self: *FractalsGui) void {
    self.allocator.free(self.image_buffer);
}

// Transform screen coordinates to fractal coordinates (accounting for zoom and pan)
fn screenToFractal(self: *const FractalsGui, screen_pos: [2]f32, fractal_pos: [2]f32, fractal_size: [2]f32) [2]f64 {
    const relative_pos = [2]f32{ screen_pos[0] - fractal_pos[0], screen_pos[1] - fractal_pos[1] };

    // Convert to normalized coordinates (0-1)
    const norm_x = relative_pos[0] / fractal_size[0];
    const norm_y = relative_pos[1] / fractal_size[1];

    // Convert to complex plane coordinates
    const range = 4.0 / self.zoom;
    return [2]f64{
        (norm_x - 0.5) * range + self.center[0],
        (norm_y - 0.5) * range + self.center[1],
    };
}

pub fn render(self: *FractalsGui, mouse_wheel_delta: f32) !void {
    // Get the available content region
    const content_region = zgui.getContentRegionAvail();
    const controls_width = 300.0; // Fixed width for controls
    const fractal_width = content_region[0] - controls_width - 10.0; // 10px spacing

    // Left side: Controls
    if (zgui.beginChild("FractalControls", .{ .w = controls_width, .h = content_region[1] })) {
        defer zgui.endChild();

        // Fractal controls
        zgui.text("Fractal Generator", .{});
        zgui.separator();

        // Fractal type selection
        var current_fractal: i32 = @intCast(@intFromEnum(self.fractal_type));
        if (zgui.combo("Fractal Type", .{
            .current_item = &current_fractal,
            .items_separated_by_zeros = "Mandelbrot Set\x00Julia Set\x00Sierpinski Triangle\x00Burning Ship\x00",
        })) {
            const new_type: FractalType = @enumFromInt(@as(u2, @intCast(current_fractal)));
            if (new_type != self.fractal_type) {
                self.fractal_type = new_type;
                self.needs_update = true;
            }
        }

        // Common parameters
        if (zgui.sliderInt("Max Iterations", .{
            .v = @ptrCast(&self.max_iterations),
            .min = 10,
            .max = 500,
        })) {
            self.needs_update = true;
        }

        // Resolution slider
        if (zgui.sliderInt("Resolution", .{
            .v = @ptrCast(&self.resolution),
            .min = 128,
            .max = 1024,
        })) {
            // Need to reallocate buffer if resolution changed
            if (self.resolution != self.image_size[0]) {
                self.allocator.free(self.image_buffer);
                const new_size = [2]u32{ self.resolution, self.resolution };
                const buffer_size = new_size[0] * new_size[1];
                self.image_buffer = self.allocator.alloc(u32, buffer_size) catch {
                    // If allocation fails, revert to old resolution
                    self.resolution = self.image_size[0];
                    return error.OutOfMemory;
                };
                self.image_size = new_size;
                self.needs_update = true;
            }
        }

        // Color scheme dropdown
        var current_color: i32 = @intCast(self.color_scheme);
        if (zgui.combo("Color Scheme", .{
            .current_item = &current_color,
            .items_separated_by_zeros = "Blue to Yellow\x00Purple to White\x00Navy to Red\x00Rainbow HSV\x00",
        })) {
            const new_scheme = @as(u32, @intCast(current_color));
            if (new_scheme != self.color_scheme) {
                self.color_scheme = new_scheme;
                self.needs_update = true;
            }
        }

        // Fractal-specific parameters
        switch (self.fractal_type) {
            .mandelbrot, .burning_ship => {
                if (zgui.sliderFloat("Zoom", .{
                    .v = &self.zoom_f32,
                    .min = 0.1,
                    .max = 1000.0,
                    .flags = .{ .logarithmic = true },
                })) {
                    self.zoom = @as(f64, self.zoom_f32);
                    self.needs_update = true;
                }

                if (zgui.sliderFloat("Center X", .{
                    .v = &self.center_f32[0],
                    .min = -2.0,
                    .max = 2.0,
                })) {
                    self.center[0] = @as(f64, self.center_f32[0]);
                    self.needs_update = true;
                }

                if (zgui.sliderFloat("Center Y", .{
                    .v = &self.center_f32[1],
                    .min = -2.0,
                    .max = 2.0,
                })) {
                    self.center[1] = @as(f64, self.center_f32[1]);
                    self.needs_update = true;
                }
            },
            .julia => {
                if (zgui.sliderFloat("Zoom", .{
                    .v = &self.zoom_f32,
                    .min = 0.1,
                    .max = 10.0,
                })) {
                    self.zoom = @as(f64, self.zoom_f32);
                    self.needs_update = true;
                }

                if (zgui.sliderFloat("Julia C Real", .{
                    .v = &self.julia_c_f32[0],
                    .min = -2.0,
                    .max = 2.0,
                })) {
                    self.julia_c[0] = @as(f64, self.julia_c_f32[0]);
                    self.needs_update = true;
                }

                if (zgui.sliderFloat("Julia C Imaginary", .{
                    .v = &self.julia_c_f32[1],
                    .min = -2.0,
                    .max = 2.0,
                })) {
                    self.julia_c[1] = @as(f64, self.julia_c_f32[1]);
                    self.needs_update = true;
                }
            },
            .sierpinski => {
                if (zgui.sliderInt("Iterations", .{
                    .v = @ptrCast(&self.sierpinski_iterations),
                    .min = 1000,
                    .max = 100000,
                })) {
                    self.needs_update = true;
                }
            },
        }

        // Reset button
        if (zgui.button("Reset to Default", .{})) {
            self.resetToDefault();
            self.needs_update = true;
        }

        // Generate button
        if (zgui.button("Generate Fractal", .{ .w = -1 }) or self.needs_update) {
            try self.generateFractal();
            self.needs_update = false;
        }

        zgui.separator();

        // Show generation info
        if (self.texture_id != null) {
            zgui.text("Fractal: {s}", .{@tagName(self.fractal_type)});
            zgui.text("Resolution: {}x{}", .{ self.image_size[0], self.image_size[1] });
            zgui.text("Iterations: {}", .{self.max_iterations});

            switch (self.fractal_type) {
                .mandelbrot, .burning_ship => {
                    zgui.text("Center: ({d:.6}, {d:.6})", .{ self.center[0], self.center[1] });
                    zgui.text("Zoom: {d:.2}", .{self.zoom});
                },
                .julia => {
                    zgui.text("Julia C: ({d:.3}, {d:.3})", .{ self.julia_c[0], self.julia_c[1] });
                    zgui.text("Zoom: {d:.2}", .{self.zoom});
                },
                .sierpinski => {
                    zgui.text("Points: {}", .{self.sierpinski_iterations});
                },
            }

            zgui.separator();
            zgui.textColored(.{ 0.8, 0.8, 0.8, 1.0 }, "Mouse Controls:", .{});
            zgui.bulletText("Left-click: Set center point", .{});
            zgui.bulletText("Right-click and drag: Pan view", .{});
            zgui.bulletText("Mouse wheel: Zoom in/out", .{});
        }
    }

    // Right side: Fractal display
    zgui.sameLine(.{});
    if (fractal_width > 100) {
        if (zgui.beginChild("FractalDisplay", .{ .w = fractal_width, .h = content_region[1] })) {
            defer zgui.endChild();

            try self.renderFractalDisplay(fractal_width, content_region[1], mouse_wheel_delta);
        }
    }
}

fn renderFractalDisplay(self: *FractalsGui, display_width: f32, display_height: f32, mouse_wheel_delta: f32) !void {
    if (self.texture_id == null) {
        zgui.text("Click 'Generate Fractal' to render", .{});
        return;
    }

    // Calculate fractal display area - make it square and centered
    const display_size = @min(display_width - 20, display_height - 20); // Leave some margin
    const fractal_size = [2]f32{ display_size, display_size };

    // Center the fractal display
    const start_x = (display_width - display_size) / 2.0;
    const start_y = 10.0; // Small top margin

    zgui.setCursorPosX(start_x);
    zgui.setCursorPosY(start_y);

    const fractal_pos = zgui.getCursorScreenPos();
    const fractal_end = [2]f32{ fractal_pos[0] + fractal_size[0], fractal_pos[1] + fractal_size[1] };

    // Draw fractal background
    const draw_list = zgui.getWindowDrawList();
    draw_list.addRectFilled(.{
        .pmin = fractal_pos,
        .pmax = fractal_end,
        .col = zgui.colorConvertFloat4ToU32(.{ 0.05, 0.05, 0.05, 1.0 }),
    });

    // Draw fractal border
    draw_list.addRect(.{
        .pmin = fractal_pos,
        .pmax = fractal_end,
        .col = zgui.colorConvertFloat4ToU32(.{ 0.5, 0.5, 0.5, 1.0 }),
        .thickness = 1.0,
    });

    // Handle mouse input for fractal interaction
    _ = zgui.invisibleButton("fractal_canvas", .{ .w = fractal_size[0], .h = fractal_size[1] });

    const is_hovered = zgui.isItemHovered(.{});
    const mouse_pos = zgui.getMousePos();

    // Handle panning with right mouse button (similar to CanvasGui)
    if (is_hovered) {
        if (zgui.isMouseClicked(.right)) {
            self.panning = true;
            self.pan_start_pos = mouse_pos;
        }

        // Handle left click to set center point (useful for exploration)
        if (zgui.isMouseClicked(.left) and !self.panning) {
            const fractal_coords = self.screenToFractal(mouse_pos, fractal_pos, fractal_size);
            self.center[0] = fractal_coords[0];
            self.center[1] = fractal_coords[1];

            // Update UI variables
            self.center_f32[0] = @floatCast(self.center[0]);
            self.center_f32[1] = @floatCast(self.center[1]);

            self.needs_update = true;
        }
    }

    if (self.panning) {
        if (zgui.isMouseDown(.right)) {
            const mouse_delta = [2]f32{ mouse_pos[0] - self.pan_start_pos[0], mouse_pos[1] - self.pan_start_pos[1] };

            // Convert mouse delta to fractal coordinate delta
            const range = 4.0 / self.zoom;
            const delta_x = (mouse_delta[0] / fractal_size[0]) * range;
            const delta_y = (mouse_delta[1] / fractal_size[1]) * range;

            // Apply pan (note: we subtract because we want to move in opposite direction)
            self.center[0] -= delta_x;
            self.center[1] -= delta_y;

            // Update UI variables
            self.center_f32[0] = @floatCast(self.center[0]);
            self.center_f32[1] = @floatCast(self.center[1]);

            self.needs_update = true;
            self.pan_start_pos = mouse_pos;
        } else {
            self.panning = false;
        }
    }

    // Handle zooming with mouse wheel using SDL events
    if (is_hovered and mouse_wheel_delta != 0) {
        // Zoom towards mouse cursor
        const fractal_coords = self.screenToFractal(mouse_pos, fractal_pos, fractal_size);

        const zoom_factor: f64 = if (mouse_wheel_delta > 0) 1.2 else 1.0 / 1.2;
        const old_zoom = self.zoom;
        self.zoom *= zoom_factor;
        self.zoom = std.math.clamp(self.zoom, 0.001, 10000.0);

        // Adjust center to zoom towards mouse cursor
        const zoom_ratio = self.zoom / old_zoom;
        self.center[0] = fractal_coords[0] + (self.center[0] - fractal_coords[0]) / zoom_ratio;
        self.center[1] = fractal_coords[1] + (self.center[1] - fractal_coords[1]) / zoom_ratio;

        // Update UI variables
        self.zoom_f32 = @floatCast(self.zoom);
        self.center_f32[0] = @floatCast(self.center[0]);
        self.center_f32[1] = @floatCast(self.center[1]);

        self.needs_update = true;
    }

    // Render fractal pixels with clipping
    draw_list.pushClipRect(.{
        .pmin = fractal_pos,
        .pmax = fractal_end,
        .intersect_with_current = true,
    });

    // Calculate pixel size to fit the display area
    const pixel_size = display_size / @as(f32, @floatFromInt(self.image_size[0]));

    // Only render if pixels are visible (at least 1 pixel each)
    if (pixel_size >= 1.0) {
        for (0..self.image_size[1]) |y| {
            for (0..self.image_size[0]) |x| {
                const color = self.image_buffer[y * self.image_size[0] + x];

                // Skip black pixels (background) for performance
                if (color == 0xFF000000) continue;

                const rect_min = [2]f32{
                    fractal_pos[0] + @as(f32, @floatFromInt(x)) * pixel_size,
                    fractal_pos[1] + @as(f32, @floatFromInt(y)) * pixel_size,
                };
                const rect_max = [2]f32{
                    rect_min[0] + pixel_size,
                    rect_min[1] + pixel_size,
                };

                draw_list.addRectFilled(.{
                    .pmin = rect_min,
                    .pmax = rect_max,
                    .col = color,
                });
            }
        }
    } else {
        // For very small pixels, sample at lower resolution
        const sample_step = @as(usize, @intFromFloat(1.0 / pixel_size));
        const effective_pixel_size = pixel_size * @as(f32, @floatFromInt(sample_step));

        for (0..self.image_size[1], 0..) |y, display_y_idx| {
            if (y % sample_step != 0) continue;
            const display_y = @as(f32, @floatFromInt(display_y_idx / sample_step));
            if (display_y * effective_pixel_size > display_size) break;

            for (0..self.image_size[0], 0..) |x, display_x_idx| {
                if (x % sample_step != 0) continue;
                const display_x = @as(f32, @floatFromInt(display_x_idx / sample_step));
                if (display_x * effective_pixel_size > display_size) break;

                const color = self.image_buffer[y * self.image_size[0] + x];
                if (color == 0xFF000000) continue;

                const rect_min = [2]f32{
                    fractal_pos[0] + display_x * effective_pixel_size,
                    fractal_pos[1] + display_y * effective_pixel_size,
                };
                const rect_max = [2]f32{
                    rect_min[0] + effective_pixel_size,
                    rect_min[1] + effective_pixel_size,
                };

                draw_list.addRectFilled(.{
                    .pmin = rect_min,
                    .pmax = rect_max,
                    .col = color,
                });
            }
        }
    }

    // Pop clipping
    draw_list.popClipRect();

    // Status info at the bottom (exactly like CanvasGui)
    const status_height = 60;
    const status_pos = [2]f32{ fractal_pos[0], fractal_end[1] - status_height };
    draw_list.addRectFilled(.{
        .pmin = status_pos,
        .pmax = [2]f32{ fractal_end[0], fractal_end[1] },
        .col = zgui.colorConvertFloat4ToU32(.{ 0.0, 0.0, 0.0, 0.7 }),
    });

    // Get fractal coordinates for current mouse position
    const fractal_coords = self.screenToFractal(mouse_pos, fractal_pos, fractal_size);

    zgui.setCursorScreenPos([2]f32{ status_pos[0] + 10, status_pos[1] + 5 });
    zgui.text("Fractal: ({d:.6}, {d:.6}) | Zoom: {d:.2}x | Center: ({d:.6}, {d:.6})", .{ fractal_coords[0], fractal_coords[1], self.zoom, self.center[0], self.center[1] });
    zgui.setCursorScreenPos([2]f32{ status_pos[0] + 10, status_pos[1] + 25 });
    zgui.text("Left: Set Center | Right: Pan | Wheel: Zoom", .{});
}

fn resetToDefault(self: *FractalsGui) void {
    switch (self.fractal_type) {
        .mandelbrot => {
            self.zoom = 1.0;
            self.center = .{ -0.5, 0.0 };
        },
        .julia => {
            self.zoom = 1.0;
            self.center = .{ 0.0, 0.0 };
            self.julia_c = .{ -0.8, 0.156 };
        },
        .burning_ship => {
            self.zoom = 1.0;
            self.center = .{ -0.5, -0.6 };
        },
        .sierpinski => {
            self.sierpinski_iterations = 10000;
        },
    }
    self.max_iterations = 100;
    self.color_scheme = 0;

    // Sync f32 values
    self.zoom_f32 = @floatCast(self.zoom);
    self.center_f32[0] = @floatCast(self.center[0]);
    self.center_f32[1] = @floatCast(self.center[1]);
    self.julia_c_f32[0] = @floatCast(self.julia_c[0]);
    self.julia_c_f32[1] = @floatCast(self.julia_c[1]);
}

fn generateFractal(self: *FractalsGui) !void {
    // Clear the image buffer
    @memset(self.image_buffer, 0xFF000000); // Black background

    switch (self.fractal_type) {
        .mandelbrot => try self.generateMandelbrot(),
        .julia => try self.generateJulia(),
        .sierpinski => try self.generateSierpinski(),
        .burning_ship => try self.generateBurningShip(),
    }

    // Update texture
    try self.updateTexture();
}

fn generateMandelbrot(self: *FractalsGui) !void {
    const width = self.image_size[0];
    const height = self.image_size[1];

    for (0..height) |y| {
        for (0..width) |x| {
            const fx = @as(f64, @floatFromInt(x));
            const fy = @as(f64, @floatFromInt(y));
            const fw = @as(f64, @floatFromInt(width));
            const fh = @as(f64, @floatFromInt(height));

            // Map pixel to complex plane
            const real = (fx / fw - 0.5) * 4.0 / self.zoom + self.center[0];
            const imag = (fy / fh - 0.5) * 4.0 / self.zoom + self.center[1];

            const iterations = mandelbrotIteration(real, imag, self.max_iterations);
            const color = self.getColor(iterations, self.max_iterations);

            self.image_buffer[y * width + x] = color;
        }
    }
}

fn generateJulia(self: *FractalsGui) !void {
    const width = self.image_size[0];
    const height = self.image_size[1];

    for (0..height) |y| {
        for (0..width) |x| {
            const fx = @as(f64, @floatFromInt(x));
            const fy = @as(f64, @floatFromInt(y));
            const fw = @as(f64, @floatFromInt(width));
            const fh = @as(f64, @floatFromInt(height));

            // Map pixel to complex plane
            const real = (fx / fw - 0.5) * 4.0 / self.zoom + self.center[0];
            const imag = (fy / fh - 0.5) * 4.0 / self.zoom + self.center[1];

            const iterations = juliaIteration(real, imag, self.julia_c[0], self.julia_c[1], self.max_iterations);
            const color = self.getColor(iterations, self.max_iterations);

            self.image_buffer[y * width + x] = color;
        }
    }
}

fn generateBurningShip(self: *FractalsGui) !void {
    const width = self.image_size[0];
    const height = self.image_size[1];

    for (0..height) |y| {
        for (0..width) |x| {
            const fx = @as(f64, @floatFromInt(x));
            const fy = @as(f64, @floatFromInt(y));
            const fw = @as(f64, @floatFromInt(width));
            const fh = @as(f64, @floatFromInt(height));

            // Map pixel to complex plane
            const real = (fx / fw - 0.5) * 4.0 / self.zoom + self.center[0];
            const imag = (fy / fh - 0.5) * 4.0 / self.zoom + self.center[1];

            const iterations = burningShipIteration(real, imag, self.max_iterations);
            const color = self.getColor(iterations, self.max_iterations);

            self.image_buffer[y * width + x] = color;
        }
    }
}

fn generateSierpinski(self: *FractalsGui) !void {
    const width = self.image_size[0];
    const height = self.image_size[1];

    // Triangle vertices
    const vertices = [_][2]f64{
        .{ @as(f64, @floatFromInt(width)) / 2.0, 10.0 },
        .{ 10.0, @as(f64, @floatFromInt(height)) - 10.0 },
        .{ @as(f64, @floatFromInt(width)) - 10.0, @as(f64, @floatFromInt(height)) - 10.0 },
    };

    // Start at random point
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    var rand = prng.random();

    var x = rand.float(f64) * @as(f64, @floatFromInt(width));
    var y = rand.float(f64) * @as(f64, @floatFromInt(height));

    for (0..self.sierpinski_iterations) |_| {
        // Choose random vertex
        const vertex = vertices[rand.intRangeAtMost(usize, 0, 2)];

        // Move halfway to chosen vertex
        x = (x + vertex[0]) / 2.0;
        y = (y + vertex[1]) / 2.0;

        // Plot point
        const px = @as(usize, @intFromFloat(@round(x)));
        const py = @as(usize, @intFromFloat(@round(y)));

        if (px < width and py < height) {
            self.image_buffer[py * width + px] = 0xFFFFFFFF; // White point
        }
    }
}

fn mandelbrotIteration(c_real: f64, c_imag: f64, max_iter: u32) u32 {
    var z_real: f64 = 0.0;
    var z_imag: f64 = 0.0;
    var iter: u32 = 0;

    while (iter < max_iter) {
        const z_real_sq = z_real * z_real;
        const z_imag_sq = z_imag * z_imag;

        if (z_real_sq + z_imag_sq > 4.0) break;

        const z_real_new = z_real_sq - z_imag_sq + c_real;
        const z_imag_new = 2.0 * z_real * z_imag + c_imag;

        z_real = z_real_new;
        z_imag = z_imag_new;
        iter += 1;
    }

    return iter;
}

fn juliaIteration(z_real: f64, z_imag: f64, c_real: f64, c_imag: f64, max_iter: u32) u32 {
    var zr = z_real;
    var zi = z_imag;
    var iter: u32 = 0;

    while (iter < max_iter) {
        const zr_sq = zr * zr;
        const zi_sq = zi * zi;

        if (zr_sq + zi_sq > 4.0) break;

        const zr_new = zr_sq - zi_sq + c_real;
        const zi_new = 2.0 * zr * zi + c_imag;

        zr = zr_new;
        zi = zi_new;
        iter += 1;
    }

    return iter;
}

fn burningShipIteration(c_real: f64, c_imag: f64, max_iter: u32) u32 {
    var z_real: f64 = 0.0;
    var z_imag: f64 = 0.0;
    var iter: u32 = 0;

    while (iter < max_iter) {
        const z_real_sq = z_real * z_real;
        const z_imag_sq = z_imag * z_imag;

        if (z_real_sq + z_imag_sq > 4.0) break;

        // Take absolute values (burning ship modification)
        const z_real_abs = @abs(z_real);
        const z_imag_abs = @abs(z_imag);

        const z_real_new = z_real_abs * z_real_abs - z_imag_abs * z_imag_abs + c_real;
        const z_imag_new = 2.0 * z_real_abs * z_imag_abs + c_imag;

        z_real = z_real_new;
        z_imag = z_imag_new;
        iter += 1;
    }

    return iter;
}

fn getColor(self: *const FractalsGui, iterations: u32, max_iterations: u32) u32 {
    if (iterations >= max_iterations) {
        return 0xFF000000; // Black for points in the set
    }

    const t = @as(f64, @floatFromInt(iterations)) / @as(f64, @floatFromInt(max_iterations));

    return switch (self.color_scheme) {
        0 => blendColor(0xFF0000FF, 0xFFFFFF00, t), // Blue to yellow
        1 => blendColor(0xFF800080, 0xFFFFFFFF, t), // Purple to white
        2 => blendColor(0xFF000080, 0xFFFF0000, t), // Navy to red
        3 => hsvToRgb(t * 360.0, 1.0, 1.0),
        else => blendColor(0xFF0000FF, 0xFFFFFF00, t), // Default to blue-yellow
    };
}

fn blendColor(color1: u32, color2: u32, t: f64) u32 {
    const r1 = @as(f64, @floatFromInt((color1 >> 16) & 0xFF));
    const g1 = @as(f64, @floatFromInt((color1 >> 8) & 0xFF));
    const b1 = @as(f64, @floatFromInt(color1 & 0xFF));

    const r2 = @as(f64, @floatFromInt((color2 >> 16) & 0xFF));
    const g2 = @as(f64, @floatFromInt((color2 >> 8) & 0xFF));
    const b2 = @as(f64, @floatFromInt(color2 & 0xFF));

    const r = @as(u32, @intFromFloat(r1 + (r2 - r1) * t));
    const g = @as(u32, @intFromFloat(g1 + (g2 - g1) * t));
    const b = @as(u32, @intFromFloat(b1 + (b2 - b1) * t));

    return 0xFF000000 | (r << 16) | (g << 8) | b;
}

fn hsvToRgb(h: f64, s: f64, v: f64) u32 {
    const c = v * s;
    const x = c * (1.0 - @abs(@mod(h / 60.0, 2.0) - 1.0));
    const m = v - c;

    var r: f64 = 0.0;
    var g: f64 = 0.0;
    var b: f64 = 0.0;

    if (h >= 0.0 and h < 60.0) {
        r = c;
        g = x;
        b = 0.0;
    } else if (h >= 60.0 and h < 120.0) {
        r = x;
        g = c;
        b = 0.0;
    } else if (h >= 120.0 and h < 180.0) {
        r = 0.0;
        g = c;
        b = x;
    } else if (h >= 180.0 and h < 240.0) {
        r = 0.0;
        g = x;
        b = c;
    } else if (h >= 240.0 and h < 300.0) {
        r = x;
        g = 0.0;
        b = c;
    } else if (h >= 300.0 and h < 360.0) {
        r = c;
        g = 0.0;
        b = x;
    }

    const red = @as(u32, @intFromFloat((r + m) * 255.0));
    const green = @as(u32, @intFromFloat((g + m) * 255.0));
    const blue = @as(u32, @intFromFloat((b + m) * 255.0));

    return 0xFF000000 | (red << 16) | (green << 8) | blue;
}

fn updateTexture(self: *FractalsGui) !void {
    // For the display method we're using, we just mark that we have data ready
    self.texture_id = @ptrFromInt(1); // Non-null placeholder
}
