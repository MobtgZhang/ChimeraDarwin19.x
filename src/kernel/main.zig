const std = @import("std");
const builtin = @import("builtin");

// ── Architecture (selected at compile time) ───────────────
const arch = @import("arch/hal.zig");

// x86_64-specific modules are now accessed through arch HAL

// ── Memory Management ─────────────────────────────────────
const pmm = @import("mm/pmm.zig");
const slab = @import("mm/slab.zig");

// ── Kernel Libraries ──────────────────────────────────────
const buddy = @import("lib/buddy.zig");
const rb_tree = @import("lib/rb_tree.zig");
const log = @import("../lib/log.zig");

// ── Mach Subsystem ────────────────────────────────────────
pub const mach_port = @import("mach/port.zig");
pub const mach_message = @import("mach/message.zig");
pub const mach_task = @import("mach/task.zig");
pub const mach_thread = @import("mach/thread.zig");
pub const mach_clock = @import("mach/clock.zig");
pub const mach_vm_object = @import("mach/vm/object.zig");
pub const mach_vm_map = @import("mach/vm/map.zig");
pub const mach_vm_pager = @import("mach/vm/pager.zig");

// ── BSD Layer ─────────────────────────────────────────────
pub const bsd_syscall = @import("bsd/syscall.zig");
pub const bsd_proc = @import("bsd/proc.zig");
pub const bsd_signal = @import("bsd/signal.zig");
pub const bsd_vnode = @import("bsd/vfs/vnode.zig");
pub const bsd_devfs = @import("bsd/vfs/devfs.zig");

// ── I/O Kit ───────────────────────────────────────────────
pub const iokit_registry = @import("iokit/registry.zig");
pub const iokit_service = @import("iokit/service.zig");
pub const iokit_pcie = if (builtin.cpu.arch == .x86_64) @import("iokit/drivers/pcie.zig") else struct {
    pub fn init() void {}
};

// ── Device Drivers (x86_64 PS/2 + ATA + AC97 are arch-specific) ──
const is_x86 = builtin.cpu.arch == .x86_64;
const keyboard = if (is_x86) @import("iokit/drivers/keyboard.zig") else @import("iokit/drivers/input_stub.zig");
const mouse = if (is_x86) @import("iokit/drivers/mouse.zig") else @import("iokit/drivers/mouse_stub.zig");
const framebuffer = @import("iokit/drivers/framebuffer.zig");
const ata = if (is_x86) @import("iokit/drivers/ata.zig") else struct {
    pub fn init() void {}
};
const ac97 = if (is_x86) @import("iokit/drivers/ac97.zig") else struct {
    pub fn init() void {}
};

// ── Loader ────────────────────────────────────────────────
pub const macho_parser = @import("../loader/macho/parser.zig");
pub const macho_fat = @import("../loader/macho/fat.zig");
pub const macho_segments = @import("../loader/macho/segments.zig");

// ── GUI Desktop ───────────────────────────────────────────
const desktop = @import("../gui/desktop.zig");
const pixel_format = @import("../lib/pixel_format.zig");

// ── Boot Info Structures ──────────────────────────────────

pub const FramebufferPixelFormat = pixel_format.FramebufferPixelFormat;

pub const FramebufferInfo = struct {
    base: u64,
    size: usize,
    width: u32,
    height: u32,
    stride: u32,
    bpp: u32,
    pixel_format: FramebufferPixelFormat,
};

pub const MemoryRegionKind = enum {
    usable,
    reserved,
    acpi_reclaimable,
    bootloader_reclaimable,
};

pub const MemoryRegion = struct {
    base: u64,
    length: u64,
    kind: MemoryRegionKind,
};

pub const MAX_MEMORY_REGIONS: usize = 256;

pub const BootInfo = struct {
    framebuffer: ?FramebufferInfo,
    memory_regions: [*]const MemoryRegion,
    memory_region_count: usize,
};

// ── Kernel Entry Point ────────────────────────────────────

pub fn kernelMain(boot_info: *const BootInfo) noreturn {
    // ── Phase 0: Architecture init & logging ──────────────
    arch.earlyInit();
    log.info("", .{});
    log.info("========================================", .{});
    log.info("  Darwin 19.x Z-Kernel", .{});
    log.info("  XNU 19.6.0 compatible", .{});
    log.info("  A macOS-compatible OS written in Zig", .{});
    log.info("========================================", .{});
    log.info("", .{});
    log.info("[ARCH] {s}", .{arch.name});

    // ── Phase 1: CPU tables & interrupt controller ─────────
    arch.cpuInit();

    // ── Phase 2: Physical memory ──────────────────────────
    pmm.init(boot_info.memory_regions[0..boot_info.memory_region_count]);
    log.info("[MEM]  PMM: {} pages free ({} MB)", .{
        pmm.freePageCount(),
        pmm.freePageCount() * 4096 / (1024 * 1024),
    });

    initBuddyZone();

    // ── Phase 3: Hardware timers ──────────────────────────
    arch.timerInit();

    // ── Phase 4: Input devices ────────────────────────────
    arch.inputInit(boot_info);

    // ── Phase 5: Display ──────────────────────────────────
    if (boot_info.framebuffer) |fb| {
        framebuffer.init(fb.base, fb.width, fb.height, fb.stride, fb.size, fb.pixel_format);
    }

    // ── Phase 6: Virtual memory ───────────────────────────
    mach_vm_map.initKernelMap();
    log.info("[VM]   Kernel VM map initialized", .{});

    // ── Phase 7: Mach subsystem ───────────────────────────
    mach_task.initKernelTask();
    log.info("[MACH] kernel_task created (PID 0)", .{});

    mach_thread.init();
    log.info("[MACH] Thread scheduler initialized", .{});

    // ── Phase 8: BSD layer ────────────────────────────────
    bsd_syscall.init();
    log.info("[BSD]  Syscall dispatch table ready ({} entries)", .{
        @typeInfo(bsd_syscall.SyscallNumber).@"enum".fields.len,
    });

    bsd_proc.init();
    log.info("[BSD]  Process table initialized", .{});

    bsd_vnode.init();
    bsd_devfs.init();
    log.info("[VFS]  VFS + DevFS mounted (/dev/null, /dev/zero, /dev/console)", .{});

    // ── Phase 9: I/O Kit & hardware detection ─────────────
    iokit_registry.init();
    iokit_service.init();
    log.info("[IOK]  IOKit registry and service manager ready", .{});

    iokit_pcie.init();
    ata.init();
    ac97.init();

    // ── Phase 10: Desktop GUI (with double buffering) ─────
    if (boot_info.framebuffer) |fb| {
        const fb_ptr: [*]volatile u32 = @ptrFromInt(fb.base);
        desktop.init(fb_ptr, fb.width, fb.height, fb.stride, fb.pixel_format, arch.name);

        // Allocate back buffer from PMM for double buffering
        const buf_pixels = @as(usize, fb.stride) * fb.height;
        const buf_bytes = buf_pixels * @sizeOf(u32);
        const buf_pages = (buf_bytes + 4095) / 4096;
        if (pmm.allocPages(buf_pages)) |start_page| {
            const back_addr = pmm.pageToPhysical(start_page);
            const back_ptr: [*]u32 = @ptrFromInt(back_addr);
            @memset(back_ptr[0..buf_pixels], 0);
            desktop.enableDoubleBuffer(back_ptr);
            log.info("[GUI]  Double buffer enabled ({} KB)", .{buf_bytes / 1024});
        } else {
            log.warn("[GUI]  Double buffer allocation failed — direct rendering", .{});
        }

        const time = arch.readTime();
        desktop.updateClock(time.hour, time.minute);

        log.info("[GUI]  Desktop compositor initialized ({}x{})", .{ fb.width, fb.height });
    }

    // ── Boot summary ──────────────────────────────────────
    log.info("", .{});
    log.info("=== Darwin 19.x Z-Kernel initialized ===", .{});
    log.info("  Architecture : {s}", .{arch.name});
    log.info("  Build        : {s}", .{
        if (@import("build_options").enable_logging) "Debug (logging ON)" else "Release (logging OFF)",
    });
    log.info("  XNU Version  : 19.6.0", .{});
    log.info("  Free memory  : {} MB", .{pmm.freePageCount() * 4096 / (1024 * 1024)});
    log.info("  Subsystems   : Mach IPC, VM, BSD, VFS, IOKit, Mach-O Loader", .{});
    log.info("  GUI          : Desktop Compositor (double-buffered), Window Manager, Dock, Menu Bar", .{});
    log.info("", .{});
    log.info("Entering desktop event loop.", .{});

    // ── Main event loop ───────────────────────────────────
    var prev_left: bool = false;
    var tick_counter: u64 = 0;
    var mouse_poll_counter: u64 = 0;

    while (true) {
        // ── Poll mouse at high frequency (every iteration) ─
        mouse_poll_counter +%= 1;
        if (mouse.poll()) |mev| {
            desktop.updateFastMousePosition(mev.x, mev.y);
            desktop.handleMouseMove(mev.x, mev.y);

            if (mev.left and !prev_left) {
                desktop.handleMouseDown(mev.x, mev.y);
            }
            if (!mev.left and prev_left) {
                desktop.handleMouseUp(mev.x, mev.y);
            }
            prev_left = mev.left;
        }

        // ── Poll keyboard ─────────────────────────────────
        if (keyboard.poll()) |ev| {
            if (ev.pressed and ev.ascii != 0) {
                desktop.handleKeyPress(ev.ascii);
                desktop.requestRedraw();
            }
        }

        // ── Periodic tasks (every 1000 iterations) ──────────
        tick_counter +%= 1;
        if (tick_counter % 50_000 == 0) {
            arch.timerTick();
            desktop.tick();
        }

        if (tick_counter % 500_000 == 0) {
            const time = arch.readTime();
            desktop.updateClock(time.hour, time.minute);
        }

        // ── Render: always draw cursor at current mouse pos ─
        if (desktop.needsRedraw() or desktop.isMouseDirty()) {
            desktop.render();
            const pos = desktop.getFastMousePosition();
            desktop.drawCursor(pos.x, pos.y);
            desktop.presentFrame();
            desktop.clearRedrawFlag();
            desktop.clearMouseDirty();
        }

        mach_clock.processAlarms();
        arch.halt(); // Use hlt for better power efficiency and responsiveness
    }
}

// ── Buddy Zone Initialisation ─────────────────────────────

fn initBuddyZone() void {
    const zone_order: u5 = 10;
    if (pmm.allocPages(1024)) |start_page| {
        const base = pmm.pageToPhysical(start_page);
        buddy.init(base, 1024);
        log.info("[MEM]  Buddy zone: {} pages at 0x{x}", .{ 1024, base });
    } else {
        log.warn("[MEM]  Not enough memory for buddy zone", .{});
        _ = zone_order;
    }
}
