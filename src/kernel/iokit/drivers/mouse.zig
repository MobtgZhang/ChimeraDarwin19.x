/// PS/2 Mouse driver.
/// Initializes the auxiliary PS/2 port and reads 3-byte movement packets.
/// Provides absolute cursor position tracking with screen bounds clamping.

const ports = @import("../../arch/x86_64/ports.zig");
const log = @import("../../../lib/log.zig");
const registry = @import("../registry.zig");

const PS2_DATA: u16 = 0x60;
const PS2_STATUS: u16 = 0x64;
const PS2_COMMAND: u16 = 0x64;

pub const MouseEvent = struct {
    x: i32,
    y: i32,
    dx: i16,
    dy: i16,
    left: bool,
    right: bool,
    middle: bool,
};

var cursor_x: i32 = 400;
var cursor_y: i32 = 300;
var screen_w: i32 = 800;
var screen_h: i32 = 600;

/// 鼠标灵敏度乘数，值越大移动越快，1.0为原速度
const MOUSE_SENSITIVITY: f32 = 5.0;

var packet_idx: u8 = 0;
var packet: [3]u8 = [_]u8{0} ** 3;
var last_buttons: u8 = 0;

pub fn init() void {
    initWithBounds(800, 600);
}

pub fn initWithBounds(w: u32, h: u32) void {
    screen_w = @intCast(w);
    screen_h = @intCast(h);
    cursor_x = @divTrunc(screen_w, 2);
    cursor_y = @divTrunc(screen_h, 2);

    // Enable auxiliary PS/2 device
    sendCommand(0xA8);

    // Read controller config
    sendCommand(0x20);
    waitOutput();
    var config = ports.inb(PS2_DATA);
    config |= 0x02; // enable IRQ12
    config &= ~@as(u8, 0x20); // enable mouse clock
    sendCommand(0x60);
    waitInput();
    ports.outb(PS2_DATA, config);

    // Set defaults
    sendMouseCommand(0xF6);
    readAck();

    // Enable data reporting
    sendMouseCommand(0xF4);
    readAck();

    if (registry.allocNode("IOHIDPointing", "PS2Mouse")) |node| {
        _ = node.setProperty("IOProviderClass", "IOHIDSystem");
        _ = node.setProperty("Transport", "PS/2");
        _ = node.setPropertyInt("Resolution", 10);
        if (registry.getRoot()) |root| root.addChild(node);
    }

    log.info("[MOUSE] PS/2 mouse initialized ({}x{} bounds)", .{ w, h });
}

/// Poll for mouse data. Returns a complete mouse event when a 3-byte
/// packet is assembled, or null if no data or packet incomplete.
pub fn poll() ?MouseEvent {
    const status = ports.inb(PS2_STATUS);
    if (status & 0x01 == 0) return null;
    if (status & 0x20 == 0) return null; // keyboard data

    const byte = ports.inb(PS2_DATA);

    // First byte must have bit 3 set (always-1 identification bit)
    if (packet_idx == 0 and byte & 0x08 == 0) return null;

    packet[packet_idx] = byte;
    packet_idx += 1;

    if (packet_idx < 3) return null;
    packet_idx = 0;

    // Decode packet
    const flags = packet[0];
    var dx: i16 = @intCast(packet[1]);
    var dy: i16 = @intCast(packet[2]);

    // Apply sign extension from flags
    if (flags & 0x10 != 0) dx -= 256;
    if (flags & 0x20 != 0) dy -= 256;

    // Discard overflow packets
    if (flags & 0xC0 != 0) return null;

    // Apply sensitivity multiplier to movement delta
    const move_x = @as(f32, @floatFromInt(dx)) * MOUSE_SENSITIVITY;
    const move_y = @as(f32, @floatFromInt(dy)) * MOUSE_SENSITIVITY;

    // Update absolute position (Y is inverted in PS/2)
    cursor_x += @intFromFloat(move_x);
    cursor_y -= @intFromFloat(move_y);

    // Clamp to screen bounds
    if (cursor_x < 0) cursor_x = 0;
    if (cursor_y < 0) cursor_y = 0;
    if (cursor_x >= screen_w) cursor_x = screen_w - 1;
    if (cursor_y >= screen_h) cursor_y = screen_h - 1;

    last_buttons = flags & 0x07;

    return MouseEvent{
        .x = cursor_x,
        .y = cursor_y,
        .dx = dx,
        .dy = dy,
        .left = flags & 0x01 != 0,
        .right = flags & 0x02 != 0,
        .middle = flags & 0x04 != 0,
    };
}

pub fn getPosition() struct { x: i32, y: i32 } {
    return .{ .x = cursor_x, .y = cursor_y };
}

pub fn isLeftPressed() bool {
    return last_buttons & 0x01 != 0;
}

fn sendCommand(cmd: u8) void {
    waitInput();
    ports.outb(PS2_COMMAND, cmd);
}

fn sendMouseCommand(cmd: u8) void {
    sendCommand(0xD4); // prefix: write to auxiliary device
    waitInput();
    ports.outb(PS2_DATA, cmd);
}

fn readAck() void {
    waitOutput();
    _ = ports.inb(PS2_DATA);
}

fn waitInput() void {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if (ports.inb(PS2_STATUS) & 0x02 == 0) return;
    }
}

fn waitOutput() void {
    var timeout: u32 = 100_000;
    while (timeout > 0) : (timeout -= 1) {
        if (ports.inb(PS2_STATUS) & 0x01 != 0) return;
    }
}
