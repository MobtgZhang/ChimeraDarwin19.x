/// 壁纸加载器 - 支持从PNG文件加载壁纸
/// 提供多种壁纸缩放模式：拉伸、填充、居中、平铺

const std = @import("std");
const graphics = @import("../graphics.zig");
const color_mod = @import("../color.zig");
const resources = @import("../resources/mod.zig");
const texture_cache = resources.texture_cache;
const log = @import("../../lib/log.zig");
const Color = color_mod.Color;

/// 壁纸缩放模式
pub const WallpaperMode = enum(u8) {
    stretch = 0,      // 拉伸填满屏幕
    fill = 1,         // 等比填充，可能裁剪
    fit = 2,          // 等比适应，可能有黑边
    center = 3,       // 居中显示原始尺寸
    tile = 4,         // 平铺重复
};

/// 壁纸描述符
pub const Wallpaper = struct {
    name: [32]u8,
    name_len: usize,
    texture: ?texture_cache.Texture,
    mode: WallpaperMode,
    loaded: bool,

    pub fn init(name: []const u8) Wallpaper {
        var w = Wallpaper{
            .name = undefined,
            .name_len = 0,
            .texture = null,
            .mode = .fill,
            .loaded = false,
        };
        w.setName(name);
        return w;
    }

    pub fn setName(self: *Wallpaper, name: []const u8) void {
        self.name_len = @min(name.len, 31);
        @memcpy(self.name[0..self.name_len], name[0..self.name_len]);
        self.name[self.name_len] = 0;
    }

    pub fn getName(self: *const Wallpaper) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn deinit(self: *Wallpaper) void {
        if (self.texture) |*tex| {
            tex.deinit();
            self.texture = null;
        }
        self.loaded = false;
    }
};

/// 全局壁纸状态
var current_wallpaper: Wallpaper = undefined;
var current_mode: WallpaperMode = .fill;
var wallpaper_initialized: bool = false;

/// 内置壁纸渐变定义
const BuiltinWallpaperGradient = struct {
    top: Color,
    mid: Color,
    bottom: Color,
};

/// 内置渐变壁纸
const builtin_wallpapers = [_]struct { name: []const u8, gradient: BuiltinWallpaperGradient }{
    .{
        .name = "cyberpunk",
        .gradient = BuiltinWallpaperGradient{
            .top = 0x001E0533,
            .mid = 0x003A1B6C,
            .bottom = 0x00643C96,
        },
    },
    .{
        .name = "nature",
        .gradient = BuiltinWallpaperGradient{
            .top = 0x00228B22,
            .mid = 0x004682B4,
            .bottom = 0x0087CEEB,
        },
    },
    .{
        .name = "minimal",
        .gradient = BuiltinWallpaperGradient{
            .top = 0x002D2D30,
            .mid = 0x002D2D30,
            .bottom = 0x002D2D30,
        },
    },
    .{
        .name = "abstract",
        .gradient = BuiltinWallpaperGradient{
            .top = 0x00FF5757,
            .mid = 0x00FFBD2E,
            .bottom = 0x0028C840,
        },
    },
};

/// 初始化壁纸系统
pub fn init() void {
    current_wallpaper = Wallpaper.init("cyberpunk");
    current_mode = .fill;
    wallpaper_initialized = true;
    log.info("[WALLPAPER] Wallpaper system initialized", .{});
}

/// 加载壁纸（从PNG或使用内置渐变）
pub fn loadWallpaper(name: []const u8) bool {
    // 检查是否是内置渐变壁纸
    for (builtin_wallpapers) |builtin| {
        if (std.mem.eql(u8, builtin.name, name)) {
            current_wallpaper.setName(name);
            current_wallpaper.texture = null;
            current_wallpaper.loaded = false;
            log.info("[WALLPAPER] Using built-in gradient wallpaper: '{s}'", .{name});
            return true;
        }
    }

    // 尝试从PNG加载
    var path_buf: [128]u8 = undefined;
    if (resources.icons_registry.getWallpaperPath(&path_buf, name)) |path| {
        if (texture_cache.loadWallpaperTexture(path)) |tex| {
            current_wallpaper.setName(name);
            current_wallpaper.texture = tex;
            current_wallpaper.loaded = true;
            log.info("[WALLPAPER] Loaded wallpaper '{s}' ({}x{})", .{
                name, tex.width, tex.height
            });
            return true;
        }
    }

    // 尝试不带.png后缀
    if (texture_cache.loadWallpaperTexture(name)) |tex| {
        current_wallpaper.setName(name);
        current_wallpaper.texture = tex;
        current_wallpaper.loaded = true;
        log.info("[WALLPAPER] Loaded wallpaper '{s}'", .{name});
        return true;
    }

    log.warn("[WALLPAPER] Failed to load wallpaper: '{s}'", .{name});
    return false;
}

/// 设置壁纸缩放模式
pub fn setMode(mode: WallpaperMode) void {
    current_mode = mode;
}

/// 获取当前壁纸缩放模式
pub fn getMode() WallpaperMode {
    return current_mode;
}

/// 获取当前壁纸名称
pub fn getCurrentWallpaperName() []const u8 {
    return current_wallpaper.getName();
}

/// 渲染当前壁纸到屏幕
pub fn render() void {
    if (!wallpaper_initialized) {
        init();
    }

    const sw = graphics.screenWidth();
    const sh = graphics.screenHeight();

    // 如果有加载的PNG纹理
    if (current_wallpaper.loaded and current_wallpaper.texture != null) {
        const tex = &current_wallpaper.texture.?;
        renderTextureMode(tex, sw, sh, current_mode);
    } else {
        // 使用内置渐变
        renderBuiltinGradient(current_wallpaper.getName());
    }
}

/// 根据模式渲染纹理
fn renderTextureMode(tex: *texture_cache.Texture, screen_w: u32, screen_h: u32, mode: WallpaperMode) void {
    switch (mode) {
        .stretch => {
            // 拉伸填满屏幕
            graphics.blitImageScaled(0, 0, screen_w, screen_h, tex.width, tex.height, tex.rgba);
        },
        .fill => {
            // 等比填充，可能裁剪
            const tex_aspect = @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height));
            const screen_aspect = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));

            var dst_w: u32 = screen_w;
            var dst_h: u32 = screen_h;
            var dst_x: i32 = 0;
            var dst_y: i32 = 0;

            if (tex_aspect > screen_aspect) {
                // 图片更宽，按高度填充，裁剪宽度
                dst_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(screen_h)) * tex_aspect));
                dst_x = @divTrunc(@as(i32, @intCast(dst_w)) - @as(i32, @intCast(screen_w)), 2);
            } else {
                // 图片更高，按宽度填充，裁剪高度
                dst_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(screen_w)) / tex_aspect));
                dst_y = @divTrunc(@as(i32, @intCast(dst_h)) - @as(i32, @intCast(screen_h)), 2);
            }

            graphics.blitImageScaled(dst_x, dst_y, screen_w, screen_h, tex.width, tex.height, tex.rgba);
        },
        .fit => {
            // 等比适应，可能有黑边
            const tex_aspect = @as(f32, @floatFromInt(tex.width)) / @as(f32, @floatFromInt(tex.height));
            const screen_aspect = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));

            var dst_w: u32 = 0;
            var dst_h: u32 = 0;

            if (tex_aspect > screen_aspect) {
                // 按宽度填充
                dst_w = screen_w;
                dst_h = @as(u32, @intFromFloat(@as(f32, @floatFromInt(screen_w)) / tex_aspect));
            } else {
                // 按高度填充
                dst_h = screen_h;
                dst_w = @as(u32, @intFromFloat(@as(f32, @floatFromInt(screen_h)) * tex_aspect));
            }

            const dst_x = @divTrunc(@as(i32, @intCast(screen_w)) - @as(i32, @intCast(dst_w)), 2);
            const dst_y = @divTrunc(@as(i32, @intCast(screen_h)) - @as(i32, @intCast(dst_h)), 2);

            // 先清空背景
            graphics.clear(0x00000000);
            // 绘制壁纸
            graphics.blitImageScaled(dst_x, dst_y, dst_w, dst_h, tex.width, tex.height, tex.rgba);
        },
        .center => {
            // 居中显示原始尺寸
            const dst_x = @divTrunc(@as(i32, @intCast(screen_w)) - @as(i32, @intCast(tex.width)), 2);
            const dst_y = @divTrunc(@as(i32, @intCast(screen_h)) - @as(i32, @intCast(tex.height)), 2);

            // 先清空背景
            graphics.clear(0x00000000);
            // 居中绘制
            graphics.blitImage(dst_x, dst_y, tex.width, tex.height, tex.rgba);
        },
        .tile => {
            // 平铺重复
            var y: i32 = 0;
            while (y < @as(i32, @intCast(screen_h))) : (y += @as(i32, @intCast(tex.height))) {
                var x: i32 = 0;
                while (x < @as(i32, @intCast(screen_w))) : (x += @as(i32, @intCast(tex.width))) {
                    graphics.blitImage(x, y, tex.width, tex.height, tex.rgba);
                }
            }
        },
    }
}

/// 渲染内置渐变壁纸
fn renderBuiltinGradient(name: []const u8) void {
    const sw = graphics.screenWidth();
    const sh = graphics.screenHeight();

    for (builtin_wallpapers) |builtin| {
        if (std.mem.eql(u8, builtin.name, name)) {
            const mid_y = sh / 2;
            graphics.fillGradientV(0, 0, sw, mid_y, builtin.gradient.top, builtin.gradient.mid);
            graphics.fillGradientV(0, @intCast(mid_y), sw, sh - mid_y, builtin.gradient.mid, builtin.gradient.bottom);
            return;
        }
    }

    // 默认渐变
    const mid_y = sh / 2;
    graphics.fillGradientV(0, 0, sw, mid_y, 0x001E0533, 0x003A1B6C);
    graphics.fillGradientV(0, @intCast(mid_y), sw, sh - mid_y, 0x003A1B6C, 0x00643C96);
}

/// 获取所有可用的内置壁纸名称
pub fn getAvailableWallpapers() []const []const u8 {
    var names: [builtin_wallpapers.len][]const u8 = undefined;
    for (builtin_wallpapers, 0..) |builtin, i| {
        names[i] = builtin.name;
    }
    return &names;
}

/// 切换到下一个壁纸
pub fn cycleToNextWallpaper() void {
    const wallpapers = getAvailableWallpapers();
    var current_idx: usize = 0;

    for (wallpapers, 0..) |name, i| {
        if (std.mem.eql(u8, name, current_wallpaper.getName())) {
            current_idx = i;
            break;
        }
    }

    const next_idx = (current_idx + 1) % wallpapers.len;
    _ = loadWallpaper(wallpapers[next_idx]);
}

/// 获取壁纸是否已加载
pub fn isLoaded() bool {
    return current_wallpaper.loaded;
}

/// 获取当前壁纸纹理
pub fn getCurrentTexture() ?*texture_cache.Texture {
    return &current_wallpaper.texture.?;
}

/// 清理壁纸系统资源
pub fn deinit() void {
    current_wallpaper.deinit();
    wallpaper_initialized = false;
    log.info("[WALLPAPER] Wallpaper system deinitialized", .{});
}
