/// Darwin 19.x BSD System Call Table (x86_64)
/// Implements syscall dispatch and individual syscall handlers for
/// POSIX / Darwin 19.x compatibility.

const log = @import("../../lib/log.zig");
const proc_mod = @import("proc.zig");
const signal_mod = @import("signal.zig");
const vnode_mod = @import("vfs/vnode.zig");
const devfs_mod = @import("vfs/devfs.zig");
const builtin = @import("builtin");
const serial = switch (builtin.cpu.arch) {
    .x86_64 => @import("../arch/x86_64/serial.zig"),
    .aarch64 => @import("../arch/aarch64/serial.zig"),
    .riscv64 => @import("../arch/riscv64/serial.zig"),
    .loongarch64 => @import("../arch/loong64/serial.zig"),
    else => @compileError("Unsupported architecture"),
};

/// Darwin 19.x system call numbers (x86_64)
pub const SyscallNumber = enum(u32) {
    // Standard POSIX syscalls
    sys_exit = 1,
    sys_fork = 2,
    sys_read = 3,
    sys_write = 4,
    sys_open = 5,
    sys_close = 6,
    sys_wait4 = 7,
    sys_link = 9,
    sys_unlink = 10,
    sys_chdir = 12,
    sys_getpid = 20,
    sys_getuid = 24,
    sys_kill = 37,
    sys_getppid = 39,
    sys_dup = 41,
    sys_pipe = 42,
    sys_getgid = 47,
    sys_sigaction = 46,
    sys_sigprocmask = 48,
    sys_ioctl = 54,
    sys_execve = 59,
    sys_munmap = 73,
    sys_mprotect = 74,
    sys_madvise = 75,
    sys_socket = 97,
    sys_connect = 98,
    sys_accept = 30,
    sys_select = 93,
    sys_mmap = 197,
    sys_lseek = 199,
    sys_stat64 = 338,

    // Darwin 19.x specific syscalls
    sys_gettid = 85,
    sys_readdir = 196,
    sys_issetugid = 253,
    sys_lstat64 = 236,
    sys_fstat64 = 224,
    sys_fstatfs64 = 298,
    sys_getfsstat64 = 297,
    sys_access = 33,
    sys_mknod = 14,
    sys_chmod = 15,
    sys_chown = 123,
    sys_umask = 60,
    sys_getegid = 43,
    sys_geteuid = 25,
    sys_quotactl = 148,
    sys_sysctl = 202,

    // Mach syscalls (Darwin specific)
    mach_epoch_receive = 247,
    mach_bootstrap_register = 8,
    mach_bootstrap_check_in = 11,
    mach_port_allocate = 260,
    mach_port_deallocate = 261,
    mach_port_insert_right = 262,
    mach_port_extract_right = 263,
    mach_port_mod_refs = 265,
    mach_port_get_refs = 266,
    mach_port_mutate = 268,
    mach_port_construct = 269,
    mach_port_destruct = 270,

    // Task syscalls
    task_for_pid = 13,
    task_self = 16,
    task_set_info = 271,
    task_get_info = 272,
    task_set_exception_ports = 280,
    task_get_exception_ports = 281,
    task_suspend = 17,
    task_resume = 18,
    task_terminate = 273,

    // Thread syscalls
    thread_self_trap = 331,
    thread_get_port = 332,
    thread_set_state = 333,
    thread_get_state = 334,
    thread_suspend = 335,
    thread_resume = 336,
    thread_terminate = 337,
    thread_abort_safely = 351,
    thread_abort = 352,
    thread_switch = 355,

    // Virtual memory syscalls
    vm_allocate = 241,
    vm_deallocate = 242,
    vm_protect = 243,
    vm_map = 244,
    vm_read = 245,
    vm_write = 246,
    vm_msync = 19,
    vm_madvise = 248,
    vm_remap = 249,
    vm_page_size = 250,

    // Clock syscalls
    clock_get_time = 306,
    clock_sleep = 329,

    // Semaphore syscalls
    semaphore_signal = 347,
    semaphore_signal_all = 348,
    semaphore_signal_thread = 349,
    semaphore_wait = 350,
    semaphore_wait_signal = 21,

    // Shared region syscalls (macOS specific)
    shared_region_map_and_slide = 22,

    // Process info syscalls
    proc_info = 285,
    process_policy = 286,

    // Thread info syscalls
    thread_policy = 356,
    thread_policy_set = 357,
    thread_policy_get = 358,

    // Host info syscalls
    host_info = 362,
    host_processors = 363,
    host_kernel_stats = 364,

    // Mach timebase info
    mach_timebase_info = 305,

    // Ledger syscalls
    ledger = 370,
    ledger2 = 371,

    // Voucher syscalls
    voucher_create = 380,
    voucher_destroy = 381,
    voucher_apply = 382,

    // Other Mach IPC
    mach_msg_trap = 317,
    mach_msg = 318,

    _,
};

pub const SyscallResult = union(enum) {
    success: u64,
    err: u32,
};

pub const SyscallArgs = struct {
    arg0: u64 = 0,
    arg1: u64 = 0,
    arg2: u64 = 0,
    arg3: u64 = 0,
    arg4: u64 = 0,
    arg5: u64 = 0,
};

/// POSIX errno constants (Darwin numbering).
pub const EPERM: u32 = 1;
pub const ENOENT: u32 = 2;
pub const ESRCH: u32 = 3;
pub const EINTR: u32 = 4;
pub const EIO: u32 = 5;
pub const EBADF: u32 = 9;
pub const ECHILD: u32 = 10;
pub const ENOMEM: u32 = 12;
pub const EACCES: u32 = 13;
pub const EFAULT: u32 = 14;
pub const EBUSY: u32 = 16;
pub const EEXIST: u32 = 17;
pub const ENOTDIR: u32 = 20;
pub const EISDIR: u32 = 21;
pub const EINVAL: u32 = 22;
pub const ENFILE: u32 = 23;
pub const EMFILE: u32 = 24;
pub const ENOSPC: u32 = 28;
pub const EPIPE: u32 = 32;
pub const ENOSYS: u32 = 78;

/// Mach error codes
pub const MACH_SEND_INVALID_DEST: u32 = 0x10000002;
pub const MACH_SEND_INVALID_REPLY: u32 = 0x10000003;
pub const MACH_SEND_INVALID_RIGHT: u32 = 0x10000007;
pub const MACH_SEND_INVALID_NOTIFY: u32 = 0x10000009;
pub const MACH_SEND_TOO_LARGE: u32 = 0x1000000B;
pub const MACH_SEND_MSG_SIZE_ERROR: u32 = 0x1000000C;
pub const MACH_RCV_INVALID_NAME: u32 = 0x10004002;
pub const MACH_RCV_LARGE: u32 = 0x10004003;
pub const MACH_RCV_INVALID_COLLECTOR: u32 = 0x10004009;
pub const MACH_RCV_INCOMPATIBLE_RECEIVE_PORT: u32 = 0x10004010;

var initialized: bool = false;

pub fn init() void {
    initialized = true;
    log.info("Darwin 19.x BSD syscall table registered ({} known entries)", .{
        @typeInfo(SyscallNumber).@"enum".fields.len,
    });
}

pub fn dispatch(number: u32, args: SyscallArgs) SyscallResult {
    if (!initialized) return .{ .err = ENOSYS };

    const syscall: SyscallNumber = @enumFromInt(number);

    return switch (syscall) {
        .sys_exit => sysExit(args),
        .sys_read => sysRead(args),
        .sys_write => sysWrite(args),
        .sys_open => sysOpen(args),
        .sys_close => sysClose(args),
        .sys_getpid => sysGetpid(),
        .sys_getppid => sysGetppid(),
        .sys_getuid => sysGetuid(),
        .sys_getgid => sysGetgid(),
        .sys_kill => sysKill(args),
        .sys_dup => sysDup(args),
        .sys_ioctl => sysIoctl(args),
        .sys_wait4 => sysWait4(args),
        .sys_fork => sysFork(),
        .sys_execve => sysExecve(args),
        .sys_mmap => sysMmap(args),
        .sys_munmap => sysMunmap(args),
        .sys_mprotect => sysMprotect(args),
        .sys_socket => sysSocket(args),
        .sys_connect => sysConnect(args),
        .sys_accept => sysAccept(args),
        .sys_select => sysSelect(args),
        .sys_lseek => sysLseek(args),

        // Mach syscalls
        .mach_msg_trap => machMsgTrap(args),
        .mach_msg => machMsg(args),
        .mach_port_allocate => machPortAllocate(args),
        .mach_port_deallocate => machPortDeallocate(args),
        .mach_port_insert_right => machPortInsertRight(args),
        .mach_port_mod_refs => machPortModRefs(args),
        .mach_timebase_info => machTimebaseInfo(args),

        // VM syscalls
        .vm_allocate => vmAllocate(args),
        .vm_deallocate => vmDeallocate(args),
        .vm_protect => vmProtect(args),
        .vm_map => vmMap(args),

        // Clock syscalls
        .clock_get_time => clockGetTime(args),

        // Task syscalls
        .task_self => taskSelf(),
        .task_suspend => taskSuspend(args),
        .task_resume => taskResume(args),
        .task_terminate => taskTerminate(args),

        // Thread syscalls
        .thread_self_trap => threadSelfTrap(),
        .thread_suspend => threadSuspend(args),
        .thread_resume => threadResume(args),
        .thread_terminate => threadTerminate(args),

        _ => {
            log.warn("Unimplemented syscall: {}", .{number});
            return .{ .err = ENOSYS };
        },
    };
}

// ── Syscall Implementations ───────────────────────────────

fn sysExit(args: SyscallArgs) SyscallResult {
    const status: i32 = @intCast(@as(i64, @bitCast(args.arg0)));
    log.info("sys_exit(status={})", .{status});
    proc_mod.exitProcess(0, status);
    return .{ .success = 0 };
}

fn sysRead(args: SyscallArgs) SyscallResult {
    const fd: usize = @intCast(args.arg0);
    const buf: [*]u8 = @ptrFromInt(args.arg1);
    const count: usize = @intCast(args.arg2);

    const p = proc_mod.lookupProcess(0) orelse return .{ .err = ESRCH };
    const fde = p.lookupFd(fd) orelse return .{ .err = EBADF };

    _ = fde;
    _ = buf;

    log.debug("sys_read(fd={}, count={}) stub", .{ fd, count });
    return .{ .err = ENOSYS };
}

fn sysWrite(args: SyscallArgs) SyscallResult {
    const fd: usize = @intCast(args.arg0);
    const buf: [*]const u8 = @ptrFromInt(args.arg1);
    const count: usize = @intCast(args.arg2);

    if (fd == 1 or fd == 2) {
        serial.writeString(buf[0..count]);
        return .{ .success = count };
    }

    log.debug("sys_write(fd={}, count={}) stub", .{ fd, count });
    return .{ .err = EBADF };
}

fn sysOpen(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_open stub", .{});
    return .{ .err = ENOSYS };
}

fn sysClose(args: SyscallArgs) SyscallResult {
    const fd: usize = @intCast(args.arg0);
    const p = proc_mod.lookupProcess(0) orelse return .{ .err = ESRCH };
    if (p.closeFd(fd)) {
        return .{ .success = 0 };
    }
    return .{ .err = EBADF };
}

fn sysGetpid() SyscallResult {
    return .{ .success = 0 };
}

fn sysGetppid() SyscallResult {
    return .{ .success = 0 };
}

fn sysGetuid() SyscallResult {
    const p = proc_mod.lookupProcess(0) orelse return .{ .success = 0 };
    return .{ .success = p.cred.uid };
}

fn sysGetgid() SyscallResult {
    const p = proc_mod.lookupProcess(0) orelse return .{ .success = 0 };
    return .{ .success = p.cred.gid };
}

fn sysKill(args: SyscallArgs) SyscallResult {
    const pid: u32 = @intCast(args.arg0);
    const sig: u8 = @intCast(args.arg1);

    const p = proc_mod.lookupProcess(pid) orelse return .{ .err = ESRCH };
    p.sig_state.postSignal(sig);
    log.debug("sys_kill(pid={}, sig={})", .{ pid, sig });
    return .{ .success = 0 };
}

fn sysDup(args: SyscallArgs) SyscallResult {
    const old_fd: usize = @intCast(args.arg0);
    const p = proc_mod.lookupProcess(0) orelse return .{ .err = ESRCH };
    const src = p.lookupFd(old_fd) orelse return .{ .err = EBADF };
    const new_fd = p.allocFd() orelse return .{ .err = EMFILE };
    p.fds[new_fd] = src.*;
    return .{ .success = new_fd };
}

fn sysIoctl(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_ioctl stub", .{});
    return .{ .err = ENOSYS };
}

fn sysWait4(args: SyscallArgs) SyscallResult {
    _ = args;
    if (proc_mod.waitProcess(0)) |w| {
        return .{ .success = w.pid };
    }
    return .{ .err = ECHILD };
}

fn sysFork() SyscallResult {
    log.debug("sys_fork stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysExecve(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_execve stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysMmap(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_mmap stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysMunmap(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_munmap stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysMprotect(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_mprotect stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysSocket(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_socket stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysConnect(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_connect stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysAccept(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_accept stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysSelect(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_select stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

fn sysLseek(args: SyscallArgs) SyscallResult {
    _ = args;
    log.debug("sys_lseek stub - returns ENOSYS", .{});
    return .{ .err = ENOSYS };
}

// ── Mach IPC Syscalls ─────────────────────────────────────

fn machMsgTrap(_: SyscallArgs) SyscallResult {
    log.debug("mach_msg_trap stub", .{});
    return .{ .err = MACH_SEND_INVALID_DEST };
}

fn machMsg(_: SyscallArgs) SyscallResult {
    log.debug("mach_msg stub", .{});
    return .{ .err = MACH_SEND_INVALID_DEST };
}

fn machPortAllocate(_: SyscallArgs) SyscallResult {
    log.debug("mach_port_allocate stub", .{});
    return .{ .err = MACH_SEND_INVALID_DEST };
}

fn machPortDeallocate(_: SyscallArgs) SyscallResult {
    log.debug("mach_port_deallocate stub", .{});
    return .{ .success = 0 };
}

fn machPortInsertRight(_: SyscallArgs) SyscallResult {
    log.debug("mach_port_insert_right stub", .{});
    return .{ .err = MACH_SEND_INVALID_RIGHT };
}

fn machPortModRefs(_: SyscallArgs) SyscallResult {
    log.debug("mach_port_mod_refs stub", .{});
    return .{ .success = 0 };
}

fn machTimebaseInfo(_: SyscallArgs) SyscallResult {
    log.debug("mach_timebase_info stub", .{});
    return .{ .success = 0 };
}

// ── VM Syscalls ──────────────────────────────────────────

fn vmAllocate(_: SyscallArgs) SyscallResult {
    log.debug("vm_allocate stub", .{});
    return .{ .err = ENOSYS };
}

fn vmDeallocate(_: SyscallArgs) SyscallResult {
    log.debug("vm_deallocate stub", .{});
    return .{ .success = 0 };
}

fn vmProtect(_: SyscallArgs) SyscallResult {
    log.debug("vm_protect stub", .{});
    return .{ .err = ENOSYS };
}

fn vmMap(_: SyscallArgs) SyscallResult {
    log.debug("vm_map stub", .{});
    return .{ .err = ENOSYS };
}

// ── Clock Syscalls ────────────────────────────────────────

fn clockGetTime(_: SyscallArgs) SyscallResult {
    log.debug("clock_get_time stub", .{});
    return .{ .success = 0 };
}

// ── Task Syscalls ───────────────────────────────────────────

fn taskSelf() SyscallResult {
    log.debug("task_self stub", .{});
    return .{ .success = 0 };
}

fn taskSuspend(_: SyscallArgs) SyscallResult {
    log.debug("task_suspend stub", .{});
    return .{ .success = 0 };
}

fn taskResume(_: SyscallArgs) SyscallResult {
    log.debug("task_resume stub", .{});
    return .{ .success = 0 };
}

fn taskTerminate(_: SyscallArgs) SyscallResult {
    log.debug("task_terminate stub", .{});
    return .{ .success = 0 };
}

// ── Thread Syscalls ───────────────────────────────────────

fn threadSelfTrap() SyscallResult {
    log.debug("thread_self_trap stub", .{});
    return .{ .success = 0 };
}

fn threadSuspend(_: SyscallArgs) SyscallResult {
    log.debug("thread_suspend stub", .{});
    return .{ .success = 0 };
}

fn threadResume(_: SyscallArgs) SyscallResult {
    log.debug("thread_resume stub", .{});
    return .{ .success = 0 };
}

fn threadTerminate(_: SyscallArgs) SyscallResult {
    log.debug("thread_terminate stub", .{});
    return .{ .success = 0 };
}
