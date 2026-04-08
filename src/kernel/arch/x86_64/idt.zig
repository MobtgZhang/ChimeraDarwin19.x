const std = @import("std");
const gdt = @import("gdt.zig");
const serial = @import("serial.zig");

const IdtEntry = packed struct(u128) {
    offset_low: u16,
    selector: u16,
    ist: u3 = 0,
    reserved0: u5 = 0,
    gate_type: u4,
    zero: u1 = 0,
    dpl: u2,
    present: u1,
    offset_mid: u16,
    offset_high: u32,
    reserved1: u32 = 0,
};

const IdtPtr = packed struct {
    limit: u16,
    base: u64,
};

const NUM_VECTORS = 256;

var idt_entries: [NUM_VECTORS]IdtEntry = std.mem.zeroes([NUM_VECTORS]IdtEntry);
var idt_ptr: IdtPtr = undefined;

const EXCEPTION_NAMES = [_][]const u8{
    "Division Error",
    "Debug",
    "NMI",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "Reserved",
    "x87 FP Exception",
    "Alignment Check",
    "Machine Check",
    "SIMD FP Exception",
    "Virtualization Exception",
    "Control Protection Exception",
};

fn setGate(vector: u8, handler: usize, ist: u3, gate_type: u4, dpl: u2) void {
    idt_entries[vector] = .{
        .offset_low = @truncate(handler),
        .selector = gdt.KERNEL_CS,
        .ist = ist,
        .gate_type = gate_type,
        .dpl = dpl,
        .present = 1,
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
    };
}

pub fn init() void {
    const handler_addr = @intFromPtr(&defaultExceptionHandler);

    // Set up default handlers for all CPU exception vectors (0-31)
    for (0..32) |i| {
        setGate(@intCast(i), handler_addr, 0, 0xE, 0);
    }

    // Set remaining interrupt vectors (32-255) to default handler
    for (32..NUM_VECTORS) |i| {
        setGate(@intCast(i), handler_addr, 0, 0xE, 0);
    }

    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt_entries)) - 1,
        .base = @intFromPtr(&idt_entries),
    };

    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&idt_ptr),
        : .{ .memory = true }
    );
}

fn defaultExceptionHandler() callconv(.naked) void {
    asm volatile (
        \\cli
        \\1: hlt
        \\jmp 1b
    );
}
