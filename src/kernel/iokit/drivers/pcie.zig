/// PCIe Bus Scanner — enumerates devices on the PCI Express bus
/// using ECAM (Enhanced Configuration Access Mechanism).
/// Detected devices are registered as IORegistry nodes.

const log = @import("../../../lib/log.zig");
const registry = @import("../registry.zig");
const service = @import("../service.zig");

pub const MAX_BUS: u8 = 255;
pub const MAX_DEVICE: u8 = 31;
pub const MAX_FUNCTION: u8 = 7;

pub const PciAddress = struct {
    bus: u8,
    device: u5,
    function: u3,
};

pub const PciDeviceInfo = struct {
    addr: PciAddress,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    revision: u8,
    header_type: u8,
    bar: [6]u64,
};

pub const MAX_PCI_DEVICES: usize = 128;
var detected: [MAX_PCI_DEVICES]PciDeviceInfo = undefined;
var detected_count: usize = 0;

// ── PCI Configuration Space I/O (legacy port-based) ───────

const PCI_CONFIG_ADDR: u16 = 0xCF8;
const PCI_CONFIG_DATA: u16 = 0xCFC;

fn pciConfigAddr(bus: u8, dev: u5, func: u3, offset: u8) u32 {
    return @as(u32, 1) << 31 | // enable
        @as(u32, bus) << 16 |
        @as(u32, dev) << 11 |
        @as(u32, func) << 8 |
        (@as(u32, offset) & 0xFC);
}

fn pciRead32(bus: u8, dev: u5, func: u3, offset: u8) u32 {
    outl(PCI_CONFIG_ADDR, pciConfigAddr(bus, dev, func, offset));
    return inl(PCI_CONFIG_DATA);
}

fn pciRead16(bus: u8, dev: u5, func: u3, offset: u8) u16 {
    const val = pciRead32(bus, dev, func, offset & 0xFC);
    return @truncate(val >> @as(u5, @intCast((offset & 2) * 8)));
}

fn pciRead8(bus: u8, dev: u5, func: u3, offset: u8) u8 {
    const val = pciRead32(bus, dev, func, offset & 0xFC);
    return @truncate(val >> @as(u5, @intCast((offset & 3) * 8)));
}

// ── Bus scan ──────────────────────────────────────────────

pub fn init() void {
    detected_count = 0;
    log.info("PCIe bus scan starting...", .{});

    for (0..@as(usize, MAX_BUS) + 1) |bus_i| {
        const bus: u8 = @intCast(bus_i);
        for (0..@as(usize, MAX_DEVICE) + 1) |dev_i| {
            const dev: u5 = @intCast(dev_i);
            scanDevice(bus, dev);
        }
    }

    log.info("PCIe scan complete: {} devices found", .{detected_count});
}

fn scanDevice(bus: u8, dev: u5) void {
    const vendor = pciRead16(bus, dev, 0, 0x00);
    if (vendor == 0xFFFF) return;

    scanFunction(bus, dev, 0);

    // Multi-function?
    const header_type = pciRead8(bus, dev, 0, 0x0E);
    if (header_type & 0x80 != 0) {
        for (1..8) |f| {
            const func: u3 = @intCast(f);
            if (pciRead16(bus, dev, func, 0x00) != 0xFFFF)
                scanFunction(bus, dev, func);
        }
    }
}

fn scanFunction(bus: u8, dev: u5, func: u3) void {
    if (detected_count >= MAX_PCI_DEVICES) return;

    const vendor_id = pciRead16(bus, dev, func, 0x00);
    const device_id = pciRead16(bus, dev, func, 0x02);
    const class_reg = pciRead32(bus, dev, func, 0x08);
    const class_code: u8 = @truncate(class_reg >> 24);
    const subclass: u8 = @truncate(class_reg >> 16);
    const prog_if: u8 = @truncate(class_reg >> 8);
    const revision: u8 = @truncate(class_reg);
    const header_type = pciRead8(bus, dev, func, 0x0E) & 0x7F;

    var info = PciDeviceInfo{
        .addr = .{ .bus = bus, .device = dev, .function = func },
        .vendor_id = vendor_id,
        .device_id = device_id,
        .class_code = class_code,
        .subclass = subclass,
        .prog_if = prog_if,
        .revision = revision,
        .header_type = header_type,
        .bar = [_]u64{0} ** 6,
    };

    // Read BARs (type 0 header only)
    if (header_type == 0) {
        for (0..6) |bar_idx| {
            const offset: u8 = @intCast(0x10 + bar_idx * 4);
            info.bar[bar_idx] = pciRead32(bus, dev, func, offset);
        }
    }

    detected[detected_count] = info;
    detected_count += 1;

    // Register in IORegistry
    registerPciNode(&info);

    log.debug("  PCI {}.{}.{}: vendor=0x{x:0>4} device=0x{x:0>4} class={x:0>2}:{x:0>2}", .{
        bus, @as(u8, dev), @as(u8, func), vendor_id, device_id, class_code, subclass,
    });
}

fn registerPciNode(info: *const PciDeviceInfo) void {
    const class_name = classToString(info.class_code);
    const node = registry.allocNode("IOPCIDevice", class_name) orelse return;
    _ = node.setPropertyInt("vendor-id", info.vendor_id);
    _ = node.setPropertyInt("device-id", info.device_id);
    _ = node.setPropertyInt("class-code", info.class_code);
    _ = node.setPropertyInt("subsystem", info.subclass);
    _ = node.setPropertyInt("bus", info.addr.bus);
    _ = node.setPropertyInt("device", @as(u64, info.addr.device));
    _ = node.setPropertyInt("function", @as(u64, info.addr.function));

    if (registry.getRoot()) |root| {
        root.addChild(node);
    }
}

fn classToString(class: u8) []const u8 {
    return switch (class) {
        0x00 => "Unclassified",
        0x01 => "MassStorage",
        0x02 => "Network",
        0x03 => "Display",
        0x04 => "Multimedia",
        0x05 => "Memory",
        0x06 => "Bridge",
        0x07 => "Communication",
        0x08 => "SystemPeripheral",
        0x09 => "Input",
        0x0C => "SerialBus",
        0x0D => "Wireless",
        else => "Unknown",
    };
}

pub fn getDevices() []const PciDeviceInfo {
    return detected[0..detected_count];
}

pub fn findDevice(vendor: u16, device: u16) ?*const PciDeviceInfo {
    for (detected[0..detected_count]) |*d| {
        if (d.vendor_id == vendor and d.device_id == device) return d;
    }
    return null;
}

// ── Port I/O ──────────────────────────────────────────────

fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}
