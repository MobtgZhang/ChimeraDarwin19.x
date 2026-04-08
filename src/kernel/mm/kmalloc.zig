/// kmalloc — 内核动态内存分配公共接口。
///
/// 这是内核内存分配的顶层模块，提供统一的分配 API 和管理功能。
///
/// 职责：
///   - 提供统一的 kmalloc/kfree/kzalloc/krealloc 接口
///   - 管理 OOM (Out Of Memory) 处理策略
///   - 提供分配统计和调试功能
///   - 提供溢出检测和安全检查
///
/// 架构层次：
///   kmalloc/kfree (用户接口) ← 本文件
///       ↓
///   Slab (对象缓存层)
///       ↓
///   Slabx (per-CPU 缓存层)
///       ↓
///   Slub (底层页框分配)
///       ↓
///   PMM (物理内存 bitmap)

const slab = @import("slab.zig");
const slub = @import("slub.zig");
const slabx = @import("slabx.zig");
const pmm = @import("pmm.zig");
const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;

// ============================================================================
// OOM 策略管理
// ============================================================================

/// OOM (Out Of Memory) 处理策略
pub const OOMPolicy = enum(u8) {
    /// 返回 null（默认）
    ReturnNull = 0,
    /// 内核 panic
    Panic = 1,
    /// 尝试驱逐页面后再返回
    TryEvict = 2,
};

var current_oom_policy: OOMPolicy = .ReturnNull;
var oom_policy_lock: SpinLock = .{};

/// 设置 OOM 策略
pub fn setOOMPolicy(policy: OOMPolicy) void {
    oom_policy_lock.acquire();
    defer oom_policy_lock.release();
    current_oom_policy = policy;
}

/// 获取当前 OOM 策略
pub fn getOOMPolicy() OOMPolicy {
    oom_policy_lock.acquire();
    defer oom_policy_lock.release();
    return current_oom_policy;
}

/// OOM 发生时的处理
fn handleOOM(comptime alloc_type: []const u8, size: usize) void {
    const policy = getOOMPolicy();

    switch (policy) {
        .ReturnNull => {
            log.warn("[kmalloc] {}: out of memory (size={})", .{ alloc_type, size });
        },
        .Panic => {
            log.err("[kmalloc] {}: out of memory (size={}), panicking", .{ alloc_type, size });
            @panic("[kmalloc] Out of memory");
        },
        .TryEvict => {
            log.warn("[kmalloc] {}: attempting page eviction for size={}", .{ alloc_type, size });

            // 尝试驱逐页面
            var evicted: usize = 0;
            var attempts: usize = 0;
            const max_attempts = 16;

            while (attempts < max_attempts) : (attempts += 1) {
                if (pmm.evictPage()) {
                    evicted += 1;
                    if (evicted >= 4) {
                        log.info("[kmalloc] Successfully evicted {} pages", .{evicted});
                        return;
                    }
                }
            }

            log.err("[kmalloc] Failed to evict enough pages (evicted={}/4)", .{evicted});

            if (getOOMPolicy() == .Panic) {
                @panic("[kmalloc] Out of memory after eviction");
            }
        },
    }
}

// ============================================================================
// 分配函数
// ============================================================================

/// kmalloc — 分配内存
///
/// 参数：
///   size - 请求的字节数
///
/// 返回：
///   分配的内存指针，或 null（如果分配失败且 OOM 策略为 ReturnNull）
pub fn kmalloc(size: usize) ?[*]u8 {
    if (size == 0) return null;

    // 检查溢出
    if (!checkAllocationSize(size)) {
        log.err("[kmalloc] Invalid allocation size: {}", .{size});
        return null;
    }

    const ptr = slab.kmalloc(size);

    if (ptr == null) {
        handleOOM("kmalloc", size);
        return null;
    }

    return ptr;
}

/// kfree — 释放内存
pub fn kfree(ptr: [*]u8) void {
    slab.kfree(ptr);
}

/// kzalloc — 分配并零初始化的内存
pub fn kzalloc(size: usize) ?[*]u8 {
    if (size == 0) return null;

    if (!checkAllocationSize(size)) {
        return null;
    }

    const ptr = slab.kzalloc(size);

    if (ptr == null) {
        handleOOM("kzalloc", size);
        return null;
    }

    return ptr;
}

/// kmalloc_array — 分配数组
///
/// 检查 n * size 不会溢出。
pub fn kmalloc_array(n: usize, size: usize) ?[*]u8 {
    if (n == 0 or size == 0) return null;

    if (!checkArrayAllocation(n, size)) {
        log.err("[kmalloc] kmalloc_array overflow: {} * {}", .{ n, size });
        return null;
    }

    const total = n * size;
    const ptr = slab.kmalloc_array(n, size);

    if (ptr == null) {
        handleOOM("kmalloc_array", total);
        return null;
    }

    return ptr;
}

/// kcalloc — 分配并零初始化的数组
pub fn kcalloc(n: usize, size: usize) ?[*]u8 {
    if (n == 0 or size == 0) return null;

    if (!checkArrayAllocation(n, size)) {
        return null;
    }

    const ptr = slab.kcalloc(n, size);

    if (ptr == null) {
        handleOOM("kcalloc", n * size);
        return null;
    }

    return ptr;
}

/// krealloc — 重新分配内存
pub fn krealloc(ptr: [*]u8, new_size: usize) ?[*]u8 {
    if (new_size == 0) {
        if (ptr != null) kfree(ptr);
        return null;
    }

    if (!checkAllocationSize(new_size)) {
        return null;
    }

    const new_ptr = slab.krealloc(ptr, new_size);

    if (new_ptr == null and ptr != null) {
        handleOOM("krealloc", new_size);
        return null;
    }

    return new_ptr;
}

/// krealloc_array — 重新分配数组
pub fn krealloc_array(ptr: [*]u8, n: usize, size: usize) ?[*]u8 {
    if (n == 0 or size == 0) {
        if (ptr != null) kfree(ptr);
        return null;
    }

    if (!checkArrayAllocation(n, size)) {
        return null;
    }

    const new_ptr = slab.krealloc_array(ptr, n, size);

    if (new_ptr == null and ptr != null) {
        handleOOM("krealloc_array", n * size);
        return null;
    }

    return new_ptr;
}

// ============================================================================
// 溢出检测
// ============================================================================

/// 检查分配大小是否有效
fn checkAllocationSize(size: usize) bool {
    // 最大分配大小：256MB
    const MAX_ALLOC_SIZE = 256 * 1024 * 1024;

    if (size == 0) return false;
    if (size > MAX_ALLOC_SIZE) return false;

    return true;
}

/// 检查数组分配是否会导致溢出
fn checkArrayAllocation(n: usize, size: usize) bool {
    // 检查 n * size 是否会溢出
    if (n == 0 or size == 0) return false;

    // 简单的溢出检查：n * size > max_val 表示溢出
    const max_val = (@as(u64, 1) << 63) - 1;
    const result = @as(u128, n) * @as(u128, size);

    if (result > max_val) return false;

    // 超过最大分配大小
    if (result > 256 * 1024 * 1024) return false;

    return true;
}

// ============================================================================
// 统计信息
// ============================================================================

/// 全局分配统计
var total_alloc_bytes: u64 = 0;
var total_alloc_count: u64 = 0;
var total_free_count: u64 = 0;
var peak_alloc_bytes: u64 = 0;
var current_alloc_bytes: u64 = 0;
var stats_lock: SpinLock = .{};

/// 记录一次分配
fn recordAlloc(size: usize) void {
    stats_lock.acquire();
    defer stats_lock.release();

    total_alloc_count += 1;
    total_alloc_bytes += @as(u64, @intCast(size));
    current_alloc_bytes += @as(u64, @intCast(size));

    if (current_alloc_bytes > peak_alloc_bytes) {
        peak_alloc_bytes = current_alloc_bytes;
    }
}

/// 记录一次释放
fn recordFree(size: usize) void {
    stats_lock.acquire();
    defer stats_lock.release();

    total_free_count += 1;
    current_alloc_bytes -|= @as(u64, @intCast(@min(size, current_alloc_bytes)));
}

/// 内存统计信息
pub const MemoryStats = struct {
    total_alloc_bytes: u64,
    total_alloc_count: u64,
    total_free_count: u64,
    peak_alloc_bytes: u64,
    current_alloc_bytes: u64,
    current_alloc_count: u64,
    slabx_stats: slabx.AllStats,
    slub_stats: slub.Stats,
    pmm_stats: pmm.PMMStats,
};

/// 获取内存统计信息
pub fn getMemoryStats() MemoryStats {
    stats_lock.acquire();
    defer stats_lock.release();

    return MemoryStats{
        .total_alloc_bytes = total_alloc_bytes,
        .total_alloc_count = total_alloc_count,
        .total_free_count = total_free_count,
        .peak_alloc_bytes = peak_alloc_bytes,
        .current_alloc_bytes = current_alloc_bytes,
        .current_alloc_count = total_alloc_count - total_free_count,
        .slabx_stats = slabx.getAllStats(),
        .slub_stats = slub.getStats(),
        .pmm_stats = pmm.getStats(),
    };
}

/// 打印内存统计
pub fn dumpStats() void {
    const stats = getMemoryStats();

    log.info("=== Kernel Memory Statistics ===", .{});
    log.info("  Total allocated: {} bytes ({} allocations)", .{
        stats.total_alloc_bytes, stats.total_alloc_count,
    });
    log.info("  Total freed:     {} allocations", .{stats.total_free_count});
    log.info("  Current:         {} bytes ({} allocations)", .{
        stats.current_alloc_bytes, stats.current_alloc_count,
    });
    log.info("  Peak:            {} bytes", .{stats.peak_alloc_bytes});
    log.info("  Memory usage:    {:.2}%", .{
        if (stats.pmm_stats.total_pages > 0)
            @as(f64, @floatFromInt(stats.current_alloc_bytes)) * 100.0 / @as(f64, @floatFromInt(stats.pmm_stats.total_pages * 4096))
        else
            0.0,
    });

    log.info("  PMM: total={}, allocated={}, free={} pages", .{
        stats.pmm_stats.total_pages,
        stats.pmm_stats.allocated_pages,
        stats.pmm_stats.free_pages,
    });
}

// ============================================================================
// 内存压力检测
// ============================================================================

/// 获取内存压力级别
pub fn getMemoryPressure() f64 {
    const stats = pmm.getMemoryPressure();
    return stats;
}

/// 检查内存是否即将耗尽
pub fn isMemoryLow() bool {
    const free_pages = pmm.freePageCount();
    const total_pages = pmm.totalPageCount();

    // 如果可用页面少于 5%，认为内存不足
    if (total_pages == 0) return false;

    const free_ratio = @as(f64, @floatFromInt(free_pages)) / @as(f64, @floatFromInt(total_pages));
    return free_ratio < 0.05;
}

/// 检查是否可以安全分配指定大小的内存
pub fn canAllocate(size: usize) bool {
    if (size == 0) return true;

    // 简单检查：可用页面是否足够
    const page_size: usize = 4096;
    const pages_needed = (size + page_size - 1) / page_size;

    return pmm.freePageCount() > pages_needed;
}

// ============================================================================
// 调试功能
// ============================================================================

/// 打印详细的内存状态
pub fn dumpMemoryState() void {
    log.info("=== Kernel Memory State ===", .{});

    const stats = getMemoryStats();

    // 基本统计
    dumpStats();

    // Slabx 层
    log.info("--- Slabx Layer ---", .{});
    slabx.dumpAllState();

    // Slub 层
    log.info("--- Slub Layer ---", .{});
    slub.dumpState();

    // PMM 层
    log.info("--- PMM Layer ---", .{});
    pmm.dumpState();

    // 大小级别
    slab.dumpSizeClasses();
}

/// 内存完整性检查
pub fn integrityCheck() bool {
    log.info("[kmalloc] Running integrity check...", .{});

    var passed = true;

    // 检查统计一致性
    const stats = getMemoryStats();
    if (stats.current_alloc_bytes > stats.peak_alloc_bytes) {
        log.err("[kmalloc] Integrity check FAILED: current > peak", .{});
        passed = false;
    }

    if (stats.current_alloc_count > stats.total_alloc_count) {
        log.err("[kmalloc] Integrity check FAILED: current_alloc_count > total", .{});
        passed = false;
    }

    if (passed) {
        log.info("[kmalloc] Integrity check PASSED", .{});
    }

    return passed;
}

/// 尝试回收内存（主动垃圾回收）
pub fn tryReclaimMemory() void {
    log.info("[kmalloc] Attempting memory reclaim...", .{});

    // 驱逐页面
    var reclaimed: usize = 0;
    var attempts: usize = 0;
    const max_attempts = 32;

    while (attempts < max_attempts) : (attempts += 1) {
        if (pmm.evictPage()) {
            reclaimed += 1;
        }
    }

    if (reclaimed > 0) {
        log.info("[kmalloc] Reclaimed {} pages", .{reclaimed});
    } else {
        log.info("[kmalloc] No pages could be reclaimed", .{});
    }
}

// ============================================================================
// 内存分配标记（用于调试追踪）
// ============================================================================

/// 分配标记，用于追踪内存来源
pub const AllocTag = struct {
    file: []const u8,
    line: u32,
    func: []const u8,
};

/// 带标记的分配（调试用）
pub fn kmallocTagged(comptime file: []const u8, comptime line: u32, comptime func: []const u8, size: usize) ?[*]u8 {
    const ptr = kmalloc(size);
    if (ptr) |p| {
        log.debug("[kmalloc] {}:{} in {}: allocated {} bytes at 0x{x}", .{
            file, line, func, size, @intFromPtr(p),
        });
    }
    return ptr;
}

/// 带标记的释放（调试用）
pub fn kfreeTagged(comptime file: []const u8, comptime line: u32, comptime func: []const u8, ptr: [*]u8) void {
    log.debug("[kmalloc] {}:{} in {}: freeing 0x{x}", .{
        file, line, func, @intFromPtr(ptr),
    });
    kfree(ptr);
}

// ============================================================================
// 初始化
// ============================================================================

/// 初始化 kmalloc 子系统
pub fn init() void {
    log.info("[kmalloc] Initializing kmalloc subsystem...", .{});

    // 初始化底层分配器
    slab.init();

    // 设置默认 OOM 策略
    setOOMPolicy(.ReturnNull);

    // 打印初始状态
    const stats = getMemoryStats();
    log.info("[kmalloc] Initial stats: total_pages={}, free_pages={}", .{
        stats.pmm_stats.total_pages,
        stats.pmm_stats.free_pages,
    });

    log.info("[kmalloc] kmalloc subsystem initialized", .{});
}

/// 基本测试
pub fn selfTest() void {
    log.info("[kmalloc] Running self-test...", .{});

    var passed = true;

    // 测试基本分配
    const ptr1 = kmalloc(64);
    if (ptr1 == null) {
        log.err("[kmalloc] self-test: kmalloc(64) failed", .{});
        passed = false;
    } else {
        @memset(ptr1.?, 0xAA);
        kfree(ptr1.?);
        log.debug("[kmalloc] self-test: kmalloc/kfree OK", .{});
    }

    // 测试 kzalloc
    const ptr2 = kzalloc(128);
    if (ptr2 == null) {
        log.err("[kmalloc] self-test: kzalloc(128) failed", .{});
        passed = false;
    } else {
        var valid = true;
        for (0..128) |i| {
            if (ptr2.?[i] != 0) {
                valid = false;
                break;
            }
        }
        if (valid) {
            log.debug("[kmalloc] self-test: kzalloc OK", .{});
        } else {
            log.err("[kmalloc] self-test: kzalloc FAILED (not zero)", .{});
            passed = false;
        }
        kfree(ptr2.?);
    }

    // 测试 kmalloc_array
    const ptr3 = kmalloc_array(50, 8);
    if (ptr3 == null) {
        log.err("[kmalloc] self-test: kmalloc_array(50, 8) failed", .{});
        passed = false;
    } else {
        log.debug("[kmalloc] self-test: kmalloc_array OK", .{});
        kfree(ptr3.?);
    }

    // 测试溢出检测
    const overflow_check = checkArrayAllocation(0x8000_0000, 0x8000_0000);
    if (!overflow_check) {
        log.debug("[kmalloc] self-test: overflow detection OK", .{});
    } else {
        log.err("[kmalloc] self-test: overflow detection FAILED", .{});
        passed = false;
    }

    // 完整性检查
    if (integrityCheck()) {
        log.debug("[kmalloc] self-test: integrity check OK", .{});
    } else {
        passed = false;
    }

    if (passed) {
        log.info("[kmalloc] self-test: ALL PASSED", .{});
    } else {
        log.err("[kmalloc] self-test: SOME TESTS FAILED", .{});
    }
}

// ============================================================================
// 便捷宏（编译时辅助）
// ============================================================================

/// 编译时大小检查
comptime {
    // 验证分配器结构体大小合理
    const header_size = @sizeOf(slab.AllocHeader);
    if (header_size > 64) {
        @compileError("AllocHeader too large: " ++ @typeName(@TypeOf(header_size)));
    }
}

/// 编译时常量
pub const MIN_ALIGN: usize = 8;
pub const MAX_ALLOC_SIZE: usize = 256 * 1024 * 1024; // 256MB
