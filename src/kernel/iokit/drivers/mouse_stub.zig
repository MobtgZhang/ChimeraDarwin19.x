/// Stub mouse driver for non-x86_64 architectures.
/// Provides the same interface as the PS/2 driver but always returns null.
/// Will be replaced by virtio-tablet or USB HID drivers per platform.

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

pub fn init() void {}

pub fn initWithBounds(w: u32, h: u32) void {
    cursor_x = @intCast(w / 2);
    cursor_y = @intCast(h / 2);
}

pub fn poll() ?MouseEvent {
    return null;
}

pub fn getPosition() struct { x: i32, y: i32 } {
    return .{ .x = cursor_x, .y = cursor_y };
}

pub fn isLeftPressed() bool {
    return false;
}
