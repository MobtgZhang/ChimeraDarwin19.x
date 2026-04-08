/// Stub keyboard driver for non-x86_64 architectures.
/// Provides the same interface as the PS/2 driver but always returns null.
/// Will be replaced by virtio-input or USB HID drivers per platform.

pub const KeyEvent = struct {
    scancode: u8,
    ascii: u8,
    pressed: bool,
    shift: bool,
    ctrl: bool,
    alt: bool,
};

pub fn init() void {}

pub fn poll() ?KeyEvent {
    return null;
}

pub fn readEvent() ?KeyEvent {
    return null;
}

pub fn isShiftHeld() bool {
    return false;
}
pub fn isCtrlHeld() bool {
    return false;
}
pub fn isAltHeld() bool {
    return false;
}
