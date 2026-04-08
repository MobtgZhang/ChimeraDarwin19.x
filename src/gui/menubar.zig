/// macOS风格菜单栏 - 始终显示在屏幕顶部
/// 包含：Apple图标 | 应用名称 | 菜单项... | 状态图标 | 时钟
/// 支持下拉菜单系统和交互

const std = @import("std");
const graphics = @import("graphics.zig");
const color_mod = @import("color.zig");
const font_mod = @import("font.zig");
const icons = @import("icons.zig");
const status_icons = @import("status_icons.zig");
const resources = @import("resources/mod.zig");
const icons_registry = @import("icons_registry.zig");
const Color = color_mod.Color;
const theme = color_mod.theme;

pub const MENUBAR_H: u32 = 24;

/// 菜单项类型
pub const MenuItemType = enum(u8) {
    normal = 0,
    separator = 1,
    disabled = 2,
};

/// 菜单项
pub const MenuEntry = struct {
    label: [32]u8,
    label_len: usize,
    item_type: MenuItemType,
    shortcut: [8]u8,
    shortcut_len: usize,
    enabled: bool,
};

/// 菜单
pub const Menu = struct {
    label: [16]u8,
    label_len: usize,
    entries: [16]MenuEntry,
    entry_count: usize,
    x: i32,
    y: i32,
    width: u32,
    height: u32,
    visible: bool,
    parent: ?*Menu,
};

pub const MAX_MENUS = 8;
const MAX_LABEL_LEN = 32;

/// 菜单栏项
pub const MenuBarItem = struct {
    label: [MAX_LABEL_LEN]u8,
    label_len: usize,
    x: i32,
    width: u32,
    active: bool,
    menu: ?*Menu,
};

var menu_bar_items: [MAX_MENUS]MenuBarItem = undefined;
var menu_count: usize = 0;

var clock_text: [8]u8 = "00:00   ".*;
var clock_len: usize = 5;
var active_app: [MAX_LABEL_LEN]u8 = "Finder                          ".*;
var active_app_len: usize = 6;

// Logo纹理
var logo_texture: ?resources.texture_cache.Texture = null;
var logo_loaded: bool = false;

// 下拉菜单状态
var active_menu: ?*Menu = null;
var menu_open: bool = false;

/// 定义预定义菜单
var file_menu: Menu = undefined;
var edit_menu: Menu = undefined;
var view_menu: Menu = undefined;
var window_menu: Menu = undefined;
var help_menu: Menu = undefined;

/// 菜单栏初始化
pub fn init() void {
    menu_count = 0;

    // 初始化菜单
    initFileMenu();
    initEditMenu();
    initViewMenu();
    initWindowMenu();
    initHelpMenu();

    // 添加菜单栏项
    addMenuBarItem("File", &file_menu);
    addMenuBarItem("Edit", &edit_menu);
    addMenuBarItem("View", &view_menu);
    addMenuBarItem("Window", &window_menu);
    addMenuBarItem("Help", &help_menu);

    // 初始化状态图标系统
    status_icons.init();

    // 加载Logo
    loadLogoTexture();

    layoutMenus();
}

fn loadLogoTexture() void {
    if (!logo_loaded) {
        logo_loaded = true;
        logo_texture = resources.texture_cache.loadMenuIcon("logo");
    }
}

fn initFileMenu() void {
    file_menu = Menu{
        .label = undefined,
        .label_len = 0,
        .entries = undefined,
        .entry_count = 0,
        .x = 0,
        .y = 0,
        .width = 180,
        .height = 0,
        .visible = false,
        .parent = null,
    };
    @memcpy(file_menu.label[0..4], "File");
    file_menu.label_len = 4;

    addMenuEntry(&file_menu, "New Window", "N", .normal);
    addMenuEntry(&file_menu, "Open...", "O", .normal);
    addMenuEntry(&file_menu, "", "", .separator);
    addMenuEntry(&file_menu, "Close", "W", .normal);
    addMenuEntry(&file_menu, "", "", .separator);
    addMenuEntry(&file_menu, "About This Mac", "", .normal);
}

fn initEditMenu() void {
    edit_menu = Menu{
        .label = undefined,
        .label_len = 0,
        .entries = undefined,
        .entry_count = 0,
        .x = 0,
        .y = 0,
        .width = 180,
        .height = 0,
        .visible = false,
        .parent = null,
    };
    @memcpy(edit_menu.label[0..4], "Edit");
    edit_menu.label_len = 4;

    addMenuEntry(&edit_menu, "Undo", "Z", .normal);
    addMenuEntry(&edit_menu, "Redo", "⇧Z", .normal);
    addMenuEntry(&edit_menu, "", "", .separator);
    addMenuEntry(&edit_menu, "Cut", "X", .normal);
    addMenuEntry(&edit_menu, "Copy", "C", .normal);
    addMenuEntry(&edit_menu, "Paste", "V", .normal);
    addMenuEntry(&edit_menu, "Select All", "A", .normal);
}

fn initViewMenu() void {
    view_menu = Menu{
        .label = undefined,
        .label_len = 0,
        .entries = undefined,
        .entry_count = 0,
        .x = 0,
        .y = 0,
        .width = 180,
        .height = 0,
        .visible = false,
        .parent = null,
    };
    @memcpy(view_menu.label[0..4], "View");
    view_menu.label_len = 4;

    addMenuEntry(&view_menu, "as Icons", "", .normal);
    addMenuEntry(&view_menu, "as List", "", .normal);
    addMenuEntry(&view_menu, "as Columns", "", .normal);
    addMenuEntry(&view_menu, "", "", .separator);
    addMenuEntry(&view_menu, "as Icons", "", .normal);
}

fn initWindowMenu() void {
    window_menu = Menu{
        .label = undefined,
        .label_len = 0,
        .entries = undefined,
        .entry_count = 0,
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 0,
        .visible = false,
        .parent = null,
    };
    @memcpy(window_menu.label[0..6], "Window");
    window_menu.label_len = 6;

    addMenuEntry(&window_menu, "Minimize", "M", .normal);
    addMenuEntry(&window_menu, "Zoom", "", .normal);
    addMenuEntry(&window_menu, "", "", .separator);
    addMenuEntry(&window_menu, "Bring All to Front", "", .normal);
}

fn initHelpMenu() void {
    help_menu = Menu{
        .label = undefined,
        .label_len = 0,
        .entries = undefined,
        .entry_count = 0,
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 0,
        .visible = false,
        .parent = null,
    };
    @memcpy(help_menu.label[0..4], "Help");
    help_menu.label_len = 4;

    addMenuEntry(&help_menu, "ChimeraOS Help", "", .normal);
    addMenuEntry(&help_menu, "About", "", .normal);
}

fn addMenuEntry(menu: *Menu, label: []const u8, shortcut: []const u8, item_type: MenuItemType) void {
    if (menu.entry_count >= 16) return;

    var entry = &menu.entries[menu.entry_count];
    entry.label_len = @min(label.len, 31);
    @memcpy(entry.label[0..entry.label_len], label[0..entry.label_len]);
    entry.item_type = item_type;
    entry.enabled = item_type != .disabled;

    entry.shortcut_len = @min(shortcut.len, 7);
    @memcpy(entry.shortcut[0..entry.shortcut_len], shortcut[0..entry.shortcut_len]);

    menu.entry_count += 1;
}

fn addMenuBarItem(label: []const u8, menu: *Menu) void {
    if (menu_count >= MAX_MENUS) return;
    var item = &menu_bar_items[menu_count];
    item.label_len = @min(label.len, MAX_LABEL_LEN - 1);
    @memcpy(item.label[0..item.label_len], label[0..item.label_len]);
    item.active = true;
    item.menu = menu;
    menu_count += 1;
}

fn layoutMenus() void {
    var x: i32 = 28 + @as(i32, @intCast(active_app_len * font_mod.GLYPH_W)) + 16;
    for (menu_bar_items[0..menu_count]) |*item| {
        item.x = x;
        item.width = @intCast(item.label_len * font_mod.GLYPH_W + 16);
        x += @intCast(item.width);
    }
}

/// 设置当前活动应用
pub fn setActiveApp(name: []const u8) void {
    active_app_len = @min(name.len, MAX_LABEL_LEN);
    @memcpy(active_app[0..active_app_len], name[0..active_app_len]);
    layoutMenus();
}

/// 更新时钟显示
pub fn updateClock(hour: u8, minute: u8) void {
    clock_text[0] = '0' + hour / 10;
    clock_text[1] = '0' + hour % 10;
    clock_text[2] = ':';
    clock_text[3] = '0' + minute / 10;
    clock_text[4] = '0' + minute % 10;
    clock_len = 5;
}

/// 渲染菜单栏
pub fn render() void {
    const sw = graphics.screenWidth();

    // 背景
    graphics.fillRect(0, 0, sw, MENUBAR_H, theme.menubar_bg);
    // 底部边框
    graphics.drawHLine(0, @intCast(MENUBAR_H - 1), sw, theme.window_border);

    // Apple图标
    drawLogo(6, 4);

    // 当前应用名称
    graphics.drawString(28, 4, active_app[0..active_app_len], theme.menubar_text);

    // 菜单项
    for (menu_bar_items[0..menu_count]) |item| {
        if (!item.active) continue;
        const text_x = item.x + 8;
        graphics.drawString(text_x, 4, item.label[0..item.label_len], theme.menubar_text);
    }

    // 渲染下拉菜单（如果打开）
    if (menu_open and active_menu != null) {
        renderDropdownMenu(active_menu.?);
    }

    // 状态图标区域
    const clock_w: i32 = @intCast(clock_len * font_mod.GLYPH_W);
    const status_start_x = @as(i32, @intCast(sw)) - clock_w - 12 - 80;
    status_icons.renderStatusIcons(status_start_x, 4);

    // 时钟
    graphics.drawString(@as(i32, @intCast(sw)) - clock_w - 12, 4, clock_text[0..clock_len], theme.menubar_text);
}

/// 渲染下拉菜单
fn renderDropdownMenu(menu: *Menu) void {
    const entry_h: u32 = 22;
    const padding: u32 = 12;
    const total_height = menu.entry_count * entry_h + padding * 2;
    menu.height = @as(u32, @intCast(total_height));

    // 菜单背景
    graphics.fillRoundedRect(menu.x, menu.y, menu.width, menu.height, 6, theme.window_bg);
    graphics.drawRect(menu.x, menu.y, menu.width, menu.height, theme.window_border);

    // 菜单项
    var entry_y = menu.y + @as(i32, @intCast(padding));
    for (menu.entries[0..menu.entry_count]) |*entry| {
        if (entry.item_type == .separator) {
            // 分隔线
            graphics.drawHLine(menu.x + 8, entry_y + 10, menu.width - 16, theme.window_border);
        } else {
            // 菜单项文字
            const text_color = if (entry.enabled) theme.text_primary else theme.text_secondary;
            graphics.drawString(menu.x + @as(i32, @intCast(padding)), entry_y + 4, entry.label[0..entry.label_len], text_color);

            // 快捷键
            if (entry.shortcut_len > 0) {
                const shortcut_w = @as(u32, @intCast(entry.shortcut_len)) * font_mod.GLYPH_W;
                const shortcut_x = menu.x + @as(i32, @intCast(menu.width)) - @as(i32, @intCast(shortcut_w)) - @as(i32, @intCast(padding));
                graphics.drawString(shortcut_x, entry_y + 4, entry.shortcut[0..entry.shortcut_len], theme.text_secondary);
            }
        }
        entry_y += @as(i32, @intCast(entry_h));
    }
}

/// 绘制Logo
fn drawLogo(x: i32, y: i32) void {
    if (logo_texture) |*tex| {
        resources.texture_cache.blitTexture(x, y, tex, 16, 16);
        return;
    }

    const data = icons.getIcon(.apple_logo);
    var row: u32 = 0;
    while (row < icons.ICON_SIZE) : (row += 1) {
        var col: u32 = 0;
        while (col < icons.ICON_SIZE) : (col += 1) {
            const idx = data[row * icons.ICON_SIZE + col];
            if (idx != 0) {
                graphics.putPixel(x + @as(i32, @intCast(col)), y + @as(i32, @intCast(row)), theme.menubar_text);
            }
        }
    }
}

/// 命中测试：返回菜单索引
pub fn hitTest(mx: i32, my: i32) ?usize {
    if (my < 0 or my >= @as(i32, MENUBAR_H)) return null;

    for (menu_bar_items[0..menu_count], 0..) |item, i| {
        if (mx >= item.x and mx < item.x + @as(i32, @intCast(item.width))) {
            return i;
        }
    }

    if (mx >= 0 and mx < 28) return null;

    return null;
}

/// 检查是否在菜单栏区域
pub fn isInMenuBar(my: i32) bool {
    return my >= 0 and my < @as(i32, MENUBAR_H);
}

/// 处理菜单栏点击
pub fn handleClick(mx: i32, my: i32) bool {
    if (my < 0 or my >= @as(i32, MENUBAR_H)) {
        // 点击在菜单栏外，关闭菜单
        closeMenu();
        return false;
    }

    // 检查是否点击菜单栏项
    var hit: bool = false;
    for (menu_bar_items[0..menu_count], 0..menu_count) |item, _| {
        if (mx >= item.x and mx < item.x + @as(i32, @intCast(item.width))) {
            if (item.menu) |menu| {
                if (active_menu == menu and menu_open) {
                    closeMenu();
                } else {
                    openMenu(menu);
                }
            }
            hit = true;
        }
    }
    return hit;
}

/// 打开菜单
fn openMenu(menu: *Menu) void {
    // 计算菜单位置
    menu.x = 100; // 简化计算
    menu.y = @as(i32, MENUBAR_H);
    menu.visible = true;
    active_menu = menu;
    menu_open = true;
}

/// 关闭菜单
fn closeMenu() void {
    if (active_menu) |_| {
        active_menu.?.visible = false;
    }
    active_menu = null;
    menu_open = false;
}

/// 更新菜单栏动画
pub fn updateAnimation() void {
    status_icons.updateAnimation();
}

/// 检查菜单是否打开
pub fn isMenuOpen() bool {
    return menu_open;
}

/// 获取活动菜单
pub fn getActiveMenu() ?*Menu {
    return active_menu;
}
