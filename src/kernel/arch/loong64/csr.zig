/// LoongArch64 Control and Status Register (CSR) definitions and accessors.
/// Covers all CSR numbers needed for kernel-mode operation on LA464 (3A5000)
/// and LA664 (3A6000/2K3000) cores.

const std = @import("std");

// ── CSR number definitions ──────────────────────────────────

pub const CRMD: u14 = 0x0; // Current Mode: PLV, IE, DA, PG
pub const PRMD: u14 = 0x1; // Pre-exception Mode
pub const EUEN: u14 = 0x2; // Extended Unit Enable (FPU, LSX, LASX, LBT)
pub const MISC: u14 = 0x3; // Miscellaneous Control
pub const ECFG: u14 = 0x4; // Exception Configuration (VS, LIE)
pub const ESTAT: u14 = 0x5; // Exception Status (IS, Ecode, EsubCode)
pub const ERA: u14 = 0x6; // Exception Return Address
pub const BADV: u14 = 0x7; // Bad Virtual Address
pub const BADI: u14 = 0x8; // Bad Instruction
pub const EENTRY: u14 = 0xC; // Exception Entry Base

pub const TLBIDX: u14 = 0x10; // TLB Index
pub const TLBEHI: u14 = 0x11; // TLB Entry High
pub const TLBELO0: u14 = 0x12; // TLB Entry Low 0
pub const TLBELO1: u14 = 0x13; // TLB Entry Low 1
pub const ASID: u14 = 0x18; // Address Space ID
pub const PGDL: u14 = 0x19; // Page Global Directory Low
pub const PGDH: u14 = 0x1A; // Page Global Directory High
pub const PGD: u14 = 0x1B; // Page Global Directory (read-only)
pub const PWCL: u14 = 0x1C; // Page Walk Controller Low
pub const PWCH: u14 = 0x1D; // Page Walk Controller High

pub const CPUID: u14 = 0x20; // CPU Identifier
pub const PRCFG1: u14 = 0x21; // Processor Config 1 (STLB ways/sets)
pub const PRCFG2: u14 = 0x22; // Processor Config 2 (TLB page sizes)
pub const PRCFG3: u14 = 0x23; // Processor Config 3

pub const SAVE0: u14 = 0x30;
pub const SAVE1: u14 = 0x31;
pub const SAVE2: u14 = 0x32;
pub const SAVE3: u14 = 0x33;

pub const TID: u14 = 0x40; // Timer ID
pub const TCFG: u14 = 0x41; // Timer Configuration
pub const TVAL: u14 = 0x42; // Timer Value (countdown)
pub const CNTC: u14 = 0x43; // Counter Compensation
pub const TICLR: u14 = 0x44; // Timer Interrupt Clear

pub const LLBCTL: u14 = 0x60; // LL-SC Bit Control

pub const TLBRENTRY: u14 = 0x88; // TLB Refill Exception Entry
pub const TLBRBADV: u14 = 0x89;
pub const TLBRERA: u14 = 0x8A;
pub const TLBRSAVE: u14 = 0x8B;
pub const TLBRELO0: u14 = 0x8C;
pub const TLBRELO1: u14 = 0x8D;
pub const TLBREHI: u14 = 0x8E;
pub const TLBRPRMD: u14 = 0x8F;

pub const DMW0: u14 = 0x180; // Direct Map Window 0
pub const DMW1: u14 = 0x181; // Direct Map Window 1
pub const DMW2: u14 = 0x182; // Direct Map Window 2
pub const DMW3: u14 = 0x183; // Direct Map Window 3

// ── CRMD field masks ────────────────────────────────────────

pub const CRMD_PLV_MASK: u64 = 0x3; // Privilege Level (0=kernel, 3=user)
pub const CRMD_IE: u64 = 1 << 2; // Global Interrupt Enable
pub const CRMD_DA: u64 = 1 << 3; // Direct Address translation
pub const CRMD_PG: u64 = 1 << 4; // Paging enable
pub const CRMD_DATF: u64 = 0x3 << 5; // DA Translation mode for Fetch
pub const CRMD_DATM: u64 = 0x3 << 7; // DA Translation mode for Memory

// ── ECFG field masks ────────────────────────────────────────

pub const ECFG_VS_MASK: u64 = 0x7 << 16; // Exception vector spacing
pub const ECFG_LIE_MASK: u64 = 0x1FFF; // Local Interrupt Enable (13 bits)
pub const ECFG_LIE_TI: u64 = 1 << 11; // Timer interrupt enable
pub const ECFG_LIE_IPI: u64 = 1 << 12; // IPI interrupt enable

// ── ESTAT field masks ───────────────────────────────────────

pub const ESTAT_IS_MASK: u64 = 0x1FFF; // Interrupt Status (13 bits)
pub const ESTAT_IS_TI: u64 = 1 << 11; // Timer interrupt status
pub const ESTAT_ECODE_MASK: u64 = 0x3F << 16; // Exception code
pub const ESTAT_ESUBCODE_MASK: u64 = 0x1FF << 22; // Exception sub-code

// ── EUEN field masks ────────────────────────────────────────

pub const EUEN_FPE: u64 = 1 << 0; // FP unit enable
pub const EUEN_SXE: u64 = 1 << 1; // 128-bit SIMD (LSX) enable
pub const EUEN_ASXE: u64 = 1 << 2; // 256-bit SIMD (LASX) enable
pub const EUEN_BTE: u64 = 1 << 3; // Binary Translation enable

// ── TCFG field masks ───────────────────────────────────────

pub const TCFG_EN: u64 = 1 << 0; // Timer enable
pub const TCFG_PERIODIC: u64 = 1 << 1; // Periodic mode (vs one-shot)
pub const TCFG_INITVAL_SHIFT: u6 = 2; // Initial value shift

// ── TICLR field masks ──────────────────────────────────────

pub const TICLR_CLR: u64 = 1 << 0; // Clear timer interrupt

// ── DMW field layout ───────────────────────────────────────
// [63:60] VSEG  — virtual segment number (high 4 bits of VA must match)
// [5:4]   MAT   — Memory Access Type (0=strongly ordered uncached,
//                  1=coherent cached)
// [3]     PLVX  — PLV3 access allowed
// [2]     unused
// [1]     PLV0  — PLV0 access allowed
// [0]     PLV0  — (duplicate in some docs; bit 0 = enable for PLV0)

pub const DMW_PLV0: u64 = 1 << 0;
pub const DMW_PLV3: u64 = 1 << 3;
pub const DMW_MAT_CC: u64 = 1 << 4; // Coherent Cached
pub const DMW_MAT_SUC: u64 = 0 << 4; // Strongly-ordered Uncached

pub inline fn dmwVseg(seg: u4) u64 {
    return @as(u64, seg) << 60;
}

// ── CSR access primitives ───────────────────────────────────

pub inline fn read(comptime csr_num: u14) u64 {
    return asm volatile ("csrrd %[ret], " ++ std.fmt.comptimePrint("{}", .{csr_num})
        : [ret] "=r" (-> u64),
    );
}

pub inline fn write(comptime csr_num: u14, value: u64) void {
    var val = value;
    asm volatile ("csrwr %[val], " ++ std.fmt.comptimePrint("{}", .{csr_num})
        : [val] "+r" (val),
    );
}

/// Atomic read-modify-write: new_csr = (old_csr & ~mask) | (value & mask).
/// Returns old CSR value.
pub inline fn xchg(comptime csr_num: u14, value: u64, mask: u64) u64 {
    var val = value;
    asm volatile ("csrxchg %[val], %[mask], " ++ std.fmt.comptimePrint("{}", .{csr_num})
        : [val] "+r" (val),
        : [mask] "r" (mask),
    );
    return val;
}
