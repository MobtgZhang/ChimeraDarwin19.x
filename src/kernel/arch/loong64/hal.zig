/// LoongArch64 Hardware Abstraction Layer.
/// Targets QEMU loongarch64 virt machine and Loongson 2K3000/3A5000/3A6000.
///
/// Implements the portable HAL interface consumed by kernel/main.zig:
///   earlyInit, cpuInit, timerInit, timerTick, inputInit,
///   readTime, cpuRelax, disableInterrupts, enableInterrupts, halt.

const csr = @import("csr.zig");
const serial = @import("serial.zig");
const interrupts = @import("interrupts.zig");
const mmu = @import("mmu.zig");
const log = @import("../../../lib/log.zig");
const BootInfo = @import("../../../kernel/main.zig").BootInfo;

pub const name = "loongarch64 (LoongArch 64-bit)";

var timer_count: u64 = 0;

// Stable Counter frequency — 100 MHz on QEMU virt, varies on real
// hardware (3A5000: 100 MHz, 3A6000: 100 MHz, 2K3000: 100 MHz).
// Read from the timer at boot and stored here.
var counter_freq: u64 = 100_000_000;

pub fn earlyInit() void {
    serial.init();
}

pub fn cpuInit() void {
    // Enable FPU (needed even if we don't use FP, some library code
    // may touch FP registers during init)
    const euen = csr.read(csr.EUEN);
    csr.write(csr.EUEN, euen | csr.EUEN_FPE);

    interrupts.init();
    mmu.init();

    // Log CPU identity
    const cpuid = csr.read(csr.CPUID);
    log.info("[CPU]  LoongArch64 CSRs configured (CPUID=0x{x})", .{cpuid});
}

pub fn timerInit() void {
    // Configure the stable counter timer for periodic ticks.
    // TCFG: enable | periodic | initial value
    //
    // With 100 MHz counter, an initial value of 1_000_000 gives
    // a 100 Hz tick (10 ms period), which is typical for an OS timer.

    const tick_interval: u64 = counter_freq / 100; // 100 Hz
    const tcfg_val = csr.TCFG_EN | csr.TCFG_PERIODIC |
        (tick_interval << csr.TCFG_INITVAL_SHIFT);
    csr.write(csr.TCFG, tcfg_val);

    log.info("[TMR]  LoongArch stable counter timer: {} Hz, interval={}", .{
        @as(u64, 100),
        tick_interval,
    });
}

pub fn timerTick() void {
    timer_count +%= 1;
}

pub fn inputInit(_: *const BootInfo) void {
    log.info("[KBD]  Input: virtio-keyboard (stub, awaiting driver)", .{});
    log.info("[MOUSE] Input: virtio-tablet (stub, awaiting driver)", .{});
}

pub const TimeInfo = struct {
    hour: u8,
    minute: u8,
};

pub fn readTime() TimeInfo {
    // Derive wall-clock from tick count.  100 ticks/sec from timerTick().
    const secs = timer_count / 100;
    return .{
        .hour = @truncate((secs / 3600) % 24),
        .minute = @truncate((secs / 60) % 60),
    };
}

pub fn cpuRelax() void {
    // LoongArch doesn't have a dedicated "pause" hint like x86.
    // A no-op loop body is the idiomatic equivalent.
    asm volatile ("nop");
}

pub fn disableInterrupts() void {
    // Clear CRMD.IE (bit 2) — disable global interrupts
    _ = csr.xchg(csr.CRMD, 0, csr.CRMD_IE);
}

pub fn enableInterrupts() void {
    // Set CRMD.IE (bit 2) — enable global interrupts
    _ = csr.xchg(csr.CRMD, csr.CRMD_IE, csr.CRMD_IE);
}

pub fn halt() void {
    asm volatile ("idle 0");
}

/// Read the 64-bit stable counter (RDTIME instruction).
/// Returns {counter_value, counter_id}.
pub fn readStableCounter() u64 {
    var val: u64 = undefined;
    var id: u64 = undefined;
    asm volatile ("rdtime.d %[val], %[id]"
        : [val] "=r" (val),
          [id] "=r" (id),
    );
    return val;
}
