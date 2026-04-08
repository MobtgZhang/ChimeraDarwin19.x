/// Mach Ledger — resource accounting for tasks and threads.
/// Implements CPU time, memory, and I/O resource tracking.

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;

pub const MACH_LEDGER_NULL: u32 = 0;
pub const MAX_LEDGERS: usize = 64;

/// Ledger resource types
pub const LedgerType = enum(u32) {
    cpu_time = 0,
    thread_cpu_time = 1,
    memory_used = 2,
    memory_phys = 3,
    fork_count = 4,
    io_physical = 5,
    io_logical = 6,
    pad = 7,
};

/// Individual ledger entry for a resource
pub const LedgerEntry = struct {
    resource: LedgerType,
    limit: i64,
    usage: i64,
    max_usage: i64,
    last_refill: i64,
    ref_count: u32,

    pub fn consume(self: *LedgerEntry, amount: i64) bool {
        self.usage += amount;
        if (self.usage > self.max_usage) {
            self.max_usage = self.usage;
        }
        _ = self.last_refill;
        return self.usage <= self.limit;
    }

    pub fn refund(self: *LedgerEntry, amount: i64) void {
        self.usage -= amount;
        if (self.usage < 0) self.usage = 0;
    }

    pub fn setLimit(self: *LedgerEntry, limit: i64) void {
        self.limit = limit;
    }
};

/// Mach ledger structure
pub const Ledger = struct {
    id: u32,
    ref_count: u32,
    entries: [8]LedgerEntry,
    entry_count: u32,
    active: bool,

    pub fn retain(self: *Ledger) void {
        self.ref_count += 1;
    }

    pub fn release(self: *Ledger) bool {
        if (self.ref_count > 1) {
            self.ref_count -= 1;
            return false;
        }
        self.ref_count = 0;
        self.active = false;
        return true;
    }

    pub fn consume(self: *Ledger, resource: LedgerType, amount: i64) bool {
        for (self.entries[0..self.entry_count]) |*entry| {
            if (entry.resource == resource) {
                return entry.consume(amount);
            }
        }
        return true;
    }

    pub fn refund(self: *Ledger, resource: LedgerType, amount: i64) void {
        for (self.entries[0..self.entry_count]) |*entry| {
            if (entry.resource == resource) {
                entry.refund(amount);
                return;
            }
        }
    }

    pub fn setLimit(self: *Ledger, resource: LedgerType, limit: i64) bool {
        for (self.entries[0..self.entry_count]) |*entry| {
            if (entry.resource == resource) {
                entry.setLimit(limit);
                return true;
            }
        }
        return false;
    }

    pub fn getUsage(self: *const Ledger, resource: LedgerType) i64 {
        for (self.entries[0..self.entry_count]) |entry| {
            if (entry.resource == resource) {
                return entry.usage;
            }
        }
        return 0;
    }
};

var ledgers: [MAX_LEDGERS]Ledger = undefined;
var ledger_count: usize = 0;
var ledger_lock: SpinLock = .{};

pub fn init() void {
    ledger_count = 0;
    for (&ledgers) |*l| l.active = false;
    log.info("Mach Ledger subsystem initialized (max {} ledgers)", .{MAX_LEDGERS});
}

/// Create a new ledger with default entries
pub fn ledgerCreate() ?u32 {
    ledger_lock.acquire();
    defer ledger_lock.release();

    if (ledger_count >= MAX_LEDGERS) return null;

    const id = @as(u32, @intCast(ledger_count));
    var l = &ledgers[ledger_count];
    l.* = .{
        .id = id,
        .ref_count = 1,
        .entries = undefined,
        .entry_count = 4,
        .active = true,
    };

    // Initialize default entries
    l.entries[0] = .{ .resource = .cpu_time, .limit = -1, .usage = 0, .max_usage = 0, .last_refill = 0, .ref_count = 1 };
    l.entries[1] = .{ .resource = .thread_cpu_time, .limit = -1, .usage = 0, .max_usage = 0, .last_refill = 0, .ref_count = 1 };
    l.entries[2] = .{ .resource = .memory_used, .limit = -1, .usage = 0, .max_usage = 0, .last_refill = 0, .ref_count = 1 };
    l.entries[3] = .{ .resource = .memory_phys, .limit = -1, .usage = 0, .max_usage = 0, .last_refill = 0, .ref_count = 1 };

    ledger_count += 1;
    log.debug("Ledger created: id={}", .{id});
    return id;
}

/// Get a ledger by ID
pub fn lookupLedger(id: u32) ?*Ledger {
    if (id >= MAX_LEDGERS) return null;
    if (!ledgers[id].active) return null;
    return &ledgers[id];
}

/// Retain a ledger reference
pub fn ledgerRetain(id: u32) bool {
    const l = lookupLedger(id) orelse return false;
    l.retain();
    return true;
}

/// Release a ledger reference
pub fn ledgerRelease(id: u32) bool {
    ledger_lock.acquire();
    defer ledger_lock.release();

    const l = lookupLedger(id) orelse return false;
    return l.release();
}

/// Consume ledger resources for CPU time
pub fn ledgerConsumeCpu(id: u32, ticks: i64) bool {
    const l = lookupLedger(id) orelse return true;
    return l.consume(.cpu_time, ticks);
}

/// Consume ledger resources for memory
pub fn ledgerConsumeMemory(id: u32, pages: i64) bool {
    const l = lookupLedger(id) orelse return true;
    return l.consume(.memory_used, pages);
}

/// Get CPU time usage
pub fn ledgerGetCpuUsage(id: u32) i64 {
    const l = lookupLedger(id) orelse return 0;
    return l.getUsage(.cpu_time);
}

/// Get memory usage
pub fn ledgerGetMemoryUsage(id: u32) i64 {
    const l = lookupLedger(id) orelse return 0;
    return l.getUsage(.memory_used);
}
