/// VNode — virtual file system node abstraction.
/// Every open file, directory, device or pipe is represented by a VNode
/// that dispatches operations through a vtable to the underlying FS.

const log = @import("../../../lib/log.zig");
const SpinLock = @import("../../../lib/spinlock.zig").SpinLock;

pub const VType = enum(u8) {
    none,
    regular,
    directory,
    block_device,
    char_device,
    symlink,
    socket,
    fifo,
};

pub const MAX_VNODES: usize = 1024;

pub const VNodeOps = struct {
    read: ?*const fn (vnode: *VNode, buf: [*]u8, offset: u64, count: usize) i64,
    write: ?*const fn (vnode: *VNode, buf: [*]const u8, offset: u64, count: usize) i64,
    ioctl: ?*const fn (vnode: *VNode, cmd: u32, arg: u64) i32,
    lookup: ?*const fn (dir: *VNode, name: []const u8) ?*VNode,
    create: ?*const fn (dir: *VNode, name: []const u8, vtype: VType) ?*VNode,
    remove: ?*const fn (dir: *VNode, name: []const u8) i32,
    readdir: ?*const fn (dir: *VNode, buf: [*]u8, count: usize) i64,
    stat: ?*const fn (vnode: *VNode, st: *Stat) i32,
    getattr: ?*const fn (vnode: *VNode, buf: [*]u8, size: usize) i32,
    setattr: ?*const fn (vnode: *VNode, buf: [*]const u8) i32,
};

pub const Stat = struct {
    dev: u32 = 0,
    ino: u64 = 0,
    mode: u32 = 0,
    nlink: u32 = 1,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
    atime: u64 = 0,
    mtime: u64 = 0,
    ctime: u64 = 0,
};

pub const VNode = struct {
    id: u32,
    vtype: VType,
    ops: *const VNodeOps,
    ref_count: u32,
    mount: ?*Mount,
    data: u64,
    name: [64]u8,
    name_len: usize,
    parent: ?*VNode,
    children: ?*VNode,
    next_sibling: ?*VNode,
    lock: SpinLock,
    active: bool,

    pub fn getName(self: *const VNode) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn retain(self: *VNode) void {
        self.lock.acquire();
        defer self.lock.release();
        self.ref_count += 1;
    }

    pub fn release(self: *VNode) void {
        self.lock.acquire();
        if (self.ref_count > 1) {
            self.ref_count -= 1;
            self.lock.release();
            return;
        }
        self.ref_count = 0;
        self.active = false;
        self.lock.release();
    }

    pub fn put(self: *VNode) void {
        self.release();
    }

    pub fn get(self: *VNode) void {
        self.retain();
    }

    pub fn read(self: *VNode, buf: [*]u8, offset: u64, count: usize) i64 {
        if (self.ops.read) |op| return op(self, buf, offset, count);
        return -1;
    }

    pub fn write(self: *VNode, buf: [*]const u8, offset: u64, count: usize) i64 {
        if (self.ops.write) |op| return op(self, buf, offset, count);
        return -1;
    }

    pub fn ioctl(self: *VNode, cmd: u32, arg: u64) i32 {
        if (self.ops.ioctl) |op| return op(self, cmd, arg);
        return -1;
    }

    pub fn lookup(self: *VNode, child_name: []const u8) ?*VNode {
        if (self.ops.lookup) |op| return op(self, child_name);
        return null;
    }

    pub fn stat(self: *VNode, st: *Stat) i32 {
        if (self.ops.stat) |op| return op(self, st);
        return -1;
    }
};

pub const FsOps = struct {
    mount: ?*const fn (dev: u64) ?*VNode,
    unmount: ?*const fn (root: *VNode) i32,
    sync: ?*const fn () void,
};

pub const Mount = struct {
    fs_type: [16]u8,
    root: ?*VNode,
    ops: *const FsOps,
    device: u64,
    flags: u32,
    active: bool,
};

var mounts: [MAX_MOUNTS]Mount = undefined;
var mount_count: usize = 0;

pub const MAX_MOUNTS: usize = 16;

var vnode_pool: [MAX_VNODES]VNode = undefined;
var pool_used: usize = 0;
var pool_lock: SpinLock = .{};

pub fn registerMount(fs_type: []const u8, root: *VNode, ops: *const FsOps, device: u64) bool {
    if (mount_count >= MAX_MOUNTS) return false;
    var m = &mounts[mount_count];
    m.* = .{
        .fs_type = [_]u8{0} ** 16,
        .root = root,
        .ops = ops,
        .device = device,
        .flags = 0,
        .active = true,
    };
    const len = @min(fs_type.len, 16);
    @memcpy(m.fs_type[0..len], fs_type[0..len]);
    mount_count += 1;
    return true;
}

pub fn allocVNode(
    vtype: VType,
    ops: *const VNodeOps,
    name: []const u8,
) ?*VNode {
    pool_lock.acquire();
    defer pool_lock.release();

    if (pool_used >= MAX_VNODES) return null;
    const v = &vnode_pool[pool_used];
    v.* = .{
        .id = @intCast(pool_used),
        .vtype = vtype,
        .ops = ops,
        .ref_count = 1,
        .mount = null,
        .data = 0,
        .name = [_]u8{0} ** 64,
        .name_len = @min(name.len, 64),
        .parent = null,
        .children = null,
        .next_sibling = null,
        .lock = .{},
        .active = true,
    };
    @memcpy(v.name[0..v.name_len], name[0..v.name_len]);
    pool_used += 1;
    return v;
}

pub fn vnodeCreate(vtype: VType, ops: *const VNodeOps, name: []const u8) ?*VNode {
    return allocVNode(vtype, ops, name);
}

pub fn init() void {
    pool_used = 0;
    mount_count = 0;
    log.info("VFS subsystem initialized (max {} vnodes, {} mounts)", .{ MAX_VNODES, MAX_MOUNTS });
}
