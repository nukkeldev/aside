//! Themes for the GUI

// -- Imports -- //

const std = @import("std");
const zgui = @import("zgui");

// -- Themes -- //

// Apply Catppuccin Mocha theme to ImGui
pub fn applyImGuiTheme(theme: anytype) void {
    const style = zgui.getStyle();

    // Window colors
    style.setColor(.window_bg, theme.base);
    style.setColor(.child_bg, theme.mantle);
    style.setColor(.popup_bg, theme.surface0);

    // Border colors
    style.setColor(.border, theme.surface1);
    style.setColor(.border_shadow, theme.crust);

    // Frame colors (buttons, checkboxes, etc.)
    style.setColor(.frame_bg, theme.surface0);
    style.setColor(.frame_bg_hovered, theme.surface1);
    style.setColor(.frame_bg_active, theme.surface2);

    // Title colors
    style.setColor(.title_bg, theme.mantle);
    style.setColor(.title_bg_active, theme.surface0);
    style.setColor(.title_bg_collapsed, theme.surface0);

    // Menu colors
    style.setColor(.menu_bar_bg, theme.surface0);

    // Scrollbar colors
    style.setColor(.scrollbar_bg, theme.surface0);
    style.setColor(.scrollbar_grab, theme.surface1);
    style.setColor(.scrollbar_grab_hovered, theme.surface2);
    style.setColor(.scrollbar_grab_active, theme.overlay0);

    // Checkbox colors
    style.setColor(.check_mark, theme.green);

    // Slider colors
    style.setColor(.slider_grab, theme.blue);
    style.setColor(.slider_grab_active, theme.sapphire);

    // Button colors
    style.setColor(.button, theme.surface0);
    style.setColor(.button_hovered, theme.surface1);
    style.setColor(.button_active, theme.surface2);

    // Header colors (for tabs)
    style.setColor(.header, theme.surface0);
    style.setColor(.header_hovered, theme.surface1);
    style.setColor(.header_active, theme.surface2);

    // Separator colors
    style.setColor(.separator, theme.surface1);
    style.setColor(.separator_hovered, theme.surface2);
    style.setColor(.separator_active, theme.overlay0);

    // Resize grip colors
    style.setColor(.resize_grip, theme.surface1);
    style.setColor(.resize_grip_hovered, theme.surface2);
    style.setColor(.resize_grip_active, theme.overlay0);

    // Tab colors
    style.setColor(.tab, theme.surface0);
    style.setColor(.tab_hovered, theme.surface1);
    style.setColor(.tab_selected, theme.surface2);
    style.setColor(.tab_dimmed, theme.surface0);
    style.setColor(.tab_dimmed_selected, theme.surface1);

    // Text colors
    style.setColor(.text, theme.text);
    style.setColor(.text_disabled, theme.overlay0);

    // Plot colors
    style.setColor(.plot_lines, theme.blue);
    style.setColor(.plot_lines_hovered, theme.sapphire);
    style.setColor(.plot_histogram, theme.green);
    style.setColor(.plot_histogram_hovered, theme.teal);

    // Table colors
    style.setColor(.table_header_bg, theme.surface0);
    style.setColor(.table_border_strong, theme.surface1);
    style.setColor(.table_border_light, theme.surface0);
    style.setColor(.table_row_bg, theme.surface0);
    style.setColor(.table_row_bg_alt, theme.surface1);

    // Progress bar colors
    style.setColor(.plot_lines, theme.blue);

    // Drag and drop colors
    style.setColor(.drag_drop_target, theme.yellow);

    // Navigation colors
    style.setColor(.nav_highlight, theme.blue);
    style.setColor(.nav_windowing_highlight, theme.blue);
    style.setColor(.nav_windowing_dim_bg, theme.overlay0);

    // Modal colors
    style.setColor(.modal_window_dim_bg, theme.overlay0);
}

pub const CatppuccinMocha = struct {
    // Base colors
    pub const base = @"#2rgba"("#1e1e2e");
    pub const mantle = @"#2rgba"("#181825");
    pub const crust = @"#2rgba"("#11111b");

    // Text colors
    pub const text = @"#2rgba"("#cdd6f4");
    pub const subtext1 = @"#2rgba"("#bac2de");
    pub const subtext0 = @"#2rgba"("#a6adc8");
    pub const overlay2 = @"#2rgba"("#9399b2");
    pub const overlay1 = @"#2rgba"("#7f849c");
    pub const overlay0 = @"#2rgba"("#6c7086");
    pub const surface2 = @"#2rgba"("#585b70");
    pub const surface1 = @"#2rgba"("#45475a");
    pub const surface0 = @"#2rgba"("#313244");

    // Accent colors
    pub const rosewater = @"#2rgba"("#f5e0dc");
    pub const flamingo = @"#2rgba"("#f2cdcd");
    pub const pink = @"#2rgba"("#f5c2e7");
    pub const mauve = @"#2rgba"("#cba6f7");
    pub const red = @"#2rgba"("#f38ba8");
    pub const maroon = @"#2rgba"("#eba0ac");
    pub const peach = @"#2rgba"("#fab387");
    pub const yellow = @"#2rgba"("#f9e2af");
    pub const green = @"#2rgba"("#a6e3a1");
    pub const teal = @"#2rgba"("#94e2d5");
    pub const sky = @"#2rgba"("#89dceb");
    pub const sapphire = @"#2rgba"("#74c7ec");
    pub const blue = @"#2rgba"("#89b4fa");
    pub const lavender = @"#2rgba"("#b4befe");
};

// -- Helpers -- //

fn @"#2rgba"(comptime hex: []const u8) [4]f32 {
    if (hex.len != 7 and hex.len != 9) {
        @compileError("Hex color must be 7 or 9 characters long (e.g., #RRGGBB or #RRGGBBAA)");
    }

    var components: [4]f32 = undefined;
    components[3] = 1.0;

    for (0..3) |i| {
        const start = 1 + i * 2;
        const end = start + 2;
        const value = try std.fmt.parseInt(u8, hex[start..end], 16);
        components[i] = @as(f32, @floatFromInt(value)) / 255.0;
    }

    if (hex.len == 9) {
        components[3] = @as(f32, @floatFromInt(try std.fmt.parseInt(u8, hex[7..9], 16))) / 255.0;
    }

    return components;
}
