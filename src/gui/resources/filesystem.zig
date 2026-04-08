/// 文件系统抽象层 - 为桌面资源提供统一的文件访问接口
/// 支持多种数据源：内嵌资源、VFS路径、UEFI文件系统
/// 设计用于bare-metal内核环境，在没有标准libc文件I/O的情况下工作

const std = @import("std");
const log = @import("../../lib/log.zig");

/// 资源数据源类型
pub const ResourceSource = enum {
    embedded,   // 内嵌到二进制中的数据
    vfs,        // 通过VFS虚拟文件系统访问
    efi,        // UEFI文件协议访问
    memory,     // 直接内存引用
};

/// 资源数据描述符
pub const ResourceData = struct {
    source: ResourceSource,
    /// 数据的直接指针（对于embedded/memory）
    data_ptr: [*]const u8,
    /// 数据长度
    length: usize,
    /// 指向底层上下文的指针（可选）
    context: ?*anyopaque,

    /// 从内存区域创建资源数据
    pub fn fromMemory(ptr: [*]const u8, len: usize) ResourceData {
        return ResourceData{
            .source = .memory,
            .data_ptr = ptr,
            .length = len,
            .context = null,
        };
    }

    /// 获取数据切片的引用
    pub fn asSlice(self: *const ResourceData) []const u8 {
        return self.data_ptr[0..self.length];
    }
};

/// 文件系统接口 - 抽象不同文件系统的访问方式
pub const FileSystem = struct {
    /// 尝试从指定路径读取文件数据
    /// 在bare-metal环境中，这会根据可用文件系统实现
    pub fn readFile(path: []const u8) ?ResourceData {
        // 首先尝试从内嵌资源加载
        if (readEmbeddedResource(path)) |data| {
            return data;
        }
        // 尝试从VFS加载
        if (vfsReadFile(path)) |data| {
            return data;
        }
        return null;
    }

    /// 检查文件是否存在
    pub fn fileExists(path: []const u8) bool {
        return readFile(path) != null;
    }

    /// 获取文件大小（如果可获取）
    pub fn getFileSize(path: []const u8) ?usize {
        if (readFile(path)) |data| {
            return data.length;
        }
        return null;
    }
};

/// 内嵌资源注册表 - 将编译时已知的资源数据映射到路径
pub const EmbeddedResourceRegistry = struct {
    /// 资源条目
    pub const Entry = struct {
        path: []const u8,
        data: []const u8,
    };

    /// 根据路径查找内嵌资源
    pub fn find(path: []const u8) ?[]const u8 {
        inline for (comptime getEmbeddedEntries()) |entry| {
            if (std.mem.eql(u8, path, entry.path)) {
                return entry.data;
            }
        }
        return null;
    }

    /// 获取所有内嵌资源条目（编译时生成）
    fn getEmbeddedEntries() []const Entry {
        return &.{};
    }
};

/// 尝试从内嵌资源读取
fn readEmbeddedResource(path: []const u8) ?ResourceData {
    if (EmbeddedResourceRegistry.find(path)) |data| {
        return ResourceData{
            .source = .embedded,
            .data_ptr = data.ptr,
            .length = data.len,
            .context = null,
        };
    }
    return null;
}

/// VFS文件读取（需要VFS子系统支持）
fn vfsReadFile(path: []const u8) ?ResourceData {
    _ = path;
    // TODO: 当VFS子系统完善后，实现从虚拟文件系统读取
    // 这需要实现文件描述符和read syscall
    return null;
}

/// 资源路径解析器
pub const ResourcePath = struct {
    /// 解析图标资源的完整路径
    /// category: dock, menu, window, status
    /// name: 图标名称
    /// size: 尺寸后缀（如_48, _64等），可选
    pub fn iconPath(buf: []u8, category: []const u8, name: []const u8, size: ?u32) ?[]const u8 {
        if (buf.len < 128) return null;

        const prefix = "assets/icons/";
        if (size) |s| {
            return std.fmt.bufPrint(buf, "{s}{s}/{s}_{d}.png", .{
                prefix, category, name, s
            }) catch return null;
        } else {
            return std.fmt.bufPrint(buf, "{s}{s}/{s}.png", .{
                prefix, category, name
            }) catch return null;
        }
    }

    /// 解析光标资源路径
    pub fn cursorPath(buf: []u8, name: []const u8) ?[]const u8 {
        if (buf.len < 128) return null;
        return std.fmt.bufPrint(buf, "assets/cursors/{s}.png", .{name}) catch return null;
    }

    /// 解析壁纸资源路径
    pub fn wallpaperPath(buf: []u8, name: []const u8) ?[]const u8 {
        if (buf.len < 128) return null;
        return std.fmt.bufPrint(buf, "assets/wallpapers/{s}.png", .{name}) catch return null;
    }

    /// 解析菜单图标路径
    pub fn menuIconPath(buf: []u8, name: []const u8) ?[]const u8 {
        return iconPath(buf, "menu", name, null);
    }

    /// 解析状态图标路径
    pub fn statusIconPath(buf: []u8, name: []const u8) ?[]const u8 {
        return iconPath(buf, "status", name, null);
    }

    /// 解析窗口按钮图标路径
    pub fn windowButtonPath(buf: []u8, name: []const u8) ?[]const u8 {
        return iconPath(buf, "window", name, null);
    }
};

/// 资源加载器上下文
pub const ResourceLoaderContext = struct {
    /// 已加载资源的缓存
    cache: ResourceCache,

    pub fn init() ResourceLoaderContext {
        return ResourceLoaderContext{
            .cache = ResourceCache.init(),
        };
    }

    /// 加载指定路径的资源
    pub fn load(self: *ResourceLoaderContext, path: []const u8) ?ResourceData {
        // 检查缓存
        if (self.cache.get(path)) |cached| {
            return cached;
        }
        // 从文件系统加载
        if (FileSystem.readFile(path)) |data| {
            self.cache.put(path, data);
            return data;
        }
        return null;
    }

    /// 清除所有缓存
    pub fn clearCache(self: *ResourceLoaderContext) void {
        self.cache.deinit();
        self.cache = ResourceCache.init();
    }
};

/// 简单的资源缓存（固定大小）
pub const ResourceCache = struct {
    const MAX_ENTRIES = 16;

    paths: [MAX_ENTRIES][128]u8,
    data: [MAX_ENTRIES]?ResourceData,
    count: u32,

    pub fn init() ResourceCache {
        var cache = ResourceCache{
            .paths = undefined,
            .data = .{null} ** MAX_ENTRIES,
            .count = 0,
        };
        for (&cache.paths) |*p| {
            @memset(p, 0);
        }
        return cache;
    }

    pub fn get(self: *const ResourceCache, path: []const u8) ?ResourceData {
        for (self.paths[0..self.count], 0..) |p, i| {
            const existing = p[0..@min(p.len, path.len)];
            const incoming = path[0..@min(p.len, path.len)];
            if (std.mem.eql(u8, existing, incoming)) {
                return self.data[i];
            }
        }
        return null;
    }

    pub fn put(self: *ResourceCache, path: []const u8, data: ResourceData) void {
        if (self.count >= MAX_ENTRIES) {
            // 简单的FIFO淘汰
            self.count -= 1;
        }
        const copy_len = @min(path.len, self.paths[self.count].len - 1);
        @memcpy(self.paths[self.count][0..copy_len], path[0..copy_len]);
        self.paths[self.count][copy_len] = 0;
        self.data[self.count] = data;
        self.count += 1;
    }

    pub fn deinit(self: *ResourceCache) void {
        self.count = 0;
    }
};

/// 全局资源加载器实例
var global_loader: ResourceLoaderContext = undefined;
var loader_initialized: bool = false;

/// 初始化全局资源加载器
pub fn initGlobalLoader() void {
    if (!loader_initialized) {
        global_loader = ResourceLoaderContext.init();
        loader_initialized = true;
        log.info("[RES] Global resource loader initialized", .{});
    }
}

/// 获取全局资源数据
pub fn getResource(path: []const u8) ?ResourceData {
    if (!loader_initialized) {
        initGlobalLoader();
    }
    return global_loader.load(path);
}

/// 清除全局资源缓存
pub fn clearGlobalCache() void {
    if (loader_initialized) {
        global_loader.clearCache();
        log.info("[RES] Global resource cache cleared", .{});
    }
}
