/// P0 FIX: Use concrete MessageQueue type from message.zig to avoid circular dependency
/// Import at compile time to resolve the opaque type
const message_mod = @import("message.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const std = @import("std");

pub const PortRight = enum(u32) {
    send,
    receive,
    send_once,
    port_set,
    dead_name,
};

pub const MACH_PORT_NULL: u32 = 0;
/// P0 FIX: Expanded port name space to 32 bits (from 16 bits)
pub const MAX_PORTS: usize = 65536;
const MAX_PORT_NAMES: u32 = 0xFFFFFFFF;

/// P0 FIX: Properly define MessageQueue type to avoid circular dependency
pub const MessageQueue = message_mod.MessageQueue;

/// P0 FIX: Port state with atomic active flag
const PortState = enum(u8) {
    inactive = 0,
    active = 1,
    destroyed = 2,
};

/// P0 FIX: Use atomic types for reference and message counting
pub const Port = struct {
    name: u32,
    right: PortRight,
    ref_count: u32,
    msg_count: u32,
    /// P0 FIX: Atomic active flag
    state: u8,
    /// P0 FIX: Properly initialize message queue
    mqueue: MessageQueue,

    /// P0 FIX: Maximum reference count to prevent overflow
    const MAX_REF_COUNT: u32 = 0x7FFFFFFF;

    pub fn init(name: u32, right: PortRight) Port {
        return .{
            .name = name,
            .right = right,
            .ref_count = 1,
            .msg_count = 0,
            .state = @intFromEnum(PortState.active),
            .mqueue = MessageQueue.initWithCapacity(64),
        };
    }

    /// P0 FIX: Atomic reference count increment with overflow check
    pub fn retain(self: *Port) void {
        const prev = @atomicRmw(u32, &self.ref_count, .Add, 1, .acq_rel);
        // P0 FIX: Check for overflow after atomic increment
        if (prev >= MAX_REF_COUNT) {
            log.warn("[Port] Reference count overflow for port {}", .{self.name});
            // Rollback
            _ = @atomicRmw(u32, &self.ref_count, .Sub, 1, .acq_rel);
        }
    }

    /// P0 FIX: Atomic reference count decrement
    /// P0 FIX: Returns true if this was the last reference and port should be destroyed
    pub fn release(self: *Port) bool {
        const prev = @atomicRmw(u32, &self.ref_count, .Sub, 1, .acq_rel);
        if (prev == 1) {
            // P0 FIX: Atomic state update
            @atomicStore(u8, &self.state, @intFromEnum(PortState.destroyed), .seq_cst);
            return true;
        }
        return false;
    }

    /// P0 FIX: Check if port is active (atomic read)
    pub fn isActive(self: *const Port) bool {
        return @atomicLoad(u8, &self.state, .acquire) == @intFromEnum(PortState.active);
    }

    /// P0 FIX: Atomic message count increment
    pub fn incMsgCount(self: *Port) void {
        _ = @atomicRmw(u32, &self.msg_count, .Add, 1, .acq_rel);
    }

    /// P0 FIX: Atomic message count decrement with underflow check
    pub fn decMsgCount(self: *Port) void {
        const prev = @atomicRmw(u32, &self.msg_count, .Sub, 1, .acq_rel);
        if (prev == 0) {
            log.warn("[Port] Message count underflow for port {}", .{self.name});
        }
    }

    /// P0 FIX: Get current message count atomically
    pub fn getMsgCount(self: *const Port) u32 {
        return @atomicLoad(u32, &self.msg_count, .acquire);
    }

    /// P2 FIX: Get pointer to message queue
    pub fn getMessageQueue(self: *Port) ?*MessageQueue {
        if (!self.isActive()) return null;
        return &self.mqueue;
    }

    /// P2 FIX: Decrement reference count and handle special rights
    pub fn decrementRefCount(self: *Port) void {
        // For send_once rights, the right is consumed on send
        if (self.right == .send_once) {
            _ = self.release();
        }
    }
};

/// P0 FIX: Log utility for port operations
const log = @import("../../lib/log.zig");

pub const PortNamespace = struct {
    /// P0 FIX: Dynamic port storage using optional array
    ports: []?Port,
    next_name: u32,
    lock: SpinLock,
    port_count: u32,

    /// P0 FIX: Initialize with given port array
    pub fn initWithBuffer(buffer: []?Port) PortNamespace {
        for (buffer) |*p| {
            p.* = null;
        }
        return .{
            .ports = buffer,
            .next_name = 1,
            .lock = .{},
            .port_count = 0,
        };
    }

    pub fn allocatePort(self: *PortNamespace, right: PortRight) ?u32 {
        self.lock.acquire();
        defer self.lock.release();

        // P0 FIX: Check for port name wraparound
        if (self.next_name >= MAX_PORT_NAMES) {
            log.warn("[Port] Port name space exhausted", .{});
            return null;
        }

        const name = self.next_name;
        self.next_name +%= 1;

        // Find a free slot
        for (self.ports, 0..) |slot, idx| {
            if (slot == null) {
                self.ports[idx] = Port.init(name, right);
                self.port_count += 1;
                return name;
            }
        }

        // No free slots
        log.warn("[Port] Port namespace full (max {})", .{self.ports.len});
        return null;
    }

    pub fn lookupPort(self: *PortNamespace, name: u32) ?*Port {
        // P0 FIX: Quick bounds check without lock (for lock-free fast path)
        if (name >= self.ports.len) return null;

        // P0 FIX: Atomic read of active state
        const slot = self.ports[name];
        if (slot) |*port| {
            if (port.isActive()) return port;
        }
        return null;
    }

    pub fn deallocatePort(self: *PortNamespace, name: u32) bool {
        self.lock.acquire();
        defer self.lock.release();

        if (name >= self.ports.len) return false;

        const slot = self.ports[name];
        if (slot) |*port| {
            if (!port.isActive()) return false;

            // P0 FIX: Clean up message queue before deallocating
            while (port.getMessageQueue()) |queue| {
                while (queue.dequeue()) |_| {}
            }

            // Mark as inactive
            @atomicStore(u8, &port.state, @intFromEnum(PortState.inactive), .seq_cst);
            self.ports[name] = null;
            self.port_count -= 1;
            log.debug("[Port] Deallocated port {}", .{name});
            return true;
        }
        return false;
    }

    /// P0 FIX: Get port count
    pub fn getPortCount(self: *const PortNamespace) u32 {
        return @atomicLoad(u32, &self.port_count, .acquire);
    }
};
