/// BSD Pipe — implements pipe() syscall for inter-process communication.
/// Provides unidirectional byte streams between related processes.

const log = @import("../../../lib/log.zig");
const SpinLock = @import("../../../lib/spinlock.zig").SpinLock;

pub const MAX_PIPES: usize = 64;
pub const PIPE_BUF_SIZE: usize = 4096;

/// Pipe buffer
pub const PipeBuffer = struct {
    data: [PIPE_BUF_SIZE]u8,
    read_pos: usize = 0,
    write_pos: usize = 0,
    count: usize = 0,
};

/// Pipe structure
pub const Pipe = struct {
    read_fd: i32,
    write_fd: i32,
    buffer: PipeBuffer,
    read_refs: u32,
    write_refs: u32,
    active: bool,
    error: bool,
};

var pipes: [MAX_PIPES]Pipe = undefined;
var pipe_count: usize = 0;
var pipe_lock: SpinLock = .{};

pub fn init() void {
    pipe_count = 0;
    for (&pipes) |*p| p.* = .{
        .read_fd = -1,
        .write_fd = -1,
        .buffer = .{
            .data = [_]u8{0} ** PIPE_BUF_SIZE,
            .read_pos = 0,
            .write_pos = 0,
            .count = 0,
        },
        .read_refs = 0,
        .write_refs = 0,
        .active = false,
        .error = false,
    };
    log.info("BSD Pipe subsystem initialized (max {} pipes)", .{MAX_PIPES});
}

pub fn createPipe() ?[2]i32 {
    pipe_lock.acquire();
    defer pipe_lock.release();

    if (pipe_count >= MAX_PIPES) return null;

    const idx = pipe_count;
    var pipe = &pipes[idx];
    pipe.active = true;
    pipe.error = false;
    pipe.buffer.count = 0;
    pipe.buffer.read_pos = 0;
    pipe.buffer.write_pos = 0;
    pipe.read_refs = 1;
    pipe.write_refs = 1;

    pipe.read_fd = @as(i32, @intCast(pipe_count)) * 2;
    pipe.write_fd = pipe.read_fd + 1;

    const result = [2]i32{ pipe.read_fd, pipe.write_fd };
    pipe_count += 1;
    log.debug("Pipe created: read_fd={}, write_fd={}", .{ result[0], result[1] });
    return result;
}

pub fn pipeRead(fd: i32, buf: [*]u8, count: usize) i64 {
    pipe_lock.acquire();
    defer pipe_lock.release();

    const idx = @as(usize, @intCast(fd / 2));
    if (idx >= MAX_PIPES) return -1;

    var pipe = &pipes[idx];
    if (!pipe.active or fd != pipe.read_fd) return -1;

    if (pipe.buffer.count == 0) {
        if (pipe.error) return 0;
        return -1;
    }

    const to_read = @min(count, pipe.buffer.count);
    for (0..to_read) |i| {
        const pos = (pipe.buffer.read_pos + i) % PIPE_BUF_SIZE;
        buf[i] = pipe.buffer.data[pos];
    }

    pipe.buffer.read_pos = (pipe.buffer.read_pos + to_read) % PIPE_BUF_SIZE;
    pipe.buffer.count -= to_read;

    return @as(i64, @intCast(to_read));
}

pub fn pipeWrite(fd: i32, buf: [*]const u8, count: usize) i64 {
    pipe_lock.acquire();
    defer pipe_lock.release();

    const idx = @as(usize, @intCast(fd / 2));
    if (idx >= MAX_PIPES) return -1;

    var pipe = &pipes[idx];
    if (!pipe.active or fd != pipe.write_fd) return -1;

    const available = PIPE_BUF_SIZE - pipe.buffer.count;
    if (available == 0) {
        return -1;
    }

    const to_write = @min(count, available);
    for (0..to_write) |i| {
        const pos = (pipe.buffer.write_pos + i) % PIPE_BUF_SIZE;
        pipe.buffer.data[pos] = buf[i];
    }

    pipe.buffer.write_pos = (pipe.buffer.write_pos + to_write) % PIPE_BUF_SIZE;
    pipe.buffer.count += to_write;

    return @as(i64, @intCast(to_write));
}

pub fn closePipeRead(fd: i32) void {
    pipe_lock.acquire();
    defer pipe_lock.release();

    const idx = @as(usize, @intCast(fd / 2));
    if (idx >= MAX_PIPES) return;

    var pipe = &pipes[idx];
    if (fd == pipe.read_fd) {
        pipe.read_refs -|= 1;
        if (pipe.read_refs == 0) {
            pipe.error = true;
        }
    }
}

pub fn closePipeWrite(fd: i32) void {
    pipe_lock.acquire();
    defer pipe_lock.release();

    const idx = @as(usize, @intCast(fd / 2));
    if (idx >= MAX_PIPES) return;

    var pipe = &pipes[idx];
    if (fd == pipe.write_fd) {
        pipe.write_refs -|= 1;
        if (pipe.write_refs == 0) {
            pipe.error = true;
        }
    }
}
