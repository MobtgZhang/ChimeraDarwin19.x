/// x86_64 Hardware Abstraction Layer — wraps GDT, IDT, PIC, PIT, RTC,
/// PS/2 keyboard/mouse, serial, and port I/O behind the portable HAL interface.

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const serial = @import("serial.zig");
const pic = @import("pic.zig");
const ports = @import("ports.zig");
const pit = @import("../../iokit/drivers/pit.zig");
const rtc = @import("../../iokit/drivers/rtc.zig");
const keyboard = @import("../../iokit/drivers/keyboard.zig");
const mouse = @import("../../iokit/drivers/mouse.zig");
const log = @import("../../../lib/log.zig");
const BootInfo = @import("../../../kernel/main.zig").BootInfo;

pub const name = "x86_64 (AMD64/Intel 64)";

pub fn earlyInit() void {
    serial.init();
}

pub fn cpuInit() void {
    gdt.init();
    log.info("[CPU]  GDT loaded (null + kernel CS/DS + user CS/DS)", .{});

    idt.init();
    log.info("[CPU]  IDT loaded (256 vectors)", .{});

    pic.init();
}

pub fn timerInit() void {
    pit.init();
    rtc.init();
}

pub fn timerTick() void {
    pit.tick();
}

pub fn inputInit(boot_info: *const BootInfo) void {
    keyboard.init();
    if (boot_info.framebuffer) |fb| {
        mouse.initWithBounds(fb.width, fb.height);
    } else {
        mouse.init();
    }
}

pub const TimeInfo = struct {
    hour: u8,
    minute: u8,
};

pub fn readTime() TimeInfo {
    const t = rtc.readTime();
    return .{ .hour = t.hour, .minute = t.minute };
}

pub fn cpuRelax() void {
    ports.pause();
}

pub fn disableInterrupts() void {
    ports.cli();
}

pub fn enableInterrupts() void {
    ports.sti();
}

pub fn halt() void {
    ports.hlt();
}
