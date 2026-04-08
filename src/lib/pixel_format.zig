//! UEFI GOP pixel layout ↔ logical 0x00RRGGBB (theme colors in color.zig).

/// Matches `EFI_GRAPHICS_PIXEL_FORMAT` numeric values (UEFI spec).
pub const FramebufferPixelFormat = enum(u32) {
    red_green_blue_reserved_8_bit_per_color = 0,
    blue_green_red_reserved_8_bit_per_color = 1,
    bit_mask = 2,
    blt_only = 3,
};

/// Convert logical xRGB to a 32-bit framebuffer pixel (little-endian byte order in memory).
pub fn xrgbToNative(xrgb: u32, fmt: FramebufferPixelFormat) u32 {
    const r = (xrgb >> 16) & 0xff;
    const g = (xrgb >> 8) & 0xff;
    const b = xrgb & 0xff;
    return switch (fmt) {
        .red_green_blue_reserved_8_bit_per_color => r | (g << 8) | (b << 16) | (0xff << 24),
        .blue_green_red_reserved_8_bit_per_color => b | (g << 8) | (r << 16) | (0xff << 24),
        // Unknown layouts: assume BGRX (common on PC/AAVMF GOP).
        .bit_mask, .blt_only => b | (g << 8) | (r << 16) | (0xff << 24),
    };
}

/// Interpret a framebuffer pixel as logical xRGB for blending / read-modify-write.
pub fn nativeToXrgb(native: u32, fmt: FramebufferPixelFormat) u32 {
    return switch (fmt) {
        .red_green_blue_reserved_8_bit_per_color => {
            const r = native & 0xff;
            const g = (native >> 8) & 0xff;
            const b = (native >> 16) & 0xff;
            return r << 16 | g << 8 | b;
        },
        .blue_green_red_reserved_8_bit_per_color, .bit_mask, .blt_only => {
            const b = native & 0xff;
            const g = (native >> 8) & 0xff;
            const r = (native >> 16) & 0xff;
            return r << 16 | g << 8 | b;
        },
    };
}
