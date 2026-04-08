/// Fat Binary (Universal Binary) — select the correct architecture slice
/// from a multi-architecture Mach-O container.

const log = @import("../../lib/log.zig");
const parser = @import("parser.zig");

pub const FAT_MAGIC: u32 = 0xCAFEBABE;
pub const FAT_CIGAM: u32 = 0xBEBAFECA;
pub const FAT_MAGIC_64: u32 = 0xCAFEBABF;
pub const FAT_CIGAM_64: u32 = 0xBFBAFECA;

pub const FatHeader = extern struct {
    magic: u32,
    nfat_arch: u32,
};

pub const FatArch = extern struct {
    cputype: i32,
    cpusubtype: i32,
    offset: u32,
    size: u32,
    @"align": u32,
};

pub const FatArch64 = extern struct {
    cputype: i32,
    cpusubtype: i32,
    offset: u64,
    size: u64,
    @"align": u32,
    reserved: u32,
};

pub const FatError = error{
    NotFatBinary,
    UnsupportedFormat,
    TruncatedFile,
    ArchNotFound,
};

/// Check whether the data starts with a Fat Binary magic number.
pub fn isFatBinary(data: [*]const u8, size: usize) bool {
    if (size < @sizeOf(FatHeader)) return false;
    const magic = @as(*const u32, @alignCast(@ptrCast(data))).*;
    return magic == FAT_MAGIC or magic == FAT_CIGAM or
        magic == FAT_MAGIC_64 or magic == FAT_CIGAM_64;
}

/// Result of extracting a specific architecture from a fat binary.
pub const SliceInfo = struct {
    data: [*]const u8,
    size: usize,
    cputype: i32,
    cpusubtype: i32,
};

/// Extract the slice matching `target_cpu` from a fat binary.
pub fn selectArch(data: [*]const u8, size: usize, target_cpu: i32) FatError!SliceInfo {
    if (size < @sizeOf(FatHeader)) return FatError.TruncatedFile;

    const hdr: *const FatHeader = @alignCast(@ptrCast(data));
    const magic = hdr.magic;
    const is_64 = (magic == FAT_MAGIC_64 or magic == FAT_CIGAM_64);
    const swapped = (magic == FAT_CIGAM or magic == FAT_CIGAM_64);

    if (magic != FAT_MAGIC and magic != FAT_CIGAM and
        magic != FAT_MAGIC_64 and magic != FAT_CIGAM_64)
        return FatError.NotFatBinary;

    if (swapped) {
        log.warn("Byte-swapped fat binary not yet supported", .{});
        return FatError.UnsupportedFormat;
    }

    const narch = hdr.nfat_arch;
    const arch_base = @sizeOf(FatHeader);

    var i: u32 = 0;
    while (i < narch) : (i += 1) {
        if (is_64) {
            const entry_size = @sizeOf(FatArch64);
            const off = arch_base + i * entry_size;
            if (off + entry_size > size) return FatError.TruncatedFile;
            const arch: *const FatArch64 = @alignCast(@ptrCast(data + off));
            if (arch.cputype == target_cpu) {
                if (arch.offset + arch.size > size) return FatError.TruncatedFile;
                return .{
                    .data = data + @as(usize, @intCast(arch.offset)),
                    .size = @intCast(arch.size),
                    .cputype = arch.cputype,
                    .cpusubtype = arch.cpusubtype,
                };
            }
        } else {
            const entry_size = @sizeOf(FatArch);
            const off = arch_base + i * entry_size;
            if (off + entry_size > size) return FatError.TruncatedFile;
            const arch: *const FatArch = @alignCast(@ptrCast(data + off));
            if (arch.cputype == target_cpu) {
                if (arch.offset + arch.size > size) return FatError.TruncatedFile;
                return .{
                    .data = data + arch.offset,
                    .size = arch.size,
                    .cputype = arch.cputype,
                    .cpusubtype = arch.cpusubtype,
                };
            }
        }
    }

    return FatError.ArchNotFound;
}

/// List all architectures present in the fat binary.
pub fn listArchitectures(data: [*]const u8, size: usize) void {
    if (size < @sizeOf(FatHeader)) return;
    const hdr: *const FatHeader = @alignCast(@ptrCast(data));
    const narch = hdr.nfat_arch;
    const is_64 = (hdr.magic == FAT_MAGIC_64);

    log.info("Fat Binary: {} architecture(s)", .{narch});

    var i: u32 = 0;
    while (i < narch) : (i += 1) {
        if (is_64) {
            const off = @sizeOf(FatHeader) + i * @sizeOf(FatArch64);
            if (off + @sizeOf(FatArch64) > size) return;
            const arch: *const FatArch64 = @alignCast(@ptrCast(data + off));
            log.info("  [{}/{}] cputype=0x{x} offset=0x{x} size=0x{x}", .{
                i + 1, narch, arch.cputype, arch.offset, arch.size,
            });
        } else {
            const off = @sizeOf(FatHeader) + i * @sizeOf(FatArch);
            if (off + @sizeOf(FatArch) > size) return;
            const arch: *const FatArch = @alignCast(@ptrCast(data + off));
            log.info("  [{}/{}] cputype=0x{x} offset=0x{x} size={}", .{
                i + 1, narch, arch.cputype, arch.offset, arch.size,
            });
        }
    }
}
