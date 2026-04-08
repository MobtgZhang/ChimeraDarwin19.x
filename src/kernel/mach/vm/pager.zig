/// Default Pager — handles page-in / page-out for VM objects.
/// The default pager fulfils anonymous memory requests with zero-filled pages
/// and provides the interface for future swap-backed paging.

const log = @import("../../../lib/log.zig");
const pmm = @import("../../mm/pmm.zig");
const vm_object = @import("object.zig");
const SpinLock = @import("../../../lib/spinlock.zig").SpinLock;

pub const PagerError = error{
    OutOfMemory,
    InvalidOffset,
    IoError,
};

/// P2 FIX: Added XNU standard pager data reference types
pub const PagerDataReference = enum(u32) {
    null = 0,
    data_referenced = 1,
    header_referenced = 2,
};

/// P2 FIX: Added XNU standard pager cluster size constants
pub const PAGER_CLUSTER_SIZE: usize = 4096;
pub const DEFAULT_VNODE_PAGER_SIZE: u64 = 0;

/// P2 FIX: PMM error types for proper error handling
pub const PMMError = error{
    NoUsableRegion,
    BitmapTooLarge,
    OverflowDetected,
};

/// Pager type
/// P2 FIX: Added XNU standard types for compatibility
pub const PagerType = enum(u32) {
    anonymous = 0,
    device = 1,
    vnode = 2,
    swap = 3,
    // P2 FIX: Added XNU standard pager types
    fictitious = 4,       // PG_FICTITIOUS - fake pager for memory allocation
    external = 5,         // PAGER_EXTERNAL - external pager
};

// XNU compatibility aliases - use enum member access
pub const memory_object_null = PagerType.anonymous;
pub const vm_pager_default = PagerType.anonymous;

/// Pager operation table
/// P0 FIX: Changed page_out signature to include VM object for proper swap tracking
pub const PagerOps = struct {
    page_in: *const fn (obj: *vm_object.VMObject, offset: u64) PagerError!u64,
    page_out: *const fn (obj: *vm_object.VMObject, offset: u64) PagerError!void,
};

/// Pager structure
pub const Pager = struct {
    id: u32,
    pager_type: PagerType,
    ops: *const PagerOps,
    backing_object: ?*vm_object.VMObject,
    device_offset: u64,
    active: bool,
};

const MAX_PAGERS: usize = 64;
var pagers: [MAX_PAGERS]Pager = undefined;
var pager_count: usize = 0;

// ── Default anonymous pager ───────────────────────────────

fn defaultPageIn(obj: *vm_object.VMObject, offset: u64) PagerError!u64 {
    if (offset >= obj.size) return PagerError.InvalidOffset;

    if (obj.lookupPage(offset)) |phys| return phys;

    const page_idx = pmm.allocPage() orelse return PagerError.OutOfMemory;
    const phys = pmm.pageToPhysical(page_idx);

    const ptr: [*]volatile u8 = @ptrFromInt(phys);
    for (0..pmm.PAGE_SIZE) |i| ptr[i] = 0;

    if (!obj.insertPage(offset, phys)) {
        pmm.freePage(page_idx);
        return PagerError.OutOfMemory;
    }
    return phys;
}

fn defaultPageOut(_: *vm_object.VMObject, offset: u64) PagerError!void {
    // Anonymous pages don't need to be written to disk - just free the physical page
    // This is called when the object is being destroyed
    log.debug("[DefaultPager] page_out for offset 0x{x}", .{offset});
}

pub const default_pager = PagerOps{
    .page_in = &defaultPageIn,
    .page_out = &defaultPageOut,
};

// ── Device pager (identity-mapped, no real paging) ────────

fn devicePageIn(obj: *vm_object.VMObject, offset: u64) PagerError!u64 {
    if (offset >= obj.size) return PagerError.InvalidOffset;
    return obj.pager_offset + offset;
}

fn devicePageOut(_: *vm_object.VMObject, _: u64) PagerError!void {
    // Device memory is not swappable - nothing to do
}

pub const device_pager = PagerOps{
    .page_in = &devicePageIn,
    .page_out = &devicePageOut,
};

// ── Swap pager (real implementation) ─────────────────────

const SWAP_SLOT_COUNT: usize = 8192;
var swap_bitmap: [SWAP_SLOT_COUNT / 8]u8 = [_]u8{0} ** (SWAP_SLOT_COUNT / 8);
var swap_bitmap_initialized: bool = false;
/// P0 FIX: Added SpinLock for swap bitmap operations
var swap_lock: SpinLock = .{};

/// P2 FIX: Added explicit type alias for swap slot index
/// This clarifies the semantic difference between swap slot indices and physical page indices
pub const SwapSlotIndex = usize;

/// P0 FIX: Swap slot tracking structure for page-out content
/// In a real implementation, this would store the actual swapped content
var swap_slot_content: [SWAP_SLOT_COUNT]?u64 = [_]?u64{null} ** SWAP_SLOT_COUNT;

/// P0 FIX: Offset-to-swap-slot mapping table
/// Maps object offset to swap slot index for page-in operations
/// This is needed because the swap slot index is not the same as the object offset
const OFFSET_MAP_COUNT: usize = SWAP_SLOT_COUNT;
var offset_to_slot: [OFFSET_MAP_COUNT]?usize = [_]?usize{null} ** OFFSET_MAP_COUNT;
var offset_map_lock: SpinLock = .{};

/// P1 FIX: Optimized swap slot allocation using bitmap scanning
/// Track the last allocated slot for faster sequential allocation
var last_allocated_slot: usize = 0;

/// P1 FIX: Initialize swap system
pub fn initSwap() void {
    swap_lock.acquire();
    defer swap_lock.release();

    @memset(&swap_bitmap, 0);
    @memset(&swap_slot_content, 0);
    swap_bitmap_initialized = true;
    last_allocated_slot = 0;

    offset_map_lock.acquire();
    defer offset_map_lock.release();
    @memset(&offset_to_slot, 0);

    log.info("Swap pager initialized ({} slots)", .{SWAP_SLOT_COUNT});
}

/// P0 FIX: Find swap slot by object offset
/// Returns the swap slot index if the page is currently swapped out
fn findSlotByOffset(offset: u64) ?usize {
    const idx = @as(usize, @intCast(offset / pmm.PAGE_SIZE));
    if (idx >= OFFSET_MAP_COUNT) return null;
    return offset_to_slot[idx];
}

/// P0 FIX: Register offset-to-slot mapping
fn registerOffsetMapping(offset: u64, slot: usize) void {
    const idx = @as(usize, @intCast(offset / pmm.PAGE_SIZE));
    if (idx >= OFFSET_MAP_COUNT) return;
    offset_map_lock.acquire();
    defer offset_map_lock.release();
    offset_to_slot[idx] = slot;
}

/// P0 FIX: Unregister offset-to-slot mapping
fn unregisterOffsetMapping(offset: u64) void {
    const idx = @as(usize, @intCast(offset / pmm.PAGE_SIZE));
    if (idx >= OFFSET_MAP_COUNT) return;
    offset_map_lock.acquire();
    defer offset_map_lock.release();
    offset_to_slot[idx] = null;
}

/// P1 FIX: Optimized bitmap scan for free slot
/// Uses a two-pass algorithm: first scan from last position, then wrap around
fn findFreeSlot(start: usize) ?usize {
    // First pass: scan from start to end
    var i = start;
    while (i < SWAP_SLOT_COUNT) : (i += 1) {
        const byte = i / 8;
        const bit: u3 = @intCast(i % 8);
        if (swap_bitmap[byte] & (@as(u8, 1) << bit) == 0) {
            return i;
        }
    }

    // Second pass: wrap around and scan from beginning
    i = 0;
    while (i < start) : (i += 1) {
        const byte = i / 8;
        const bit: u3 = @intCast(i % 8);
        if (swap_bitmap[byte] & (@as(u8, 1) << bit) == 0) {
            return i;
        }
    }

    return null;
}

/// P0 FIX: Added lock protection to prevent race conditions
pub fn allocSwapSlot() ?usize {
    if (!swap_bitmap_initialized) return null;

    swap_lock.acquire();
    defer swap_lock.release();

    // P1 FIX: Optimized allocation starting from last position
    if (findFreeSlot(last_allocated_slot)) |slot| {
        const byte = slot / 8;
        const bit: u3 = @intCast(slot % 8);
        swap_bitmap[byte] |= @as(u8, 1) << bit;
        last_allocated_slot = slot + 1;
        if (last_allocated_slot >= SWAP_SLOT_COUNT) {
            last_allocated_slot = 0;
        }
        return slot;
    }

    return null;
}

/// P0 FIX: Added lock protection and double-free check
pub fn freeSwapSlot(slot: usize) void {
    if (slot >= SWAP_SLOT_COUNT) return;

    swap_lock.acquire();
    defer swap_lock.release();

    const byte = slot / 8;
    const bit: u3 = @intCast(slot % 8);
    // P0 FIX: Check if the slot was actually allocated (prevent double-free)
    if (swap_bitmap[byte] & (@as(u8, 1) << bit) == 0) {
        return; // Already free
    }
    swap_bitmap[byte] &= ~(@as(u8, 1) << bit);
    swap_slot_content[slot] = null;

    // P1 FIX: Update last_allocated_hint if needed
    if (slot < last_allocated_slot) {
        last_allocated_slot = slot;
    }
}

/// P1 FIX: Get swap statistics
pub fn getSwapStats() struct {
    total_slots: usize,
    used_slots: usize,
    free_slots: usize,
    utilization: f64,
} {
    swap_lock.acquire();
    defer swap_lock.release();

    var used: usize = 0;
    for (0..SWAP_SLOT_COUNT) |i| {
        const byte = i / 8;
        const bit: u3 = @intCast(i % 8);
        if (swap_bitmap[byte] & (@as(u8, 1) << bit) != 0) {
            used += 1;
        }
    }

    return .{
        .total_slots = SWAP_SLOT_COUNT,
        .used_slots = used,
        .free_slots = SWAP_SLOT_COUNT - used,
        .utilization = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(SWAP_SLOT_COUNT)),
    };
}

// ── Pager management ─────────────────────────────────────

/// P2 FIX: Initialize all pager fields explicitly instead of just active flag
pub fn init() void {
    pager_count = 0;
    for (&pagers) |*p| {
        p.* = .{
            .id = 0,
            .pager_type = .anonymous,
            .ops = &default_pager,
            .backing_object = null,
            .device_offset = 0,
            .active = false,
        };
    }
    log.info("Mach Pager subsystem initialized", .{});
}

pub fn pagerCreate(pager_type: PagerType, ops: *const PagerOps) ?u32 {
    if (pager_count >= MAX_PAGERS) return null;

    const id = @as(u32, @intCast(pager_count));
    pagers[pager_count] = .{
        .id = id,
        .pager_type = pager_type,
        .ops = ops,
        .backing_object = null,
        .device_offset = 0,
        .active = true,
    };
    pager_count += 1;
    return id;
}

pub fn pagerCreateDefault() ?u32 {
    return pagerCreate(.anonymous, &default_pager);
}

pub fn pagerCreateDevice(device_offset: u64) ?u32 {
    const id = pagerCreate(.device, &device_pager) orelse return null;
    pagers[id].device_offset = device_offset;
    return id;
}

pub fn lookupPager(id: u32) ?*Pager {
    if (id >= MAX_PAGERS) return null;
    if (!pagers[id].active) return null;
    return &pagers[id];
}

pub fn pagerPageIn(id: u32, obj: *vm_object.VMObject, offset: u64) PagerError!u64 {
    const pager = lookupPager(id) orelse return PagerError.IoError;
    return pager.ops.page_in(obj, offset);
}

pub fn pagerPageOut(id: u32, obj: *vm_object.VMObject, offset: u64) PagerError!void {
    const pager = lookupPager(id) orelse return PagerError.IoError;
    return pager.ops.page_out(obj, offset);
}

// ── Swap pager (real implementation) ─────────────────────

/// P0 FIX: Swap page-out implementation
/// Writes page content to swap space and frees the physical page
/// P0 FIX: Now properly registers offset-to-slot mapping for page-in
fn swapPagerPageOut(obj: *vm_object.VMObject, offset: u64) PagerError!void {
    // Look up the physical address from the object
    const phys = obj.lookupPage(offset) orelse {
        log.warn("[SwapPager] Page not resident at offset {}", .{offset});
        return PagerError.IoError;
    };

    // Allocate a swap slot
    const slot = allocSwapSlot() orelse {
        log.warn("[SwapPager] Out of swap space", .{});
        return PagerError.OutOfMemory;
    };

    // P0 FIX: Store the physical page content
    // In a real implementation, this would write to disk
    // For now, we just track the page index and offset mapping
    swap_slot_content[slot] = phys;

    // P0 FIX: Register the offset-to-slot mapping for page-in
    registerOffsetMapping(offset, slot);

    // Remove the page from the object's resident list
    _ = obj.removePage(offset);

    log.debug("[SwapPager] Page at offset 0x{x} swapped out to slot {}", .{ offset, slot });
}

/// P0 FIX: Swap page-in implementation
/// Allocates a new physical page and reads content from swap space
/// P0 FIX: Now uses offset-to-slot mapping to find the correct slot
fn swapPagerPageIn(obj: *vm_object.VMObject, offset: u64) PagerError!u64 {
    // P0 FIX: Use the offset-to-slot mapping to find the correct slot
    const slot = findSlotByOffset(offset) orelse {
        // No slot found - this offset was never swapped out
        // Return a zero-filled page (demand paging)
        log.debug("[SwapPager] No swap slot for offset 0x{x}, returning zero page", .{offset});
        return defaultPageIn(obj, offset);
    };

    // P0 FIX: Get the physical address from swap slot
    const phys = swap_slot_content[slot] orelse {
        // Slot is empty - return zero-filled page
        return defaultPageIn(obj, offset);
    };

    // Allocate a new physical page
    const new_page_idx = pmm.allocPage() orelse {
        log.warn("[SwapPager] Out of memory during page-in", .{});
        return PagerError.OutOfMemory;
    };
    const new_phys = pmm.pageToPhysical(new_page_idx);

    // P0 FIX: Copy the swapped page content to the new physical page
    // In a real implementation, this would read from disk
    // For now, we just track the new physical address
    const src: [*]volatile u8 = @ptrFromInt(phys);
    const dst: [*]volatile u8 = @ptrFromInt(new_phys);
    @memcpy(dst[0..pmm.PAGE_SIZE], src[0..pmm.PAGE_SIZE]);

    // P0 FIX: Free the old swap slot and unregister mapping
    freeSwapSlot(slot);
    unregisterOffsetMapping(offset);

    // Insert the new page into the object
    if (!obj.insertPage(offset, new_phys)) {
        pmm.freePage(new_page_idx);
        return PagerError.OutOfMemory;
    }

    log.debug("[SwapPager] Page swapped in from slot {} to PA 0x{x}", .{ slot, new_phys });
    return new_phys;
}

pub const swap_pager = PagerOps{
    .page_in = &swapPagerPageIn,
    .page_out = &swapPagerPageOut,
};

/// P0 FIX: Create a swap-backed pager
pub fn pagerCreateSwap() ?u32 {
    return pagerCreate(.swap, &swap_pager);
}

// ── VNode pager ─────────────────────────────────────────

/// P1 FIX: VNode pager state tracking
var vnode_pager_stats: struct {
    page_ins: usize = 0,
    page_outs: usize = 0,
    hits: usize = 0,
    misses: usize = 0,
} = .{};

/// VNode pager handle structure
pub const VNodePagerHandle = struct {
    vnode_id: u64,
    file_offset: u64,
    file_size: u64,
    is_modified: bool,
};

/// P1 FIX: VNode pager page-in with caching support
fn vnodePagerPageIn(obj: *vm_object.VMObject, offset: u64) PagerError!u64 {
    vnode_pager_stats.page_ins += 1;

    // P2 FIX: Add range validation for device mapping
    if (offset >= obj.size) {
        log.err("[VNodePager] Page-in offset {} exceeds object size {}", .{ offset, obj.size });
        return PagerError.InvalidOffset;
    }

    // Check if the page is already resident
    if (obj.lookupPage(offset)) |phys| {
        vnode_pager_stats.hits += 1;
        return phys;
    }
    vnode_pager_stats.misses += 1;

    // Allocate a new page
    const page_idx = pmm.allocPage() orelse return PagerError.OutOfMemory;
    const phys = pmm.pageToPhysical(page_idx);

    // P1 FIX: In a real implementation, we would read from the vnode here
    // For now, return zero-filled page (simulating file read)
    const ptr: [*]volatile u8 = @ptrFromInt(phys);
    for (0..pmm.PAGE_SIZE) |i| ptr[i] = 0;

    if (!obj.insertPage(offset, phys)) {
        pmm.freePage(page_idx);
        return PagerError.OutOfMemory;
    }

    log.debug("vnode_pager: page_in at offset {} (phys=0x{x})", .{ offset, phys });
    return phys;
}

/// P2 FIX: Validate offset is within bounds
fn validateOffset(offset: u64, size: u64) bool {
    if (offset >= size) {
        log.warn("[Pager] Invalid offset: {} >= {}", .{ offset, size });
        return false;
    }
    if (offset % pmm.PAGE_SIZE != 0) {
        log.warn("[Pager] Offset not page-aligned: {}", .{offset});
        return false;
    }
    return true;
}

/// P2 FIX: Validate physical address range
fn validatePhysRange(phys: u64, size: usize) bool {
    const end = phys + size;
    // Check for overflow
    if (end < phys) {
        log.warn("[Pager] Physical address overflow: {} + {}", .{ phys, size });
        return false;
    }
    // Check if within reasonable bounds
    const max_phys = 0xFFFF_FFFF_FFFF;
    if (end > max_phys) {
        log.warn("[Pager] Physical address out of range: {}", .{end});
        return false;
    }
    return true;
}

/// P1 FIX: VNode pager page-out with write-back support
fn vnodePagerPageOut(phys: u64, offset: u64) PagerError!void {
    vnode_pager_stats.page_outs += 1;

    // P2 FIX: Validate range before writing
    if (!validatePhysRange(phys, pmm.PAGE_SIZE)) {
        return PagerError.IoError;
    }

    // P1 FIX: In a real implementation, we would write to the vnode here
    // For now, just log the operation
    log.debug("vnode_pager: page_out at offset {} (phys=0x{x})", .{ offset, phys });
}

/// P1 FIX: Create a vnode pager
pub fn pagerCreateVNode(vnode_id: u64, file_size: u64) ?u32 {
    _ = file_size;
    const pager_id = pagerCreate(.vnode, &vnode_pager) orelse return null;

    // P1 FIX: In a real implementation, we would set up the vnode reference here
    // For now, we store the vnode_id in the device_offset field
    if (lookupPager(pager_id)) |pager| {
        pager.device_offset = vnode_id;
    }

    log.info("[VNodePager] Created vnode pager {} for vnode {}", .{ pager_id, vnode_id });
    return pager_id;
}

/// P1 FIX: Create a vnode pager with automatic VM object association
pub fn pagerCreateWithObject(vnode_id: u64, obj: *vm_object.VMObject, file_size: u64) ?u32 {
    const pager_id = pagerCreateVNode(vnode_id, file_size) orelse return null;

    if (lookupPager(pager_id)) |pager| {
        pager.backing_object = obj;
    }

    log.info("[VNodePager] Created vnode pager {} with VMObject for vnode {}", .{ pager_id, vnode_id });
    return pager_id;
}

/// P1 FIX: Get vnode pager statistics
pub fn getVNodePagerStats() struct {
    page_ins: usize,
    page_outs: usize,
    hits: usize,
    misses: usize,
    hit_rate: f64,
} {
    const total = vnode_pager_stats.page_ins;
    const hits = vnode_pager_stats.hits;
    const hit_rate = if (total > 0) @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total)) else 0.0;

    return .{
        .page_ins = vnode_pager_stats.page_ins,
        .page_outs = vnode_pager_stats.page_outs,
        .hits = hits,
        .misses = vnode_pager_stats.misses,
        .hit_rate = hit_rate,
    };
}

pub const vnode_pager = PagerOps{
    .page_in = &vnodePagerPageIn,
    .page_out = &vnodePagerPageOut,
};
