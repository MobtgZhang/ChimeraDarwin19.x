/// Mach-O Parser — reads and validates Mach-O binary headers, load commands,
/// and provides iterators over segments, sections and symbol tables.

const log = @import("../../lib/log.zig");

pub const MH_MAGIC: u32 = 0xFEEDFACE;
pub const MH_CIGAM: u32 = 0xCEFAEDFE;
pub const MH_MAGIC_64: u32 = 0xFEEDFACF;
pub const MH_CIGAM_64: u32 = 0xCFFAEDFE;

pub const CPU_ARCH_ABI64: i32 = 0x01000000;
pub const CPU_TYPE_X86: i32 = 7;
pub const CPU_TYPE_X86_64: i32 = CPU_TYPE_X86 | CPU_ARCH_ABI64;
pub const CPU_TYPE_ARM: i32 = 12;
pub const CPU_TYPE_ARM64: i32 = CPU_TYPE_ARM | CPU_ARCH_ABI64;
pub const CPU_TYPE_RISCV64: i32 = 0x80000000 | CPU_ARCH_ABI64;
pub const CPU_TYPE_LOONGARCH64: i32 = 0x80000000 | CPU_ARCH_ABI64;

pub const MH_OBJECT: u32 = 0x1;
pub const MH_EXECUTE: u32 = 0x2;
pub const MH_FVMLIB: u32 = 0x3;
pub const MH_CORE: u32 = 0x4;
pub const MH_PRELOAD: u32 = 0x5;
pub const MH_DYLIB: u32 = 0x6;
pub const MH_DYLINKER: u32 = 0x7;
pub const MH_BUNDLE: u32 = 0x8;
pub const MH_DSYM: u32 = 0xA;

pub const MH_NOUNDEFS: u32 = 0x01;
pub const MH_DYLDLINK: u32 = 0x04;
pub const MH_TWOLEVEL: u32 = 0x80;
pub const MH_PIE: u32 = 0x200000;

pub const LC_REQ_DYLD: u32 = 0x80000000;
pub const LC_SEGMENT_64: u32 = 0x19;
pub const LC_SYMTAB: u32 = 0x02;
pub const LC_DYSYMTAB: u32 = 0x0B;
pub const LC_LOAD_DYLIB: u32 = 0x0C;
pub const LC_ID_DYLIB: u32 = 0x0D;
pub const LC_LOAD_DYLINKER: u32 = 0x0E;
pub const LC_UUID: u32 = 0x1B;
pub const LC_RPATH: u32 = 0x8000001C;
pub const LC_CODE_SIGNATURE: u32 = 0x1D;
pub const LC_DYLD_INFO: u32 = 0x22;
pub const LC_DYLD_INFO_ONLY: u32 = 0x22 | LC_REQ_DYLD;
pub const LC_MAIN: u32 = 0x28 | LC_REQ_DYLD;
pub const LC_SOURCE_VERSION: u32 = 0x2A;
pub const LC_BUILD_VERSION: u32 = 0x32;
pub const LC_DYLD_EXPORTS_TRIE: u32 = 0x33 | LC_REQ_DYLD;
pub const LC_DYLD_CHAINED_FIXUPS: u32 = 0x34 | LC_REQ_DYLD;

pub const MachHeader64 = extern struct {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
};

pub const LoadCommandHdr = extern struct {
    cmd: u32,
    cmdsize: u32,
};

pub const SegmentCommand64 = extern struct {
    cmd: u32,
    cmdsize: u32,
    segname: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: i32,
    initprot: i32,
    nsects: u32,
    flags: u32,

    pub fn getSegName(self: *const SegmentCommand64) []const u8 {
        var len: usize = 0;
        while (len < 16 and self.segname[len] != 0) len += 1;
        return self.segname[0..len];
    }
};

pub const Section64 = extern struct {
    sectname: [16]u8,
    segname: [16]u8,
    addr: u64,
    size: u64,
    offset: u32,
    @"align": u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,

    pub fn getSectName(self: *const Section64) []const u8 {
        var len: usize = 0;
        while (len < 16 and self.sectname[len] != 0) len += 1;
        return self.sectname[0..len];
    }
};

pub const SymtabCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    symoff: u32,
    nsyms: u32,
    stroff: u32,
    strsize: u32,
};

pub const DyldInfoCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    rebase_off: u32,
    rebase_size: u32,
    bind_off: u32,
    bind_size: u32,
    weak_bind_off: u32,
    weak_bind_size: u32,
    lazy_bind_off: u32,
    lazy_bind_size: u32,
    export_off: u32,
    export_size: u32,
};

pub const EntryPointCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    entryoff: u64,
    stacksize: u64,
};

pub const UuidCommand = extern struct {
    cmd: u32,
    cmdsize: u32,
    uuid: [16]u8,
};

pub const Nlist64 = extern struct {
    n_strx: u32,
    n_type: u8,
    n_sect: u8,
    n_desc: i16,
    n_value: u64,
};

pub const ParseError = error{
    InvalidMagic,
    UnsupportedArchitecture,
    TruncatedFile,
    InvalidLoadCommand,
};

pub const ParseResult = struct {
    header: *const MachHeader64,
    base: [*]const u8,
    file_size: usize,
    is_64: bool,
    is_swapped: bool,
};

pub fn parse(data: [*]const u8, size: usize) ParseError!ParseResult {
    if (size < @sizeOf(MachHeader64)) return ParseError.TruncatedFile;

    const magic = @as(*const u32, @alignCast(@ptrCast(data))).*;

    const is_swapped = switch (magic) {
        MH_MAGIC, MH_MAGIC_64 => false,
        MH_CIGAM, MH_CIGAM_64 => true,
        else => return ParseError.InvalidMagic,
    };

    const is_64 = switch (magic) {
        MH_MAGIC_64, MH_CIGAM_64 => true,
        MH_MAGIC, MH_CIGAM => false,
        else => return ParseError.InvalidMagic,
    };

    if (!is_64) {
        log.warn("32-bit Mach-O not supported", .{});
        return ParseError.UnsupportedArchitecture;
    }

    var header: MachHeader64 = undefined;
    if (is_swapped) {
        header = byteSwapHeader(@alignCast(@ptrCast(data)));
    } else {
        header = @as(*const MachHeader64, @alignCast(@ptrCast(data))).*;
    }

    if (@sizeOf(MachHeader64) + header.sizeofcmds > size)
        return ParseError.TruncatedFile;

    return .{
        .header = @ptrCast(&header),
        .base = data,
        .file_size = size,
        .is_64 = true,
        .is_swapped = is_swapped,
    };
}

fn byteSwapHeader(h: *const MachHeader64) MachHeader64 {
    return .{
        .magic = @byteSwap(h.magic),
        .cputype = @intCast(@byteSwap(@as(u32, @bitCast(h.cputype)))),
        .cpusubtype = @intCast(@byteSwap(@as(u32, @bitCast(h.cpusubtype)))),
        .filetype = @byteSwap(h.filetype),
        .ncmds = @byteSwap(h.ncmds),
        .sizeofcmds = @byteSwap(h.sizeofcmds),
        .flags = @byteSwap(h.flags),
        .reserved = @byteSwap(h.reserved),
    };
}

pub const LoadCommandIterator = struct {
    base: [*]const u8,
    offset: usize,
    end: usize,
    is_swapped: bool,

    pub fn init(result: ParseResult) LoadCommandIterator {
        const start = @sizeOf(MachHeader64);
        return .{
            .base = result.base,
            .offset = start,
            .end = start + result.header.sizeofcmds,
            .is_swapped = result.is_swapped,
        };
    }

    pub fn next(self: *LoadCommandIterator) ?*const LoadCommandHdr {
        if (self.offset + @sizeOf(LoadCommandHdr) > self.end) return null;
        const lc: *const LoadCommandHdr = @alignCast(@ptrCast(self.base + self.offset));
        if (lc.cmdsize < @sizeOf(LoadCommandHdr)) return null;
        self.offset += lc.cmdsize;
        return lc;
    }

    pub fn asSegment(lc: *const LoadCommandHdr) ?*const SegmentCommand64 {
        if (lc.cmd != LC_SEGMENT_64) return null;
        return @alignCast(@ptrCast(lc));
    }

    pub fn asSymtab(lc: *const LoadCommandHdr) ?*const SymtabCommand {
        if (lc.cmd != LC_SYMTAB) return null;
        return @alignCast(@ptrCast(lc));
    }

    pub fn asDyldInfo(lc: *const LoadCommandHdr) ?*const DyldInfoCommand {
        if (lc.cmd != LC_DYLD_INFO and lc.cmd != LC_DYLD_INFO_ONLY) return null;
        return @alignCast(@ptrCast(lc));
    }

    pub fn asEntryPoint(lc: *const LoadCommandHdr) ?*const EntryPointCommand {
        if (lc.cmd != LC_MAIN) return null;
        return @alignCast(@ptrCast(lc));
    }

    pub fn asUuid(lc: *const LoadCommandHdr) ?*const UuidCommand {
        if (lc.cmd != LC_UUID) return null;
        return @alignCast(@ptrCast(lc));
    }
};

pub fn getSections(seg: *const SegmentCommand64) []const Section64 {
    if (seg.nsects == 0) return &.{};
    const base: [*]const u8 = @ptrCast(seg);
    const sects: [*]const Section64 = @alignCast(@ptrCast(base + @sizeOf(SegmentCommand64)));
    return sects[0..seg.nsects];
}

pub fn findEntryPoint(result: ParseResult) ?u64 {
    var iter = LoadCommandIterator.init(result);
    while (iter.next()) |lc| {
        if (LoadCommandIterator.asEntryPoint(lc)) |ep| {
            return ep.entryoff;
        }
    }
    return null;
}

pub fn dumpInfo(result: ParseResult) void {
    const h = result.header;
    log.info("Mach-O: cputype=0x{x} filetype={} ncmds={} flags=0x{x}", .{
        h.cputype, h.filetype, h.ncmds, h.flags,
    });

    var iter = LoadCommandIterator.init(result);
    while (iter.next()) |lc| {
        if (LoadCommandIterator.asSegment(lc)) |seg| {
            log.info("  Segment '{s}': vm=0x{x}+0x{x} file=0x{x}+0x{x} ({} sections)", .{
                seg.getSegName(), seg.vmaddr, seg.vmsize,
                seg.fileoff, seg.filesize, seg.nsects,
            });
        }
    }

    if (findEntryPoint(result)) |ep| {
        log.info("  Entry point offset: 0x{x}", .{ep});
    }
}
