const COM1: u16 = 0x3F8;

pub fn init() void {
    outb(COM1 + 1, 0x00); // Disable all interrupts
    outb(COM1 + 3, 0x80); // Enable DLAB (set baud rate divisor)
    outb(COM1 + 0, 0x03); // Set divisor to 3 (lo byte) → 38400 baud
    outb(COM1 + 1, 0x00); //                  (hi byte)
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0xC7); // Enable FIFO, clear them, 14-byte threshold
    outb(COM1 + 4, 0x0B); // IRQs enabled, RTS/DSR set
    outb(COM1 + 4, 0x1E); // Set in loopback mode, test the serial chip
    outb(COM1 + 0, 0xAE); // Send test byte

    if (inb(COM1 + 0) != 0xAE) {
        return; // Serial port is faulty
    }

    // Not loopback, normal operation
    outb(COM1 + 4, 0x0F);
}

pub fn writeByte(byte: u8) void {
    // Wait for transmit buffer to be empty
    while (inb(COM1 + 5) & 0x20 == 0) {
        asm volatile ("pause");
    }
    outb(COM1, byte);
}

pub fn writeString(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') writeByte('\r');
        writeByte(c);
    }
}

pub fn readByte() u8 {
    while (inb(COM1 + 5) & 0x01 == 0) {
        asm volatile ("pause");
    }
    return inb(COM1);
}

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}
