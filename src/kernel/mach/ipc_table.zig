/// Mach IPC Table — global port namespace and port rights management.
/// Implements port insertion/extraction and global IPC table for Darwin 19.x.
///
/// P1 Improvements:
///   - Atomic reference count operations
///   - Atomic message count operations
///   - Free list for entry reuse
///   - More efficient O(1) lookup using name-to-index mapping
///   - Port right validation and protection

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;

pub const MACH_PORT_NULL: u32 = 0;
pub const MACH_PORT_DEAD: u32 = 0xFFFFFFFF;
pub const MACH_PORT_MASK: u32 = 0xFFFF;
pub const MAX_IPC_ENTRIES: usize = 4096;

/// Port right types (matches Darwin mach/port_def.h)
pub const PortRight = enum(u32) {
    send = 0,
    receive = 1,
    send_once = 2,
    port_set = 3,
    dead_name = 4,
    port_space = 5,
    label = 6,
    none = 7,
};

/// Port right bits in msgh_bits (matches Darwin)
pub const PortRightBits = packed struct(u32) {
    _data: u32 = 0,

    pub const NONE: u5 = 0;
    pub const SEND: u5 = 1;
    pub const RECEIVE: u5 = 2;
    pub const SEND_ONCE: u5 = 3;
    pub const PORT_SET: u5 = 4;
    pub const DEAD_NAME: u5 = 5;
};

/// IPC entry state
const EntryState = enum(u8) {
    free = 0,
    active = 1,
    dying = 2,    // Entry being destroyed
};

/// IPC port entry with atomic operations
pub const IPCEntry = struct {
    name: u32,
    right: PortRight,
    msg_count: u32,
    state: EntryState,
    
    /// P1 FIX: Separate ref count that is accessed atomically
    _ref_count: u32,
    
    /// P1 FIX: For free list linkage
    next: ?*IPCEntry,

    /// P1 FIX: Statistics
    var stats: struct {
        total_allocations: usize = 0,
        peak_usage: usize = 0,
    } = .{};

    pub fn init(name: u32, right: PortRight) IPCEntry {
        return .{
            .name = name,
            .right = right,
            ._ref_count = 1,
            .msg_count = 0,
            .state = .active,
            .next = null,
        };
    }

    /// P1 FIX: Atomic retain with overflow protection
    pub fn retain(self: *IPCEntry) void {
        const max_ref: u32 = 0x7FFF_FFFF;
        var old = @atomicLoad(u32, &self._ref_count, .acquire);
        while (true) {
            if (old >= max_ref) {
                log.warn("[IPC] Reference count overflow prevented for port {}", .{self.name});
                return;
            }
            const desired = old + 1;
            old = @cmpxchgWeak(u32, &self._ref_count, old, desired, .acq_rel, .acquire) orelse return;
        }
    }

    /// P1 FIX: Atomic release
    pub fn release(self: *IPCEntry) bool {
        const old = @atomicRmw(u32, &self._ref_count, .Sub, 1, .acq_rel);
        if (old == 1) {
            @atomicStore(u8, &self.state, @intFromEnum(EntryState.dying), .seq_cst);
            return true;
        }
        return false;
    }

    /// P1 FIX: Atomic ref count read
    pub fn getRefCount(self: *const IPCEntry) u32 {
        return @atomicLoad(u32, &self._ref_count, .acquire);
    }

    /// P1 FIX: Atomic message count increment
    pub fn incMsgCount(self: *IPCEntry) void {
        _ = @atomicRmw(u32, &self.msg_count, .Add, 1, .acq_rel);
    }

    /// P1 FIX: Atomic message count decrement
    pub fn decMsgCount(self: *IPCEntry) void {
        const old = @atomicRmw(u32, &self.msg_count, .Sub, 1, .acq_rel);
        if (old == 0) {
            log.warn("[IPC] Message count underflow for port {}", .{self.name});
        }
    }

    /// P1 FIX: Get message count
    pub fn getMsgCount(self: *const IPCEntry) u32 {
        return @atomicLoad(u32, &self.msg_count, .acquire);
    }

    /// P1 FIX: Check if port is alive
    pub fn isAlive(self: *const IPCEntry) bool {
        return @atomicLoad(u8, &self.state, .acquire) == @intFromEnum(EntryState.active);
    }

    /// P1 FIX: Check if entry is free
    pub fn isFree(self: *const IPCEntry) bool {
        return @atomicLoad(u8, &self.state, .acquire) == @intFromEnum(EntryState.free);
    }
};

// ============================================================================
// Global IPC Table
// ============================================================================

/// IPC table entries
var ipc_table: [MAX_IPC_ENTRIES]IPCEntry = undefined;
var ipc_entry_count: usize = 0;
/// P2 FIX: Changed to u16 to match MACH_PORT_MASK (16-bit port names)
/// and added overflow detection
var ipc_next_name: u16 = 100;
var ipc_lock: SpinLock = .{};

/// P1 FIX: Free list for entry reuse
var ipc_free_list: ?*IPCEntry = null;
var ipc_free_count: usize = 0;

/// P1 FIX: Name-to-index hash map for O(1) lookup
/// Uses a simple open addressing hash table
var name_hash: [MAX_IPC_ENTRIES]u16 = undefined;
var name_hash_count: usize = 0;

/// P2 FIX: Statistics for hash table performance monitoring
var ipc_stats: struct {
    total_ports: usize = 0,
    active_ports: usize = 0,
    peak_ports: usize = 0,
    lookup_hits: usize = 0,
    lookup_misses: usize = 0,
    hash_collisions: usize = 0,
    hash_rehashs: usize = 0,
} = .{};

/// P1 FIX: Hash function for port names
fn hashName(name: u32) usize {
    // Simple hash function
    return @as(usize, name * 0x9E3779B9) % MAX_IPC_ENTRIES;
}

/// P1 FIX: Add entry to hash table
fn addToHash(entry: *IPCEntry) void {
    var index = hashName(entry.name);
    while (name_hash[index] != 0) {
        index = (index + 1) % MAX_IPC_ENTRIES;
    }
    // Store the entry index + 1 (0 means empty)
    name_hash[index] = @as(u16, @intFromPtr(entry) - @intFromPtr(&ipc_table)) / @sizeOf(IPCEntry) + 1;
    name_hash_count += 1;
}

/// P1 FIX: Remove entry from hash table
fn removeFromHash(name: u32) void {
    var index = hashName(name);
    var probes: usize = 0;
    while (probes < MAX_IPC_ENTRIES) {
        const stored = name_hash[index];
        if (stored == 0) break;
        
        const entry_idx = stored - 1;
        if (entry_idx < ipc_entry_count and ipc_table[entry_idx].name == name) {
            name_hash[index] = 0;
            name_hash_count -= 1;
            return;
        }
        
        index = (index + 1) % MAX_IPC_ENTRIES;
        probes += 1;
    }
}

/// P1 FIX: Find entry by name in hash table (O(1) average)
fn findInHash(name: u32) ?*IPCEntry {
    var index = hashName(name);
    var probes: usize = 0;
    while (probes < MAX_IPC_ENTRIES) {
        const stored = name_hash[index];
        if (stored == 0) {
            ipc_stats.lookup_misses += 1;
            return null;
        }
        
        const entry_idx = stored - 1;
        if (entry_idx < ipc_entry_count and ipc_table[entry_idx].name == name) {
            const entry = &ipc_table[entry_idx];
            if (entry.isAlive()) {
                ipc_stats.lookup_hits += 1;
                return entry;
            }
        }
        
        index = (index + 1) % MAX_IPC_ENTRIES;
        probes += 1;
    }
    
    ipc_stats.lookup_misses += 1;
    return null;
}

/// Initialize the IPC table
pub fn init() void {
    ipc_lock.acquire();
    defer ipc_lock.release();
    
    ipc_entry_count = 0;
    ipc_next_name = 100;
    ipc_free_list = null;
    ipc_free_count = 0;
    name_hash_count = 0;
    
    // Initialize all entries to free state
    for (&ipc_table) |*e| {
        e.* = .{
            .name = 0,
            .right = .none,
            ._ref_count = 0,
            .msg_count = 0,
            .state = .free,
            .next = null,
        };
    }
    
    // Initialize hash table
    for (&name_hash) |*h| h.* = 0;
    
    // Reserve well-known ports
    ipc_table[0] = IPCEntry.init(0, .dead_name);
    ipc_entry_count = 1;
    ipc_next_name = 1;
    addToHash(&ipc_table[0]);
    
    ipc_stats = .{
        .total_ports = 0,
        .active_ports = 1,
        .peak_ports = 1,
        .lookup_hits = 0,
        .lookup_misses = 0,
    };
    
    log.info("[IPC] Mach IPC table initialized (max {} entries)", .{MAX_IPC_ENTRIES});
}

/// P1 FIX: Find a free slot in the pool
fn findFreeSlot() ?*IPCEntry {
    // First check free list
    if (ipc_free_list) |entry| {
        ipc_free_list = entry.next;
        ipc_free_count -= 1;
        
        // Reinitialize the entry
        entry.state = .free;
        entry._ref_count = 0;
        entry.msg_count = 0;
        entry.next = null;
        
        return entry;
    }
    
    // Then check linear search for unused slots
    if (ipc_entry_count >= MAX_IPC_ENTRIES) return null;
    
    // Find first free slot after used entries
    var i: usize = 0;
    while (i < ipc_entry_count) : (i += 1) {
        if (ipc_table[i].isFree()) {
            return &ipc_table[i];
        }
    }
    
    // If no free slot found, extend the table
    if (ipc_entry_count < MAX_IPC_ENTRIES) {
        const slot = &ipc_table[ipc_entry_count];
        ipc_entry_count += 1;
        return slot;
    }
    
    return null;
}

/// Allocate a new port with the specified right
pub fn ipcAllocPort(right: PortRight) ?u32 {
    ipc_lock.acquire();
    defer ipc_lock.release();

    const entry = findFreeSlot() orelse return null;
    
    // P2 FIX: Check for port name wraparound
    if (ipc_next_name >= 0xFFFF) {
        ipc_next_name = 1; // Reserve 0 for MACH_PORT_NULL
        ipc_stats.hash_rehashs += 1;
        log.warn("[IPC] Port name namespace wrapped around", .{});
    }
    
    const name = ipc_next_name;
    ipc_next_name +%= 1;
    
    entry.* = IPCEntry.init(name, right);
    addToHash(entry);
    
    ipc_stats.total_ports += 1;
    ipc_stats.active_ports += 1;
    if (ipc_stats.active_ports > ipc_stats.peak_ports) {
        ipc_stats.peak_ports = ipc_stats.active_ports;
    }
    
    log.debug("[IPC] Port allocated: name={}, right={}", .{ name, @tagName(right) });
    return name;
}

/// Allocate a receive right (creates a kernel port)
pub fn ipcAllocReceivePort() ?u32 {
    return ipcAllocPort(.receive);
}

/// Allocate a send right
pub fn ipcAllocSendPort() ?u32 {
    return ipcAllocPort(.send);
}

/// P1 FIX: Allocate a send-once right
pub fn ipcAllocSendOncePort() ?u32 {
    return ipcAllocPort(.send_once);
}

/// Deallocate a port
pub fn ipcDeallocPort(name: u32) u32 {
    ipc_lock.acquire();
    defer ipc_lock.release();

    const entry = findInHash(name) orelse return 1;
    if (!entry.release()) {
        return 1;
    }
    
    // Remove from hash and mark as free
    removeFromHash(name);
    entry.state = .free;
    
    // Add to free list for reuse
    entry.next = @ptrFromInt(@intFromPtr(ipc_free_list));
    ipc_free_list = entry;
    ipc_free_count += 1;
    
    ipc_stats.active_ports -= 1;
    return 0;
}

/// P1 FIX: Lookup port entry by name using hash table (O(1))
pub fn lookupEntry(name: u32) ?*IPCEntry {
    if (name == MACH_PORT_NULL or name == MACH_PORT_DEAD) return null;
    
    ipc_lock.acquire();
    defer ipc_lock.release();
    
    return findInHash(name);
}

/// Lookup port by name (public interface)
pub fn lookupPortByName(name: u32) ?*IPCEntry {
    ipc_lock.acquire();
    defer ipc_lock.release();
    return findInHash(name);
}

/// Insert a send right into a receive right's port
pub fn ipcPortInsertSend(receive_name: u32) ?u32 {
    ipc_lock.acquire();
    defer ipc_lock.release();

    const receive_entry = findInHash(receive_name) orelse return null;
    if (receive_entry.right != .receive) return null;

    const send_entry = findFreeSlot() orelse return null;
    const send_name = ipc_next_name;
    ipc_next_name +%= 1;

    send_entry.* = IPCEntry.init(send_name, .send);
    addToHash(send_entry);
    
    ipc_stats.total_ports += 1;
    ipc_stats.active_ports += 1;

    return send_name;
}

/// P1 FIX: Extract send right from a receive right's port
pub fn ipcPortExtractSend(receive_name: u32) ?u32 {
    ipc_lock.acquire();
    defer ipc_lock.release();

    const receive_entry = findInHash(receive_name) orelse return null;
    if (receive_entry.right != .receive) return null;

    const send_entry = findFreeSlot() orelse return null;
    const send_name = ipc_next_name;
    ipc_next_name +%= 1;

    send_entry.* = IPCEntry.init(send_name, .send);
    addToHash(send_entry);
    
    ipc_stats.total_ports += 1;
    ipc_stats.active_ports += 1;

    return send_name;
}

/// Extract the receive right from a port name
pub fn ipcPortExtractReceive(name: u32) ?u32 {
    ipc_lock.acquire();
    defer ipc_lock.release();

    const entry = findInHash(name) orelse return null;
    if (entry.right != .receive) return null;

    entry.retain();
    return entry.name;
}

/// Modify port references with atomic operations
pub fn ipcPortModRefs(name: u32, right: PortRight, delta: i32) u32 {
    _ = right;
    ipc_lock.acquire();
    defer ipc_lock.release();

    const entry = findInHash(name) orelse return 1;
    
    if (delta > 0) {
        var old = entry._ref_count;
        while (true) {
            const desired = old + @as(u32, @intCast(delta));
            old = @cmpxchgWeak(u32, &entry._ref_count, old, desired, .acq_rel, .acquire) orelse break;
        }
    } else if (delta < 0) {
        const abs_delta = @as(u32, @intCast(-delta));
        var old = entry._ref_count;
        while (true) {
            if (old <= abs_delta) {
                // Mark as dying if ref count reaches 0
                if (@cmpxchgWeak(u32, &entry._ref_count, old, 0, .acq_rel, .acquire)) |_| {
                    continue;
                }
                @atomicStore(u8, &entry.state, @intFromEnum(EntryState.dying), .seq_cst);
                break;
            }
            const desired = old - abs_delta;
            old = @cmpxchgWeak(u32, &entry._ref_count, old, desired, .acq_rel, .acquire) orelse break;
        }
    }
    return 0;
}

/// Get port reference count
pub fn ipcPortGetRefs(name: u32) u32 {
    ipc_lock.acquire();
    defer ipc_lock.release();

    const entry = findInHash(name) orelse return 0;
    return entry.getRefCount();
}

/// Make a dead name
pub fn ipcPortMakeDead(name: u32) u32 {
    ipc_lock.acquire();
    defer ipc_lock.release();

    const entry = findInHash(name) orelse return 1;
    entry.right = .dead_name;
    entry.state = .dying;
    removeFromHash(name);
    ipc_stats.active_ports -= 1;
    return 0;
}

/// Check if port is valid (not null or dead)
pub fn ipcPortIsValid(name: u32) bool {
    return name != MACH_PORT_NULL and name != MACH_PORT_DEAD;
}

// ============================================================================
// P1 FIX: Statistics and Debug Functions
// ============================================================================

/// Get active port count
pub fn getActivePortCount() usize {
    return ipc_stats.active_ports;
}

/// Get peak port count
pub fn getPeakPortCount() usize {
    return ipc_stats.peak_ports;
}

/// Get total ports ever allocated
pub fn getTotalPortCount() usize {
    return ipc_stats.total_ports;
}

/// Get lookup statistics
pub fn getLookupStats() struct { hits: usize, misses: usize, hit_rate: f64 } {
    const total = ipc_stats.lookup_hits + ipc_stats.lookup_misses;
    const hit_rate = if (total > 0) @as(f64, @floatFromInt(ipc_stats.lookup_hits)) / @as(f64, @floatFromInt(total)) else 0.0;
    return .{
        .hits = ipc_stats.lookup_hits,
        .misses = ipc_stats.lookup_misses,
        .hit_rate = hit_rate,
    };
}

/// P1 FIX: Debug dump of IPC table state
pub fn dumpState() void {
    ipc_lock.acquire();
    defer ipc_lock.release();
    
    log.info("=== IPC Table State ===", .{});
    log.info("  Active ports:    {}", .{ipc_stats.active_ports});
    log.info("  Peak ports:     {}", .{ipc_stats.peak_ports});
    log.info("  Total allocated: {}", .{ipc_stats.total_ports});
    log.info("  Free slots:     {}", .{MAX_IPC_ENTRIES - ipc_entry_count});
    log.info("  Free list size: {}", .{ipc_free_count});
    
    const lookup = getLookupStats();
    log.info("  Lookup hits:    {}", .{lookup.hits});
    log.info("  Lookup misses:  {}", .{lookup.misses});
    log.info("  Lookup hit rate: {:.2}%", .{lookup.hit_rate * 100});
}
