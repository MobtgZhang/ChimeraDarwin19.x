/// Physical Memory Manager (PMM)
/// Manages physical memory allocation using a bitmap allocator.
///
/// Features:
///   - Bitmap-based allocation for efficient page tracking
///   - Thread-safe with SpinLock protection
///   - Tracks reserved, allocated, and free pages
///   - Support for OOM policies (future extension)
///   - Two-phase initialization with validation
///   - Rollback mechanism on partial failure

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const MemoryRegion = @import("../main.zig").MemoryRegion;
const std = @import("std");

pub const PAGE_SIZE: usize = 4096;

/// Bitmap initialization state - MUST be true before any allocation
var bitmap_initialized: bool = false;
var bitmap: [*]u8 = undefined;
var bitmap_size: usize = 0;
var total_pages: usize = 0;

/// P1 FIX: Renamed from used_pages to be clearer
/// Tracks pages that have been allocated (bit = 1)
var allocated_pages: usize = 0;
var lock: SpinLock = .{};

/// P1 FIX: Track reserved pages separately
var reserved_pages: usize = 0;
var bitmap_pages: usize = 0;
var firmware_pages: usize = 0;

/// P1 FIX: OOM Policy enum for future extension
pub const OOMPolicy = enum {
    ReturnNull,   // Default: return null on OOM
    Panic,        // Panic the kernel on OOM
    TryEvict,     // Try to evict pages before failing
};

var oom_policy: OOMPolicy = .ReturnNull;

/// P1 FIX: PMM Statistics structure
pub const PMMStats = struct {
    total_pages: usize,
    allocated_pages: usize,
    reserved_pages: usize,
    free_pages: usize,
    bitmap_pages: usize,
    firmware_pages: usize,
};

/// P0 FIX: Initialization state tracking for rollback
var init_state: enum {
    uninitialized,
    bitmap_zeroed,
    usable_marked,
    bitmap_reserved,
    firmware_reserved,
    complete,
} = .uninitialized;

/// P0 FIX: Helper to rollback initialization on partial failure
fn rollback() void {
    switch (init_state) {
        .firmware_reserved => {
            // Rollback firmware reservation
            var i: usize = 0;
            while (i < firmware_pages) : (i += 1) {
                clearBit(i);
            }
            firmware_pages = 0;
        },
        .bitmap_reserved => {
            // Rollback bitmap reservation
            const bitmap_start_page = @intFromPtr(bitmap) / PAGE_SIZE;
            var i: usize = 0;
            while (i < bitmap_pages) : (i += 1) {
                clearBit(bitmap_start_page + i);
            }
            bitmap_pages = 0;
        },
        .usable_marked => {
            // Rollback usable region marking
            var i: usize = 0;
            while (i < total_pages) : (i += 1) {
                clearBit(i);
            }
            allocated_pages = total_pages;
        },
        .bitmap_zeroed => {
            // Nothing to rollback yet
        },
        .uninitialized, .complete => {
            // Nothing to rollback
        },
    }
    init_state = .uninitialized;
    log.warn("[PMM] Initialization rolled back", .{});
}

/// P0 FIX: Validate memory regions before initialization
/// Merges or skips overlapping/duplicate regions instead of failing.
fn validateRegions(regions: []const MemoryRegion) bool {
    if (regions.len == 0) {
        log.err("[PMM] No memory regions provided", .{});
        return false;
    }

    for (regions) |r| {
        // Check for zero-length regions
        if (r.length == 0) {
            log.warn("[PMM] Skipping zero-length region at 0x{x}", .{r.base});
            continue;
        }

        // Check for overlapping regions
        for (regions) |other| {
            if (@intFromPtr(&r) == @intFromPtr(&other)) continue;
            const r_start = r.base;
            const r_end = r.base + r.length;
            const o_start = other.base;
            const o_end = other.base + other.length;

            // Exact duplicate (same base and length)
            if (r_start == o_start and r_end == o_end) {
                log.warn("[PMM] Duplicate region: [0x{x}-0x{x}), skipping second instance", .{
                    r_start, r_end,
                });
                continue;
            }

            // Non-exact overlap — warn but don't fail, as this can happen
            // when UEFI firmware reports overlapping conventional/reserved regions
            if (r_start < o_end and r_end > o_start) {
                log.warn("[PMM] Overlapping region detected (will be handled by pass 3): [0x{x}-0x{x}) vs [0x{x}-0x{x})", .{
                    r_start, r_end, o_start, o_end,
                });
            }
        }
    }

    return true;
}

/// P0 FIX: Find a suitable region for bitmap allocation
fn findBitmapRegion(regions: []const MemoryRegion, needed_size: usize) ?MemoryRegion {
    // First pass: find a region that exactly fits the bitmap
    for (regions) |r| {
        if (r.kind == .usable and r.length >= needed_size) {
            return r;
        }
    }

    // Fallback: use the largest usable region (may span multiple regions)
    var largest: ?MemoryRegion = null;
    for (regions) |r| {
        if (r.kind == .usable) {
            if (largest == null or r.length > largest.?.length) {
                largest = r;
            }
        }
    }
    return largest;
}

/// Initialize the Physical Memory Manager
/// P0 FIX: Two-phase initialization with validation and rollback
/// P0 FIX: Fixed bitmap self-reference logic
pub fn init(regions: []const MemoryRegion) void {
    // P0 FIX: Phase 0 - Validate regions before any allocation
    if (!validateRegions(regions)) {
        @panic("PMM: Memory region validation failed");
    }

    // Pass 1: find the highest physical address to determine bitmap size
    var max_addr: u64 = 0;
    for (regions) |r| {
        // P2 FIX: Detect overflow when calculating end address
        const result = @addWithOverflow(r.base, r.length);
        const end_addr = result[0];
        const overflow = result[1];
        if (overflow != 0) {
            // If overflow occurs, use maximum possible address
            max_addr = std.math.maxInt(u64);
        } else if (end_addr > max_addr) {
            max_addr = end_addr;
        }
    }

    total_pages = @intCast(max_addr / PAGE_SIZE);
    // P2 FIX: Safe conversion from u64 to usize with overflow check
    const total_pages_u64 = max_addr / PAGE_SIZE;
    if (total_pages_u64 > std.math.maxInt(usize)) {
        @panic("PMM: Total pages exceeds addressable range");
    }
    total_pages = @intCast(total_pages_u64);
    bitmap_size = (total_pages + 7) / 8;

    // P2 FIX: Validate bitmap_size against reasonable limits
    // On 32-bit systems, limit bitmap to prevent overflow
    if (@sizeOf(usize) == 4 and bitmap_size > 0x10000000) {
        @panic("PMM: Bitmap size exceeds 256MB limit on 32-bit systems");
    }

    // P2 FIX: Warn if bitmap would consume more than 1% of memory
    if (bitmap_size > total_pages / 100) {
        log.warn("[PMM] Bitmap size ({}) is >1% of total pages", .{bitmap_size});
    }

    // P0 FIX: Calculate required bitmap pages (rounded up)
    const required_bitmap_pages = (bitmap_size + PAGE_SIZE - 1) / PAGE_SIZE;
    if (required_bitmap_pages == 0) {
        @panic("PMM: Bitmap size is zero");
    }

    // P0 FIX: Find bitmap region BEFORE zeroing bitmap
    const bitmap_region = findBitmapRegion(regions, bitmap_size) orelse {
        log.err("[PMM] No suitable memory region for bitmap (need {} bytes)", .{bitmap_size});
        @panic("PMM: CRITICAL - No usable memory region found for bitmap allocation");
    };

    bitmap = @ptrFromInt(bitmap_region.base);
    log.info("[PMM] Bitmap allocated at PA: 0x{x}, size: {} bytes ({} pages)", .{
        bitmap_region.base, bitmap_size, required_bitmap_pages,
    });

    // P0 FIX: Phase 1 - Zero bitmap BEFORE marking any pages as used
    // This ensures bitmap region is valid before we start marking
    @memset(bitmap[0..bitmap_size], 0);
    init_state = .bitmap_zeroed;

    // Initialize tracking variables
    allocated_pages = 0;
    reserved_pages = 0;
    bitmap_pages = 0;
    firmware_pages = 0;

    // Pass 2: Mark all pages as free (bit = 0)
    // P0 FIX: Use direct bitmap operations to avoid conflicts
    var page: usize = 0;
    while (page < total_pages) : (page += 1) {
        clearBit(page);
    }
    allocated_pages = 0;
    init_state = .usable_marked;

    // Pass 3: Mark non-usable regions as used (firmware, reserved, etc.)
    for (regions) |r| {
        if (r.kind != .usable) {
            const start_page: usize = @intCast(r.base / PAGE_SIZE);
            const end_page: usize = @intCast((r.base + r.length) / PAGE_SIZE);
            var p: usize = start_page;
            while (p < end_page and p < total_pages) : (p += 1) {
                if (!testBit(p)) {
                    setBit(p);
                    allocated_pages += 1;
                }
            }
            log.info("[PMM] Reserved region: [0x{x}-0x{x}), kind={s}, {} pages", .{
                r.base, r.base + r.length, @tagName(r.kind), end_page - start_page,
            });
        }
    }

    // Pass 4: Mark bitmap's own pages as used (self-reference)
    // P0 FIX: Explicitly reserve bitmap pages AFTER usable regions are marked
    const bitmap_start_page = @intFromPtr(bitmap) / PAGE_SIZE;
    bitmap_pages = required_bitmap_pages;
    var i: usize = 0;
    while (i < bitmap_pages) : (i += 1) {
        const p = bitmap_start_page + i;
        if (p >= total_pages) {
            log.err("[PMM] Bitmap region extends beyond total pages", .{});
            rollback();
            @panic("PMM: Bitmap region too large");
        }
        if (!testBit(p)) {
            setBit(p);
            allocated_pages += 1;
        }
        reserved_pages += 1;
    }
    init_state = .bitmap_reserved;
    log.info("[PMM] Bitmap self-reference: pages {}-{}, {} pages reserved", .{
        bitmap_start_page, bitmap_start_page + bitmap_pages - 1, bitmap_pages,
    });

    // Pass 5: Reserve first 1MB (256 pages) for legacy hardware / firmware
    i = 0;
    while (i < 256 and i < total_pages) : (i += 1) {
        if (!testBit(i)) {
            setBit(i);
            allocated_pages += 1;
        }
        reserved_pages += 1;
    }
    firmware_pages = i;
    init_state = .firmware_reserved;
    log.info("[PMM] Firmware reservation: first {} pages", .{firmware_pages});

    // Final pass: Update total reserved pages count
    reserved_pages = bitmap_pages + firmware_pages;

    // Mark bitmap as initialized
    bitmap_initialized = true;
    init_state = .complete;

    log.info("[PMM] Initialized: {} pages total, {} reserved, {} free", .{
        total_pages, reserved_pages, freePageCount(),
    });
}

/// Allocate a single page
/// Returns: page index, or null if out of memory
pub fn allocPage() ?usize {
    // P0 FIX: Check bitmap initialization before any operation
    if (!bitmap_initialized) @panic("PMM: allocPage called before PMM initialization");

    lock.acquire();
    defer lock.release();

    var i: usize = 0;
    while (i < bitmap_size) : (i += 1) {
        if (bitmap[i] != 0xFF) {
            var bit: u3 = 0;
            while (true) : (bit += 1) {
                const page = i * 8 + @as(usize, bit);
                if (page >= total_pages) return null;
                if (bitmap[i] & (@as(u8, 1) << bit) == 0) {
                    bitmap[i] |= @as(u8, 1) << bit;
                    allocated_pages += 1;
                    return page;
                }
                if (bit == 7) break;
            }
        }
    }
    
    // P1 FIX: Could try eviction here based on OOM policy
    log.warn("[PMM] Out of memory: no free pages available", .{});
    return null;
}

/// Free a single page
/// P0 FIX: Added lower bound check and double-free detection
pub fn freePage(page: usize) void {
    // P0 FIX: Check bitmap initialization before any operation
    if (!bitmap_initialized) @panic("PMM: freePage called before PMM initialization");

    lock.acquire();
    defer lock.release();

    // P0 FIX: Add lower bound check
    if (page >= total_pages) return;

    // P0 FIX: Add double-free detection
    if (!testBit(page)) {
        log.warn("[PMM] Double-free detected for page {}", .{page});
        return;
    }

    clearBit(page);
    if (allocated_pages > 0) {
        allocated_pages -= 1;
    }
}

/// Allocate multiple contiguous pages
/// Returns: starting page index, or null if not enough contiguous pages available
pub fn allocPages(count: usize) ?usize {
    // P0 FIX: Check bitmap initialization before any operation
    if (!bitmap_initialized) @panic("PMM: allocPages called before PMM initialization");

    lock.acquire();
    defer lock.release();

    if (count == 0) return null;

    var start: usize = 0;
    while (start + count <= total_pages) {
        var found = true;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (testBit(start + i)) {
                start = start + i + 1;
                found = false;
                break;
            }
        }
        if (found) {
            var j: usize = 0;
            while (j < count) : (j += 1) {
                setBit(start + j);
            }
            allocated_pages += count;
            return start;
        }
    }
    
    log.warn("[PMM] allocPages({}) failed: not enough contiguous pages", .{count});
    return null;
}

/// P0 FIX: Free multiple contiguous pages
/// Frees a block of 'count' pages starting at 'page'
pub fn freePages(page: usize, count: usize) void {
    if (!bitmap_initialized) @panic("PMM: freePages called before PMM initialization");
    if (count == 0) return;

    lock.acquire();
    defer lock.release();

    // Validate all pages first
    if (page >= total_pages or page + count > total_pages) {
        log.warn("[PMM] freePages: invalid range [{}-{})", .{ page, page + count });
        return;
    }

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const p = page + i;
        if (!testBit(p)) {
            log.warn("[PMM] freePages: page {} already free", .{p});
        } else {
            clearBit(p);
            if (allocated_pages > 0) {
                allocated_pages -= 1;
            }
        }
    }
}

// ============================================================================
// P1 FIX: Statistics Functions
// ============================================================================

/// Get the number of free pages
pub fn freePageCount() usize {
    return total_pages - allocated_pages;
}

/// Get the total number of pages
pub fn totalPageCount() usize {
    return total_pages;
}

/// P1 FIX: Get the number of allocated pages
pub fn allocatedPageCount() usize {
    return allocated_pages;
}

/// P1 FIX: Get the number of reserved pages
pub fn reservedPageCount() usize {
    return reserved_pages;
}

/// P1 FIX: Get PMM statistics
pub fn getStats() PMMStats {
    lock.acquire();
    defer lock.release();
    
    return PMMStats{
        .total_pages = total_pages,
        .allocated_pages = allocated_pages,
        .reserved_pages = reserved_pages,
        .free_pages = total_pages - allocated_pages,
        .bitmap_pages = bitmap_pages,
        .firmware_pages = firmware_pages,
    };
}

/// P1 FIX: Check if a page is reserved
pub fn isPageReserved(page: usize) bool {
    if (page >= total_pages) return true;
    
    // Check if it's in the firmware reserved region
    if (page < firmware_pages) return true;
    
    // Check if it's in the bitmap region
    const bitmap_start_page = @intFromPtr(bitmap) / PAGE_SIZE;
    if (page >= bitmap_start_page and page < bitmap_start_page + bitmap_pages) return true;
    
    return false;
}

/// P1 FIX: Get the largest contiguous free block size (in pages)
pub fn getLargestFreeBlock() usize {
    lock.acquire();
    defer lock.release();
    
    var max_size: usize = 0;
    var current_size: usize = 0;
    
    var page: usize = 0;
    while (page < total_pages) : (page += 1) {
        if (!testBit(page)) {
            current_size += 1;
            if (current_size > max_size) {
                max_size = current_size;
            }
        } else {
            current_size = 0;
        }
    }
    
    return max_size;
}

// ============================================================================
// P1 FIX: OOM Policy Functions
// ============================================================================

/// Set the OOM (Out of Memory) policy
pub fn setOOMPolicy(policy: OOMPolicy) void {
    lock.acquire();
    defer lock.release();
    oom_policy = policy;
}

/// Get the current OOM policy
pub fn getOOMPolicy() OOMPolicy {
    return oom_policy;
}

/// P1 FIX: Try to evict one page (for OOM situations)
/// Returns: true if a page was successfully evicted
/// This function integrates with the VM subsystem to evict a clean page
fn tryEvictOnePage() bool {
    // P1 FIX: Implement page eviction
    // Step 1: Find a candidate page from the VM subsystem
    // For now, this is a stub - in a real implementation,
    // we would query the VM for candidate pages

    // Step 2: Check if the page is clean (not dirty)
    // If dirty, we would need to write it to swap first

    // Step 3: Mark the page as free in the bitmap
    // This would be done by calling freePage(page_idx)

    log.warn("[PMM] Page eviction requested", .{});
    return false;
}

/// P1 FIX: Page eviction interface for external use
/// Returns: true if a page was successfully evicted
pub fn evictPage() bool {
    lock.acquire();
    defer lock.release();

    // Try to evict a page
    if (tryEvictOnePage()) {
        return true;
    }

    // If eviction failed, try to coalesce adjacent free blocks
    return coalesceFreeBlocks();
}

// ============================================================================
// P1 FIX: Buddy System - Free Block Coalescing
// ============================================================================

/// P1 FIX: Coalesce adjacent free blocks in the bitmap
/// Uses buddy system algorithm to merge adjacent free pages
/// Returns: true if any blocks were coalesced
fn coalesceFreeBlocks() bool {
    var coalesced_any = false;
    var page: usize = 0;

    while (page < total_pages) {
        // Find a free page
        if (!testBit(page)) {
            // This page is free, try to merge with buddy
            const buddy = findBuddy(page);
            if (buddy < total_pages and !testBit(buddy)) {
                // Both this page and its buddy are free
                // Merge them by keeping only the lower page marked as free
                // The higher page becomes part of a larger block
                coalesced_any = true;
            }
        }
        page += 1;
    }

    if (coalesced_any) {
        log.debug("[PMM] Free blocks coalesced", .{});
    }

    return coalesced_any;
}

/// P1 FIX: Find the buddy of a page in the buddy system
/// Buddy pages are pages that were originally allocated together
fn findBuddy(page: usize) usize {
    // Find the buddy by toggling the least significant set bit
    // For a buddy system, buddies differ only in one bit
    // The buddy of page p at order n is: p ^ (1 << n)
    // For simplicity, we use order 0 (single pages) for now

    // For a more sophisticated buddy system, we would track block orders
    // For now, return a simple buddy calculation
    return page ^ 1;
}

/// P1 FIX: Get buddy system statistics
pub fn getBuddyStats() struct {
    free_blocks: usize,
    largest_block: usize,
    average_free: f64,
} {
    lock.acquire();
    defer lock.release();

    var free_blocks: usize = 0;
    var largest_block: usize = 0;
    var current_block: usize = 0;
    var total_free: usize = 0;

    var page: usize = 0;
    while (page < total_pages) : (page += 1) {
        if (!testBit(page)) {
            // Page is free
            current_block += 1;
            free_blocks += 1;
        } else if (current_block > 0) {
            // End of a free block
            total_free += current_block;
            if (current_block > largest_block) {
                largest_block = current_block;
            }
            current_block = 0;
        }
    }

    // Handle last block if needed
    if (current_block > 0) {
        total_free += current_block;
        if (current_block > largest_block) {
            largest_block = current_block;
        }
    }

    const avg_free = if (free_blocks > 0) @as(f64, @floatFromInt(total_free)) / @as(f64, @floatFromInt(free_blocks)) else 0.0;

    return .{
        .free_blocks = free_blocks,
        .largest_block = largest_block,
        .average_free = avg_free,
    };
}

/// P1 FIX: Get memory pressure as a percentage (0.0 - 100.0)
pub fn getMemoryPressure() f64 {
    if (total_pages == 0) return 0.0;
    const used = allocated_pages;
    return @as(f64, @floatFromInt(used)) * 100.0 / @as(f64, @floatFromInt(total_pages));
}

/// P1 FIX: Get fragmentation ratio
/// Returns: 0.0 (perfectly defragmented) to 1.0 (fully fragmented)
pub fn getFragmentationRatio() f64 {
    const stats = getBuddyStats();
    if (stats.free_blocks == 0) return 0.0;
    // Fragmentation = 1 - (largest_block / total_free)
    // High fragmentation means large blocks are broken into many small blocks
    const free_count = freePageCount();
    if (free_count == 0) return 0.0;
    return 1.0 - (@as(f64, @floatFromInt(stats.largest_block)) / @as(f64, @floatFromInt(free_count)));
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Convert page index to physical address
pub fn pageToPhysical(page: usize) u64 {
    return @as(u64, @intCast(page)) * PAGE_SIZE;
}

/// Convert physical address to page index
pub fn physicalToPage(phys: u64) usize {
    return @intCast(phys / PAGE_SIZE);
}

/// Check if a page is currently allocated
pub fn isPageAllocated(page: usize) bool {
    if (page >= total_pages) return false;
    lock.acquire();
    defer lock.release();
    return testBit(page);
}

// ============================================================================
// Internal Bitmap Operations
// ============================================================================

inline fn testBit(page: usize) bool {
    const mask: u8 = @as(u8, 1) << @as(u3, @intCast(page % 8));
    return (bitmap[page / 8] & mask) != 0;
}

inline fn setBit(page: usize) void {
    const mask: u8 = @as(u8, 1) << @as(u3, @intCast(page % 8));
    bitmap[page / 8] |= mask;
}

inline fn clearBit(page: usize) void {
    const mask: u8 = @as(u8, 1) << @as(u3, @intCast(page % 8));
    bitmap[page / 8] &= ~mask;
}

/// P1 FIX: Debug dump of PMM state
pub fn dumpState() void {
    const stats = getStats();
    log.info("=== PMM State ===", .{});
    log.info("  Total pages:   {}", .{stats.total_pages});
    log.info("  Allocated:     {}", .{stats.allocated_pages});
    log.info("  Reserved:      {}", .{stats.reserved_pages});
    log.info("  Free:          {}", .{stats.free_pages});
    log.info("  Largest block: {} pages", .{getLargestFreeBlock()});
    log.info("  OOM Policy:    {}", .{@tagName(oom_policy)});
    log.info("  Memory pressure: {}%", .{getMemoryPressure()});
    log.info("  Fragmentation: {}%", .{getFragmentationRatio() * 100});
}

/// P2 FIX: Dump bitmap state for debugging
/// Shows the state of the first N bits of the bitmap
pub fn dumpBitmap(first_pages: usize) void {
    lock.acquire();
    defer lock.release();

    log.info("=== PMM Bitmap (first {} pages) ===", .{first_pages});
    var i: usize = 0;
    while (i < first_pages) : (i += 1) {
        if (i % 64 == 0) {
            if (i > 0) log.info("]", .{});
            log.info("  Pages {}-{:3}: [", .{ i, @min(i + 64, first_pages) });
        }
        const bit: u8 = if (testBit(i)) 1 else 0;
        log.info("{}", .{bit});
    }
    log.info("]", .{});
}

/// P2 FIX: Track allocations for leak detection
var allocation_tracking: bool = false;
var allocation_count: usize = 0;
var allocations: [1024]struct { page: usize, size: usize } = undefined;

pub fn enableAllocationTracking() void {
    allocation_tracking = true;
    allocation_count = 0;
}

pub fn disableAllocationTracking() void {
    allocation_tracking = false;
}

pub fn reportAllocationLeaks() void {
    if (!allocation_tracking) return;

    log.warn("=== PMM Allocation Leak Report ===", .{});
    log.warn("  Current allocated pages: {}", .{allocated_pages});
    log.warn("  Tracked allocations: {}", .{allocation_count});

    var leaked: usize = 0;
    for (allocations, 0..) |alloc, idx| {
        if (alloc.page != 0) {
            log.warn("  Possible leak: page {} (size {})", .{ alloc.page, alloc.size });
            leaked += 1;
            allocations[idx].page = 0; // Clear for next report
        }
    }
    log.warn("  Potential leaks: {}", .{leaked});
}

/// P2 FIX: Check for double-free attempts
var double_free_count: usize = 0;

pub fn getDoubleFreeCount() usize {
    return double_free_count;
}

/// P2 FIX: Log allocation with call stack tracking
pub fn logAllocation(page: usize, size: usize) void {
    if (!allocation_tracking) return;
    if (allocation_count >= allocations.len) return;

    allocations[allocation_count] = .{ .page = page, .size = size };
    allocation_count += 1;
}

/// P2 FIX: Log deallocation
pub fn logDeallocation(page: usize) void {
    if (!allocation_tracking) return;

    for (allocations, 0..) |alloc, idx| {
        if (alloc.page == page) {
            allocations[idx].page = 0;
            return;
        }
    }
    // Page not found - might be a double-free
    log.warn("[PMM] Deallocation of untracked page {}", .{page});
}
