/// ChimeraDarwin19.x 桌面资源管理模块
/// 提供统一的资源索引、加载和渲染接口
/// 所有资源均为原创设计，不侵犯任何版权

const color = @import("../color.zig");
const Color = color.Color;

/// 资源加载器模块
pub const loader = @import("loader.zig");
/// 文件系统抽象层
pub const filesystem = @import("filesystem.zig");
/// 纹理缓存系统
pub const texture_cache = @import("texture_cache.zig");
/// 光标加载器
pub const cursor_loader = @import("cursor_loader.zig");
/// 壁纸加载器
pub const wallpaper_loader = @import("wallpaper_loader.zig");
/// 图标注册表（位于 gui/ 目录）
pub const icons_registry = @import("../icons_registry.zig");

/// 资源尺寸常量
pub const IconSize = enum(u32) {
    tiny = 8,
    small = 16,
    medium = 24,
    large = 32,
    xlarge = 48,
};

/// 光标尺寸常量
pub const CursorSize = enum(u32) {
    standard = 32,
    large = 48,
};

/// 调色板类型定义
/// 索引含义: 0=透明, 1=主色, 2=次色, 3=强调色, 4=高亮色
pub const Palette = struct {
    primary: Color,
    secondary: Color,
    accent: Color,
    highlight: Color,

    /// 从主题色构建调色板
    pub fn fromTheme() Palette {
        return Palette{
            .primary = color.theme.text_primary,
            .secondary = color.theme.text_secondary,
            .accent = color.theme.accent,
            .highlight = color.theme.white,
        };
    }

    /// 从自定义颜色构建调色板
    pub fn create(primary: Color, secondary: Color, accent: Color, highlight: Color) Palette {
        return Palette{
            .primary = primary,
            .secondary = secondary,
            .accent = accent,
            .highlight = highlight,
        };
    }
};

/// 资源条目基础结构
pub const ResourceEntry = struct {
    id: u32,
    width: u32,
    height: u32,
    data_offset: u32,
};

/// 图标条目
pub const IconEntry = struct {
    id: u32,
    name: []const u8,
    width: u32,
    height: u32,
    data_offset: u32,
};

/// 光标条目
pub const CursorEntry = struct {
    id: u32,
    name: []const u8,
    width: u32,
    height: u32,
    hot_x: u32,
    hot_y: u32,
    data_offset: u32,
};

/// 壁纸条目
pub const WallpaperEntry = struct {
    id: u32,
    name: []const u8,
    width: u32,
    height: u32,
    data_offset: u32,
    format: WallpaperFormat,
};

pub const WallpaperFormat = enum(u8) {
    gradient = 0,
    solid = 1,
    bitmap = 2,
};

/// 资源清单
pub const ResourceManifest = struct {
    pub const icon_count = 32;
    pub const cursor_count = 12;
    pub const wallpaper_count = 4;

    pub const icons = [_]IconEntry{
        // Dock 应用图标 (16x16)
        IconEntry{ .id = 0, .name = "dock_finder", .width = 16, .height = 16, .data_offset = 0 },
        IconEntry{ .id = 1, .name = "dock_terminal", .width = 16, .height = 16, .data_offset = 256 },
        IconEntry{ .id = 2, .name = "dock_settings", .width = 16, .height = 16, .data_offset = 512 },
        IconEntry{ .id = 3, .name = "dock_editor", .width = 16, .height = 16, .data_offset = 768 },
        IconEntry{ .id = 4, .name = "dock_music", .width = 16, .height = 16, .data_offset = 1024 },
        IconEntry{ .id = 5, .name = "dock_browser", .width = 16, .height = 16, .data_offset = 1280 },
        IconEntry{ .id = 6, .name = "dock_calendar", .width = 16, .height = 16, .data_offset = 1536 },
        IconEntry{ .id = 7, .name = "dock_calculator", .width = 16, .height = 16, .data_offset = 1792 },

        // 菜单栏图标 (16x16)
        IconEntry{ .id = 8, .name = "menu_logo", .width = 16, .height = 16, .data_offset = 2048 },
        IconEntry{ .id = 9, .name = "menu_hamburger", .width = 16, .height = 16, .data_offset = 2304 },
        IconEntry{ .id = 10, .name = "menu_file", .width = 16, .height = 16, .data_offset = 2560 },
        IconEntry{ .id = 11, .name = "menu_edit", .width = 16, .height = 16, .data_offset = 2816 },
        IconEntry{ .id = 12, .name = "menu_view", .width = 16, .height = 16, .data_offset = 3072 },
        IconEntry{ .id = 13, .name = "menu_window", .width = 16, .height = 16, .data_offset = 3328 },
        IconEntry{ .id = 14, .name = "menu_help", .width = 16, .height = 16, .data_offset = 3584 },

        // 窗口控件图标 (8x8)
        IconEntry{ .id = 15, .name = "btn_close", .width = 8, .height = 8, .data_offset = 3840 },
        IconEntry{ .id = 16, .name = "btn_minimize", .width = 8, .height = 8, .data_offset = 3904 },
        IconEntry{ .id = 17, .name = "btn_maximize", .width = 8, .height = 8, .data_offset = 3968 },
        IconEntry{ .id = 18, .name = "btn_zoom", .width = 8, .height = 8, .data_offset = 4032 },

        // 状态栏图标 (8x8)
        IconEntry{ .id = 19, .name = "status_wifi", .width = 8, .height = 8, .data_offset = 4096 },
        IconEntry{ .id = 20, .name = "status_battery", .width = 8, .height = 8, .data_offset = 4160 },
        IconEntry{ .id = 21, .name = "status_volume", .width = 8, .height = 8, .data_offset = 4224 },
        IconEntry{ .id = 22, .name = "status_clock", .width = 8, .height = 8, .data_offset = 4288 },
        IconEntry{ .id = 23, .name = "status_notification", .width = 8, .height = 8, .data_offset = 4352 },

        // 扩展 Dock 图标 (16x16)
        IconEntry{ .id = 24, .name = "dock_trash", .width = 16, .height = 16, .data_offset = 4416 },
        IconEntry{ .id = 25, .name = "dock_appstore", .width = 16, .height = 16, .data_offset = 4672 },
        IconEntry{ .id = 26, .name = "dock_photos", .width = 16, .height = 16, .data_offset = 4928 },
        IconEntry{ .id = 27, .name = "dock_mail", .width = 16, .height = 16, .data_offset = 5184 },
        IconEntry{ .id = 28, .name = "dock_notes", .width = 16, .height = 16, .data_offset = 5440 },
        IconEntry{ .id = 29, .name = "dock_safari", .width = 16, .height = 16, .data_offset = 5696 },
        IconEntry{ .id = 30, .name = "dock_preferences", .width = 16, .height = 16, .data_offset = 5952 },
        IconEntry{ .id = 31, .name = "dock_launchpad", .width = 16, .height = 16, .data_offset = 6208 },
    };

    pub const cursors = [_]CursorEntry{
        CursorEntry{ .id = 0, .name = "arrow", .width = 32, .height = 32, .hot_x = 3, .hot_y = 1, .data_offset = 0 },
        CursorEntry{ .id = 1, .name = "hand", .width = 32, .height = 32, .hot_x = 9, .hot_y = 0, .data_offset = 1024 },
        CursorEntry{ .id = 2, .name = "text", .width = 32, .height = 32, .hot_x = 15, .hot_y = 14, .data_offset = 2048 },
        CursorEntry{ .id = 3, .name = "wait", .width = 32, .height = 32, .hot_x = 15, .hot_y = 8, .data_offset = 3072 },
        CursorEntry{ .id = 4, .name = "crosshair", .width = 32, .height = 32, .hot_x = 15, .hot_y = 15, .data_offset = 4096 },
        CursorEntry{ .id = 5, .name = "resize_nwse", .width = 32, .height = 32, .hot_x = 15, .hot_y = 15, .data_offset = 5120 },
        CursorEntry{ .id = 6, .name = "resize_nesw", .width = 32, .height = 32, .hot_x = 15, .hot_y = 15, .data_offset = 6144 },
        CursorEntry{ .id = 7, .name = "resize_ns", .width = 32, .height = 32, .hot_x = 15, .hot_y = 15, .data_offset = 7168 },
        CursorEntry{ .id = 8, .name = "resize_ew", .width = 32, .height = 32, .hot_x = 15, .hot_y = 15, .data_offset = 8192 },
        CursorEntry{ .id = 9, .name = "drag", .width = 32, .height = 32, .hot_x = 15, .hot_y = 15, .data_offset = 9216 },
        CursorEntry{ .id = 10, .name = "help", .width = 32, .height = 32, .hot_x = 15, .hot_y = 4, .data_offset = 10240 },
        CursorEntry{ .id = 11, .name = "disallowed", .width = 32, .height = 32, .hot_x = 15, .hot_y = 15, .data_offset = 11264 },
    };

    pub const wallpapers = [_]WallpaperEntry{
        WallpaperEntry{ .id = 0, .name = "cyberpunk", .width = 1920, .height = 1080, .data_offset = 0, .format = .gradient },
        WallpaperEntry{ .id = 1, .name = "nature", .width = 1920, .height = 1080, .data_offset = 1, .format = .gradient },
        WallpaperEntry{ .id = 2, .name = "minimal", .width = 1920, .height = 1080, .data_offset = 2, .format = .solid },
        WallpaperEntry{ .id = 3, .name = "abstract", .width = 1920, .height = 1080, .data_offset = 3, .format = .gradient },
    };
};

/// 图标 ID 枚举
pub const DockIconId = enum(u8) {
    finder = 0,
    terminal = 1,
    settings = 2,
    editor = 3,
    music = 4,
    browser = 5,
    calendar = 6,
    calculator = 7,
    trash = 24,
    appstore = 25,
    photos = 26,
    mail = 27,
    notes = 28,
    safari = 29,
    preferences = 30,
    launchpad = 31,
};

pub const MenuIconId = enum(u8) {
    logo = 8,
    hamburger = 9,
    file = 10,
    edit = 11,
    view = 12,
    window_icon = 13,
    help = 14,
};

pub const WindowButtonId = enum(u8) {
    close = 15,
    minimize = 16,
    maximize = 17,
    zoom = 18,
};

pub const StatusIconId = enum(u8) {
    wifi = 19,
    battery = 20,
    volume = 21,
    clock = 22,
    notification = 23,
};

pub const CursorId = enum(u8) {
    arrow = 0,
    hand = 1,
    text = 2,
    wait = 3,
    crosshair = 4,
    resize_nwse = 5,
    resize_nesw = 6,
    resize_ns = 7,
    resize_ew = 8,
    drag = 9,
    help = 10,
    disallowed = 11,
};

/// 资源上下文，用于运行时资源管理
pub const ResourceContext = struct {
    palette: Palette,
    current_cursor: CursorId,

    pub fn init() ResourceContext {
        return ResourceContext{
            .palette = Palette.fromTheme(),
            .current_cursor = .arrow,
        };
    }

    /// 设置主题调色板
    pub fn setPalette(self: *ResourceContext, palette: Palette) void {
        self.palette = palette;
    }

    /// 获取调色板颜色
    pub fn resolveColor(self: ResourceContext, idx: u8) Color {
        return switch (idx) {
            0 => 0,
            1 => self.palette.primary,
            2 => self.palette.secondary,
            3 => self.palette.accent,
            4 => self.palette.highlight,
            else => self.palette.primary,
        };
    }
};
