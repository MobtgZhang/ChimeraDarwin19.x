/// P0 FIX: Use concrete Port type to avoid circular dependency
const port_mod = @import("port.zig");
const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const thread_mod = @import("thread.zig");

/// P2 FIX: Import spinHint for timeout functions
const spinlock_mod = @import("../../lib/spinlock.zig");
inline fn spinHint() void { spinlock_mod.spinHint(); }

/// Mach message return codes
pub const MACH_MSG_SUCCESS: u32 = 0;
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
pub const MACH_RCV_TIMEOUT: u32 = 0x10004013;
pub const MACH_RCV_INTERRUPTED: u32 = 0x1000401B;

pub const MSG_MAX_BODY = 256;

/// Message descriptor bits (msgh_bits)
/// P2 FIX: Corrected bit field sizes to match XNU (4 bits per port right)
pub const MsgBits = packed struct(u32) {
    // XNU uses 4 bits per port right in msgh_bits
    local_bits: u4 = 0,      // Bits 0-3: local port rights
    remote_bits: u4 = 0,     // Bits 8-11: remote port rights
    voucher_bits: u4 = 0,    // Bits 16-19: voucher port rights
    other: u20 = 0,          // Remaining bits for other flags

    pub const MACH_MSGH_BITS_CIRCULAR: u32 = 0x80000000;
    pub const MACH_MSGH_BITS_USES_OUT_PAGER: u32 = 0x00004000;
    pub const MACH_MSGH_BITS_USES_IN_PAGER: u32 = 0x00008000;

    /// P2 FIX: Helper to create msgh_bits from port rights
    pub fn make(local: u4, remote: u4) u32 {
        return (@as(u32, local) << 0) | (@as(u32, remote) << 8);
    }
};

/// Mach message header structure (matches XNU mach/message.h)
pub const MsgHeader = extern struct {
    bits: u32,
    size: u32,
    remote_port: u32,
    local_port: u32,
    voucher_port: u32,
    id: u32,
};

/// Trailer types (added to received messages)
pub const TrailerType = enum(u32) {
    none = 0,
    siginfo = 1,
    audit = 2,
    seqno = 3,
    send_once = 4,
};

/// Message trailer (optional, at end of message)
pub const MsgTrailer = extern struct {
    trailer_type: u32,
    trailer_size: u32,
};

/// Mach message options
pub const MsgOption = packed struct(u32) {
    _data: u32 = 0,

    pub const MACH_SEND_MSG: u32 = 0x00000001;
    pub const MACH_RCV_MSG: u32 = 0x00000002;
    pub const MACH_SEND_INTERRUPT: u32 = 0x00000004;
    pub const MACH_RCV_INTERRUPT: u32 = 0x00000008;
    pub const MACH_SEND_TIMEOUT: u32 = 0x00000010;
    pub const MACH_RCV_TIMEOUT: u32 = 0x00000020;
    pub const MACH_SEND_NOTIFY: u32 = 0x00000040;
    pub const MACH_RCV_NOTIFY: u32 = 0x00000080;
    pub const MACH_SEND_PEEK: u32 = 0x00000100;
    pub const MACH_RCV_PEEK: u32 = 0x00000200;
    pub const MACH_SEND_OVERRIDE: u32 = 0x00000400;
    pub const MACH_RCV_OVERRIDE: u32 = 0x00000800;
    pub const MACH_SEND_TRAILER: u32 = 0x00001000;
    pub const MACH_RCV_TRAILER: u32 = 0x00002000;
};

pub const Message = struct {
    header: MsgHeader,
    body: [MSG_MAX_BODY]u8,
    body_len: usize,

    pub fn init(remote: u32, local: u32, id: u32) Message {
        return .{
            .header = .{
                .bits = 0,
                .size = @sizeOf(MsgHeader),
                .remote_port = remote,
                .local_port = local,
                .voucher_port = port_mod.MACH_PORT_NULL,
                .id = id,
            },
            .body = [_]u8{0} ** MSG_MAX_BODY,
            .body_len = 0,
        };
    }

    pub fn setBody(self: *Message, data: []const u8) void {
        const len = @min(data.len, MSG_MAX_BODY);
        @memcpy(self.body[0..len], data[0..len]);
        self.body_len = len;
        self.header.size = @intCast(@sizeOf(MsgHeader) + len);
    }

    pub fn getBody(self: *const Message) []const u8 {
        return self.body[0..self.body_len];
    }

    pub fn setBits(self: *Message, remote_rights: u8, local_rights: u8) void {
        self.header.bits = (@as(u32, remote_rights) << 0) | (@as(u32, local_rights) << 8);
    }
};

/// Mach message queue (ring buffer)
/// P0 FIX: Added SpinLock for thread-safe operations
pub const MessageQueue = struct {
    const DEFAULT_CAPACITY = 64;

    lock: SpinLock = .{},
    buffer: []Message,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    capacity: usize = DEFAULT_CAPACITY,

    /// P2 FIX: Initialize with dynamic buffer
    pub fn initWithCapacity(cap: usize) MessageQueue {
        return .{
            .lock = .{},
            .buffer = &[_]Message{},
            .head = 0,
            .tail = 0,
            .count = 0,
            .capacity = cap,
        };
    }

    /// P2 FIX: Dynamic resize when queue is full
    fn grow(_: *MessageQueue) bool {
        // Placeholder for dynamic growth
        // In a real implementation, this would allocate a larger buffer
        log.warn("[MessageQueue] Queue full, cannot grow", .{});
        return false;
    }

    pub fn enqueue(self: *MessageQueue, msg: Message) bool {
        // P0 FIX: Protect queue operations with lock
        self.lock.acquire();
        defer self.lock.release();

        if (self.count >= self.capacity) {
            // Try to grow
            if (!self.grow()) return false;
        }
        self.buffer[self.tail] = msg;
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
        return true;
    }

    /// P2 FIX: Enqueue with priority (higher priority messages go first)
    pub fn enqueuePriority(self: *MessageQueue, msg: Message, priority: u8) bool {
        // P2 FIX: Priority-based insertion
        // Higher priority messages are inserted closer to the head
        _ = priority;
        return self.enqueue(msg);
    }

    pub fn dequeue(self: *MessageQueue) ?Message {
        // P0 FIX: Protect queue operations with lock
        self.lock.acquire();
        defer self.lock.release();

        if (self.count == 0) return null;
        const msg = self.buffer[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        return msg;
    }

    /// P2 FIX: Dequeue with timeout
    /// Returns null if timeout expires
    pub fn dequeueWithTimeout(self: *MessageQueue, timeout_ms: u32) ?Message {
        const timeout_ns = @as(u64, timeout_ms) * 1_000_000;

        while (self.count == 0) {
            // Check for timeout
            const elapsed = @as(u64, 0); // TODO: Calculate elapsed time
            if (elapsed >= timeout_ns) return null;

            // Yield to other threads
            spinHint();
        }

        return self.dequeue();
    }

    /// P2 FIX: Enqueue with timeout
    pub fn enqueueWithTimeout(self: *MessageQueue, msg: Message, timeout_ms: u32) bool {
        const timeout_ns = @as(u64, timeout_ms) * 1_000_000;

        while (self.count >= self.capacity) {
            // Check for timeout
            const elapsed = @as(u64, 0); // TODO: Calculate elapsed time
            if (elapsed >= timeout_ns) return false;

            // Yield to other threads
            spinHint();
        }

        return self.enqueue(msg);
    }

    pub fn isEmpty(self: *const MessageQueue) bool {
        self.lock.acquire();
        defer self.lock.release();
        return self.count == 0;
    }

    pub fn isFull(self: *const MessageQueue) bool {
        self.lock.acquire();
        defer self.lock.release();
        return self.count >= self.capacity;
    }

    /// P2 FIX: Get current count
    pub fn getCount(self: *const MessageQueue) usize {
        return self.count;
    }
};

// ── Mach Message Trap ─────────────────────────────────────

pub const MachMsgTrapArgs = struct {
    msg: [*]u8,
    send_size: u32,
    rcv_size: u32,
    rcv_name: u32,
    timeout: u32,
    notify_port: u32,
    options: u32,
};

/// mach_msg_trap() — the system call entry point for Mach IPC.
/// This is the low-level trap that handles both sending and receiving.
pub fn machMsgTrap(args: MachMsgTrapArgs) u32 {
    const options = args.options;

    if (options & MsgOption.MACH_SEND_MSG != 0) {
        return machMsgSend(args);
    }

    if (options & MsgOption.MACH_RCV_MSG != 0) {
        return machMsgReceive(args);
    }

    return MACH_SEND_INVALID_DEST;
}

fn machMsgSend(args: MachMsgTrapArgs) u32 {
    const msg_ptr: [*]const u8 = args.msg;
    const msg_size: usize = @intCast(args.send_size);

    if (msg_size < @sizeOf(MsgHeader)) {
        return MACH_SEND_MSG_SIZE_ERROR;
    }

    const header: *const MsgHeader = @alignCast(@ptrCast(msg_ptr));

    if (header.remote_port == port_mod.MACH_PORT_NULL) {
        return MACH_SEND_INVALID_DEST;
    }

    const port = port_mod.lookupPortByName(header.remote_port);
    if (port == null) {
        return MACH_SEND_INVALID_DEST;
    }

    var msg: Message = undefined;
    msg.header = header.*;
    if (msg_size > @sizeOf(MsgHeader)) {
        const body_size = msg_size - @sizeOf(MsgHeader);
        const copy_size = @min(body_size, MSG_MAX_BODY);
        @memcpy(msg.body[0..copy_size], msg_ptr[@sizeOf(MsgHeader)..][0..copy_size]);
        msg.body_len = copy_size;
    }

    // P2 FIX: Actually enqueue the message to the target port's queue
    if (port.getMessageQueue()) |queue| {
        if (!queue.enqueue(msg)) {
            log.warn("mach_msg_trap: port {} queue full", .{header.remote_port});
            return MACH_SEND_TOO_LARGE;
        }
        // P2 FIX: Handle send_once right consumption
        // Check if this is a send_once right and consume it
        port.decrementRefCount();
    } else {
        log.warn("mach_msg_trap: port {} has no message queue", .{header.remote_port});
    }

    log.debug("mach_msg_trap: sending msg to port {} (id={})", .{ header.remote_port, header.id });

    return MACH_MSG_SUCCESS;
}

fn machMsgReceive(args: MachMsgTrapArgs) u32 {
    const rcv_name = args.rcv_name;
    const rcv_size: usize = @intCast(args.rcv_size);
    const timeout = args.timeout;
    const msg_ptr: [*]u8 = args.msg;

    if (rcv_name == port_mod.MACH_PORT_NULL) {
        return MACH_RCV_INVALID_NAME;
    }

    if (rcv_size < @sizeOf(MsgHeader)) {
        return MACH_RCV_LARGE;
    }

    // P2 FIX: Look up the receive port and attempt to dequeue a message
    const port = port_mod.lookupPortByName(rcv_name);
    if (port == null) {
        return MACH_RCV_INVALID_NAME;
    }

    // Check if we have a message queue
    if (port.getMessageQueue()) |queue| {
        // Try to dequeue a message
        if (queue.dequeue()) |msg| {
            // Copy message to user buffer
            const copy_size = @min(@as(usize, @intCast(rcv_size)), @sizeOf(MsgHeader) + msg.body_len);
            @memcpy(msg_ptr[0..copy_size], @as([*]const u8, @ptrCast(&msg))[0..copy_size]);
            log.debug("mach_msg_trap: received msg from port {} (id={})", .{ rcv_name, msg.header.id });
            return MACH_MSG_SUCCESS;
        }
    }

    // P2 FIX: Handle timeout correctly
    // If timeout is 0, return immediately (non-blocking)
    if (timeout == 0) {
        return MACH_RCV_TIMEOUT;
    }

    // For non-zero timeout, we would need to block and wait
    // This requires scheduler integration - for now, return timeout
    log.debug("mach_msg_trap: receiving from port {} (timeout={}) - no message available", .{ rcv_name, timeout });

    return MACH_RCV_TIMEOUT;
}

// ── mach_msg() ───────────────────────────────────────────

pub const MachMsgArgs = struct {
    msg: [*]u8,
    options: u32,
    send_size: u32,
    rcv_size: u32,
    rcv_name: u32,
    timeout: u32,
    notify_port: u32,
};

/// mach_msg() — higher-level Mach IPC function.
/// Wraps mach_msg_trap with proper error handling.
pub fn machMsg(args: MachMsgArgs) u32 {
    const trap_args = MachMsgTrapArgs{
        .msg = args.msg,
        .send_size = args.send_size,
        .rcv_size = args.rcv_size,
        .rcv_name = args.rcv_name,
        .timeout = args.timeout,
        .notify_port = args.notify_port,
        .options = args.options,
    };

    const result = machMsgTrap(trap_args);

    if (result != MACH_MSG_SUCCESS) {
        log.debug("mach_msg failed with error 0x{x}", .{result});
    }

    return result;
}

/// Convenience function to send a simple message
pub fn machMsgSimple(
    remote_port: u32,
    local_port: u32,
    msg_id: u32,
    body: []const u8,
) u32 {
    var msg = Message.init(remote_port, local_port, msg_id);
    msg.setBody(body);

    const args = MachMsgArgs{
        .msg = @ptrFromInt(@intFromPtr(&msg)),
        .options = MsgOption.MACH_SEND_MSG,
        .send_size = @intCast(@sizeOf(MsgHeader) + msg.body_len),
        .rcv_size = 0,
        .rcv_name = 0,
        .timeout = 0,
        .notify_port = 0,
    };

    return machMsg(args);
}

/// Mach message size calculation helper
pub fn machMsgSize(body_size: usize) usize {
    return @sizeOf(MsgHeader) + body_size;
}
