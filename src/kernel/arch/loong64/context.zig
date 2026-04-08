/// LoongArch64 Context Switch — implements context switching for loongarch64.
/// Saves and restores general-purpose registers, SP, and PC.

const log = @import("../../../lib/log.zig");

pub const CpuContext = extern struct {
    zero: u64 = 0,
    ra: u64 = 0,
    tp: u64 = 0,
    sp: u64 = 0,
    gp: u64 = 0,
    a0: u64 = 0,
    a1: u64 = 0,
    a2: u64 = 0,
    a3: u64 = 0,
    a4: u64 = 0,
    a5: u64 = 0,
    a6: u64 = 0,
    a7: u64 = 0,
    t0: u64 = 0,
    t1: u64 = 0,
    t2: u64 = 0,
    t3: u64 = 0,
    t4: u64 = 0,
    t5: u64 = 0,
    t6: u64 = 0,
    t7: u64 = 0,
    t8: u64 = 0,
    s0: u64 = 0,
    s1: u64 = 0,
    s2: u64 = 0,
    s3: u64 = 0,
    s4: u64 = 0,
    s5: u64 = 0,
    s6: u64 = 0,
    s7: u64 = 0,
    s8: u64 = 0,
    pc: u64 = 0,
};

/// Perform context switch between two threads
pub fn contextSwitch(old_sp: *u64, new_sp: u64) void {
    asm volatile (
        \\st.d $ra, %[old], 0
        \\st.d $tp, %[old], 8
        \\st.d $sp, %[old], 16
        \\st.d $gp, %[old], 24
        \\st.d $a0, %[old], 32
        \\st.d $a1, %[old], 40
        \\st.d $a2, %[old], 48
        \\st.d $a3, %[old], 56
        \\st.d $a4, %[old], 64
        \\st.d $a5, %[old], 72
        \\st.d $a6, %[old], 80
        \\st.d $a7, %[old], 88
        \\st.d $t0, %[old], 96
        \\st.d $t1, %[old], 104
        \\st.d $t2, %[old], 112
        \\st.d $t3, %[old], 120
        \\st.d $t4, %[old], 128
        \\st.d $t5, %[old], 136
        \\st.d $t6, %[old], 144
        \\st.d $t7, %[old], 152
        \\st.d $t8, %[old], 160
        \\st.d $s0, %[old], 168
        \\st.d $s1, %[old], 176
        \\st.d $s2, %[old], 184
        \\st.d $s3, %[old], 192
        \\st.d $s4, %[old], 200
        \\st.d $s5, %[old], 208
        \\st.d $s6, %[old], 216
        \\st.d $s7, %[old], 224
        \\st.d $s8, %[old], 232
        \\move %[old], $sp
        \\move $sp, %[new_sp]
        \\ld.d $ra, $sp, 0
        \\ld.d $tp, $sp, 8
        \\ld.d $sp, $sp, 16
        \\ld.d $gp, $sp, 24
        \\ld.d $a0, $sp, 32
        \\ld.d $a1, $sp, 40
        \\ld.d $a2, $sp, 48
        \\ld.d $a3, $sp, 56
        \\ld.d $a4, $sp, 64
        \\ld.d $a5, $sp, 72
        \\ld.d $a6, $sp, 80
        \\ld.d $a7, $sp, 88
        \\ld.d $t0, $sp, 96
        \\ld.d $t1, $sp, 104
        \\ld.d $t2, $sp, 112
        \\ld.d $t3, $sp, 120
        \\ld.d $t4, $sp, 128
        \\ld.d $t5, $sp, 136
        \\ld.d $t6, $sp, 144
        \\ld.d $t7, $sp, 152
        \\ld.d $t8, $sp, 160
        \\ld.d $s0, $sp, 168
        \\ld.d $s1, $sp, 176
        \\ld.d $s2, $sp, 184
        \\ld.d $s3, $sp, 192
        \\ld.d $s4, $sp, 200
        \\ld.d $s5, $sp, 208
        \\ld.d $s6, $sp, 216
        \\ld.d $s7, $sp, 224
        \\ld.d $s8, $sp, 232
        \\jr $ra
        : [old] "+r" (old_sp)
        : [new_sp] "r" (new_sp)
        : .{ .memory = true }
    );
}

pub fn init() void {
    log.info("LoongArch64 context switch initialized", .{});
}
