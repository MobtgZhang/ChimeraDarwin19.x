/// ChimeraOS LoongArch64 entry point.
///
/// Supports two boot paths:
///   1. UEFI boot: firmware loads PE/COFF, passes ImageHandle ($a0)
///      and SystemTable* ($a1).  We query GOP for the framebuffer,
///      retrieve the UEFI memory map, exit boot services, then
///      switch to Direct Address mode and enter the kernel.
///   2. Direct boot: QEMU -kernel loads the ELF with DA=1.
///      We skip UEFI interaction, use a hardcoded memory map,
///      and enter the kernel without a framebuffer.
///
/// Boot mode is detected by reading CRMD.DA at entry.

pub const kernel = @import("kernel/main.zig");
pub const log = @import("lib/log.zig");

// ── Minimal UEFI type definitions (LoongArch64 LP64 ABI) ─

const EfiStatus = usize;
const EFI_SUCCESS: EfiStatus = 0;

const EfiGuid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const GOP_GUID = EfiGuid{
    .data1 = 0x9042a9de,
    .data2 = 0x23dc,
    .data3 = 0x4a38,
    .data4 = .{ 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a },
};

const EfiGopModeInfo = extern struct {
    version: u32,
    horizontal_resolution: u32,
    vertical_resolution: u32,
    pixel_format: u32,
    pixel_bitmask: extern struct { r: u32, g: u32, b: u32, a: u32 },
    pixels_per_scan_line: u32,
};

const EfiGopMode = extern struct {
    max_mode: u32,
    mode: u32,
    info: *EfiGopModeInfo,
    size_of_info: usize,
    frame_buffer_base: u64,
    frame_buffer_size: usize,
};

const EfiGop = extern struct {
    query_mode: *anyopaque,
    set_mode: *anyopaque,
    blt: *anyopaque,
    mode: *EfiGopMode,
};

// EFI_BOOT_SERVICES function-pointer byte offsets (64-bit ABI).
// Each entry before GetMemoryMap is 8 bytes (one function pointer).
const BS_GET_MEMORY_MAP: usize = 0x38;
const BS_EXIT_BOOT_SERVICES: usize = 0xE8;
const BS_SET_WATCHDOG_TIMER: usize = 0x100;
const BS_LOCATE_PROTOCOL: usize = 0x140;

// EFI_SYSTEM_TABLE.BootServices byte offset.
const ST_BOOT_SERVICES: usize = 0x60;

// UEFI function-pointer types (LoongArch64 LP64 calling convention).
const LocateProtocolFn = *const fn (*const EfiGuid, ?*anyopaque, *?*anyopaque) callconv(.c) EfiStatus;
const GetMemoryMapFn = *const fn (*usize, [*]u8, *usize, *usize, *u32) callconv(.c) EfiStatus;
const ExitBootServicesFn = *const fn (usize, usize) callconv(.c) EfiStatus;
const SetWatchdogTimerFn = *const fn (usize, u64, usize, ?*anyopaque) callconv(.c) EfiStatus;

// ── Saved boot state (populated by uefi_boot) ───────────

var saved_fb: ?kernel.FramebufferInfo = null;
var memory_regions: [kernel.MAX_MEMORY_REGIONS]kernel.MemoryRegion = undefined;
var region_count: usize = 0;
var mmap_buf: [24576]u8 align(8) = undefined;

// ── Entry point ──────────────────────────────────────────

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        // Detect boot mode via CRMD.DA (bit 3):
        //   DA=0  →  UEFI paged mode  →  call uefi_boot first
        //   DA=1  →  direct -kernel load →  skip to kernel
        \\csrrd  $t0, 0x0
        \\andi   $t0, $t0, 0x8
        \\bnez   $t0, 1f
        //
        // UEFI path: a0 = ImageHandle, a1 = SystemTable*
        \\bl     uefi_boot
        \\1:
        // Switch to DA mode with Coherent Cached memory access.
        // CRMD = PLV0 | DA | DATF(CC) | DATM(CC)
        //      = 0x00 | 0x08 | 0x20 | 0x80 = 0xA8
        // DATF=01 (bits[6:5]): instruction fetch uses cache
        // DATM=01 (bits[8:7]): data load/store uses cache
        // Without caching the CPU runs orders of magnitude slower,
        // making the kernel appear to hang during rendering.
        \\li.w   $t0, 0xA8
        \\csrwr  $t0, 0x0
        // Kernel stack at 8 MB physical
        \\lu12i.w $sp, 0x800
        \\or     $fp, $zero, $zero
        \\bl     loong64_entry
        \\break  0
    );
}

/// Runs under UEFI paged mode with boot services active.
/// Queries GOP, retrieves the memory map, exits boot services.
export fn uefi_boot(image_handle: usize, system_table_ptr: usize) callconv(.c) void {
    const bs = readWord(system_table_ptr + ST_BOOT_SERVICES);

    // Disable UEFI watchdog timer to prevent board-level reset.
    const set_wd: SetWatchdogTimerFn = @ptrFromInt(readWord(bs + BS_SET_WATCHDOG_TIMER));
    _ = set_wd(0, 0, 0, null);

    // ── Query Graphics Output Protocol ───────────────────
    var gop_iface: ?*anyopaque = null;
    const locate: LocateProtocolFn = @ptrFromInt(readWord(bs + BS_LOCATE_PROTOCOL));

    if (locate(&GOP_GUID, null, &gop_iface) == EFI_SUCCESS) {
        if (gop_iface) |raw| {
            const gop: *EfiGop = @ptrCast(@alignCast(raw));
            const m = gop.mode;
            const info = m.info;
            // Accept any pixel format with a direct framebuffer.
            // Format 3 (PixelBltOnly) has frame_buffer_base == 0.
            if (m.frame_buffer_base != 0) {
                saved_fb = .{
                    .base = m.frame_buffer_base,
                    .size = m.frame_buffer_size,
                    .width = info.horizontal_resolution,
                    .height = info.vertical_resolution,
                    .stride = info.pixels_per_scan_line,
                    .bpp = 32,
                    .pixel_format = @enumFromInt(info.pixel_format),
                };
            }
        }
    }

    // ── Get memory map & exit boot services ──────────────
    var map_size: usize = mmap_buf.len;
    var map_key: usize = 0;
    var desc_size: usize = 0;
    var desc_ver: u32 = 0;

    const get_mmap: GetMemoryMapFn = @ptrFromInt(readWord(bs + BS_GET_MEMORY_MAP));
    const exit_bs: ExitBootServicesFn = @ptrFromInt(readWord(bs + BS_EXIT_BOOT_SERVICES));

    if (get_mmap(&map_size, &mmap_buf, &map_key, &desc_size, &desc_ver) == EFI_SUCCESS) {
        if (exit_bs(image_handle, map_key) != EFI_SUCCESS) {
            // Map key went stale — re-acquire and retry once.
            map_size = mmap_buf.len;
            if (get_mmap(&map_size, &mmap_buf, &map_key, &desc_size, &desc_ver) == EFI_SUCCESS) {
                _ = exit_bs(image_handle, map_key);
            }
        }
        if (desc_size > 0) parseMemoryMap(&mmap_buf, map_size, desc_size);
    }
}

/// Kernel entry — called after DA mode switch with a fresh stack.
export fn loong64_entry() noreturn {
    if (region_count == 0) fallbackMemoryMap();

    const boot_info = kernel.BootInfo{
        .framebuffer = saved_fb,
        .memory_regions = &memory_regions,
        .memory_region_count = region_count,
    };
    kernel.kernelMain(&boot_info);
}

// ── Internal helpers ─────────────────────────────────────

inline fn readWord(addr: usize) usize {
    return @as(*const usize, @ptrFromInt(addr)).*;
}

fn parseMemoryMap(buf: [*]const u8, total: usize, desc_sz: usize) void {
    var off: usize = 0;
    while (off + 40 <= total) : (off += desc_sz) {
        if (region_count >= kernel.MAX_MEMORY_REGIONS) break;
        const d = buf + off;
        // EFI_MEMORY_DESCRIPTOR layout (LP64):
        //   +0  u32 Type
        //   +4  u32 (pad)
        //   +8  u64 PhysicalStart
        //  +16  u64 VirtualStart
        //  +24  u64 NumberOfPages
        //  +32  u64 Attribute
        const mtype = @as(*align(1) const u32, @ptrCast(d)).*;
        const pstart = @as(*align(1) const u64, @ptrCast(d + 8)).*;
        const npages = @as(*align(1) const u64, @ptrCast(d + 24)).*;
        memory_regions[region_count] = .{
            .base = pstart,
            .length = npages * 4096,
            .kind = uefiMemKind(mtype),
        };
        region_count += 1;
    }
}

/// Translate EFI memory type to kernel region kind.
/// Uses if-else instead of switch to avoid compiler-generated jump tables
/// whose absolute-address entries break when the PE/COFF is base-relocated.
fn uefiMemKind(t: u32) kernel.MemoryRegionKind {
    if (t == 7) return .usable;
    if (t == 1 or t == 2 or t == 3 or t == 4) return .bootloader_reclaimable;
    if (t == 9) return .acpi_reclaimable;
    return .reserved;
}

/// Hardcoded QEMU loongarch64 virt layout for the -kernel boot path.
fn fallbackMemoryMap() void {
    // 0 – 32 MB: reserved (kernel image + BSS + stack)
    memory_regions[0] = .{ .base = 0, .length = 0x0200_0000, .kind = .reserved };
    // 32 MB – 256 MB: usable RAM (low region, below MMIO aperture)
    memory_regions[1] = .{ .base = 0x0200_0000, .length = 0x0E00_0000, .kind = .usable };
    region_count = 2;
}
