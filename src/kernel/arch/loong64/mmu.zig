/// LoongArch64 MMU / TLB management with full PG (Paging) mode support.
///
/// LoongArch supports two address-translation modes controlled by CRMD:
///   DA=1, PG=0 : Direct Address — VA == PA (used at boot, no TLB)
///   DA=0, PG=1 : Paged — multi-level page table with STLB/MTLB
///
/// In addition, four Direct Map Windows (DMW0–DMW3) provide fixed
/// VA→PA mappings without TLB lookups, which is how the Linux kernel
/// maps its own linear address space on LoongArch.
///
/// At boot (QEMU -kernel), DA=1.  We switch to DMW-based mapping so
/// the kernel can access all physical memory through a known VA prefix
/// while leaving PG available for user-space later.
///
/// DMW0: 0x9000_xxxx_xxxx_xxxx → PA (Coherent Cached, PLV0)
/// DMW1: 0x8000_xxxx_xxxx_xxxx → PA (Strongly-ordered Uncached, PLV0)
/// 
/// This module provides:
///   - DMW (Direct Map Window) configuration for early boot
///   - PG (Paging) mode with 3-level page tables
///   - TLB operations (tlbfill, tlbwr, tlbr, tlbi)
///   - ASID management for TLB optimization
///   - Kernel virtual memory mapping

const csr = @import("csr.zig");
const log = @import("../../../lib/log.zig");
const pmm = @import("../../mm/pmm.zig");
const std = @import("std");

pub const PAGE_SIZE: usize = 4096; // 4 KB (16 KB optional on some cores)
pub const TABLE_ENTRIES: usize = 512;

var initialized: bool = false;

// ============================================================================
// Page Table Constants
// ============================================================================

/// LoongArch64 uses a 3-level page table:
///   Level 1: PGD (Page Global Directory) - indexed by bits [38:30]
///   Level 2: PMD (Page Middle Directory) - indexed by bits [29:21]
///   Level 3: PT  (Page Table)           - indexed by bits [20:12]

/// Virtual address layout for 48-bit VA with 4KB pages:
///   bits [63:48]  - sign extension (must match bit 47)
///   bits [47:39]  - PGD index (9 bits)
///   bits [38:30]  - PMD index (9 bits)
///   bits [29:21]  - PT index (9 bits)
///   bits [20:12]  - page offset in PT entry
///   bits [11:0]   - byte offset within page

pub const KERNEL_VIRT_BASE: u64 = 0xFFFF_8000_0000_0000;
pub const KERNEL_VIRT_TOP: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// PTE (Page Table Entry) permission flags
pub const PLV0: u64 = 0;  // Kernel privilege (PLV0)
pub const PLV3: u64 = 3;  // User privilege (PLV3)

pub const TLB_ENTRY_SIZE: usize = 16;  // Each TLB entry is 16 bytes (two 64-bit values)

/// Page table entry structure
pub const PageTableEntry = packed struct {
    ppn: u36,      // Physical Page Number (bits [47:12])
    _reserved0: u4 = 0,
    plv: u2,       // Privilege level (0=kernel, 3=user)
    ar: u3,         // Access Rights
    g: u1 = 0,      // Global bit
    _reserved1: u1 = 0,
    rplv: u1 = 0,  // Restrict privilege
    v: u1 = 0,     // Valid bit
    _reserved2: u4 = 0,
    csx: u1 = 0,   // CXE (Cacheable, Shareable, Execute)
    c: u1 = 0,      // Coherent
   _mat: u2 = 0,   // Memory Attribute
    cc: u1 = 0,     // Direct mapping cacheable
    _reserved3: u6 = 0,
};

/// Memory types for TLBELO
pub const MAT_STRONGLY_ORDERED: u2 = 0;
pub const MAT_COHERENT: u2 = 1;
pub const MAT_DEVICE: u2 = 2;
pub const MAT_NORMAL: u2 = 3;

/// Access Rights (AR) values
pub const AR_RWX: u3 = 0;    // Read/Write/Execute
pub const AR_RW: u3 = 1;   // Read/Write (no execute)
pub const AR_RX: u3 = 2;   // Read/Execute (no write)
pub const AR_R: u3 = 3;    // Read-only
pub const AR_RW_U: u3 = 5; // Read/Write in user mode
pub const AR_RX_U: u3 = 6; // Read/Execute in user mode
pub const AR_R_U: u3 = 7;  // Read-only in user mode

// ============================================================================
// CSR Access (extended from csr.zig)
// ============================================================================

/// LoongArch64 CSR 编号定义
pub const CSR = struct {
    pub const CRMD = 0x0;    // Current Mode
    pub const PRMD = 0x1;    // Previous Mode
    pub const EUEN = 0x2;    // Extended Unit Enable
    pub const MISC = 0x3;    // Misc Control
    pub const ECFG = 0x4;    // Exception Configuration
    pub const ESTAT = 0x5;   // Exception Status
    pub const ERA = 0x6;     // Exception Return Address
    pub const BADV = 0x7;    // Bad Virtual Address
    pub const BADV1 = 0x8;   // Bad Virtual Address 1
    pub const BADV2 = 0x9;   // Bad Virtual Address 2
    pub const PLV0 = 0x1C;   // Privilege Level 0
    pub const PLV1 = 0x1D;   // Privilege Level 1
    pub const PLV2 = 0x1E;   // Privilege Level 2
    pub const PLV3 = 0x1F;   // Privilege Level 3
    pub const TLBRERA = 0xB; // TLB Refill Exception PC
    pub const DMW0 = 0x180;  // Direct Map Window 0
    pub const DMW1 = 0x181;  // Direct Map Window 1
    pub const DMW2 = 0x182;  // Direct Map Window 2
    pub const DMW3 = 0x183;  // Direct Map Window 3
    pub const PGDL = 0x19;   // Page Global Directory Low
    pub const PGDH = 0x1A;   // Page Global Directory High
    pub const PGD = 0x1B;    // Page Global Directory (read-only)
    pub const PWCL = 0x1C;   // Page Walk Control Low
    pub const PWCH = 0x1D;   // Page Walk Control High
    pub const TLBRBADV = 0x11; // TLB Read BadVA
    pub const TLBRERA_RD = 0x12;  // TLB Read ERA
    pub const TLBRSAVE = 0x13; // TLB Read SAVE
    pub const STLBPS = 0x15;   // STLB Page Size
    pub const INVTLB = 0x16;  // Invalidate TLB
    pub const QID = 0x17;     // Queue ID
    pub const FTLBC = 0x18;   // FTLB Control
    pub const FTLBW = 0x19;   // FTLB Write
    pub const FTLBR = 0x1A;   // FTLB Read
    pub const SCFP = 0x1B;   // Software Cache Flush Pointer
};

/// DMW 属性标志
pub const DMW_PLV0 = @as(u64, 1) << 0;  // PLV0 access
pub const DMW_PLV3 = @as(u64, 1) << 3;  // PLV3 access
pub const DMW_MAT_SUC = @as(u64, 0) << 4; // Strong Uncached
pub const DMW_MAT_CC = @as(u64, 1) << 4;  // Coherent Cached
pub const DMW_MAT_WUC = @as(u64, 2) << 4; // Weak Uncached
pub const DMW_MAT_PCC = @as(u64, 3) << 4; // Private Coherent Cached

/// P1 FIX: 读取 CSR 寄存器
pub inline fn readCSR(comptime csr_num: u14) u64 {
    return switch (csr_num) {
        0x0 => asm volatile ("csrrd %0, 0x0"
            : [ret] "=r" (-> u64)
        ),
        0x1 => asm volatile ("csrrd %0, 0x1"
            : [ret] "=r" (-> u64)
        ),
        0x2 => asm volatile ("csrrd %0, 0x2"
            : [ret] "=r" (-> u64)
        ),
        0x4 => asm volatile ("csrrd %0, 0x4"
            : [ret] "=r" (-> u64)
        ),
        0x5 => asm volatile ("csrrd %0, 0x5"
            : [ret] "=r" (-> u64)
        ),
        0x6 => asm volatile ("csrrd %0, 0x6"
            : [ret] "=r" (-> u64)
        ),
        0x7 => asm volatile ("csrrd %0, 0x7"
            : [ret] "=r" (-> u64)
        ),
        0x10 => asm volatile ("csrrd %0, 0x10"
            : [ret] "=r" (-> u64)
        ),
        0x11 => asm volatile ("csrrd %0, 0x11"
            : [ret] "=r" (-> u64)
        ),
        0x12 => asm volatile ("csrrd %0, 0x12"
            : [ret] "=r" (-> u64)
        ),
        0x13 => asm volatile ("csrrd %0, 0x13"
            : [ret] "=r" (-> u64)
        ),
        0x14 => asm volatile ("csrrd %0, 0x14"
            : [ret] "=r" (-> u64)
        ),
        0x15 => asm volatile ("csrrd %0, 0x15"
            : [ret] "=r" (-> u64)
        ),
        0x16 => asm volatile ("csrrd %0, 0x16"
            : [ret] "=r" (-> u64)
        ),
        0x17 => asm volatile ("csrrd %0, 0x17"
            : [ret] "=r" (-> u64)
        ),
        0x18 => asm volatile ("csrrd %0, 0x18"
            : [ret] "=r" (-> u64)
        ),
        0x19 => asm volatile ("csrrd %0, 0x19"
            : [ret] "=r" (-> u64)
        ),
        0x1A => asm volatile ("csrrd %0, 0x1A"
            : [ret] "=r" (-> u64)
        ),
        0x1B => asm volatile ("csrrd %0, 0x1B"
            : [ret] "=r" (-> u64)
        ),
        0x1C => asm volatile ("csrrd %0, 0x1C"
            : [ret] "=r" (-> u64)
        ),
        0x1D => asm volatile ("csrrd %0, 0x1D"
            : [ret] "=r" (-> u64)
        ),
        0x1E => asm volatile ("csrrd %0, 0x1E"
            : [ret] "=r" (-> u64)
        ),
        0x1F => asm volatile ("csrrd %0, 0x1F"
            : [ret] "=r" (-> u64)
        ),
        0x20 => asm volatile ("csrrd %0, 0x20"
            : [ret] "=r" (-> u64)
        ),
        0x180 => asm volatile ("csrrd %0, 0x180"
            : [ret] "=r" (-> u64)
        ),
        0x181 => asm volatile ("csrrd %0, 0x181"
            : [ret] "=r" (-> u64)
        ),
        0x182 => asm volatile ("csrrd %0, 0x182"
            : [ret] "=r" (-> u64)
        ),
        0x183 => asm volatile ("csrrd %0, 0x183"
            : [ret] "=r" (-> u64)
        ),
        else => {
            return 0;
        },
    };
}

/// P1 FIX: 写入 CSR 寄存器
pub inline fn writeCSR(comptime csr_num: u14, value: u64) void {
    switch (csr_num) {
        0x0 => asm volatile ("csrwr %[val], 0x0"
            :
            : [val] "r" (value)
        ),
        0x1 => asm volatile ("csrwr %[val], 0x1"
            :
            : [val] "r" (value)
        ),
        0x2 => asm volatile ("csrwr %[val], 0x2"
            :
            : [val] "r" (value)
        ),
        0x4 => asm volatile ("csrwr %[val], 0x4"
            :
            : [val] "r" (value)
        ),
        0x5 => asm volatile ("csrwr %[val], 0x5"
            :
            : [val] "r" (value)
        ),
        0x6 => asm volatile ("csrwr %[val], 0x6"
            :
            : [val] "r" (value)
        ),
        0x10 => asm volatile ("csrwr %[val], 0x10"
            :
            : [val] "r" (value)
        ),
        0x11 => asm volatile ("csrwr %[val], 0x11"
            :
            : [val] "r" (value)
        ),
        0x12 => asm volatile ("csrwr %[val], 0x12"
            :
            : [val] "r" (value)
        ),
        0x13 => asm volatile ("csrwr %[val], 0x13"
            :
            : [val] "r" (value)
        ),
        0x14 => asm volatile ("csrwr %[val], 0x14"
            :
            : [val] "r" (value)
        ),
        0x15 => asm volatile ("csrwr %[val], 0x15"
            :
            : [val] "r" (value)
        ),
        0x16 => asm volatile ("csrwr %[val], 0x16"
            :
            : [val] "r" (value)
        ),
        0x17 => asm volatile ("csrwr %[val], 0x17"
            :
            : [val] "r" (value)
        ),
        0x18 => asm volatile ("csrwr %[val], 0x18"
            :
            : [val] "r" (value)
        ),
        0x19 => asm volatile ("csrwr %[val], 0x19"
            :
            : [val] "r" (value)
        ),
        0x1A => asm volatile ("csrwr %[val], 0x1A"
            :
            : [val] "r" (value)
        ),
        0x1B => asm volatile ("csrwr %[val], 0x1B"
            :
            : [val] "r" (value)
        ),
        0x1C => asm volatile ("csrwr %[val], 0x1C"
            :
            : [val] "r" (value)
        ),
        0x1D => asm volatile ("csrwr %[val], 0x1D"
            :
            : [val] "r" (value)
        ),
        0x1E => asm volatile ("csrwr %[val], 0x1E"
            :
            : [val] "r" (value)
        ),
        0x1F => asm volatile ("csrwr %[val], 0x1F"
            :
            : [val] "r" (value)
        ),
        0x20 => asm volatile ("csrwr %[val], 0x20"
            :
            : [val] "r" (value)
        ),
        0x180 => asm volatile ("csrwr %[val], 0x180"
            :
            : [val] "r" (value)
        ),
        0x181 => asm volatile ("csrwr %[val], 0x181"
            :
            : [val] "r" (value)
        ),
        0x182 => asm volatile ("csrwr %[val], 0x182"
            :
            : [val] "r" (value)
        ),
        0x183 => asm volatile ("csrwr %[val], 0x183"
            :
            : [val] "r" (value)
        ),
        else => {
            // 不支持的 CSR，静默忽略
        },
    }
}

/// P1 FIX: DMW 配置辅助函数
pub fn dmwVseg(vseg: u8) u64 {
    return @as(u64, vseg) << 48;
}

// ============================================================================
// Page Table Operations
// ============================================================================

/// Allocate a page table from PMM
fn allocPageTable() ?u64 {
    const page_idx = pmm.allocPage() orelse return null;
    return pmm.pageToPhysical(page_idx);
}

/// Zero out a page table
/// P2 FIX: Fixed loop to use index i instead of always writing to ptr[0]
fn zeroPageTable(phys: u64) void {
    const ptr: [*]volatile u64 = @ptrFromInt(phys);
    for (0..TABLE_ENTRIES) |i| {
        ptr[i * 2] = 0;
        ptr[i * 2 + 1] = 0;
    }
}

/// Extract indices from virtual address
fn pgdIndex(vaddr: u64) u9 {
    return @truncate(vaddr >> 30);
}

fn pmdIndex(vaddr: u64) u9 {
    return @truncate(vaddr >> 21);
}

fn ptIndex(vaddr: u64) u9 {
    return @truncate(vaddr >> 12);
}

/// Get pointer to page table entry at given address
fn getPageTablePtr(table_phys: u64, index: u9) *u64 {
    const ptr: [*]u64 = @ptrFromInt(table_phys);
    return &ptr[index];
}

// ============================================================================
// TLB Operations
// ============================================================================

/// TLB Index Register (TLBIDX) fields
///   [31:16] - Index
///   [15:8]  - PS (Page Size, in log2)
///   [5:0]   - Index width

/// Read TLB Index Register
pub inline fn readTLBIDX() u64 {
    return readCSR(0x10);
}

/// Write TLB Index Register
pub inline fn writeTLBIDX(val: u64) void {
    writeCSR(0x10, val);
}

/// Read TLB Entry High (contains VPN[47:12])
pub inline fn readTLBEHI() u64 {
    return readCSR(0x11);
}

/// Write TLB Entry High (sets the VPN for search/invalidation)
pub inline fn writeTLBEHI(val: u64) void {
    writeCSR(0x11, val);
}

/// Read TLB Entry Low 0 (PPN[47:6], PLV, AR, G, V)
pub inline fn readTLBELO0() u64 {
    return readCSR(0x12);
}

/// Write TLB Entry Low 0
pub inline fn writeTLBELO0(val: u64) void {
    writeCSR(0x12, val);
}

/// Read TLB Entry Low 1 (for huge pages)
pub inline fn readTLBELO1() u64 {
    return readCSR(0x13);
}

/// Write TLB Entry Low 1
pub inline fn writeTLBELO1(val: u64) void {
    writeCSR(0x13, val);
}

/// ASID register
pub inline fn readASID() u64 {
    return readCSR(0x18);
}

pub inline fn writeASID(val: u64) void {
    writeCSR(0x18, val);
}

/// PGD register (read-only, points to root page table)
pub inline fn readPGD() u64 {
    return readCSR(0x1B);
}

/// Page Walk Controller registers
pub inline fn readPWCL() u64 {
    return readCSR(0x1C);
}

pub inline fn readPWCH() u64 {
    return readCSR(0x1D);
}

/// TLB operations
/// 
/// invtlb  - Invalidate TLB entries matching a given pattern
///   rs1, rd, rj
///   rs1: value to match (0 = match all based on type)
///   rd:  ignored (set to 0)
///   rj:  instruction operand (indicates type of invalidation)

/// Invalidate all TLB entries (global)
/// P2 FIX: Added memory barrier for proper synchronization
inline fn invtlbAll() void {
    asm volatile ("invtlb 0, %[zero], %[zero]"
        :
        : [zero] "r" (@as(u64, 0))
    );
    asm volatile ("sync"); // Memory barrier to ensure TLB invalidation completes
}

/// Invalidate TLB entries by ASID
inline fn invtlbASID(asid: u64) void {
    asm volatile ("invtlb 1, %[asid], %[zero]"
        :
        : [asid] "r" (asid), [zero] "r" (@as(u64, 0))
    );
}

/// Invalidate TLB entry by virtual address
inline fn invtlbVA(vaddr: u64) void {
    asm volatile ("invtlb 2, %[vaddr], %[zero]"
        :
        : [vaddr] "r" (vaddr), [zero] "r" (@as(u64, 0))
    );
}

/// TLB fill (load from page tables into TLB)
/// LoongArch uses a "pagetable walk" hardware mechanism
/// The tlbwr/tlbfill instructions are used to write TLB entries

/// TLB Write Random - write current TLB entries to a random TLB slot
inline fn tlbwr() void {
    asm volatile ("tlbwr");
}

/// TLB Fill - used for TLB refill exception handler
inline fn tlbfill() void {
    asm volatile ("tlbfill");
}

/// TLB Read - read a TLB entry by index
inline fn tlbrd() void {
    asm volatile ("tlbrd");
}

/// Flush all TLB entries
/// P2 FIX: Added sync instruction for proper memory ordering
pub fn flushTLB() void {
    invtlbAll();
}

/// Flush TLB for a specific virtual address
pub fn flushTLBAddr(vaddr: u64) void {
    invtlbVA(vaddr);
}

/// Flush TLB for a specific ASID
pub fn flushTLBASID(asid: u64) void {
    invtlbASID(asid);
}

// ============================================================================
// P2 FIX: ASID Management
// ============================================================================

/// P2 FIX: ASID (Address Space Identifier) management for TLB optimization
/// ASID allows TLB entries to remain valid across context switches without full flush
var next_asid: u16 = 1;
const MAX_ASID: u16 = 255;

/// TLB shootdown 状态
var tlb_shootdown_in_progress: bool = false;

/// Allocate a new ASID for a process
pub fn allocASID() u16 {
    const asid = next_asid;
    next_asid +%= 1;
    if (next_asid >= MAX_ASID) {
        next_asid = 1;
        // When ASID namespace wraps, we need to flush all TLB entries
        flushTLB();
    }
    return asid;
}

/// P1 FIX: TLB Shootdown - 多核 TLB 刷新
pub fn tlbShootdown() void {
    tlb_shootdown_in_progress = true;

    // 在多核系统中，这里应该发送 IPI 到其他 CPU
    // 当前单核实现只需刷新本地 TLB
    flushTLB();

    tlb_shootdown_in_progress = false;
    log.debug("[MMU] TLB shootdown completed", .{});
}

/// P1 FIX: TLB Shootdown for specific address
pub fn tlbShootdownAddr(vaddr: u64) void {
    tlb_shootdown_in_progress = true;

    // 本地 TLB 刷新
    invtlbVA(vaddr);

    // 在多核系统中，应该发送 IPI 到其他 CPU
    tlb_shootdown_in_progress = false;
}

/// P1 FIX: TLB Shootdown for specific ASID
pub fn tlbShootdownASID(asid: u64) void {
    tlb_shootdown_in_progress = true;

    // 本地 ASID TLB 刷新
    invtlbASID(asid);

    tlb_shootdown_in_progress = false;
}

/// P1 FIX: 获取 TLB shootdown 状态
pub fn isTLBShootdownInProgress() bool {
    return tlb_shootdown_in_progress;
}

// ============================================================================
// PG (Paging) Mode Setup
// ============================================================================

var root_pgd_phys: u64 = 0;

/// Configure Page Walk Controller (PWCL/PWCH)
/// This tells the hardware how to walk the page table
fn configurePageWalk() void {
    // PWCL: Page Walk Controller Low
    //   [5:0]  - PT base width (usually 9 for 512-entry tables)
    //   [11:6] - PT base offset
    //   [17:12] - PT base level
    //   [21:18] - Levels (3 for our 3-level table)
    const pwcl: u64 = 
        (9 << 0) |   // PT base width
        (9 << 6) |   // PT base offset
        (0 << 12) |  // PT base level (0 = PGD)
        (2 << 18);   // PT levels (3 levels total: 0, 1, 2)
    
    // PWCH: Page Walk Controller High
    //   [5:0]  - Entry count (511 for 512-entry tables, but we use 511 = 2^9 - 1)
    //   [11:6] - PT levels (2 for 3-level table: PMD and PT)
    //   [16:12] - 4KB page size (12 bits)
    const pwch: u64 =
        (511 << 0) |   // Entry count (2^9 - 1)
        (2 << 11) |    // PT levels (PMD and PT)
        (12 << 6);     // Page size = 12 (4KB)
    
    writeCSR(0x1C, pwcl);
    writeCSR(0x1D, pwch);
    
    log.info("[MMU]  Page walk configured: PWCL=0x{x}, PWCH=0x{x}", .{pwcl, pwch});
}

/// Initialize the root page table (PGD)
fn initPageTables() void {
    // Allocate root PGD (Level 1)
    root_pgd_phys = allocPageTable() orelse @panic("[MMU] Failed to allocate PGD");
    zeroPageTable(root_pgd_phys);
    
    // Set the PGD base address in hardware
    // PGD is stored in PGDL (low) and PGDH (high) registers
    writeCSR(0x19, root_pgd_phys & 0xFFFF_FFFF); // PGDL
    writeCSR(0x1A, root_pgd_phys >> 32);          // PGDH
    
    log.info("[MMU]  Root PGD allocated at PA: 0x{x}", .{root_pgd_phys});
}

/// Create a mapping in the page table
/// This is a software page table walker that creates entries
fn mapPageTableEntry(vaddr: u64, paddr: u64, perm: u3, plv: u2, mat: u2) bool {
    _ = mat; // Reserved for future use (memory attribute)
    if (root_pgd_phys == 0) @panic("[MMU] PGD not initialized");
    
    const pgd_i = pgdIndex(vaddr);
    const pmd_i = pmdIndex(vaddr);
    const pt_i = ptIndex(vaddr);
    
    // Level 1: PGD
    const pgd_ptr: [*]volatile u64 = @ptrFromInt(root_pgd_phys);
    if (pgd_ptr[pgd_i * 2] == 0) {
        const pmd_phys = allocPageTable() orelse return false;
        zeroPageTable(pmd_phys);
        // PTE format: PPN[47:6] | FLAGS
        pgd_ptr[pgd_i * 2] = (pmd_phys & 0xFFFF_FFFF_F000) | 1; // V=1, Table type
        pgd_ptr[pgd_i * 2 + 1] = 0;
    }
    
    // Level 2: PMD
    const pgd_entry = pgd_ptr[pgd_i * 2];
    const pmd_phys = pgd_entry & 0xFFFF_FFFF_F000;
    const pmd_ptr: [*]volatile u64 = @ptrFromInt(pmd_phys);
    if (pmd_ptr[pmd_i * 2] == 0) {
        const pt_phys = allocPageTable() orelse return false;
        zeroPageTable(pt_phys);
        pmd_ptr[pmd_i * 2] = (pt_phys & 0xFFFF_FFFF_F000) | 1; // V=1, Table type
        pmd_ptr[pmd_i * 2 + 1] = 0;
    }
    
    // Level 3: PT
    const pmd_entry = pmd_ptr[pmd_i * 2];
    const pt_phys = pmd_entry & 0xFFFF_FFFF_F000;
    const pt_ptr: [*]volatile u64 = @ptrFromInt(pt_phys);
    
    // Create the actual page mapping
    const ppn = (paddr >> 12) & 0xFFFF_FFFFF; // PPN is bits [47:12]
    const entry0 = (ppn << 6) |          // PPN
                   (@as(u64, plv) << 4) |  // PLV
                   (@as(u64, perm) << 1) |  // AR
                   1;                       // V (Valid)
    const entry1: u64 = 0; // Reserved for huge pages
    
    pt_ptr[pt_i * 2] = entry0;
    pt_ptr[pt_i * 2 + 1] = entry1;
    
    return true;
}

/// Create identity mapping for kernel
fn mapKernelIdentity(size: usize) bool {
    log.info("[MMU]  Creating kernel identity mapping: 0x0 - 0x{x}", .{size});
    return mapRange(0, 0, size, AR_RWX, PLV0);
}

/// Create high memory mapping for kernel
fn mapKernelHigh(virt_base: u64, phys_base: u64, size: usize) bool {
    log.info("[MMU]  Creating kernel high mapping: PA 0x{x} -> VA 0x{x}", .{phys_base, virt_base});
    return mapRange(virt_base, phys_base, size, AR_RWX, PLV0);
}

/// Enable paging (PG) mode in CRMD
fn enablePaging() void {
    // Read current CRMD
    var crmd = readCSR(0x0);
    
    // Clear DA bit (bit 3), set PG bit (bit 4)
    crmd = (crmd & ~(1 << 3)) | (1 << 4);
    
    // Set privilege level to 0 (kernel)
    crmd = (crmd & ~@as(u64, 3)) | 0;
    
    // Enable global interrupt
    crmd |= (1 << 2);
    
    writeCSR(0x0, crmd);
    
    log.info("[MMU]  Paging enabled: CRMD = 0x{x}", .{crmd});
}

// ============================================================================
// Kernel Virtual Address Utilities
// ============================================================================

/// Convert physical address to kernel virtual address using DMW0
/// This is used before PG mode is enabled or for early boot
pub inline fn physToVirtCached(paddr: u64) u64 {
    return paddr | (@as(u64, 0x9) << 60);
}

/// Convert physical address to uncached kernel virtual address
pub inline fn physToVirtUncached(paddr: u64) u64 {
    return paddr | (@as(u64, 0x8) << 60);
}

/// Strip the DMW VSEG prefix to recover the physical address
pub inline fn virtToPhys(vaddr: u64) u64 {
    return vaddr & 0x0FFF_FFFF_FFFF_FFFF;
}

// ============================================================================
// Public API
// ============================================================================

/// P1 FIX: Huge page size constants
pub const HUGE_PAGE_2MB: usize = 2 * 1024 * 1024;
pub const HUGE_PAGE_16MB: usize = 16 * 1024 * 1024;
pub const HUGE_PAGE_64MB: usize = 64 * 1024 * 1024;

/// P1 FIX: Map a single page (4KB)
pub fn mapPage(vaddr: u64, paddr: u64, flags: u3) bool {
    return mapPageTableEntry(vaddr, paddr, flags, PLV0, MAT_NORMAL);
}

/// P1 FIX: Map a huge page (2MB)
/// For 2MB huge pages, the PT index (bits [20:12]) must be 0
pub fn mapHugePage2MB(vaddr: u64, paddr: u64, flags: u3) bool {
    _ = flags;
    if (root_pgd_phys == 0) @panic("[MMU] PGD not initialized");

    // 2MB alignment check
    if ((vaddr & 0x1F_FFFF) != 0 or (paddr & 0x1F_FFFF) != 0) {
        log.err("[MMU] mapHugePage2MB: addresses not 2MB aligned", .{});
        return false;
    }

    const pgd_i = pgdIndex(vaddr);
    const pmd_i = pmdIndex(vaddr);

    const pgd_ptr: [*]volatile u64 = @ptrFromInt(root_pgd_phys);

    // Level 1: PGD - allocate if needed
    if (pgd_ptr[pgd_i * 2] == 0) {
        const pmd_phys = allocPageTable() orelse return false;
        zeroPageTable(pmd_phys);
        pgd_ptr[pgd_i * 2] = (pmd_phys & 0xFFFF_FFFF_F000) | 1;
        pgd_ptr[pgd_i * 2 + 1] = 0;
    }

    // Level 2: PMD - create huge page entry directly
    const pgd_entry = pgd_ptr[pgd_i * 2];
    const pmd_phys = pgd_entry & 0xFFFF_FFFF_F000;
    const pmd_ptr: [*]volatile u64 = @ptrFromInt(pmd_phys);

    // Create huge page PTE in PMD
    const ppn = (paddr >> 12) & 0xFFFF_FFFFF;
    const entry0 = (ppn << 6) | (@as(u64, PLV0) << 4) | (@as(u64, AR_RWX) << 1) | 1;
    const entry1: u64 = (1 << 5); // PS = 1 (indicates huge page)

    pmd_ptr[pmd_i * 2] = entry0;
    pmd_ptr[pmd_i * 2 + 1] = entry1;

    log.debug("[MMU] Mapped 2MB huge page: VA 0x{x} -> PA 0x{x}", .{ vaddr, paddr });
    return true;
}

/// P1 FIX: Map a 16MB huge page
pub fn mapHugePage16MB(vaddr: u64, paddr: u64, flags: u3) bool {
    _ = flags;
    if (root_pgd_phys == 0) @panic("[MMU] PGD not initialized");

    // 16MB alignment check
    if ((vaddr & 0xFF_FFFF) != 0 or (paddr & 0xFF_FFFF) != 0) {
        log.err("[MMU] mapHugePage16MB: addresses not 16MB aligned", .{});
        return false;
    }

    const pgd_i = pgdIndex(vaddr);

    const pgd_ptr: [*]volatile u64 = @ptrFromInt(root_pgd_phys);

    // Level 1: PGD - create huge page entry directly
    const ppn = (paddr >> 12) & 0xFFFF_FFFFF;
    const entry0 = (ppn << 6) | (@as(u64, PLV0) << 4) | (@as(u64, AR_RWX) << 1) | 1;
    const entry1: u64 = (2 << 5); // PS = 2 (indicates larger huge page)

    pgd_ptr[pgd_i * 2] = entry0;
    pgd_ptr[pgd_i * 2 + 1] = entry1;

    log.debug("[MMU] Mapped 16MB huge page: VA 0x{x} -> PA 0x{x}", .{ vaddr, paddr });
    return true;
}

/// Unmap a virtual address (invalidate TLB)
pub fn unmapPage(vaddr: u64) bool {
    invtlbVA(vaddr);
    return true;
}

/// P1 FIX: 修改页面保护权限
pub fn protectPage(vaddr: u64, flags: u3) bool {
    if (root_pgd_phys == 0) return false;

    const pgd_i = pgdIndex(vaddr);
    const pmd_i = pmdIndex(vaddr);
    const pt_i = ptIndex(vaddr);

    const pgd_ptr: [*]volatile u64 = @ptrFromInt(root_pgd_phys);
    if (pgd_ptr[pgd_i * 2] == 0) return false;

    const pmd_phys = pgd_ptr[pgd_i * 2] & 0xFFFF_FFFF_F000;
    const pmd_ptr: [*]volatile u64 = @ptrFromInt(pmd_phys);
    if (pmd_ptr[pmd_i * 2] == 0) return false;

    const pmd_entry = pmd_ptr[pmd_i * 2];
    if ((pmd_entry & 1) == 0) return false;

    const pmd_entry1 = pmd_ptr[pmd_i * 2 + 1];
    const ps = (pmd_entry1 >> 5) & 0x7;
    if (ps > 0) {
        const new_entry0 = (pmd_entry & ~(@as(u64, 7) << 1)) | (@as(u64, flags) << 1) | 1;
        pmd_ptr[pmd_i * 2] = new_entry0;
        invtlbVA(vaddr);
        return true;
    }

    const pt_phys = pmd_entry & 0xFFFF_FFFF_F000;
    const pt_ptr: [*]volatile u64 = @ptrFromInt(pt_phys);
    if (pt_ptr[pt_i * 2] == 0) return false;

    const new_entry0 = (pt_ptr[pt_i * 2] & ~(@as(u64, 7) << 1)) | (@as(u64, flags) << 1) | 1;
    pt_ptr[pt_i * 2] = new_entry0;
    invtlbVA(vaddr);

    return true;
}

/// P1 FIX: 切换地址空间
pub fn switchAddressSpace(pgd_phys: u64, asid: u16) void {
    writeCSR(CSR.PGDL, pgd_phys & 0xFFFF_FFFF);
    writeCSR(CSR.PGDH, pgd_phys >> 32);
    writeASID(@as(u64, asid));
    invtlbASID(@as(u64, asid));
    log.debug("[MMU] Switched to address space (pgd=0x{x}, asid={})", .{ pgd_phys, asid });
}

/// P1 FIX: 创建新的地址空间
pub fn createAddressSpace() ?u64 {
    const new_pgd = allocPageTable() orelse return null;
    zeroPageTable(new_pgd);
    return new_pgd;
}

/// P1 FIX: 激活地址空间
pub fn activateAddressSpace(pgd_phys: u64, asid: u16) void {
    switchAddressSpace(pgd_phys, asid);
}

/// P0 FIX: Public mapRange function for external use
pub fn mapRange(vaddr: u64, paddr: u64, size: usize, perm: u3, plv: u2) bool {
    const num_pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;

    var offset: usize = 0;
    while (offset < num_pages) : (offset += 1) {
        const va = vaddr + @as(u64, offset) * PAGE_SIZE;
        const pa = paddr + @as(u64, offset) * PAGE_SIZE;
        if (!mapPageTableEntry(va, pa, perm, plv, MAT_NORMAL)) {
            log.err("[MMU] mapRange: failed at page {}", .{offset});
            return false;
        }
    }
    return true;
}

/// Translate virtual to physical address (software walk)
pub fn translate(vaddr: u64) ?u64 {
    if (root_pgd_phys == 0) return null;

    const pgd_i = pgdIndex(vaddr);
    const pmd_i = pmdIndex(vaddr);
    const pt_i = ptIndex(vaddr);

    const pgd_ptr: [*]volatile u64 = @ptrFromInt(root_pgd_phys);

    // Level 1: PGD
    if (pgd_ptr[pgd_i * 2] == 0) return null;

    const pgd_entry = pgd_ptr[pgd_i * 2];
    if ((pgd_entry & 1) == 0) return null; // Not valid

    const pmd_phys = pgd_entry & 0xFFFF_FFFF_F000;
    const pmd_ptr: [*]volatile u64 = @ptrFromInt(pmd_phys);

    // Level 2: PMD
    if (pmd_ptr[pmd_i * 2] == 0) return null;

    const pmd_entry = pmd_ptr[pmd_i * 2];
    if ((pmd_entry & 1) == 0) return null; // Not valid

    // Check for huge pages (PS bit)
    const pmd_entry1 = pmd_ptr[pmd_i * 2 + 1];
    const ps = (pmd_entry1 >> 5) & 0x7;

    if (ps > 0) {
        // Huge page - extract PPN and add offset
        const huge_ppn = (pmd_entry >> 6) & 0xFFFF_FFFFF;
        return (huge_ppn << 12) | (vaddr & 0xFF_FFFF);
    }

    const pt_phys = pmd_entry & 0xFFFF_FFFF_F000;
    const pt_ptr: [*]volatile u64 = @ptrFromInt(pt_phys);

    // Level 3: PT
    if (pt_ptr[pt_i * 2] == 0) return null;

    const pt_entry = pt_ptr[pt_i * 2];
    if ((pt_entry & 1) == 0) return null; // Not valid

    // Regular 4KB page
    const ppn = (pt_entry >> 6) & 0xFFFF_FFFFF;
    return (ppn << 12) | (vaddr & 0xFFF);
}

/// Initialize the MMU
pub fn init() void {
    if (initialized) return;
    
    log.info("[MMU]  LoongArch64 MMU initialization", .{});
    
    // Step 1: Configure Direct Map Windows for early boot
    // These allow us to access physical memory through known VA prefixes
    csr.write(csr.DMW0, csr.dmwVseg(0x9) | csr.DMW_MAT_CC | csr.DMW_PLV0);
    csr.write(csr.DMW1, csr.dmwVseg(0x8) | csr.DMW_MAT_SUC | csr.DMW_PLV0);
    csr.write(csr.DMW2, 0);
    csr.write(csr.DMW3, 0);
    
    const dmw0_val = csr.read(csr.DMW0);
    const dmw1_val = csr.read(csr.DMW1);
    
    log.info("[MMU]    DMW0 = 0x{x} (0x9000_xxxx cached)", .{dmw0_val});
    log.info("[MMU]    DMW1 = 0x{x} (0x8000_xxxx uncached)", .{dmw1_val});
    
    // Step 2: Configure Page Walk Controller
    configurePageWalk();
    
    // Step 3: Initialize page tables
    initPageTables();
    
    // Step 4: Create kernel identity mapping (first 1GB)
    if (!mapKernelIdentity(0x4000_0000)) {
        @panic("[MMU] Failed to create identity mapping");
    }
    
    // Step 5: Create kernel high memory mapping
    if (!mapKernelHigh(KERNEL_VIRT_BASE, 0x8000_0000, 0x1000_0000)) {
        log.warn("[MMU]  Failed to create high memory mapping", .{});
    }
    
    // Step 6: Enable paging
    enablePaging();
    
    // Report TLB capabilities
    const prcfg1 = csr.read(csr.PRCFG1);
    const stlb_ways = (prcfg1 >> 8) & 0xFF;
    const stlb_sets_log2 = prcfg1 & 0xFF;
    log.info("[MMU]    STLB: {} ways, {} sets", .{ stlb_ways, @as(u64, 1) << @as(u6, @intCast(stlb_sets_log2)) });
    
    initialized = true;
    log.info("[MMU]  LoongArch64 MMU initialized with PG mode enabled", .{});
}

pub fn isInitialized() bool {
    return initialized;
}

// ============================================================================
// Page Query
// ============================================================================

/// P2 FIX: Page query info
pub const PageInfo = struct {
    present: bool,
    phys: u64,
    perm: u3,
    plv: u2,
    huge: bool,
    huge_size: usize,
};

/// P2 FIX: 查询页面详细信息
pub fn queryPage(vaddr: u64) PageInfo {
    if (root_pgd_phys == 0) {
        return .{ .present = false, .phys = 0, .perm = 0, .plv = 0, .huge = false, .huge_size = 0 };
    }

    const pgd_i = pgdIndex(vaddr);
    const pmd_i = pmdIndex(vaddr);
    const pt_i = ptIndex(vaddr);

    const pgd_ptr: [*]volatile u64 = @ptrFromInt(root_pgd_phys);

    if (pgd_ptr[pgd_i * 2] == 0) {
        return .{ .present = false, .phys = 0, .perm = 0, .plv = 0, .huge = false, .huge_size = 0 };
    }

    const pmd_phys = pgd_ptr[pgd_i * 2] & 0xFFFF_FFFF_F000;
    const pmd_ptr: [*]volatile u64 = @ptrFromInt(pmd_phys);

    if (pmd_ptr[pmd_i * 2] == 0) {
        return .{ .present = false, .phys = 0, .perm = 0, .plv = 0, .huge = false, .huge_size = 0 };
    }

    const pmd_entry = pmd_ptr[pmd_i * 2];
    const pmd_entry1 = pmd_ptr[pmd_i * 2 + 1];
    const ps = (pmd_entry1 >> 5) & 0x7;

    if (ps > 0) {
        const huge_size: usize = switch (ps) {
            1 => HUGE_PAGE_2MB,
            2 => HUGE_PAGE_16MB,
            else => HUGE_PAGE_2MB,
        };
        const huge_ppn = (pmd_entry >> 6) & 0xFFFF_FFFFF;
        const huge_offset = vaddr & (huge_size - 1);
        return .{
            .present = true,
            .phys = (huge_ppn << 12) | huge_offset,
            .perm = @truncate((pmd_entry >> 1) & 0x7),
            .plv = @truncate((pmd_entry >> 4) & 0x3),
            .huge = true,
            .huge_size = huge_size,
        };
    }

    const pt_phys = pmd_entry & 0xFFFF_FFFF_F000;
    const pt_ptr: [*]volatile u64 = @ptrFromInt(pt_phys);

    if (pt_ptr[pt_i * 2] == 0) {
        return .{ .present = false, .phys = 0, .perm = 0, .plv = 0, .huge = false, .huge_size = 0 };
    }

    const pt_entry = pt_ptr[pt_i * 2];
    return .{
        .present = true,
        .phys = ((pt_entry >> 6) & 0xFFFF_FFFFF) << 12 | (vaddr & 0xFFF),
        .perm = @truncate((pt_entry >> 1) & 0x7),
        .plv = @truncate((pt_entry >> 4) & 0x3),
        .huge = false,
        .huge_size = PAGE_SIZE,
    };
}

// ============================================================================
// MMU Statistics
// ============================================================================

/// P2 FIX: MMU 统计信息
pub const MMUStats = struct {
    root_pgd_phys: u64,
    paging_enabled: bool,
    dmw0: u64,
    dmw1: u64,
    pgdl: u64,
    pgdh: u64,
    asid: u16,
};

/// P2 FIX: 获取 MMU 统计
pub fn getStats() MMUStats {
    return .{
        .root_pgd_phys = root_pgd_phys,
        .paging_enabled = initialized,
        .dmw0 = readCSR(CSR.DMW0),
        .dmw1 = readCSR(CSR.DMW1),
        .pgdl = readCSR(CSR.PGDL),
        .pgdh = readCSR(CSR.PGDL),
        .asid = @truncate(readASID()),
    };
}

/// P2 FIX: 打印 MMU 状态
pub fn dumpState() void {
    const stats = getStats();

    log.info("=== LoongArch64 MMU State ===", .{});
    log.info("  Root PGD PA:    0x{x}", .{stats.root_pgd_phys});
    log.info("  Paging enabled: {}", .{stats.paging_enabled});
    log.info("  DMW0:           0x{x}", .{stats.dmw0});
    log.info("  DMW1:           0x{x}", .{stats.dmw1});
    log.info("  PGDL:           0x{x}", .{stats.pgdl});
    log.info("  PGDH:           0x{x}", .{stats.pgdh});
    log.info("  Current ASID:   {}", .{stats.asid});
}
