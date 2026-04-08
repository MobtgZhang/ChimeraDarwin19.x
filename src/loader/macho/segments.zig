/// Segment Loader — maps Mach-O segments into a task's virtual address space.
/// Handles __TEXT, __DATA, __LINKEDIT and other standard segments.

const log = @import("../../lib/log.zig");
const parser = @import("parser.zig");

pub const LoadError = error{
    NoTextSegment,
    MappingFailed,
    InvalidSegment,
};

pub const SegmentInfo = struct {
    name: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    prot: u8,
};

pub const MAX_SEGMENTS: usize = 32;

pub const LoadedImage = struct {
    segments: [MAX_SEGMENTS]SegmentInfo,
    segment_count: usize,
    entry_point: u64,
    text_base: u64,
    text_size: u64,
    data_base: u64,
    data_size: u64,
    slide: u64,

    pub fn findSegment(self: *const LoadedImage, name: []const u8) ?*const SegmentInfo {
        for (self.segments[0..self.segment_count]) |*seg| {
            var slen: usize = 0;
            while (slen < 16 and seg.name[slen] != 0) slen += 1;
            if (slen == name.len and eql(seg.name[0..slen], name)) return seg;
        }
        return null;
    }
};

pub fn loadSegments(result: parser.ParseResult, slide: u64) LoadError!LoadedImage {
    var image = LoadedImage{
        .segments = undefined,
        .segment_count = 0,
        .entry_point = 0,
        .text_base = 0,
        .text_size = 0,
        .data_base = 0,
        .data_size = 0,
        .slide = slide,
    };

    var iter = parser.LoadCommandIterator.init(result);
    while (iter.next()) |lc| {
        if (parser.LoadCommandIterator.asSegment(lc)) |seg| {
            if (image.segment_count >= MAX_SEGMENTS) break;
            const idx = image.segment_count;
            image.segments[idx] = .{
                .name = seg.segname,
                .vmaddr = seg.vmaddr + slide,
                .vmsize = seg.vmsize,
                .fileoff = seg.fileoff,
                .filesize = seg.filesize,
                .prot = protFromMach(seg.initprot),
            };
            image.segment_count += 1;

            const seg_name = seg.getSegName();
            if (eql(seg_name, "__TEXT")) {
                image.text_base = seg.vmaddr + slide;
                image.text_size = seg.vmsize;
            } else if (eql(seg_name, "__DATA") or eql(seg_name, "__DATA_CONST")) {
                if (image.data_base == 0) {
                    image.data_base = seg.vmaddr + slide;
                    image.data_size = seg.vmsize;
                }
            }
        }
    }

    if (image.text_base == 0) return LoadError.NoTextSegment;

    if (parser.findEntryPoint(result)) |ep_off| {
        image.entry_point = image.text_base + ep_off;
    }

    log.info("Loaded {} segments, entry=0x{x}, slide=0x{x}", .{
        image.segment_count, image.entry_point, slide,
    });
    return image;
}

pub fn mapSegmentContent(
    image: *const LoadedImage,
    file_base: [*]const u8,
    seg_idx: usize,
) bool {
    if (seg_idx >= image.segment_count) return false;
    const seg = &image.segments[seg_idx];
    if (seg.filesize == 0) return true;

    const src = file_base + @as(usize, @intCast(seg.fileoff));
    const dst: [*]u8 = @ptrFromInt(seg.vmaddr);
    const copy_len: usize = @intCast(@min(seg.filesize, seg.vmsize));

    @memcpy(dst[0..copy_len], src[0..copy_len]);

    if (seg.vmsize > seg.filesize) {
        const zero_start: usize = @intCast(seg.filesize);
        const zero_len: usize = @intCast(seg.vmsize - seg.filesize);
        @memset(dst[zero_start..][0..zero_len], 0);
    }

    return true;
}

pub fn applySlide(
    image: *const LoadedImage,
    rebase_data: ?[*]const u8,
    rebase_size: usize,
) void {
    if (image.slide == 0) return;
    if (rebase_data == null or rebase_size == 0) return;

    const data = rebase_data.?;
    var offset: usize = 0;
    var seg_idx: u8 = 0;
    var seg_off: u64 = 0;

    const REBASE_OPCODE_MASK: u8 = 0xF0;
    const REBASE_IMMEDIATE_MASK: u8 = 0x0F;
    const REBASE_OPCODE_DONE: u8 = 0x00;
    const REBASE_OPCODE_SET_SEGMENT: u8 = 0x10;
    const REBASE_OPCODE_ADD_ADDR: u8 = 0x30;
    const REBASE_OPCODE_DO_REBASE: u8 = 0x50;
    const REBASE_OPCODE_DO_REBASE_4: u8 = 0x51;
    const REBASE_OPCODE_DO_REBASE_8: u8 = 0x52;

    while (offset < rebase_size) {
        const byte = data[offset];
        offset += 1;
        const opcode = byte & REBASE_OPCODE_MASK;
        const imm = byte & REBASE_IMMEDIATE_MASK;

        switch (opcode) {
            REBASE_OPCODE_DONE => break,
            REBASE_OPCODE_SET_SEGMENT => {
                seg_idx = imm;
                seg_off = 0;
            },
            REBASE_OPCODE_ADD_ADDR => {
                seg_off += readULEB128(data, &offset);
            },
            REBASE_OPCODE_DO_REBASE => {
                if (seg_idx < image.segment_count) {
                    const addr = image.segments[seg_idx].vmaddr + seg_off;
                    const ptr: *u64 = @ptrFromInt(addr);
                    ptr.* += image.slide;
                    seg_off += 8;
                }
            },
            REBASE_OPCODE_DO_REBASE_4 => {
                if (seg_idx < image.segment_count) {
                    const addr = image.segments[seg_idx].vmaddr + seg_off;
                    const ptr: *u32 = @ptrFromInt(addr);
                    ptr.* +%= @intCast(image.slide);
                    seg_off += 4;
                }
            },
            REBASE_OPCODE_DO_REBASE_8 => {
                if (seg_idx < image.segment_count) {
                    const addr = image.segments[seg_idx].vmaddr + seg_off;
                    const ptr: *u64 = @ptrFromInt(addr);
                    ptr.* += image.slide;
                    seg_off += 8;
                }
            },
            else => {},
        }
    }
}

pub fn dumpImage(image: *const LoadedImage) void {
    log.info("=== Loaded Image ===", .{});
    log.info("  Entry: 0x{x}  Slide: 0x{x}", .{ image.entry_point, image.slide });
    for (image.segments[0..image.segment_count]) |*seg| {
        var slen: usize = 0;
        while (slen < 16 and seg.name[slen] != 0) slen += 1;
        log.info("  {s}: vm=0x{x}+0x{x} file=0x{x}+0x{x} prot={}", .{
            seg.name[0..slen], seg.vmaddr, seg.vmsize,
            seg.fileoff, seg.filesize, seg.prot,
        });
    }
}

fn protFromMach(prot: i32) u8 {
    var result: u8 = 0;
    if (prot & 0x01 != 0) result |= 0x01;
    if (prot & 0x02 != 0) result |= 0x02;
    if (prot & 0x04 != 0) result |= 0x04;
    return result;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (ca != cb) return false;
    return true;
}

fn readULEB128(data: [*]const u8, offset: *usize) u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = data[offset.*];
        offset.* += 1;
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
    }
    return result;
}
