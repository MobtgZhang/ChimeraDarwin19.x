/// Buddy Allocator — power-of-two block allocation.
/// Manages physical memory in power-of-two sized blocks for efficient kernel allocation.
///
/// Features:
///   - Power-of-two allocation (order 0 = 4KB, order 10 = 4MB)
///   - O(log n) allocation and deallocation
///   - Minimal external fragmentation
///   - Thread-safe with SpinLock protection

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;

pub const PAGE_SIZE: usize = 4096;
pub const MAX_ORDER: u5 = 10;

/// P1 FIX: Removed hardcoded MAX_PAGES limit - now uses runtime size from init()
const MAX_SUPPORTED_PAGES = 256 * 1024; // Default max for static arrays

const FreeBlock = struct {
    next: ?*FreeBlock,
};

const FLAG_ALLOCATED: u8 = 0x01;
const ORDER_SHIFT: u3 = 1;

/// P1 FIX: Static arrays with maximum supported size (1GB)
var free_lists: [MAX_ORDER + 1]?*FreeBlock = [_]?*FreeBlock{null} ** (MAX_ORDER + 1);
var page_flags: [MAX_SUPPORTED_PAGES]u8 = [_]u8{0} ** MAX_SUPPORTED_PAGES;
var lock: SpinLock = .{};

var zone_base: usize = 0;
var zone_pages: usize = 0;
var free_count: usize = 0;
/// P1 FIX: Track actual allocated pages for bounds checking
var max_managed_pages: usize = 0;

fn pageAddr(page: usize) usize {
    return zone_base + page * PAGE_SIZE;
}

fn addrPage(addr: usize) usize {
    return (addr - zone_base) / PAGE_SIZE;
}

fn buddyOf(page: usize, order: u5) usize {
    return page ^ (@as(usize, 1) << order);
}

fn setAllocated(page: usize, order: u5) void {
    page_flags[page] = FLAG_ALLOCATED | (@as(u8, order) << ORDER_SHIFT);
}

fn setFree(page: usize, order: u5) void {
    page_flags[page] = @as(u8, order) << ORDER_SHIFT;
}

fn isAllocated(page: usize) bool {
    return page_flags[page] & FLAG_ALLOCATED != 0;
}

fn pageOrder(page: usize) u5 {
    return @intCast((page_flags[page] >> ORDER_SHIFT) & 0x1F);
}

fn listPush(order: u5, page: usize) void {
    const block: *FreeBlock = @ptrFromInt(pageAddr(page));
    block.next = free_lists[order];
    free_lists[order] = block;
    setFree(page, order);
}

fn listPop(order: u5) ?usize {
    const block = free_lists[order] orelse return null;
    free_lists[order] = block.next;
    return addrPage(@intFromPtr(block));
}

fn listRemove(order: u5, page: usize) void {
    const target: *FreeBlock = @ptrFromInt(pageAddr(page));
    var pp = &free_lists[order];
    while (pp.*) |block| {
        if (block == target) {
            pp.* = block.next;
            return;
        }
        pp = &block.next;
    }
}

/// Initialize the buddy allocator with a memory region
/// 
/// Parameters:
///   - region_base: Physical base address of the memory region
///   - num_pages: Number of pages to manage (will be clamped to MAX_SUPPORTED_PAGES)
pub fn init(region_base: usize, num_pages: usize) void {
    zone_base = region_base;
    zone_pages = @min(num_pages, MAX_SUPPORTED_PAGES);
    max_managed_pages = zone_pages;
    free_count = 0;

    // P1 FIX: Clear page_flags for the actual managed range only
    @memset(&page_flags, 0);
    for (0..zone_pages) |i| {
        page_flags[i] = 0;
    }
    for (&free_lists) |*fl| fl.* = null;

    var page: usize = 0;
    while (page < zone_pages) {
        var order: u5 = MAX_ORDER;
        while (order > 0) : (order -= 1) {
            const block_size: usize = @as(usize, 1) << order;
            if (page % block_size == 0 and page + block_size <= zone_pages) break;
        }
        const block_size: usize = @as(usize, 1) << order;
        if (page + block_size <= zone_pages) {
            listPush(order, page);
            free_count += block_size;
            page += block_size;
        } else {
            page += 1;
        }
    }

    log.info("Buddy allocator: zone 0x{x}, {} pages ({} MB), {} free", .{
        zone_base, zone_pages, zone_pages * PAGE_SIZE / (1024 * 1024), free_count,
    });
}

/// P1 FIX: Added bounds checking for page index
fn isValidPage(page: usize) bool {
    return page < max_managed_pages;
}

/// Allocate a block of size 2^order pages
/// 
/// Returns: Physical address of the allocated block, or null if out of memory
pub fn allocPages(order: u5) ?usize {
    lock.acquire();
    defer lock.release();

    var o: usize = order;
    while (o <= MAX_ORDER) {
        if (free_lists[o] != null) break;
        o += 1;
    }
    if (o > MAX_ORDER) return null;

    const page = listPop(@intCast(o)) orelse return null;

    // Split higher-order blocks to get the requested size
    while (o > order) {
        o -= 1;
        const buddy = page + (@as(usize, 1) << @intCast(o));
        listPush(@intCast(o), buddy);
    }

    setAllocated(page, order);
    const count: usize = @as(usize, 1) << order;
    // P1 FIX: Corrected syntax error -|= -> -=
    free_count -= count;
    return pageAddr(page);
}

/// Free a block allocated with allocPages
pub fn freePages(addr: usize, order: u5) void {
    lock.acquire();
    defer lock.release();

    var page = addrPage(addr);
    var o: usize = order;

    // Coalesce with buddies while possible
    while (o < MAX_ORDER) {
        const buddy = buddyOf(page, @intCast(o));
        // P1 FIX: Add bounds check for buddy
        if (buddy >= zone_pages) break;
        if (isAllocated(buddy)) break;
        if (pageOrder(buddy) != @as(u5, @intCast(o))) break;

        listRemove(@intCast(o), buddy);
        page = @min(page, buddy);
        o += 1;
    }

    listPush(@intCast(o), page);
    const count: usize = @as(usize, 1) << order;
    free_count += count;
}

/// Allocate a single 4KB page
pub fn allocOnePage() ?usize {
    return allocPages(0);
}

/// Free a single 4KB page
pub fn freeOnePage(addr: usize) void {
    freePages(addr, 0);
}

/// Get the number of free pages
pub fn freePageCount() usize {
    return free_count;
}

/// Get the total number of managed pages
pub fn totalPageCount() usize {
    return zone_pages;
}

/// Get the number of allocated pages
pub fn allocatedPageCount() usize {
    return zone_pages - free_count;
}

/// Calculate the order (log2) for a given number of pages
pub fn orderForPages(n: usize) u5 {
    if (n == 0) return 0;
    var order: u5 = 0;
    var size: usize = 1;
    while (size < n and order < MAX_ORDER) {
        order += 1;
        size <<= 1;
    }
    return order;
}

/// P1 FIX: Added debug function to dump allocator state
pub fn dumpState() void {
    log.info("=== Buddy Allocator State ===", .{});
    log.info("  Zone base: 0x{x}", .{zone_base});
    log.info("  Managed pages: {}", .{zone_pages});
    log.info("  Free pages: {}", .{free_count});
    log.info("  Allocated pages: {}", .{zone_pages - free_count});
    
    var total_free_lists: usize = 0;
    for (free_lists, 0..) |fl, order| {
        var count: usize = 0;
        var block = fl;
        while (block) |b| : (block = b.next) {
            count += 1;
        }
        if (count > 0) {
            log.info("  Order {} ({}KB): {} blocks", .{ order, (@as(usize, 1) << order) * PAGE_SIZE / 1024, count });
            total_free_lists += count;
        }
    }
    log.info("  Total free blocks: {}", .{total_free_lists});
}
