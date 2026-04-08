/// CMOS Real-Time Clock driver.
/// Reads date and time from the MC146818-compatible RTC via I/O ports 0x70/0x71.

const ports = @import("../../arch/x86_64/ports.zig");
const log = @import("../../../lib/log.zig");
const registry = @import("../registry.zig");

const CMOS_ADDR: u16 = 0x70;
const CMOS_DATA: u16 = 0x71;

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8,
};

pub fn init() void {
    if (registry.allocNode("IORealtimeClock", "CMOSRTC")) |node| {
        _ = node.setProperty("IOProviderClass", "IOPlatformDevice");
        _ = node.setProperty("compatible", "mc146818");
        if (registry.getRoot()) |root| root.addChild(node);
    }
    log.info("[RTC]  CMOS real-time clock initialized", .{});
}

pub fn readTime() DateTime {
    // Wait until update-in-progress flag clears
    while (readRegister(0x0A) & 0x80 != 0) {}

    var dt = DateTime{
        .second = readRegister(0x00),
        .minute = readRegister(0x02),
        .hour = readRegister(0x04),
        .weekday = readRegister(0x06),
        .day = readRegister(0x07),
        .month = readRegister(0x08),
        .year = readRegister(0x09),
    };

    const reg_b = readRegister(0x0B);

    // Convert BCD to binary if needed
    if (reg_b & 0x04 == 0) {
        dt.second = bcdToBin(dt.second);
        dt.minute = bcdToBin(dt.minute);
        dt.hour = bcdToBin(dt.hour & 0x7F) | (dt.hour & 0x80);
        dt.day = bcdToBin(dt.day);
        dt.month = bcdToBin(dt.month);
        dt.year = bcdToBin(@truncate(dt.year));
    }

    // Convert 12-hour to 24-hour
    if (reg_b & 0x02 == 0 and dt.hour & 0x80 != 0) {
        dt.hour = ((dt.hour & 0x7F) % 12) + 12;
    }

    // CMOS stores 2-digit year; assume 2000s
    dt.year += 2000;

    return dt;
}

fn readRegister(reg: u8) u8 {
    // Preserve NMI disable bit (bit 7)
    ports.outb(CMOS_ADDR, reg);
    return ports.inb(CMOS_DATA);
}

fn bcdToBin(bcd: u8) u8 {
    return (bcd >> 4) * 10 + (bcd & 0x0F);
}
