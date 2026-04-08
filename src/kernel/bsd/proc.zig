/// BSD Process — the user-visible process abstraction layered on top of
/// Mach Tasks.  Adds file descriptor tables, credentials, process groups,
/// and wait/exit semantics.

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const task_mod = @import("../mach/task.zig");
const signal_mod = @import("signal.zig");

pub const MAX_PROCS: usize = task_mod.MAX_TASKS;
pub const MAX_FDS: usize = 256;

pub const ProcState = enum(u8) {
    embryo,
    runnable,
    sleeping,
    stopped,
    zombie,
};

pub const FileDescriptor = struct {
    vnode_id: u32,
    offset: u64,
    flags: u32,
    active: bool,

    pub const O_RDONLY: u32 = 0x0000;
    pub const O_WRONLY: u32 = 0x0001;
    pub const O_RDWR: u32 = 0x0002;
    pub const O_APPEND: u32 = 0x0008;
    pub const O_CREAT: u32 = 0x0200;
    pub const O_TRUNC: u32 = 0x0400;
    pub const O_NONBLOCK: u32 = 0x0004;
    pub const O_CLOEXEC: u32 = 0x1000000;
};

pub const Credentials = struct {
    uid: u32,
    gid: u32,
    euid: u32,
    egid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    is_issetugid: bool,
};

pub const SigAltStack = struct {
    ss_sp: u64,
    ss_size: u64,
    ss_flags: u32,

    pub const SS_DISABLE: u32 = 0x0004;
    pub const SS_ONSTACK: u32 = 0x0001;
};

pub const Process = struct {
    pid: u32,
    ppid: u32,
    pgid: u32,
    sid: u32,
    state: ProcState,
    exit_status: i32,
    exit_signal: i32,

    cred: Credentials,
    p_ucred: u32,
    p_sigstk: SigAltStack,

    fds: [MAX_FDS]FileDescriptor,
    fd_count: usize,

    sig_state: signal_mod.SignalState,

    parent: u32,
    children_head: u32,
    children_next: u32,

    pcomm: [17]u8,
    name: [64]u8,
    name_len: usize,
    active: bool,

    p_stats: u32,
    p_limit: u32,

    pub fn getName(self: *const Process) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getPcomm(self: *const Process) []const u8 {
        var len: usize = 0;
        while (len < 17 and self.pcomm[len] != 0) len += 1;
        return self.pcomm[0..len];
    }

    pub fn allocFd(self: *Process) ?usize {
        for (0..MAX_FDS) |i| {
            if (!self.fds[i].active) {
                self.fds[i].active = true;
                self.fd_count += 1;
                return i;
            }
        }
        return null;
    }

    pub fn closeFd(self: *Process, fd: usize) bool {
        if (fd >= MAX_FDS or !self.fds[fd].active) return false;
        self.fds[fd].active = false;
        self.fd_count -|= 1;
        return true;
    }

    pub fn lookupFd(self: *Process, fd: usize) ?*FileDescriptor {
        if (fd >= MAX_FDS or !self.fds[fd].active) return null;
        return &self.fds[fd];
    }

    pub fn dupFd(self: *Process, old_fd: usize) ?usize {
        const src = self.lookupFd(old_fd) orelse return null;
        const new_fd = self.allocFd() orelse return null;
        self.fds[new_fd] = src.*;
        return new_fd;
    }
};

var procs: [MAX_PROCS]Process = undefined;
var proc_active: [MAX_PROCS]bool = [_]bool{false} ** MAX_PROCS;
var next_pid: u32 = 0;
var lock: SpinLock = .{};

pub fn init() void {
    for (&proc_active) |*a| a.* = false;
    next_pid = 0;
    _ = createProcess("kernel", 0, 0) orelse {};
    log.info("BSD process table initialized (max {} procs)", .{MAX_PROCS});
}

pub fn createProcess(name: []const u8, ppid: u32, pgid: u32) ?u32 {
    lock.acquire();
    defer lock.release();

    if (next_pid >= MAX_PROCS) return null;
    const pid = next_pid;

    var p = &procs[pid];
    p.* = .{
        .pid = pid,
        .ppid = ppid,
        .pgid = if (pgid != 0) pgid else pid,
        .sid = pid,
        .state = .embryo,
        .exit_status = 0,
        .exit_signal = 0,
        .cred = .{
            .uid = 0,
            .gid = 0,
            .euid = 0,
            .egid = 0,
            .ruid = 0,
            .rgid = 0,
            .svuid = 0,
            .svgid = 0,
            .is_issetugid = false,
        },
        .p_ucred = 0,
        .p_sigstk = .{ .ss_sp = 0, .ss_size = 0, .ss_flags = SigAltStack.SS_DISABLE },
        .fds = undefined,
        .fd_count = 0,
        .sig_state = signal_mod.SignalState.init(),
        .parent = ppid,
        .children_head = 0,
        .children_next = 0,
        .pcomm = [_]u8{0} ** 17,
        .name = [_]u8{0} ** 64,
        .name_len = @min(name.len, 64),
        .active = true,
        .p_stats = 0,
        .p_limit = 0,
    };
    for (&p.fds) |*fd| fd.active = false;
    @memcpy(p.name[0..p.name_len], name[0..p.name_len]);

    setupStdFds(p);

    proc_active[pid] = true;
    p.state = .runnable;
    next_pid += 1;

    log.debug("Process created: pid={}, name='{s}'", .{pid, name});
    return pid;
}

fn setupStdFds(p: *Process) void {
    p.fds[0] = .{ .vnode_id = 0, .offset = 0, .flags = FileDescriptor.O_RDONLY, .active = true };
    p.fds[1] = .{ .vnode_id = 1, .offset = 0, .flags = FileDescriptor.O_WRONLY, .active = true };
    p.fds[2] = .{ .vnode_id = 1, .offset = 0, .flags = FileDescriptor.O_WRONLY, .active = true };
    p.fd_count = 3;
}

pub fn lookupProcess(pid: u32) ?*Process {
    if (pid >= MAX_PROCS or !proc_active[pid]) return null;
    return &procs[pid];
}

pub fn exitProcess(pid: u32, status: i32) void {
    lock.acquire();
    defer lock.release();

    if (pid == 0) return;
    if (pid >= MAX_PROCS or !proc_active[pid]) return;

    var p = &procs[pid];
    p.exit_status = status;
    p.state = .zombie;

    for (&p.fds) |*fd| fd.active = false;
    p.fd_count = 0;

    for (0..next_pid) |i| {
        if (proc_active[i] and procs[i].ppid == pid) {
            procs[i].ppid = 0;
        }
    }

    log.debug("Process {} exited with status {}", .{ pid, status });
}

pub fn waitProcess(ppid: u32) ?struct { pid: u32, status: i32 } {
    lock.acquire();
    defer lock.release();

    for (0..next_pid) |i| {
        if (!proc_active[i]) continue;
        const p = &procs[i];
        if (p.ppid == ppid and p.state == .zombie) {
            const result = .{ .pid = p.pid, .status = p.exit_status };
            p.active = false;
            proc_active[i] = false;
            return result;
        }
    }
    return null;
}

pub fn sigparent(pid: u32, sig: u32) void {
    const p = lookupProcess(pid) orelse return;
    const ppid = p.ppid;
    const parent = lookupProcess(ppid) orelse return;
    parent.sig_state.postSignal(sig);
}

pub fn setpgid(pid: u32, pgid: u32) i32 {
    const p = lookupProcess(pid) orelse return -1;
    if (pgid == 0) {
        p.pgid = pid;
    } else {
        p.pgid = pgid;
    }
    return 0;
}

pub fn getpgid(pid: u32) i32 {
    const p = lookupProcess(pid) orelse return -1;
    return @as(i32, @intCast(p.pgid));
}

pub fn setpgrp(pid: u32) i32 {
    return setpgid(pid, pid);
}

pub fn getpgrp(pid: u32) i32 {
    return getpgid(pid);
}

pub fn setsid(pid: u32) i32 {
    const p = lookupProcess(pid) orelse return -1;
    if (p.pgid == pid) return -1;
    p.sid = pid;
    p.pgid = pid;
    return 0;
}

pub fn getuid() u32 {
    const p = lookupProcess(0) orelse return 0;
    return p.cred.uid;
}

pub fn geteuid() u32 {
    const p = lookupProcess(0) orelse return 0;
    return p.cred.euid;
}

pub fn getgid() u32 {
    const p = lookupProcess(0) orelse return 0;
    return p.cred.gid;
}

pub fn getegid() u32 {
    const p = lookupProcess(0) orelse return 0;
    return p.cred.egid;
}

pub fn issetugid(pid: u32) bool {
    const p = lookupProcess(pid) orelse return true;
    return p.cred.is_issetugid;
}

pub fn getpid() u32 {
    return 0;
}
