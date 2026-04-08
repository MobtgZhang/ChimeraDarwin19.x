/// Mach Voucher — resource attribution for Mach IPC messages.
/// Implements the voucher mechanism for tracking CPU, memory, and I/O resources.

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;

pub const MACH_VOUCHER_NULL: u32 = 0;
pub const MAX_VOUCHERS: usize = 128;

/// Voucher attribute key types
pub const VoucherAttrKey = enum(u32) {
    all = 0,
    cpu_lock_grp = 1,
    cpu_lock_attr = 2,
    cpu_time = 3,
    memory_lock_grp = 4,
    memory_lock_attr = 5,
    memory_lock = 6,
    io_bandwidth = 7,
    debug = 8,
};

/// Mach voucher attribute value
pub const VoucherAttrValue = struct {
    key: VoucherAttrKey,
    value: u64,
    ref_count: u32,
};

/// Mach voucher structure
pub const Voucher = struct {
    id: u32,
    ref_count: u32,
    attr_count: u32,
    attrs: [8]VoucherAttrValue,
    active: bool,

    pub fn retain(self: *Voucher) void {
        self.ref_count += 1;
    }

    pub fn release(self: *Voucher) bool {
        if (self.ref_count > 1) {
            self.ref_count -= 1;
            return false;
        }
        self.ref_count = 0;
        self.active = false;
        return true;
    }

    pub fn getAttr(self: *const Voucher, key: VoucherAttrKey) ?u64 {
        for (self.attrs[0..self.attr_count]) |attr| {
            if (attr.key == key) return attr.value;
        }
        return null;
    }

    pub fn setAttr(self: *Voucher, key: VoucherAttrKey, value: u64) bool {
        for (self.attrs[0..self.attr_count]) |*attr| {
            if (attr.key == key) {
                attr.value = value;
                return true;
            }
        }
        if (self.attr_count >= 8) return false;
        self.attrs[self.attr_count] = .{
            .key = key,
            .value = value,
            .ref_count = 1,
        };
        self.attr_count += 1;
        return true;
    }
};

var vouchers: [MAX_VOUCHERS]Voucher = undefined;
var voucher_count: usize = 0;
var voucher_lock: SpinLock = .{};

pub fn init() void {
    voucher_count = 0;
    for (&vouchers) |*v| v.active = false;
    log.info("Mach Voucher subsystem initialized (max {} vouchers)", .{MAX_VOUCHERS});
}

/// Create a new voucher with default attributes
pub fn voucherCreate() ?u32 {
    voucher_lock.acquire();
    defer voucher_lock.release();

    if (voucher_count >= MAX_VOUCHERS) return null;

    const id = @as(u32, @intCast(voucher_count));
    var v = &vouchers[voucher_count];
    v.* = .{
        .id = id,
        .ref_count = 1,
        .attr_count = 0,
        .attrs = undefined,
        .active = true,
    };

    // Set default attributes
    _ = v.setAttr(.cpu_time, 0);
    _ = v.setAttr(.memory_lock_grp, 0);
    _ = v.setAttr(.io_bandwidth, 0);

    voucher_count += 1;
    log.debug("Voucher created: id={}", .{id});
    return id;
}

/// Create a voucher with specific attributes
pub fn voucherCreateWithAttrs(attrs: []const VoucherAttrValue) ?u32 {
    voucher_lock.acquire();
    defer voucher_lock.release();

    if (voucher_count >= MAX_VOUCHERS) return null;
    if (attrs.len > 8) return null;

    const id = @as(u32, @intCast(voucher_count));
    var v = &vouchers[voucher_count];
    v.* = .{
        .id = id,
        .ref_count = 1,
        .attr_count = @intCast(attrs.len),
        .attrs = undefined,
        .active = true,
    };

    for (attrs, 0..) |attr, i| {
        v.attrs[i] = attr;
    }

    voucher_count += 1;
    return id;
}

/// Get a voucher by ID
pub fn lookupVoucher(id: u32) ?*Voucher {
    if (id >= MAX_VOUCHERS) return null;
    if (!vouchers[id].active) return null;
    return &vouchers[id];
}

/// Retain a voucher reference
pub fn voucherRetain(id: u32) bool {
    const v = lookupVoucher(id) orelse return false;
    v.retain();
    return true;
}

/// Release a voucher reference
pub fn voucherRelease(id: u32) bool {
    voucher_lock.acquire();
    defer voucher_lock.release();

    const v = lookupVoucher(id) orelse return false;
    return v.release();
}

/// Apply a voucher to the current thread/task
pub fn voucherApply(voucher_id: u32) u32 {
    const v = lookupVoucher(voucher_id) orelse return 1;
    v.retain();
    log.debug("Voucher {} applied", .{voucher_id});
    return 0;
}

/// Get voucher attribute
pub fn voucherGetAttr(voucher_id: u32, key: VoucherAttrKey) ?u64 {
    const v = lookupVoucher(voucher_id) orelse return null;
    return v.getAttr(key);
}
