/// Dyld Dylinker — handles dynamic linker operations for Mach-O.
/// Implements LC_LOAD_DYLINKER, dyld-style symbol binding, and lazy binding.

const log = @import("../../lib/log.zig");
const parser = @import("parser.zig");

pub const MAX_DYLINKS: usize = 16;
pub const MAX_SYMBOLS: usize = 4096;

/// Symbol entry
pub const SymbolEntry = struct {
    name: [128]u8,
    name_len: usize,
    address: u64,
    defined: bool,
    weak: bool,
};

/// Dylinker info
pub const DylinkerInfo = struct {
    path: [256]u8,
    path_len: usize,
    entry_point: u64,
    active: bool,
};

var dylinkers: [MAX_DYLINKS]DylinkerInfo = undefined;
var dylinker_count: usize = 0;
var symbols: [MAX_SYMBOLS]SymbolEntry = undefined;
var symbol_count: usize = 0;

pub fn init() void {
    dylinker_count = 0;
    symbol_count = 0;
    for (&dylinkers) |*d| d.* = .{ .path = undefined, .path_len = 0, .entry_point = 0, .active = false };
    for (&symbols) |*s| {
        s.* = .{ .name = undefined, .name_len = 0, .address = 0, .defined = false, .weak = false };
    }
    log.info("Dyld dylinker subsystem initialized", .{});
}

pub fn loadDylinker(result: parser.ParseResult, dyld_path: []const u8) ?u32 {
    if (dylinker_count >= MAX_DYLINKS) return null;

    const id = @as(u32, @intCast(dylinker_count));
    var dl = &dylinkers[dylinker_count];
    dl.* = .{
        .path = undefined,
        .path_len = @min(dyld_path.len, 255),
        .entry_point = 0,
        .active = true,
    };
    @memcpy(dl.path[0..dl.path_len], dyld_path);
    dylinker_count += 1;

    log.debug("Dylinker loaded: id={}, path='{s}'", .{ id, dyld_path });
    return id;
}

pub fn bindSymbol(name: []const u8, address: u64, weak: bool) ?u32 {
    if (symbol_count >= MAX_SYMBOLS) return null;

    const id = @as(u32, @intCast(symbol_count));
    var sym = &symbols[symbol_count];
    sym.* = .{
        .name = undefined,
        .name_len = @min(name.len, 127),
        .address = address,
        .defined = true,
        .weak = weak,
    };
    @memcpy(sym.name[0..sym.name_len], name);
    symbol_count += 1;

    return id;
}

pub fn lookupSymbol(name: []const u8) ?u64 {
    for (symbols[0..symbol_count]) |sym| {
        if (!sym.defined) continue;
        if (sym.name_len != name.len) continue;
        var match = true;
        for (0..sym.name_len) |i| {
            if (sym.name[i] != name[i]) {
                match = false;
                break;
            }
        }
        if (match) return sym.address;
    }
    return null;
}

pub fn lazyBind(
    image_base: u64,
    lazy_info_offset: u64,
    sym_name: []const u8,
) ?u64 {
    const resolved = lookupSymbol(sym_name) orelse return null;
    const stub_addr = image_base + lazy_info_offset;

    log.debug("Lazy binding: {s} -> 0x{x}", .{ sym_name, resolved });
    return resolved;
}

pub const BindOpcode = enum(u8) {
    done = 0x00,
    set_dylib_ordinal = 0x10,
    set_dylib_special_immediate = 0x20,
    set_symbol_trait = 0x30,
    set_type = 0x40,
    add_addr_imm_scaled = 0x50,
    do_bind = 0x60,
    do_bind_imm_scaled = 0x70,
    do_bind_imm_scaled_once = 0x90,
    do_bind_add_addr_imm_scaled = 0xA0,
    do_bind_add_addr_imm_scaled_once = 0xB0,
    do_bind_uleb = 0xC0,
    do_bind_uleb_once = 0xD0,
    do_bind_add_addr_uleb = 0xE0,
};

pub fn processBindInfo(
    bind_data: [*]const u8,
    bind_size: usize,
    image_base: u64,
) void {
    var offset: usize = 0;
    var addr: u64 = image_base;

    const BIND_OPCODE_MASK: u8 = 0xF0;
    const BIND_IMMEDIATE_MASK: u8 = 0x0F;

    while (offset < bind_size) {
        const byte = bind_data[offset];
        offset += 1;
        const opcode_val = @as(u8, @intCast(byte & BIND_OPCODE_MASK)) >> 4;
        const immediate = byte & BIND_IMMEDIATE_MASK;

        const opcode: BindOpcode = @enumFromInt(opcode_val);

        switch (opcode) {
            .done => break,
            .add_addr_imm_scaled => {
                addr += @as(u64, immediate) * @sizeOf(u64);
            },
            .do_bind => {
                const ptr: *u64 = @ptrFromInt(addr);
                const sym_addr = lookupSymbol("") orelse 0;
                ptr.* = sym_addr;
                addr += @sizeOf(u64);
            },
            .do_bind_imm_scaled => {
                const ptr: *u64 = @ptrFromInt(addr);
                const sym_addr = lookupSymbol("") orelse 0;
                ptr.* = sym_addr;
                addr += @as(u64, immediate + 1) * @sizeOf(u64);
            },
            else => {},
        }
    }
}
