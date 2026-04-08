/// ChimeraOS RISC-V64 entry: UEFI (PE/COFF via GNU objcopy) or direct QEMU -kernel.
///
/// UEFI: firmware passes ImageHandle (a0) and SystemTable* (a1).
/// Direct: OpenSBI passes hart id / DTB — detect via EFI system table signature.

pub const kernel = @import("kernel/main.zig");
pub const log = @import("lib/log.zig");

extern const __stack_top: u8;

const EfiStatus = usize;
const EFI_SUCCESS: EfiStatus = 0;

const EFI_SYSTEM_TABLE_SIGNATURE: u64 = 0x5453_5953_2049_4249;

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

const BS_GET_MEMORY_MAP: usize = 0x38;
const BS_EXIT_BOOT_SERVICES: usize = 0xE8;
const BS_SET_WATCHDOG_TIMER: usize = 0x100;
const BS_LOCATE_PROTOCOL: usize = 0x140;
const ST_BOOT_SERVICES: usize = 0x60;

const LocateProtocolFn = *const fn (*const EfiGuid, ?*anyopaque, *?*anyopaque) callconv(.c) EfiStatus;
const GetMemoryMapFn = *const fn (*usize, [*]u8, *usize, *usize, *u32) callconv(.c) EfiStatus;
const ExitBootServicesFn = *const fn (usize, usize) callconv(.c) EfiStatus;
const SetWatchdogTimerFn = *const fn (usize, u64, usize, ?*anyopaque) callconv(.c) EfiStatus;

var saved_fb: ?kernel.FramebufferInfo = null;
var memory_regions: [kernel.MAX_MEMORY_REGIONS]kernel.MemoryRegion = undefined;
var region_count: usize = 0;
var mmap_buf: [24576]u8 align(8) = undefined;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ .option push
        \\ .option norelax
        \\ la sp, __stack_top
        \\ .option pop
        \\ call riscv_uefi_entry
    );
}

export fn riscv_uefi_entry(image_handle: usize, system_table: usize) callconv(.c) noreturn {
    region_count = 0;
    if (isEfiSystemTable(system_table)) {
        uefi_boot(image_handle, system_table);
    }
    riscv64_kernel_entry();
}

export fn uefi_boot(image_handle: usize, system_table_ptr: usize) callconv(.c) void {
    const bs = readWord(system_table_ptr + ST_BOOT_SERVICES);

    const set_wd: SetWatchdogTimerFn = @ptrFromInt(readWord(bs + BS_SET_WATCHDOG_TIMER));
    _ = set_wd(0, 0, 0, null);

    var gop_iface: ?*anyopaque = null;
    const locate: LocateProtocolFn = @ptrFromInt(readWord(bs + BS_LOCATE_PROTOCOL));

    if (locate(&GOP_GUID, null, &gop_iface) == EFI_SUCCESS) {
        if (gop_iface) |raw| {
            const gop: *EfiGop = @ptrCast(@alignCast(raw));
            const m = gop.mode;
            const info = m.info;
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

    var map_size: usize = mmap_buf.len;
    var map_key: usize = 0;
    var desc_size: usize = 0;
    var desc_ver: u32 = 0;

    const get_mmap: GetMemoryMapFn = @ptrFromInt(readWord(bs + BS_GET_MEMORY_MAP));
    const exit_bs: ExitBootServicesFn = @ptrFromInt(readWord(bs + BS_EXIT_BOOT_SERVICES));

    if (get_mmap(&map_size, &mmap_buf, &map_key, &desc_size, &desc_ver) == EFI_SUCCESS) {
        if (exit_bs(image_handle, map_key) != EFI_SUCCESS) {
            map_size = mmap_buf.len;
            if (get_mmap(&map_size, &mmap_buf, &map_key, &desc_size, &desc_ver) == EFI_SUCCESS) {
                _ = exit_bs(image_handle, map_key);
            }
        }
        if (desc_size > 0) parseMemoryMap(&mmap_buf, map_size, desc_size);
    }
}

export fn riscv64_kernel_entry() noreturn {
    if (region_count == 0) fallbackMemoryMap();

    const boot_info = kernel.BootInfo{
        .framebuffer = saved_fb,
        .memory_regions = &memory_regions,
        .memory_region_count = region_count,
    };
    kernel.kernelMain(&boot_info);
}

fn isEfiSystemTable(ptr: usize) bool {
    if (ptr == 0) return false;
    const sig = @as(*align(8) const u64, @ptrFromInt(ptr)).*;
    return sig == EFI_SYSTEM_TABLE_SIGNATURE;
}

inline fn readWord(addr: usize) usize {
    return @as(*const usize, @ptrFromInt(addr)).*;
}

fn parseMemoryMap(buf: [*]const u8, total: usize, desc_sz: usize) void {
    var off: usize = 0;
    while (off + 40 <= total) : (off += desc_sz) {
        if (region_count >= kernel.MAX_MEMORY_REGIONS) break;
        const d = buf + off;
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

fn uefiMemKind(t: u32) kernel.MemoryRegionKind {
    if (t == 7) return .usable;
    if (t == 1 or t == 2 or t == 3 or t == 4) return .bootloader_reclaimable;
    if (t == 9) return .acpi_reclaimable;
    return .reserved;
}

/// QEMU `virt` RAM low region (typical OpenSBI / -kernel layout).
fn fallbackMemoryMap() void {
    memory_regions[0] = .{ .base = 0x8000_0000, .length = 0x0800_0000, .kind = .usable };
    region_count = 1;
}
