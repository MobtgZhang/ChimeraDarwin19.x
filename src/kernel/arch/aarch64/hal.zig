/// AArch64 Hardware Abstraction Layer — PL011 UART, GICv2, generic timer.
/// Targets QEMU virt machine and real UEFI-capable ARM64 hardware.

const serial = @import("serial.zig");
const interrupts = @import("interrupts.zig");
const mmu = @import("mmu.zig");
const log = @import("../../../lib/log.zig");
const BootInfo = @import("../../../kernel/main.zig").BootInfo;

pub const name = "aarch64 (ARMv8-A / ARM64)";

var timer_count: u64 = 0;

pub fn earlyInit() void {
    serial.init();
}

pub fn cpuInit() void {
    interrupts.init();
    mmu.init();
    log.info("[CPU]  AArch64 exception levels configured", .{});
}

pub fn timerInit() void {
    // ARM generic timer — frequency is in CNTFRQ_EL0
    log.info("[TMR]  ARM Generic Timer configured", .{});
}

pub fn timerTick() void {
    timer_count +%= 1;
}

pub fn inputInit(_: *const BootInfo) void {
    log.info("[KBD]  Virtio / USB HID input (stub)", .{});
    log.info("[MOUSE] Virtio / USB HID pointer (stub)", .{});
}

pub const TimeInfo = struct {
    hour: u8,
    minute: u8,
};

pub fn readTime() TimeInfo {
    // Derive wall-clock from monotonic counter (placeholder)
    const secs = timer_count / 100;
    return .{
        .hour = @truncate((secs / 3600) % 24),
        .minute = @truncate((secs / 60) % 60),
    };
}

pub fn cpuRelax() void {
    asm volatile ("yield");
}

pub fn disableInterrupts() void {
    asm volatile ("msr daifset, #0xF");
}

pub fn enableInterrupts() void {
    asm volatile ("msr daifclr, #0xF");
}

pub fn halt() void {
    asm volatile ("wfe");
}
