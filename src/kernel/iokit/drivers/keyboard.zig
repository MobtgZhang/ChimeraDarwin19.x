/// PS/2 Keyboard driver.
/// Initializes the PS/2 controller, polls for scancodes, and translates
/// Set 1 scancodes to ASCII characters.

const ports = @import("../../arch/x86_64/ports.zig");
const log = @import("../../../lib/log.zig");
const registry = @import("../registry.zig");

const PS2_DATA: u16 = 0x60;
const PS2_STATUS: u16 = 0x64;
const PS2_COMMAND: u16 = 0x64;

pub const KeyEvent = struct {
    scancode: u8,
    ascii: u8,
    pressed: bool,
    shift: bool,
    ctrl: bool,
    alt: bool,
};

const BUFFER_SIZE = 64;
var event_buffer: [BUFFER_SIZE]KeyEvent = undefined;
var buf_write: usize = 0;
var buf_read: usize = 0;

var shift_held: bool = false;
var ctrl_held: bool = false;
var alt_held: bool = false;
var caps_lock: bool = false;

pub fn init() void {
    // Disable devices during setup
    sendCommand(0xAD);
    sendCommand(0xA7);

    // Flush the output buffer
    _ = ports.inb(PS2_DATA);

    // Read config, enable IRQ1, enable keyboard clock
    sendCommand(0x20);
    waitOutput();
    var config = ports.inb(PS2_DATA);
    config |= 0x01;
    config &= ~@as(u8, 0x10);
    sendCommand(0x60);
    waitInput();
    ports.outb(PS2_DATA, config);

    // Controller self-test
    sendCommand(0xAA);
    waitOutput();
    const test_res = ports.inb(PS2_DATA);
    if (test_res != 0x55) {
        log.warn("[KBD]  PS/2 self-test failed: 0x{x}", .{test_res});
    }

    // Enable keyboard port
    sendCommand(0xAE);

    // Reset keyboard
    waitInput();
    ports.outb(PS2_DATA, 0xFF);
    waitOutput();
    _ = ports.inb(PS2_DATA);

    if (registry.allocNode("IOHIDKeyboard", "PS2Keyboard")) |node| {
        _ = node.setProperty("IOProviderClass", "IOHIDSystem");
        _ = node.setProperty("Transport", "PS/2");
        if (registry.getRoot()) |root| root.addChild(node);
    }

    log.info("[KBD]  PS/2 keyboard initialized", .{});
}

/// Poll the PS/2 controller. Returns a key event if one is available.
pub fn poll() ?KeyEvent {
    const status = ports.inb(PS2_STATUS);
    if (status & 0x01 == 0) return null;
    if (status & 0x20 != 0) return null; // mouse data

    const scancode = ports.inb(PS2_DATA);
    return processScancode(scancode);
}

/// Read a buffered event (if poll() was used to fill the buffer).
pub fn readEvent() ?KeyEvent {
    if (buf_read == buf_write) return null;
    const ev = event_buffer[buf_read % BUFFER_SIZE];
    buf_read += 1;
    return ev;
}

fn processScancode(scancode: u8) ?KeyEvent {
    const pressed = (scancode & 0x80) == 0;
    const code = scancode & 0x7F;

    // Update modifier state
    switch (code) {
        0x2A, 0x36 => {
            shift_held = pressed;
            return null;
        },
        0x1D => {
            ctrl_held = pressed;
            return null;
        },
        0x38 => {
            alt_held = pressed;
            return null;
        },
        0x3A => {
            if (pressed) caps_lock = !caps_lock;
            return null;
        },
        else => {},
    }

    var ascii: u8 = 0;
    if (code < 128) {
        if (shift_held or caps_lock) {
            ascii = scancode_shift[code];
        } else {
            ascii = scancode_normal[code];
        }
    }

    return KeyEvent{
        .scancode = scancode,
        .ascii = ascii,
        .pressed = pressed,
        .shift = shift_held,
        .ctrl = ctrl_held,
        .alt = alt_held,
    };
}

fn sendCommand(cmd: u8) void {
    waitInput();
    ports.outb(PS2_COMMAND, cmd);
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

pub fn isShiftHeld() bool {
    return shift_held;
}
pub fn isCtrlHeld() bool {
    return ctrl_held;
}
pub fn isAltHeld() bool {
    return alt_held;
}

// US QWERTY Set 1 scancode → ASCII (normal)
const scancode_normal = blk: {
    var t = [_]u8{0} ** 128;
    t[0x01] = 0x1B; // Escape
    t[0x02] = '1';
    t[0x03] = '2';
    t[0x04] = '3';
    t[0x05] = '4';
    t[0x06] = '5';
    t[0x07] = '6';
    t[0x08] = '7';
    t[0x09] = '8';
    t[0x0A] = '9';
    t[0x0B] = '0';
    t[0x0C] = '-';
    t[0x0D] = '=';
    t[0x0E] = 0x08; // Backspace
    t[0x0F] = '\t';
    t[0x10] = 'q';
    t[0x11] = 'w';
    t[0x12] = 'e';
    t[0x13] = 'r';
    t[0x14] = 't';
    t[0x15] = 'y';
    t[0x16] = 'u';
    t[0x17] = 'i';
    t[0x18] = 'o';
    t[0x19] = 'p';
    t[0x1A] = '[';
    t[0x1B] = ']';
    t[0x1C] = '\n';
    t[0x1E] = 'a';
    t[0x1F] = 's';
    t[0x20] = 'd';
    t[0x21] = 'f';
    t[0x22] = 'g';
    t[0x23] = 'h';
    t[0x24] = 'j';
    t[0x25] = 'k';
    t[0x26] = 'l';
    t[0x27] = ';';
    t[0x28] = '\'';
    t[0x29] = '`';
    t[0x2B] = '\\';
    t[0x2C] = 'z';
    t[0x2D] = 'x';
    t[0x2E] = 'c';
    t[0x2F] = 'v';
    t[0x30] = 'b';
    t[0x31] = 'n';
    t[0x32] = 'm';
    t[0x33] = ',';
    t[0x34] = '.';
    t[0x35] = '/';
    t[0x39] = ' ';
    break :blk t;
};

// US QWERTY Set 1 scancode → ASCII (shift held)
const scancode_shift = blk: {
    var t = [_]u8{0} ** 128;
    t[0x01] = 0x1B;
    t[0x02] = '!';
    t[0x03] = '@';
    t[0x04] = '#';
    t[0x05] = '$';
    t[0x06] = '%';
    t[0x07] = '^';
    t[0x08] = '&';
    t[0x09] = '*';
    t[0x0A] = '(';
    t[0x0B] = ')';
    t[0x0C] = '_';
    t[0x0D] = '+';
    t[0x0E] = 0x08;
    t[0x0F] = '\t';
    t[0x10] = 'Q';
    t[0x11] = 'W';
    t[0x12] = 'E';
    t[0x13] = 'R';
    t[0x14] = 'T';
    t[0x15] = 'Y';
    t[0x16] = 'U';
    t[0x17] = 'I';
    t[0x18] = 'O';
    t[0x19] = 'P';
    t[0x1A] = '{';
    t[0x1B] = '}';
    t[0x1C] = '\n';
    t[0x1E] = 'A';
    t[0x1F] = 'S';
    t[0x20] = 'D';
    t[0x21] = 'F';
    t[0x22] = 'G';
    t[0x23] = 'H';
    t[0x24] = 'J';
    t[0x25] = 'K';
    t[0x26] = 'L';
    t[0x27] = ':';
    t[0x28] = '"';
    t[0x29] = '~';
    t[0x2B] = '|';
    t[0x2C] = 'Z';
    t[0x2D] = 'X';
    t[0x2E] = 'C';
    t[0x2F] = 'V';
    t[0x30] = 'B';
    t[0x31] = 'N';
    t[0x32] = 'M';
    t[0x33] = '<';
    t[0x34] = '>';
    t[0x35] = '?';
    t[0x39] = ' ';
    break :blk t;
};
