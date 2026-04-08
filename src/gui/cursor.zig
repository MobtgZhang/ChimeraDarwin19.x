/// 鼠标光标渲染系统 - 支持多种光标类型
/// 包含标准光标位图和从PNG加载的自定义光标
/// 设计用于全场景重绘：在每个渲染通道末尾调用draw()

const graphics = @import("graphics.zig");
const color_mod = @import("color.zig");
const log = @import("../lib/log.zig");
const resources = @import("resources/mod.zig");
const Color = color_mod.Color;

/// 光标类型枚举
pub const CursorType = enum(u8) {
    arrow = 0,       // 标准箭头
    crosshair = 1,   // 十字准星
    hand = 2,        // 手型（链接/悬停）
    text = 3,        // 文本选择（I形）
    wait = 4,        // 等待/沙漏
    resize_ns = 5,    // 上下调整
    resize_ew = 6,    // 左右调整
    resize_nwse = 7,  // 对角线调整（左上-右下）
    resize_nesw = 8,  // 对角线调整（右上-左下）
    disallowed = 9,  // 禁止（红圈斜杠）
    drag = 10,       // 拖拽
    help = 11,       // 帮助（问号箭头）
};

/// 光标热点信息
pub const CursorHotspot = struct {
    x: u16,
    y: u16,
};

/// 光标描述符
pub const CursorDescriptor = struct {
    cursor_type: CursorType,
    name: []const u8,
    width: u16,
    height: u16,
    hotspot_x: u16,
    hotspot_y: u16,
};

/// 所有标准光标的描述符
pub const cursor_descriptors = [_]CursorDescriptor{
    CursorDescriptor{ .cursor_type = .arrow,     .name = "arrow",      .width = 12, .height = 18, .hotspot_x = 0, .hotspot_y = 0 },
    CursorDescriptor{ .cursor_type = .crosshair, .name = "crosshair",  .width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9 },
    CursorDescriptor{ .cursor_type = .hand,      .name = "hand",       .width = 16, .height = 20, .hotspot_x = 4, .hotspot_y = 0 },
    CursorDescriptor{ .cursor_type = .text,       .name = "text",       .width = 6,  .height = 18, .hotspot_x = 3, .hotspot_y = 0 },
    CursorDescriptor{ .cursor_type = .wait,       .name = "wait",       .width = 16, .height = 16, .hotspot_x = 8, .hotspot_y = 8 },
    CursorDescriptor{ .cursor_type = .resize_ns,  .name = "resize_ns",  .width = 12, .height = 18, .hotspot_x = 6, .hotspot_y = 9 },
    CursorDescriptor{ .cursor_type = .resize_ew,  .name = "resize_ew",  .width = 18, .height = 12, .hotspot_x = 9, .hotspot_y = 6 },
    CursorDescriptor{ .cursor_type = .resize_nwse,.name = "resize_nwse",.width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9 },
    CursorDescriptor{ .cursor_type = .resize_nesw,.name = "resize_nesw",.width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9 },
    CursorDescriptor{ .cursor_type = .disallowed,  .name = "disallowed", .width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9 },
    CursorDescriptor{ .cursor_type = .drag,        .name = "drag",       .width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9 },
    CursorDescriptor{ .cursor_type = .help,        .name = "help",       .width = 16, .height = 20, .hotspot_x = 12, .hotspot_y = 0 },
};

/// 标准箭头光标位图（12x18）
/// 0 = 透明, 1 = 白色填充, 2 = 黑色边框
const ARROW_BITMAP = [18][12]u8{
    .{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0 },
    .{ 2, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0 },
    .{ 2, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0 },
    .{ 2, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0 },
    .{ 2, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0 },
    .{ 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 0 },
    .{ 2, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 0 },
    .{ 2, 1, 1, 1, 2, 1, 1, 2, 0, 0, 0, 0 },
    .{ 2, 1, 1, 2, 0, 2, 1, 1, 2, 0, 0, 0 },
    .{ 2, 1, 2, 0, 0, 2, 1, 1, 2, 0, 0, 0 },
    .{ 2, 2, 0, 0, 0, 0, 2, 1, 1, 2, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 2, 1, 1, 2, 0, 0 },
    .{ 0, 0, 0, 0, 0, 0, 0, 2, 2, 0, 0, 0 },
};

/// 文本光标位图（6x18，I形）
const TEXT_CURSOR_BITMAP = [18][6]u8{
    .{ 2, 2, 2, 2, 2, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 1, 1, 1, 1, 2 },
    .{ 2, 2, 2, 2, 2, 2 },
};

/// 全局光标状态
var current_cursor_type: CursorType = .arrow;
var previous_cursor_type: CursorType = .arrow;
var cursor_x: i32 = 0;
var cursor_y: i32 = 0;
var cursor_visible: bool = true;

/// 已加载的光标纹理缓存
var loaded_cursors: [12]?resources.texture_cache.Texture = [_]?resources.texture_cache.Texture{null} ** 12;

/// 初始化光标系统
pub fn init() void {
    current_cursor_type = .arrow;
    previous_cursor_type = .arrow;
    cursor_x = 0;
    cursor_y = 0;
    cursor_visible = true;

    // 预加载所有标准光标
    preloadCursors();

    log.info("[CURSOR] Cursor system initialized with {} types", .{cursor_descriptors.len});
}

/// 预加载所有标准光标（从PNG或使用内置位图）
fn preloadCursors() void {
    inline for (cursor_descriptors, 0..) |desc, i| {
        // 尝试从PNG加载
        if (resources.texture_cache.loadCursorTexture(desc.name)) |tex| {
            loaded_cursors[i] = tex;
            log.debug("[CURSOR] Loaded cursor '{s}' from PNG ({}x{})", .{
                desc.name, tex.width, tex.height
            });
        } else {
            // 使用内置位图
            log.debug("[CURSOR] Using built-in cursor '{s}'", .{desc.name});
        }
    }
}

/// 设置当前光标类型
pub fn setCursorType(cursor_type: CursorType) void {
    if (current_cursor_type != cursor_type) {
        previous_cursor_type = current_cursor_type;
        current_cursor_type = cursor_type;
    }
}

/// 获取当前光标类型
pub fn getCursorType() CursorType {
    return current_cursor_type;
}

/// 获取之前的光标类型（用于恢复）
pub fn getPreviousCursorType() CursorType {
    return previous_cursor_type;
}

/// 恢复之前的光标类型
pub fn restorePreviousCursor() void {
    const temp = current_cursor_type;
    current_cursor_type = previous_cursor_type;
    previous_cursor_type = temp;
}

/// 根据上下文设置光标类型
pub fn setCursorForContext(context: CursorContext) void {
    switch (context) {
        .default => setCursorType(.arrow),
        .pointer => setCursorType(.hand),
        .text_input => setCursorType(.text),
        .busy => setCursorType(.wait),
        .crosshair => setCursorType(.crosshair),
        .resize_north_south => setCursorType(.resize_ns),
        .resize_east_west => setCursorType(.resize_ew),
        .resize_nwse => setCursorType(.resize_nwse),
        .resize_nesw => setCursorType(.resize_nesw),
        .not_allowed => setCursorType(.disallowed),
        .help => setCursorType(.help),
    }
}

/// 光标上下文类型
pub const CursorContext = enum(u8) {
    default = 0,
    pointer,        // 可点击元素
    text_input,    // 文本输入区域
    busy,          // 忙碌状态
    crosshair,     // 十字准星
    resize_north_south,
    resize_east_west,
    resize_nwse,
    resize_nesw,
    not_allowed,
    help,
};

/// 隐藏光标
pub fn hide() void {
    cursor_visible = false;
}

/// 显示光标
pub fn show() void {
    cursor_visible = true;
}

/// 设置光标位置
pub fn setPosition(x: i32, y: i32) void {
    cursor_x = x;
    cursor_y = y;
}

/// 获取光标位置
pub fn getPosition() struct { x: i32, y: i32 } {
    return .{ .x = cursor_x, .y = cursor_y };
}

/// 检查光标是否可见
pub fn isVisible() bool {
    return cursor_visible;
}

/// 获取当前光标的热点
pub fn getHotspot() CursorHotspot {
    for (cursor_descriptors) |desc| {
        if (desc.cursor_type == current_cursor_type) {
            return .{ .x = desc.hotspot_x, .y = desc.hotspot_y };
        }
    }
    return .{ .x = 0, .y = 0 };
}

/// 获取光标描述符
pub fn getDescriptor(cursor_type: CursorType) ?*const CursorDescriptor {
    for (&cursor_descriptors) |*desc| {
        if (desc.cursor_type == cursor_type) {
            return desc;
        }
    }
    return null;
}

/// 主绘制函数 - 在屏幕当前位置绘制当前光标
pub fn draw(x: i32, y: i32) void {
    if (!cursor_visible) return;

    cursor_x = x;
    cursor_y = y;

    const idx = @intFromEnum(current_cursor_type);

    // 如果有加载的PNG纹理，使用它
    if (idx < loaded_cursors.len and loaded_cursors[idx] != null) {
        drawFromTexture(x, y, &loaded_cursors[idx].?);
        return;
    }

    // 否则使用内置位图
    switch (current_cursor_type) {
        .arrow => drawArrow(x, y),
        .text => drawTextCursor(x, y),
        else => drawArrow(x, y), // 默认使用箭头
    }
}

/// 从PNG纹理绘制光标
fn drawFromTexture(x: i32, y: i32, tex: *const resources.texture_cache.Texture) void {
    // 获取热点偏移
    const hotspot = getHotspot();
    const draw_x = x - @as(i32, @intCast(hotspot.x));
    const draw_y = y - @as(i32, @intCast(hotspot.y));

    resources.texture_cache.blitTexture(draw_x, draw_y, tex, null, null);
}

/// 绘制标准箭头光标
fn drawArrow(x: i32, y: i32) void {
    var row: u32 = 0;
    while (row < 18) : (row += 1) {
        var col: u32 = 0;
        while (col < 12) : (col += 1) {
            const pixel = ARROW_BITMAP[row][col];
            if (pixel != 0) {
                const c: Color = if (pixel == 1) color_mod.theme.white else color_mod.theme.black;
                graphics.putPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), c);
            }
        }
    }
}

/// 绘制文本光标
fn drawTextCursor(x: i32, y: i32) void {
    var row: u32 = 0;
    while (row < 18) : (row += 1) {
        var col: u32 = 0;
        while (col < 6) : (col += 1) {
            const pixel = TEXT_CURSOR_BITMAP[row][col];
            if (pixel != 0) {
                const c: Color = if (pixel == 1) color_mod.theme.white else color_mod.theme.black;
                graphics.putPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), c);
            }
        }
    }
}

/// 绘制手型光标（用于链接悬停）
pub fn drawHand(x: i32, y: i32) void {
    // 简单的8x12手型光标
    const hand_bitmap = [12][8]u8{
        .{ 0, 0, 2, 2, 0, 0, 0, 0 },
        .{ 0, 2, 1, 2, 2, 0, 0, 0 },
        .{ 0, 2, 1, 1, 2, 0, 0, 0 },
        .{ 0, 2, 1, 1, 2, 2, 0, 0 },
        .{ 0, 0, 2, 1, 1, 2, 0, 0 },
        .{ 0, 0, 0, 2, 1, 1, 2, 0 },
        .{ 0, 0, 2, 1, 1, 1, 2, 0 },
        .{ 0, 0, 2, 1, 1, 1, 2, 0 },
        .{ 0, 0, 2, 1, 1, 1, 2, 0 },
        .{ 0, 0, 2, 1, 1, 2, 0, 0 },
        .{ 0, 0, 2, 1, 2, 0, 0, 0 },
        .{ 0, 0, 2, 2, 0, 0, 0, 0 },
    };

    var row: u32 = 0;
    while (row < 12) : (row += 1) {
        var col: u32 = 0;
        while (col < 8) : (col += 1) {
            const pixel = hand_bitmap[row][col];
            if (pixel != 0) {
                const c: Color = if (pixel == 1) color_mod.theme.white else color_mod.theme.black;
                graphics.putPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), c);
            }
        }
    }
}

/// 绘制等待光标（沙漏形状）
pub fn drawWait(x: i32, y: i32) void {
    // 简单的16x16沙漏形状
    var row: u32 = 0;
    while (row < 16) : (row += 1) {
        var col: u32 = 0;
        while (col < 16) : (col += 1) {
            const dx: i32 = @as(i32, @intCast(col)) - 8;
            _ = dx;

            // 绘制沙漏的斜线效果
            if (row == 0 or row == 15) {
                if (col >= 4 and col <= 11) {
                    graphics.putPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), color_mod.theme.black);
                }
            } else if (row < 8) {
                if (@abs(@as(i32, @intCast(col)) - 8) <= @as(i32, @intCast(8 - row))) {
                    graphics.putPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), color_mod.theme.black);
                }
            } else {
                if (@abs(@as(i32, @intCast(col)) - 8) <= @as(i32, @intCast(row - 8))) {
                    graphics.putPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), color_mod.theme.black);
                }
            }
        }
    }
}

/// 绘制禁止光标
pub fn drawDisallowed(x: i32, y: i32) void {
    const cx = x + 9;
    const cy = y + 9;
    const radius: u32 = 8;

    var row: i32 = -@as(i32, @intCast(radius));
    while (row <= @as(i32, @intCast(radius))) : (row += 1) {
        var col: i32 = -@as(i32, @intCast(radius));
        while (col <= @as(i32, @intCast(radius))) : (col += 1) {
            const dist = col * col + row * row;
            const r: i32 = @intCast(radius);
            if (dist <= r * r) {
                // 红色圆圈
                graphics.putPixel(cx + col, cy + row, color_mod.rgb(255, 80, 80));

                // 绘制对角线
                if (@abs(row - col) <= 2) {
                    graphics.putPixel(cx + col, cy + row, color_mod.theme.white);
                }
            }
        }
    }
}

/// 清理光标系统资源
pub fn deinit() void {
    for (&loaded_cursors) |*tex| {
        if (tex.*) |*t| {
            t.deinit();
            tex.* = null;
        }
    }
    cursor_visible = false;
    log.info("[CURSOR] Cursor system deinitialized", .{});
}
