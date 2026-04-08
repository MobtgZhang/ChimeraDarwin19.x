/// VFS Syscalls — implements BSD VFS-related system calls.
/// Provides file system operations like mkdir, rmdir, rename, etc.

const log = @import("../../../lib/log.zig");
const vnode_mod = @import("vnode.zig");

pub const MAX_SYSCALL_PATH: usize = 256;

pub const AttrList = struct {
    bitmapcount: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
};

pub const ATTR_CMN_RETURNED_ATTRS: u32 = 0x00020000;
pub const ATTR_CMN_NAME: u32 = 0x00000001;
pub const ATTR_CMN_DEVID: u32 = 0x00000002;
pub const ATTR_CMN_FSID: u32 = 0x00000004;

pub fn init() void {
    log.info("VFS syscall subsystem initialized", .{});
}

pub fn sysChdir(path: [*]const u8) i32 {
    _ = path;
    log.debug("sys_chdir stub", .{});
    return 0;
}

pub fn sysChroot(path: [*]const u8) i32 {
    _ = path;
    log.debug("sys_chroot stub", .{});
    return -1;
}

pub fn sysUnmount(path: [*]const u8, flags: u32) i32 {
    _ = path;
    _ = flags;
    log.debug("sys_unmount stub", .{});
    return -1;
}

pub fn sysRename(old_path: [*]const u8, new_path: [*]const u8) i32 {
    _ = old_path;
    _ = new_path;
    log.debug("sys_rename stub", .{});
    return -1;
}

pub fn sysMkdir(path: [*]const u8, mode: u32) i32 {
    _ = path;
    _ = mode;
    log.debug("sys_mkdir stub", .{});
    return -1;
}

pub fn sysRmdir(path: [*]const u8) i32 {
    _ = path;
    log.debug("sys_rmdir stub", .{});
    return -1;
}

pub fn sysGetattrlist(path: [*]const u8, alist: *const AttrList, buf: [*]u8, bufsize: usize) i32 {
    _ = path;
    _ = alist;
    _ = buf;
    _ = bufsize;
    log.debug("sys_getattrlist stub", .{});
    return -1;
}

pub fn sysSetattrlist(path: [*]const u8, alist: *const AttrList, buf: [*]const u8, bufsize: usize) i32 {
    _ = path;
    _ = alist;
    _ = buf;
    _ = bufsize;
    log.debug("sys_setattrlist stub", .{});
    return -1;
}

pub fn sysExchange(old_path: [*]const u8, new_path: [*]const u8, options: u32) i32 {
    _ = old_path;
    _ = new_path;
    _ = options;
    log.debug("sys_exchange stub", .{});
    return -1;
}

pub fn sysAccess(path: [*]const u8, mode: u32) i32 {
    _ = path;
    _ = mode;
    log.debug("sys_access stub", .{});
    return 0;
}

pub fn sysChmod(path: [*]const u8, mode: u32) i32 {
    _ = path;
    _ = mode;
    log.debug("sys_chmod stub", .{});
    return -1;
}

pub fn sysChown(path: [*]const u8, uid: u32, gid: u32) i32 {
    _ = path;
    _ = uid;
    _ = gid;
    log.debug("sys_chown stub", .{});
    return -1;
}

pub fn sysLstat(path: [*]const u8, buf: [*]u8) i32 {
    _ = path;
    _ = buf;
    log.debug("sys_lstat64 stub", .{});
    return -1;
}

pub fn sysFstat(fd: i32, buf: [*]u8) i32 {
    _ = fd;
    _ = buf;
    log.debug("sys_fstat64 stub", .{});
    return -1;
}

pub fn sysFstatfs(fd: i32, buf: [*]u8) i32 {
    _ = fd;
    _ = buf;
    log.debug("sys_fstatfs64 stub", .{});
    return -1;
}

pub fn sysFsync(fd: i32) i32 {
    _ = fd;
    log.debug("sys_fsync stub", .{});
    return 0;
}
