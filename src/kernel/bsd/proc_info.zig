/// BSD Process Info — implements proc_info for getting process information.
/// Provides interfaces to query process and thread information.

const log = @import("../../../lib/log.zig");
const proc = @import("proc.zig");
const thread = @import("../mach/thread.zig");

pub const MAX_PROC_INFO_ENTRIES: usize = 128;

/// Proc info call types
pub const ProcInfoCall = enum(u32) {
    proc_info_flavor_t = 1,
    proc_pidinfo = 2,
    proc_pidpath = 3,
    proc_pidfdinfo = 4,
    proc_kperf = 5,
    proc_pidbsdinfo = 6,
};

/// Process info flavor
pub const ProcInfoFlavor = enum(u32) {
    proc_pidinfo = 2,
    proc_pidpath = 3,
    proc_pidfdinfo = 4,
    proc_pidbsdinfo = 6,
};

/// BSD info structure
pub const ProcBsdInfo = extern struct {
    pbi_flags: u32,
    pbi_status: u32,
    pbi_xstatus: u32,
    pbi_pid: u32,
    pbi_ppid: u32,
    pbi_uid: u32,
    pbi_gid: u32,
    pbi_ruid: u32,
    pbi_rgid: u32,
    pbi_svuid: u32,
    pbi_svgid: u32,
    rfu_1: u32,
    pbi_comm: [17]u8,
    pbi_name: [17]u8,
    pbi_nfiles: u32,
    pbi_pgid: u32,
    pbi_pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    pbi_nice: i32,
    pbi_start_tvsec: u64,
    pbi_start_tvusec: u64,
};

/// Task info flavor
pub const TaskInfoFlavor = enum(u32) {
    task_basic_flavor = 3,
    task_events_flavor = 4,
    task_thread_info_flavor = 5,
    task_threadlist_flavor = 6,
    task_ledger_flavor = 7,
};

pub fn init() void {
    log.info("BSD proc_info subsystem initialized", .{});
}

pub fn getProcBsdInfo(pid: u32) ?ProcBsdInfo {
    const p = proc.lookupProcess(pid) orelse return null;

    var info: ProcBsdInfo = undefined;
    @memset(@as([*]u8, @ptrCast(&info))[0..@sizeOf(ProcBsdInfo)], 0);

    info.pbi_pid = pid;
    info.pbi_ppid = p.ppid;
    info.pbi_uid = p.cred.uid;
    info.pbi_gid = p.cred.gid;
    info.pbi_ruid = p.cred.uid;
    info.pbi_rgid = p.cred.gid;
    info.pbi_svuid = p.cred.uid;
    info.pbi_svgid = p.cred.gid;
    info.pbi_pgid = p.pgid;
    info.pbi_nice = 0;
    info.pbi_nfiles = p.fd_count;

    const name = p.getName();
    const copy_len = @min(name.len, 16);
    @memcpy(info.pbi_comm[0..copy_len], name);
    @memcpy(info.pbi_name[0..copy_len], name);

    return info;
}

pub fn getTaskInfo(task_pid: u32, flavor: TaskInfoFlavor) ?[32]u8 {
    _ = task_pid;
    _ = flavor;
    return null;
}

pub fn procInfoCall(call: ProcInfoCall, pid: u32, flavor: u32, arg: u64, buf: [*]u8, buf_size: u32) i64 {
    switch (call) {
        .proc_pidinfo => return procPidInfo(pid, flavor, arg, buf, buf_size),
        .proc_pidpath => return procPidPath(pid, buf, buf_size),
        .proc_pidbsdinfo => return procPidBsdInfo(pid, buf, buf_size),
        else => return -1,
    }
}

fn procPidInfo(pid: u32, flavor: u32, arg: u64, buf: [*]u8, buf_size: u32) i64 {
    _ = arg;
    _ = buf_size;
    _ = pid;
    _ = flavor;
    return -1;
}

fn procPidPath(pid: u32, buf: [*]u8, buf_size: u32) i64 {
    const p = proc.lookupProcess(pid) orelse return -1;

    const name = p.getName();
    const copy_len = @min(@as(usize, @intCast(buf_size)) - 1, name.len);
    @memcpy(buf[0..copy_len], name[0..copy_len]);
    buf[copy_len] = 0;

    return @as(i64, @intCast(copy_len + 1));
}

fn procPidBsdInfo(pid: u32, buf: [*]u8, buf_size: u32) i64 {
    if (buf_size < @sizeOf(ProcBsdInfo)) return -1;

    const info = getProcBsdInfo(pid) orelse return -1;
    @memcpy(buf[0..@sizeOf(ProcBsdInfo)], @as([*]u8, @ptrCast(&info))[0..@sizeOf(ProcBsdInfo)]);

    return @sizeOf(ProcBsdInfo);
}
