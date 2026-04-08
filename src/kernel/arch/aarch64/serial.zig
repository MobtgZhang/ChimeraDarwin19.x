/// PL011 UART driver for AArch64.
/// On QEMU virt machine the PL011 is at 0x0900_0000.

const UART_BASE: u64 = 0x0900_0000;

const DR: *volatile u32 = @ptrFromInt(UART_BASE + 0x000);
const FR: *volatile u32 = @ptrFromInt(UART_BASE + 0x018);
const IBRD: *volatile u32 = @ptrFromInt(UART_BASE + 0x024);
const FBRD: *volatile u32 = @ptrFromInt(UART_BASE + 0x028);
const LCR_H: *volatile u32 = @ptrFromInt(UART_BASE + 0x02C);
const CR: *volatile u32 = @ptrFromInt(UART_BASE + 0x030);
const IMSC: *volatile u32 = @ptrFromInt(UART_BASE + 0x038);
const ICR: *volatile u32 = @ptrFromInt(UART_BASE + 0x044);

pub fn init() void {
    CR.* = 0;

    ICR.* = 0x7FF;

    // 115200 baud with 24 MHz clock: IBRD = 13, FBRD = 1
    IBRD.* = 13;
    FBRD.* = 1;

    // 8 bits, FIFO enabled
    LCR_H.* = (0b11 << 5) | (1 << 4);

    // Mask all interrupts
    IMSC.* = 0;

    // Enable UART, TX, RX
    CR.* = (1 << 0) | (1 << 8) | (1 << 9);
}

pub fn writeByte(byte: u8) void {
    while (FR.* & (1 << 5) != 0) {
        asm volatile ("yield");
    }
    DR.* = byte;
}

pub fn writeString(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

pub fn readByte() u8 {
    while (FR.* & (1 << 4) != 0) {
        asm volatile ("yield");
    }
    return @truncate(DR.*);
}
