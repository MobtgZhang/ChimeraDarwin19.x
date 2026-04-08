/// PIT (Programmable Interval Timer, 8253/8254) driver.
/// Channel 0 is configured as a rate generator for system ticks.
/// The PIT runs at a base frequency of 1,193,182 Hz.

const ports = @import("../../arch/x86_64/ports.zig");
const log = @import("../../../lib/log.zig");
const registry = @import("../registry.zig");

const PIT_CH0_DATA: u16 = 0x40;
const PIT_CH2_DATA: u16 = 0x42;
const PIT_CMD: u16 = 0x43;

const PIT_BASE_FREQ: u32 = 1_193_182;
const TARGET_HZ: u32 = 1000;
const DIVISOR: u16 = @intCast(PIT_BASE_FREQ / TARGET_HZ);

var tick_count: u64 = 0;
var initialized: bool = false;

pub fn init() void {
    // Channel 0, access mode lo/hi, mode 2 (rate generator)
    ports.outb(PIT_CMD, 0x34);
    ports.outb(PIT_CH0_DATA, @truncate(DIVISOR));
    ports.outb(PIT_CH0_DATA, @truncate(DIVISOR >> 8));

    initialized = true;

    if (registry.allocNode("IOTimerDevice", "PIT8254")) |node| {
        _ = node.setProperty("IOProviderClass", "IOPlatformDevice");
        _ = node.setPropertyInt("frequency", TARGET_HZ);
        if (registry.getRoot()) |root| root.addChild(node);
    }

    log.info("[PIT]  Timer configured: {} Hz (divisor {})", .{ TARGET_HZ, DIVISOR });
}

/// Called from the timer IRQ handler or polled from the main loop.
pub fn tick() void {
    tick_count +%= 1;
}

pub fn getTicks() u64 {
    return tick_count;
}

pub fn getMillis() u64 {
    return tick_count;
}

/// Busy-wait for approximately `ms` milliseconds using the PIT counter.
pub fn sleep(ms: u32) void {
    const start = tick_count;
    while (tick_count - start < ms) {
        ports.pause();
    }
}

/// Read current PIT channel 0 count (latched read).
pub fn readCounter() u16 {
    ports.outb(PIT_CMD, 0x00); // latch channel 0
    const lo = ports.inb(PIT_CH0_DATA);
    const hi = ports.inb(PIT_CH0_DATA);
    return @as(u16, hi) << 8 | lo;
}

/// Use PIT channel 2 for a one-shot delay (more reliable for calibration).
pub fn calibrateDelay() void {
    // Enable PIT channel 2 gate
    const gate = ports.inb(0x61);
    ports.outb(0x61, (gate & 0xFD) | 0x01);

    // Channel 2, mode 0 (interrupt on terminal count), lo/hi
    ports.outb(PIT_CMD, 0xB0);
    ports.outb(PIT_CH2_DATA, 0xFF);
    ports.outb(PIT_CH2_DATA, 0xFF);

    // Wait for output to go high
    while (ports.inb(0x61) & 0x20 == 0) {
        ports.pause();
    }
}
