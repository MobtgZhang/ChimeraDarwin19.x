/// Lightweight PNG decoder and RGBA texture cache for the desktop GUI.
/// Decodes PNG images from memory buffers and caches decoded RGBA data.

const std = @import("std");
const graphics = @import("graphics.zig");
const color_mod = @import("color.zig");
const Color = color_mod.Color;

const MAX_TEXTURES = 32;

/// Bump allocator for PNG decode buffers - avoids POSIX dependency
const ICON_PNG_BUF_SIZE = 4 * 1024 * 1024; // 4MB
var icon_png_buffers: [ICON_PNG_BUF_SIZE]u8 align(8) = .{0} ** ICON_PNG_BUF_SIZE;
var icon_png_buf_offset: usize = 0;

fn iconPngAlloc(len: usize) ?[*]u8 {
    const aligned = (icon_png_buf_offset + 7) & ~@as(usize, 7);
    if (aligned + len > ICON_PNG_BUF_SIZE) return null;
    icon_png_buf_offset = aligned + len;
    return icon_png_buffers[aligned..].ptr;
}

fn iconPngAllocSlice(len: usize) ?[]u8 {
    const ptr = iconPngAlloc(len) orelse return null;
    return ptr[0..len];
}

fn iconPngResetBuffers() void {
    icon_png_buf_offset = 0;
}

/// Decoded RGBA texture descriptor.
pub const Texture = struct {
    width: u32,
    height: u32,
    rgba: [*]u8,
    owns_data: bool,

    pub fn deinit(self: *Texture) void {
        _ = self;
        // Bump allocator 不支持真正的释放
    }
};

/// Texture cache for deduplicating loaded icons.
pub const TextureCache = struct {
    entries: [MAX_TEXTURES]?Texture,
    count: u32,

    pub fn init() TextureCache {
        return TextureCache{
            .entries = [_]?Texture{null} ** MAX_TEXTURES,
            .count = 0,
        };
    }

    pub fn deinit(self: *TextureCache) void {
        var i: u32 = 0;
        while (i < MAX_TEXTURES) : (i += 1) {
            if (self.entries[i]) |*tex| {
                tex.deinit();
                self.entries[i] = null;
            }
        }
        self.count = 0;
    }

    pub fn get(self: *TextureCache, id: u32) ?*Texture {
        if (id < self.count and self.entries[id] != null) {
            return &self.entries[id].?;
        }
        return null;
    }
};

// ── CRC32 ───────────────────────────────────────────────

const crc32_table = [_]u32{
    0x00000000, 0x77073096, 0xee0e612c, 0x990951ba, 0x076dc419, 0x706af48f, 0xe963a535, 0x9e6495a3,
    0x0edb8832, 0x79dcb8a4, 0xe0d5e91e, 0x97d2d988, 0x09b64c2b, 0x7eb17cbd, 0xe7b82d07, 0x90bf1d91,
    0x1db71064, 0x6ab020f2, 0xf3b97148, 0x84be41de, 0x1adad47d, 0x6ddde4eb, 0xf4d4b551, 0x83d385c7,
    0x136c9856, 0x646ba8c0, 0xfd62f97a, 0x8a65c9ec, 0x14015c4f, 0x63066cd9, 0xfa0f3d63, 0x8d080df5,
    0x3b6e20c8, 0x4c69105e, 0xd56041e4, 0xa2677172, 0x3c03e4d1, 0x4b04d447, 0xd20d85fd, 0xa50ab56b,
    0x35b5a8fa, 0x42b2986c, 0xdede96a6, 0xa9d96990, 0x37a1fc33, 0x40a5cca5, 0xd99c9d1f, 0xae9bad89,
    0x2368a17c, 0x546f91ea, 0xcd6bd0a0, 0xba6ce036, 0x24085595, 0x530f6503, 0xca0634b9, 0xbd01042f,
    0x2db719be, 0x5ab02928, 0xc3b97892, 0xb4be4804, 0x2adadfa7, 0x5dddef31, 0xc4d4be8b, 0xb3d38e1d,
    0x76dc4190, 0x0bdb7106, 0x92d220bc, 0xe5d5102a, 0x7bb18589, 0x0cb6b51f, 0x95bfe4a5, 0xe2b8d433,
    0x7207c9a2, 0x0500f934, 0x9c09a88e, 0xeb0e9818, 0x756a0dbb, 0x026d3d2d, 0x9b646c97, 0xec635c01,
    0x616b51f4, 0x166c6162, 0x8f6530d8, 0xf862004e, 0x660695ed, 0x1101a57b, 0x8808f4c1, 0xff0fc457,
    0x6fb0d9c6, 0x18b7e950, 0x81beb8ea, 0xf6b9887c, 0x68dd1ddf, 0x1fda2d49, 0x86d37cf3, 0xf1d44c65,
    0x4306c278, 0x3401f2ee, 0xad08a354, 0xda0f93c2, 0x446b0661, 0x336c36f7, 0xaa65674d, 0xdd6257db,
    0x4ddd6f4a, 0x3ada5fdc, 0xa3d30e66, 0xd4d43ef0, 0x4ab0ab53, 0x3db79bc5, 0xa4bec87f, 0xd3b9f8e9,
    0x5eb1f51c, 0x29b6c58a, 0xb0bf9430, 0xc7b8a4a6, 0x59dc3105, 0x2edb0193, 0xb7d25029, 0xc0d560bf,
    0x506a8b3c, 0x276d5baa, 0xbe641a10, 0xc9632a86, 0x570dbf25, 0x200a8fb3, 0xb903de09, 0xce04ee9f,
    0xedb88320, 0x9abfb3b6, 0x03b6e20c, 0x74b1d29a, 0xead54739, 0x9dd277af, 0x04db2615, 0x73dc1683,
    0xe3630b12, 0x94643b84, 0x0d6d6a3e, 0x7a6a5aa8, 0xe40ecf0b, 0x9309ff9d, 0x0a00ae27, 0x7d079eb1,
    0xf00f9344, 0x8708a3d2, 0x1e01f268, 0x6906c2fe, 0xf762575d, 0x806567cb, 0x196c3671, 0x6e6b06e7,
    0xfed41b76, 0x89d32be0, 0x10da7a5a, 0x67dd4acc, 0xf9b9df6f, 0x8ebeeff9, 0x17b7be43, 0x60b08ed5,
    0xd36300e8, 0xa464307e, 0x3d6d61c4, 0x4a6a5152, 0xd40ec4f1, 0xa309f467, 0x3a00a5dd, 0x4d07954b,
    0xddb888da, 0xaabfb84c, 0x33b6e9f6, 0x44b1d960, 0xdad54cc3, 0xadd27c55, 0x34db2def, 0x43dc1d79,
    0xced4108c, 0xb9d3201a, 0x20da71a0, 0x57dd4136, 0xc9b9d495, 0xbebee403, 0x27b7b5b9, 0x50b0852f,
    0xc00f98be, 0xb708a828, 0x2e01f992, 0x5906c904, 0xc7625ca7, 0xb0656c31, 0x296c3d8b, 0x5e6b0d1d,
    0x9b5643b0, 0xec517326, 0x7558229c, 0x025f120a, 0x9c0b87a9, 0xeb0cb73f, 0x7205e685, 0x0502d613,
    0x95bdcb82, 0xe2bafb14, 0x7bb3aade, 0x0cb49a48, 0x92d00feb, 0xe5d73f7d, 0x7cde6ec7, 0x0bd95e51,
    0x86d153a4, 0xf1d66332, 0x68df3288, 0x1fd8021e, 0x81bc97bd, 0xf6bba72b, 0x6fb2f691, 0x18b5c607,
    0x880adb96, 0xff0deb00, 0x6604ba4a, 0x11038adc, 0x8f671f7f, 0xf8602fe9, 0x61697e53, 0x166e4ec5,
    0xa4acc0d8, 0xd3abf04e, 0x4aa2a1f4, 0x3da59162, 0xa3c104c1, 0xd4c63457, 0x4dcf65ed, 0x3ac8557b,
    0xaa7748ea, 0xdd70787c, 0x447929c6, 0x337e1950, 0xad1a8cf3, 0xda1dbc65, 0x431eeddf, 0x3419dd49,
    0xb911d0bc, 0xce16e02a, 0x571fb190, 0x20188106, 0xbe7c14a5, 0xc97b2433, 0x50727589, 0x2775451f,
    0xb7ca688e, 0xc0cd5818, 0x59c409a2, 0x2ec33934, 0xb0a7ac97, 0xc7a09c01, 0x5ea9cdbb, 0x29aefd2d,
};

fn crc32Update(crc: u32, data: []const u8) u32 {
    var c = crc ^ 0xFFFFFFFF;
    for (data) |byte| {
        c = crc32_table[@as(usize, (c ^ byte) & 0xFF)] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
}

// ── Deflate decompressor ─────────────────────────────────

const ZLIB_WINDOW = 32768;

/// Build a canonical Huffman table from code lengths.
fn buildHuffmanTable(table: []i32, lens: []const u8) void {
    var count: [16]u32 = .{0} ** 16;
    for (lens) |len| {
        if (len > 0) count[len] += 1;
    }

    var code: u32 = 0;
    var next_code: [16]u32 = .{0} ** 16;
    for (1..16) |len| {
        code = (code + count[len - 1]) << 1;
        next_code[len] = code;
    }

    for (0..lens.len) |i| {
        if (lens[i] > 0) {
            table[@as(usize, next_code[lens[i]])] = @as(i32, @intCast(i)) | (@as(i32, lens[i]) << 30);
            next_code[lens[i]] += 1;
        }
    }
}

/// Decompress zlib-compressed data into output buffer.
/// Uses fixed DEFLATE Huffman tables (standard for PNG).
fn decompressZlib(compressed: []const u8, output: []u8) usize {
    if (compressed.len < 6) return 0;
    const cmf = compressed[0];
    const flg = compressed[1];
    if ((cmf * 256 + flg) % 31 != 0) return 0;
    if ((cmf & 0x0F) != 8) return 0;

    var pos: usize = 2;
    if ((flg & 0x20) != 0) pos += 4;

    const deflate_data = compressed[pos .. compressed.len - 4];

    // Fixed Huffman code lengths for DEFLATE
    var ll_lens: [288]u8 = .{0} ** 288;
    var dist_lens: [32]u8 = .{0} ** 32;

    @memcpy(ll_lens[0..288], &[_]u8{
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
        8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    });

    @memcpy(dist_lens[0..32], &[_]u8{
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    });

    var ll_table: [288]i32 = .{0} ** 288;
    var dist_table: [32]i32 = .{0} ** 32;
    buildHuffmanTable(&ll_table, ll_lens[0..]);
    buildHuffmanTable(&dist_table, dist_lens[0..]);

    const length_base = [_]u32{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
    const dist_base = [_]u32{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };

    var bit_buffer: u32 = 0;
    var bits_in: u32 = 0;
    var window: [ZLIB_WINDOW]u8 = .{0} ** ZLIB_WINDOW;
    var win_pos: usize = 0;
    var out_pos: usize = 0;

    // Inline readBits macro: reads n bits from the bit buffer
    while (true) {
        const sym = blk: {
            // Read 9 bits (literal/length code from fixed table)
            while (bits_in < 9) {
                if (pos < deflate_data.len) {
                    bit_buffer |= @as(u32, deflate_data[pos]) << bits_in;
                    pos += 1;
                    bits_in += 8;
                } else {
                    break :blk 256;
                }
            }
            const s = bit_buffer & 0x1FF;
            bit_buffer >>= 9;
            bits_in -= 9;
            break :blk ll_table[@as(usize, s)];
        };
        if (sym == 256) break;

        if (sym >= 0) {
            if (out_pos >= output.len) return out_pos;
            output[out_pos] = @as(u8, @intCast(sym));
            window[win_pos % ZLIB_WINDOW] = @as(u8, @intCast(sym));
            win_pos += 1;
            out_pos += 1;
        } else {
            const lit = sym - 257;
            var len = length_base[@as(usize, @intCast(@max(lit, 0)))];
            if (lit >= 8 and lit <= 15) {
                while (bits_in < (blk2: { const b: u32 = @as(u32, @intCast(lit - 8)) + 1; break :blk2 b; })) {
                    if (pos < deflate_data.len) {
                        bit_buffer |= @as(u32, deflate_data[pos]) << bits_in;
                        pos += 1;
                        bits_in += 8;
                    }
                }
                len += bit_buffer & ((1 << (@as(u32, @intCast(lit - 8)) + 1)) - 1);
                bit_buffer >>= (@as(u32, @intCast(lit - 8)) + 1);
                bits_in -= (@as(u32, @intCast(lit - 8)) + 1);
            }

            while (bits_in < 5) {
                if (pos < deflate_data.len) {
                    bit_buffer |= @as(u32, deflate_data[pos]) << bits_in;
                    pos += 1;
                    bits_in += 8;
                }
            }
            const d_sym = dist_table[@as(usize, bit_buffer & 0x1F)];
            bit_buffer >>= 5;
            bits_in -= 5;

            var dist = dist_base[@as(usize, @intCast(@max(d_sym, 0)))];
            if (d_sym >= 4) {
                while (bits_in < (blk3: { const b: u32 = @as(u32, @intCast(d_sym / 2)) + 1; break :blk3 b; })) {
                    if (pos < deflate_data.len) {
                        bit_buffer |= @as(u32, deflate_data[pos]) << bits_in;
                        pos += 1;
                        bits_in += 8;
                    }
                }
                dist += bit_buffer & ((1 << (@as(u32, @intCast(d_sym / 2)) + 1)) - 1);
                bit_buffer >>= (@as(u32, @intCast(d_sym / 2)) + 1);
                bits_in -= (@as(u32, @intCast(d_sym / 2)) + 1);
            }

            var k: u32 = 0;
            while (k < len) : (k += 1) {
                if (out_pos >= output.len) return out_pos;
                const si = (win_pos - dist + ZLIB_WINDOW) % ZLIB_WINDOW;
                const byte = window[si];
                output[out_pos] = byte;
                window[win_pos % ZLIB_WINDOW] = byte;
                win_pos += 1;
                out_pos += 1;
            }
        }

        if (out_pos >= output.len) break;
    }

    return out_pos;
}

// ── PNG decoder ─────────────────────────────────────────

const PNG_SIGNATURE = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

const CHUNK_IHDR: u32 = 0x49484452;
const CHUNK_IDAT: u32 = 0x49444154;
const CHUNK_IEND: u32 = 0x49454E44;
const CHUNK_PLTE: u32 = 0x504C5445;

pub const PngResult = struct {
    width: u32,
    height: u32,
    rgba: [*]u8,
    rgba_len: usize,
    ok: bool,
};

pub fn decodePng(data: []const u8) PngResult {
    if (data.len < 8) return .{ .width = 0, .height = 0, .rgba = undefined, .rgba_len = 0, .ok = false };
    if (!std.mem.eql(u8, data[0..8], &PNG_SIGNATURE)) return .{ .width = 0, .height = 0, .rgba = undefined, .rgba_len = 0, .ok = false };

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var has_plte: bool = false;
    var palette: [256]color_mod.Color = .{0} ** 256;
    var palette_count: u32 = 0;

    // 使用 bump allocator 收集 IDAT 数据
    var idat_buf: [512 * 1024]u8 = .{0} ** (512 * 1024);
    var idat_len: usize = 0;

    while (pos < data.len) {
        if (pos + 12 > data.len) break;
        const chunk_len = @as(u32, data[pos]) << 24 | @as(u32, data[pos + 1]) << 16 | @as(u32, data[pos + 2]) << 8 | @as(u32, data[pos + 3]);
        const chunk_type = @as(u32, data[pos + 4]) << 24 | @as(u32, data[pos + 5]) << 16 | @as(u32, data[pos + 6]) << 8 | @as(u32, data[pos + 7]);
        const chunk_start = pos + 8;
        const chunk_end = chunk_start + chunk_len;
        if (chunk_end > data.len) break;

        switch (chunk_type) {
            CHUNK_IHDR => {
                if (chunk_len < 13) return .{ .width = 0, .height = 0, .rgba = undefined, .rgba_len = 0, .ok = false };
                width = @as(u32, data[chunk_start]) << 24 | @as(u32, data[chunk_start + 1]) << 16 | @as(u32, data[chunk_start + 2]) << 8 | @as(u32, data[chunk_start + 3]);
                height = @as(u32, data[chunk_start + 4]) << 24 | @as(u32, data[chunk_start + 5]) << 16 | @as(u32, data[chunk_start + 6]) << 8 | @as(u32, data[chunk_start + 7]);
                bit_depth = data[chunk_start + 8];
                color_type = data[chunk_start + 9];
            },
            CHUNK_PLTE => {
                palette_count = @min(chunk_len / 3, 256);
                var i: u32 = 0;
                while (i < palette_count) : (i += 1) {
                    const r = data[chunk_start + i * 3 + 0];
                    const g = data[chunk_start + i * 3 + 1];
                    const b = data[chunk_start + i * 3 + 2];
                    palette[i] = (@as(color_mod.Color, r) << 16) | (@as(color_mod.Color, g) << 8) | @as(color_mod.Color, b);
                }
                has_plte = true;
            },
            CHUNK_IDAT => {
                if (idat_len + chunk_len < idat_buf.len) {
                    @memcpy(idat_buf[idat_len..][0..chunk_len], data[chunk_start..chunk_end]);
                    idat_len += chunk_len;
                }
            },
            CHUNK_IEND => {
                break;
            },
            else => {},
        }

        pos = chunk_end + 4;
    }

    if (width == 0 or height == 0 or idat_len == 0) {
        return .{ .width = 0, .height = 0, .rgba = undefined, .rgba_len = 0, .ok = false };
    }

    const row_bytes: usize = @intCast((@as(usize, width) * @as(usize, bit_depth) * @as(usize, if (color_type == 2) 3 else if (color_type == 6) 4 else 1) + 7) / 8);
    const scanline_len = row_bytes + 1;
    const decomp_len = @as(usize, height) * scanline_len;

    // 使用 bump allocator 分配解码缓冲区
    iconPngResetBuffers();
    const raw = iconPngAllocSlice(decomp_len) orelse return .{ .width = 0, .height = 0, .rgba = undefined, .rgba_len = 0, .ok = false };
    const rgba_len = @as(usize, width) * @as(usize, height) * 4;
    const rgba = iconPngAllocSlice(rgba_len) orelse return .{ .width = 0, .height = 0, .rgba = undefined, .rgba_len = 0, .ok = false };

    const actual = decompressZlib(idat_buf[0..idat_len], raw);
    if (actual == 0) {
        return .{ .width = 0, .height = 0, .rgba = undefined, .rgba_len = 0, .ok = false };
    }

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const scanline_off = @as(usize, y) * scanline_len;
        const scanline = raw[scanline_off + 1 .. scanline_off + 1 + row_bytes];

        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const out_idx = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
            const px_bytes: usize = if (color_type == 6) 4 else if (color_type == 2) 3 else 1;
            const raw_idx = @as(usize, x) * px_bytes;

            var r: u32 = 0;
            var g: u32 = 0;
            var b: u32 = 0;
            var a: u32 = 255;

            if (color_type == 6) {
                if (raw_idx + 3 < scanline.len) {
                    r = scanline[raw_idx + 0];
                    g = scanline[raw_idx + 1];
                    b = scanline[raw_idx + 2];
                    a = scanline[raw_idx + 3];
                }
            } else if (color_type == 2) {
                if (raw_idx + 2 < scanline.len) {
                    r = scanline[raw_idx + 0];
                    g = scanline[raw_idx + 1];
                    b = scanline[raw_idx + 2];
                }
            } else if (color_type == 0 or color_type == 3) {
                if (raw_idx < scanline.len) {
                    const idx = scanline[raw_idx];
                    if (color_type == 3 and has_plte and idx < palette_count) {
                        const c = palette[idx];
                        r = (c >> 16) & 0xFF;
                        g = (c >> 8) & 0xFF;
                        b = c & 0xFF;
                    } else {
                        r = idx;
                        g = idx;
                        b = idx;
                    }
                }
            }

            rgba[out_idx + 0] = @as(u8, @intCast(@min(r, 255)));
            rgba[out_idx + 1] = @as(u8, @intCast(@min(g, 255)));
            rgba[out_idx + 2] = @as(u8, @intCast(@min(b, 255)));
            rgba[out_idx + 3] = @as(u8, @intCast(@min(a, 255)));
        }
    }

    return .{
        .width = width,
        .height = height,
        .rgba = rgba.ptr,
        .rgba_len = rgba_len,
        .ok = true,
    };
}

// ── Public rendering API ────────────────────────────────

/// Blit a decoded RGBA texture to the screen at the given position,
/// optionally scaled using nearest-neighbor.
pub fn blitTexture(x: i32, y: i32, tex: *const Texture, dst_w: ?u32, dst_h: ?u32) void {
    const tw = dst_w orelse tex.width;
    const th = dst_h orelse tex.height;
    if (tw == tex.width and th == tex.height) {
        graphics.blitImage(x, y, tex.width, tex.height, tex.rgba);
    } else {
        graphics.blitImageScaled(x, y, tw, th, tex.width, tex.height, tex.rgba);
    }
}

/// Blit a texture with a tint color applied (multiplies RGB channels).
pub fn blitTextureWithTint(x: i32, y: i32, tex: *const Texture, tint: color_mod.Color, dst_w: ?u32, dst_h: ?u32) void {
    const tw = dst_w orelse tex.width;
    const th = dst_h orelse tex.height;
    const tint_r: u8 = @intCast((tint >> 16) & 0xFF);
    const tint_g: u8 = @intCast((tint >> 8) & 0xFF);
    const tint_b: u8 = @intCast(tint & 0xFF);

    if (tw == tex.width and th == tex.height) {
        var py: u32 = 0;
        while (py < tex.height) : (py += 1) {
            var px: u32 = 0;
            while (px < tex.width) : (px += 1) {
                const pi = @as(usize, py) * tex.width * 4 + @as(usize, px) * 4;
                const src_a = tex.rgba[pi + 3];
                if (src_a == 0) continue;

                const dx = x + @as(i32, @intCast(px));
                const dy = y + @as(i32, @intCast(py));

                if (src_a == 255) {
                    const out_r = @as(u32, tex.rgba[pi + 0]) * @as(u32, tint_r) / 255;
                    const out_g = @as(u32, tex.rgba[pi + 1]) * @as(u32, tint_g) / 255;
                    const out_b = @as(u32, tex.rgba[pi + 2]) * @as(u32, tint_b) / 255;
                    graphics.putPixel(dx, dy, (@as(Color, @intCast(@min(out_r, 255))) << 16) | (@as(Color, @intCast(@min(out_g, 255))) << 8) | @as(Color, @intCast(@min(out_b, 255))));
                } else {
                    const bg = graphics.getPixel(dx, dy);
                    const bg_r: u32 = (bg >> 16) & 0xFF;
                    const bg_g: u32 = (bg >> 8) & 0xFF;
                    const bg_b: u32 = bg & 0xFF;
                    const f: u32 = @as(u32, src_a);
                    const r1 = @as(u32, tex.rgba[pi + 0]) * @as(u32, tint_r) / 255;
                    const g1 = @as(u32, tex.rgba[pi + 1]) * @as(u32, tint_g) / 255;
                    const b1 = @as(u32, tex.rgba[pi + 2]) * @as(u32, tint_b) / 255;
                    graphics.putPixel(dx, dy, (@as(Color, @intCast((r1 * f + bg_r * (255 - f)) / 255)) << 16) | (@as(Color, @intCast((g1 * f + bg_g * (255 - f)) / 255)) << 8) | @as(Color, @intCast((b1 * f + bg_b * (255 - f)) / 255)));
                }
            }
        }
    } else {
        var dst_y: u32 = 0;
        while (dst_y < th) : (dst_y += 1) {
            const src_y = (@as(u32, @intCast(dst_y)) * tex.height) / th;
            var dst_x: u32 = 0;
            while (dst_x < tw) : (dst_x += 1) {
                const src_x = (@as(u32, @intCast(dst_x)) * tex.width) / tw;
                const pi = @as(usize, src_y) * tex.width * 4 + @as(usize, src_x) * 4;
                const src_a = tex.rgba[pi + 3];
                if (src_a == 0) continue;

                const dx = x + @as(i32, @intCast(dst_x));
                const dy = y + @as(i32, @intCast(dst_y));

                if (src_a == 255) {
                    const out_r = @as(u32, tex.rgba[pi + 0]) * @as(u32, tint_r) / 255;
                    const out_g = @as(u32, tex.rgba[pi + 1]) * @as(u32, tint_g) / 255;
                    const out_b = @as(u32, tex.rgba[pi + 2]) * @as(u32, tint_b) / 255;
                    graphics.putPixel(dx, dy, (@as(Color, @intCast(@min(out_r, 255))) << 16) | (@as(Color, @intCast(@min(out_g, 255))) << 8) | @as(Color, @intCast(@min(out_b, 255))));
                } else {
                    const bg = graphics.getPixel(dx, dy);
                    const bg_r: u32 = (bg >> 16) & 0xFF;
                    const bg_g: u32 = (bg >> 8) & 0xFF;
                    const bg_b: u32 = bg & 0xFF;
                    const f: u32 = @as(u32, src_a);
                    const r1 = @as(u32, tex.rgba[pi + 0]) * @as(u32, tint_r) / 255;
                    const g1 = @as(u32, tex.rgba[pi + 1]) * @as(u32, tint_g) / 255;
                    const b1 = @as(u32, tex.rgba[pi + 2]) * @as(u32, tint_b) / 255;
                    graphics.putPixel(dx, dy, (@as(Color, @intCast((r1 * f + bg_r * (255 - f)) / 255)) << 16) | (@as(Color, @intCast((g1 * f + bg_g * (255 - f)) / 255)) << 8) | @as(Color, @intCast((b1 * f + bg_b * (255 - f)) / 255)));
                }
            }
        }
    }
}
