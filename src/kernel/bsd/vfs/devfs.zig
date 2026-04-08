/// DevFS — the /dev device filesystem.
/// Provides character and block device nodes for the BSD layer.

const log = @import("../../../lib/log.zig");
const vnode = @import("vnode.zig");
const builtin = @import("builtin");
const serial = switch (builtin.cpu.arch) {
    .x86_64 => @import("../../arch/x86_64/serial.zig"),
    .aarch64 => @import("../../arch/aarch64/serial.zig"),
    .riscv64 => @import("../../arch/riscv64/serial.zig"),
    .loongarch64 => @import("../../arch/loong64/serial.zig"),
    else => @compileError("Unsupported architecture"),
};

pub const MAX_DEVICES: usize = 128;

pub const DeviceType = enum(u8) {
    char_device,
    block_device,
};

pub const DeviceOps = struct {
    read: ?*const fn (dev: *Device, buf: [*]u8, count: usize) i64,
    write: ?*const fn (dev: *Device, buf: [*]const u8, count: usize) i64,
    ioctl: ?*const fn (dev: *Device, cmd: u32, arg: u64) i32,
};

pub const Device = struct {
    major: u16,
    minor: u16,
    dev_type: DeviceType,
    ops: DeviceOps,
    name: [32]u8,
    name_len: usize,
    vn: ?*vnode.VNode,
    active: bool,

    pub fn getName(self: *const Device) []const u8 {
        return self.name[0..self.name_len];
    }
};

var devices: [MAX_DEVICES]Device = undefined;
var device_count: usize = 0;
var root_vnode: ?*vnode.VNode = null;

fn devRead(vn: *vnode.VNode, buf: [*]u8, _: u64, count: usize) i64 {
    const dev = findDeviceByVNode(vn) orelse return -1;
    if (dev.ops.read) |rd| return rd(dev, buf, count);
    return -1;
}

fn devWrite(vn: *vnode.VNode, buf: [*]const u8, _: u64, count: usize) i64 {
    const dev = findDeviceByVNode(vn) orelse return -1;
    if (dev.ops.write) |wr| return wr(dev, buf, count);
    return -1;
}

fn devIoctl(vn: *vnode.VNode, cmd: u32, arg: u64) i32 {
    const dev = findDeviceByVNode(vn) orelse return -1;
    if (dev.ops.ioctl) |io| return io(dev, cmd, arg);
    return -1;
}

fn devLookup(_: *vnode.VNode, name: []const u8) ?*vnode.VNode {
    for (0..device_count) |i| {
        if (!devices[i].active) continue;
        const dname = devices[i].getName();
        if (name.len == dname.len and eql(name, dname)) return devices[i].vn;
    }
    return null;
}

fn devStat(vn: *vnode.VNode, st: *vnode.Stat) i32 {
    const dev = findDeviceByVNode(vn) orelse return -1;
    st.* = .{
        .dev = (@as(u32, dev.major) << 16) | dev.minor,
        .ino = vn.id,
        .mode = if (dev.dev_type == .char_device) 0o20666 else 0o60666,
        .size = 0,
    };
    return 0;
}

const dev_vnode_ops = vnode.VNodeOps{
    .read = &devRead,
    .write = &devWrite,
    .ioctl = &devIoctl,
    .lookup = &devLookup,
    .create = null,
    .remove = null,
    .readdir = null,
    .stat = &devStat,
    .getattr = null,
    .setattr = null,
};

const devfs_ops = vnode.FsOps{
    .mount = null,
    .unmount = null,
    .sync = null,
};

pub fn init() void {
    device_count = 0;
    for (&devices) |*d| d.active = false;

    root_vnode = vnode.allocVNode(.directory, &dev_vnode_ops, "dev");

    registerBuiltinDevices();

    if (root_vnode) |rv| {
        _ = vnode.registerMount("devfs", rv, &devfs_ops, 0);
    }

    log.info("DevFS initialized: {} devices", .{device_count});
}

pub fn registerDevice(
    name: []const u8,
    major: u16,
    minor: u16,
    dev_type: DeviceType,
    ops: DeviceOps,
) ?*Device {
    if (device_count >= MAX_DEVICES) return null;
    var dev = &devices[device_count];
    dev.* = .{
        .major = major,
        .minor = minor,
        .dev_type = dev_type,
        .ops = ops,
        .name = [_]u8{0} ** 32,
        .name_len = @min(name.len, 32),
        .vn = null,
        .active = true,
    };
    @memcpy(dev.name[0..dev.name_len], name[0..dev.name_len]);

    const vtype: vnode.VType = switch (dev_type) {
        .char_device => .char_device,
        .block_device => .block_device,
    };
    dev.vn = vnode.allocVNode(vtype, &dev_vnode_ops, name);
    if (dev.vn) |vn| {
        vn.data = device_count;
        if (root_vnode) |rv| {
            vn.parent = rv;
            vn.next_sibling = rv.children;
            rv.children = vn;
        }
    }

    device_count += 1;
    return dev;
}

pub fn lookupDevice(major: u16, minor: u16) ?*Device {
    for (0..device_count) |i| {
        if (!devices[i].active) continue;
        if (devices[i].major == major and devices[i].minor == minor) return &devices[i];
    }
    return null;
}

fn nullRead(_: *Device, buf: [*]u8, count: usize) i64 {
    _ = buf;
    _ = count;
    return 0;
}

fn nullWrite(_: *Device, _: [*]const u8, count: usize) i64 {
    return @intCast(count);
}

fn zeroRead(_: *Device, buf: [*]u8, count: usize) i64 {
    for (0..count) |i| buf[i] = 0;
    return @intCast(count);
}

fn consoleWrite(_: *Device, buf: [*]const u8, count: usize) i64 {
    serial.writeString(buf[0..count]);
    return @intCast(count);
}

fn consoleRead(_: *Device, _: [*]u8, _: usize) i64 {
    return 0;
}

fn randomRead(dev: *Device, buf: [*]u8, count: usize) i64 {
    _ = dev;
    for (0..count) |i| {
        buf[i] = @as(u8, @intCast(i * 17 + 42));
    }
    return @intCast(count);
}

fn urandomRead(dev: *Device, buf: [*]u8, count: usize) i64 {
    return randomRead(dev, buf, count);
}

fn registerBuiltinDevices() void {
    _ = registerDevice("null", 1, 3, .char_device, .{
        .read = &nullRead,
        .write = &nullWrite,
        .ioctl = null,
    });

    _ = registerDevice("zero", 1, 5, .char_device, .{
        .read = &zeroRead,
        .write = &nullWrite,
        .ioctl = null,
    });

    _ = registerDevice("console", 5, 1, .char_device, .{
        .read = &consoleRead,
        .write = &consoleWrite,
        .ioctl = null,
    });

    _ = registerDevice("random", 8, 0, .char_device, .{
        .read = &randomRead,
        .write = &nullWrite,
        .ioctl = null,
    });

    _ = registerDevice("urandom", 8, 1, .char_device, .{
        .read = &urandomRead,
        .write = &nullWrite,
        .ioctl = null,
    });
}

fn findDeviceByVNode(vn: *vnode.VNode) ?*Device {
    const idx = vn.data;
    if (idx >= device_count) return null;
    if (devices[idx].active) return &devices[idx];
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (ca != cb) return false;
    return true;
}
