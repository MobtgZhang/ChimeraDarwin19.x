/// Slub — 底层页框分配层 (Slab Layer Underneath Buddy)。
///
/// Slub 是内存管理架构中的最底层，直接与 PMM (物理内存管理器) 交互。
///
/// 职责：
///   - 管理物理页面的分配和释放
///   - 将大块内存分割为较小块供 Slabx 层使用
///   - 合并相邻的空闲块以减少碎片
///   - 提供页面级的分配原语
///
/// 架构层次：
///   kmalloc/kfree (用户接口)
///       ↓
///   Slab (对象缓存层)
///       ↓
///   Slabx (per-CPU 缓存层)
///       ↓
///   Slub (底层页框层) ← 本文件
///       ↓
///   PMM (物理内存管理器 bitmap)
///       ↓
///   硬件 (物理 RAM)

const pmm = @import("pmm.zig");
const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const builtin = @import("builtin");

pub const PAGE_SIZE: usize = pmm.PAGE_SIZE;

comptime {
    if (PAGE_SIZE != 4096 and PAGE_SIZE != 16384) {
        @compileError("Unsupported page size: " ++ @typeName(@TypeOf(PAGE_SIZE)));
    }
}

/// Slub 空闲块链表节点
/// 每个空闲块的开头存储指向下一个空闲块的指针
const FreeNode = struct {
    next: ?*FreeNode,
};

/// Slub 分配块的头部信息
/// 存储在每个分配块的开始处，用于追踪块大小和状态
const SlubBlockHeader = struct {
    /// 块的大小（以字节为单位）
    size: usize,
    /// 块的魔法数，用于验证指针有效性
    magic: u32,
    /// 块是否正在使用
    in_use: bool,

    const MAGIC: u32 = 0x534C5542; // "SLUB" 的 ASCII 码
};

/// Slub 分配器状态枚举
const State = enum {
    uninitialized,
    initialized,
    state_error,
};

/// Slub Arena — 管理一组物理页面的 Slub 分配器
///
/// 每个 Slub Arena 管理特定大小范围的分配请求。
/// Arena 从 PMM 请求页面，将页面分割为空闲块，并维护空闲链表。
pub const SlubArena = struct {
    /// Arena 管理的最小分配大小
    min_size: usize,
    /// Arena 管理的最大分配大小（单个块不超过此值）
    max_size: usize,
    /// Arena 锁，保护内部数据结构
    lock: SpinLock = .{},
    /// 状态
    state: State = .uninitialized,
    /// 全局空闲块链表
    free_list: ?*FreeNode = null,
    /// 当前管理的页面数
    page_count: usize = 0,
    /// 已分配的块数
    allocated_count: usize = 0,
    /// 已释放的块数
    freed_count: usize = 0,
    /// Arena 名称（用于调试）
    name: []const u8,

    /// Slub Arena 配置
    pub const Config = struct {
        name: []const u8,
        min_size: usize,
        max_size: usize,
    };

    /// 创建并初始化一个新的 Slub Arena
    pub fn create(config: Config) SlubArena {
        return SlubArena{
            .name = config.name,
            .min_size = config.min_size,
            .max_size = config.max_size,
            .state = .uninitialized,
        };
    }

    /// 初始化 Slub Arena
    pub fn init(self: *SlubArena) void {
        self.lock = .{};
        self.free_list = null;
        self.page_count = 0;
        self.allocated_count = 0;
        self.freed_count = 0;
        self.state = .initialized;
        log.debug("[Slub] Arena '{}' initialized (size range: {}-{} bytes)", .{
            self.name, self.min_size, self.max_size,
        });
    }

    /// 从 Arena 分配一个块
    /// 如果空闲链表为空，从 PMM 请求新页面
    pub fn alloc(self: *SlubArena, size: usize) ?[*]u8 {
        if (self.state != .initialized) {
            return null;
        }

        // 检查大小是否在 Arena 范围内
        if (size < self.min_size or size > self.max_size) {
            return null;
        }

        self.lock.acquire();
        defer self.lock.release();

        // 从空闲链表分配
        if (self.free_list) |node| {
            self.free_list = node.next;
            self.allocated_count += 1;

            // 写入头部信息
            const header: *SlubBlockHeader = @ptrFromInt(@intFromPtr(node));
            header.* = .{
                .size = size,
                .magic = SlubBlockHeader.MAGIC,
                .in_use = true,
            };

            const data_ptr: [*]u8 = @ptrFromInt(@intFromPtr(node) + @sizeOf(SlubBlockHeader));
            return data_ptr;
        }

        // 空闲链表为空，请求新页面
        const page_ptr = self.allocFromPmm(size) orelse return null;

        // 写入头部信息
        const header: *SlubBlockHeader = @ptrFromInt(@intFromPtr(page_ptr));
        header.* = .{
            .size = size,
            .magic = SlubBlockHeader.MAGIC,
            .in_use = true,
        };

        const data_ptr: [*]u8 = @ptrFromInt(@intFromPtr(page_ptr) + @sizeOf(SlubBlockHeader));
        return data_ptr;
    }

    /// 释放一个块
    pub fn free(self: *SlubArena, ptr: [*]u8) void {
        if (self.state != .initialized or ptr == null) {
            return;
        }

        // 获取头部信息
        const header_ptr: *SlubBlockHeader = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(SlubBlockHeader));

        // 验证魔法数
        if (header_ptr.magic != SlubBlockHeader.MAGIC) {
            log.warn("[Slub] free: invalid magic for ptr 0x{x}", .{@intFromPtr(ptr)});
            return;
        }

        // 验证块是否正在使用
        if (!header_ptr.in_use) {
            log.warn("[Slub] free: block already freed (double-free?)", .{});
            return;
        }

        self.lock.acquire();
        defer self.lock.release();

        // 标记为未使用
        header_ptr.in_use = false;

        // 将块放回空闲链表
        const node: *FreeNode = @ptrFromInt(@intFromPtr(header_ptr));
        node.next = self.free_list;
        self.free_list = node;

        self.freed_count += 1;

        // 尝试回收完全空闲的页面
        self.tryShrink();
    }

    /// 从 PMM 分配一个页面并分割为空闲块
    fn allocFromPmm(self: *SlubArena, obj_size: usize) ?[*]u8 {
        // 分配一个页面
        const page_idx = pmm.allocPage() orelse return null;
        self.page_count += 1;

        const page_phys = pmm.pageToPhysical(page_idx);

        // 转换为虚拟地址
        const page_virt = physToVirt(page_phys);

        // 计算块头部大小
        const header_size = @sizeOf(SlubBlockHeader);

        // 计算可以容纳的块数
        const usable = PAGE_SIZE - header_size;
        const block_size = obj_size + header_size;
        const block_count = usable / block_size;

        if (block_count == 0) {
            // 单个块太大，标记整个页面
            return @ptrFromInt(page_virt);
        }

        // 将页面分割为空闲块（除了第一个块返回给调用者，其余放入空闲链表）
        const first_block = page_virt;

        var offset: usize = 0;
        var first = true;

        while (offset + block_size <= PAGE_SIZE) : (offset += block_size) {
            const block_start = page_virt + offset;
            const node: *FreeNode = @ptrFromInt(block_start);

            if (first) {
                // 第一个块会被使用，不放入空闲链表
                first = false;
                continue;
            }

            // 初始化空闲节点
            node.* = .{
                .next = self.free_list,
            };
            self.free_list = node;
        }

        log.debug("[Slub] Arena '{}': allocated page, {} free blocks (obj_size={})", .{
            self.name, block_count - 1, obj_size,
        });

        return @ptrFromInt(first_block);
    }

    /// 尝试回收完全空闲的页面
    /// 当某个页面中的所有块都被释放时，回收该页面
    fn tryShrink(self: *SlubArena) void {
        _ = self;
        // 简化实现：在实际系统中，这里需要追踪每个页面的使用情况
        // 目前依赖 PMM 的页面回收机制
    }

    /// 获取 Arena 的统计信息
    pub fn getStats(self: *const SlubArena) struct {
        name: []const u8,
        page_count: usize,
        allocated_count: usize,
        freed_count: usize,
        state: State,
    } {
        return .{
            .name = self.name,
            .page_count = self.page_count,
            .allocated_count = self.allocated_count,
            .freed_count = self.freed_count,
            .state = self.state,
        };
    }
};

// ============================================================================
// 全局 Slub Arenas
// ============================================================================

/// 全局 Slub Arenas，用于不同大小范围的分配
pub var arena_64: SlubArena = SlubArena.create(.{ .name = "slub-64", .min_size = 1, .max_size = 64 });
pub var arena_256: SlubArena = SlubArena.create(.{ .name = "slub-256", .min_size = 65, .max_size = 256 });
pub var arena_1k: SlubArena = SlubArena.create(.{ .name = "slub-1k", .min_size = 257, .max_size = 1024 });
pub var arena_4k: SlubArena = SlubArena.create(.{ .name = "slub-4k", .min_size = 1025, .max_size = 4096 });
pub var arena_large: SlubArena = SlubArena.create(.{ .name = "slub-large", .min_size = 4097, .max_size = 65536 });

/// Slub 全局锁（保护 Arena 选择逻辑）
var global_lock: SpinLock = .{};

/// 初始化所有全局 Slub Arenas
pub fn init() void {
    arena_64.init();
    arena_256.init();
    arena_1k.init();
    arena_4k.init();
    arena_large.init();
    log.info("[Slub] Initialized {} arenas", .{5});
}

/// 根据请求大小选择合适的 Arena
fn selectArena(size: usize) ?*SlubArena {
    if (size <= 64) return &arena_64;
    if (size <= 256) return &arena_256;
    if (size <= 1024) return &arena_1k;
    if (size <= 4096) return &arena_4k;
    if (size <= 65536) return &arena_large;
    return null;
}

// ============================================================================
// 物理地址到虚拟地址转换
// ============================================================================

/// 将物理地址转换为虚拟地址
/// 根据不同架构使用不同的映射策略
fn physToVirt(phys: u64) u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // x86_64 使用恒等映射访问低 1GB 内存
            if (phys < 0x4000_0000) {
                return phys;
            }
            // 高内存使用直接映射区域
            return 0xFFFF_8000_0000_0000 + (phys - 0x8000_0000);
        },
        .aarch64, .aarch64_be => {
            // AArch64 通常使用恒等映射
            return phys;
        },
        .riscv64 => {
            // RISC-V Sv48：高 256GB 区域直接映射 0x8000_0000 开始的内存
            if (phys >= 0x8000_0000) {
                return 0xFFFF_8000_0000_0000 + (phys - 0x8000_0000);
            }
            return phys;
        },
        .loongarch64 => {
            // LoongArch64 使用 DMW 窗口
            // 0x9000_xxxx_xxxx_xxxx 直接映射物理地址
            return phys | (@as(u64, 0x9000) << 48);
        },
        else => {
            return phys;
        },
    }
}

/// 将虚拟地址转换为物理地址
fn virtToPhys(virt: u64) u64 {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            if (virt < 0x0000_8000_0000_0000) {
                return virt; // 恒等映射
            }
            // 直接映射区域
            if (virt >= 0xFFFF_8000_0000_0000) {
                return 0x8000_0000 + (virt - 0xFFFF_8000_0000_0000);
            }
            return virt;
        },
        .aarch64, .aarch64_be => {
            return virt; // 恒等映射
        },
        .riscv64 => {
            if (virt >= 0xFFFF_8000_0000_0000) {
                return 0x8000_0000 + (virt - 0xFFFF_8000_0000_0000);
            }
            return virt;
        },
        .loongarch64 => {
            // 去除 VSEG 前缀
            return virt & 0x0FFF_FFFF_FFFF_FFFF;
        },
        else => {
            return virt;
        },
    }
}

// ============================================================================
// 页面级分配
// ============================================================================

/// 分配连续的物理页面
/// 返回页面索引
pub fn allocPages(count: usize) ?usize {
    if (count == 0) return null;
    return pmm.allocPages(count);
}

/// 分配单个页面
pub fn allocPage() ?usize {
    return pmm.allocPage();
}

/// 释放连续的物理页面
pub fn freePages(page: usize, count: usize) void {
    pmm.freePages(page, count);
}

/// 释放单个页面
pub fn freePage(page: usize) void {
    pmm.freePage(page);
}

// ============================================================================
// Slub 统一分配接口
// ============================================================================

/// 从 Slub Arena 分配内存
/// 根据请求大小选择合适的 Arena
pub fn slubAlloc(size: usize) ?[*]u8 {
    if (size == 0) return null;

    global_lock.acquire();
    defer global_lock.release();

    const arena = selectArena(size) orelse {
        // 大于 64KB 的分配，绕过 Slub 直接使用 PMM
        return slubAllocLarge(size);
    };

    return arena.alloc(size);
}

/// 释放 Slub 分配的内存
pub fn slubFree(ptr: [*]u8) void {
    if (ptr == null) return;

    // 获取块头部信息
    const header_ptr: [*]SlubBlockHeader = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(SlubBlockHeader));

    if (header_ptr[0].magic != SlubBlockHeader.MAGIC) {
        log.warn("[Slub] slubFree: invalid magic", .{});
        return;
    }

    global_lock.acquire();
    defer global_lock.release();

    // 根据大小找到对应的 Arena
    const size = header_ptr[0].size;
    const arena = selectArena(size) orelse {
        // 大于 64KB，可能是大型分配
        slubFreeLarge(ptr);
        return;
    };

    arena.free(ptr);
}

/// 分配大于 Arena 限制的内存（直接使用 PMM）
fn slubAllocLarge(size: usize) ?[*]u8 {
    // 计算需要的页面数
    const header_size = @sizeOf(SlubBlockHeader);
    const total_size = size + header_size;
    const pages_needed = (total_size + PAGE_SIZE - 1) / PAGE_SIZE;

    const page_idx = pmm.allocPages(pages_needed) orelse return null;
    const page_phys = pmm.pageToPhysical(page_idx);
    const page_virt = physToVirt(page_phys);

    // 写入头部信息
    const header: *SlubBlockHeader = @ptrFromInt(page_virt);
    header.* = .{
        .size = size,
        .magic = SlubBlockHeader.MAGIC,
        .in_use = true,
    };

    const data_ptr: [*]u8 = @ptrFromInt(page_virt + header_size);
    return data_ptr;
}

/// 释放大型分配
fn slubFreeLarge(ptr: [*]u8) void {
    const header_ptr: [*]SlubBlockHeader = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(SlubBlockHeader));

    if (header_ptr[0].magic != SlubBlockHeader.MAGIC) {
        log.warn("[Slub] slubFreeLarge: invalid magic", .{});
        return;
    }

    const size = header_ptr[0].size;
    const header_virt = @intFromPtr(header_ptr);
    const page_virt = header_virt & ~(@as(u64, PAGE_SIZE - 1));
    const page_phys = virtToPhys(page_virt);
    const page_idx = pmm.physicalToPage(page_phys);

    const header_size = @sizeOf(SlubBlockHeader);
    const total_size = size + header_size;
    const pages_needed = (total_size + PAGE_SIZE - 1) / PAGE_SIZE;

    pmm.freePages(page_idx, pages_needed);
}

// ============================================================================
// 调试和统计
// ============================================================================

/// Slub 统计信息
pub const Stats = struct {
    arena_64: SlubArena.Stats,
    arena_256: SlubArena.Stats,
    arena_1k: SlubArena.Stats,
    arena_4k: SlubArena.Stats,
    arena_large: SlubArena.Stats,
    pmm_stats: pmm.PMMStats,
};

/// 获取全局 Slub 统计信息
pub fn getStats() Stats {
    global_lock.acquire();
    defer global_lock.release();

    return Stats{
        .arena_64 = arena_64.getStats(),
        .arena_256 = arena_256.getStats(),
        .arena_1k = arena_1k.getStats(),
        .arena_4k = arena_4k.getStats(),
        .arena_large = arena_large.getStats(),
        .pmm_stats = pmm.getStats(),
    };
}

/// 打印 Slub 状态
pub fn dumpState() void {
    const stats = getStats();

    log.info("=== Slub State ===", .{});
    log.info("  Arena 'slub-64':   pages={}, alloc={}, free={}", .{
        stats.arena_64.page_count,
        stats.arena_64.allocated_count,
        stats.arena_64.freed_count,
    });
    log.info("  Arena 'slub-256':  pages={}, alloc={}, free={}", .{
        stats.arena_256.page_count,
        stats.arena_256.allocated_count,
        stats.arena_256.freed_count,
    });
    log.info("  Arena 'slub-1k':   pages={}, alloc={}, free={}", .{
        stats.arena_1k.page_count,
        stats.arena_1k.allocated_count,
        stats.arena_1k.freed_count,
    });
    log.info("  Arena 'slub-4k':   pages={}, alloc={}, free={}", .{
        stats.arena_4k.page_count,
        stats.arena_4k.allocated_count,
        stats.arena_4k.freed_count,
    });
    log.info("  Arena 'slub-large': pages={}, alloc={}, free={}", .{
        stats.arena_large.page_count,
        stats.arena_large.allocated_count,
        stats.arena_large.freed_count,
    });
    log.info("  PMM: total={}, allocated={}, free={}", .{
        stats.pmm_stats.total_pages,
        stats.pmm_stats.allocated_pages,
        stats.pmm_stats.free_pages,
    });
}

/// 合并相邻的空闲块（Buddy 合并）
/// 在实际系统中，这需要追踪每个页面的起始位置和块数量
/// 目前为简化实现，跳过此功能
pub fn mergeFreeBlocks() void {
    // 简化：依赖 PMM 的页面回收机制
    // 真正的 Slub 合并需要页级追踪
    log.debug("[Slub] mergeFreeBlocks called (stub)", .{});
}

// ============================================================================
// 简单测试
// ============================================================================

/// 运行基本测试
pub fn selfTest() void {
    log.info("[Slub] Running self-test...", .{});

    // 测试 Arena 分配
    const test_sizes = [_]usize{ 8, 32, 64, 128, 256, 512, 1024 };

    for (test_sizes) |size| {
        const ptr = slubAlloc(size);
        if (ptr == null) {
            log.err("[Slub] self-test: alloc failed for size {}", .{size});
            continue;
        }

        // 写入数据
        @memset(ptr[0..size], 0xAA);

        // 验证数据
        var valid = true;
        for (0..size) |i| {
            if (ptr[i] != 0xAA) {
                valid = false;
                break;
            }
        }

        if (valid) {
            log.debug("[Slub] self-test: size {} OK", .{size});
        } else {
            log.err("[Slub] self-test: size {} FAILED (data corruption)", .{size});
        }

        slubFree(ptr);
    }

    // 测试大分配
    const large_ptr = slubAlloc(8000);
    if (large_ptr) |ptr| {
        @memset(ptr[0..8000], 0xBB);
        slubFree(ptr);
        log.debug("[Slub] self-test: large alloc (8000) OK", .{});
    }

    log.info("[Slub] self-test complete", .{});
}
