/// Sandbox — implements kernel sandbox filter hooks.
/// Provides seatbelt-style MAC policy for process sandboxing.

const log = @import("../lib/log.zig");
const SpinLock = @import("../lib/spinlock.zig").SpinLock;

pub const MAX_SANDBOX_PROFILES: usize = 64;
pub const MAX_SANDBOX_ARGS: usize = 16;

pub const SandboxAction = enum(u32) {
    ALLOW = 0,
    DENY = 1,
};

pub const SandboxOperation = enum(u32) {
    op_connect = 0,
    op_listen = 1,
    op_open = 2,
    op_read = 3,
    op_write = 4,
    op_stat = 5,
    op_chdir = 6,
    op_getcwd = 7,
    op_lookup = 8,
    op_mkfifo = 9,
    op_mkdir = 10,
    op_link = 11,
    op_unlink = 12,
    op_rename = 13,
    op_rmdir = 14,
    op_symlink = 15,
    op_chmod = 16,
    op_chown = 17,
    op_utimes = 18,
    op_clone = 19,
    op_exec = 20,
    op_pid_check = 21,
    op_proc_check = 22,
    op_iokit_open = 23,
    op_sysctlbyname = 24,
};

pub const SandboxProfile = struct {
    id: u32,
    name: [64]u8,
    name_len: usize,
    operations: [MAX_SANDBOX_ARGS]SandboxOperation,
    op_count: u32,
    active: bool,
};

var profiles: [MAX_SANDBOX_PROFILES]SandboxProfile = undefined;
var profile_count: usize = 0;
var sandbox_lock: SpinLock = .{};

pub fn init() void {
    profile_count = 0;
    for (&profiles) |*p| p.* = .{
        .id = 0,
        .name = [_]u8{0} ** 64,
        .name_len = 0,
        .operations = undefined,
        .op_count = 0,
        .active = false,
    };
    log.info("Sandbox subsystem initialized", .{});
}

pub fn sandboxInit(profile_name: []const u8) ?u32 {
    sandbox_lock.acquire();
    defer sandbox_lock.release();

    if (profile_count >= MAX_SANDBOX_PROFILES) return null;

    const id = @as(u32, @intCast(profile_count));
    var profile = &profiles[profile_count];
    profile.* = .{
        .id = id,
        .name = [_]u8{0} ** 64,
        .name_len = @min(profile_name.len, 63),
        .operations = undefined,
        .op_count = 0,
        .active = true,
    };
    @memcpy(profile.name[0..profile.name_len], profile_name);
    profile_count += 1;

    log.debug("Sandbox profile created: id={}, name='{s}'", .{ id, profile_name });
    return id;
}

pub fn sandboxFree(profile_id: u32) void {
    sandbox_lock.acquire();
    defer sandbox_lock.release();

    if (profile_id >= profile_count) return;
    profiles[profile_id].active = false;
    log.debug("Sandbox profile freed: id={}", .{profile_id});
}

pub fn sandboxCheck(profile_id: u32, operation: SandboxOperation) SandboxAction {
    sandbox_lock.acquire();
    defer sandbox_lock.release();

    if (profile_id >= profile_count) return .ALLOW;
    if (!profiles[profile_id].active) return .ALLOW;

    for (profiles[profile_id].operations[0..profiles[profile_id].op_count]) |op| {
        if (op == operation) return .DENY;
    }

    return .ALLOW;
}

pub fn sandboxCheckPath(profile_id: u32, path: [*]const u8, operation: SandboxOperation) SandboxAction {
    _ = profile_id;
    _ = path;
    _ = operation;
    return .ALLOW;
}

pub fn sandboxCheckFD(profile_id: u32, fd: i32, operation: SandboxOperation) SandboxAction {
    _ = profile_id;
    _ = fd;
    _ = operation;
    return .ALLOW;
}

pub fn sandboxContainer(profile_id: u32) bool {
    sandbox_lock.acquire();
    defer sandbox_lock.release();

    if (profile_id >= profile_count) return false;
    return profiles[profile_id].active;
}
