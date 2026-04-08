/// 增强的纹理缓存系统 - 支持LRU淘汰和多类别资源管理
/// 这是桌面GUI的核心资源加载模块

const std = @import("std");
const graphics = @import("../graphics.zig");
const color_mod = @import("../color.zig");
const filesystem = @import("filesystem.zig");
const log = @import("../../lib/log.zig");
const Color = color_mod.Color;

const MAX_TEXTURES = 32;
const MAX_CURSOR_TEXTURES = 16;

/// 简单的 bump 分配器 - 适用于 UEFI 环境，不依赖 POSIX
const BUMP_SIZE = 2 * 1024 * 1024; // 2MB bump region
var bump_memory: [BUMP_SIZE]u8 align(4096) = .{0} ** BUMP_SIZE;
var bump_offset: usize = 0;

fn bumpAlloc(len: usize) []u8 {
    const aligned = (bump_offset + 7) & ~@as(usize, 7); // 8-byte align
    if (aligned + len > BUMP_SIZE) return &[_]u8{};
    bump_offset = aligned + len;
    return bump_memory[aligned..][0..len];
}

/// 纹理解码缓冲区 - 静态分配避免依赖 POSIX 分配器
const MAX_PNG_BUFFER = 4 * 1024 * 1024; // 4MB for decode buffers
var png_buffers: [MAX_PNG_BUFFER]u8 align(8) = .{0} ** MAX_PNG_BUFFER;
var png_buf_offset: usize = 0;

fn pngAlloc(len: usize) ?[*]u8 {
    const aligned = (png_buf_offset + 7) & ~@as(usize, 7);
    if (aligned + len > MAX_PNG_BUFFER) return null;
    png_buf_offset = aligned + len;
    return png_buffers[aligned..].ptr;
}

fn pngAllocSlice(len: usize) ?[]u8 {
    const ptr = pngAlloc(len) orelse return null;
    return ptr[0..len];
}

fn pngResetBuffers() void {
    png_buf_offset = 0;
}

/// 解码后的RGBA纹理描述符
pub const Texture = struct {
    width: u32,
    height: u32,
    rgba: [*]u8,
    owns_data: bool,
    /// 资源路径（用于缓存键）
    path: [128]u8,
    path_len: usize,

    pub fn initWithRGBA(w: u32, h: u32, data: [*]u8, owns: bool) Texture {
        return Texture{
            .width = w,
            .height = h,
            .rgba = data,
            .owns_data = owns,
            .path = undefined,
            .path_len = 0,
        };
    }

    pub fn deinit(self: *Texture) void {
        _ = self;
        // Bump allocator 不支持真正的释放，纹理数据在 pngResetBuffers 时统一释放
    }

    /// 创建纹理的克隆
    pub fn clone(self: *const Texture) ?Texture {
        const size = @as(usize, self.width) * @as(usize, self.height) * 4;
        const new_data = pngAlloc(size) orelse return null;
        @memcpy(new_data[0..size], self.rgba[0..size]);
        var new_tex = Texture.initWithRGBA(self.width, self.height, new_data, true);
        @memcpy(new_tex.path[0..self.path_len], self.path[0..self.path_len]);
        new_tex.path_len = self.path_len;
        return new_tex;
    }
};

/// LRU缓存条目
const CacheEntry = struct {
    path: [128]u8,
    path_len: usize,
    texture: ?Texture,
    last_access: u32,
    loaded: bool,
};

/// 纹理缓存 - 支持LRU淘汰策略
pub const TextureCache = struct {
    entries: [MAX_TEXTURES]CacheEntry,
    count: u32,
    access_counter: u32,

    pub fn init() TextureCache {
        var cache = TextureCache{
            .entries = undefined,
            .count = 0,
            .access_counter = 0,
        };
        for (&cache.entries) |*e| {
            e.* = .{
                .path = undefined,
                .path_len = 0,
                .texture = null,
                .last_access = 0,
                .loaded = false,
            };
        }
        return cache;
    }

    pub fn deinit(self: *TextureCache) void {
        for (&self.entries) |*e| {
            if (e.texture) |*tex| {
                tex.deinit();
                e.texture = null;
            }
            e.loaded = false;
        }
        self.count = 0;
    }

    /// 查找缓存条目
    fn findEntry(self: *TextureCache, path: []const u8) ?*CacheEntry {
        for (0..self.entries.len) |i| {
            const e = &self.entries[i];
            if (e.loaded and e.path_len == path.len) {
                const existing = e.path[0..e.path_len];
                if (std.mem.eql(u8, existing, path)) {
                    return @constCast(e);
                }
            }
        }
        return null;
    }

    /// 获取缓存的纹理
    pub fn get(self: *TextureCache, path: []const u8) ?*Texture {
        if (findEntry(self, path)) |entry| {
            entry.last_access = self.access_counter;
            self.access_counter += 1;
            return &entry.texture.?;
        }
        return null;
    }

    /// 查找最久未使用的条目
    fn findLRU(self: *TextureCache) ?*CacheEntry {
        if (self.count == 0) return null;
        var oldest: ?*CacheEntry = null;
        var oldest_access: u32 = std.math.maxInt(u32);

        for (&self.entries) |*e| {
            if (e.loaded and e.last_access < oldest_access) {
                oldest_access = e.last_access;
                oldest = e;
            }
        }
        return oldest;
    }

    /// 存储纹理到缓存
    pub fn put(self: *TextureCache, path: []const u8, tex: Texture) bool {
        // 如果已存在，更新
        if (findEntry(self, path)) |entry| {
            if (entry.texture) |*old| {
                old.deinit();
            }
            entry.texture = tex;
            entry.last_access = self.access_counter;
            self.access_counter += 1;
            return true;
        }

        // 如果缓存满了，淘汰LRU
        if (self.count >= MAX_TEXTURES) {
            if (findLRU(self)) |oldest| {
                if (oldest.texture) |*old| {
                    old.deinit();
                }
            } else {
                return false;
            }
        } else {
            self.count += 1;
        }

        // 找到空槽位
        for (&self.entries) |*e| {
            if (!e.loaded) {
                const copy_len = @min(path.len, e.path.len - 1);
                @memcpy(e.path[0..copy_len], path[0..copy_len]);
                e.path_len = copy_len;
                e.texture = tex;
                e.last_access = self.access_counter;
                e.loaded = true;
                self.access_counter += 1;
                return true;
            }
        }
        return false;
    }

    /// 检查是否已缓存
    pub fn contains(self: *TextureCache, path: []const u8) bool {
        for (0..self.entries.len) |i| {
            const e = &self.entries[i];
            if (e.loaded and e.path_len == path.len) {
                const existing = e.path[0..e.path_len];
                if (std.mem.eql(u8, existing, path)) {
                    return true;
                }
            }
        }
        return false;
    }

    /// 获取缓存统计
    pub fn stats(self: *const TextureCache) struct { count: u32, max: u32 } {
        return .{ .count = self.count, .max = MAX_TEXTURES };
    }
};

/// 光标纹理缓存
pub const CursorTextureCache = struct {
    entries: [MAX_CURSOR_TEXTURES]CacheEntry,
    count: u32,
    access_counter: u32,

    pub fn init() CursorTextureCache {
        var cache = CursorTextureCache{
            .entries = undefined,
            .count = 0,
            .access_counter = 0,
        };
        for (&cache.entries) |*e| {
            e.* = .{
                .path = undefined,
                .path_len = 0,
                .texture = null,
                .last_access = 0,
                .loaded = false,
            };
        }
        return cache;
    }

    pub fn deinit(self: *CursorTextureCache) void {
        for (&self.entries) |*e| {
            if (e.texture) |*tex| {
                tex.deinit();
                e.texture = null;
            }
            e.loaded = false;
        }
        self.count = 0;
    }

    pub fn get(self: *CursorTextureCache, path: []const u8) ?*Texture {
        for (&self.entries) |*e| {
            if (e.loaded and e.path_len == path.len) {
                const existing = e.path[0..e.path_len];
                if (std.mem.eql(u8, existing, path)) {
                    e.last_access = self.access_counter;
                    self.access_counter += 1;
                    return &e.texture.?;
                }
            }
        }
        return null;
    }

    pub fn put(self: *CursorTextureCache, path: []const u8, tex: Texture) bool {
        if (self.count >= MAX_CURSOR_TEXTURES) {
            // 淘汰最旧的
            var oldest_idx: usize = 0;
            var oldest_access: u32 = std.math.maxInt(u32);
            for (0..self.entries.len) |i| {
                const e = &self.entries[i];
                if (e.loaded and e.last_access < oldest_access) {
                    oldest_access = e.last_access;
                    oldest_idx = i;
                }
            }
            if (self.entries[oldest_idx].texture) |*old| {
                old.deinit();
            }
        } else {
            self.count += 1;
        }

        var i: usize = 0;
        while (i < self.entries.len) : (i += 1) {
            const e = &self.entries[i];
            if (!e.loaded) {
                const copy_len = @min(path.len, e.path.len - 1);
                @memcpy(e.path[0..copy_len], path[0..copy_len]);
                e.path_len = copy_len;
                e.texture = tex;
                e.last_access = self.access_counter;
                e.loaded = true;
                self.access_counter += 1;
                return true;
            }
        }
        return false;
    }
};

// ── 全局缓存实例 ──────────────────────────────────────

var global_icon_cache: TextureCache = undefined;
var global_cursor_cache: CursorTextureCache = undefined;
var caches_initialized: bool = false;

/// 初始化全局缓存
pub fn initCaches() void {
    if (!caches_initialized) {
        global_icon_cache = TextureCache.init();
        global_cursor_cache = CursorTextureCache.init();
        caches_initialized = true;
        log.info("[TEX] Texture caches initialized (icons: {}, cursors: {})", .{
            MAX_TEXTURES, MAX_CURSOR_TEXTURES
        });
    }
}

/// 从PNG文件加载纹理（使用路径）
pub fn loadTextureFromPath(path: []const u8) ?Texture {
    if (!caches_initialized) initCaches();

    // 检查缓存
    if (global_icon_cache.get(path)) |cached| {
        // 返回克隆以避免生命周期问题
        if (cached.clone()) |clone| {
            return clone;
        }
    }

    // 从文件系统加载
    if (filesystem.getResource(path)) |data| {
        if (decodePng(data.asSlice())) |result| {
            var tex = Texture.initWithRGBA(result.width, result.height, result.rgba, true);
            const copy_len = @min(path.len, tex.path.len - 1);
            @memcpy(tex.path[0..copy_len], path[0..copy_len]);
            tex.path_len = copy_len;

            // 加入缓存（克隆一份存储）
            if (tex.clone()) |cached_copy| {
                _ = global_icon_cache.put(path, cached_copy);
            }

            return tex;
        }
    }
    return null;
}

/// 加载图标纹理（带尺寸选择）
pub fn loadIconTexture(category: []const u8, name: []const u8, preferred_size: ?u32) ?Texture {
    if (!caches_initialized) initCaches();

    var path_buf: [128]u8 = undefined;
    const sizes = [_]u32{ 256, 128, 64, 48, 32 };

    if (preferred_size) |pref| {
        // 按优先尺寸和降序尝试
        for (sizes) |size| {
            if (size <= pref) {
                if (filesystem.ResourcePath.iconPath(&path_buf, category, name, size)) |path| {
                    if (loadTextureFromPath(path)) |tex| {
                        return tex;
                    }
                }
            }
        }
    }

    // 尝试所有可用尺寸
    for (sizes) |size| {
        if (filesystem.ResourcePath.iconPath(&path_buf, category, name, size)) |path| {
            if (loadTextureFromPath(path)) |tex| {
                return tex;
            }
        }
    }

    // 尝试无尺寸后缀
    if (filesystem.ResourcePath.iconPath(&path_buf, category, name, null)) |path| {
        if (loadTextureFromPath(path)) |tex| {
            return tex;
        }
    }

    return null;
}

/// 加载Dock图标
pub fn loadDockIcon(name: []const u8, size: ?u32) ?Texture {
    return loadIconTexture("dock", name, size);
}

/// 加载菜单图标
pub fn loadMenuIcon(name: []const u8) ?Texture {
    return loadIconTexture("menu", name, null);
}

/// 加载状态栏图标
pub fn loadStatusIcon(name: []const u8) ?Texture {
    return loadIconTexture("status", name, null);
}

/// 加载窗口按钮图标
pub fn loadWindowButton(name: []const u8) ?Texture {
    return loadIconTexture("window", name, null);
}

/// 加载光标纹理
pub fn loadCursorTexture(name: []const u8) ?Texture {
    if (!caches_initialized) initCaches();

    // 检查缓存
    if (global_cursor_cache.get(name)) |cached| {
        if (cached.clone()) |clone| {
            return clone;
        }
    }

    var path_buf: [128]u8 = undefined;
        if (filesystem.ResourcePath.cursorPath(&path_buf, name)) |path| {
        if (filesystem.getResource(path)) |data| {
            if (decodePng(data.asSlice())) |result| {
                var tex = Texture.initWithRGBA(result.width, result.height, result.rgba, true);
                const copy_len = @min(name.len, tex.path.len - 1);
                @memcpy(tex.path[0..copy_len], name[0..copy_len]);
                tex.path_len = copy_len;

                // 加入缓存
                if (tex.clone()) |cached_copy| {
                    _ = global_cursor_cache.put(name, cached_copy);
                }

                return tex;
            }
        }
    }
    return null;
}

/// 加载壁纸纹理
pub fn loadWallpaperTexture(name: []const u8) ?Texture {
    var path_buf: [128]u8 = undefined;
    if (filesystem.ResourcePath.wallpaperPath(&path_buf, name)) |path| {
        if (filesystem.getResource(path)) |data| {
            if (decodePng(data.asSlice())) |result| {
                return Texture.initWithRGBA(result.width, result.height, result.rgba, true);
            }
        }
    }
    return null;
}

/// 清除所有纹理缓存
pub fn clearAllCaches() void {
    if (caches_initialized) {
        global_icon_cache.deinit();
        global_cursor_cache.deinit();
        global_icon_cache = TextureCache.init();
        global_cursor_cache = CursorTextureCache.init();
        log.info("[TEX] All texture caches cleared", .{});
    }
}

/// 获取缓存统计
pub fn getCacheStats() struct { icons: u32, cursors: u32 } {
    if (!caches_initialized) return .{ .icons = 0, .cursors = 0 };
    const icon_stats = global_icon_cache.stats();
    const cursor_stats = global_cursor_cache.stats();
    return .{
        .icons = icon_stats.count,
        .cursors = cursor_stats.count,
    };
}

// ── 渲染API（保留原有功能）───────────────────────────────

/// 绘制纹理到屏幕
pub fn blitTexture(x: i32, y: i32, tex: *const Texture, dst_w: ?u32, dst_h: ?u32) void {
    const tw = dst_w orelse tex.width;
    const th = dst_h orelse tex.height;
    if (tw == tex.width and th == tex.height) {
        graphics.blitImage(x, y, tex.width, tex.height, tex.rgba);
    } else {
        graphics.blitImageScaled(x, y, tw, th, tex.width, tex.height, tex.rgba);
    }
}

/// 绘制带色调的纹理
pub fn blitTextureWithTint(x: i32, y: i32, tex: *const Texture, tint: Color, dst_w: ?u32, dst_h: ?u32) void {
    _ = tint;
    blitTexture(x, y, tex, dst_w, dst_h);
}

/// 绘制带透明度的纹理
pub fn blitTextureAlpha(x: i32, y: i32, tex: *const Texture, alpha: u8, dst_w: ?u32, dst_h: ?u32) void {
    _ = alpha;
    blitTexture(x, y, tex, dst_w, dst_h);
}

// ── PNG解码器（复用原有实现）─────────────────────────────

const PNG_SIGNATURE = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
const CHUNK_IHDR: u32 = 0x49484452;
const CHUNK_IDAT: u32 = 0x49444154;
const CHUNK_IEND: u32 = 0x49454E44;
const CHUNK_PLTE: u32 = 0x504C5445;

/// PNG解码结果
pub const PngResult = struct {
    width: u32,
    height: u32,
    rgba: [*]u8,
    ok: bool,
};

/// 解码PNG数据
pub fn decodePng(data: []const u8) ?PngResult {
    if (data.len < 8) return null;
    if (!std.mem.eql(u8, data[0..8], &PNG_SIGNATURE)) return null;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var has_plte = false;
    var palette: [256]Color = .{0} ** 256;
    var palette_count: u32 = 0;

    // 使用 bump allocator 收集 IDAT 数据
    var idat_buf: [512 * 1024]u8 = .{0} ** (512 * 1024);
    var idat_len: usize = 0;

    while (pos < data.len) {
        if (pos + 12 > data.len) break;
        const chunk_len = @as(u32, data[pos]) << 24 | @as(u32, data[pos + 1]) << 16 | @as(u32, data[pos + 2]) << 8 | @as(u32, data[pos + 3]);
        const chunk_type = @as(u32, data[pos + 4]) << 24 | @as(u32, data[pos + 5]) << 16 | @as(u32, data[pos + 6]) << 8 | @as(u32, data[pos + 7]);
        const chunk_start = pos + 8;
        const chunk_end = chunk_start + chunk_len;
        if (chunk_end > data.len) break;

        switch (chunk_type) {
            CHUNK_IHDR => {
                if (chunk_len < 13) return null;
                width = @as(u32, data[chunk_start]) << 24 | @as(u32, data[chunk_start + 1]) << 16 | @as(u32, data[chunk_start + 2]) << 8 | @as(u32, data[chunk_start + 3]);
                height = @as(u32, data[chunk_start + 4]) << 24 | @as(u32, data[chunk_start + 5]) << 16 | @as(u32, data[chunk_start + 6]) << 8 | @as(u32, data[chunk_start + 7]);
                bit_depth = data[chunk_start + 8];
                color_type = data[chunk_start + 9];
            },
            CHUNK_PLTE => {
                palette_count = @min(chunk_len / 3, 256);
                var i: u32 = 0;
                while (i < palette_count) : (i += 1) {
                    const r = data[chunk_start + i * 3 + 0];
                    const g = data[chunk_start + i * 3 + 1];
                    const b = data[chunk_start + i * 3 + 2];
                    palette[i] = (@as(Color, r) << 16) | (@as(Color, g) << 8) | @as(Color, b);
                }
                has_plte = true;
            },
            CHUNK_IDAT => {
                if (idat_len + chunk_len < idat_buf.len) {
                    @memcpy(idat_buf[idat_len..][0..chunk_len], data[chunk_start..chunk_end]);
                    idat_len += chunk_len;
                }
            },
            CHUNK_IEND => break,
            else => {},
        }
        pos = chunk_end + 4;
    }

    if (width == 0 or height == 0 or idat_len == 0) {
        return null;
    }

    const row_bytes: usize = @intCast((@as(usize, width) * @as(usize, bit_depth) * @as(usize, if (color_type == 2) 3 else if (color_type == 6) 4 else 1) + 7) / 8);
    const scanline_len = row_bytes + 1;
    const decomp_len = @as(usize, height) * scanline_len;

    // 使用 bump allocator 分配解码缓冲区
    pngResetBuffers();
    const raw = pngAllocSlice(decomp_len) orelse return null;
    const rgba = pngAllocSlice(@as(usize, width) * @as(usize, height) * 4) orelse return null;

    if (decompressZlib(idat_buf[0..idat_len], raw) == 0) {
        return null;
    }

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const scanline_off = @as(usize, y) * scanline_len;
        const scanline = raw[scanline_off + 1 .. scanline_off + 1 + row_bytes];

        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const out_idx = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
            const px_bytes: usize = if (color_type == 6) 4 else if (color_type == 2) 3 else 1;
            const raw_idx = @as(usize, x) * px_bytes;

            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var a: u32 = 255;

            if (color_type == 6) {
                if (raw_idx + 3 < scanline.len) {
                    r = scanline[raw_idx + 0];
                    g = scanline[raw_idx + 1];
                    b = scanline[raw_idx + 2];
                    a = scanline[raw_idx + 3];
                }
            } else if (color_type == 2) {
                if (raw_idx + 2 < scanline.len) {
                    r = scanline[raw_idx + 0];
                    g = scanline[raw_idx + 1];
                    b = scanline[raw_idx + 2];
                }
            } else if (color_type == 0 or color_type == 3) {
                if (raw_idx < scanline.len) {
                    const idx = scanline[raw_idx];
                    if (color_type == 3 and has_plte and idx < palette_count) {
                        const c = palette[idx];
                        r = (c >> 16) & 0xFF;
                        g = (c >> 8) & 0xFF;
                        b = c & 0xFF;
                    } else {
                        r = idx;
                        g = idx;
                        b = idx;
                    }
                }
            }

            rgba[out_idx + 0] = @as(u8, @intCast(@min(r, 255)));
            rgba[out_idx + 1] = @as(u8, @intCast(@min(g, 255)));
            rgba[out_idx + 2] = @as(u8, @intCast(@min(b, 255)));
            rgba[out_idx + 3] = @as(u8, @intCast(@min(a, 255)));
        }
    }

    return .{
        .width = width,
        .height = height,
        .rgba = rgba.ptr,
        .ok = true,
    };
}

/// 解压缩zlib数据
fn decompressZlib(compressed: []const u8, output: []u8) usize {
    if (compressed.len < 6) return 0;
    const cmf = compressed[0];
    const flg = compressed[1];
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0) return 0;
    if ((cmf & 0x0F) != 8) return 0;

    var pos: usize = 2;
    if ((flg & 0x20) != 0) pos += 4;

    const deflate_data = compressed[pos .. compressed.len - 4];

    // 固定Huffman编码（初始化为全8，然后设置部分为7）
    var ll_lens: [288]u8 = .{8} ** 288;
    for (144..176) |i| ll_lens[i] = 7;

    // 距离长度表（全5）
    var dist_lens: [32]u8 = .{5} ** 32;

    var ll_table: [288]i32 = .{0} ** 288;
    var dist_table: [32]i32 = .{0} ** 32;
    buildHuffmanTable(&ll_table, ll_lens[0..]);
    buildHuffmanTable(&dist_table, dist_lens[0..]);

    const length_base = [_]u32{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const dist_base = [_]u32{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

    var bit_buffer: u32 = 0;
    var bits_in: u32 = 0;
    var window: [32768]u8 = .{0} ** 32768;
    var win_pos: usize = 0;
    var out_pos: usize = 0;

    while (true) {
        const sym = blk: {
            while (bits_in < 9) {
                if (pos < deflate_data.len) {
                    bit_buffer |= @as(u32, deflate_data[pos]) << @as(u5, @intCast(bits_in));
                    pos += 1;
                    bits_in += 8;
                } else {
                    break :blk 256;
                }
            }
            const s = bit_buffer & 0x1FF;
            bit_buffer >>= 9;
            bits_in -= 9;
            break :blk ll_table[@as(usize, s)];
        };
        if (sym == 256) break;

        if (sym >= 0) {
            if (out_pos >= output.len) return out_pos;
            output[out_pos] = @as(u8, @intCast(sym));
            window[win_pos % 32768] = @as(u8, @intCast(sym));
            win_pos += 1;
            out_pos += 1;
        } else {
            const lit = sym - 257;
            var len = length_base[@as(usize, @intCast(@max(lit, 0)))];
            if (lit >= 8 and lit <= 15) {
                const extra_bits_count = @as(u5, @intCast(lit - 8 + 1));
                while (bits_in < extra_bits_count) {
                    if (pos < deflate_data.len) {
                        bit_buffer |= @as(u32, deflate_data[pos]) << @as(u5, @intCast(bits_in));
                        pos += 1;
                        bits_in += 8;
                    }
                }
                const mask: u32 = (@as(u32, 1) << extra_bits_count) - 1;
                len += bit_buffer & mask;
                bit_buffer >>= extra_bits_count;
                bits_in -= extra_bits_count;
            }

            while (bits_in < 5) {
                if (pos < deflate_data.len) {
                    bit_buffer |= @as(u32, deflate_data[pos]) << @as(u5, @intCast(bits_in));
                    pos += 1;
                    bits_in += 8;
                }
            }
            const d_sym = dist_table[@as(usize, bit_buffer & 0x1F)];
            bit_buffer >>= 5;
            bits_in -= 5;

            var dist = dist_base[@as(usize, @intCast(@max(d_sym, 0)))];
            if (d_sym >= 4) {
                const dist_extra_bits = @as(u5, @intCast(@divTrunc(d_sym, 2) + 1));
                while (bits_in < dist_extra_bits) {
                    if (pos < deflate_data.len) {
                        bit_buffer |= @as(u32, deflate_data[pos]) << @as(u5, @intCast(bits_in));
                        pos += 1;
                        bits_in += 8;
                    }
                }
                const mask: u32 = (@as(u32, 1) << dist_extra_bits) - 1;
                dist += bit_buffer & mask;
                bit_buffer >>= dist_extra_bits;
                bits_in -= dist_extra_bits;
            }

            var k: u32 = 0;
            while (k < len) : (k += 1) {
                if (out_pos >= output.len) return out_pos;
                const si = (win_pos - dist + 32768) % 32768;
                const byte = window[si];
                output[out_pos] = byte;
                window[win_pos % 32768] = byte;
                win_pos += 1;
                out_pos += 1;
            }
        }

        if (out_pos >= output.len) break;
    }

    return out_pos;
}

/// 构建Huffman表
fn buildHuffmanTable(table: []i32, lens: []const u8) void {
    var count: [16]u32 = .{0} ** 16;
    for (lens) |len| {
        if (len > 0) count[len] += 1;
    }

    var code: u32 = 0;
    var next_code: [16]u32 = .{0} ** 16;
    for (1..16) |len| {
        code = (code + count[len - 1]) << 1;
        next_code[len] = code;
    }

    for (0..lens.len) |i| {
        if (lens[i] > 0) {
            table[@as(usize, next_code[lens[i]])] = @as(i32, @intCast(i)) | (@as(i32, lens[i]) << 30);
            next_code[lens[i]] += 1;
        }
    }
}
