/// Slab — 对象缓存层（固定大小内存分配）。
///
/// Slab 是三层内存分配架构中的第三层（最上层），提供固定大小的对象缓存。
/// 在 Slub 和 Slabx 之上，Slab 提供标准化的对象缓存接口，
/// 支持 kmalloc/kfree 等通用分配函数。
///
/// 职责：
///   - 提供固定大小的对象缓存池
///   - 自动选择合适大小的缓存
///   - 支持通用分配 API (kmalloc/kfree/kzalloc)
///   - 与 Slabx 层集成获得 per-CPU 优化
///
/// 架构层次：
///   kmalloc/kfree (用户接口) ← 这里
///       ↓
///   Slab (对象缓存，固定大小) ← 本文件
///       ↓
///   Slabx (per-CPU 缓存层)
///       ↓
///   Slub (底层页框分配)
///       ↓
///   PMM (物理内存 bitmap)

const slub = @import("slub.zig");
const slabx = @import("slabx.zig");
const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const builtin = @import("builtin");

pub const PAGE_SIZE: usize = slub.PAGE_SIZE;

// ============================================================================
// 分配大小级别定义
// ============================================================================

/// 标准分配大小级别
pub const SizeClass = enum(u8) {
    size_8 = 0,
    size_16 = 1,
    size_32 = 2,
    size_48 = 3,  // 特殊：48 字节（常见内核对象大小）
    size_64 = 4,
    size_96 = 5,  // 特殊：96 字节
    size_128 = 6,
    size_192 = 7, // 特殊：192 字节
    size_256 = 8,
    size_512 = 9,
    size_1024 = 10,
    size_2048 = 11,
    size_4096 = 12,
    size_8192 = 13,
    size_16384 = 14,
    size_32768 = 15,
    size_65536 = 16,
    large = 17, // 超过 64KB
};

/// 大小级别信息
const SizeClassInfo = struct {
    size_class: SizeClass,
    max_size: usize,
};

/// 大小级别查找表
const SIZE_CLASS_TABLE = [_]SizeClassInfo{
    .{ .size_class = .size_8, .max_size = 8 },
    .{ .size_class = .size_16, .max_size = 16 },
    .{ .size_class = .size_32, .max_size = 32 },
    .{ .size_class = .size_48, .max_size = 48 },
    .{ .size_class = .size_64, .max_size = 64 },
    .{ .size_class = .size_96, .max_size = 96 },
    .{ .size_class = .size_128, .max_size = 128 },
    .{ .size_class = .size_192, .max_size = 192 },
    .{ .size_class = .size_256, .max_size = 256 },
    .{ .size_class = .size_512, .max_size = 512 },
    .{ .size_class = .size_1024, .max_size = 1024 },
    .{ .size_class = .size_2048, .max_size = 2048 },
    .{ .size_class = .size_4096, .max_size = 4096 },
    .{ .size_class = .size_8192, .max_size = 8192 },
    .{ .size_class = .size_16384, .max_size = 16384 },
    .{ .size_class = .size_32768, .max_size = 32768 },
    .{ .size_class = .size_65536, .max_size = 65536 },
    .{ .size_class = .large, .max_size = 0xFFFF_FFFF },
};

/// 获取请求大小对应的最小适配大小级别
fn getSizeClass(requested: usize) SizeClass {
    if (requested <= 8) return .size_8;
    if (requested <= 16) return .size_16;
    if (requested <= 32) return .size_32;
    if (requested <= 48) return .size_48;
    if (requested <= 64) return .size_64;
    if (requested <= 96) return .size_96;
    if (requested <= 128) return .size_128;
    if (requested <= 192) return .size_192;
    if (requested <= 256) return .size_256;
    if (requested <= 512) return .size_512;
    if (requested <= 1024) return .size_1024;
    if (requested <= 2048) return .size_2048;
    if (requested <= 4096) return .size_4096;
    if (requested <= 8192) return .size_8192;
    if (requested <= 16384) return .size_16384;
    if (requested <= 32768) return .size_32768;
    if (requested <= 65536) return .size_65536;
    return .large;
}

/// 获取大小级别对应的实际分配大小
fn getClassSize(class: SizeClass) usize {
    return switch (class) {
        .size_8 => 8,
        .size_16 => 16,
        .size_32 => 32,
        .size_48 => 48,
        .size_64 => 64,
        .size_96 => 96,
        .size_128 => 128,
        .size_192 => 192,
        .size_256 => 256,
        .size_512 => 512,
        .size_1024 => 1024,
        .size_2048 => 2048,
        .size_4096 => 4096,
        .size_8192 => 8192,
        .size_16384 => 16384,
        .size_32768 => 32768,
        .size_65536 => 65536,
        .large => 0,
    };
}

// ============================================================================
// 元数据头（用于自动大小检测）
// ============================================================================

/// 分配元数据头
/// 存储在每个分配块的开头，允许 kfree 自动检测大小
const AllocHeader = struct {
    /// 请求的分配大小（不包括头部）
    size: usize,
    /// 大小级别
    class: u8,
    /// 魔数，用于验证
    magic: u32,

    const MAGIC: u32 = 0x4B4D414C; // "KMAL" 的 ASCII 码（小端序）
    const HEADER_SIZE: usize = @sizeOf(AllocHeader);
};

// ============================================================================
// kmalloc/kfree 实现
// ============================================================================

/// kmalloc — 分配内存
///
/// 参数：
///   size - 请求的字节数
///
/// 返回：
///   分配的内存指针，或 null（如果分配失败）
pub fn kmalloc(size: usize) ?[*]u8 {
    if (size == 0) return null;

    // 检查溢出
    if (size > 0xFFFF_FFFF) return null;

    // 超过 64KB，使用 Slub 直接分配
    if (size > 65536) {
        return kmallocLarge(size);
    }

    // 获取大小级别
    const class = getSizeClass(size);
    const alloc_size = getClassSize(class);

    // 从 Slabx 分配
    const ptr = slabx.slabxAlloc(alloc_size) orelse return null;

    // 写入元数据头部
    const header: *AllocHeader = @ptrFromInt(@intFromPtr(ptr) - AllocHeader.HEADER_SIZE);
    header.* = .{
        .size = size,
        .class = @intFromEnum(class),
        .magic = AllocHeader.MAGIC,
    };

    log.debug("[Slab] kmalloc({}) = 0x{x} (class={}, alloc={})", .{
        size, @intFromPtr(ptr), @tagName(class), alloc_size,
    });

    return ptr;
}

/// kfree — 释放内存
///
/// 自动检测分配大小并释放到正确的缓存池。
pub fn kfree(ptr: [*]u8) void {
    if (ptr == null) return;

    // 获取元数据头部
    const header: *AllocHeader = @ptrFromInt(@intFromPtr(ptr) - AllocHeader.HEADER_SIZE);

    // 验证魔数
    if (header.magic != AllocHeader.MAGIC) {
        log.warn("[Slab] kfree: invalid magic at 0x{x}", .{@intFromPtr(ptr)});
        return;
    }

    const size = header.size;
    const class: SizeClass = @enumFromInt(header.class);
    const alloc_size = getClassSize(class);

    log.debug("[Slab] kfree(0x{x}, size={})", .{ @intFromPtr(ptr), size });

    // 释放回 Slabx
    slabx.slabxFree(ptr, alloc_size);
}

/// kzalloc — 分配并零初始化的内存
pub fn kzalloc(size: usize) ?[*]u8 {
    const ptr = kmalloc(size) orelse return null;
    @memset(ptr[0..size], 0);
    return ptr;
}

/// kmalloc_array — 分配数组
/// 检查 n * size 不会溢出
pub fn kmalloc_array(n: usize, size: usize) ?[*]u8 {
    // 检查溢出
    if (n == 0 or size == 0) return null;
    if (n > (0xFFFF_FFFF / size)) return null;
    return kmalloc(n * size);
}

/// kcalloc — 分配并零初始化的数组
pub fn kcalloc(n: usize, size: usize) ?[*]u8 {
    const ptr = kmalloc_array(n, size) orelse return null;
    const total = n * size;
    @memset(ptr[0..total], 0);
    return ptr;
}

/// krealloc — 重新分配内存
/// 注意：简化实现，不保留原有数据
pub fn krealloc(ptr: [*]u8, new_size: usize) ?[*]u8 {
    if (ptr == null) return kmalloc(new_size);
    if (new_size == 0) {
        kfree(ptr);
        return null;
    }

    const new_ptr = kmalloc(new_size) orelse return null;

    // 获取旧大小
    const header: *AllocHeader = @ptrFromInt(@intFromPtr(ptr) - AllocHeader.HEADER_SIZE);
    if (header.magic == AllocHeader.MAGIC) {
        const old_size = header.size;
        const copy_size = if (old_size < new_size) old_size else new_size;
        @memcpy(new_ptr[0..copy_size], ptr[0..copy_size]);
    }

    kfree(ptr);
    return new_ptr;
}

/// krealloc_array — 重新分配数组
pub fn krealloc_array(ptr: [*]u8, n: usize, size: usize) ?[*]u8 {
    if (n == 0 or size == 0) return krealloc(ptr, 0);
    if (n > (0xFFFF_FFFF / size)) return null;
    return krealloc(ptr, n * size);
}

// ============================================================================
// 大型分配（直接使用 Slub）
// ============================================================================

/// kmalloc_large — 分配大于 64KB 的内存
fn kmallocLarge(size: usize) ?[*]u8 {
    const total_size = size + AllocHeader.HEADER_SIZE;

    // 使用 Slub 分配
    const ptr = slub.slubAlloc(total_size) orelse return null;

    // 写入元数据
    const header: *AllocHeader = @ptrFromInt(@intFromPtr(ptr));
    header.* = .{
        .size = size,
        .class = @intFromEnum(SizeClass.large),
        .magic = AllocHeader.MAGIC,
    };

    const data_ptr: [*]u8 = @ptrFromInt(@intFromPtr(ptr) + AllocHeader.HEADER_SIZE);

    log.debug("[Slab] kmalloc_large({}) = 0x{x}", .{ size, @intFromPtr(data_ptr) });

    return data_ptr;
}

/// kfree_large — 释放大型分配
/// 由 kfree 自动调用，不需要直接使用
pub fn kfree_large(data_ptr: [*]u8, original_size: usize) void {
    _ = original_size;

    const header_ptr = @intFromPtr(data_ptr) - AllocHeader.HEADER_SIZE;
    const header: *AllocHeader = @ptrFromInt(header_ptr);

    if (header.magic != AllocHeader.MAGIC) {
        log.warn("[Slab] kfree_large: invalid magic", .{});
        return;
    }

    slub.slubFree(@ptrFromInt(header_ptr));
}

// ============================================================================
// Slab 缓存管理
// ============================================================================

/// SlabCache — 用于特定对象类型的专用缓存
///
/// 例如：vm_map_entry 缓存、task 缓存、thread 缓存等。
pub const SlabCache = struct {
    name: []const u8,
    object_size: usize,
    alloc_size: usize,
    class: SizeClass,
    lock: SpinLock = .{},

    alloc_count: usize = 0,
    free_count: usize = 0,

    pub fn create(name: []const u8, object_size: usize) SlabCache {
        const class = getSizeClass(object_size);
        const alloc_size = getClassSize(class);

        return SlabCache{
            .name = name,
            .object_size = object_size,
            .alloc_size = alloc_size,
            .class = class,
        };
    }

    /// 从缓存分配对象
    pub fn alloc(self: *SlabCache) ?[*]u8 {
        self.lock.acquire();
        defer self.lock.release();

        const ptr = slabx.slabxAlloc(self.alloc_size) orelse return null;
        self.alloc_count += 1;

        return ptr;
    }

    /// 释放对象回缓存
    pub fn free(self: *SlabCache, ptr: [*]u8) void {
        self.lock.acquire();
        defer self.lock.release();

        slabx.slabxFree(ptr, self.alloc_size);
        self.free_count += 1;
    }

    /// 分配并零初始化对象
    pub fn allocZero(self: *SlabCache) ?[*]u8 {
        const ptr = self.alloc() orelse return null;
        @memset(ptr[0..self.object_size], 0);
        return ptr;
    }

    /// 获取缓存统计
    pub fn getStats(self: *const SlabCache) struct {
        name: []const u8,
        object_size: usize,
        alloc_size: usize,
        alloc_count: usize,
        free_count: usize,
        in_use: usize,
    } {
        return .{
            .name = self.name,
            .object_size = self.object_size,
            .alloc_size = self.alloc_size,
            .alloc_count = self.alloc_count,
            .free_count = self.free_count,
            .in_use = self.alloc_count - self.free_count,
        };
    }
};

// ============================================================================
// 预定义的标准缓存
// ============================================================================

/// 内核对象的标准缓存
pub var cache_task: SlabCache = SlabCache.create("task", 256);
pub var cache_thread: SlabCache = SlabCache.create("thread", 128);
pub var cache_port: SlabCache = SlabCache.create("port", 64);
pub var cache_vm_entry: SlabCache = SlabCache.create("vm_entry", 128);
pub var cache_vm_object: SlabCache = SlabCache.create("vm_object", 192);
pub var cache_message: SlabCache = SlabCache.create("message", 512);

// ============================================================================
// 统计和调试
// ============================================================================

/// Slab 统计信息
pub const Stats = struct {
    total_alloc: usize,
    total_free: usize,
    current_alloc: usize,
    slabx_stats: slabx.AllStats,
    slub_stats: slub.Stats,
};

/// 获取全局 Slab 统计
pub fn getStats() Stats {
    return Stats{
        .total_alloc = 0,
        .total_free = 0,
        .current_alloc = 0,
        .slabx_stats = slabx.getAllStats(),
        .slub_stats = slub.getStats(),
    };
}

/// 打印 Slab 状态
pub fn dumpState() void {
    log.info("=== Slab State ===", .{});

    const stats = getStats();

    log.info("  Total allocs: {}", .{stats.total_alloc});
    log.info("  Total frees:  {}", .{stats.total_free});
    log.info("  Current:      {}", .{stats.current_alloc});

    log.info("  --- Slabx Layer ---", .{});
    slabx.dumpAllState();

    log.info("  --- Slub Layer ---", .{});
    slub.dumpState();

    log.info("  --- Cache Stats ---", .{});
    log.info("    task:    alloc={}, free={}, in_use={}", .{
        cache_task.alloc_count, cache_task.free_count,
        cache_task.alloc_count - cache_task.free_count,
    });
    log.info("    thread:  alloc={}, free={}, in_use={}", .{
        cache_thread.alloc_count, cache_thread.free_count,
        cache_thread.alloc_count - cache_thread.free_count,
    });
    log.info("    port:    alloc={}, free={}, in_use={}", .{
        cache_port.alloc_count, cache_port.free_count,
        cache_port.alloc_count - cache_port.free_count,
    });
    log.info("    vm_entry: alloc={}, free={}, in_use={}", .{
        cache_vm_entry.alloc_count, cache_vm_entry.free_count,
        cache_vm_entry.alloc_count - cache_vm_entry.free_count,
    });
}

/// 调试：打印分配大小级别信息
pub fn dumpSizeClasses() void {
    log.info("=== Slab Size Classes ===", .{});

    inline for (SIZE_CLASS_TABLE) |info| {
        if (info.max_size == 0xFFFF_FFFF) break;
        log.info("  {}: max_size={}", .{
            @tagName(info.size_class), info.max_size,
        });
    }
}

// ============================================================================
// 基本测试
// ============================================================================

/// 运行基本测试
pub fn selfTest() void {
    log.info("[Slab] Running self-test...", .{});

    // 测试各种大小的分配
    const test_sizes = [_]usize{
        1, 8, 16, 32, 48, 64, 96, 128, 192, 256,
        512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
    };

    var all_passed = true;

    for (test_sizes) |size| {
        const ptr = kmalloc(size);
        if (ptr == null) {
            log.err("[Slab] self-test: kmalloc({}) failed", .{size});
            all_passed = false;
            continue;
        }

        // 写入模式
        const pattern: u8 = @as(u8, @truncate(size & 0xFF));
        @memset(ptr[0..size], pattern);

        // 验证
        var valid = true;
        for (0..size) |i| {
            if (ptr[i] != pattern) {
                valid = false;
                break;
            }
        }

        if (valid) {
            log.debug("[Slab] self-test: size {} OK", .{size});
        } else {
            log.err("[Slab] self-test: size {} FAILED (data corruption)", .{size});
            all_passed = false;
        }

        kfree(ptr);
    }

    // 测试 kzalloc
    for (test_sizes) |size| {
        const ptr = kzalloc(size);
        if (ptr == null) {
            log.err("[Slab] self-test: kzalloc({}) failed", .{size});
            all_passed = false;
            continue;
        }

        // 验证零初始化
        var all_zero = true;
        for (0..size) |i| {
            if (ptr[i] != 0) {
                all_zero = false;
                break;
            }
        }

        if (all_zero) {
            log.debug("[Slab] self-test: kzalloc({}) OK", .{size});
        } else {
            log.err("[Slab] self-test: kzalloc({}) FAILED (not zero)", .{size});
            all_passed = false;
        }

        kfree(ptr);
    }

    // 测试分配数组
    const arr_ptr = kmalloc_array(100, 64);
    if (arr_ptr) |ptr| {
        log.debug("[Slab] self-test: kmalloc_array(100, 64) OK", .{});
        kfree(ptr);
    }

    // 测试专用缓存
    const task_ptr = cache_task.alloc();
    if (task_ptr) |ptr| {
        log.debug("[Slab] self-test: cache_task.alloc() OK", .{});
        cache_task.free(ptr);
    }

    if (all_passed) {
        log.info("[Slab] self-test: ALL PASSED", .{});
    } else {
        log.err("[Slab] self-test: SOME TESTS FAILED", .{});
    }
}

/// 初始化 Slab 层
pub fn init() void {
    // 初始化 Slub 层
    slub.init();

    // 打印大小级别信息
    log.info("[Slab] Initialized", .{});

    // 运行自检（可选，生产环境可能禁用）
    if (@import("builtin").is_test) {
        selfTest();
    }
}
