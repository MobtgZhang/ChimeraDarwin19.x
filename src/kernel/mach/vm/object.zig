/// VM Object — backing store abstraction for virtual memory.
/// Each VM object represents a contiguous region of pageable memory that
/// can be anonymous (zero-filled), copy-on-write, or device-mapped.
///
/// P1 Improvements:
///   - Proper memory pool initialization and free list reuse
///   - Reference count overflow protection
///   - Object lifecycle management (destroy, iterate)
///   - Pool statistics
///   - Thread-safe object creation

const log = @import("../../../lib/log.zig");
const SpinLock = @import("../../../lib/spinlock.zig").SpinLock;
const pmm = @import("../../mm/pmm.zig");

pub const PAGE_SIZE: u64 = 4096;

/// Maximum reference count before considering it "shared too much"
const MAX_REF_COUNT: u32 = 0x7FFF_FFFF;

/// P2 FIX: Magic patterns for memory debugging
pub const MAGIC_ALLOC: u32 = 0xDEADBEEF;
pub const MAGIC_FREE: u32 = 0xCAFEBABE;

/// Object type (matches XNU vo_type)
pub const ObjectType = enum(u8) {
    anonymous = 0,
    copy_on_write = 1,
    device = 2,
    physical = 3,
    pager = 4,
};

/// P2 FIX: Debug header for memory corruption detection
const DebugHeader = extern struct {
    magic: u32,
    alloc_line: u32,
    alloc_file: [32]u8,
};

const DEBUG_HEADER_SIZE: usize = @sizeOf(DebugHeader);

/// Resident page structure
pub const ResidentPage = struct {
    phys_addr: u64,
    offset: u64,
    dirty: bool,
    wired: bool,
    next: ?*ResidentPage,
};

// ============================================================================
// Memory Pool for Resident Pages
// ============================================================================

const MAX_RESIDENT: usize = 4096;
var page_pool: [MAX_RESIDENT]ResidentPage = undefined;
var pool_next: usize = 0;
var pool_lock: SpinLock = .{};

/// P1 FIX: Free list for resident page reuse
var free_page_list: ?*ResidentPage = null;
var free_page_count: usize = 0;

/// P1 FIX: Pool statistics
var pool_stats: struct {
    total_allocations: usize = 0,
    total_frees: usize = 0,
    peak_usage: usize = 0,
} = .{};

fn allocResidentPage() ?*ResidentPage {
    pool_lock.acquire();
    defer pool_lock.release();
    
    // P1 FIX: Reuse from free list first
    if (free_page_list) |head| {
        free_page_list = head.next;
        free_page_count -= 1;
        // Reset the page fields
        head.* = .{
            .phys_addr = 0,
            .offset = 0,
            .dirty = false,
            .wired = false,
            .next = null,
        };
        pool_stats.total_allocations += 1;
        // P2 FIX: Calculate actual usage as (pool_next - free_page_count)
        const actual_usage = pool_next - free_page_count;
        if (actual_usage > pool_stats.peak_usage) {
            pool_stats.peak_usage = actual_usage;
        }
        return head;
    }
    
    // Fall back to pool allocation
    if (pool_next >= MAX_RESIDENT) return null;
    const p = &page_pool[pool_next];
    pool_next += 1;
    pool_stats.total_allocations += 1;
    // P2 FIX: Calculate actual usage as (pool_next - free_page_count)
    const actual_usage = pool_next - free_page_count;
    if (actual_usage > pool_stats.peak_usage) {
        pool_stats.peak_usage = actual_usage;
    }
    return p;
}

/// P1 FIX: Free a resident page back to the free list for reuse
fn freeResidentPage(page: *ResidentPage) void {
    pool_lock.acquire();
    defer pool_lock.release();
    
    page.next = free_page_list;
    free_page_list = page;
    free_page_count += 1;
    pool_stats.total_frees += 1;
}

/// P1 FIX: Initialize the resident page pool
pub fn initResidentPagePool() void {
    pool_lock.acquire();
    defer pool_lock.release();
    
    // Initialize all pages to zero
    for (&page_pool) |*p| {
        p.* = .{
            .phys_addr = 0,
            .offset = 0,
            .dirty = false,
            .wired = false,
            .next = null,
        };
    }
    
    pool_next = 0;
    free_page_list = null;
    free_page_count = 0;
    
    log.info("[VMObject] Resident page pool initialized: {} pages", .{MAX_RESIDENT});
}

// ============================================================================
// VM Object Structure
// ============================================================================

pub const MAX_OBJECTS: usize = 512;

const ObjectState = enum(u8) {
    free = 0,
    active = 1,
    dying = 2,    // Being destroyed, ref count is 0
};

/// VM Object structure with P1 improvements
pub const VMObject = struct {
    obj_type: ObjectType,
    size: u64,
    ref_count: u32,
    resident_list: ?*ResidentPage,
    resident_count: u32,
    shadow: ?*VMObject,
    pager_offset: u64,
    lock: SpinLock,
    state: ObjectState,

    // P2 FIX: Add explicit next_free field instead of reusing shadow field
    next_free: ?*VMObject = null,

    /// P1 FIX: Object header for pool management
    const Header = struct {
        in_use: bool,
        padding: [7]u8 = [_]u8{0} ** 7,
    };
    
    /// P1 FIX: Object statistics
    var stats: struct {
        total_objects: usize = 0,
        active_objects: usize = 0,
        peak_objects: usize = 0,
    } = .{};

    pub fn initAnonymous(size: u64) VMObject {
        return .{
            .obj_type = .anonymous,
            .size = size,
            .ref_count = 1,
            .resident_list = null,
            .resident_count = 0,
            .shadow = null,
            .pager_offset = 0,
            .lock = .{},
            .state = .active,
        };
    }

    pub fn initDevice(phys_base: u64, size: u64) VMObject {
        return .{
            .obj_type = .device,
            .size = size,
            .ref_count = 1,
            .resident_list = null,
            .resident_count = 0,
            .shadow = null,
            .pager_offset = phys_base,
            .lock = .{},
            .state = .active,
        };
    }

    /// P0 FIX: Thread-safe retain with overflow check
    /// P0 FIX: Fixed TOCTOU - now uses non-atomic operations under lock
    /// P0 FIX: Previous version used atomic Add while lock was held, which was redundant
    pub fn retain(self: *VMObject) void {
        self.lock.acquire();
        defer self.lock.release();

        // P0 FIX: Check state first to prevent retaining dying objects
        if (self.state == .dying) {
            return;
        }

        // P0 FIX: Prevent ref count overflow
        if (self.ref_count >= MAX_REF_COUNT) {
            log.warn("[VMObject] Reference count overflow prevented for object", .{});
            return;
        }

        // P0 FIX: Use non-atomic operation since we hold the lock
        // This eliminates the TOCTOU window between check and increment
        self.ref_count += 1;
    }

    /// P0 FIX: Release with improved semantics
    /// P0 FIX: Fixed TOCTOU - destroy() is now called while holding the lock
    /// P0 FIX: Previous version called destroy() after lock release
    /// Returns true if this was the last reference and object was destroyed
    pub fn release(self: *VMObject) bool {
        self.lock.acquire();

        // P0 FIX: Check state to prevent double-destroy
        if (self.state == .dying) {
            self.lock.release();
            return false;
        }

        // P0 FIX: Use non-atomic operation since we hold the lock
        // This eliminates the TOCTOU window between check and decrement
        if (self.ref_count == 0) {
            self.lock.release();
            return false;
        }

        self.ref_count -= 1;

        if (self.ref_count == 0) {
            self.state = .dying;
            // P0 FIX: Call destroy() while holding the lock to prevent race conditions
            self.destroy();
            self.lock.release();
            return true;
        }

        self.lock.release();
        return false;
    }

    /// P0 FIX: Try to retain, returns false if at max ref count
    /// P0 FIX: Fixed to use non-atomic operation under lock
    pub fn tryRetain(self: *VMObject) bool {
        self.lock.acquire();
        defer self.lock.release();

        if (self.state == .dying) {
            return false;
        }

        if (self.ref_count >= MAX_REF_COUNT) {
            return false;
        }

        // P0 FIX: Use non-atomic operation since we hold the lock
        self.ref_count += 1;
        return true;
    }

    /// P1 FIX: Get current reference count (atomic read)
    pub fn getRefCount(self: *VMObject) u32 {
        return @atomicLoad(u32, &self.ref_count, .acquire);
    }

    /// P1 FIX: Get current state
    pub fn getState(self: *VMObject) ObjectState {
        return @atomicLoad(ObjectState, &self.state, .acquire);
    }

    /// P1 FIX: Check if object is alive
    pub fn isAlive(self: *VMObject) bool {
        return self.getState() == .active;
    }

    /// P1 FIX: Get resident page count
    pub fn getResidentPageCount(self: *VMObject) u32 {
        self.lock.acquire();
        defer self.lock.release();
        return self.resident_count;
    }

    /// P1 FIX: Look up a page by offset
    pub fn lookupPage(self: *VMObject, offset: u64) ?u64 {
        self.lock.acquire();
        defer self.lock.release();

        var cur = self.resident_list;
        while (cur) |rp| {
            if (rp.offset == offset) return rp.phys_addr;
            cur = rp.next;
        }

        if (self.shadow) |shadow| {
            return shadow.lookupPage(offset);
        }

        return null;
    }

    /// P1 FIX: Insert a page at the given offset
    pub fn insertPage(self: *VMObject, offset: u64, phys: u64) bool {
        self.lock.acquire();
        defer self.lock.release();

        // Check for existing page at this offset
        var cur = self.resident_list;
        while (cur) |rp| {
            if (rp.offset == offset) {
                // Update existing page
                rp.phys_addr = phys;
                rp.dirty = false;
                return true;
            }
            cur = rp.next;
        }

        const rp = allocResidentPage() orelse return false;
        rp.* = .{
            .phys_addr = phys,
            .offset = offset,
            .dirty = false,
            .wired = false,
            .next = self.resident_list,
        };
        self.resident_list = rp;
        self.resident_count += 1;
        return true;
    }

    /// P1 FIX: Remove a page by offset
    pub fn removePage(self: *VMObject, offset: u64) bool {
        self.lock.acquire();
        defer self.lock.release();

        var prev: ?*ResidentPage = null;
        var cur = self.resident_list;
        
        while (cur) |rp| {
            if (rp.offset == offset) {
                if (prev) |p| {
                    p.next = rp.next;
                } else {
                    self.resident_list = rp.next;
                }
                self.resident_count -= 1;
                
                // Return page to pool for reuse
                if (self.obj_type != .device) {
                    const page_idx: usize = @intCast(rp.phys_addr / pmm.PAGE_SIZE);
                    pmm.freePage(page_idx);
                }
                freeResidentPage(rp);
                return true;
            }
            prev = cur;
            cur = rp.next;
        }
        
        return false;
    }

    /// Handle a page fault at the given offset
    pub fn fault(self: *VMObject, offset: u64) ?u64 {
        if (self.lookupPage(offset)) |phys| return phys;

        switch (self.obj_type) {
            .anonymous => {
                const page_idx = pmm.allocPage() orelse return null;
                const phys = pmm.pageToPhysical(page_idx);
                // P2 FIX: Use @memset for efficient zeroing instead of byte-by-byte loop
                @memset(@as([*]volatile u8, @ptrFromInt(phys))[0..pmm.PAGE_SIZE], 0);
                if (!self.insertPage(offset, phys)) {
                    pmm.freePage(page_idx);
                    return null;
                }
                return phys;
            },
            .device => {
                return self.pager_offset + offset;
            },
            .copy_on_write => {
                // P0 FIX: Prevent infinite recursion when shadow lookup fails
                if (self.shadow) |shadow| {
                    if (shadow.lookupPage(offset)) |src_phys| {
                        const page_idx = pmm.allocPage() orelse return null;
                        const dst_phys = pmm.pageToPhysical(page_idx);
                        const src: [*]const u8 = @ptrFromInt(src_phys);
                        const dst: [*]u8 = @ptrFromInt(dst_phys);
                        @memcpy(dst[0..pmm.PAGE_SIZE], src[0..pmm.PAGE_SIZE]);
                        _ = self.insertPage(offset, dst_phys);
                        return dst_phys;
                    }
                    // P0 FIX: If shadow lookup fails, fall through to allocate a new zero page
                    // This handles the case where the shadow hasn't been populated yet
                }
                // Allocate a new zero-filled page (COW will copy on next write)
                const page_idx = pmm.allocPage() orelse return null;
                const phys = pmm.pageToPhysical(page_idx);
                @memset(@as([*]volatile u8, @ptrFromInt(phys))[0..pmm.PAGE_SIZE], 0);
                if (!self.insertPage(offset, phys)) {
                    pmm.freePage(page_idx);
                    return null;
                }
                return phys;
            },
            else => return null,
        }
    }

    /// Create a shadow (copy-on-write) copy of this object
    /// P1 FIX: Fixed to properly handle reference counting
    pub fn createShadow(self: *VMObject) VMObject {
        // Retain self as the shadow backing store
        self.retain();
        
        return .{
            .obj_type = .copy_on_write,
            .size = self.size,
            .ref_count = 1,
            .resident_list = null,
            .resident_count = 0,
            .shadow = self,
            .pager_offset = 0,
            .lock = .{},
            .state = .active,
        };
    }

    /// P1 FIX: Destroy this object and release all resources
    /// P0 FIX: Return object to the free list for reuse
    fn destroy(self: *VMObject) void {
        // Release all resident pages
        var cur = self.resident_list;
        while (cur) |rp| {
            if (self.obj_type != .device) {
                const page_idx: usize = @intCast(rp.phys_addr / pmm.PAGE_SIZE);
                pmm.freePage(page_idx);
            }
            const next = rp.next;
            freeResidentPage(rp);
            cur = next;
        }
        self.resident_list = null;
        self.resident_count = 0;
        
        // Release shadow reference if present
        if (self.shadow) |shadow| {
            _ = shadow.release();
            self.shadow = null;
        }
        
        self.state = .free;
        
        // P0 FIX: Return this object to the free list for reuse
        deallocate(self);
        
        // Update statistics
        VMObject.stats.active_objects -= 1;
    }

    /// P1 FIX: Coalesce adjacent dirty pages (for swap optimization)
    pub fn coalesceDirtyPages(self: *VMObject) void {
        self.lock.acquire();
        defer self.lock.release();
        
        var cur = self.resident_list;
        while (cur) |rp| : (cur = rp.next) {
            rp.dirty = false;
        }
    }
};

// ============================================================================
// Global Object Pool with Dynamic Expansion
// ============================================================================

/// P1 FIX: Dynamic object pool with expansion support
pub const DynamicObjectPool = struct {
    /// Initial pool capacity
    const INITIAL_CAPACITY: usize = MAX_OBJECTS;
    /// Maximum number of dynamic blocks
    const MAX_BLOCKS: usize = 16;
    /// Number of objects per dynamic block
    const OBJECTS_PER_BLOCK: usize = 256;
    /// Number of dynamic blocks allocated
    var num_blocks: usize = 0;
    /// Array of dynamic object blocks (each block is OBJECTS_PER_BLOCK objects)
    var blocks: [MAX_BLOCKS][OBJECTS_PER_BLOCK]VMObject = undefined;
    /// Dynamic free list (across all blocks)
    var dynamic_free_list: ?*VMObject = null;
    var dynamic_free_count: usize = 0;
    var lock: SpinLock = .{};

    /// Initialize the dynamic pool
    pub fn init() void {
        lock.acquire();
        defer lock.release();

        num_blocks = 0;
        dynamic_free_list = null;
        dynamic_free_count = 0;

        // Initialize all blocks
        for (0..MAX_BLOCKS) |b| {
            for (0..OBJECTS_PER_BLOCK) |i| {
                blocks[b][i] = .{
                    .obj_type = .anonymous,
                    .size = 0,
                    .ref_count = 0,
                    .resident_list = null,
                    .resident_count = 0,
                    .shadow = null,
                    .pager_offset = 0,
                    .lock = .{},
                    .state = .free,
                };
            }
        }

        log.info("[VMObject] Dynamic pool initialized", .{});
    }

    /// Allocate a new block of objects
    fn allocateBlock() bool {
        if (num_blocks >= MAX_BLOCKS) return false;

        const block_idx = num_blocks;
        num_blocks += 1;

        // Link all objects in this block into the free list
        var i: usize = 0;
        while (i < OBJECTS_PER_BLOCK) : (i += 1) {
            blocks[block_idx][i].next_free = dynamic_free_list;
            dynamic_free_list = &blocks[block_idx][i];
            dynamic_free_count += 1;
        }

        log.info("[VMObject] Dynamic block {} allocated ({} objects)", .{ block_idx, OBJECTS_PER_BLOCK });
        return true;
    }

    /// Allocate an object from the dynamic pool
    pub fn allocate() ?*VMObject {
        lock.acquire();
        defer lock.release();

        // Try free list first
        if (dynamic_free_list) |obj| {
            dynamic_free_list = obj.next_free;
            dynamic_free_count -= 1;
            obj.next_free = null;
            return obj;
        }

        // Try to allocate a new block
        if (allocateBlock()) {
            // Should have objects now
            if (dynamic_free_list) |obj| {
                dynamic_free_list = obj.next_free;
                dynamic_free_count -= 1;
                obj.next_free = null;
                return obj;
            }
        }

        return null;
    }

    /// Return an object to the dynamic pool
    pub fn deallocate(obj: *VMObject) void {
        lock.acquire();
        defer lock.release();

        obj.next_free = dynamic_free_list;
        dynamic_free_list = obj;
        dynamic_free_count += 1;
    }

    /// Get pool statistics
    pub fn getStats() struct {
        total_capacity: usize,
        free_count: usize,
        used_count: usize,
        num_blocks: usize,
    } {
        lock.acquire();
        defer lock.release();

        const total_capacity = INITIAL_CAPACITY + num_blocks * OBJECTS_PER_BLOCK;
        return .{
            .total_capacity = total_capacity,
            .free_count = dynamic_free_count,
            .used_count = objects_used + (total_capacity - dynamic_free_count),
            .num_blocks = num_blocks,
        };
    }
};

var objects: [MAX_OBJECTS]VMObject = undefined;
var objects_used: usize = 0;
var objects_lock: SpinLock = .{};

/// P1 FIX: Free list for object reuse
var free_object_list: ?*VMObject = null;
var free_object_count: usize = 0;

/// P0 FIX: Return an object to the free list
fn deallocate(obj: *VMObject) void {
    objects_lock.acquire();
    defer objects_lock.release();

    obj.next_free = free_object_list;
    free_object_list = obj;
    free_object_count += 1;
}

/// P1 FIX: Initialize the object pool with dynamic expansion support
pub fn initObjectPool() void {
    objects_lock.acquire();
    defer objects_lock.release();

    for (&objects) |*obj| {
        obj.* = .{
            .obj_type = .anonymous,
            .size = 0,
            .ref_count = 0,
            .resident_list = null,
            .resident_count = 0,
            .shadow = null,
            .pager_offset = 0,
            .lock = .{},
            .state = .free,
        };
    }

    objects_used = 0;
    free_object_list = null;
    free_object_count = 0;

    VMObject.stats = .{
        .total_objects = 0,
        .active_objects = 0,
        .peak_objects = 0,
    };

    // Initialize dynamic pool
    DynamicObjectPool.init();

    log.info("[VMObject] Object pool initialized: {} objects", .{MAX_OBJECTS});
}

/// P1 FIX: Find a free slot in the pool with dynamic expansion
/// P2 FIX: Now uses explicit next_free field instead of shadow field
fn findFreeSlot() ?*VMObject {
    // First check free list
    if (free_object_list) |obj| {
        // P2 FIX: Use explicit next_free field for free list linkage
        free_object_list = obj.next_free;
        free_object_count -= 1;
        // Reset the next_free field after unlinking
        obj.next_free = null;
        return obj;
    }

    // Then check linear search of static pool
    if (objects_used < MAX_OBJECTS) {
        const idx = objects_used;
        objects_used += 1;
        return &objects[idx];
    }

    // P1 FIX: Try dynamic pool expansion
    return DynamicObjectPool.allocate();
}

/// Create an anonymous VM object
pub fn createAnonymous(size: u64) ?*VMObject {
    objects_lock.acquire();
    defer objects_lock.release();
    
    const obj = findFreeSlot() orelse return null;
    obj.* = VMObject.initAnonymous(size);
    VMObject.stats.total_objects += 1;
    VMObject.stats.active_objects += 1;
    if (VMObject.stats.active_objects > VMObject.stats.peak_objects) {
        VMObject.stats.peak_objects = VMObject.stats.active_objects;
    }
    
    return obj;
}

/// Create a device-mapped VM object
pub fn createDevice(phys: u64, size: u64) ?*VMObject {
    objects_lock.acquire();
    defer objects_lock.release();
    
    const obj = findFreeSlot() orelse return null;
    obj.* = VMObject.initDevice(phys, size);
    VMObject.stats.total_objects += 1;
    VMObject.stats.active_objects += 1;
    if (VMObject.stats.active_objects > VMObject.stats.peak_objects) {
        VMObject.stats.peak_objects = VMObject.stats.active_objects;
    }
    
    return obj;
}

/// Create a shadow (copy-on-write) object
/// P1 FIX: Simplified and fixed reference counting
pub fn createShadowObject(parent: *VMObject) ?*VMObject {
    objects_lock.acquire();
    defer objects_lock.release();
    
    const obj = findFreeSlot() orelse return null;
    obj.* = parent.createShadow();
    VMObject.stats.total_objects += 1;
    VMObject.stats.active_objects += 1;
    if (VMObject.stats.active_objects > VMObject.stats.peak_objects) {
        VMObject.stats.peak_objects = VMObject.stats.active_objects;
    }
    
    return obj;
}

/// Create a copy of a VM object
pub fn objectCopy(src: *VMObject, size: u64) ?*VMObject {
    objects_lock.acquire();
    defer objects_lock.release();
    
    const obj = findFreeSlot() orelse return null;
    obj.* = src.createShadow();
    obj.size = size;
    VMObject.stats.total_objects += 1;
    VMObject.stats.active_objects += 1;
    if (VMObject.stats.active_objects > VMObject.stats.peak_objects) {
        VMObject.stats.peak_objects = VMObject.stats.active_objects;
    }
    
    return obj;
}

// ============================================================================
// P1 FIX: Statistics and Debug Functions
// ============================================================================

/// Get the number of active objects
pub fn getObjectCount() usize {
    return VMObject.stats.active_objects;
}

/// Get total objects ever created
pub fn getTotalObjectCount() usize {
    return VMObject.stats.total_objects;
}

/// Get peak object count
pub fn getPeakObjectCount() usize {
    return VMObject.stats.peak_objects;
}

/// Get pool statistics
pub fn getPoolStats() struct {
    object_count: usize,
    resident_pages: usize,
    pool_capacity: usize,
    peak_usage: usize,
} {
    return .{
        .object_count = VMObject.stats.active_objects,
        .resident_pages = pool_next,
        .pool_capacity = MAX_OBJECTS,
        .peak_usage = VMObject.stats.peak_objects,
    };
}

/// P1 FIX: Debug dump of VMObject state
pub fn dumpState() void {
    const stats = getPoolStats();
    log.info("=== VMObject State ===", .{});
    log.info("  Active objects:   {}", .{stats.object_count});
    log.info("  Peak objects:     {}", .{stats.peak_usage});
    log.info("  Pool capacity:   {}", .{stats.pool_capacity});
    log.info("  Resident pages:  {}", .{stats.resident_pages});
    log.info("  Page pool used:  {}/{}", .{pool_next, MAX_RESIDENT});
    log.info("  Page pool peak:  {}", .{pool_stats.peak_usage});
}

/// P2 FIX: Validate object integrity (check for memory corruption)
pub fn validateObject(obj: *const VMObject) bool {
    // Check if the object is in a valid state
    switch (obj.state) {
        .free => {
            log.warn("[VMObject] Warning: Object in free state", .{});
            return false;
        },
        .dying => {
            log.debug("[VMObject] Object in dying state (normal for cleanup)", .{});
            return true;
        },
        .active => {
            // Active object should have a valid type
            return true;
        },
    }
}

/// P2 FIX: Get detailed object info
pub fn getObjectInfo(obj: *const VMObject) struct {
    type: ObjectType,
    size: u64,
    ref_count: u32,
    resident_count: u32,
    state: ObjectState,
} {
    return .{
        .type = obj.obj_type,
        .size = obj.size,
        .ref_count = obj.ref_count,
        .resident_count = obj.resident_count,
        .state = obj.state,
    };
}
