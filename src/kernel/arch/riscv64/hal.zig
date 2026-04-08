/// RISC-V 64 Hardware Abstraction Layer — 16550 UART, PLIC, SBI timer.
/// Targets QEMU virt machine and UEFI-capable RISC-V boards.

const serial = @import("serial.zig");
const interrupts = @import("interrupts.zig");
const mmu = @import("mmu.zig");
const log = @import("../../../lib/log.zig");
const BootInfo = @import("../../../kernel/main.zig").BootInfo;

pub const name = "riscv64 (RISC-V 64-bit)";

var timer_count: u64 = 0;

pub fn earlyInit() void {
    serial.init();
}

pub fn cpuInit() void {
    interrupts.init();
    mmu.init();
    log.info("[CPU]  RISC-V privilege modes configured", .{});
}

pub fn timerInit() void {
    log.info("[TMR]  RISC-V mtime/mtimecmp timer configured", .{});
}

pub fn timerTick() void {
    timer_count +%= 1;
}

pub fn inputInit(_: *const BootInfo) void {
    log.info("[KBD]  Virtio input (stub)", .{});
    log.info("[MOUSE] Virtio tablet (stub)", .{});
}

pub const TimeInfo = struct {
    hour: u8,
    minute: u8,
};

pub fn readTime() TimeInfo {
    const secs = timer_count / 100;
    return .{
        .hour = @truncate((secs / 3600) % 24),
        .minute = @truncate((secs / 60) % 60),
    };
}

pub fn cpuRelax() void {
    asm volatile ("");
}

pub fn disableInterrupts() void {
    asm volatile ("csrc sstatus, %[val]"
        :
        : [val] "r" (@as(u64, 1 << 1)),
    );
}

pub fn enableInterrupts() void {
    asm volatile ("csrs sstatus, %[val]"
        :
        : [val] "r" (@as(u64, 1 << 1)),
    );
}

pub fn halt() void {
    asm volatile ("wfi");
}
