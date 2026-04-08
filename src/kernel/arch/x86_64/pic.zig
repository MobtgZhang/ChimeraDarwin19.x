/// 8259 PIC (Programmable Interrupt Controller) driver.
/// Remaps hardware IRQs 0-15 to interrupt vectors 32-47 to avoid
/// conflicts with CPU exception vectors 0-31.

const ports = @import("ports.zig");
const log = @import("../../../lib/log.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

pub const IRQ_OFFSET_MASTER: u8 = 32;
pub const IRQ_OFFSET_SLAVE: u8 = 40;

pub fn init() void {
    // ICW1: begin initialization sequence (cascade mode, ICW4 needed)
    ports.outb(PIC1_CMD, 0x11);
    ports.ioWait();
    ports.outb(PIC2_CMD, 0x11);
    ports.ioWait();

    // ICW2: set vector offsets
    ports.outb(PIC1_DATA, IRQ_OFFSET_MASTER);
    ports.ioWait();
    ports.outb(PIC2_DATA, IRQ_OFFSET_SLAVE);
    ports.ioWait();

    // ICW3: cascading — slave on IRQ2
    ports.outb(PIC1_DATA, 0x04);
    ports.ioWait();
    ports.outb(PIC2_DATA, 0x02);
    ports.ioWait();

    // ICW4: 8086 mode
    ports.outb(PIC1_DATA, 0x01);
    ports.ioWait();
    ports.outb(PIC2_DATA, 0x01);
    ports.ioWait();

    // Mask all IRQs initially
    ports.outb(PIC1_DATA, 0xFF);
    ports.outb(PIC2_DATA, 0xFF);

    log.info("[PIC]  8259 PIC remapped (IRQ 0-7 → vec 32-39, IRQ 8-15 → vec 40-47)", .{});
}

pub fn enableIrq(irq: u8) void {
    if (irq < 8) {
        const mask = ports.inb(PIC1_DATA);
        ports.outb(PIC1_DATA, mask & ~(@as(u8, 1) << @intCast(irq)));
    } else if (irq < 16) {
        const mask = ports.inb(PIC2_DATA);
        ports.outb(PIC2_DATA, mask & ~(@as(u8, 1) << @intCast(irq - 8)));
        // Ensure cascade (IRQ2) is unmasked on master
        const m1 = ports.inb(PIC1_DATA);
        ports.outb(PIC1_DATA, m1 & ~@as(u8, 0x04));
    }
}

pub fn disableIrq(irq: u8) void {
    if (irq < 8) {
        const mask = ports.inb(PIC1_DATA);
        ports.outb(PIC1_DATA, mask | (@as(u8, 1) << @intCast(irq)));
    } else if (irq < 16) {
        const mask = ports.inb(PIC2_DATA);
        ports.outb(PIC2_DATA, mask | (@as(u8, 1) << @intCast(irq - 8)));
    }
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        ports.outb(PIC2_CMD, 0x20);
    }
    ports.outb(PIC1_CMD, 0x20);
}

pub fn getMask() u16 {
    return @as(u16, ports.inb(PIC2_DATA)) << 8 | ports.inb(PIC1_DATA);
}

pub fn setMask(mask: u16) void {
    ports.outb(PIC1_DATA, @truncate(mask));
    ports.outb(PIC2_DATA, @truncate(mask >> 8));
}
