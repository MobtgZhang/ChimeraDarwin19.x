/// RISC-V PLIC (Platform-Level Interrupt Controller) stub.
/// On QEMU virt, PLIC is at 0x0C00_0000.

const log = @import("../../../lib/log.zig");

const PLIC_BASE: u64 = 0x0C00_0000;
const PLIC_PRIORITY: u64 = PLIC_BASE + 0x0;
const PLIC_PENDING: u64 = PLIC_BASE + 0x1000;
const PLIC_ENABLE: u64 = PLIC_BASE + 0x2000;
const PLIC_THRESHOLD: u64 = PLIC_BASE + 0x200000;
const PLIC_CLAIM: u64 = PLIC_BASE + 0x200004;

pub fn init() void {
    // Set threshold to 0 (accept all priorities)
    const threshold: *volatile u32 = @ptrFromInt(PLIC_THRESHOLD);
    threshold.* = 0;

    log.info("[PLIC] RISC-V PLIC initialized (threshold=0)", .{});
}

pub fn enableIrq(irq: u32) void {
    if (irq == 0) return;
    const enable_reg: *volatile u32 = @ptrFromInt(PLIC_ENABLE + (irq / 32) * 4);
    enable_reg.* |= @as(u32, 1) << @intCast(irq % 32);

    const prio_reg: *volatile u32 = @ptrFromInt(PLIC_PRIORITY + irq * 4);
    prio_reg.* = 1;
}

pub fn claim() u32 {
    const reg: *volatile u32 = @ptrFromInt(PLIC_CLAIM);
    return reg.*;
}

pub fn complete(irq: u32) void {
    const reg: *volatile u32 = @ptrFromInt(PLIC_CLAIM);
    reg.* = irq;
}
