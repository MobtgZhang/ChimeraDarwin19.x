/// RISC-V64 Context Switch — implements context switching for riscv64.
/// Saves and restores general-purpose registers, SP, and PC.

const log = @import("../../../lib/log.zig");

pub const CpuContext = extern struct {
    ra: u64 = 0,
    sp: u64 = 0,
    gp: u64 = 0,
    tp: u64 = 0,
    t0: u64 = 0,
    t1: u64 = 0,
    t2: u64 = 0,
    s0: u64 = 0,
    s1: u64 = 0,
    a0: u64 = 0,
    a1: u64 = 0,
    a2: u64 = 0,
    a3: u64 = 0,
    a4: u64 = 0,
    a5: u64 = 0,
    a6: u64 = 0,
    a7: u64 = 0,
    s2: u64 = 0,
    s3: u64 = 0,
    s4: u64 = 0,
    s5: u64 = 0,
    s6: u64 = 0,
    s7: u64 = 0,
    s8: u64 = 0,
    s9: u64 = 0,
    s10: u64 = 0,
    s11: u64 = 0,
    t3: u64 = 0,
    t4: u64 = 0,
    t5: u64 = 0,
    t6: u64 = 0,
    pc: u64 = 0,
};

/// Perform context switch between two threads
pub fn contextSwitch(old_sp: *u64, new_sp: u64) void {
    asm volatile (
        \\sd ra, 0(%[old])
        \\sd sp, 8(%[old])
        \\sd gp, 16(%[old])
        \\sd tp, 24(%[old])
        \\sd t0, 32(%[old])
        \\sd t1, 40(%[old])
        \\sd t2, 48(%[old])
        \\sd s0, 56(%[old])
        \\sd s1, 64(%[old])
        \\sd a0, 72(%[old])
        \\sd a1, 80(%[old])
        \\sd a2, 88(%[old])
        \\sd a3, 96(%[old])
        \\sd a4, 104(%[old])
        \\sd a5, 112(%[old])
        \\sd a6, 120(%[old])
        \\sd a7, 128(%[old])
        \\sd s2, 136(%[old])
        \\sd s3, 144(%[old])
        \\sd s4, 152(%[old])
        \\sd s5, 160(%[old])
        \\sd s6, 168(%[old])
        \\sd s7, 176(%[old])
        \\sd s8, 184(%[old])
        \\sd s9, 192(%[old])
        \\sd s10, 200(%[old])
        \\sd s11, 208(%[old])
        \\sd t3, 216(%[old])
        \\sd t4, 224(%[old])
        \\sd t5, 232(%[old])
        \\sd t6, 240(%[old])
        \\mv %[old], sp
        \\mv sp, %[new_sp]
        \\ld ra, 0(sp)
        \\ld gp, 16(sp)
        \\ld tp, 24(sp)
        \\ld t0, 32(sp)
        \\ld t1, 40(sp)
        \\ld t2, 48(sp)
        \\ld s0, 56(sp)
        \\ld s1, 64(sp)
        \\ld a0, 72(sp)
        \\ld a1, 80(sp)
        \\ld a2, 88(sp)
        \\ld a3, 96(sp)
        \\ld a4, 104(sp)
        \\ld a5, 112(sp)
        \\ld a6, 120(sp)
        \\ld a7, 128(sp)
        \\ld s2, 136(sp)
        \\ld s3, 144(sp)
        \\ld s4, 152(sp)
        \\ld s5, 160(sp)
        \\ld s6, 168(sp)
        \\ld s7, 176(sp)
        \\ld s8, 184(sp)
        \\ld s9, 192(sp)
        \\ld s10, 200(sp)
        \\ld s11, 208(sp)
        \\ld t3, 216(sp)
        \\ld t4, 224(sp)
        \\ld t5, 232(sp)
        \\ld t6, 240(sp)
        \\ld sp, 8(sp)
        \\ret
        : [old] "+r" (old_sp)
        : [new_sp] "r" (new_sp)
        : .{ .memory = true }
    );
}

pub fn init() void {
    log.info("RISC-V64 context switch initialized", .{});
}
