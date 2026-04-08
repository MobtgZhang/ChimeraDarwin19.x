/// 窗口管理器 - macOS风格窗口，支持标题栏、交通灯按钮和拖拽
/// 包含阴影、动画、按钮悬停效果等增强功能

const graphics = @import("graphics.zig");
const color_mod = @import("color.zig");
const font = @import("font.zig");
const resources = @import("resources/mod.zig");
const texture_cache = resources.texture_cache;
const Color = color_mod.Color;
const theme = color_mod.theme;

pub const MAX_WINDOWS: usize = 16;
pub const TITLE_BAR_H: u32 = 28;
pub const BTN_RADIUS: u32 = 6;
pub const BTN_Y_OFFSET: u32 = 8;
pub const BTN_SPACING: u32 = 20;
pub const TITLE_MAX_LEN: usize = 64;

/// 窗口按钮悬停状态
pub const ButtonHoverState = struct {
    close: bool,
    minimize: bool,
    maximize: bool,
};

/// 窗口结构
pub const Window = struct {
    id: u16,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    title: [TITLE_MAX_LEN]u8,
    title_len: usize,
    visible: bool,
    focused: bool,
    closable: bool,
    minimizable: bool,
    content_type: ContentType,
    text_buf: [2048]u8,
    text_len: usize,
    active: bool,

    // 动画相关
    alpha: u8,           // 透明度 (0-255)
    scale: f32,          // 缩放比例
    target_scale: f32,   // 目标缩放
    animating: bool,     // 是否正在动画

    // 悬停状态
    hover: ButtonHoverState,

    // 窗口按钮纹理
    btn_close_tex: ?texture_cache.Texture,
    btn_minimize_tex: ?texture_cache.Texture,
    btn_maximize_tex: ?texture_cache.Texture,
};

pub const ContentType = enum {
    empty,
    text_view,
    about_dialog,
    terminal,
    file_manager,
};

var windows: [MAX_WINDOWS]Window = undefined;
var window_count: usize = 0;
var z_order: [MAX_WINDOWS]u16 = undefined;
var z_count: usize = 0;
var drag_win: ?u16 = null;
var drag_offset_x: i32 = 0;
var drag_offset_y: i32 = 0;

/// 窗口初始化
pub fn init() void {
    window_count = 0;
    z_count = 0;
    for (&windows) |*w| {
        w.* = .{
            .id = 0,
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .title = undefined,
            .title_len = 0,
            .visible = false,
            .focused = false,
            .closable = true,
            .minimizable = true,
            .content_type = .empty,
            .text_buf = undefined,
            .text_len = 0,
            .active = false,
            .alpha = 255,
            .scale = 1.0,
            .target_scale = 1.0,
            .animating = false,
            .hover = .{ .close = false, .minimize = false, .maximize = false },
            .btn_close_tex = null,
            .btn_minimize_tex = null,
            .btn_maximize_tex = null,
        };
    }
}

/// 创建窗口
pub fn createWindow(title: []const u8, x: i32, y: i32, w: u32, h: u32, content: ContentType) ?u16 {
    if (window_count >= MAX_WINDOWS) return null;
    const id: u16 = @intCast(window_count);
    var win = &windows[window_count];
    win.* = .{
        .id = id,
        .x = x,
        .y = y,
        .width = w,
        .height = h,
        .title = [_]u8{0} ** TITLE_MAX_LEN,
        .title_len = @min(title.len, TITLE_MAX_LEN),
        .visible = true,
        .focused = true,
        .closable = true,
        .minimizable = true,
        .content_type = content,
        .text_buf = [_]u8{0} ** 2048,
        .text_len = 0,
        .active = true,
        .alpha = 0,
        .scale = 0.8,
        .target_scale = 1.0,
        .animating = true,
        .hover = .{ .close = false, .minimize = false, .maximize = false },
        .btn_close_tex = null,
        .btn_minimize_tex = null,
        .btn_maximize_tex = null,
    };
    @memcpy(win.title[0..win.title_len], title[0..win.title_len]);

    // 取消所有其他窗口的焦点
    for (windows[0..window_count]) |*other| {
        if (other.active) other.focused = false;
    }

    z_order[z_count] = id;
    z_count += 1;
    window_count += 1;

    // 尝试加载窗口按钮纹理
    loadWindowButtonTextures(win);

    return id;
}

/// 加载窗口按钮纹理
fn loadWindowButtonTextures(win: *Window) void {
    win.btn_close_tex = texture_cache.loadWindowButton("btn_close");
    win.btn_minimize_tex = texture_cache.loadWindowButton("btn_minimize");
    win.btn_maximize_tex = texture_cache.loadWindowButton("btn_maximize");
}

/// 设置窗口文本
pub fn setWindowText(id: u16, text: []const u8) void {
    if (id >= window_count) return;
    var win = &windows[id];
    const len = @min(text.len, win.text_buf.len);
    @memcpy(win.text_buf[0..len], text[0..len]);
    win.text_len = len;
}

/// 关闭窗口
pub fn closeWindow(id: u16) void {
    if (id >= window_count) return;
    windows[id].visible = false;
    windows[id].active = false;
    windows[id].animating = true;
    windows[id].target_scale = 0.8;

    // 从z-order移除
    var i: usize = 0;
    while (i < z_count) {
        if (z_order[i] == id) {
            var j = i;
            while (j + 1 < z_count) : (j += 1) {
                z_order[j] = z_order[j + 1];
            }
            z_count -= 1;
        } else {
            i += 1;
        }
    }
}

/// 聚焦窗口
pub fn focusWindow(id: u16) void {
    for (windows[0..window_count]) |*w| w.focused = false;
    if (id < window_count) windows[id].focused = true;

    // 移动到z-order顶部
    var i: usize = 0;
    while (i < z_count) : (i += 1) {
        if (z_order[i] == id) {
            var j = i;
            while (j + 1 < z_count) : (j += 1) {
                z_order[j] = z_order[j + 1];
            }
            z_order[z_count - 1] = id;
            break;
        }
    }
}

/// 获取窗口数量
pub fn getWindowCount() usize {
    return window_count;
}

// ── 命中测试 ──────────────────────────────────────────

pub const HitResult = enum {
    none,
    title_bar,
    close_btn,
    minimize_btn,
    maximize_btn,
    content,
};

/// 命中测试
pub fn hitTest(mx: i32, my: i32) ?struct { id: u16, hit: HitResult } {
    // 按z-order反向检查（顶部窗口优先）
    var i = z_count;
    while (i > 0) {
        i -= 1;
        const wid = z_order[i];
        const win = &windows[wid];
        if (!win.visible or !win.active) continue;

        if (mx >= win.x and mx < win.x + @as(i32, @intCast(win.width)) and
            my >= win.y and my < win.y + @as(i32, @intCast(win.height)))
        {
            if (my < win.y + @as(i32, TITLE_BAR_H)) {
                // 检查交通灯按钮
                const btn_base_x = win.x + 12;
                const btn_cy = win.y + @as(i32, BTN_Y_OFFSET) + @as(i32, BTN_RADIUS);

                if (inCircle(mx, my, btn_base_x, btn_cy, BTN_RADIUS))
                    return .{ .id = wid, .hit = .close_btn };
                if (inCircle(mx, my, btn_base_x + @as(i32, BTN_SPACING), btn_cy, BTN_RADIUS))
                    return .{ .id = wid, .hit = .minimize_btn };
                if (inCircle(mx, my, btn_base_x + @as(i32, BTN_SPACING) * 2, btn_cy, BTN_RADIUS))
                    return .{ .id = wid, .hit = .maximize_btn };

                return .{ .id = wid, .hit = .title_bar };
            }
            return .{ .id = wid, .hit = .content };
        }
    }
    return null;
}

/// 更新窗口按钮悬停状态
pub fn updateButtonHover(mx: i32, my: i32) void {
    for (&windows) |*w| {
        if (!w.active or !w.visible) continue;

        if (mx >= w.x and mx < w.x + @as(i32, @intCast(w.width)) and
            my >= w.y and my < w.y + @as(i32, @intCast(w.height)) and
            my < w.y + @as(i32, TITLE_BAR_H))
        {
            const btn_base_x = w.x + 12;
            const btn_cy = w.y + @as(i32, BTN_Y_OFFSET) + @as(i32, BTN_RADIUS);

            w.hover.close = inCircle(mx, my, btn_base_x, btn_cy, BTN_RADIUS);
            w.hover.minimize = inCircle(mx, my, btn_base_x + @as(i32, BTN_SPACING), btn_cy, BTN_RADIUS);
            w.hover.maximize = inCircle(mx, my, btn_base_x + @as(i32, BTN_SPACING) * 2, btn_cy, BTN_RADIUS);
        } else {
            w.hover.close = false;
            w.hover.minimize = false;
            w.hover.maximize = false;
        }
    }
}

fn inCircle(px: i32, py: i32, cx: i32, cy: i32, r: u32) bool {
    const dx = px - cx;
    const dy = py - cy;
    const ir: i32 = @intCast(r);
    return dx * dx + dy * dy <= ir * ir;
}

// ── 拖拽 ─────────────────────────────────────────────

pub fn beginDrag(id: u16, mx: i32, my: i32) void {
    drag_win = id;
    if (id < window_count) {
        drag_offset_x = mx - windows[id].x;
        drag_offset_y = my - windows[id].y;
    }
}

pub fn updateDrag(mx: i32, my: i32) void {
    if (drag_win) |id| {
        if (id < window_count) {
            windows[id].x = mx - drag_offset_x;
            windows[id].y = my - drag_offset_y;
        }
    }
}

pub fn endDrag() void {
    drag_win = null;
}

pub fn isDragging() bool {
    return drag_win != null;
}

// ── 动画更新 ─────────────────────────────────────────

/// 更新窗口动画
pub fn updateAnimations() void {
    for (&windows) |*w| {
        if (!w.active) continue;

        // 透明度动画
        if (w.alpha < 255) {
            w.alpha = @min(255, w.alpha + 16);
        }

        // 缩放动画
        if (w.animating) {
            const diff = w.target_scale - w.scale;
            if (@abs(diff) < 0.01) {
                w.scale = w.target_scale;
                w.animating = false;
            } else {
                w.scale += diff * 0.15;
            }
        }
    }
}

// ── 渲染 ─────────────────────────────────────────────

pub fn renderAll() void {
    // 按z-order渲染（底部到顶部）
    for (z_order[0..z_count]) |wid| {
        if (wid < window_count and windows[wid].visible and windows[wid].active) {
            renderWindow(&windows[wid]);
        }
    }
}

/// 渲染单个窗口
fn renderWindow(win: *const Window) void {
    const x = win.x;
    const y = win.y;
    const w = win.width;
    const h = win.height;

    // 窗口阴影（根据焦点状态调整）
    const shadow_alpha: u8 = if (win.focused) 80 else 40;
    const shadow_offset: i32 = if (win.focused) 6 else 3;
    graphics.fillRectAlpha(x + shadow_offset, y + shadow_offset, w, h, theme.window_shadow, shadow_alpha);

    // 侧边阴影效果
    if (win.focused) {
        graphics.fillRectAlpha(x + shadow_offset, y + shadow_offset, 4, h, theme.window_shadow, 30);
        graphics.fillRectAlpha(x + shadow_offset, y + shadow_offset, w, 4, theme.window_shadow, 30);
    }

    // 窗口主体
    const body_color = color_mod.blend(theme.window_bg, theme.white, @as(u8, @intFromFloat(@as(f32, @floatFromInt(win.alpha)) * 0.3)));
    graphics.fillRoundedRect(x, y, w, h, 8, body_color);

    // 标题栏
    const tb_color = if (win.focused) theme.title_bar_active else theme.title_bar;
    graphics.fillRoundedRect(x, y, w, TITLE_BAR_H, 8, tb_color);
    graphics.fillRect(x, y + @as(i32, TITLE_BAR_H) - 8, w, 8, tb_color);

    // 分隔线
    graphics.drawHLine(x, y + @as(i32, TITLE_BAR_H) - 1, w, theme.window_border);

    // 交通灯按钮
    renderTrafficLights(win);

    // 标题文本（居中）
    const title_y = y + 6;
    graphics.drawStringCentered(x, title_y, w, win.title[0..win.title_len], theme.title_text);

    // 窗口边框
    graphics.drawRect(x, y, w, h, theme.window_border);

    // 内容区域
    renderContent(win);
}

/// 渲染交通灯按钮
fn renderTrafficLights(win: *const Window) void {
    const x = win.x;
    const y = win.y;
    const btn_x = x + 12;
    const btn_cy = y + @as(i32, BTN_Y_OFFSET) + @as(i32, BTN_RADIUS);

    if (win.focused) {
        // 关闭按钮
        if (win.hover.close) {
            graphics.fillCircle(btn_x, btn_cy, BTN_RADIUS + 1, theme.btn_close);
        } else {
            graphics.fillCircle(btn_x, btn_cy, BTN_RADIUS, theme.btn_close);
        }

        // 最小化按钮
        if (win.hover.minimize) {
            graphics.fillCircle(btn_x + @as(i32, BTN_SPACING), btn_cy, BTN_RADIUS + 1, theme.btn_minimize);
        } else {
            graphics.fillCircle(btn_x + @as(i32, BTN_SPACING), btn_cy, BTN_RADIUS, theme.btn_minimize);
        }

        // 最大化按钮
        if (win.hover.maximize) {
            graphics.fillCircle(btn_x + @as(i32, BTN_SPACING) * 2, btn_cy, BTN_RADIUS + 1, theme.btn_maximize);
        } else {
            graphics.fillCircle(btn_x + @as(i32, BTN_SPACING) * 2, btn_cy, BTN_RADIUS, theme.btn_maximize);
        }

        // 尝试渲染PNG按钮纹理（如果已加载）
        if (win.btn_close_tex != null) {
            graphics.fillCircle(btn_x, btn_cy, BTN_RADIUS, theme.btn_close);
        }
        if (win.btn_minimize_tex != null) {
            graphics.fillCircle(btn_x + @as(i32, BTN_SPACING), btn_cy, BTN_RADIUS, theme.btn_minimize);
        }
        if (win.btn_maximize_tex != null) {
            graphics.fillCircle(btn_x + @as(i32, BTN_SPACING) * 2, btn_cy, BTN_RADIUS, theme.btn_maximize);
        }
    } else {
        graphics.fillCircle(btn_x, btn_cy, BTN_RADIUS, theme.btn_inactive);
        graphics.fillCircle(btn_x + @as(i32, BTN_SPACING), btn_cy, BTN_RADIUS, theme.btn_inactive);
        graphics.fillCircle(btn_x + @as(i32, BTN_SPACING) * 2, btn_cy, BTN_RADIUS, theme.btn_inactive);
    }
}

/// 渲染窗口内容
fn renderContent(win: *const Window) void {
    const cx = win.x + 8;
    const cy = win.y + @as(i32, TITLE_BAR_H) + 8;

    switch (win.content_type) {
        .text_view, .terminal => {
            if (win.text_len > 0) {
                drawWrappedText(cx, cy, win.width - 16, win.text_buf[0..win.text_len], theme.text_primary);
            }
        },
        .about_dialog => {
            const center_x = win.x + @as(i32, @intCast(win.width / 2));
            _ = center_x;
            graphics.drawStringCentered(win.x, cy + 20, win.width, "ChimeraOS", theme.text_primary);
            graphics.drawStringCentered(win.x, cy + 44, win.width, "Version 0.2.0", theme.text_secondary);
            graphics.drawStringCentered(win.x, cy + 68, win.width, "A macOS-compatible OS in Zig", theme.text_secondary);
            graphics.drawStringCentered(win.x, cy + 100, win.width, "XNU-style hybrid kernel", theme.accent);
            graphics.drawStringCentered(win.x, cy + 124, win.width, "Mach IPC + BSD + IOKit", theme.text_secondary);
        },
        .file_manager => {
            graphics.drawString(cx, cy, "Desktop", theme.text_primary);
            graphics.drawString(cx, cy + 24, "Documents", theme.text_primary);
            graphics.drawString(cx, cy + 48, "Applications", theme.text_primary);
            graphics.drawString(cx, cy + 72, "Downloads", theme.text_primary);
        },
        .empty => {},
    }
}

/// 绘制自动换行文本
fn drawWrappedText(x: i32, y: i32, max_w: u32, text: []const u8, c: Color) void {
    var cx: i32 = x;
    var cy: i32 = y;
    const char_w: i32 = @intCast(font.GLYPH_W);
    const line_h: i32 = @intCast(font.GLYPH_H + 2);
    const limit = x + @as(i32, @intCast(max_w));

    for (text) |ch| {
        if (ch == '\n' or cx + char_w > limit) {
            cx = x;
            cy += line_h;
        }
        if (ch != '\n') {
            graphics.drawChar(cx, cy, ch, c);
            cx += char_w;
        }
    }
}

/// 窗口最小化动画
pub fn minimizeWindow(id: u16) void {
    if (id < window_count) {
        windows[id].animating = true;
        windows[id].target_scale = 0.1;
        windows[id].alpha = 255;
    }
}

/// 窗口恢复动画
pub fn restoreWindow(id: u16) void {
    if (id < window_count) {
        windows[id].animating = true;
        windows[id].target_scale = 1.0;
        windows[id].alpha = 0;
    }
}
