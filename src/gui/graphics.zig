/// 2D graphics primitives for the GUI compositor.
/// Supports double buffering: draws to a back buffer, then swaps to the
/// framebuffer in a single pass to eliminate visible tearing/flickering.

const font = @import("font.zig");
const color_mod = @import("color.zig");
const pixel_format = @import("../lib/pixel_format.zig");
const Color = color_mod.Color;

var fb: [*]volatile u32 = undefined;
var back: [*]u32 = undefined;
var has_back_buffer: bool = false;
var fb_w: u32 = 0;
var fb_h: u32 = 0;
var fb_stride: u32 = 0;
var pix_fmt: pixel_format.FramebufferPixelFormat = .blue_green_red_reserved_8_bit_per_color;
var ready: bool = false;

pub fn init(base: [*]volatile u32, w: u32, h: u32, stride: u32, fmt: pixel_format.FramebufferPixelFormat) void {
    fb = base;
    fb_w = w;
    fb_h = h;
    fb_stride = stride;
    pix_fmt = fmt;
    has_back_buffer = false;
    ready = true;
}

pub fn enableDoubleBuffer(back_buf: [*]u32) void {
    back = back_buf;
    has_back_buffer = true;
}

pub fn swapBuffers() void {
    if (!has_back_buffer) return;
    const total = @as(usize, fb_stride) * fb_h;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        fb[i] = pixel_format.xrgbToNative(back[i], pix_fmt);
    }
}

pub fn screenWidth() u32 {
    return fb_w;
}
pub fn screenHeight() u32 {
    return fb_h;
}

inline fn writePixel(offset: usize, c: Color) void {
    if (has_back_buffer) {
        back[offset] = c;
    } else {
        fb[offset] = pixel_format.xrgbToNative(c, pix_fmt);
    }
}

inline fn readPixel(offset: usize) Color {
    if (has_back_buffer) {
        return back[offset];
    } else {
        return pixel_format.nativeToXrgb(fb[offset], pix_fmt);
    }
}

pub fn putPixel(x: i32, y: i32, c: Color) void {
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux < fb_w and uy < fb_h) {
        writePixel(@as(usize, uy) * fb_stride + ux, c);
    }
}

pub fn getPixel(x: i32, y: i32) Color {
    if (x < 0 or y < 0) return 0;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux < fb_w and uy < fb_h) {
        return readPixel(@as(usize, uy) * fb_stride + ux);
    }
    return 0;
}

pub fn putPixelBlend(x: i32, y: i32, c: Color, alpha: u8) void {
    if (x < 0 or y < 0) return;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux < fb_w and uy < fb_h) {
        const idx = @as(usize, uy) * fb_stride + ux;
        writePixel(idx, color_mod.blend(c, readPixel(idx), alpha));
    }
}

// ── Rectangles ───────────────────────────────────────────

pub fn fillRect(x: i32, y: i32, w: u32, h: u32, c: Color) void {
    var row: i32 = y;
    const end_y = y + @as(i32, @intCast(h));
    const end_x = x + @as(i32, @intCast(w));
    while (row < end_y) : (row += 1) {
        if (row < 0 or row >= @as(i32, @intCast(fb_h))) continue;
        var col: i32 = x;
        while (col < end_x) : (col += 1) {
            if (col >= 0 and col < @as(i32, @intCast(fb_w))) {
                writePixel(@as(usize, @intCast(row)) * fb_stride + @as(usize, @intCast(col)), c);
            }
        }
    }
}

pub fn fillRectAlpha(x: i32, y: i32, w: u32, h: u32, c: Color, alpha: u8) void {
    var row: i32 = y;
    const end_y = y + @as(i32, @intCast(h));
    const end_x = x + @as(i32, @intCast(w));
    while (row < end_y) : (row += 1) {
        if (row < 0 or row >= @as(i32, @intCast(fb_h))) continue;
        var col: i32 = x;
        while (col < end_x) : (col += 1) {
            if (col >= 0 and col < @as(i32, @intCast(fb_w))) {
                const idx = @as(usize, @intCast(row)) * fb_stride + @as(usize, @intCast(col));
                writePixel(idx, color_mod.blend(c, readPixel(idx), alpha));
            }
        }
    }
}

pub fn drawRect(x: i32, y: i32, w: u32, h: u32, c: Color) void {
    drawHLine(x, y, w, c);
    drawHLine(x, y + @as(i32, @intCast(h)) - 1, w, c);
    drawVLine(x, y, h, c);
    drawVLine(x + @as(i32, @intCast(w)) - 1, y, h, c);
}

/// Rounded rectangle (macOS-style window corners).
pub fn fillRoundedRect(x: i32, y: i32, w: u32, h: u32, radius: u32, c: Color) void {
    const r: i32 = @intCast(@min(radius, @min(w / 2, h / 2)));
    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);

    // Main body (excluding corners)
    fillRect(x + r, y, w - @as(u32, @intCast(r)) * 2, h, c);
    fillRect(x, y + r, w, h - @as(u32, @intCast(r)) * 2, c);

    // Four rounded corners
    fillCorner(x + r, y + r, r, c, true, true);
    fillCorner(x + iw - r - 1, y + r, r, c, false, true);
    fillCorner(x + r, y + ih - r - 1, r, c, true, false);
    fillCorner(x + iw - r - 1, y + ih - r - 1, r, c, false, false);
}

fn fillCorner(cx: i32, cy: i32, r: i32, c: Color, left: bool, top: bool) void {
    var dy: i32 = 0;
    while (dy <= r) : (dy += 1) {
        // Integer circle approximation: x² + y² ≤ r²
        var dx: i32 = 0;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy <= r * r) {
                const px = if (left) cx - dx else cx + dx;
                const py = if (top) cy - dy else cy + dy;
                putPixel(px, py, c);
            }
        }
    }
}

// ── Lines ────────────────────────────────────────────────

pub fn drawHLine(x: i32, y: i32, w: u32, c: Color) void {
    if (y < 0 or y >= @as(i32, @intCast(fb_h))) return;
    var col: i32 = x;
    const end = x + @as(i32, @intCast(w));
    while (col < end) : (col += 1) {
        if (col >= 0 and col < @as(i32, @intCast(fb_w))) {
            writePixel(@as(usize, @intCast(y)) * fb_stride + @as(usize, @intCast(col)), c);
        }
    }
}

pub fn drawVLine(x: i32, y: i32, h: u32, c: Color) void {
    if (x < 0 or x >= @as(i32, @intCast(fb_w))) return;
    var row: i32 = y;
    const end = y + @as(i32, @intCast(h));
    while (row < end) : (row += 1) {
        if (row >= 0 and row < @as(i32, @intCast(fb_h))) {
            writePixel(@as(usize, @intCast(row)) * fb_stride + @as(usize, @intCast(x)), c);
        }
    }
}

// ── Circle ───────────────────────────────────────────────

pub fn fillCircle(cx: i32, cy: i32, r: u32, c: Color) void {
    const ir: i32 = @intCast(r);
    var dy: i32 = -ir;
    while (dy <= ir) : (dy += 1) {
        var dx: i32 = -ir;
        while (dx <= ir) : (dx += 1) {
            if (dx * dx + dy * dy <= ir * ir) {
                putPixel(cx + dx, cy + dy, c);
            }
        }
    }
}

/// 绘制弧形（用于WiFi信号等）
pub fn drawArc(cx: i32, cy: i32, r: u32, c: Color, thickness: u8) void {
    const ir: i32 = @intCast(r);
    const outer_r = ir;
    const inner_r = @as(i32, @intCast(r)) - @as(i32, @intCast(thickness));

    var dy: i32 = -outer_r;
    while (dy <= outer_r) : (dy += 1) {
        var dx: i32 = -outer_r;
        while (dx <= outer_r) : (dx += 1) {
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq <= outer_r * outer_r and dist_sq >= inner_r * inner_r) {
                // 只绘制上半圆（90度到270度，即向下凸起）
                if (dy <= 0) {
                    putPixel(cx + dx, cy + dy, c);
                }
            }
        }
    }
}

// ── Text rendering ───────────────────────────────────────

pub fn drawChar(x: i32, y: i32, ch: u8, c: Color) void {
    const glyph = font.getGlyph(ch) orelse font.getGlyph('?') orelse return;
    var row: u32 = 0;
    while (row < font.GLYPH_H) : (row += 1) {
        const bits = glyph[row];
        var col: u32 = 0;
        while (col < font.GLYPH_W) : (col += 1) {
            if (bits & (@as(u8, 0x80) >> @intCast(col)) != 0) {
                putPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), c);
            }
        }
    }
}

pub fn drawString(x: i32, y: i32, str: []const u8, c: Color) void {
    var cx: i32 = x;
    for (str) |ch| {
        if (ch == '\n') {
            cx = x;
            continue;
        }
        drawChar(cx, y, ch, c);
        cx += @intCast(font.GLYPH_W);
    }
}

pub fn drawStringCentered(x: i32, y: i32, w: u32, str: []const u8, c: Color) void {
    const text_w: i32 = @intCast(str.len * font.GLYPH_W);
    const offset = @divTrunc(@as(i32, @intCast(w)) - text_w, 2);
    drawString(x + offset, y, str, c);
}

/// Vertical gradient fill.
pub fn fillGradientV(x: i32, y: i32, w: u32, h: u32, top: Color, bottom: Color) void {
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const t: u8 = @intCast((@as(u32, row) * 255) / (if (h > 1) h - 1 else 1));
        const c = color_mod.lerp(top, bottom, t);
        drawHLine(x, y + @as(i32, @intCast(row)), w, c);
    }
}

pub fn clear(c: Color) void {
    fillRect(0, 0, fb_w, fb_h, c);
}

// ── Image blitting ──────────────────────────────────────

/// Draw an RGBA image at the given coordinates (1:1 pixel mapping).
/// Handles alpha blending: pixels with alpha=0 are skipped,
/// pixels with alpha=255 are written directly, partial alpha blends with background.
pub fn blitImage(x: i32, y: i32, img_w: u32, img_h: u32, rgba: [*]const u8) void {
    if (img_w == 0 or img_h == 0) return;

    var row: u32 = 0;
    while (row < img_h) : (row += 1) {
        const py: i32 = y + @as(i32, @intCast(row));
        if (py < 0 or py >= @as(i32, @intCast(fb_h))) continue;

        var col: u32 = 0;
        while (col < img_w) : (col += 1) {
            const px: i32 = x + @as(i32, @intCast(col));
            if (px < 0 or px >= @as(i32, @intCast(fb_w))) continue;

            const pi: usize = @as(usize, row) * img_w * 4 + @as(usize, col) * 4;
            const src_r = rgba[pi + 0];
            const src_g = rgba[pi + 1];
            const src_b = rgba[pi + 2];
            const src_a = rgba[pi + 3];

            if (src_a == 0) continue;

            const idx: usize = @as(usize, @intCast(py)) * fb_stride + @as(usize, @intCast(px));

            if (src_a == 255) {
                const c: Color = (@as(Color, src_r) << 16) | (@as(Color, src_g) << 8) | @as(Color, src_b);
                writePixel(idx, c);
            } else {
                const bg = readPixel(idx);
                const bg_r: u8 = @intCast((bg >> 16) & 0xFF);
                const bg_g: u8 = @intCast((bg >> 8) & 0xFF);
                const bg_b: u8 = @intCast(bg & 0xFF);
                const out_r: u8 = @intCast((@as(u32, src_r) * @as(u32, src_a) + @as(u32, bg_r) * (255 - @as(u32, src_a))) / 255);
                const out_g: u8 = @intCast((@as(u32, src_g) * @as(u32, src_a) + @as(u32, bg_g) * (255 - @as(u32, src_a))) / 255);
                const out_b: u8 = @intCast((@as(u32, src_b) * @as(u32, src_a) + @as(u32, bg_b) * (255 - @as(u32, src_a))) / 255);
                writePixel(idx, (@as(Color, out_r) << 16) | (@as(Color, out_g) << 8) | @as(Color, out_b));
            }
        }
    }
}

/// Draw an RGBA image scaled to fill the target rectangle (w × h).
/// Uses simple nearest-neighbor scaling for performance.
pub fn blitImageScaled(x: i32, y: i32, dst_w: u32, dst_h: u32, img_w: u32, img_h: u32, rgba: [*]const u8) void {
    if (dst_w == 0 or dst_h == 0 or img_w == 0 or img_h == 0) return;

    var dst_y: u32 = 0;
    while (dst_y < dst_h) : (dst_y += 1) {
        const py: i32 = y + @as(i32, @intCast(dst_y));
        if (py < 0 or py >= @as(i32, @intCast(fb_h))) continue;

        const src_y = (@as(u32, @intCast(dst_y)) * img_h) / dst_h;
        if (src_y >= img_h) continue;

        var dst_x: u32 = 0;
        while (dst_x < dst_w) : (dst_x += 1) {
            const px: i32 = x + @as(i32, @intCast(dst_x));
            if (px < 0 or px >= @as(i32, @intCast(fb_w))) continue;

            const src_x = (@as(u32, @intCast(dst_x)) * img_w) / dst_w;
            if (src_x >= img_w) continue;

            const pi: usize = @as(usize, src_y) * img_w * 4 + @as(usize, src_x) * 4;
            const src_r = rgba[pi + 0];
            const src_g = rgba[pi + 1];
            const src_b = rgba[pi + 2];
            const src_a = rgba[pi + 3];

            if (src_a == 0) continue;

            const idx: usize = @as(usize, @intCast(py)) * fb_stride + @as(usize, @intCast(px));

            if (src_a == 255) {
                const c: Color = (@as(Color, src_r) << 16) | (@as(Color, src_g) << 8) | @as(Color, src_b);
                writePixel(idx, c);
            } else {
                const bg = readPixel(idx);
                const bg_r: u8 = @intCast((bg >> 16) & 0xFF);
                const bg_g: u8 = @intCast((bg >> 8) & 0xFF);
                const bg_b: u8 = @intCast(bg & 0xFF);
                const out_r: u8 = @intCast((@as(u32, src_r) * @as(u32, src_a) + @as(u32, bg_r) * (255 - @as(u32, src_a))) / 255);
                const out_g: u8 = @intCast((@as(u32, src_g) * @as(u32, src_a) + @as(u32, bg_g) * (255 - @as(u32, src_a))) / 255);
                const out_b: u8 = @intCast((@as(u32, src_b) * @as(u32, src_a) + @as(u32, bg_b) * (255 - @as(u32, src_a))) / 255);
                writePixel(idx, (@as(Color, out_r) << 16) | (@as(Color, out_g) << 8) | @as(Color, out_b));
            }
        }
    }
}
