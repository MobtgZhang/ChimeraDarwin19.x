/// AArch64 GICv2 (Generic Interrupt Controller) stub.
/// On QEMU virt, GICD is at 0x0800_0000 and GICC at 0x0801_0000.

const log = @import("../../../lib/log.zig");

const GICD_BASE: u64 = 0x0800_0000;
const GICC_BASE: u64 = 0x0801_0000;

const GICD_CTLR: *volatile u32 = @ptrFromInt(GICD_BASE + 0x000);
const GICD_ISENABLER0: *volatile u32 = @ptrFromInt(GICD_BASE + 0x100);
const GICC_CTLR: *volatile u32 = @ptrFromInt(GICC_BASE + 0x000);
const GICC_PMR: *volatile u32 = @ptrFromInt(GICC_BASE + 0x004);
const GICC_IAR: *volatile u32 = @ptrFromInt(GICC_BASE + 0x00C);
const GICC_EOIR: *volatile u32 = @ptrFromInt(GICC_BASE + 0x010);

pub fn init() void {
    GICD_CTLR.* = 1;
    GICC_PMR.* = 0xFF;
    GICC_CTLR.* = 1;

    log.info("[GIC]  GICv2 distributor and CPU interface enabled", .{});
}

pub fn enableIrq(irq: u32) void {
    const reg_offset = (irq / 32) * 4;
    const bit: u5 = @intCast(irq % 32);
    const reg: *volatile u32 = @ptrFromInt(GICD_BASE + 0x100 + reg_offset);
    reg.* = @as(u32, 1) << bit;
}

pub fn acknowledge() u32 {
    return GICC_IAR.*;
}

pub fn endOfInterrupt(irq: u32) void {
    GICC_EOIR.* = irq;
}
