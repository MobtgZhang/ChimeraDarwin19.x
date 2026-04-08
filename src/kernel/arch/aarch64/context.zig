/// ARM64 Context Switch — implements context switching for aarch64.
/// Saves and restores general-purpose registers, SP, and PC.

const log = @import("../../../lib/log.zig");

pub const CpuContext = extern struct {
    x0: u64 = 0,
    x1: u64 = 0,
    x2: u64 = 0,
    x3: u64 = 0,
    x4: u64 = 0,
    x5: u64 = 0,
    x6: u64 = 0,
    x7: u64 = 0,
    x8: u64 = 0,
    x9: u64 = 0,
    x10: u64 = 0,
    x11: u64 = 0,
    x12: u64 = 0,
    x13: u64 = 0,
    x14: u64 = 0,
    x15: u64 = 0,
    x16: u64 = 0,
    x17: u64 = 0,
    x18: u64 = 0,
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    x29: u64 = 0,
    x30: u64 = 0,
    sp: u64 = 0,
    pc: u64 = 0,
};

/// Perform context switch between two threads
pub fn contextSwitch(old_sp: *u64, new_sp: u64) void {
    asm volatile (
        \\stp x0, x1, [x0, #-16]!
        \\stp x2, x3, [x0, #16]
        \\stp x4, x5, [x0, #32]
        \\stp x6, x7, [x0, #48]
        \\stp x8, x9, [x0, #64]
        \\stp x10, x11, [x0, #80]
        \\stp x12, x13, [x0, #96]
        \\stp x14, x15, [x0, #112]
        \\stp x16, x17, [x0, #128]
        \\stp x18, x19, [x0, #144]
        \\stp x20, x21, [x0, #160]
        \\stp x22, x23, [x0, #176]
        \\stp x24, x25, [x0, #192]
        \\stp x26, x27, [x0, #208]
        \\stp x28, x29, [x0, #224]
        \\str x30, [x0, #240]
        \\mov x1, sp
        \\str x1, [x0, #248]
        \\str x30, [x0, #256]
        \\mov sp, %[new_sp]
        \\ldp x0, x1, [sp], #16
        \\ldp x2, x3, [sp], #16
        \\ldp x4, x5, [sp], #16
        \\ldp x6, x7, [sp], #16
        \\ldp x8, x9, [sp], #16
        \\ldp x10, x11, [sp], #16
        \\ldp x12, x13, [sp], #16
        \\ldp x14, x15, [sp], #16
        \\ldp x16, x17, [sp], #16
        \\ldp x18, x19, [sp], #16
        \\ldp x20, x21, [sp], #16
        \\ldp x22, x23, [sp], #16
        \\ldp x24, x25, [sp], #16
        \\ldp x26, x27, [sp], #16
        \\ldp x28, x29, [sp], #16
        \\ldr x30, [sp], #8
        \\ldr x1, [sp], #8
        \\mov sp, x1
        \\ret
        : [old_sp] "+r" (old_sp), [new_sp] "+r" (new_sp)
        :
        : .{ .memory = true }
    );
}

pub fn init() void {
    log.info("ARM64 context switch initialized", .{});
}
