const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const SpinLock = @import("spinlock.zig").SpinLock;

const serial = switch (builtin.cpu.arch) {
    .x86_64 => @import("../kernel/arch/x86_64/serial.zig"),
    .aarch64 => @import("../kernel/arch/aarch64/serial.zig"),
    .riscv64 => @import("../kernel/arch/riscv64/serial.zig"),
    .loongarch64 => @import("../kernel/arch/loong64/serial.zig"),
    else => @compileError("Unsupported architecture for logging"),
};

/// P0 FIX: Global lock for thread-safe logging
var log_lock: SpinLock = .{};

/// P2 FIX: Log level enum for internal implementation
const LogLevel = enum {
    info,
    warn,
    err,
    debug,
};

/// P0 FIX: Thread-safe internal helper function
fn logImpl(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (comptime !build_options.enable_logging) return;
    
    const prefix = switch (level) {
        .info => "[INFO] ",
        .warn => "[WARN] ",
        .err => "[ERR]  ",
        .debug => "[DBG]  ",
    };
    
    // P0 FIX: Acquire lock before writing to serial
    log_lock.acquire();
    defer log_lock.release();
    
    var buf: [1024]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, fmt, args) catch {
        serial.writeString(prefix);
        serial.writeString("[log fmt error]");
        serial.writeString("\r\n");
        return;
    };
    
    serial.writeString(prefix);
    serial.writeString(result);
    serial.writeString("\r\n");
}

/// P2 FIX: Consolidated log functions using helper
pub fn info(comptime fmt: []const u8, args: anytype) void {
    logImpl(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    logImpl(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    logImpl(.err, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    logImpl(.debug, fmt, args);
}
