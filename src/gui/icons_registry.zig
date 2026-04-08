/// 图标注册表 - 将应用程序和UI元素名称映射到assets目录中的PNG文件路径
/// 提供集中式的资源查找，支持尺寸优先级

const std = @import("std");

/// Dock应用条目：映射应用名称到图标文件名和首选尺寸
pub const DockAppEntry = struct {
    icon_name: []const u8,
    preferred_size: u32,
};

/// 所有已知Dock应用的注册表
/// 每个条目指定图标文件名（无路径/尺寸后缀）和首选图标尺寸
/// 加载器将按降序尝试尺寸
pub const dock_apps = [_]DockAppEntry{
    DockAppEntry{ .icon_name = "finder",      .preferred_size = 48 },
    DockAppEntry{ .icon_name = "terminal",    .preferred_size = 48 },
    DockAppEntry{ .icon_name = "settings",    .preferred_size = 48 },
    DockAppEntry{ .icon_name = "editor",      .preferred_size = 48 },
    DockAppEntry{ .icon_name = "music",       .preferred_size = 48 },
    DockAppEntry{ .icon_name = "browser",     .preferred_size = 48 },
    DockAppEntry{ .icon_name = "calendar",    .preferred_size = 48 },
    DockAppEntry{ .icon_name = "calculator",  .preferred_size = 48 },
    DockAppEntry{ .icon_name = "appstore",    .preferred_size = 48 },
    DockAppEntry{ .icon_name = "photos",      .preferred_size = 48 },
    DockAppEntry{ .icon_name = "mail",        .preferred_size = 48 },
    DockAppEntry{ .icon_name = "notes",       .preferred_size = 48 },
    DockAppEntry{ .icon_name = "safari",      .preferred_size = 48 },
    DockAppEntry{ .icon_name = "preferences", .preferred_size = 48 },
    DockAppEntry{ .icon_name = "launchpad",   .preferred_size = 48 },
    DockAppEntry{ .icon_name = "trash",       .preferred_size = 48 },
};

/// 可用图标尺寸，按优先级降序排列
pub const icon_sizes = [_]u32{ 256, 128, 64, 48, 32 };

/// 图标类别目录名称
pub const IconCategory = enum {
    dock,
    menu,
    window,
    status,
    cursor,
};

fn iconCategoryPath(cat: IconCategory) []const u8 {
    return switch (cat) {
        .dock => "assets/icons/dock/",
        .menu => "assets/icons/menu/",
        .window => "assets/icons/window/",
        .status => "assets/icons/status/",
        .cursor => "assets/cursors/",
    };
}

/// 为Dock图标构建完整路径，按尺寸优先级尝试
/// 返回找到的第一个匹配路径，如果没有则返回null
/// 路径缓冲区必须足够大（至少128字节）
pub fn getDockIconPath(buf: []u8, icon_name: []const u8) ?[]const u8 {
    if (buf.len < 128) return null;

    for (icon_sizes) |size| {
        const n = std.fmt.bufPrint(buf, "assets/icons/dock/{s}_{d}.png", .{
            icon_name, size
        }) catch continue;
        if (n.len > 0) return n;
    }

    // 回退：尝试不带尺寸后缀的基础名称
    const n = std.fmt.bufPrint(buf, "assets/icons/dock/{s}.png", .{icon_name}) catch return null;
    return n;
}

/// 为特定类别中的图标构建路径
/// 成功时返回路径字符串
pub fn getIconPath(buf: []u8, cat: IconCategory, icon_name: []const u8, size: ?u32) ?[]const u8 {
    if (buf.len < 128) return null;

    if (size) |s| {
        return std.fmt.bufPrint(buf, "{s}{s}_{d}.png", .{
            iconCategoryPath(cat), icon_name, s
        }) catch return null;
    } else {
        return std.fmt.bufPrint(buf, "{s}{s}.png", .{
            iconCategoryPath(cat), icon_name
        }) catch return null;
    }
}

/// 获取窗口按钮图标名称
pub const window_buttons = struct {
    pub const close = "btn_close";
    pub const minimize = "btn_minimize";
    pub const maximize = "btn_maximize";
    pub const zoom = "btn_zoom";
};

/// 菜单栏图标名称
pub const menu_icons = struct {
    pub const logo = "logo";
    pub const hamburger = "hamburger";
    pub const file = "file";
    pub const edit = "edit";
    pub const view = "view";
    pub const window_icon = "window";
    pub const help = "help";
    pub const vertical_dots = "vertical_dots";
};

/// 状态栏图标名称
pub const status_icons = struct {
    pub const wifi = "wifi";
    pub const wifi_weak = "wifi_weak";
    pub const wifi_medium = "wifi_medium";
    pub const battery = "battery";
    pub const battery_low = "battery_low";
    pub const battery_half = "battery_half";
    pub const battery_critical = "battery_critical";
    pub const volume = "volume";
    pub const volume_low = "volume_low";
    pub const volume_mute = "volume_mute";
    pub const clock = "clock";
    pub const notification = "notification";
};

/// 光标类型名称
pub const cursor_types = struct {
    pub const arrow = "arrow";
    pub const hand = "hand";
    pub const text = "text";
    pub const wait = "wait";
    pub const crosshair = "crosshair";
    pub const resize_nwse = "resize_nwse";
    pub const resize_ns = "resize_ns";
    pub const resize_ew = "resize_ew";
    pub const drag = "drag";
    pub const help = "help";
    pub const disallowed = "disallowed";
};

/// 壁纸名称
pub const wallpaper_names = struct {
    pub const cyberpunk = "cyberpunk";
    pub const nature = "nature";
    pub const minimal = "minimal";
    pub const abstract_wallpaper = "abstract";
};

/// 构建光标图标路径
pub fn getCursorPath(buf: []u8, cursor_name: []const u8) ?[]const u8 {
    if (buf.len < 128) return null;
    return std.fmt.bufPrint(buf, "assets/cursors/{s}.png", .{cursor_name}) catch return null;
}

/// 构建壁纸路径
pub fn getWallpaperPath(buf: []u8, wallpaper_name: []const u8) ?[]const u8 {
    if (buf.len < 128) return null;
    return std.fmt.bufPrint(buf, "assets/wallpapers/{s}.png", .{wallpaper_name}) catch return null;
}

/// 构建状态图标路径
pub fn getStatusIconPath(buf: []u8, icon_name: []const u8) ?[]const u8 {
    return getIconPath(buf, .status, icon_name, null);
}

/// 构建菜单图标路径
pub fn getMenuIconPath(buf: []u8, icon_name: []const u8) ?[]const u8 {
    return getIconPath(buf, .menu, icon_name, null);
}

/// 构建窗口按钮图标路径
pub fn getWindowButtonPath(buf: []u8, button_name: []const u8) ?[]const u8 {
    return getIconPath(buf, .window, button_name, null);
}

/// 解析最佳图标尺寸
/// 基于首选尺寸和可用尺寸，返回最接近但不大于首选尺寸的尺寸
pub fn resolveBestIconSize(preferred: u32, available: []const u32) ?u32 {
    var best: ?u32 = null;
    for (available) |size| {
        if (size <= preferred) {
            if (best == null or size > best.?) {
                best = size;
            }
        }
    }
    return best;
}

/// 根据类别和名称查找Dock应用条目
pub fn findDockApp(name: []const u8) ?*const DockAppEntry {
    for (&dock_apps) |*app| {
        if (std.mem.eql(u8, app.icon_name, name)) {
            return app;
        }
    }
    return null;
}

/// 获取应用图标的最佳尺寸路径
pub fn getAppIconBestPath(buf: []u8, app_name: []const u8) ?[]const u8 {
    if (findDockApp(app_name)) |app| {
        return getDockIconPath(buf, app.icon_name);
    }
    return getDockIconPath(buf, app_name);
}
