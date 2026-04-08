/// sysctl — implements BSD sysctl interface for kernel parameters.
/// Provides a hierarchical interface for getting and setting kernel variables.

const log = @import("../lib/log.zig");
const SpinLock = @import("../lib/spinlock.zig").SpinLock;

pub const MAX_SYSCTL_NODES: usize = 256;

pub const CTL_TYPE_NONE: u32 = 0;
pub const CTL_TYPE_INT: u32 = 1;
pub const CTL_TYPE_STRING: u32 = 2;
pub const CTL_TYPE_QUAD: u32 = 3;
pub const CTL_TYPE_STRUCT: u32 = 4;
pub const CTL_TYPE_OPAQUE: u32 = 5;

pub const SYSCTL_VERS: u32 = 0x00001000;

pub const SysctlHandler = *const fn (name: [*]const u32, namelen: usize, oldp: [*]u8, oldlenp: *usize, newp: [*]const u8, newlen: usize) i32;

pub const SysctlNode = struct {
    oid: [16]u32,
    oid_len: usize,
    ctl_type: u32,
    handler: ?SysctlHandler,
    data: u64,
    active: bool,
};

var sysctl_nodes: [MAX_SYSCTL_NODES]SysctlNode = undefined;
var sysctl_count: usize = 0;
var sysctl_lock: SpinLock = .{};

pub fn init() void {
    sysctl_count = 0;
    for (&sysctl_nodes) |*n| n.* = .{
        .oid = undefined,
        .oid_len = 0,
        .ctl_type = CTL_TYPE_NONE,
        .handler = null,
        .data = 0,
        .active = false,
    };

    registerBaseNodes();
    log.info("sysctl subsystem initialized", .{});
}

pub fn registerSysctlNode(
    oid: []const u32,
    ctl_type: u32,
    handler: ?SysctlHandler,
    data: u64,
) ?u32 {
    sysctl_lock.acquire();
    defer sysctl_lock.release();

    if (sysctl_count >= MAX_SYSCTL_NODES) return null;

    const id = @as(u32, @intCast(sysctl_count));
    var node = &sysctl_nodes[sysctl_count];
    node.* = .{
        .oid = undefined,
        .oid_len = @min(oid.len, 16),
        .ctl_type = ctl_type,
        .handler = handler,
        .data = data,
        .active = true,
    };
    @memcpy(node.oid[0..node.oid_len], oid);
    sysctl_count += 1;

    return id;
}

pub fn lookupSysctl(oid: []const u32) ?*SysctlNode {
    sysctl_lock.acquire();
    defer sysctl_lock.release();

    for (sysctl_nodes[0..sysctl_count]) |*node| {
        if (!node.active) continue;
        if (node.oid_len != oid.len) continue;

        var match = true;
        for (0..oid.len) |i| {
            if (node.oid[i] != oid[i]) {
                match = false;
                break;
            }
        }
        if (match) return node;
    }
    return null;
}

pub fn dispatchSysctl(
    oid: [*]const u32,
    namelen: usize,
    oldp: [*]u8,
    oldlenp: *usize,
    newp: [*]const u8,
    newlen: usize,
) i32 {
    const oid_slice = oid[0..namelen];
    const node = lookupSysctl(oid_slice) orelse return -1;

    if (node.handler) |handler| {
        return handler(oid, namelen, oldp, oldlenp, newp, newlen);
    }

    return -1;
}

fn registerBaseNodes() void {
    _ = registerSysctlNode(&.{ 0 }, CTL_TYPE_STRING, null, 0);
    _ = registerSysctlNode(&.{ 1 }, CTL_TYPE_INT, null, 0);
    _ = registerSysctlNode(&.{ 2 }, CTL_TYPE_STRING, null, 0);
    log.debug("Base sysctl nodes registered", .{});
}

// ── Hardware info handlers ────────────────────────────────

fn hwNcpuHandler(
    _: [*]const u32,
    _: usize,
    oldp: [*]u8,
    oldlenp: *usize,
    _: [*]const u8,
    _: usize,
) i32 {
    if (oldp != @as([*]u8, @ptrFromInt(0)) and oldlenp.* >= @sizeOf(u32)) {
        const val: u32 = 1;
        @as(*u32, @alignCast(@ptrCast(oldp))).* = val;
        oldlenp.* = @sizeOf(u32);
    }
    return 0;
}

pub fn hwNcpuSysctl() u32 {
    return 1;
}
