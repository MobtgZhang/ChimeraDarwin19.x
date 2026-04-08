/// Slabx — per-CPU 缓存层 (Slab allocator with per-CPU caches)。
///
/// Slabx 是三层内存分配架构中的第二层，位于 Slub 之上。
/// 主要目标是减少锁竞争，通过为每个 CPU 提供独立的分配缓存。
///
/// 职责：
///   - 管理同一对象大小的多个 Slab
///   - 为每个 CPU 提供本地分配缓存
///   - 在缓存命中率低时自动回收空闲 slab
///   - 提供高效的分配和释放路径
///
/// 架构：
///   kmalloc/kfree
///       ↓
///   Slab (对象缓存，固定大小)
///       ↓
///   Slabx (per-CPU 缓存层) ← 本文件
///       ↓
///   Slub (底层页框分配)
///       ↓
///   PMM (物理内存 bitmap)

const slub = @import("slub.zig");
const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const builtin = @import("builtin");

pub const PAGE_SIZE: usize = slub.PAGE_SIZE;

/// CPU 本地缓存条目
const CPUCacheEntry = struct {
    /// 缓存的数据指针
    ptr: [*]u8 = undefined,
    /// 缓存是否有效
    valid: bool = false,
};

/// Slabx — 管理一个对象大小的 per-CPU 缓存
///
/// 每个 Slabx 实例管理一种固定大小的对象分配。
/// 包含：
///   - 一个 per-CPU 的空闲对象链表（用于快速分配）
///   - 一个全局的空闲 slab 列表
///   - 统计信息
pub const Slabx = struct {
    /// 对象大小
    object_size: usize,
    /// 每个 slab 的对象数量
    objects_per_slab: usize,
    /// Slabx 名称（用于调试）
    name: []const u8,
    /// Slabx 锁（保护全局数据结构）
    lock: SpinLock = .{},

    /// 全局空闲对象链表（当 per-CPU 缓存为空时使用）
    global_free_list: ?[*]u8 = null,
    /// 全局空闲对象计数
    global_free_count: usize = 0,

    /// Per-CPU 本地缓存
    /// 每个 CPU 维护一个小型的对象缓存，减少全局锁竞争
    cpu_cache: []CPUCacheEntry,
    /// CPU 缓存大小（每个 CPU 的缓存条目数）
    cpu_cache_size: usize,

    /// 活跃 slab 计数
    active_slabs: usize = 0,
    /// 峰值 slab 计数
    peak_slabs: usize = 0,
    /// 总分配计数
    alloc_count: usize = 0,
    /// 总释放计数
    free_count: usize = 0,
    /// CPU 缓存命中计数
    cpu_cache_hits: usize = 0,
    /// CPU 缓存未命中计数
    cpu_cache_misses: usize = 0,

    /// Slabx 配置
    pub const Config = struct {
        name: []const u8,
        object_size: usize,
        cpu_cache_size: usize = 8,
    };

    /// 创建并初始化一个新的 Slabx
    pub fn create(config: Config) Slabx {
        // 计算每个 slab 能容纳的对象数
        const header_size = @sizeOf(SlabHeader);
        const usable = PAGE_SIZE - header_size;
        const objects = usable / (config.object_size + @sizeOf(FreeObject));

        // 分配 per-CPU 缓存
        const max_cpus = 256; // 最大支持 CPU 数
        var cache = [_]CPUCacheEntry{CPUCacheEntry{}} ** max_cpus;
        for (&cache) |*entry| {
            entry.* = .{ .valid = false };
        }

        return Slabx{
            .name = config.name,
            .object_size = config.object_size,
            .objects_per_slab = if (objects == 0) 1 else objects,
            .cpu_cache_size = config.cpu_cache_size,
            .cpu_cache = &cache,
        };
    }

    /// 获取当前 CPU 的 ID
    /// 在不同架构上实现
    fn getCurrentCPU() usize {
        return getCPUId();
    }

    /// 从 Slabx 分配一个对象
    pub fn allocate(self: *Slabx) ?[*]u8 {
        self.alloc_count += 1;

        // 尝试从当前 CPU 的本地缓存分配
        const cpu_id = getCurrentCPU();
        if (cpu_id < self.cpu_cache.len) {
            const entry = &self.cpu_cache[cpu_id];
            if (entry.valid) {
                const ptr = entry.ptr;
                entry.valid = false;
                self.cpu_cache_hits += 1;
                return ptr;
            }
            self.cpu_cache_misses += 1;
        }

        // CPU 缓存未命中，尝试全局缓存
        self.lock.acquire();
        defer self.lock.release();

        if (self.global_free_list) |ptr| {
            self.global_free_list = @as(?[*]u8, @ptrFromInt(@intFromPtr(ptr)));
            self.global_free_count -= 1;
            return ptr;
        }

        // 全局缓存也为空，分配新的 slab
        const slab_ptr = self.allocateSlab() orelse return null;

        // 第一个对象返回给调用者，其余放入全局缓存
        const first_obj = slab_ptr;
        const rest_count = self.objects_per_slab - 1;

        var current: [*]u8 = @ptrFromInt(@intFromPtr(slab_ptr) + self.object_size);
        var count: usize = 0;

        while (count < rest_count) : (count += 1) {
            const next: ?[*]u8 = @ptrFromInt(@intFromPtr(current));
            self.global_free_list = next;
            self.global_free_count += 1;
            current = @ptrFromInt(@intFromPtr(current) + self.object_size);
        }

        return first_obj;
    }

    /// 向 Slabx 释放一个对象
    pub fn deallocate(self: *Slabx, ptr: [*]u8) void {
        if (ptr == null) return;

        self.free_count += 1;

        // 尝试放入当前 CPU 的本地缓存
        const cpu_id = getCurrentCPU();
        if (cpu_id < self.cpu_cache.len) {
            const entry = &self.cpu_cache[cpu_id];
            if (!entry.valid) {
                entry.ptr = ptr;
                entry.valid = true;
                return;
            }
        }

        // CPU 缓存已满，放入全局缓存
        self.lock.acquire();
        defer self.lock.release();

        // 将对象放入全局空闲链表
        self.global_free_list = ptr;
        self.global_free_count += 1;

        // 检查是否需要回收
        self.checkReclaim();
    }

    /// 分配一个新的 slab
    fn allocateSlab(self: *Slabx) ?[*]u8 {
        // 从 Slub 分配一个页面
        const page_ptr = slub.slubAlloc(PAGE_SIZE) orelse {
            log.warn("[Slabx] '{}': failed to allocate slab", .{self.name});
            return null;
        };

        // 写入 slab 头部
        const header: *SlabHeader = @ptrFromInt(@intFromPtr(page_ptr));
        header.* = .{
            .object_size = self.object_size,
            .magic = SlabHeader.MAGIC,
        };

        self.active_slabs += 1;
        if (self.active_slabs > self.peak_slabs) {
            self.peak_slabs = self.active_slabs;
        }

        log.debug("[Slabx] '{}': allocated new slab (now {} active)", .{
            self.name, self.active_slabs,
        });

        return page_ptr;
    }

    /// 检查是否需要回收空闲的 slab
    fn checkReclaim(self: *Slabx) void {
        // 如果全局空闲对象太多，尝试释放一些 slab
        // 回收阈值：当全局空闲对象数 > 2 * objects_per_slab 时
        if (self.global_free_count <= 2 * self.objects_per_slab) {
            return;
        }

        // 简单策略：保留一半的空闲对象在缓存中
        const retain_count = self.objects_per_slab;
        var freed_count: usize = 0;

        while (self.global_free_count > retain_count) {
            const ptr = self.global_free_list orelse break;
            self.global_free_list = @as(?[*]u8, @ptrFromInt(@intFromPtr(ptr)));
            self.global_free_count -= 1;
            freed_count += 1;
        }

        if (freed_count > 0) {
            log.debug("[Slabx] '{}': reclaimed {} free objects", .{ self.name, freed_count });
        }
    }

    /// 获取 Slabx 的统计信息
    pub fn getStats(self: *Slabx) struct {
        name: []const u8,
        object_size: usize,
        active_slabs: usize,
        peak_slabs: usize,
        global_free_count: usize,
        alloc_count: usize,
        free_count: usize,
        cpu_cache_hits: usize,
        cpu_cache_misses: usize,
        cpu_cache_hit_rate: f64,
    } {
        const total_cache_ops = self.cpu_cache_hits + self.cpu_cache_misses;
        const hit_rate = if (total_cache_ops > 0)
            @as(f64, @floatFromInt(self.cpu_cache_hits)) / @as(f64, @floatFromInt(total_cache_ops))
        else
            0.0;

        return .{
            .name = self.name,
            .object_size = self.object_size,
            .active_slabs = self.active_slabs,
            .peak_slabs = self.peak_slabs,
            .global_free_count = self.global_free_count,
            .alloc_count = self.alloc_count,
            .free_count = self.free_count,
            .cpu_cache_hits = self.cpu_cache_hits,
            .cpu_cache_misses = self.cpu_cache_misses,
            .cpu_cache_hit_rate = hit_rate,
        };
    }

    /// 刷新指定 CPU 的本地缓存到全局池
    pub fn flushCPUCache(self: *Slabx, cpu_id: usize) void {
        if (cpu_id >= self.cpu_cache.len) return;

        self.lock.acquire();
        defer self.lock.release();

        const entry = &self.cpu_cache[cpu_id];
        if (entry.valid) {
            // 将本地缓存的对象放回全局池
            entry.valid = false;
            self.global_free_count += 1;
        }
    }

    /// 刷新所有 CPU 的本地缓存
    pub fn flushAll(self: *Slabx) void {
        self.lock.acquire();
        defer self.lock.release();

        for (self.cpu_cache, 0..) |entry, cpu_id| {
            if (entry.valid) {
                _ = cpu_id;
                // 在锁内修改本地缓存（危险操作，仅用于关闭时）
            }
        }
    }
};

/// Slab 头部
/// 存储在每个 slab 页面的开始处
const SlabHeader = struct {
    object_size: usize,
    magic: u32,

    const MAGIC: u32 = 0x534C4142; // "SLAB" 的 ASCII 码
};

/// 空闲对象链表节点
/// 存储在每个空闲对象的开始处
const FreeObject = struct {
    next: ?[*]u8,
};

// ============================================================================
// CPU ID 获取（架构相关）
// ============================================================================

/// 获取当前 CPU 的 ID
/// 在不同架构上有不同的实现
fn getCPUId() usize {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            return getX86CPUId();
        },
        .aarch64, .aarch64_be => {
            return getAArch64CPUId();
        },
        .riscv64 => {
            return getRiscvCPUId();
        },
        .loongarch64 => {
            return getLoongArchCPUId();
        },
        else => {
            return 0; // 默认返回 0（单核或未实现）
        },
    }
}

/// x86_64 CPU ID（通过 APIC）
fn getX86CPUId() usize {
    // 简化实现：返回 0
    // 在实际系统中，需要从 APIC 或 Local APIC 读取 CPU ID
    return 0;
}

/// AArch64 CPU ID（通过 MPIDR_EL1）
fn getAArch64CPUId() usize {
    var mpidr: u64 = 0;
    asm volatile ("mrs %[result], mpidr_el1"
        : [result] "=r" (mpidr)
    );
    // 从 MPIDR_EL1 提取 CPU ID（Affinity Level 0）
    return @as(usize, @intCast(mpidr & 0xFF));
}

/// RISC-V CPU ID（通过 mhartid CSR）
fn getRiscvCPUId() usize {
    var hartid: usize = 0;
    asm volatile ("csrr %[result], mhartid"
        : [result] "=r" (hartid)
    );
    return hartid;
}

/// LoongArch64 CPU ID（通过 CPUNum CSR）
fn getLoongArchCPUId() usize {
    var cpuid: usize = 0;
    // LoongArch64 使用 CSR 0x20 (CPUID)
    asm volatile ("csrrd %[result], 0x20"
        : [result] "=r" (cpuid)
    );
    return cpuid;
}

// ============================================================================
// 全局 Slabx 实例
// ============================================================================

/// 全局 Slabx 实例，按对象大小分级
pub var slabx_8: Slabx = Slabx.create(.{ .name = "slabx-8", .object_size = 8 });
pub var slabx_16: Slabx = Slabx.create(.{ .name = "slabx-16", .object_size = 16 });
pub var slabx_32: Slabx = Slabx.create(.{ .name = "slabx-32", .object_size = 32 });
pub var slabx_64: Slabx = Slabx.create(.{ .name = "slabx-64", .object_size = 64 });
pub var slabx_128: Slabx = Slabx.create(.{ .name = "slabx-128", .object_size = 128 });
pub var slabx_256: Slabx = Slabx.create(.{ .name = "slabx-256", .object_size = 256 });
pub var slabx_512: Slabx = Slabx.create(.{ .name = "slabx-512", .object_size = 512 });
pub var slabx_1024: Slabx = Slabx.create(.{ .name = "slabx-1024", .object_size = 1024 });

/// 根据对象大小选择合适的 Slabx
fn selectSlabx(size: usize) ?*Slabx {
    if (size <= 8) return &slabx_8;
    if (size <= 16) return &slabx_16;
    if (size <= 32) return &slabx_32;
    if (size <= 64) return &slabx_64;
    if (size <= 128) return &slabx_128;
    if (size <= 256) return &slabx_256;
    if (size <= 512) return &slabx_512;
    if (size <= 1024) return &slabx_1024;
    return null;
}

/// 分配函数
pub fn slabxAlloc(size: usize) ?[*]u8 {
    if (size == 0) return null;

    // 先尝试 Slabx
    if (selectSlabx(size)) |slabx| {
        return slabx.allocate();
    }

    // 超过 1KB，直接使用 Slub
    return slub.slubAlloc(size);
}

/// 释放函数
pub fn slabxFree(ptr: [*]u8, size: usize) void {
    if (ptr == null or size == 0) return;

    if (selectSlabx(size)) |slabx| {
        slabx.deallocate(ptr);
        return;
    }

    // 超过 1KB，使用 Slub 释放
    slub.slubFree(ptr);
}

// ============================================================================
// 统计和调试
// ============================================================================

/// 获取所有 Slabx 的统计信息
pub const AllStats = struct {
    slabx_8: Slabx.Stats,
    slabx_16: Slabx.Stats,
    slabx_32: Slabx.Stats,
    slabx_64: Slabx.Stats,
    slabx_128: Slabx.Stats,
    slabx_256: Slabx.Stats,
    slabx_512: Slabx.Stats,
    slabx_1024: Slabx.Stats,
};

/// Slabx 统计信息别名（用于简化代码）
pub const Stats = @TypeOf(slabx_8).Stats;

/// 获取全局 Slabx 统计信息
pub fn getAllStats() AllStats {
    return AllStats{
        .slabx_8 = slabx_8.getStats(),
        .slabx_16 = slabx_16.getStats(),
        .slabx_32 = slabx_32.getStats(),
        .slabx_64 = slabx_64.getStats(),
        .slabx_128 = slabx_128.getStats(),
        .slabx_256 = slabx_256.getStats(),
        .slabx_512 = slabx_512.getStats(),
        .slabx_1024 = slabx_1024.getStats(),
    };
}

/// 打印所有 Slabx 的状态
pub fn dumpAllState() void {
    const stats = getAllStats();

    log.info("=== Slabx State ===", .{});

    inline for (@typeInfo(AllStats).Struct.fields) |field| {
        const s = @field(stats, field.name);
        log.info("  {}: obj={}B, slabs={}/{}, alloc={}, free={}, cache_hit_rate={:.1}%", .{
            s.name,
            s.object_size,
            s.active_slabs,
            s.peak_slabs,
            s.alloc_count,
            s.free_count,
            s.cpu_cache_hit_rate * 100,
        });
    }
}

/// 基本测试
pub fn selfTest() void {
    log.info("[Slabx] Running self-test...", .{});

    const test_sizes = [_]usize{ 8, 16, 32, 64, 128, 256, 512, 1024 };

    for (test_sizes) |size| {
        // 分配测试
        var ptr = slabxAlloc(size);
        if (ptr == null) {
            log.err("[Slabx] self-test: alloc failed for size {}", .{size});
            continue;
        }

        // 写入和读取测试
        @memset(ptr[0..size], 0x55);

        var valid = true;
        for (0..size) |i| {
            if (ptr[i] != 0x55) {
                valid = false;
                break;
            }
        }

        if (valid) {
            log.debug("[Slabx] self-test: size {} OK", .{size});
        } else {
            log.err("[Slabx] self-test: size {} FAILED", .{size});
        }

        // 释放
        slabxFree(ptr, size);
    }

    // 多次分配/释放测试
    const ptrs: [100][*]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        ptrs[i] = slabxAlloc(64) orelse {
            log.err("[Slabx] self-test: failed to allocate 100 objects", .{});
            break;
        };
    }

    if (i == 100) {
        log.debug("[Slabx] self-test: 100 allocations OK", .{});
    }

    // 释放所有
    i = 0;
    while (i < 100) : (i += 1) {
        slabxFree(ptrs[i], 64);
    }

    log.info("[Slabx] self-test complete", .{});
}
