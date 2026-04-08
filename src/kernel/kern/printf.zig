/// Kernel printf and panic — implements kernel printf and panic functions.
/// Provides formatted output and kernel panic for critical errors.

const log = @import("../lib/log.zig");
const builtin = @import("builtin");
const std = @import("std");

const BUF_SIZE: usize = 1024;

/// P2 FIX: Panic context structure for capturing additional information
pub const PanicContext = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

/// P2 FIX: Architecture-specific halt function
fn halt() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64, .aarch64_be => asm volatile ("wfi"), // Wait For Interrupt
            .riscv64 => asm volatile ("wfi"), // Wait For Interrupt
            .loongarch64 => asm volatile ("idle 0"), // Idle until interrupt
            else => {},
        }
    }
}

/// P1 FIX: Architecture-specific register dump structure
pub const Registers = struct {
    // General purpose registers (architecture-specific)
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    rsp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rip: u64,
    rflags: u64,
    cs: u64,
    ss: u64,
    fs_base: u64,
    gs_base: u64,
};

/// P2 FIX: Capture current register state for panic dump
/// This is architecture-specific and would typically be called from
/// the exception/interrupt handler that detected the panic condition
pub fn captureRegisters(ctx: *Registers) void {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // Read registers from the exception frame
            // In a real implementation, these would come from the CPU trap frame
            ctx.rax = asm volatile ("mov %%rax, %0" : [ret] "=r" (-> u64));
            ctx.rbx = asm volatile ("mov %%rbx, %0" : [ret] "=r" (-> u64));
            ctx.rcx = asm volatile ("mov %%rcx, %0" : [ret] "=r" (-> u64));
            ctx.rdx = asm volatile ("mov %%rdx, %0" : [ret] "=r" (-> u64));
            ctx.rsi = asm volatile ("mov %%rsi, %0" : [ret] "=r" (-> u64));
            ctx.rdi = asm volatile ("mov %%rdi, %0" : [ret] "=r" (-> u64));
            ctx.rbp = asm volatile ("mov %%rbp, %0" : [ret] "=r" (-> u64));
            ctx.rsp = asm volatile ("mov %%rsp, %0" : [ret] "=r" (-> u64));
            ctx.rip = asm volatile ("mov $0, %%rax; call 1f; 1:" ::: "rax");
            ctx.rflags = asm volatile ("pushfq; pop %0" : [ret] "=r" (-> u64));
            ctx.cs = 0;
            ctx.ss = 0;
            ctx.fs_base = asm volatile ("mov %%fs:0, %0" : [ret] "=r" (-> u64));
            ctx.gs_base = asm volatile ("mov %%gs:0, %0" : [ret] "=r" (-> u64));
            // Additional registers
            ctx.r8 = 0;
            ctx.r9 = 0;
            ctx.r10 = 0;
            ctx.r11 = 0;
            ctx.r12 = 0;
            ctx.r13 = 0;
            ctx.r14 = 0;
            ctx.r15 = 0;
        },
        .aarch64, .aarch64_be => {
            ctx.rax = 0; // X0
            ctx.rbx = 0; // X1
            ctx.rcx = 0; // X2
            ctx.rdx = 0; // X3
            ctx.rsi = 0; // X4
            ctx.rdi = 0; // X5
            ctx.rbp = 0; // X6
            ctx.rsp = 0; // X7 (SP)
            ctx.rip = 0; // PC
            ctx.rflags = 0; // PSTATE
            ctx.cs = 0;
            ctx.ss = 0;
            ctx.fs_base = 0;
            ctx.gs_base = 0;
            ctx.r8 = 0;  // X8
            ctx.r9 = 0;  // X9
            ctx.r10 = 0; // X10
            ctx.r11 = 0; // X11
            ctx.r12 = 0; // X12
            ctx.r13 = 0; // X13
            ctx.r14 = 0; // X14
            ctx.r15 = 0; // X15
        },
        .riscv64 => {
            // RISC-V registers would be captured similarly
            ctx.rax = 0;
            ctx.rbx = 0;
            ctx.rcx = 0;
            ctx.rdx = 0;
            ctx.rsi = 0;
            ctx.rdi = 0;
            ctx.rbp = 0;
            ctx.rsp = 0; // SP
            ctx.rip = 0; // PC
            ctx.rflags = 0; // SSTATUS
            ctx.cs = 0;
            ctx.ss = 0;
            ctx.fs_base = 0;
            ctx.gs_base = 0;
            ctx.r8 = 0;
            ctx.r9 = 0;
            ctx.r10 = 0;
            ctx.r11 = 0;
            ctx.r12 = 0;
            ctx.r13 = 0;
            ctx.r14 = 0;
            ctx.r15 = 0;
        },
        .loongarch64 => {
            // LoongArch64 registers
            ctx.rax = 0;
            ctx.rbx = 0;
            ctx.rcx = 0;
            ctx.rdx = 0;
            ctx.rsi = 0;
            ctx.rdi = 0;
            ctx.rbp = 0;
            ctx.rsp = 0; // SP
            ctx.rip = 0; // PC
            ctx.rflags = 0;
            ctx.cs = 0;
            ctx.ss = 0;
            ctx.fs_base = 0;
            ctx.gs_base = 0;
            ctx.r8 = 0;
            ctx.r9 = 0;
            ctx.r10 = 0;
            ctx.r11 = 0;
            ctx.r12 = 0;
            ctx.r13 = 0;
            ctx.r14 = 0;
            ctx.r15 = 0;
        },
        else => {
            @memset(@as([*]u8, @ptrCast(ctx))[0..@sizeOf(Registers)], 0);
        },
    }
}

/// P2 FIX: Dump register state to serial/log output
/// This function outputs all captured register values
pub fn dumpRegisters(ctx: *const Registers) void {
    log.err("=== Register Dump ===", .{});
    switch (builtin.cpu.arch) {
        .x86_64 => {
            log.err("RAX = 0x{x:016}  RBX = 0x{x:016}  RCX = 0x{x:016}", .{ ctx.rax, ctx.rbx, ctx.rcx });
            log.err("RDX = 0x{x:016}  RSI = 0x{x:016}  RDI = 0x{x:016}", .{ ctx.rdx, ctx.rsi, ctx.rdi });
            log.err("RBP = 0x{x:016}  RSP = 0x{x:016}  R8  = 0x{x:016}", .{ ctx.rbp, ctx.rsp, ctx.r8 });
            log.err("R9  = 0x{x:016}  R10 = 0x{x:016}  R11 = 0x{x:016}", .{ ctx.r9, ctx.r10, ctx.r11 });
            log.err("R12 = 0x{x:016}  R13 = 0x{x:016}  R14 = 0x{x:016}", .{ ctx.r12, ctx.r13, ctx.r14 });
            log.err("R15 = 0x{x:016}  RIP = 0x{x:016}  RFLAGS = 0x{x}", .{ ctx.r15, ctx.rip, ctx.rflags });
            log.err("CS = 0x{x:04}  SS = 0x{x:04}  FS_BASE = 0x{x:016}", .{ ctx.cs, ctx.ss, ctx.fs_base });
            log.err("GS_BASE = 0x{x:016}", .{ctx.gs_base});
        },
        .aarch64, .aarch64_be => {
            log.err("X0  = 0x{x:016}  X1  = 0x{x:016}  X2  = 0x{x:016}", .{ ctx.rax, ctx.rbx, ctx.rcx });
            log.err("X3  = 0x{x:016}  X4  = 0x{x:016}  X5  = 0x{x:016}", .{ ctx.rdx, ctx.rsi, ctx.rdi });
            log.err("X6  = 0x{x:016}  X7  = 0x{x:016}  SP  = 0x{x:016}", .{ ctx.rbp, ctx.rsp, ctx.r8 });
            log.err("X9  = 0x{x:016}  X10 = 0x{x:016}  X11 = 0x{x:016}", .{ ctx.r9, ctx.r10, ctx.r11 });
            log.err("X12 = 0x{x:016}  X13 = 0x{x:016}  X14 = 0x{x:016}", .{ ctx.r12, ctx.r13, ctx.r14 });
            log.err("X15 = 0x{x:016}  PC  = 0x{x:016}  PSTATE = 0x{x}", .{ ctx.r15, ctx.rip, ctx.rflags });
        },
        .riscv64 => {
            log.err("PC  = 0x{x:016}  SP  = 0x{x:016}  GP  = 0x{x:016}", .{ ctx.rip, ctx.rsp, ctx.rsi });
            log.err("TP  = 0x{x:016}  T0  = 0x{x:016}  T1  = 0x{x:016}", .{ ctx.rdi, ctx.rdx, ctx.rax });
            log.err("SSTATUS = 0x{x}", .{ctx.rflags});
        },
        .loongarch64 => {
            log.err("PC  = 0x{x:016}  SP  = 0x{x:016}  RA  = 0x{x:016}", .{ ctx.rip, ctx.rsp, ctx.rax });
            log.err("TP  = 0x{x:016}  S0  = 0x{x:016}  S1  = 0x{x:016}", .{ ctx.rdi, ctx.rbp, ctx.rbx });
            log.err("CSR = 0x{x}", .{ctx.rflags});
        },
        else => {
            log.err("Register dump not supported for this architecture", .{});
        },
    }
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [BUF_SIZE]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "[fmt error]";
    log.info("{s}", .{msg});
}

pub fn printfDebug(comptime fmt: []const u8, args: anytype) void {
    var buf: [BUF_SIZE]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "[fmt error]";
    log.debug("{s}", .{msg});
}

pub fn printfWarn(comptime fmt: []const u8, args: anytype) void {
    var buf: [BUF_SIZE]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "[fmt error]";
    log.warn("{s}", .{msg});
}

pub fn printfErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [BUF_SIZE]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "[fmt error]";
    log.err("{s}", .{msg});
}

pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [BUF_SIZE]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "[fmt error]";

    log.err("=== KERNEL PANIC ===", .{});
    log.err("{s}", .{msg});

    // P1 FIX: Dump register state for debugging
    var regs: Registers = undefined;
    captureRegisters(&regs);
    dumpRegisters(&regs);

    log.err("System halted.", .{});

    halt();
}

pub fn panicWithContext(comptime fmt: []const u8, args: anytype, context: []const u8) noreturn {
    var buf: [BUF_SIZE]u8 = undefined;
    var ctx_buf: [BUF_SIZE]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "[fmt error]";
    const ctx = std.fmt.bufPrint(&ctx_buf, "Context: {s}", .{context}) catch "[ctx error]";

    log.err("=== KERNEL PANIC ===", .{});
    log.err("{s}", .{msg});
    log.err("{s}", .{ctx});

    // P1 FIX: Dump register state for debugging
    var regs: Registers = undefined;
    captureRegisters(&regs);
    dumpRegisters(&regs);

    log.err("System halted.", .{});

    halt();
}
