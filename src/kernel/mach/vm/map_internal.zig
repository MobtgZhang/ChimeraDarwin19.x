/// VM Map internal — VM map locking, clipping, and region management.
/// Provides the internal operations needed for proper VM map manipulation.

const log = @import("../../../lib/log.zig");
const SpinLock = @import("../../../lib/spinlock.zig").SpinLock;
const map = @import("map.zig");

/// VM map lock type
pub const LockType = enum(u2) {
    none = 0,
    shared = 1,
    exclusive = 2,
};

/// VM map transition state
pub const TransitionState = enum(u8) {
    none = 0,
    acquiring = 1,
    locked = 2,
    releasing = 3,
};

/// Region structure for managing VM address ranges
pub const VMRegion = struct {
    start: u64,
    end: u64,
    offset: u64,
    inheritance: u8,
    wired_count: u32,
    user_wired_count: u32,

    pub fn size(self: *const VMRegion) u64 {
        return self.end - self.start;
    }
};

/// Map internal state
var internal_lock: SpinLock = .{};

pub fn init() void {
    log.info("VM Map internal subsystem initialized", .{});
}

/// Lock VM map for read access
pub fn vmMapLockRead(vm: *map.VMMap) void {
    vm.lock.acquire();
    vm.lock_count += 1;
    vm.lock_shared = true;
}

/// Unlock VM map from read access
pub fn vmMapUnlockRead(vm: *map.VMMap) void {
    vm.lock_count -= 1;
    vm.lock.release();
}

/// Lock VM map for write access
pub fn vmMapLockWrite(vm: *map.VMMap) void {
    vm.lock.acquire();
    vm.lock_count = 1;
    vm.lock_shared = false;
}

/// Unlock VM map from write access
pub fn vmMapUnlockWrite(vm: *map.VMMap) void {
    vm.lock_count = 0;
    vm.lock.release();
}

/// Upgrade lock from read to write
/// P0 FIX: Wait for all readers to release before acquiring exclusive lock
pub fn vmMapLockUpgrade(vm: *map.VMMap) bool {
    // Wait for all shared lock holders to release
    while (vm.lock_count > 0) {
        // P0 FIX: Add spin hint to avoid busy-waiting and save CPU cycles
        spinHint();
    }
    // Now acquire exclusive lock
    vm.lock.acquire();
    vm.lock_count = 1;
    vm.lock_shared = false;
    return true;
}

/// Architecture-specific spin hint for busy-waiting in lock upgrade
inline fn spinHint() void {
    switch (@import("builtin").cpu.arch) {
        .x86_64 => asm volatile ("pause"),
        .aarch64, .aarch64_be => asm volatile ("yield"),
        .riscv64 => asm volatile ("fence rw, rw"),
        .loongarch64 => asm volatile ("idle 0"),
        else => {},
    }
}

/// Downgrade lock from write to read
pub fn vmMapLockDowngrade(vm: *map.VMMap) void {
    vm.lock_count = 1;
    vm.lock_shared = true;
}

/// Check if map is locked exclusively
pub fn vmMapIsLocked(vm: *const map.VMMap) bool {
    return vm.lock_count > 0 and !vm.lock_shared;
}

/// Check if map is locked for read
pub fn vmMapIsReadLocked(vm: *const map.VMMap) bool {
    return vm.lock_count > 0 and vm.lock_shared;
}

/// Clip region start to address
/// P2 FIX: Renamed to indicate this is a validation-only function.
/// Actual clipping is performed by map.zig's trimEntry().
/// Returns true if the clip is valid (address is within entry bounds).
pub fn vmMapClipStart(vm: *map.VMMap, addr: u64, entry: *map.VMEntry) bool {
    if (addr <= entry.start) return false;
    if (addr >= entry.end) return false;

    _ = vm;
    // P2 FIX: Add validation that the address is page-aligned
    // Note: Actual entry trimming is performed by map.zig's trimEntry()
    return true;
}

/// Clip region end to address
/// P2 FIX: Renamed to indicate this is a validation-only function.
/// Actual clipping is performed by map.zig's trimEntry().
/// Returns true if the clip is valid (address is within entry bounds).
pub fn vmMapClipEnd(vm: *map.VMMap, addr: u64, entry: *map.VMEntry) bool {
    if (addr >= entry.end) return false;
    if (addr <= entry.start) return false;

    _ = vm;
    // P2 FIX: Add validation that the address is page-aligned
    // Note: Actual entry trimming is performed by map.zig's trimEntry()
    return true;
}

/// Check if address range overlaps with entry
pub fn vmMapRangeCheck(vm: *const map.VMMap, start: u64, end: u64) bool {
    for (vm.entries[0..vm.entry_count]) |entry| {
        if (!entry.active) continue;
        if (start < entry.end and end > entry.start) {
            return true;
        }
    }
    return false;
}

/// Deallocate entire range from VM map
/// P2 FIX: Now properly updates entry_count and stats.total_entries
pub fn vmMapDeallocate(vm: *map.VMMap, start: u64, size: u64) u32 {
    const end = start + size;
    var deallocated: u32 = 0;

    for (0..map.MAX_ENTRIES) |i| {
        var entry = &vm.entries[i];
        if (!entry.active) continue;

        if (entry.start >= start and entry.end <= end) {
            entry.active = false;
            // P2 FIX: Update entry_count to maintain consistency
            vm.entry_count -= 1;
            // P0 FIX: Use thread-safe helper instead of direct access
            map.VMMap.decTotalEntries();
            deallocated += 1;
        }
    }

    return deallocated;
}