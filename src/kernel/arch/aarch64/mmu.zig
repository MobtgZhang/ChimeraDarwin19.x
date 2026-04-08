/// AArch64 MMU — 4-level page table setup (4 KB granule, 48-bit VA).
/// Provides complete MMU initialization for ARMv8-A architecture.
/// 
/// AArch64 uses a 4-level page table structure:
///   Level 0 (PML4/PGD): 512 entries, indexed by bits [47:39]
///   Level 1 (PUD/PMD): 512 entries, indexed by bits [38:30]
///   Level 2 (PMD/PT): 512 entries, indexed by bits [29:21]
///   Level 3 (PT):      512 entries, indexed by bits [20:12]
/// 
/// This module provides:
///   - MAIR_EL1 configuration for memory attributes
///   - TCR_EL1 configuration for translation control
///   - TTBR0_EL1/TTBR1_EL1 for page table bases
///   - SCTLR_EL1 for MMU enable/disable
///   - Page table allocation and mapping functions
///   - TLB invalidation operations

const log = @import("../../../lib/log.zig");
const pmm = @import("../../mm/pmm.zig");

pub const PAGE_SIZE: usize = 4096;
pub const TABLE_ENTRIES: usize = 512;

var initialized: bool = false;

// ============================================================================
// Page Table Entry (PTE) for AArch64
// ============================================================================

pub const PageTableEntry = packed struct {
    valid: u1 = 0,
    table_or_page: u1 = 0,  // 0 = table descriptor, 1 = page descriptor
    attr_index: u3 = 0,
    ns: u1 = 0,
    ap: u2 = 0,
    sh: u2 = 0,
    af: u1 = 0,
    _reserved0: u1 = 0,
    address: u36 = 0,
    _reserved1: u4 = 0,
    contiguous: u1 = 0,
    pxn: u1 = 0,  // Privileged Execute Never
    uxn: u1 = 0,  // Unprivileged Execute Never
    _reserved2: u4 = 0,
    pbha: u4 = 0,
    _reserved3: u1 = 0,
};

/// Memory Attribute Index values for MAIR_EL1
pub const MAIR_ATTR_DEVICE: u3 = 0;      // Device memory (non-gathering, non-reordering)
pub const MAIR_ATTR_NORMAL_NC: u3 = 1;   // Normal memory, Non-Cacheable
pub const MAIR_ATTR_NORMAL_WT: u3 = 2;   // Normal memory, Write-Through
pub const MAIR_ATTR_NORMAL_WB: u3 = 3;   // Normal memory, Write-Back (default)
pub const MAIR_ATTR_NORMAL_WB_RA: u3 = 4; // Normal memory, Write-Back, Read-Allocate
pub const MAIR_ATTR_NORMAL_WB_WA: u3 = 5; // Normal memory, Write-Back, Write-Allocate
pub const MAIR_ATTR_NORMAL_WB_RA_WA: u3 = 6; // Normal memory, Write-Back, Read+Write Allocate

/// AP (Access Permission) values
pub const AP_RW_PL1_RW: u2 = 0;  // EL1: read/write, EL0: no access
pub const AP_RW_PL1_RO: u2 = 1;  // EL1: read/write, EL0: read-only
pub const AP_RO_PL1_RO: u2 = 2;  // EL1: read-only, EL0: no access
pub const AP_RO_PL1_RO_PL0_RO: u2 = 3;  // EL1: read-only, EL0: read-only

/// Shareability attributes
pub const SH_NONE: u2 = 0;     // Non-shareable
pub const SH_OUTER: u2 = 2;   // Outer shareable
pub const SH_INNER: u2 = 3;   // Inner shareable

// ============================================================================
// System Register Access Functions (inline assembly)
// ============================================================================

/// Read from a system register
inline fn readSysReg(comptime reg: []const u8) u64 {
    return asm volatile ("mrs %0, " ++ reg
        : [ret] "=r" (-> u64)
    );
}

// ============================================================================
// System Register Definitions
// ============================================================================

/// MAIR_EL1 - Memory Attribute Indirection Register
/// Defines the memory attribute for each of the 8 attribute indices
pub fn readMAIR_EL1() u64 {
    return readSysReg("MAIR_EL1");
}

/// P0 FIX: Write to MAIR_EL1
pub fn writeMAIR_EL1(val: u64) void {
    asm volatile ("msr MAIR_EL1, %[val]"
        :
        : [val] "r" (val)
    );
}

/// TCR_EL1 - Translation Control Register
/// Controls the address translation mode and page size
pub fn readTCR_EL1() u64 {
    return readSysReg("TCR_EL1");
}

/// P0 FIX: Write to TCR_EL1
pub fn writeTCR_EL1(val: u64) void {
    asm volatile ("msr TCR_EL1, %[val]"
        :
        : [val] "r" (val)
    );
}

/// TTBR0_EL1 - Translation Table Base Register 0
/// Holds the base address of the level 1 translation table for EL1
pub fn readTTBR0_EL1() u64 {
    return readSysReg("TTBR0_EL1");
}

/// P0 FIX: Write to TTBR0_EL1
pub fn writeTTBR0_EL1(val: u64) void {
    asm volatile ("msr TTBR0_EL1, %[val]"
        :
        : [val] "r" (val)
    );
}

/// P1 FIX: Alias for TTBR0_EL1 (API compatibility)
pub const readTTBR0 = readTTBR0_EL1;
pub const writeTTBR0 = writeTTBR0_EL1;

/// TTBR1_EL1 - Translation Table Base Register 1
/// Holds the base address of the level 1 translation table for EL1 (high addresses)
pub fn readTTBR1_EL1() u64 {
    return readSysReg("TTBR1_EL1");
}

/// P0 FIX: Write to TTBR1_EL1
pub fn writeTTBR1_EL1(val: u64) void {
    asm volatile ("msr TTBR1_EL1, %[val]"
        :
        : [val] "r" (val)
    );
}

/// SCTLR_EL1 - System Control Register
/// Contains control bits for the MMU, cache, alignment checking, etc.
pub fn readSCTLR_EL1() u64 {
    return readSysReg("SCTLR_EL1");
}

/// P0 FIX: Write to SCTLR_EL1
pub fn writeSCTLR_EL1(val: u64) void {
    asm volatile ("msr SCTLR_EL1, %[val]"
        :
        : [val] "r" (val)
    );
}

/// CurrentEL - Current Exception Level
pub fn getCurrentEL() u2 {
    return @truncate(readSysReg("CurrentEL") >> 2);
}

/// PAR_EL1 - Physical Address Register (used by AT instruction)
pub fn readPAR_EL1() u64 {
    return readSysReg("PAR_EL1");
}

// ============================================================================
// MAIR Configuration
// ============================================================================

/// TCR_EL1 bit definitions
pub const TCR_T0SZ_SHIFT: u6 = 0;    // TTBR0_EL1 field size
pub const TCR_T1SZ_SHIFT: u6 = 16;   // TTBR1_EL1 field size
pub const TCR_TG0_SHIFT: u2 = 14;    // TTBR0 granule size
pub const TCR_TG1_SHIFT: u2 = 30;    // TTBR1 granule size
pub const TCR_SH0_SHIFT: u2 = 12;    // TTBR0 shareability
pub const TCR_SH1_SHIFT: u2 = 28;    // TTBR1 shareability
pub const TCR_ORGN0_SHIFT: u2 = 10;  // TTBR0 outer cacheability
pub const TCR_ORGN1_SHIFT: u2 = 26;  // TTBR1 outer cacheability
pub const TCR_IRGN0_SHIFT: u2 = 8;  // TTBR0 inner cacheability
pub const TCR_IRGN1_SHIFT: u2 = 24;  // TTBR1 inner cacheability
pub const TCR_EPD0_SHIFT: u5 = 7;    // TTBR0 translation table walk disable
pub const TCR_EPD1_SHIFT: u5 = 23;   // TTBR1 translation table walk disable

/// TCR_TG0 values (4KB granule)
pub const TCR_TG0_4KB: u2 = 0;
pub const TCR_TG0_16KB: u2 = 2;
pub const TCR_TG0_64KB: u2 = 1;

/// TCR cacheability values
pub const TCR_CACHE_NC: u2 = 0;   // Non-cacheable
pub const TCR_CACHE_WB_RA_WA: u2 = 1; // Write-back, Read-allocate, Write-allocate
pub const TCR_CACHE_WT_RA_NWA: u2 = 2; // Write-through, Read-allocate, No Write-allocate
pub const TCR_CACHE_WB_RA_NWA: u3 = 3; // Write-back, Read-allocate, No Write-allocate

/// SCTLR_EL1 bit definitions
pub const SCTLR_M: u64 = 1 << 0;      // MMU enable
pub const SCTLR_A: u64 = 1 << 1;      // Alignment check enable
pub const SCTLR_C: u64 = 1 << 2;      // Data cache enable
pub const SCTLR_SA: u64 = 1 << 3;     // Stack alignment check enable
pub const SCTLR_I: u64 = 1 << 12;     // Instruction cache enable
pub const SCTLR_WXN: u64 = 1 << 19;   // Write-permission implies XN
pub const SCTLR_IESB: u64 = 1 << 21;  // Implicit Error Synchronization Barrier

// ============================================================================
// Page Table Operations
// ============================================================================

/// Allocate a page table from PMM
fn allocPageTable() ?u64 {
    const page_idx = pmm.allocPage() orelse return null;
    return pmm.pageToPhysical(page_idx);
}

/// Zero out a page table
fn zeroPageTable(phys: u64) void {
    const ptr: [*]volatile u64 = @ptrFromInt(phys);
    for (0..TABLE_ENTRIES) |i| {
        ptr[i] = 0;
    }
}

/// Create a page table entry for a next-level table
fn makeTableDescriptor(table_phys: u64, attr_index: u3, sh: u2) u64 {
    return (@as(u64, table_phys) & 0xFFFF_FFFF_F000) |
           (@as(u64, attr_index) << 2) |
           (@as(u64, sh) << 8) |
           0x3;  // Table descriptor type
}

/// Create a page table entry for a 4KB page
fn makePageDescriptor(phys: u64, attr_index: u3, ap: u2, sh: u2, nx: bool) u64 {
    return (@as(u64, phys) & 0xFFFF_FFFF_F000) |
           (@as(u64, attr_index) << 2) |
           (@as(u64, ap) << 6) |
           (@as(u64, sh) << 8) |
           (1 << 10) |  // AF (Access Flag)
           (@as(u64, @intFromBool(nx)) << 54) |
           0x3;  // Page descriptor type
}

/// Index extraction functions
fn pgdIndex(virt: u64) u9 {
    return @truncate(virt >> 39);
}

fn pudIndex(virt: u64) u9 {
    return @truncate(virt >> 30);
}

fn pmdIndex(virt: u64) u9 {
    return @truncate(virt >> 21);
}

fn ptIndex(virt: u64) u9 {
    return @truncate(virt >> 12);
}

// ============================================================================
// MAIR Initialization
// ============================================================================

/// Initialize MAIR_EL1 with memory attributes
/// 
/// Encoding:
///   Attr<n> (bits 8*(n+1)-1 : 8*n) for attribute index n
/// 
/// Device memory (Attr0):   0x00 - Device-nGnRnE (non-gathering, non-reordering, no early acknowledgment)
/// Normal (Attr1):          0x44 - Normal, Outer Write-Back, Inner Write-Back, RA-WA
/// Normal NC (Attr2):       0xFF - Normal, Non-cacheable
/// 
fn initMAIR() void {
    // Device memory: 0x00 (most restrictive)
    const attr_device = @as(u64, 0x00);
    // Normal WB RA-WA: 0x44 (cacheable)
    const attr_normal = @as(u64, 0x44);
    // Normal NC: 0xFF (non-cacheable)
    const attr_normal_nc = @as(u64, 0xFF);
    
    // Build MAIR_EL1 value
    // Attr0 = Device (bits 7:0)
    // Attr1 = Normal WB (bits 15:8)
    // Attr2 = Normal NC (bits 23:16)
    // Attr3-7 = Reserved (0x00)
    const mair = (attr_normal_nc << 16) | (attr_normal << 8) | attr_device;
    
    writeMAIR_EL1(mair);
    log.info("[MMU]  MAIR_EL1 configured: 0x{x}", .{mair});
}

// ============================================================================
// TCR Initialization
// ============================================================================

/// Initialize TCR_EL1 for 48-bit VA, 4KB granule
/// 
/// T0SZ/T1SZ = 64 - 48 = 16 (indicates 48-bit address space)
/// For 4KB granule with 4 levels:
///   Level 0 index: bits [47:39]
///   Level 1 index: bits [38:30]
///   Level 2 index: bits [29:21]
///   Level 3 index: bits [20:12]
///   Offset: bits [11:0]
/// 
/// T0SZ = 16 means:
///   - Virtual address bits [63:48] must match bit [47] (sign extension)
///   - TTBR0 covers 0x0000_0000_0000 to 0x0000_7FFF_FFFF_FFFF
///   - TTBR1 covers 0xFFFF_8000_0000_0000 to 0xFFFF_FFFF_FFFF_FFFF
/// 
fn initTCR() void {
    const t0sz: u6 = 16;
    const t1sz: u6 = 16;
    
    // Build TCR value
    var tcr: u64 = 0;
    tcr |= @as(u64, t0sz) << TCR_T0SZ_SHIFT;
    tcr |= @as(u64, t1sz) << TCR_T1SZ_SHIFT;
    tcr |= @as(u64, TCR_TG0_4KB) << TCR_TG0_SHIFT;    // 4KB granule for TTBR0
    tcr |= @as(u64, TCR_TG0_4KB) << TCR_TG1_SHIFT;   // 4KB granule for TTBR1
    tcr |= @as(u64, SH_INNER) << TCR_SH0_SHIFT;       // Inner shareable
    tcr |= @as(u64, SH_INNER) << TCR_SH1_SHIFT;
    tcr |= @as(u64, TCR_CACHE_WB_RA_WA) << TCR_ORGN0_SHIFT;  // Outer WB
    tcr |= @as(u64, TCR_CACHE_WB_RA_WA) << TCR_ORGN1_SHIFT;
    tcr |= @as(u64, TCR_CACHE_WB_RA_WA) << TCR_IRGN0_SHIFT;  // Inner WB
    tcr |= @as(u64, TCR_CACHE_WB_RA_WA) << TCR_IRGN1_SHIFT;
    // EPD0/EPD1 = 0 (enable translation table walks)
    
    writeTCR_EL1(tcr);
    log.info("[MMU]  TCR_EL1 configured: 0x{x}", .{tcr});
}

// ============================================================================
// Page Table Setup
// ============================================================================

var root_table_phys: u64 = 0;

fn initPageTables() void {
    // Allocate root page table (PGD/Level 0)
    root_table_phys = allocPageTable() orelse @panic("[MMU] Failed to allocate root page table");
    zeroPageTable(root_table_phys);
    
    log.info("[MMU]  Root page table allocated at PA: 0x{x}", .{root_table_phys});
}

/// Map kernel region with identity mapping
/// This creates a 1:1 mapping of physical to virtual for kernel memory
fn mapKernelRegion(virt_base: u64, phys_base: u64, size: usize, attr_index: u3, ap: u2) bool {
    if (root_table_phys == 0) @panic("[MMU] Page tables not initialized");
    
    const num_pages = (size + PAGE_SIZE - 1) / PAGE_SIZE;
    
    const pgd: [*]u64 = @ptrFromInt(root_table_phys);
    
    var offset: usize = 0;
    while (offset < num_pages) : (offset += 1) {
        const virt = virt_base + @as(u64, offset * PAGE_SIZE);
        const phys = phys_base + @as(u64, offset * PAGE_SIZE);
        
        const pgd_i = pgdIndex(virt);
        const pud_i = pudIndex(virt);
        const pmd_i = pmdIndex(virt);
        const pt_i = ptIndex(virt);
        
        // Allocate PGD entry if needed
        if (pgd[pgd_i] == 0) {
            const pud_phys = allocPageTable() orelse return false;
            zeroPageTable(pud_phys);
            pgd[pgd_i] = makeTableDescriptor(pud_phys, MAIR_ATTR_NORMAL_WB, SH_INNER);
        }
        
        const pud_phys = pgd[pgd_i] & 0xFFFF_FFFF_F000;
        const pud: [*]u64 = @ptrFromInt(pud_phys);
        
        // Allocate PUD entry if needed
        if (pud[pud_i] == 0) {
            const pmd_phys = allocPageTable() orelse return false;
            zeroPageTable(pmd_phys);
            pud[pud_i] = makeTableDescriptor(pmd_phys, MAIR_ATTR_NORMAL_WB, SH_INNER);
        }
        
        const pmd_phys = pud[pud_i] & 0xFFFF_FFFF_F000;
        const pmd: [*]u64 = @ptrFromInt(pmd_phys);
        
        // Allocate PMD entry if needed
        if (pmd[pmd_i] == 0) {
            const pt_phys = allocPageTable() orelse return false;
            zeroPageTable(pt_phys);
            pmd[pmd_i] = makeTableDescriptor(pt_phys, MAIR_ATTR_NORMAL_WB, SH_INNER);
        }
        
        const pt_phys = pmd[pmd_i] & 0xFFFF_FFFF_F000;
        const pt: [*]u64 = @ptrFromInt(pt_phys);
        
        // Map the page
        pt[pt_i] = makePageDescriptor(phys, attr_index, ap, SH_INNER, false);
    }
    
    return true;
}

/// Map a region into the kernel virtual address space
/// virt_base should be in the high address range (0xFFFF_...)
fn mapKernelVirtual(virt_base: u64, phys_base: u64, size: usize, attr_index: u3, ap: u2) bool {
    return mapKernelRegion(virt_base, phys_base, size, attr_index, ap);
}

// ============================================================================
// MMU Enable/Disable
// ============================================================================

/// Enable the MMU
/// WARNING: This function assumes page tables are already set up correctly.
/// Calling this with invalid page tables will cause an immediate data abort.
fn enableMMU() void {
    const current_sctlr = readSCTLR_EL1();
    
    // Set required bits
    var new_sctlr = current_sctlr;
    new_sctlr |= SCTLR_M;   // Enable MMU
    new_sctlr |= SCTLR_C;   // Enable data cache
    new_sctlr |= SCTLR_I;   // Enable instruction cache
    new_sctlr |= SCTLR_A;   // Enable alignment check
    new_sctlr |= SCTLR_SA;  // Enable stack alignment check
    new_sctlr |= SCTLR_IESB; // Implicit Error Synchronization Barrier
    
    // Clear WXN if we want to execute in RW regions
    new_sctlr &= ~SCTLR_WXN;
    
    // Ensure instruction cache is enabled before enabling MMU
    isb();  // Instruction synchronization barrier
    
    writeSCTLR_EL1(new_sctlr);
    
    isb();  // Ensure MMU enable takes effect before returning
}

/// Disable the MMU
pub fn disableMMU() void {
    var sctlr = readSCTLR_EL1();
    sctlr &= ~SCTLR_M;
    writeSCTLR_EL1(sctlr);
    isb();
}

// ============================================================================
// TLB Operations
// ============================================================================

/// Instruction Synchronization Barrier
inline fn isb() void {
    asm volatile ("isb");
}

/// Data Synchronization Barrier
inline fn dsb() void {
    asm volatile ("dsb sy");
}

/// Data Memory Barrier
inline fn dmb() void {
    asm volatile ("dmb sy");
}

/// TLBI (TLB Invalidate) operations
/// 
/// TLBIALLE1: Invalidate all TLB entries for EL1
/// TLBI VAE1IS: Invalidate TLB by VA, inner shareable
/// TLBI ASIDE1IS: Invalidate by ASID, EL1, inner shareable
/// 
inline fn tlbiAllEL1() void {
    asm volatile ("tlbi alle1is");
    dsb();
    isb();
}

inline fn tlbiVAE1(vaddr: u64) void {
    // Combine address with 12-bit ASID (use 0 for global entries)
    const val = vaddr & 0xFFFF_FFFF_F000;
    asm volatile ("tlbi vae1is, %[val]"
        :
        : [val] "r" (val)
    );
    dsb();
    isb();
}

/// Flush TLB for a single address
pub fn flushTLB(vaddr: u64) void {
    tlbiVAE1(vaddr);
}

/// Flush entire TLB
pub fn flushTLBAll() void {
    tlbiAllEL1();
}

// ============================================================================
// Public Page Mapping API
// ============================================================================

/// P1 FIX: Public mapPage function for external use
/// Maps a virtual address to a physical address with the given attributes
/// Parameters:
///   - virt: Virtual address (must be 4KB aligned)
///   - phys: Physical address (must be 4KB aligned)
///   - attr_index: Memory attribute index (MAIR_EL1)
///   - ap: Access permission (AP_RW_PL1_RW, AP_RO_PL1_RO, etc.)
///   - nx: No-Execute flag
pub fn mapPage(virt: u64, phys: u64, attr_index: u3, ap: u2, nx: bool) bool {
    if (root_table_phys == 0) @panic("[MMU] Page tables not initialized");

    const pgd_i = pgdIndex(virt);
    const pud_i = pudIndex(virt);
    const pmd_i = pmdIndex(virt);
    const pt_i = ptIndex(virt);

    const pgd: [*]u64 = @ptrFromInt(root_table_phys);

    // Allocate PGD entry if needed
    if (pgd[pgd_i] == 0) {
        const pud_phys = allocPageTable() orelse return false;
        zeroPageTable(pud_phys);
        pgd[pgd_i] = makeTableDescriptor(pud_phys, attr_index, SH_INNER);
    }

    const pud_phys = pgd[pgd_i] & 0xFFFF_FFFF_F000;
    const pud: [*]u64 = @ptrFromInt(pud_phys);

    // Allocate PUD entry if needed
    if (pud[pud_i] == 0) {
        const pmd_phys = allocPageTable() orelse return false;
        zeroPageTable(pmd_phys);
        pud[pud_i] = makeTableDescriptor(pmd_phys, attr_index, SH_INNER);
    }

    const pmd_phys = pud[pud_i] & 0xFFFF_FFFF_F000;
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);

    // Allocate PMD entry if needed
    if (pmd[pmd_i] == 0) {
        const pt_phys = allocPageTable() orelse return false;
        zeroPageTable(pt_phys);
        pmd[pmd_i] = makeTableDescriptor(pt_phys, attr_index, SH_INNER);
    }

    const pt_phys = pmd[pmd_i] & 0xFFFF_FFFF_F000;
    const pt: [*]u64 = @ptrFromInt(pt_phys);

    // Map the page with AP and NX parameters
    pt[pt_i] = makePageDescriptor(phys, attr_index, ap, SH_INNER, nx);

    return true;
}

/// P2 FIX: Map a 2MB huge page at the PMD level
pub fn mapHugePage2MB(virt: u64, phys: u64, attr_index: u3, ap: u2, nx: bool) bool {
    if (root_table_phys == 0) @panic("[MMU] Page tables not initialized");

    // Validate 2MB alignment
    if ((virt & 0x1F_FFFF) != 0 or (phys & 0x1F_FFFF) != 0) {
        log.err("[MMU] mapHugePage2MB: addresses not 2MB-aligned", .{});
        return false;
    }

    const pgd_i = pgdIndex(virt);
    const pud_i = pudIndex(virt);
    const pmd_i = pmdIndex(virt);

    const pgd: [*]u64 = @ptrFromInt(root_table_phys);

    // Allocate PGD entry if needed
    if (pgd[pgd_i] == 0) {
        const pud_phys = allocPageTable() orelse return false;
        zeroPageTable(pud_phys);
        pgd[pgd_i] = makeTableDescriptor(pud_phys, attr_index, SH_INNER);
    }

    const pud_phys = pgd[pgd_i] & 0xFFFF_FFFF_F000;
    const pud: [*]u64 = @ptrFromInt(pud_phys);

    // Allocate PUD entry if needed
    if (pud[pud_i] == 0) {
        const pmd_phys = allocPageTable() orelse return false;
        zeroPageTable(pmd_phys);
        pud[pud_i] = makeTableDescriptor(pmd_phys, attr_index, SH_INNER);
    }

    const pmd_phys = pud[pud_i] & 0xFFFF_FFFF_F000;
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);

    // Create huge page descriptor at PMD level
    // For 2MB pages, the PT index field becomes part of the address
    const paddr_phys = phys;
    const ppn = (paddr_phys >> 21) & 0x7FFFFFF; // PPN[47:21]

    const entry = (@as(u64, ppn) << 21) |
                  (@as(u64, attr_index) << 2) |
                  (@as(u64, ap) << 6) |
                  (@as(u64, SH_INNER) << 8) |
                  (1 << 10) | // AF (Access Flag)
                  (@as(u64, @intFromBool(nx)) << 54) |
                  (1 << 1);   // Table descriptor bit

    pmd[pmd_i] = entry;

    log.debug("[MMU] Mapped 2MB huge page: VA 0x{x} -> PA 0x{x}", .{ virt, phys });
    return true;
}

/// P1 FIX: Public unmapPage function for external use
/// Removes the mapping for the given virtual address
pub fn unmapPage(virt: u64) bool {
    if (root_table_phys == 0) return false;

    const pgd_i = pgdIndex(virt);
    const pud_i = pudIndex(virt);
    const pmd_i = pmdIndex(virt);
    const pt_i = ptIndex(virt);

    const pgd: [*]u64 = @ptrFromInt(root_table_phys);

    // Check if PGD entry exists
    if (pgd[pgd_i] == 0) return false;

    const pud_phys = pgd[pgd_i] & 0xFFFF_FFFF_F000;
    const pud: [*]u64 = @ptrFromInt(pud_phys);

    // Check if PUD entry exists
    if (pud[pud_i] == 0) return false;

    const pmd_phys = pud[pud_i] & 0xFFFF_FFFF_F000;
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);

    // Check if PMD entry exists
    if (pmd[pmd_i] == 0) return false;

    const pt_phys = pmd[pmd_i] & 0xFFFF_FFFF_F000;
    const pt: [*]u64 = @ptrFromInt(pt_phys);

    // Clear the PTE
    pt[pt_i] = 0;

    // Flush TLB for this address
    flushTLB(virt);

    return true;
}

/// P0 FIX: Map a range of virtual addresses to physical pages
pub fn mapRange(virt_start: u64, phys_start: u64, page_count: usize, attr_index: u3, ap: u2, nx: bool) bool {
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const virt = virt_start + @as(u64, i) * PAGE_SIZE;
        const phys = phys_start + @as(u64, i) * PAGE_SIZE;
        if (!mapPage(virt, phys, attr_index, ap, nx)) {
            log.err("[MMU] mapRange: failed at page {}", .{i});
            return false;
        }
    }
    return true;
}

// ============================================================================
// ASID (Address Space ID) Support
// ============================================================================

/// P0 FIX: ASID management for user space address space switching
var asid_next: u16 = 1;
var asid_bitmap: [256]u64 = .{0} ** 256;

const MAX_ASID: u16 = 255;

/// P1 FIX: 跨核 TLB Shootdown 状态
var tlb_shootdown_in_progress: bool = false;

/// P0 FIX: Allocate a new ASID for a user address space
pub fn allocASID() ?u16 {
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const word_idx = i / 64;
        const bit_idx = @as(u6, @intCast(i % 64));
        if ((asid_bitmap[word_idx] & (@as(u64, 1) << bit_idx)) == 0) {
            asid_bitmap[word_idx] |= @as(u64, 1) << bit_idx;
            return @as(u16, @intCast(i));
        }
    }
    return null;
}

/// P0 FIX: Free an ASID
pub fn freeASID(asid: u16) void {
    if (asid == 0) return;
    const word_idx = @as(usize, @intCast(asid)) / 64;
    const bit_idx = @as(u6, @intCast(asid % 64));
    asid_bitmap[word_idx] &= ~(@as(u64, 1) << bit_idx);
}

/// P0 FIX: Switch to a user address space using ASID
/// This sets TTBR0_EL1 with the appropriate ASID for user space
pub fn switchAddressSpace(pgd_phys: u64, asid: u16) void {
    // TTBR1_EL1 holds the kernel page table (high VA)
    // TTBR0_EL1 holds the user page table (low VA) with ASID
    const ttbr0_val = pgd_phys | @as(u64, asid);
    writeTTBR0_EL1(ttbr0_val);
    dsb();
    isb();
}

/// P0 FIX: Create a new address space (new root page table)
pub fn createAddressSpace() ?u64 {
    const new_root = allocPageTable() orelse return null;
    zeroPageTable(new_root);
    return new_root;
}

/// P0 FIX: Activate a new address space (switch to it)
pub fn activateAddressSpace(pgd_phys: u64, asid: u16) void {
    switchAddressSpace(pgd_phys, asid);
}

/// P1 FIX: TLB Shootdown - 刷新远程 CPU 的 TLB
pub fn tlbShootdown() void {
    tlb_shootdown_in_progress = true;

    // 使用 ARM 的 TLBI VMALLS12E1IS 指令
    // 这会 Invalidate 所有与当前 ASID 相关的 TLB 条目
    asm volatile ("tlbi vmalls12e1is");
    dsb();
    isb();

    tlb_shootdown_in_progress = false;

    log.debug("[MMU] TLB shootdown completed", .{});
}

/// P1 FIX: TLB Shootdown for specific address
pub fn tlbShootdownAddr(vaddr: u64) void {
    tlb_shootdown_in_progress = true;

    // 使用 TLBI VAE1IS 指令
    // 将地址与当前 ASID 结合进行 TLB 无效化
    const val = vaddr & 0xFFFF_FFFF_F000;
    asm volatile ("tlbi vae1is, %[val]"
        :
        : [val] "r" (val)
    );
    dsb();
    isb();

    tlb_shootdown_in_progress = false;
}

/// P1 FIX: 获取 TLB shootdown 状态
pub fn isTLBShootdownInProgress() bool {
    return tlb_shootdown_in_progress;
}

// ============================================================================
// Address Translation
// ============================================================================

/// Translate a virtual address to physical using the AT instruction
/// Returns the physical address on success, null on translation failure
pub fn virtToPhys(virt: u64) ?u64 {
    // Use AT instruction to perform address translation
    // AT S1E1R, Xt -> performs a stage 1 translation at EL1 and writes to Xt
    var par: u64 = undefined;
    asm volatile ("at s1e1r, %[virt]"
        : [par] "=r" (par)
        : [virt] "r" (virt)
    );
    dsb();

    // Check for translation fault (bit 0 = 0 means success)
    if ((par & 1) == 0) {
        return par & 0xFFFF_FFFF_F000;  // Physical address (lower 48 bits)
    }
    return null;
}

/// Check if a virtual address is accessible
pub fn isVirtMapped(virt: u64) bool {
    return virtToPhys(virt) != null;
}

// ============================================================================
// Page Protection
// ============================================================================

/// P2 FIX: Page protection flags for AArch64
pub const ProtFlags = struct {
    read: bool,
    write: bool,
    exec: bool,
};

/// P2 FIX: 获取页面保护信息
pub fn getPageProtection(virt: u64) ?ProtFlags {
    if (root_table_phys == 0) return null;

    const pgd_i = pgdIndex(virt);
    const pud_i = pudIndex(virt);
    const pmd_i = pmdIndex(virt);
    const pt_i = ptIndex(virt);

    const pgd: [*]u64 = @ptrFromInt(root_table_phys);

    if (pgd[pgd_i] == 0) return null;

    const pud_phys = pgd[pgd_i] & 0xFFFF_FFFF_F000;
    const pud: [*]u64 = @ptrFromInt(pud_phys);

    if (pud[pud_i] == 0) return null;

    const pmd_phys = pud[pud_i] & 0xFFFF_FFFF_F000;
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);

    if (pmd[pmd_i] == 0) return null;

    const pt_phys = pmd[pmd_i] & 0xFFFF_FFFF_F000;
    const pt: [*]u64 = @ptrFromInt(pt_phys);

    if (pt[pt_i] == 0) return null;

    const pte = pt[pt_i];
    const ap = (pte >> 6) & 0x3;
    const uxn = (pte >> 54) & 0x1;

    return ProtFlags{
        .read = true,
        .write = (ap == 0),
        .exec = (uxn == 0),
    };
}

/// P2 FIX: 修改页面保护权限
pub fn protectPage(virt: u64, ap: u2, nx: bool) bool {
    if (root_table_phys == 0) return false;

    const pgd_i = pgdIndex(virt);
    const pud_i = pudIndex(virt);
    const pmd_i = pmdIndex(virt);
    const pt_i = ptIndex(virt);

    const pgd: [*]u64 = @ptrFromInt(root_table_phys);
    if (pgd[pgd_i] == 0) return false;

    const pud_phys = pgd[pgd_i] & 0xFFFF_FFFF_F000;
    const pud: [*]u64 = @ptrFromInt(pud_phys);
    if (pud[pud_i] == 0) return false;

    const pmd_phys = pud[pud_i] & 0xFFFF_FFFF_F000;
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);
    if (pmd[pmd_i] == 0) return false;

    const pt_phys = pmd[pmd_i] & 0xFFFF_FFFF_F000;
    const pt: [*]u64 = @ptrFromInt(pt_phys);
    if (pt[pt_i] == 0) return false;

    // 修改 AP 和 NX 位
    const old_pte = pt[pt_i];
    var new_pte = old_pte & ~(@as(u64, 0x3) << 6); // 清除旧 AP
    new_pte = new_pte & ~(@as(u64, 1) << 54); // 清除旧 NX
    new_pte = new_pte | (@as(u64, ap) << 6); // 设置新 AP
    new_pte = new_pte | (@as(u64, @intFromBool(nx)) << 54); // 设置新 NX

    pt[pt_i] = new_pte;

    // TLB 刷新
    flushTLB(virt);

    return true;
}

// ============================================================================
// Page Query
// ============================================================================

/// P2 FIX: Page query info
pub const PageInfo = struct {
    present: bool,
    phys: u64,
    attr_index: u3,
    ap: u2,
    nx: bool,
    shared: bool,
};

/// P2 FIX: 查询页面详细信息
pub fn queryPage(virt: u64) PageInfo {
    if (root_table_phys == 0) {
        return .{ .present = false, .phys = 0, .attr_index = 0, .ap = 0, .nx = false, .shared = false };
    }

    const pgd_i = pgdIndex(virt);
    const pud_i = pudIndex(virt);
    const pmd_i = pmdIndex(virt);
    const pt_i = ptIndex(virt);

    const pgd: [*]u64 = @ptrFromInt(root_table_phys);
    if (pgd[pgd_i] == 0) {
        return .{ .present = false, .phys = 0, .attr_index = 0, .ap = 0, .nx = false, .shared = false };
    }

    const pud_phys = pgd[pgd_i] & 0xFFFF_FFFF_F000;
    const pud: [*]u64 = @ptrFromInt(pud_phys);
    if (pud[pud_i] == 0) {
        return .{ .present = false, .phys = 0, .attr_index = 0, .ap = 0, .nx = false, .shared = false };
    }

    const pmd_phys = pud[pud_i] & 0xFFFF_FFFF_F000;
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);
    if (pmd[pmd_i] == 0) {
        return .{ .present = false, .phys = 0, .attr_index = 0, .ap = 0, .nx = false, .shared = false };
    }

    const pt_phys = pmd[pmd_i] & 0xFFFF_FFFF_F000;
    const pt: [*]u64 = @ptrFromInt(pt_phys);
    if (pt[pt_i] == 0) {
        return .{ .present = false, .phys = 0, .attr_index = 0, .ap = 0, .nx = false, .shared = false };
    }

    const pte = pt[pt_i];
    return .{
        .present = true,
        .phys = (pte >> 12) << 12 | (virt & 0xFFF),
        .attr_index = @truncate((pte >> 2) & 0x7),
        .ap = @truncate((pte >> 6) & 0x3),
        .nx = ((pte >> 54) & 0x1) != 0,
        .shared = ((pte >> 8) & 0x3) == 3, // Inner shareable
    };
}

// ============================================================================
// MMU Statistics
// ============================================================================

/// P2 FIX: 获取 MMU 统计信息
pub const MMUStats = struct {
    root_table_phys: u64,
    mair_el1: u64,
    tcr_el1: u64,
    sctlr_el1: u64,
    mmu_enabled: bool,
};

/// P2 FIX: 获取 MMU 统计
pub fn getStats() MMUStats {
    const sctlr = readSCTLR_EL1();
    return .{
        .root_table_phys = root_table_phys,
        .mair_el1 = readMAIR_EL1(),
        .tcr_el1 = readTCR_EL1(),
        .sctlr_el1 = sctlr,
        .mmu_enabled = (sctlr & SCTLR_M) != 0,
    };
}

/// P2 FIX: 打印 MMU 状态
pub fn dumpState() void {
    const stats = getStats();

    log.info("=== AArch64 MMU State ===", .{});
    log.info("  Root table PA:  0x{x}", .{stats.root_table_phys});
    log.info("  MAIR_EL1:       0x{x}", .{stats.mair_el1});
    log.info("  TCR_EL1:        0x{x}", .{stats.tcr_el1});
    log.info("  SCTLR_EL1:      0x{x}", .{stats.sctlr_el1});
    log.info("  MMU enabled:    {}", .{stats.mmu_enabled});
}

// ============================================================================
// Initialization
// ============================================================================

/// Initialize the MMU with kernel identity mapping
pub fn init() void {
    if (initialized) return;
    
    log.info("[MMU]  AArch64 4-level page tables (4KB granule, 48-bit VA)", .{});
    
    // Step 1: Configure MAIR
    initMAIR();
    
    // Step 2: Configure TCR
    initTCR();
    
    // Step 3: Create page tables
    initPageTables();
    
    // Step 4: Map kernel identity region
    // Map first 1GB of memory with identity mapping for early boot
    // Virt = Phys for this region (boot region)
    const boot_size = 0x4000_0000; // 1GB
    if (!mapKernelRegion(0, 0, boot_size, MAIR_ATTR_NORMAL_WB, AP_RW_PL1_RW)) {
        @panic("[MMU] Failed to map kernel boot region");
    }
    log.info("[MMU]  Boot region mapped: 0x0 -> 0x0 ({} MB)", .{boot_size / 0x100000});
    
    // Step 5: Set TTBR0 (for user space)
    // For now, use the same root table
    // TODO: Implement ASID-based switching for user space
    writeTTBR0_EL1(root_table_phys);
    
    // Step 6: Set TTBR1 (for kernel space - high addresses)
    writeTTBR1_EL1(root_table_phys);
    
    // Step 7: Enable MMU
    enableMMU();
    
    initialized = true;
    log.info("[MMU]  MMU enabled successfully", .{});
}

pub fn isInitialized() bool {
    return initialized;
}
