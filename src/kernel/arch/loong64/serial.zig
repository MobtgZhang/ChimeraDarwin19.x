/// LoongArch64 16550-compatible UART driver.
///
/// UART base addresses for supported platforms:
///   QEMU loongarch64 virt : 0x1FE0_01E0
///   Loongson 2K3000       : 0x1FE0_01E0 (SoC integrated UART0)
///   Loongson 3A5000+7A    : 0x1FE0_01E0 (via 7A1000/7A2000 bridge)
///   Loongson 3A6000+7A    : 0x1FE0_01E0 (via 7A2000 bridge)
///
/// All current LoongArch platforms use the same legacy UART base.
/// If a future platform differs, add detection logic here.

const UART_BASE: u64 = 0x1FE0_01E0;

const THR: *volatile u8 = @ptrFromInt(UART_BASE + 0); // Transmit Holding
const RBR: *volatile u8 = @ptrFromInt(UART_BASE + 0); // Receive Buffer
const IER: *volatile u8 = @ptrFromInt(UART_BASE + 1); // Interrupt Enable
const FCR: *volatile u8 = @ptrFromInt(UART_BASE + 2); // FIFO Control
const LCR: *volatile u8 = @ptrFromInt(UART_BASE + 3); // Line Control
const MCR: *volatile u8 = @ptrFromInt(UART_BASE + 4); // Modem Control
const LSR: *volatile u8 = @ptrFromInt(UART_BASE + 5); // Line Status
const DLL: *volatile u8 = @ptrFromInt(UART_BASE + 0); // Divisor Latch Low
const DLM: *volatile u8 = @ptrFromInt(UART_BASE + 1); // Divisor Latch High

// LSR bit masks
const LSR_DR: u8 = 0x01; // Data Ready
const LSR_THRE: u8 = 0x20; // Transmit Holding Register Empty

pub fn init() void {
    // Disable all interrupts during setup
    IER.* = 0x00;

    // Enter divisor-latch access mode
    LCR.* = 0x80;

    // Set baud rate divisor.
    // On LoongArch platforms the UART reference clock is typically 1.8432 MHz
    // or the firmware has already configured the baud rate.
    // Divisor = 1 → maximum speed, works on QEMU and most real hardware
    // where firmware pre-configures the UART.
    DLL.* = 0x01;
    DLM.* = 0x00;

    // 8 data bits, 1 stop bit, no parity
    LCR.* = 0x03;

    // Enable and clear FIFOs, 14-byte trigger level
    FCR.* = 0xC7;

    // DTR + RTS + OUT2 (OUT2 enables interrupts on 16550)
    MCR.* = 0x0B;

    // Enable receive-data-available interrupt (optional, useful later
    // when we implement interrupt-driven input)
    IER.* = 0x01;
}

pub fn writeByte(byte: u8) void {
    // Spin until the transmit holding register is empty
    while (LSR.* & LSR_THRE == 0) {
        asm volatile ("nop");
    }
    THR.* = byte;
}

pub fn writeString(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

pub fn readByte() u8 {
    while (LSR.* & LSR_DR == 0) {
        asm volatile ("nop");
    }
    return RBR.*;
}

/// Non-blocking byte read; returns null if no data available.
pub fn tryReadByte() ?u8 {
    if (LSR.* & LSR_DR != 0) {
        return RBR.*;
    }
    return null;
}
