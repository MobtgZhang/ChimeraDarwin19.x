/// Mach Clock Service — monotonic time-keeping.
/// Provides nanosecond-resolution timestamps and alarm scheduling.
/// Architecture-specific timing primitives are selected at compile time.

const builtin = @import("builtin");
const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;

pub const NANOS_PER_SEC: u64 = 1_000_000_000;
pub const NANOS_PER_MS: u64 = 1_000_000;
pub const NANOS_PER_US: u64 = 1_000;

// ── PIT (x86_64 only) ────────────────────────────────────

const PIT_FREQ: u32 = 1_193_182;

var pit_ticks: u64 = 0;
var pit_hz: u32 = 0;

pub fn initPIT(hz: u32) void {
    if (builtin.cpu.arch != .x86_64) return;

    pit_hz = hz;
    const divisor: u16 = @intCast(PIT_FREQ / hz);

    portOutImpl(0x43, 0x36);
    portOutImpl(0x40, @truncate(divisor));
    portOutImpl(0x40, @truncate(divisor >> 8));

    log.info("PIT initialized at {} Hz (divisor={})", .{ hz, divisor });
}

pub fn pitIrqHandler() void {
    pit_ticks += 1;
}

pub fn pitUptime() u64 {
    if (pit_hz == 0) return 0;
    return pit_ticks * NANOS_PER_SEC / pit_hz;
}

// ── TSC / generic monotonic counter ──────────────────────

var tsc_freq: u64 = 0;
var tsc_base: u64 = 0;
var generic_counter: u64 = 0;

pub const readTSC = if (builtin.cpu.arch == .x86_64) readTSCx86 else readTSCGeneric;

fn readTSCx86() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return @as(u64, hi) << 32 | lo;
}

fn readTSCGeneric() u64 {
    generic_counter +%= 1;
    return generic_counter;
}

pub fn calibrateTSC() void {
    if (builtin.cpu.arch != .x86_64) return;
    if (pit_hz == 0) {
        log.warn("Cannot calibrate TSC: PIT not initialized", .{});
        return;
    }

    const wait_ticks: u64 = pit_hz / 20;
    const start_pit = pit_ticks;
    const start_tsc = readTSC();

    while (pit_ticks - start_pit < wait_ticks) {
        relaxImpl();
    }

    const elapsed_tsc = readTSC() - start_tsc;
    const elapsed_ns = (pit_ticks - start_pit) * NANOS_PER_SEC / pit_hz;

    if (elapsed_ns > 0) {
        tsc_freq = elapsed_tsc * NANOS_PER_SEC / elapsed_ns;
    }
    tsc_base = readTSC();

    log.info("TSC frequency: {} MHz", .{tsc_freq / 1_000_000});
}

pub fn tscNanos() u64 {
    if (tsc_freq == 0) return pitUptime();
    const delta = readTSC() - tsc_base;
    return delta * NANOS_PER_SEC / tsc_freq;
}

// ── High-level clock API ──────────────────────────────────

pub const TimeSpec = struct {
    seconds: u64,
    nanoseconds: u32,
};

pub fn getTime() TimeSpec {
    const ns = tscNanos();
    return .{
        .seconds = ns / NANOS_PER_SEC,
        .nanoseconds = @intCast(ns % NANOS_PER_SEC),
    };
}

pub fn uptimeNanos() u64 {
    return tscNanos();
}

pub fn uptimeMs() u64 {
    return tscNanos() / NANOS_PER_MS;
}

// ── Alarm queue ───────────────────────────────────────────

pub const MAX_ALARMS: usize = 64;

pub const Alarm = struct {
    deadline_ns: u64,
    callback: ?*const fn () void,
    active: bool,
};

var alarms: [MAX_ALARMS]Alarm = [_]Alarm{.{ .deadline_ns = 0, .callback = null, .active = false }} ** MAX_ALARMS;
var alarm_lock: SpinLock = .{};

pub fn setAlarm(deadline_ns: u64, callback: *const fn () void) bool {
    alarm_lock.acquire();
    defer alarm_lock.release();
    for (&alarms) |*a| {
        if (!a.active) {
            a.* = .{ .deadline_ns = deadline_ns, .callback = callback, .active = true };
            return true;
        }
    }
    return false;
}

pub fn processAlarms() void {
    const now = uptimeNanos();
    alarm_lock.acquire();
    defer alarm_lock.release();
    for (&alarms) |*a| {
        if (a.active and now >= a.deadline_ns) {
            if (a.callback) |cb| cb();
            a.active = false;
        }
    }
}

// ── Architecture-specific helpers (comptime dispatch) ─────

const portOutImpl = if (builtin.cpu.arch == .x86_64) portOutX86 else portOutNoop;
const relaxImpl = if (builtin.cpu.arch == .x86_64) relaxX86 else relaxGeneric;

fn portOutX86(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

fn portOutNoop(_: u16, _: u8) void {}

fn relaxX86() void {
    asm volatile ("pause");
}

fn relaxGeneric() void {
    asm volatile ("");
}
