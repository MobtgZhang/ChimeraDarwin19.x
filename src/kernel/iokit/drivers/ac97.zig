/// AC'97 Audio Codec driver (stub).
/// Detects and initializes the AC'97-compatible audio controller.
/// Full audio playback requires DMA buffer management (future work).

const ports = @import("../../arch/x86_64/ports.zig");
const log = @import("../../../lib/log.zig");
const registry = @import("../registry.zig");
const pcie = @import("pcie.zig");

const AC97_VENDOR_INTEL: u16 = 0x8086;
const AC97_DEVICE_ICH: u16 = 0x2415;

const AC97_NAM_RESET: u16 = 0x00;
const AC97_NAM_MASTER_VOL: u16 = 0x02;
const AC97_NAM_PCM_VOL: u16 = 0x18;

pub const AudioState = enum {
    uninitialized,
    no_device,
    ready,
    playing,
};

var state: AudioState = .uninitialized;
var nam_base: u16 = 0;
var nabm_base: u16 = 0;

pub fn init() void {
    // Scan PCI for AC97-class device (class 0x04, subclass 0x01)
    const devices = pcie.getDevices();
    var found = false;
    for (devices) |dev| {
        if (dev.class_code == 0x04 and dev.subclass == 0x01) {
            nam_base = @truncate(dev.bar[0] & 0xFFFC);
            nabm_base = @truncate(dev.bar[1] & 0xFFFC);
            found = true;
            break;
        }
    }

    if (!found) {
        state = .no_device;
        log.info("[AC97] No AC'97 audio controller found", .{});
        return;
    }

    // Reset codec
    ports.outw(nam_base + AC97_NAM_RESET, 0x0000);
    ports.ioWait();
    ports.ioWait();

    // Set master volume (0 = max, 0x8000 = mute)
    ports.outw(nam_base + AC97_NAM_MASTER_VOL, 0x0000);
    ports.outw(nam_base + AC97_NAM_PCM_VOL, 0x0808);

    state = .ready;

    if (registry.allocNode("IOAudioDevice", "AC97-Audio")) |node| {
        _ = node.setProperty("IOProviderClass", "IOAudioDevice");
        _ = node.setProperty("codec", "AC97");
        _ = node.setPropertyInt("nam-base", nam_base);
        _ = node.setPropertyInt("nabm-base", nabm_base);
        if (registry.getRoot()) |root| root.addChild(node);
    }

    log.info("[AC97] Audio controller initialized (NAM=0x{x}, NABM=0x{x})", .{ nam_base, nabm_base });
}

pub fn getState() AudioState {
    return state;
}

pub fn setMasterVolume(left: u8, right: u8) void {
    if (state != .ready and state != .playing) return;
    const vol: u16 = @as(u16, left & 0x3F) << 8 | (right & 0x3F);
    ports.outw(nam_base + AC97_NAM_MASTER_VOL, vol);
}

pub fn setPcmVolume(left: u8, right: u8) void {
    if (state != .ready and state != .playing) return;
    const vol: u16 = @as(u16, left & 0x1F) << 8 | (right & 0x1F);
    ports.outw(nam_base + AC97_NAM_PCM_VOL, vol);
}
