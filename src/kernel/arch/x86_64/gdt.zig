const log = @import("../../../lib/log.zig");

const GdtEntry = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    limit_high: u4,
    flags: u4,
    base_high: u8,
};

const GdtPtr = packed struct {
    limit: u16,
    base: u64,
};

// Segment selectors (byte offsets into GDT)
pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x18;
pub const USER_DS: u16 = 0x20;

var gdt_entries: [5]GdtEntry = undefined;
var gdt_ptr: GdtPtr = undefined;

fn makeEntry(base: u32, limit: u20, access: u8, flags: u4) GdtEntry {
    return .{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = access,
        .limit_high = @truncate(limit >> 16),
        .flags = flags,
        .base_high = @truncate(base >> 24),
    };
}

pub fn init() void {
    // Entry 0: Null descriptor
    gdt_entries[0] = makeEntry(0, 0, 0, 0);

    // Entry 1: Kernel Code (64-bit, DPL=0)
    //   Access: P=1 DPL=00 S=1 Type=1010 → 0x9A
    //   Flags:  G=1 D=0 L=1 AVL=0 → 0xA
    gdt_entries[1] = makeEntry(0, 0xFFFFF, 0x9A, 0xA);

    // Entry 2: Kernel Data (64-bit, DPL=0)
    //   Access: P=1 DPL=00 S=1 Type=0010 → 0x92
    //   Flags:  G=1 D=1 L=0 AVL=0 → 0xC
    gdt_entries[2] = makeEntry(0, 0xFFFFF, 0x92, 0xC);

    // Entry 3: User Code (64-bit, DPL=3)
    //   Access: P=1 DPL=11 S=1 Type=1010 → 0xFA
    //   Flags:  G=1 D=0 L=1 AVL=0 → 0xA
    gdt_entries[3] = makeEntry(0, 0xFFFFF, 0xFA, 0xA);

    // Entry 4: User Data (64-bit, DPL=3)
    //   Access: P=1 DPL=11 S=1 Type=0010 → 0xF2
    //   Flags:  G=1 D=1 L=0 AVL=0 → 0xC
    gdt_entries[4] = makeEntry(0, 0xFFFFF, 0xF2, 0xC);

    gdt_ptr = .{
        .limit = @sizeOf(@TypeOf(gdt_entries)) - 1,
        .base = @intFromPtr(&gdt_entries),
    };

    asm volatile ("lgdt (%[ptr])"
        :
        : [ptr] "r" (&gdt_ptr),
        : .{ .memory = true }
    );

    reloadSegments();
}

fn reloadSegments() void {
    // Reload CS via far return
    asm volatile (
        \\pushq $0x08
        \\lea 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        ::: .{ .rax = true, .memory = true });

    // Reload data segment registers
    asm volatile (
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%ss
        \\xor %%ax, %%ax
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        ::: .{ .rax = true, .memory = true });
}
