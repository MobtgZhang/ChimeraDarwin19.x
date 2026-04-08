/// macOS风格Dock - 底部应用图标栏
/// 支持PNG图标加载、放大效果、弹跳动画和运行指示器

const std = @import("std");
const graphics = @import("graphics.zig");
const color_mod = @import("color.zig");
const icons = @import("icons.zig");
const font_mod = @import("font.zig");
const resources = @import("resources/mod.zig");
const icons_loader = resources.texture_cache;
const icons_registry = @import("icons_registry.zig");
const Color = color_mod.Color;
const theme = color_mod.theme;

pub const DOCK_H: u32 = 70;
const DOCK_PADDING: u32 = 10;
const ICON_SLOT_SIZE: u32 = 48;
const ICON_RENDER_SIZE: u32 = 40;
const DOCK_RADIUS: u32 = 14;
const MAX_DOCK_ITEMS = 16;

/// 放大效果参数
const MAG_MIN_SCALE: f32 = 1.0;
const MAG_MAX_SCALE: f32 = 1.4;
const MAG_DISTANCE: u32 = 60;

/// Dock项目
pub const DockItem = struct {
    icon_name: []const u8,
    label: [32]u8,
    label_len: usize,
    primary_color: Color,
    secondary_color: Color,
    accent_color: Color,
    highlight_color: Color,
    running: bool,
    active: bool,

    // 纹理
    texture: ?icons_loader.Texture,
    texture_loaded: bool,

    // 动画
    bounce_offset: i32,
    bounce_velocity: f32,
    bounce_target: i32,

    // 放大效果
    magnification: f32,
    target_magnification: f32,
};

var items: [MAX_DOCK_ITEMS]DockItem = undefined;
var item_count: usize = 0;
var hovered_idx: ?usize = null;

/// Dock初始化
pub fn init() void {
    item_count = 0;

    addItem("finder",     "Finder",           color_mod.rgb(60, 120, 220), color_mod.rgb(30, 80, 180), color_mod.rgb(100, 160, 255), theme.white);
    addItem("terminal",  "Terminal",         color_mod.rgb(40, 40, 40),    color_mod.rgb(20, 20, 20),    color_mod.rgb(0, 200, 80),  theme.white);
    addItem("settings",  "Settings",         color_mod.rgb(120, 120, 120), color_mod.rgb(80, 80, 80),   color_mod.rgb(0, 122, 255), theme.white);
    addItem("editor",    "TextEdit",         color_mod.rgb(80, 80, 80),    color_mod.rgb(50, 50, 50),   color_mod.rgb(200, 200, 200), theme.white);
    addItem("browser",   "Safari",           color_mod.rgb(0, 100, 200),   color_mod.rgb(0, 60, 140),   color_mod.rgb(0, 122, 255), theme.white);
    addItem("calendar",  "Calendar",         color_mod.rgb(180, 80, 80),   color_mod.rgb(140, 40, 40),  color_mod.rgb(255, 100, 100), theme.white);
    addItem("calculator","Calculator",       color_mod.rgb(100, 100, 100), color_mod.rgb(60, 60, 60),  color_mod.rgb(255, 180, 0),   theme.white);
    addItem("mail",      "Mail",             color_mod.rgb(0, 120, 200),   color_mod.rgb(0, 80, 160),   color_mod.rgb(0, 180, 255), theme.white);
}

/// 添加Dock项目
fn addItem(icon_name: []const u8, label: []const u8, primary: Color, secondary: Color, accent: Color, highlight: Color) void {
    if (item_count >= MAX_DOCK_ITEMS) return;

    var item = &items[item_count];
    item.icon_name = icon_name;
    item.label_len = @min(label.len, 32);
    @memcpy(item.label[0..item.label_len], label[0..item.label_len]);
    item.primary_color = primary;
    item.secondary_color = secondary;
    item.accent_color = accent;
    item.highlight_color = highlight;
    item.running = false;
    item.active = true;
    item.texture = null;
    item.texture_loaded = false;
    item.bounce_offset = 0;
    item.bounce_velocity = 0;
    item.bounce_target = 0;
    item.magnification = MAG_MIN_SCALE;
    item.target_magnification = MAG_MIN_SCALE;

    // 尝试加载PNG图标
    item.texture = icons_loader.loadDockIcon(icon_name, 48);
    if (item.texture) |_| {
        item.texture_loaded = true;
    }

    item_count += 1;
}

/// 渲染Dock
pub fn render() void {
    if (item_count == 0) return;

    const sw = graphics.screenWidth();
    const sh = graphics.screenHeight();

    const dock_w: u32 = @intCast(item_count * ICON_SLOT_SIZE + DOCK_PADDING * 2);
    const dock_x: i32 = @intCast((sw - dock_w) / 2);
    const dock_y: i32 = @intCast(sh - DOCK_H - 6);

    // Dock背景（半透明圆角矩形）
    graphics.fillRoundedRect(dock_x, dock_y, dock_w, DOCK_H, DOCK_RADIUS, color_mod.blend(theme.dock_bg, theme.white, 180));
    graphics.drawRect(dock_x, dock_y, dock_w, DOCK_H, theme.dock_border);

    // 计算鼠标位置用于放大效果
    const mouse_pos = getMouseForMagnification();

    // 渲染图标
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const item = &items[i];
        if (!item.active) continue;

        // 计算图标位置
        const base_ix: i32 = dock_x + @as(i32, @intCast(DOCK_PADDING + i * ICON_SLOT_SIZE + (ICON_SLOT_SIZE - ICON_RENDER_SIZE) / 2));
        const base_iy: i32 = dock_y + @as(i32, @intCast((DOCK_H - ICON_RENDER_SIZE) / 2));

        // 计算放大效果
        const icon_center_x = base_ix + @as(i32, @intCast(ICON_RENDER_SIZE / 2));
        const dist = @abs(icon_center_x - mouse_pos.x);
        const mag_factor = if (dist < MAG_DISTANCE) @as(f32, @floatFromInt(MAG_DISTANCE - dist)) / @as(f32, @floatFromInt(MAG_DISTANCE)) else 0.0;
        item.target_magnification = MAG_MIN_SCALE + (MAG_MAX_SCALE - MAG_MIN_SCALE) * mag_factor;

        // 悬停效果
        if (hovered_idx != null and hovered_idx.? == i) {
            graphics.fillRoundedRect(
                dock_x + @as(i32, @intCast(DOCK_PADDING + i * ICON_SLOT_SIZE)),
                dock_y + 6,
                ICON_SLOT_SIZE,
                DOCK_H - 12,
                8,
                color_mod.blend(theme.accent, theme.white, 40),
            );
        }

        // 计算放大后的图标尺寸和位置
        const mag = item.magnification;
        const scaled_size = @as(u32, @intFromFloat(@as(f32, @floatFromInt(ICON_RENDER_SIZE)) * mag));
        const offset = @divTrunc(@as(i32, @intCast(ICON_RENDER_SIZE)) - @as(i32, @intCast(scaled_size)), 2);

        // 弹跳动画偏移
        const bounce_y = item.bounce_offset;

        const draw_x = base_ix + offset;
        const draw_y = base_iy + offset + bounce_y;
        drawDockIcon(draw_x, draw_y, scaled_size, item);

        // 运行指示器
        if (item.running) {
            const dot_x = base_ix + @as(i32, @intCast(ICON_RENDER_SIZE / 2));
            const dot_y = dock_y + @as(i32, @intCast(DOCK_H - 10)) + bounce_y;
            graphics.fillCircle(dot_x, dot_y, 2, theme.text_primary);
        }
    }
}

/// 获取鼠标位置（用于放大效果计算）
var mouse_x: i32 = 0;
var mouse_y: i32 = 0;

fn getMouseForMagnification() struct { x: i32 } {
    return .{ .x = mouse_x };
}

/// 更新鼠标位置
pub fn updateMousePosition(x: i32, y: i32) void {
    mouse_x = x;
    mouse_y = y;
}

/// 绘制Dock图标
fn drawDockIcon(x: i32, y: i32, size: u32, item: *const DockItem) void {
    // 图标背景（圆角矩形）
    graphics.fillRoundedRect(x - 4, y - 4, size + 8, size + 8, 8, item.secondary_color);

    // 尝试使用PNG纹理
    if (item.texture_loaded and item.texture != null) {
        icons_loader.blitTexture(x, y, &item.texture.?, size, size);
    } else {
        // 回退：使用内置调色板图标
        const legacy_id = getLegacyIconId(item.icon_name);
        if (legacy_id) |id| {
            const data = icons.getIcon(id);
            var row: u32 = 0;
            while (row < icons.ICON_SIZE) : (row += 1) {
                var col: u32 = 0;
                while (col < icons.ICON_SIZE) : (col += 1) {
                    const idx = data[row * icons.ICON_SIZE + col];
                    if (idx != 0) {
                        const c = icons.paletteColor(idx, item.primary_color, item.secondary_color, item.accent_color, item.highlight_color);
                        const scale_x: i32 = @intCast((@as(u32, col) * size) / icons.ICON_SIZE);
                        const scale_y: i32 = @intCast((@as(u32, row) * size) / icons.ICON_SIZE);
                        graphics.putPixel(x + scale_x, y + scale_y, c);
                    }
                }
            }
        }
    }
}

fn getLegacyIconId(name: []const u8) ?icons.IconId {
    if (std.mem.eql(u8, name, "finder")) return .finder;
    if (std.mem.eql(u8, name, "terminal")) return .terminal;
    if (std.mem.eql(u8, name, "settings")) return .settings;
    if (std.mem.eql(u8, name, "editor")) return .file_text;
    return null;
}

// ── 命中测试 ──────────────────────────────────────────

/// 命中测试
pub fn hitTest(mx: i32, my: i32) ?usize {
    const sw = graphics.screenWidth();
    const sh = graphics.screenHeight();

    const dock_w: u32 = @intCast(item_count * ICON_SLOT_SIZE + DOCK_PADDING * 2);
    const dock_x: i32 = @intCast((sw - dock_w) / 2);
    const dock_y: i32 = @intCast(sh - DOCK_H - 6);

    if (my < dock_y or my >= dock_y + @as(i32, DOCK_H)) return null;
    if (mx < dock_x or mx >= dock_x + @as(i32, @intCast(dock_w))) return null;

    const rel_x = mx - dock_x - @as(i32, @intCast(DOCK_PADDING));
    if (rel_x < 0) return null;
    const idx: usize = @intCast(@divTrunc(rel_x, @as(i32, @intCast(ICON_SLOT_SIZE))));
    if (idx < item_count) return idx;
    return null;
}

/// 更新悬停状态
pub fn updateHover(mx: i32, my: i32) void {
    hovered_idx = hitTest(mx, my);
}

/// 设置运行状态
pub fn setRunning(idx: usize, running: bool) void {
    if (idx < item_count) {
        // 如果变为运行状态，触发动画
        if (running and !items[idx].running) {
            items[idx].bounce_velocity = -8.0;
        }
        items[idx].running = running;
    }
}

/// 获取项目标签
pub fn getItemLabel(idx: usize) ?[]const u8 {
    if (idx >= item_count) return null;
    return items[idx].label[0..items[idx].label_len];
}

/// 获取项目数量
pub fn getItemCount() usize {
    return item_count;
}

/// 检查是否在Dock区域
pub fn isInDock(my: i32) bool {
    const sh = graphics.screenHeight();
    const dock_y: i32 = @intCast(sh - DOCK_H - 6);
    return my >= dock_y;
}

/// 更新Dock动画
pub fn updateAnimations() void {
    for (&items) |*item| {
        if (!item.active) continue;

        // 放大效果动画
        const diff = item.target_magnification - item.magnification;
        if (@abs(diff) < 0.01) {
            item.magnification = item.target_magnification;
        } else {
            item.magnification += diff * 0.2;
        }

        // 弹跳动画
        if (item.bounce_offset != item.bounce_target or item.bounce_velocity != 0) {
            // 弹跳物理
            const spring = -0.15 * @as(f32, @floatFromInt(item.bounce_offset));
            const damping = 0.7;

            item.bounce_velocity += spring;
            item.bounce_velocity *= damping;
            item.bounce_offset += @as(i32, @intFromFloat(item.bounce_velocity));

            if (@abs(item.bounce_offset) < 1 and @abs(item.bounce_velocity) < 0.5) {
                item.bounce_offset = 0;
                item.bounce_velocity = 0;
            }
        }
    }
}

/// 触发图标弹跳动画
pub fn bounceItem(idx: usize) void {
    if (idx < item_count) {
        items[idx].bounce_velocity = -10.0;
    }
}
