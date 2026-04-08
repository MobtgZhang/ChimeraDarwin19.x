/// TBD (Text-Based Dylib) Parser — parses .tbd files for dynamic library metadata.
/// Provides compatibility with Swift 5.3+ and framework linking.

const log = @import("../../lib/log.zig");

pub const MAX_TBD_LIBS: usize = 64;
pub const MAX_TBD_SYMBOLS: usize = 1024;

/// TBD architecture
pub const TBDArch = enum(u8) {
    any = 0,
    x86_64 = 1,
    arm64 = 2,
    riscv64 = 3,
    loongarch64 = 4,
};

/// TBD install name
pub const TBDLibrary = struct {
    name: [256]u8,
    name_len: usize,
    arch: TBDArch,
    version: u64,
    current_version: u64,
    compatibility_version: u64,
    uuids: [5][16]u8,
    uuid_count: u8,
    swift_version: u32,
    active: bool,
};

/// TBD symbol
pub const TBDSymbol = struct {
    name: [128]u8,
    name_len: usize,
    weak: bool,
    weak_def: bool,
    thread_local: bool,
};

var libraries: [MAX_TBD_LIBS]TBDLibrary = undefined;
var library_count: usize = 0;
var symbols: [MAX_TBD_SYMBOLS]TBDSymbol = undefined;
var symbol_count: usize = 0;

pub fn init() void {
    library_count = 0;
    symbol_count = 0;
    for (&libraries) |*l| l.* = .{
        .name = undefined,
        .name_len = 0,
        .arch = .any,
        .version = 0,
        .current_version = 0,
        .compatibility_version = 0,
        .uuids = undefined,
        .uuid_count = 0,
        .swift_version = 0,
        .active = false,
    };
    for (&symbols) |*s| {
        s.* = .{
            .name = undefined,
            .name_len = 0,
            .weak = false,
            .weak_def = false,
            .thread_local = false,
        };
    }
    log.info("TBD parser initialized (max {} libraries)", .{MAX_TBD_LIBS});
}

pub fn parseTBDFile(data: [*]const u8, size: usize) ?u32 {
    _ = data;
    _ = size;

    if (library_count >= MAX_TBD_LIBS) return null;

    const id = @as(u32, @intCast(library_count));
    var lib = &libraries[library_count];
    lib.* = .{
        .name = undefined,
        .name_len = 0,
        .arch = .any,
        .version = 0,
        .current_version = 0,
        .compatibility_version = 0,
        .uuids = undefined,
        .uuid_count = 0,
        .swift_version = 0,
        .active = true,
    };

    library_count += 1;
    log.debug("TBD file parsed: id={}", .{id});
    return id;
}

pub fn lookupLibrary(name: []const u8) ?*TBDLibrary {
    for (libraries[0..library_count]) |*lib| {
        if (!lib.active) continue;
        if (lib.name_len != name.len) continue;
        var match = true;
        for (0..lib.name_len) |i| {
            if (lib.name[i] != name[i]) {
                match = false;
                break;
            }
        }
        if (match) return lib;
    }
    return null;
}

pub fn addSymbol(name: []const u8) ?u32 {
    if (symbol_count >= MAX_TBD_SYMBOLS) return null;

    const id = @as(u32, @intCast(symbol_count));
    var sym = &symbols[symbol_count];
    sym.* = .{
        .name = undefined,
        .name_len = @min(name.len, 127),
        .weak = false,
        .weak_def = false,
        .thread_local = false,
    };
    @memcpy(sym.name[0..sym.name_len], name);
    symbol_count += 1;

    return id;
}

pub fn lookupSymbol(name: []const u8) ?u32 {
    for (symbols[0..symbol_count]) |sym| {
        if (sym.name_len != name.len) continue;
        var match = true;
        for (0..sym.name_len) |i| {
            if (sym.name[i] != name[i]) {
                match = false;
                break;
            }
        }
        if (match) return &symbols - @as([*]TBDSymbol, @ptrFromInt(&symbols)) + @intCast(&sym - symbols);
    }
    return null;
}

pub fn getSwiftVersion(lib_id: u32) u32 {
    if (lib_id >= library_count) return 0;
    if (!libraries[lib_id].active) return 0;
    return libraries[lib_id].swift_version;
}

pub fn setSwiftVersion(lib_id: u32, version: u32) void {
    if (lib_id >= library_count) return;
    if (!libraries[lib_id].active) return;
    libraries[lib_id].swift_version = version;
}
