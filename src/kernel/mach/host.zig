/// Mach Host — provides host-level information and privileged operations.
/// Implements host_priv, host_security, and machine information.

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;
const builtin = @import("builtin");

pub const HOST_PORT_NAME: u32 = 1;
pub const HOST_PRIV_PORT_NAME: u32 = 2;
pub const HOST_SECURITY_PORT_NAME: u32 = 3;
pub const HOST_DEFAULT_PORT_NAME: u32 = 4;

pub const MAX_CPUS: usize = 64;

/// Processor info
pub const ProcessorInfo = struct {
    id: u32,
    cpu_type: u32,
    cpu_subtype: u32,
    running: bool,
    current_thread: u32,
    active: bool,
};

/// Host basic info
pub const HostBasicInfo = extern struct {
    info_size: u32,
    cpu_type: u32,
    cpu_subtype: u32,
    max_cpus: u32,
    av_cpus: u32,
    memory_size: u64,
    cpu_freq: u64,
    bus_freq: u64,
};

/// Host clock info
pub const HostClockInfo = struct {
    sec: u32,
    usec: u32,
};

/// Machine type constants
pub const CPU_TYPE_X86_64: i32 = 0x01000007;
pub const CPU_TYPE_ARM64: i32 = 0x0100000C;

var host_initialized: bool = false;
var processors: [MAX_CPUS]ProcessorInfo = undefined;
var processor_count: u32 = 0;
var host_lock: SpinLock = .{};

pub fn init() void {
    host_initialized = true;
    processor_count = 1;

    for (&processors) |*p| {
        p.* = .{
            .id = 0,
            .cpu_type = getCpuType(),
            .cpu_subtype = 0,
            .running = true,
            .current_thread = 0,
            .active = false,
        };
    }

    processors[0].active = true;
    log.info("Mach Host subsystem initialized", .{});
}

fn getCpuType() u32 {
    return switch (builtin.cpu.arch) {
        .x86_64 => CPU_TYPE_X86_64,
        .aarch64 => CPU_TYPE_ARM64,
        else => 0,
    };
}

/// Get host basic info
pub fn getHostBasicInfo() HostBasicInfo {
    const mem_size: u64 = 256 * 1024 * 1024;
    return .{
        .info_size = @sizeOf(HostBasicInfo),
        .cpu_type = @intCast(getCpuType()),
        .cpu_subtype = 0,
        .max_cpus = @intCast(MAX_CPUS),
        .av_cpus = processor_count,
        .memory_size = mem_size,
        .cpu_freq = 2_000_000_000,
        .bus_freq = 100_000_000,
    };
}

/// Get processor count
pub fn getProcessorCount() u32 {
    return processor_count;
}

/// Get processor info by id
pub fn getProcessorInfo(id: u32) ?ProcessorInfo {
    if (id >= MAX_CPUS) return null;
    if (!processors[id].active) return null;
    return processors[id];
}

/// Get machine type string
pub fn getMachineType() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        .riscv64 => "riscv64",
        .loongarch64 => "loongarch64",
        else => "unknown",
    };
}

/// Get OS version string
pub fn getOsVersion() []const u8 {
    return "Darwin 19.6.0";
}

/// Get OS build string
pub fn getOsBuild() []const u8 {
    return "Darwin Kernel Version 19.6.0";
}

/// Get kernel version
pub fn getKernelVersion() []const u8 {
    return "XNU 19.6.0";
}

/// Read host time
pub fn readHostTime() HostClockInfo {
    return .{
        .sec = 0,
        .usec = 0,
    };
}

/// Get CPU type for current architecture
pub fn getHostCpuType() u32 {
    return @intCast(getCpuType());
}

/// Get CPU subtype
pub fn getHostCpuSubtype() u32 {
    return 0;
}
