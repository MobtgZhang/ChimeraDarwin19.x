/// 光标资源加载器 - 从PNG文件加载光标纹理
/// 支持标准光标和自定义光标的缓存管理

const std = @import("std");
const resources = @import("../resources/mod.zig");
const texture_cache = resources.texture_cache;
const log = @import("../../lib/log.zig");

/// 光标加载结果
pub const CursorLoadResult = struct {
    texture: ?texture_cache.Texture,
    width: u32,
    height: u32,
    hotspot_x: u16,
    hotspot_y: u16,
    ok: bool,
};

/// 标准光标热点定义
pub const standard_cursors = struct {
    pub const arrow = CursorLoadResult{
        .texture = null, .width = 12, .height = 18, .hotspot_x = 0, .hotspot_y = 0, .ok = false
    };
    pub const hand = CursorLoadResult{
        .texture = null, .width = 16, .height = 20, .hotspot_x = 4, .hotspot_y = 0, .ok = false
    };
    pub const text = CursorLoadResult{
        .texture = null, .width = 6, .height = 18, .hotspot_x = 3, .hotspot_y = 0, .ok = false
    };
    pub const wait = CursorLoadResult{
        .texture = null, .width = 16, .height = 16, .hotspot_x = 8, .hotspot_y = 8, .ok = false
    };
    pub const crosshair = CursorLoadResult{
        .texture = null, .width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9, .ok = false
    };
    pub const resize_nwse = CursorLoadResult{
        .texture = null, .width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9, .ok = false
    };
    pub const resize_nesw = CursorLoadResult{
        .texture = null, .width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9, .ok = false
    };
    pub const resize_ns = CursorLoadResult{
        .texture = null, .width = 12, .height = 18, .hotspot_x = 6, .hotspot_y = 9, .ok = false
    };
    pub const resize_ew = CursorLoadResult{
        .texture = null, .width = 18, .height = 12, .hotspot_x = 9, .hotspot_y = 6, .ok = false
    };
    pub const drag = CursorLoadResult{
        .texture = null, .width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9, .ok = false
    };
    pub const help = CursorLoadResult{
        .texture = null, .width = 16, .height = 20, .hotspot_x = 12, .hotspot_y = 0, .ok = false
    };
    pub const disallowed = CursorLoadResult{
        .texture = null, .width = 18, .height = 18, .hotspot_x = 9, .hotspot_y = 9, .ok = false
    };
};

/// 全局光标缓存
var global_cursor_cache: [12]?texture_cache.Texture = [_]?texture_cache.Texture{null} ** 12;
var cursor_cache_initialized: bool = false;

/// 初始化光标缓存
pub fn init() void {
    if (!cursor_cache_initialized) {
        cursor_cache_initialized = true;
        preloadAllCursors();
        log.info("[CURSOR] Cursor loader initialized", .{});
    }
}

/// 预加载所有标准光标
fn preloadAllCursors() void {
    const cursor_names = [_][]const u8{
        "arrow", "crosshair", "hand", "text", "wait",
        "resize_ns", "resize_ew", "resize_nwse", "resize_nesw",
        "disallowed", "drag", "help",
    };

    for (cursor_names, 0..) |name, i| {
        if (loadCursor(name)) |result| {
            if (result.ok) {
                global_cursor_cache[i] = result.texture;
                log.debug("[CURSOR] Loaded '{s}' ({}x{})", .{
                    name, result.width, result.height
                });
            }
        }
    }
}

/// 从名称加载光标
pub fn loadCursor(name: []const u8) ?CursorLoadResult {
    var path_buf: [128]u8 = undefined;
    if (resources.icons_registry.getCursorPath(&path_buf, name)) |path| {
        if (texture_cache.loadCursorTexture(path)) |tex| {
            return CursorLoadResult{
                .texture = tex,
                .width = tex.width,
                .height = tex.height,
                .hotspot_x = 0,
                .hotspot_y = 0,
                .ok = true,
            };
        }
    }

    // 尝试直接用名称
    if (texture_cache.loadCursorTexture(name)) |tex| {
        return CursorLoadResult{
            .texture = tex,
            .width = tex.width,
            .height = tex.height,
            .hotspot_x = 0,
            .hotspot_y = 0,
            .ok = true,
        };
    }

    return null;
}

/// 获取缓存的光标
pub fn getCachedCursor(index: usize) ?*texture_cache.Texture {
    if (index < global_cursor_cache.len) {
        return &global_cursor_cache[index].?;
    }
    return null;
}

/// 检查光标是否已加载
pub fn isCursorLoaded(index: usize) bool {
    if (index < global_cursor_cache.len) {
        return global_cursor_cache[index] != null;
    }
    return false;
}

/// 清除所有光标缓存
pub fn clearCache() void {
    for (&global_cursor_cache) |*tex| {
        if (tex.*) |*t| {
            t.deinit();
            tex.* = null;
        }
    }
    texture_cache.clearAllCaches();
    log.info("[CURSOR] Cursor cache cleared", .{});
}

/// 获取光标数量
pub fn getCursorCount() usize {
    var count: usize = 0;
    for (global_cursor_cache) |tex| {
        if (tex != null) count += 1;
    }
    return count;
}
