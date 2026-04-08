/// Color types and macOS-inspired theme palette.
/// Logical colors are 0x00RRGGBB (xRGB). The compositor converts to the GOP
/// framebuffer layout (BGRX vs RGBX) using `lib/pixel_format.zig`.

pub const Color = u32;

pub fn rgb(r: u8, g: u8, b: u8) Color {
    return @as(u32, r) << 16 | @as(u32, g) << 8 | b;
}

pub fn rgba(r: u8, g: u8, b: u8, _: u8) Color {
    return rgb(r, g, b);
}

pub fn getRed(c: Color) u8 {
    return @truncate(c >> 16);
}

pub fn getGreen(c: Color) u8 {
    return @truncate(c >> 8);
}

pub fn getBlue(c: Color) u8 {
    return @truncate(c);
}

/// Alpha-blend `fg` over `bg` with 8-bit alpha.
pub fn blend(fg: Color, bg: Color, alpha: u8) Color {
    const a: u32 = alpha;
    const inv_a: u32 = 255 - a;
    const r = (@as(u32, getRed(fg)) * a + @as(u32, getRed(bg)) * inv_a) / 255;
    const g = (@as(u32, getGreen(fg)) * a + @as(u32, getGreen(bg)) * inv_a) / 255;
    const b = (@as(u32, getBlue(fg)) * a + @as(u32, getBlue(bg)) * inv_a) / 255;
    return rgb(@truncate(r), @truncate(g), @truncate(b));
}

/// Linearly interpolate between two colors by `t` (0-255).
pub fn lerp(a: Color, b_col: Color, t: u8) Color {
    return blend(b_col, a, t);
}

// ── macOS-inspired Theme ─────────────────────────────────

pub const theme = struct {
    // Window chrome
    pub const title_bar: Color = rgb(232, 232, 232);
    pub const title_bar_active: Color = rgb(212, 212, 212);
    pub const title_text: Color = rgb(60, 60, 60);
    pub const window_bg: Color = rgb(246, 246, 246);
    pub const window_border: Color = rgb(190, 190, 190);
    pub const window_shadow: Color = rgb(0, 0, 0);

    // Traffic light buttons
    pub const btn_close: Color = rgb(255, 95, 87);
    pub const btn_minimize: Color = rgb(255, 189, 46);
    pub const btn_maximize: Color = rgb(40, 200, 64);
    pub const btn_inactive: Color = rgb(204, 204, 204);

    // Menu bar
    pub const menubar_bg: Color = rgb(240, 240, 240);
    pub const menubar_text: Color = rgb(30, 30, 30);
    pub const menubar_highlight: Color = rgb(0, 122, 255);

    // Dock
    pub const dock_bg: Color = rgb(200, 200, 200);
    pub const dock_border: Color = rgb(170, 170, 170);

    // Desktop wallpaper gradient
    pub const wallpaper_top: Color = rgb(30, 5, 51);
    pub const wallpaper_mid: Color = rgb(58, 27, 108);
    pub const wallpaper_bottom: Color = rgb(100, 60, 150);

    // Accent
    pub const accent: Color = rgb(0, 122, 255);
    pub const accent_hover: Color = rgb(0, 100, 220);

    // Text
    pub const text_primary: Color = rgb(30, 30, 30);
    pub const text_secondary: Color = rgb(120, 120, 120);
    pub const text_light: Color = rgb(255, 255, 255);

    // General
    pub const white: Color = rgb(255, 255, 255);
    pub const black: Color = rgb(0, 0, 0);
    pub const transparent: Color = 0;
};
