/// ATA/IDE PIO-mode disk driver.
/// Supports device identification and 28-bit LBA sector read/write
/// on the primary ATA bus (ports 0x1F0-0x1F7, control 0x3F6).

const ports = @import("../../arch/x86_64/ports.zig");
const log = @import("../../../lib/log.zig");
const registry = @import("../registry.zig");

const ATA_PRIMARY_DATA: u16 = 0x1F0;
const ATA_PRIMARY_ERR: u16 = 0x1F1;
const ATA_PRIMARY_SECT_CNT: u16 = 0x1F2;
const ATA_PRIMARY_LBA_LO: u16 = 0x1F3;
const ATA_PRIMARY_LBA_MID: u16 = 0x1F4;
const ATA_PRIMARY_LBA_HI: u16 = 0x1F5;
const ATA_PRIMARY_DRIVE: u16 = 0x1F6;
const ATA_PRIMARY_STATUS: u16 = 0x1F7;
const ATA_PRIMARY_CMD: u16 = 0x1F7;
const ATA_PRIMARY_CTRL: u16 = 0x3F6;

const ATA_STATUS_BSY: u8 = 0x80;
const ATA_STATUS_DRDY: u8 = 0x40;
const ATA_STATUS_DRQ: u8 = 0x08;
const ATA_STATUS_ERR: u8 = 0x01;

const ATA_CMD_IDENTIFY: u8 = 0xEC;
const ATA_CMD_READ_SECTORS: u8 = 0x20;
const ATA_CMD_WRITE_SECTORS: u8 = 0x30;

pub const AtaDriveInfo = struct {
    present: bool,
    model: [40]u8,
    model_len: usize,
    serial: [20]u8,
    serial_len: usize,
    sectors: u64,
    lba48: bool,
};

var drive0: AtaDriveInfo = .{
    .present = false,
    .model = [_]u8{0} ** 40,
    .model_len = 0,
    .serial = [_]u8{0} ** 20,
    .serial_len = 0,
    .sectors = 0,
    .lba48 = false,
};

pub fn init() void {
    // Software reset
    ports.outb(ATA_PRIMARY_CTRL, 0x04);
    ports.ioWait();
    ports.ioWait();
    ports.outb(ATA_PRIMARY_CTRL, 0x00);
    ports.ioWait();

    // Try to identify master drive (drive 0)
    identify(0);

    if (drive0.present) {
        if (registry.allocNode("IOATABlockStorage", "ATA-Primary")) |node| {
            _ = node.setProperty("IOProviderClass", "IOBlockStorageDevice");
            _ = node.setProperty("device-type", "ATA");
            _ = node.setPropertyInt("sectors", drive0.sectors);
            if (registry.getRoot()) |root| root.addChild(node);
        }
        log.info("[ATA]  Drive 0: {s} ({} sectors, {} MB)", .{
            drive0.model[0..drive0.model_len],
            drive0.sectors,
            drive0.sectors / 2048,
        });
    } else {
        log.info("[ATA]  No drives detected on primary bus", .{});
    }
}

fn identify(drive: u8) void {
    ports.outb(ATA_PRIMARY_DRIVE, 0xA0 | (@as(u8, drive) << 4));
    ports.ioWait();

    ports.outb(ATA_PRIMARY_SECT_CNT, 0);
    ports.outb(ATA_PRIMARY_LBA_LO, 0);
    ports.outb(ATA_PRIMARY_LBA_MID, 0);
    ports.outb(ATA_PRIMARY_LBA_HI, 0);
    ports.outb(ATA_PRIMARY_CMD, ATA_CMD_IDENTIFY);
    ports.ioWait();

    var status = ports.inb(ATA_PRIMARY_STATUS);
    if (status == 0) return; // no drive

    // Wait for BSY to clear
    var timeout: u32 = 100_000;
    while (status & ATA_STATUS_BSY != 0 and timeout > 0) : (timeout -= 1) {
        status = ports.inb(ATA_PRIMARY_STATUS);
    }
    if (timeout == 0) return;

    // Check for ATAPI (not supported)
    if (ports.inb(ATA_PRIMARY_LBA_MID) != 0 or ports.inb(ATA_PRIMARY_LBA_HI) != 0)
        return;

    // Wait for DRQ
    timeout = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        status = ports.inb(ATA_PRIMARY_STATUS);
        if (status & ATA_STATUS_ERR != 0) return;
        if (status & ATA_STATUS_DRQ != 0) break;
    }
    if (timeout == 0) return;

    // Read 256 words (512 bytes) of identify data
    var data: [256]u16 = undefined;
    for (&data) |*word| {
        word.* = ports.inw(ATA_PRIMARY_DATA);
    }

    drive0.present = true;

    // Model string (words 27-46, byte-swapped)
    drive0.model_len = extractString(&drive0.model, data[27..47]);

    // Serial (words 10-19)
    drive0.serial_len = extractString(&drive0.serial, data[10..20]);

    // LBA28 sector count (words 60-61)
    drive0.sectors = @as(u64, data[61]) << 16 | data[60];

    // LBA48 support (word 83, bit 10)
    if (data[83] & (1 << 10) != 0) {
        drive0.lba48 = true;
        drive0.sectors = @as(u64, data[103]) << 48 |
            @as(u64, data[102]) << 32 |
            @as(u64, data[101]) << 16 |
            data[100];
    }
}

fn extractString(dest: []u8, words: []const u16) usize {
    var i: usize = 0;
    for (words) |w| {
        if (i + 1 < dest.len) {
            dest[i] = @truncate(w >> 8);
            dest[i + 1] = @truncate(w);
            i += 2;
        }
    }
    // Trim trailing spaces
    while (i > 0 and (dest[i - 1] == ' ' or dest[i - 1] == 0)) : (i -= 1) {}
    return i;
}

pub fn readSectors(lba: u32, count: u8, buffer: []u16) bool {
    if (!drive0.present) return false;

    waitReady();

    ports.outb(ATA_PRIMARY_DRIVE, 0xE0 | @as(u8, @truncate(lba >> 24)) & 0x0F);
    ports.outb(ATA_PRIMARY_SECT_CNT, count);
    ports.outb(ATA_PRIMARY_LBA_LO, @truncate(lba));
    ports.outb(ATA_PRIMARY_LBA_MID, @truncate(lba >> 8));
    ports.outb(ATA_PRIMARY_LBA_HI, @truncate(lba >> 16));
    ports.outb(ATA_PRIMARY_CMD, ATA_CMD_READ_SECTORS);

    var offset: usize = 0;
    for (0..count) |_| {
        if (!waitDrq()) return false;
        for (0..256) |_| {
            if (offset < buffer.len) {
                buffer[offset] = ports.inw(ATA_PRIMARY_DATA);
                offset += 1;
            }
        }
    }
    return true;
}

pub fn writeSectors(lba: u32, count: u8, data: []const u16) bool {
    if (!drive0.present) return false;

    waitReady();

    ports.outb(ATA_PRIMARY_DRIVE, 0xE0 | @as(u8, @truncate(lba >> 24)) & 0x0F);
    ports.outb(ATA_PRIMARY_SECT_CNT, count);
    ports.outb(ATA_PRIMARY_LBA_LO, @truncate(lba));
    ports.outb(ATA_PRIMARY_LBA_MID, @truncate(lba >> 8));
    ports.outb(ATA_PRIMARY_LBA_HI, @truncate(lba >> 16));
    ports.outb(ATA_PRIMARY_CMD, ATA_CMD_WRITE_SECTORS);

    var offset: usize = 0;
    for (0..count) |_| {
        if (!waitDrq()) return false;
        for (0..256) |_| {
            if (offset < data.len) {
                ports.outw(ATA_PRIMARY_DATA, data[offset]);
                offset += 1;
            } else {
                ports.outw(ATA_PRIMARY_DATA, 0);
            }
        }
    }
    return true;
}

pub fn getDriveInfo() ?AtaDriveInfo {
    if (drive0.present) return drive0;
    return null;
}

fn waitReady() void {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        const s = ports.inb(ATA_PRIMARY_STATUS);
        if (s & ATA_STATUS_BSY == 0 and s & ATA_STATUS_DRDY != 0) return;
    }
}

fn waitDrq() bool {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        const s = ports.inb(ATA_PRIMARY_STATUS);
        if (s & ATA_STATUS_ERR != 0) return false;
        if (s & ATA_STATUS_DRQ != 0) return true;
    }
    return false;
}
