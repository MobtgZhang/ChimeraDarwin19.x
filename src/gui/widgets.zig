/// Basic UI widgets — buttons, labels, and text input.

const graphics = @import("graphics.zig");
const color_mod = @import("color.zig");
const font_mod = @import("font.zig");
const Color = color_mod.Color;
const theme = color_mod.theme;

pub const WidgetType = enum {
    label,
    button,
    text_input,
    separator,
};

pub const Widget = struct {
    kind: WidgetType,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    text: [128]u8,
    text_len: usize,
    bg_color: Color,
    fg_color: Color,
    hovered: bool,
    pressed: bool,
    focused: bool,
    active: bool,
};

pub const MAX_WIDGETS: usize = 64;
var widgets: [MAX_WIDGETS]Widget = undefined;
var widget_count: usize = 0;

pub fn init() void {
    widget_count = 0;
    for (&widgets) |*w| w.active = false;
}

pub fn createLabel(x: i32, y: i32, text: []const u8, fg: Color) ?*Widget {
    return createWidget(.{
        .kind = .label,
        .x = x,
        .y = y,
        .width = @intCast(text.len * font_mod.GLYPH_W),
        .height = font_mod.GLYPH_H,
        .text = undefined,
        .text_len = @min(text.len, 128),
        .bg_color = 0,
        .fg_color = fg,
        .hovered = false,
        .pressed = false,
        .focused = false,
        .active = true,
    }, text);
}

pub fn createButton(x: i32, y: i32, w: u32, h: u32, text: []const u8) ?*Widget {
    return createWidget(.{
        .kind = .button,
        .x = x,
        .y = y,
        .width = w,
        .height = h,
        .text = undefined,
        .text_len = @min(text.len, 128),
        .bg_color = theme.accent,
        .fg_color = theme.text_light,
        .hovered = false,
        .pressed = false,
        .focused = false,
        .active = true,
    }, text);
}

pub fn createTextInput(x: i32, y: i32, w: u32) ?*Widget {
    return createWidget(.{
        .kind = .text_input,
        .x = x,
        .y = y,
        .width = w,
        .height = font_mod.GLYPH_H + 8,
        .text = undefined,
        .text_len = 0,
        .bg_color = theme.white,
        .fg_color = theme.text_primary,
        .hovered = false,
        .pressed = false,
        .focused = false,
        .active = true,
    }, "");
}

fn createWidget(template: Widget, text: []const u8) ?*Widget {
    if (widget_count >= MAX_WIDGETS) return null;
    var w = &widgets[widget_count];
    w.* = template;
    const len = @min(text.len, 128);
    @memcpy(w.text[0..len], text[0..len]);
    w.text_len = len;
    widget_count += 1;
    return w;
}

// ── Rendering ────────────────────────────────────────────

pub fn renderWidget(w: *const Widget) void {
    switch (w.kind) {
        .label => renderLabel(w),
        .button => renderButton(w),
        .text_input => renderTextInput(w),
        .separator => {
            graphics.drawHLine(w.x, w.y, w.width, theme.window_border);
        },
    }
}

fn renderLabel(w: *const Widget) void {
    graphics.drawString(w.x, w.y, w.text[0..w.text_len], w.fg_color);
}

fn renderButton(w: *const Widget) void {
    const bg = if (w.pressed) theme.accent_hover else if (w.hovered) color_mod.blend(theme.accent, theme.white, 200) else w.bg_color;
    graphics.fillRoundedRect(w.x, w.y, w.width, w.height, 6, bg);
    const text_y = w.y + @as(i32, @intCast((w.height - font_mod.GLYPH_H) / 2));
    graphics.drawStringCentered(w.x, text_y, w.width, w.text[0..w.text_len], w.fg_color);
}

fn renderTextInput(w: *const Widget) void {
    const border = if (w.focused) theme.accent else theme.window_border;
    graphics.fillRoundedRect(w.x, w.y, w.width, w.height, 4, w.bg_color);
    graphics.drawRect(w.x, w.y, w.width, w.height, border);

    if (w.text_len > 0) {
        graphics.drawString(w.x + 4, w.y + 4, w.text[0..w.text_len], w.fg_color);
    }

    // Blinking cursor (simplified — always shown when focused)
    if (w.focused) {
        const cursor_x = w.x + 4 + @as(i32, @intCast(w.text_len * font_mod.GLYPH_W));
        graphics.drawVLine(cursor_x, w.y + 4, font_mod.GLYPH_H, theme.text_primary);
    }
}

pub fn pointInWidget(w: *const Widget, px: i32, py: i32) bool {
    return px >= w.x and px < w.x + @as(i32, @intCast(w.width)) and
        py >= w.y and py < w.y + @as(i32, @intCast(w.height));
}
