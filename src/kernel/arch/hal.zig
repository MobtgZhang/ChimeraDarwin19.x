/// Hardware Abstraction Layer — compile-time architecture dispatch.
/// Re-exports the architecture-specific HAL selected at compile time.

const builtin = @import("builtin");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("x86_64/hal.zig"),
    .aarch64 => @import("aarch64/hal.zig"),
    .riscv64 => @import("riscv64/hal.zig"),
    .loongarch64 => @import("loong64/hal.zig"),
    else => @compileError("Unsupported architecture for Darwin 19.x Z-Kernel"),
};

pub const name = impl.name;
pub const TimeInfo = impl.TimeInfo;

pub const earlyInit = impl.earlyInit;
pub const cpuInit = impl.cpuInit;
pub const timerInit = impl.timerInit;
pub const timerTick = impl.timerTick;
pub const inputInit = impl.inputInit;
pub const readTime = impl.readTime;
pub const cpuRelax = impl.cpuRelax;
pub const disableInterrupts = impl.disableInterrupts;
pub const enableInterrupts = impl.enableInterrupts;
pub const halt = impl.halt;
