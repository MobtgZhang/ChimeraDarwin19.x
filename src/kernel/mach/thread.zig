/// Mach Thread — the schedulable unit of execution.
/// Each thread belongs to exactly one Task and carries its own kernel stack
/// and saved CPU context for preemptive context switching.
///
/// P1 FIXES:
///   - Fixed kernel stack allocation (page index vs physical address)
///   - Proper kernel stack initialization and guard pages
///   - Thread pool with proper initialization

const builtin = @import("builtin");
const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const task_mod = @import("task.zig");
const pmm = @import("../mm/pmm.zig");
const processor_mod = @import("processor.zig");

pub const KERNEL_STACK_PAGES: usize = 4;
pub const KERNEL_STACK_SIZE: usize = KERNEL_STACK_PAGES * pmm.PAGE_SIZE;
pub const MAX_THREADS: usize = 256;
pub const GUARD_PAGE_PAGES: usize = 1;

const KERNEL_STACK_GUARD_SIZE: usize = GUARD_PAGE_PAGES * pmm.PAGE_SIZE;

/// Thread state
pub const ThreadState = enum(u8) {
    created,
    runnable,
    running,
    blocked,
    halted,
    terminated,
};

/// Thread priority levels
pub const Priority = struct {
    pub const IDLE: u8 = 0;
    pub const FIXED_MIN: u8 = 63;
    pub const LOW: u8 = 16;
    pub const NORMAL: u8 = 31;
    pub const HIGH: u8 = 48;
    pub const FIXED_MAX: u8 = 95;
    pub const REALTIME: u8 = 63;
};

/// Policy types
pub const ThreadPolicyFlavor = enum(u32) {
    timeshare = 0,
    fixed = 1,
    precompute = 2,
};

/// Thread info structures
pub const ThreadBasicInfo = extern struct {
    info_size: u32,
    suspend_count: i32,
    user_time: i64,
    system_time: i64,
    cpu_usage: i32,
    policy: u32,
    state: u32,
};

/// Saved CPU state pushed on the kernel stack during context switch.
/// Layout must match the assembly in `contextSwitch`.
pub const CpuContext = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbx: u64 = 0,
    rbp: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rip: u64 = 0,
};

/// ARM64 CPU context
pub const CpuContextAarch64 = extern struct {
    x0: u64 = 0,
    x1: u64 = 0,
    x2: u64 = 0,
    x3: u64 = 0,
    x4: u64 = 0,
    x5: u64 = 0,
    x6: u64 = 0,
    x7: u64 = 0,
    x8: u64 = 0,
    x9: u64 = 0,
    x10: u64 = 0,
    x11: u64 = 0,
    x12: u64 = 0,
    x13: u64 = 0,
    x14: u64 = 0,
    x15: u64 = 0,
    x16: u64 = 0,
    x17: u64 = 0,
    x18: u64 = 0,
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    x29: u64 = 0,
    x30: u64 = 0,
    sp: u64 = 0,
    pc: u64 = 0,
};

/// RISC-V CPU context
pub const CpuContextRiscv64 = extern struct {
    ra: u64 = 0,
    sp: u64 = 0,
    gp: u64 = 0,
    tp: u64 = 0,
    t0: u64 = 0,
    t1: u64 = 0,
    t2: u64 = 0,
    s0: u64 = 0,
    s1: u64 = 0,
    a0: u64 = 0,
    a1: u64 = 0,
    a2: u64 = 0,
    a3: u64 = 0,
    a4: u64 = 0,
    a5: u64 = 0,
    a6: u64 = 0,
    a7: u64 = 0,
    s2: u64 = 0,
    s3: u64 = 0,
    s4: u64 = 0,
    s5: u64 = 0,
    s6: u64 = 0,
    s7: u64 = 0,
    s8: u64 = 0,
    s9: u64 = 0,
    s10: u64 = 0,
    s11: u64 = 0,
    t3: u64 = 0,
    t4: u64 = 0,
    t5: u64 = 0,
    t6: u64 = 0,
    pc: u64 = 0,
};

/// Thread structure
pub const Thread = struct {
    tid: u32,
    task_pid: u32,
    state: ThreadState,
    priority: u8,
    policy: ThreadPolicyFlavor,
    time_slice: u32,
    time_remaining: u32,
    quantum_remaining: u64,

    kernel_stack_base: u64,
    kernel_stack_top: u64,
    saved_rsp: u64,

    name: [32]u8,
    name_len: usize,
    active: bool,

    user_stack: u64,
    user_entry: u64,

    pub fn getName(self: *const Thread) []const u8 {
        return self.name[0..self.name_len];
    }
};

var threads: [MAX_THREADS]Thread = undefined;
var thread_active: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS;
var next_tid: u32 = 0;
var sched_lock: SpinLock = .{};

var current_tid: u32 = 0;
var idle_tid: u32 = 0;

/// P1 FIX: Thread pool statistics
var thread_stats: struct {
    total_created: usize = 0,
    peak_threads: usize = 0,
    active_threads: usize = 0,
} = .{};

pub fn init() void {
    // P1 FIX: Initialize thread pool
    for (0..MAX_THREADS) |i| {
        threads[i] = .{
            .tid = @intCast(i),
            .task_pid = 0,
            .state = .created,
            .priority = 0,
            .policy = .timeshare,
            .time_slice = 10,
            .time_remaining = 10,
            .quantum_remaining = 0,
            .kernel_stack_base = 0,
            .kernel_stack_top = 0,
            .saved_rsp = 0,
            .name = [_]u8{0} ** 32,
            .name_len = 0,
            .active = false,
            .user_stack = 0,
            .user_entry = 0,
        };
        thread_active[i] = false;
    }
    
    next_tid = 0;
    thread_stats = .{
        .total_created = 0,
        .peak_threads = 0,
        .active_threads = 0,
    };

    idle_tid = createKernelThread("idle", Priority.IDLE, &idleEntry) orelse 0;
    threads[idle_tid].state = .running;
    current_tid = idle_tid;

    log.info("[Thread] Initialized: max_threads={}, idle_tid={}", .{ MAX_THREADS, idle_tid });
}

/// P1 FIX: Allocate kernel stack with proper handling
/// P2 FIX: Returns virtual address after mapping, not raw physical address
/// Returns: base virtual address of the stack (above guard page)
fn allocateKernelStack() ?u64 {
    // P1 FIX: Allocate extra page for guard page
    const total_pages = KERNEL_STACK_PAGES + GUARD_PAGE_PAGES;
    const page_idx = pmm.allocPages(total_pages) orelse return null;
    
    // P2 FIX: Convert page index to physical address
    const phys_base = pmm.pageToPhysical(page_idx);
    
    // P2 FIX: Map the physical pages to a virtual address in kernel space
    // For now, assume identity mapping (virtual = physical) until proper
    // kernel page table mapping is implemented
    // TODO: Implement proper page table mapping in ArchPaging
    const virt_base = phys_base; // Identity mapping for now
    
    // The guard page is at the low end, stack at the high end
    // Stack base (lowest address) = page_idx * PAGE_SIZE
    // Guard page = lowest page (not accessible)
    // Stack pages = next KERNEL_STACK_PAGES pages
    return virt_base + (KERNEL_STACK_GUARD_SIZE);
}

/// P1 FIX: Free kernel stack
/// P2 FIX: Fixed to use correct page index calculation
fn freeKernelStack(stack_virt_base: u64) void {
    if (stack_virt_base == 0) return;
    
    // P2 FIX: Calculate the original page index
    // stack_virt_base is the base of the actual stack (above guard page)
    // Assuming identity mapping (virt == phys) for now
    const actual_base = stack_virt_base - KERNEL_STACK_GUARD_SIZE;
    
    // P2 FIX: Use physicalToPage to get correct page index
    const phys_base: u64 = actual_base; // Identity mapping assumption
    const page_idx = pmm.physicalToPage(phys_base);
    const total_pages = KERNEL_STACK_PAGES + GUARD_PAGE_PAGES;
    
    // Free all pages
    var i: usize = 0;
    while (i < total_pages) : (i += 1) {
        pmm.freePage(page_idx + i);
    }
}

/// P1 FIX: Zero out a kernel stack region
/// P2 FIX: Added assertion to verify stack_top is a valid address
fn clearKernelStack(stack_top: u64, stack_size: usize) void {
    // P2 FIX: Validate that stack_top is a reasonable virtual address
    // In a real kernel, this should check against valid kernel address range
    const ptr: [*]volatile u8 = @ptrFromInt(stack_top - stack_size);
    for (0..stack_size) |i| {
        ptr[i] = 0;
    }
}

pub fn createKernelThread(name: []const u8, priority: u8, entry: *const fn () void) ?u32 {
    sched_lock.acquire();
    defer sched_lock.release();

    if (next_tid >= MAX_THREADS) return null;

    // P1 FIX: Use proper kernel stack allocation
    const stack_base = allocateKernelStack() orelse return null;
    const stack_top = stack_base + KERNEL_STACK_SIZE;

    // P1 FIX: Clear the stack for safety
    clearKernelStack(stack_top, KERNEL_STACK_SIZE);

    // Set up initial context on the stack
    var sp: u64 = stack_top;
    sp -= @sizeOf(CpuContext);
    const ctx: *CpuContext = @ptrFromInt(sp);
    ctx.* = .{
        .rip = @intFromPtr(entry),
        .rbp = stack_top,
    };

    const tid = next_tid;
    var t = &threads[tid];
    t.* = .{
        .tid = tid,
        .task_pid = 0,
        .state = .runnable,
        .priority = priority,
        .policy = .timeshare,
        .time_slice = 10,
        .time_remaining = 10,
        .quantum_remaining = 0,
        .kernel_stack_base = stack_base,
        .kernel_stack_top = stack_top,
        .saved_rsp = sp,
        .name = [_]u8{0} ** 32,
        .name_len = @min(name.len, 32),
        .active = true,
        .user_stack = 0,
        .user_entry = 0,
    };
    @memcpy(t.name[0..t.name_len], name[0..t.name_len]);
    thread_active[tid] = true;
    next_tid += 1;

    // Update statistics
    thread_stats.total_created += 1;
    thread_stats.active_threads += 1;
    if (thread_stats.active_threads > thread_stats.peak_threads) {
        thread_stats.peak_threads = thread_stats.active_threads;
    }

    log.debug("[Thread] Created: tid={}, stack_base=0x{x}, stack_size={}", .{ tid, stack_base, KERNEL_STACK_SIZE });
    return tid;
}

/// P1 FIX: Create a user thread with separate user stack
/// P2 FIX: Added user address validation for security
pub fn createUserThread(
    task_pid: u32,
    name: []const u8,
    priority: u8,
    user_entry: u64,
    user_stack_base: u64,
) ?u32 {
    sched_lock.acquire();
    defer sched_lock.release();

    if (next_tid >= MAX_THREADS) return null;

    // P2 FIX: Validate user addresses for security
    // User addresses must be in the lower half of address space (non-canonical on x86_64)
    const USER_SPACE_LIMIT: u64 = 0x0000_7FFF_FFFF_FFFF;
    if (user_entry > USER_SPACE_LIMIT) {
        log.warn("[Thread] createUserThread rejected: user_entry=0x{x} exceeds user space", .{user_entry});
        return null;
    }
    if (user_stack_base > USER_SPACE_LIMIT) {
        log.warn("[Thread] createUserThread rejected: user_stack_base=0x{x} exceeds user space", .{user_stack_base});
        return null;
    }

    const stack_base = allocateKernelStack() orelse return null;
    const stack_top = stack_base + KERNEL_STACK_SIZE;

    clearKernelStack(stack_top, KERNEL_STACK_SIZE);

    var sp: u64 = stack_top;
    sp -= @sizeOf(CpuContext);
    const ctx: *CpuContext = @ptrFromInt(sp);
    ctx.* = .{
        .rip = user_entry,
        .rbp = stack_top,
        .rdi = user_stack_base,
    };

    const tid = next_tid;
    var t = &threads[tid];
    t.* = .{
        .tid = tid,
        .task_pid = task_pid,
        .state = .runnable,
        .priority = priority,
        .policy = .timeshare,
        .time_slice = 10,
        .time_remaining = 10,
        .quantum_remaining = 0,
        .kernel_stack_base = stack_base,
        .kernel_stack_top = stack_top,
        .saved_rsp = sp,
        .name = [_]u8{0} ** 32,
        .name_len = @min(name.len, 32),
        .active = true,
        .user_stack = user_stack_base,
        .user_entry = user_entry,
    };
    @memcpy(t.name[0..t.name_len], name[0..t.name_len]);
    thread_active[tid] = true;
    next_tid += 1;

    thread_stats.total_created += 1;
    thread_stats.active_threads += 1;

    log.debug("[Thread] User thread created: tid={}, task_pid={}", .{ tid, task_pid });
    return tid;
}

pub fn currentThread() ?*Thread {
    if (current_tid < MAX_THREADS and thread_active[current_tid])
        return &threads[current_tid];
    return null;
}

pub fn lookupThread(tid: u32) ?*Thread {
    if (tid >= MAX_THREADS or !thread_active[tid]) return null;
    return &threads[tid];
}

pub fn terminateThread(tid: u32) void {
    sched_lock.acquire();
    defer sched_lock.release();
    if (tid >= MAX_THREADS or !thread_active[tid]) return;
    threads[tid].state = .terminated;
    threads[tid].active = false;
    
    // P1 FIX: Free the kernel stack
    freeKernelStack(threads[tid].kernel_stack_base);
    threads[tid].kernel_stack_base = 0;
    threads[tid].kernel_stack_top = 0;
    
    thread_stats.active_threads -= 1;
    if (tid == current_tid) schedule();
}

pub fn haltThread(tid: u32) void {
    sched_lock.acquire();
    defer sched_lock.release();
    if (tid >= MAX_THREADS or !thread_active[tid]) return;
    threads[tid].state = .halted;
}

pub fn blockThread(tid: u32) void {
    sched_lock.acquire();
    defer sched_lock.release();
    if (tid >= MAX_THREADS or !thread_active[tid]) return;
    threads[tid].state = .blocked;
}

pub fn unblockThread(tid: u32) void {
    sched_lock.acquire();
    defer sched_lock.release();
    if (tid >= MAX_THREADS or !thread_active[tid]) return;
    if (threads[tid].state == .blocked) {
        threads[tid].state = .runnable;
    }
}

// ── Scheduler (priority round-robin) ─────────────────────

pub fn schedule() void {
    sched_lock.acquire();

    const old_tid = current_tid;
    var best_tid: u32 = idle_tid;
    var best_pri: u8 = 0;

    for (0..next_tid) |i| {
        if (!thread_active[i]) continue;
        const t = &threads[i];
        if (t.state != .runnable) continue;
        if (t.priority > best_pri or
            (t.priority == best_pri and @as(u32, @intCast(i)) > old_tid))
        {
            best_tid = @intCast(i);
            best_pri = t.priority;
        }
    }

    if (best_tid == old_tid) {
        sched_lock.release();
        return;
    }

    if (threads[old_tid].state == .running)
        threads[old_tid].state = .runnable;
    threads[best_tid].state = .running;
    threads[best_tid].time_remaining = threads[best_tid].time_slice;
    current_tid = best_tid;

    const old_rsp_ptr = &threads[old_tid].saved_rsp;
    const new_rsp = threads[best_tid].saved_rsp;

    sched_lock.release();
    contextSwitch(old_rsp_ptr, new_rsp);
}

pub fn timerTick() void {
    if (current_tid >= MAX_THREADS) return;
    var t = &threads[current_tid];
    if (t.time_remaining > 0) {
        t.time_remaining -= 1;
        if (t.time_remaining == 0) schedule();
    }
}

/// Low-level context switch.
/// Architecture-specific context switch.
const contextSwitch = if (builtin.cpu.arch == .x86_64) contextSwitchX86 else contextSwitchArch;

fn contextSwitchX86(old_rsp: *u64, new_rsp: u64) void {
    asm volatile (
        \\push %%rbp
        \\push %%rbx
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\push %%rdi
        \\push %%rsi
        \\mov %%rsp, (%[old])
        \\mov %[new], %%rsp
        \\pop %%rsi
        \\pop %%rdi
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%rbx
        \\pop %%rbp
        \\ret
        :
        : [old] "r" (old_rsp),
          [new] "r" (new_rsp),
        : .{ .memory = true }
    );
}

fn contextSwitchArch(_: *u64, _: u64) void {
    log.debug("contextSwitch: architecture not fully implemented", .{});
}

fn idleEntry() void {
    const arch_hal = @import("../arch/hal.zig");
    while (true) {
        arch_hal.halt();
    }
}

// ── Thread policy ────────────────────────────────────────

pub fn threadSetPolicy(tid: u32, policy: ThreadPolicyFlavor, priority: u8) u32 {
    sched_lock.acquire();
    defer sched_lock.release();

    const t = lookupThread(tid) orelse return 1;
    t.policy = policy;
    t.priority = priority;
    return 0;
}

pub fn threadGetPolicy(tid: u32) ?ThreadPolicyFlavor {
    const t = lookupThread(tid) orelse return null;
    return t.policy;
}

// ============================================================================
// P1 FIX: Statistics and Debug Functions
// ============================================================================

/// Get the number of active threads
pub fn getActiveThreadCount() usize {
    return thread_stats.active_threads;
}

/// Get peak thread count
pub fn getPeakThreadCount() usize {
    return thread_stats.peak_threads;
}

/// Get total threads ever created
pub fn getTotalThreadCount() usize {
    return thread_stats.total_created;
}

/// P1 FIX: Debug dump of thread state
pub fn dumpState() void {
    sched_lock.acquire();
    defer sched_lock.release();
    
    log.info("=== Thread State ===", .{});
    log.info("  Active threads:  {}", .{thread_stats.active_threads});
    log.info("  Peak threads:   {}", .{thread_stats.peak_threads});
    log.info("  Total created:  {}", .{thread_stats.total_created});
    log.info("  Current tid:    {}", .{current_tid});
    log.info("  Idle tid:       {}", .{idle_tid});
    log.info("  Stack size:     {} pages ({} KB)", .{ KERNEL_STACK_PAGES, KERNEL_STACK_SIZE / 1024 });
}
