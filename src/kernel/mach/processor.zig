/// Mach Processor — manages processor sets and CPU assignments.
/// Implements processor_t, processor_set, and multi-core management.

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const thread_mod = @import("thread.zig");

pub const MAX_PROCESSORS: usize = 64;
pub const MAX_PROCESSOR_SETS: usize = 16;

/// Processor state
pub const ProcessorState = enum(u8) {
    idle,
    running,
    off_line,
    shutdown,
};

/// Policy types for threads
pub const PolicyType = enum(u8) {
    standard = 0,
    fixed = 1,
    revert = 2,
    timeshare = 3,
};

/// Thread policy base
pub const ThreadPolicy = struct {
    policy_type: PolicyType,
    data: u64,
};

/// Default processor set ID
pub const PROCESSOR_SET_DEFAULT: u32 = 1;

/// Processor structure
pub const Processor = struct {
    id: u32,
    cpu_type: u32,
    state: ProcessorState,
    current_thread: ?*thread_mod.Thread,
    processor_set: u32,
    active: bool,
};

/// Processor set structure
pub const ProcessorSet = struct {
    id: u32,
    name: [32]u8,
    name_len: usize,
    processor_count: u32,
    thread_count: u32,
    policy: PolicyType,
    active: bool,

    pub fn getName(self: *const ProcessorSet) []const u8 {
        return self.name[0..self.name_len];
    }
};

var processors: [MAX_PROCESSORS]Processor = undefined;
var processor_count: u32 = 0;
var processor_sets: [MAX_PROCESSOR_SETS]ProcessorSet = undefined;
var processor_set_count: u32 = 0;
var default_ps: u32 = 0;
var proc_lock: SpinLock = .{};

pub fn init() void {
    processor_count = 0;
    processor_set_count = 0;

    for (&processors) |*p| {
        p.* = .{
            .id = 0,
            .cpu_type = 0,
            .state = .off_line,
            .current_thread = null,
            .processor_set = 0,
            .active = false,
        };
    }

    for (&processor_sets) |*ps| {
        ps.* = .{
            .id = 0,
            .name = [_]u8{0} ** 32,
            .name_len = 0,
            .processor_count = 0,
            .thread_count = 0,
            .policy = .timeshare,
            .active = false,
        };
    }

    // Create default processor set
    var ps = &processor_sets[processor_set_count];
    ps.* = .{
        .id = PROCESSOR_SET_DEFAULT,
        .name = [_]u8{0} ** 32,
        .name_len = 6,
        .processor_count = 0,
        .thread_count = 0,
        .policy = .timeshare,
        .active = true,
    };
    @memcpy(ps.name[0..6], "default");
    default_ps = PROCESSOR_SET_DEFAULT;
    processor_set_count += 1;

    log.info("Mach Processor subsystem initialized ({} max processors)", .{MAX_PROCESSORS});
}

/// Register a processor
pub fn registerProcessor(id: u32, cpu_type: u32) ?u32 {
    proc_lock.acquire();
    defer proc_lock.release();

    if (processor_count >= MAX_PROCESSORS) return null;
    if (id >= MAX_PROCESSORS) return null;

    const p = &processors[id];
    p.* = .{
        .id = id,
        .cpu_type = cpu_type,
        .state = .idle,
        .current_thread = null,
        .processor_set = PROCESSOR_SET_DEFAULT,
        .active = true,
    };

    processor_count += 1;

    // Update processor set count
    var ps = lookupProcessorSet(PROCESSOR_SET_DEFAULT) orelse return null;
    ps.processor_count += 1;

    log.debug("Processor registered: id={}, cpu_type=0x{x}", .{ id, cpu_type });
    return id;
}

/// Get processor info
pub fn getProcessor(id: u32) ?*Processor {
    if (id >= MAX_PROCESSORS) return null;
    if (!processors[id].active) return null;
    return &processors[id];
}

/// Get processor count
pub fn getProcessorCount() u32 {
    return processor_count;
}

/// Get processor set by ID
pub fn lookupProcessorSet(id: u32) ?*ProcessorSet {
    if (id >= MAX_PROCESSOR_SETS) return null;
    if (!processor_sets[id].active) return null;
    return &processor_sets[id];
}

/// Get default processor set
pub fn getDefaultProcessorSet() ?*ProcessorSet {
    return lookupProcessorSet(default_ps);
}

/// Assign processor to a set
pub fn processorSetAssignProcessor(ps_id: u32, proc_id: u32) u32 {
    proc_lock.acquire();
    defer proc_lock.release();

    const ps = lookupProcessorSet(ps_id) orelse return 1;
    const proc = getProcessor(proc_id) orelse return 1;

    if (proc.processor_set == ps_id) return 0;

    // Remove from old set
    const old_ps = lookupProcessorSet(proc.processor_set);
    if (old_ps) |ops| {
        ops.processor_count -= 1;
    }

    // Add to new set
    ps.processor_count += 1;
    proc.processor_set = ps_id;

    return 0;
}

/// Get processor set policy
pub fn processorSetGetPolicy(ps_id: u32) ?PolicyType {
    const ps = lookupProcessorSet(ps_id) orelse return null;
    return ps.policy;
}

/// Set processor set policy
pub fn processorSetSetPolicy(ps_id: u32, policy: PolicyType) u32 {
    proc_lock.acquire();
    defer proc_lock.release();

    const ps = lookupProcessorSet(ps_id) orelse return 1;
    ps.policy = policy;
    return 0;
}
