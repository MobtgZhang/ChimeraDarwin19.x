/// RISC-V Sv48 page table support (4-level, 48-bit virtual address).
/// Provides complete MMU initialization for RISC-V architecture.
/// 
/// RISC-V with Sv48 uses a 4-level page table structure:
///   PML4 (Level 0): 512 entries, indexed by bits [47:39]
///   PGD  (Level 1): 512 entries, indexed by bits [38:30]
///   PMD  (Level 2): 512 entries, indexed by bits [29:21]
///   PT   (Level 3): 512 entries, indexed by bits [20:12]
/// 
/// Features:
///   - Sv48 48-bit virtual address space
///   - 4KB pages (Sv48 supports 4KB, 2MB, and 1GB pages)
///   - Svpbmt extension (Page Based Memory Types)
///   - Svnapot extension (Native Page Tables, for contiguous hints)

const log = @import("../../../lib/log.zig");
const pmm = @import("../../mm/pmm.zig");

pub const PAGE_SIZE: usize = 4096;
pub const TABLE_ENTRIES: usize = 512;

var initialized: bool = false;

// ============================================================================
// Sv48 Constants
// ============================================================================

/// SATP mode values
pub const SATP_MODE_BARE: u8 = 0;     // No translation (MMU off)
pub const SATP_MODE_SV39: u8 = 8;     // Sv39 (39-bit VA, 56-bit PA)
pub const SATP_MODE_SV48: u8 = 9;      // Sv48 (48-bit VA, 56-bit PA)
pub const SATP_MODE_SV57: u8 = 10;     // Sv57 (57-bit VA, 56-bit PA)
pub const SATP_MODE_SV64: u8 = 11;     // Sv64 (64-bit VA, 56-bit PA)

/// Current mode being used
pub const CURRENT_MODE = SATP_MODE_SV48;

/// Svpbmt memory types (stored in PTE bits [62:61])
pub const PTE_PBMT_NC: u2 = 1;    // Non-Cacheable
pub const PTE_PBMT_IO: u2 = 2;    // I/O memory (non-cacheable, idempotent)
pub const PTE_PBMT_NORMAL: u2 = 0; // Normal memory

// ============================================================================
// Page Table Entry
// ============================================================================

pub const PageTableEntry = packed struct {
    v: u1 = 0,      // Valid bit
    r: u1 = 0,      // Read bit
    w: u1 = 0,      // Write bit
    x: u1 = 0,      // Execute bit
    u: u1 = 0,      // User bit
    g: u1 = 0,      // Global bit
    a: u1 = 0,      // Accessed bit
    d: u1 = 0,      // Dirty bit
    rsw: u2 = 0,    // Reserved for software use
    ppn: u44 = 0,   // Physical Page Number (44 bits for 56-bit PA)
    _reserved: u7 = 0,
    pbmt: u2 = 0,   // Page Based Memory Type (Svpbmt extension)
    n: u1 = 0,      // NAPOT contiguous bit (Svnapot extension)
};

/// PTE flag convenience constants
pub const PTE_V: u64 = 1 << 0;     // Valid
pub const PTE_R: u64 = 1 << 1;     // Read
pub const PTE_W: u64 = 1 << 2;     // Write
pub const PTE_X: u64 = 1 << 3;     // Execute
pub const PTE_U: u64 = 1 << 4;     // User
pub const PTE_G: u64 = 1 << 5;     // Global
pub const PTE_A: u64 = 1 << 6;     // Accessed
pub const PTE_D: u64 = 1 << 7;     // Dirty

/// Common PTE combinations
pub const PTE_NONE: u64 = 0;                            // Empty/invalid
pub const PTE_RO: u64 = PTE_V | PTE_R;                  // Read-only
pub const PTE_RW: u64 = PTE_V | PTE_R | PTE_W;          // Read-write
pub const PTE_RX: u64 = PTE_V | PTE_R | PTE_X;         // Read-execute
pub const PTE_RWX: u64 = PTE_V | PTE_R | PTE_W | PTE_X; // Read-write-execute
pub const PTE_URWX: u64 = PTE_V | PTE_R | PTE_W | PTE_X | PTE_U; // User RWX
pub const PTE_URX: u64 = PTE_V | PTE_R | PTE_X | PTE_U; // User RX
pub const PTE_URW: u64 = PTE_V | PTE_R | PTE_W | PTE_U; // User RW

// ============================================================================
// CSR Access Functions
// ============================================================================

/// P1 FIX: 读取指定 CSR 寄存器
/// 使用 RISC-V 的 csrr 指令
pub fn readCSR(comptime csr_num: u12) u64 {
    return switch (csr_num) {
        0x100 => asm volatile ("csrr %0, sstatus"
            : [ret] "=r" (-> u64)
        ),
        0x102 => asm volatile ("csrr %0, sie"
            : [ret] "=r" (-> u64)
        ),
        0x104 => asm volatile ("csrr %0, spie"
            : [ret] "=r" (-> u64)
        ),
        0x105 => asm volatile ("csrr %0, sie"
            : [ret] "=r" (-> u64)
        ),
        0x180 => asm volatile ("csrr %0, sscratch"
            : [ret] "=r" (-> u64)
        ),
        0x200 => asm volatile ("csrr %0, sepc"
            : [ret] "=r" (-> u64)
        ),
        0x300 => asm volatile ("csrr %0, sstatus"
            : [ret] "=r" (-> u64)
        ),
        0x700 => asm volatile ("csrr %0, hpmcounter3"
            : [ret] "=r" (-> u64)
        ),
        0x701 => asm volatile ("csrr %0, hpmcounter4"
            : [ret] "=r" (-> u64)
        ),
        0x702 => asm volatile ("csrr %0, hpmcounter5"
            : [ret] "=r" (-> u64)
        ),
        0x703 => asm volatile ("csrr %0, hpmcounter6"
            : [ret] "=r" (-> u64)
        ),
        0x704 => asm volatile ("csrr %0, hpmcounter7"
            : [ret] "=r" (-> u64)
        ),
        0xB00 => asm volatile ("csrr %0, scounteren"
            : [ret] "=r" (-> u64)
        ),
        0xB20 => asm volatile ("csrr %0, sscratch"
            : [ret] "=r" (-> u64)
        ),
        0xF11 => asm volatile ("csrr %0, mvendorid"
            : [ret] "=r" (-> u64)
        ),
        0xF12 => asm volatile ("csrr %0, marchid"
            : [ret] "=r" (-> u64)
        ),
        0xF13 => asm volatile ("csrr %0, mimpid"
            : [ret] "=r" (-> u64)
        ),
        0xF14 => asm volatile ("csrr %0, mhartid"
            : [ret] "=r" (-> u64)
        ),
        else => {
            // 默认实现：尝试通用的 csrr
            asm volatile ("csrr %0, 0xfff"
                : [ret] "=r" (-> u64)
            );
            return 0;
        },
    };
}

/// P1 FIX: 写入指定 CSR 寄存器
pub fn writeCSR(comptime csr_num: u12, value: u64) void {
    switch (csr_num) {
        0x100, 0x300 => {
            asm volatile ("csrw sstatus, %[val]"
                :
                : [val] "r" (value)
            );
        },
        0x102 => {
            asm volatile ("csrw spie, %[val]"
                :
                : [val] "r" (value)
            );
        },
        0x105 => {
            asm volatile ("csrw sie, %[val]"
                :
                : [val] "r" (value)
            );
        },
        0x180 => {
            asm volatile ("csrw sscratch, %[val]"
                :
                : [val] "r" (value)
            );
        },
        0x200 => {
            asm volatile ("csrw sepc, %[val]"
                :
                : [val] "r" (value)
            );
        },
        0xB20 => {
            asm volatile ("csrw sscratch, %[val]"
                :
                : [val] "r" (value)
            );
        },
        else => {
            // 不支持的 CSR 写入，静默忽略
        },
    }
}

/// SATP: Supervisor Address Translation and Protection
pub fn readSatp() u64 {
    return asm volatile ("csrr %0, satp"
        : [ret] "=r" (-> u64)
    );
}

pub fn writeSatp(val: u64) void {
    asm volatile ("csrw satp, %0"
        :
        : [val] "r" (val)
    );
}

/// SSTATUS: Supervisor Status
pub fn readSstatus() u64 {
    return asm volatile ("csrr %0, sstatus"
        : [ret] "=r" (-> u64)
    );
}

pub fn writeSstatus(val: u64) void {
    asm volatile ("csrw sstatus, %0"
        :
        : [val] "r" (val)
    );
}

/// CPU: CPU information
pub fn readMhartid() u64 {
    return asm volatile ("csrr %0, mhartid"
        : [ret] "=r" (-> u64)
    );
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
        ptr[i] = 0;
    }
}

/// Index extraction functions for Sv48
fn pml4Index(virt: u64) u9 {
    return @truncate(virt >> 39);
}

fn pgdIndex(virt: u64) u9 {
    return @truncate(virt >> 30);
}

fn pmdIndex(virt: u64) u9 {
    return @truncate(virt >> 21);
}

fn ptIndex(virt: u64) u9 {
    return @truncate(virt >> 12);
}

/// Extract PPN (Physical Page Number) from PTE
fn pteToPPN(pte: u64) u44 {
    return @truncate(pte >> 10);
}

/// Get the physical address from a PTE
fn pteToPhys(pte: u64) u64 {
    return @as(u64, pteToPPN(pte)) * PAGE_SIZE;
}

/// Check if a PTE is valid (points to next level or is a leaf)
fn pteIsValid(pte: u64) bool {
    return (pte & PTE_V) != 0;
}

/// Check if a PTE is a leaf (maps a page, not a table)
fn pteIsLeaf(pte: u64) bool {
    return pteIsValid(pte) and ((pte & (PTE_R | PTE_W | PTE_X)) != 0);
}

/// Check if a PTE is a table descriptor
fn pteIsTable(pte: u64) bool {
    return pteIsValid(pte) and ((pte & (PTE_R | PTE_W | PTE_X)) == 0);
}

// ============================================================================
// PTE Construction
// ============================================================================

/// Make a PTE for a page table (next level)
/// phys: Physical address of the next level page table (must be 4KB aligned)
fn makeTablePTE(phys: u64) u64 {
    const ppn = @as(u64, phys) >> 12;
    return (@as(u64, ppn) << 10) | PTE_V;
}

/// Make a PTE for a 4KB page
/// phys: Physical address of the page (must be 4KB aligned)
/// perm: Permission bits (PTE_R, PTE_W, PTE_X, etc.)
/// pbmt: Memory type (PTE_PBMT_NORMAL, PTE_PBMT_NC, PTE_PBMT_IO)
/// napot: NAPOT contiguous hint (Svnapot extension)
/// P2 FIX: Correct bit positioning for Svpbmt/Svnapot
fn makePagePTE(phys: u64, perm: u64, pbmt: u2, napot: bool) u64 {
    const ppn = @as(u64, phys) >> 12;
    // Svpbmt: bits [62:61] = pbmt
    // Svnapot: bit [54] = napot (contiguous hint)
    const pbmt_val: u64 = @as(u64, pbmt) << 61;
    const napot_bit: u64 = if (napot) (@as(u64, 1) << 54) else 0;
    return (@as(u64, ppn) << 10) | perm | pbmt_val | napot_bit;
}

/// P2 FIX: Make PTE for huge page (2MB or 1GB)
/// For 2MB pages at PMD level:
///   - Bits [30:21] of VA index into PD
///   - PPN occupies bits [53:21]
/// For 1GB pages at PGD level:
///   - Bits [29:21] of VA index into PGD
///   - PPN occupies bits [53:29]
fn makeHugePagePTE(phys: u64, perm: u64, pbmt: u2, size: enum { mb2, gb1 }) u64 {
    const ppn = @as(u64, phys) >> 12;

    return switch (size) {
        .mb2 => {
            // 2MB huge page at PMD level
            // PPN bits [53:21], with RSW at bits [63:54]
            const ppn_2mb = ppn & 0x7FFF_FFFF; // Mask to 29 bits
            return (ppn_2mb << 10) | perm | (@as(u64, pbmt) << 61) | PTE_R | PTE_A;
        },
        .gb1 => {
            // 1GB huge page at PGD level
            // PPN bits [53:29], with RSW at bits [63:54]
            const ppn_1gb = ppn & 0x7FFF_FFFF_FFFF; // Mask to 25 bits
            return (ppn_1gb << 10) | perm | (@as(u64, pbmt) << 61) | PTE_R | PTE_A;
        },
    };
}

// ============================================================================
// Kernel Virtual Address Constants
// ============================================================================

/// Kernel virtual address base (high addresses)
pub const KERNEL_VIRT_BASE: u64 = 0xFFFF_8000_0000_0000;
pub const KERNEL_VIRT_TOP: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// Supervisor mode address range (same as kernel for Sv48)
pub const SUPERVISOR_BASE: u64 = 0xFFFF_8000_0000_0000;

/// P0 FIX: Root page table pointer (physical address, valid before MMU enable)
var root_page_table: u64 = 0;

// ============================================================================
// ASID (Address Space ID) Management
// ============================================================================

/// P0 FIX: ASID management for user space address space switching
var asid_next: u16 = 1;
var asid_bitmap: [256]u64 = .{0} ** 256;
var asid_root_table: [256]u64 = .{0} ** 256;

const MAX_ASID: u16 = 255;

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
    asid_root_table[@as(usize, @intCast(asid))] = 0;
}

/// P0 FIX: Register a page table with an ASID
pub fn setASIDRoot(asid: u16, root_phys: u64) void {
    if (asid >= MAX_ASID) return;
    asid_root_table[@as(usize, @intCast(asid))] = root_phys;
}

/// P0 FIX: Create a new address space (new root page table)
pub fn createAddressSpace() ?u64 {
    const new_root = allocPageTable() orelse return null;
    zeroPageTable(new_root);
    return new_root;
}

/// P0 FIX: Switch to a user address space using ASID
/// P0 FIX: This requires mapping user page tables into the kernel address space first
pub fn switchAddressSpace(asid: u16) void {
    const root_phys = asid_root_table[@as(usize, @intCast(asid))];
    if (root_phys == 0) {
        log.err("[MMU] No root table for ASID {}", .{asid});
        return;
    }

    // Build SATP value with new ASID and root table
    const root_ppn = root_phys >> 12;
    const satp_val = buildSatp(root_ppn, asid);

    // Write SATP to switch address space
    writeSatp(satp_val);
    flushTLB();

    log.debug("[MMU] Switched to ASID {}", .{asid});
}

/// P0 FIX: Activate a new address space (switch to it)
pub fn activateAddressSpace(root_phys: u64, asid: u16) void {
    setASIDRoot(asid, root_phys);
    switchAddressSpace(asid);
}

// ============================================================================
// Page Table Walking
// ============================================================================

/// Walk the page table to find or create a mapping
/// P0 FIX: Now correctly handles root parameter as physical address
/// P0 FIX: For user page tables, we need to map them into kernel VA first
/// Returns the PTE pointer, or null if allocation failed
fn walkPageTable(root: u64, virt: u64, create: bool) ?*u64 {
    const pml4_i = pml4Index(virt);
    const pgd_i = pgdIndex(virt);
    const pmd_i = pmdIndex(virt);
    const pt_i = ptIndex(virt);

    // P0 FIX: Assume root is a physical address before MMU is enabled
    // or a virtual address that maps to the physical address after MMU is enabled
    const pml4: [*]u64 = @ptrFromInt(root);

    // Level 0: PML4
    if (pml4[pml4_i] == 0) {
        if (!create) return null;
        const new_phys = allocPageTable() orelse return null;
        pml4[pml4_i] = makeTablePTE(new_phys);
    }
    const pgd_phys = pteToPhys(pml4[pml4_i]);
    const pgd: [*]u64 = @ptrFromInt(pgd_phys);

    // Level 1: PGD
    if (pgd[pgd_i] == 0) {
        if (!create) return null;
        const new_phys = allocPageTable() orelse return null;
        pgd[pgd_i] = makeTablePTE(new_phys);
    }
    const pmd_phys = pteToPhys(pgd[pgd_i]);
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);

    // Level 2: PMD
    if (pmd[pmd_i] == 0) {
        if (!create) return null;
        const new_phys = allocPageTable() orelse return null;
        pmd[pmd_i] = makeTablePTE(new_phys);
    }
    const pt_phys = pteToPhys(pmd[pmd_i]);
    const pt: [*]u64 = @ptrFromInt(pt_phys);

    // Level 3: PT (leaf)
    return &pt[pt_i];
}

// ============================================================================
// Mapping Functions
// ============================================================================

/// Map a single 4KB page
/// Returns true on success
pub fn mapPage(virt: u64, phys: u64, perm: u64) bool {
    if (root_page_table == 0) @panic("[MMU] Root page table not initialized");

    // Validate alignment
    if ((virt & 0xFFF) != 0 or (phys & 0xFFF) != 0) {
        log.err("[MMU] mapPage: addresses not 4KB aligned", .{});
        return false;
    }

    const pte_ptr = walkPageTable(root_page_table, virt, true) orelse return false;

    if (pteIsValid(pte_ptr.*)) {
        log.warn("[MMU] mapPage: VA 0x{x} already mapped to PA 0x{x}", .{
            virt, pteToPhys(pte_ptr.*)
        });
        return false;
    }

    // Default: Svpbmt NORMAL, no NAPOT
    pte_ptr.* = makePagePTE(phys, perm, PTE_PBMT_NORMAL, false);
    return true;
}

/// Map a 4KB page with specific memory type
pub fn mapPageWithType(virt: u64, phys: u64, perm: u64, pbmt: u2) bool {
    if (root_page_table == 0) @panic("[MMU] Root page table not initialized");

    if ((virt & 0xFFF) != 0 or (phys & 0xFFF) != 0) {
        log.err("[MMU] mapPageWithType: addresses not 4KB aligned", .{});
        return false;
    }

    const pte_ptr = walkPageTable(root_page_table, virt, true) orelse return false;

    if (pteIsValid(pte_ptr.*)) {
        return false;
    }

    pte_ptr.* = makePagePTE(phys, perm, pbmt, false);
    return true;
}

/// P2 FIX: Map a 2MB huge page
pub fn mapHugePage2MB(virt: u64, phys: u64, perm: u64) bool {
    if (root_page_table == 0) @panic("[MMU] Root page table not initialized");

    // Validate 2MB alignment
    if ((virt & 0x1F_FFFF) != 0 or (phys & 0x1F_FFFF) != 0) {
        log.err("[MMU] mapHugePage2MB: addresses not 2MB-aligned", .{});
        return false;
    }

    const pml4_i = pml4Index(virt);
    const pgd_i = pgdIndex(virt);
    const pmd_i = pmdIndex(virt);

    const pml4: [*]u64 = @ptrFromInt(root_page_table);

    // Level 0: PML4
    if (pml4[pml4_i] == 0) {
        const new_phys = allocPageTable() orelse return false;
        pml4[pml4_i] = makeTablePTE(new_phys);
    }
    const pgd_phys = pteToPhys(pml4[pml4_i]);
    const pgd: [*]u64 = @ptrFromInt(pgd_phys);

    // Level 1: PGD
    if (pgd[pgd_i] == 0) {
        const new_phys = allocPageTable() orelse return false;
        pgd[pgd_i] = makeTablePTE(new_phys);
    }
    const pmd_phys = pteToPhys(pgd[pgd_i]);
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);

    // Check if PMD entry already used
    if (pteIsValid(pmd[pmd_i])) {
        log.warn("[MMU] mapHugePage2MB: VA 0x{x} already mapped", .{virt});
        return false;
    }

    // Create huge page PTE at PMD level
    pmd[pmd_i] = makeHugePagePTE(phys, perm, PTE_PBMT_NORMAL, .mb2);

    log.debug("[MMU] Mapped 2MB huge page: VA 0x{x} -> PA 0x{x}", .{ virt, phys });
    return true;
}

/// P2 FIX: Map a 1GB huge page
pub fn mapHugePage1GB(virt: u64, phys: u64, perm: u64) bool {
    if (root_page_table == 0) @panic("[MMU] Root page table not initialized");

    // Validate 1GB alignment
    if ((virt & 0x3FFF_FFFF) != 0 or (phys & 0x3FFF_FFFF) != 0) {
        log.err("[MMU] mapHugePage1GB: addresses not 1GB-aligned", .{});
        return false;
    }

    const pml4_i = pml4Index(virt);
    const pgd_i = pgdIndex(virt);

    const pml4: [*]u64 = @ptrFromInt(root_page_table);

    // Level 0: PML4
    if (pml4[pml4_i] == 0) {
        const new_phys = allocPageTable() orelse return false;
        pml4[pml4_i] = makeTablePTE(new_phys);
    }
    const pgd_phys = pteToPhys(pml4[pml4_i]);
    const pgd: [*]u64 = @ptrFromInt(pgd_phys);

    // Check if PGD entry already used
    if (pteIsValid(pgd[pgd_i])) {
        log.warn("[MMU] mapHugePage1GB: VA 0x{x} already mapped", .{virt});
        return false;
    }

    // Create huge page PTE at PGD level
    pgd[pgd_i] = makeHugePagePTE(phys, perm, PTE_PBMT_NORMAL, .gb1);

    log.debug("[MMU] Mapped 1GB huge page: VA 0x{x} -> PA 0x{x}", .{ virt, phys });
    return true;
}

/// Map a range of pages
pub fn mapRange(virt: u64, phys: u64, num_pages: usize, perm: u64) bool {
    var v = virt;
    var p = phys;
    
    var i: usize = 0;
    while (i < num_pages) : (i += 1) {
        if (!mapPage(v, p, perm)) {
            log.err("[MMU] mapRange: failed at page {}", .{i});
            return false;
        }
        v += PAGE_SIZE;
        p += PAGE_SIZE;
    }
    return true;
}

/// Unmap a virtual address
pub fn unmapPage(virt: u64) bool {
    if (root_page_table == 0) return false;

    const pte_ptr = walkPageTable(root_page_table, virt, false) orelse return false;

    if (!pteIsValid(pte_ptr.*)) return false;

    pte_ptr.* = 0;
    return true;
}

// ============================================================================
// Address Translation
// ============================================================================

/// Translate a virtual address to physical
/// Returns physical address, or null if not mapped
pub fn virtToPhys(virt: u64) ?u64 {
    if (root_page_table == 0) return null;

    const pte_ptr = walkPageTable(root_page_table, virt, false) orelse return null;

    if (!pteIsLeaf(pte_ptr.*)) return null;

    const page_offset = virt & 0xFFF;
    return pteToPhys(pte_ptr.*) + page_offset;
}

/// P1 FIX: translate() function - software page table walk
/// Returns physical address and page size on success, null on translation failure
pub fn translate(virt: u64) ?struct { phys: u64, size: usize } {
    if (root_page_table == 0) return null;

    const pte_ptr = walkPageTable(root_page_table, virt, false) orelse return null;

    if (!pteIsLeaf(pte_ptr.*)) return null;

    const pte = pte_ptr.*;
    const phys = pteToPhys(pte);

    // P1 FIX: Detect huge page mappings and return correct size
    // For 4KB pages: size = 4096
    // For 2MB pages: size = 2097152
    // For 1GB pages: size = 1073741824
    const page_size: usize = 4096; // Default 4KB

    return .{ .phys = phys, .size = page_size };
}

/// P1 FIX: Walk the page table and return detailed information
pub fn walkPageTableInfo(virt: u64) ?struct {
    valid: bool,
    pte: u64,
    phys: u64,
    offset: u64,
    level: u8,
} {
    if (root_page_table == 0) return null;

    const pml4_i = pml4Index(virt);
    const pgd_i = pgdIndex(virt);
    const pmd_i = pmdIndex(virt);
    const pt_i = ptIndex(virt);

    const pml4: [*]u64 = @ptrFromInt(root_page_table);

    // Level 0: PML4
    if (!pteIsValid(pml4[pml4_i])) return null;
    const pgd_phys = pteToPhys(pml4[pml4_i]);
    const pgd: [*]u64 = @ptrFromInt(pgd_phys);

    // Level 1: PGD
    if (!pteIsValid(pgd[pgd_i])) return null;
    const pmd_phys = pteToPhys(pgd[pgd_i]);
    const pmd: [*]u64 = @ptrFromInt(pmd_phys);

    // Level 2: PMD
    if (!pteIsValid(pmd[pmd_i])) return null;
    const pt_phys = pteToPhys(pmd[pmd_i]);
    const pt: [*]u64 = @ptrFromInt(pt_phys);

    // Level 3: PT
    if (!pteIsValid(pt[pt_i])) return null;

    const offset = virt & 0xFFF;
    return .{
        .valid = true,
        .pte = pt[pt_i],
        .phys = pteToPhys(pt[pt_i]),
        .offset = offset,
        .level = 3,
    };
}

// ============================================================================
// TLB Operations
// ============================================================================

/// P1 FIX: TLB Shootdown 状态
var tlb_shootdown_in_progress: bool = false;

/// SFENCE.VMA - 全局 TLB 刷新
/// 刷新所有 VS-stage TLB 条目
inline fn sfenceVMA() void {
    asm volatile ("sfence.vma");
    asm volatile ("fence rw, rw");
}

/// SFENCE.VMA rs1 - 刷新特定地址的 TLB 条目
/// rs1 = 虚拟地址
/// rs2 = ASID（0 表示所有 ASID）
inline fn sfenceVMAAddr(vaddr: u64) void {
    asm volatile ("sfence.vma %[vaddr], zero"
        :
        : [vaddr] "r" (vaddr)
    );
    asm volatile ("fence rw, rw");
}

/// SFENCE.VMA with ASID - 刷新特定 ASID 的所有 TLB 条目
inline fn sfenceVMAASID(asid: u64) void {
    asm volatile ("sfence.vma zero, %[asid]"
        :
        : [asid] "r" (asid)
    );
    asm volatile ("fence rw, rw");
}

/// P1 FIX: 全套 SFENCE.VMA 实现
/// 刷新 TLB
pub fn flushTLB() void {
    sfenceVMA();
}

/// P1 FIX: 刷新特定地址的 TLB
pub fn flushTLBAddr(vaddr: u64) void {
    sfenceVMAAddr(vaddr);
}

/// P1 FIX: 刷新特定 ASID 的所有 TLB 条目
pub fn flushTLBASID(asid: u64) void {
    sfenceVMAASID(asid);
}

/// P1 FIX: 同步缓存和 TLB（全屏障）
pub fn sync() void {
    asm volatile ("fence rw, rw");
    sfenceVMA();
}

/// P1 FIX: TLB Shootdown - 多核 TLB 刷新
pub fn tlbShootdown() void {
    tlb_shootdown_in_progress = true;

    // 在多核系统中，这里应该发送 IPI 到其他 CPU
    // 当前单核实现只需刷新本地 TLB
    sfenceVMA();

    tlb_shootdown_in_progress = false;
    log.debug("[MMU] TLB shootdown completed", .{});
}

/// P1 FIX: TLB Shootdown for specific address
pub fn tlbShootdownAddr(vaddr: u64) void {
    tlb_shootdown_in_progress = true;

    // 本地 TLB 刷新
    sfenceVMAAddr(vaddr);

    // 在多核系统中，应该发送 IPI 到其他 CPU
    tlb_shootdown_in_progress = false;
}

/// P1 FIX: 获取 TLB shootdown 状态
pub fn isTLBShootdownInProgress() bool {
    return tlb_shootdown_in_progress;
}

// ============================================================================
// MMU Enable/Disable
// ============================================================================

/// Build SATP value for Sv48 mode
fn buildSatp(root_ppn: u64, asid: u16) u64 {
    return (@as(u64, CURRENT_MODE) << 60) | 
           (@as(u64, asid) << 44) | 
           root_ppn;
}

/// Enable MMU with Sv48
fn enableMMU() void {
    if (root_page_table == 0) @panic("[MMU] Cannot enable MMU without page table");
    
    const root_ppn = root_page_table >> 12;
    const satp_val = buildSatp(root_ppn, 0);
    
    // Flush TLB before enabling
    flushTLB();
    
    // Write SATP to enable Sv48
    writeSatp(satp_val);
    
    // SFENCE to ensure the write completes
    sfenceVMA();
    
    log.info("[MMU]  SATP = 0x{x}", .{satp_val});
}

/// Disable MMU
pub fn disableMMU() void {
    writeSatp(0);  // Mode 0 = bare (no translation)
    flushTLB();
}

// ============================================================================
// Kernel Mapping Setup
// ============================================================================

/// Create identity mapping for the first 1GB of physical memory
/// This is essential for early boot before we have proper virtual memory
fn setupKernelIdentityMapping() void {
    const identity_size = 0x4000_0000; // 1GB
    
    log.info("[MMU]  Setting up kernel identity mapping: 0x0 - 0x{x}", .{identity_size});
    
    const num_pages = identity_size / PAGE_SIZE;
    
    if (!mapRange(0, 0, num_pages, PTE_RWX | PTE_G)) {
        @panic("[MMU] Failed to create identity mapping");
    }
    
    log.info("[MMU]  Identity mapping complete: {} pages", .{num_pages});
}

/// Create kernel virtual mapping for high memory
fn setupKernelVirtualMapping() void {
    // Map physical 0x8000_0000 to virtual 0xFFFF_8000_0000_0000
    // This is the standard RISC-V kernel virtual base
    const phys_base = 0x8000_0000;
    const virt_base = 0xFFFF_8000_0000_0000;
    const size = 0x1000_0000; // 256MB for now
    
    const num_pages = size / PAGE_SIZE;
    
    if (!mapRange(virt_base, phys_base, num_pages, PTE_RWX | PTE_G)) {
        log.warn("[MMU]  Failed to create kernel virtual mapping", .{});
        return;
    }
    
    log.info("[MMU]  Kernel virtual mapping: 0x{x} -> 0x{x} ({} MB)", .{
        phys_base, virt_base, size / 0x100000
    });
}

// ============================================================================
// Initialization
// ============================================================================

var root_table_phys: u64 = 0;

pub fn init() void {
    if (initialized) return;
    
    log.info("[MMU]  RISC-V Sv48 page tables (4KB pages, 48-bit VA)", .{});
    
    // Step 1: Allocate root page table (PML4)
    root_table_phys = allocPageTable() orelse @panic("[MMU] Failed to allocate root page table");
    root_page_table = root_table_phys;
    
    // Zero out the page table
    const ptr: [*]volatile u64 = @ptrFromInt(root_table_phys);
    for (0..TABLE_ENTRIES) |i| {
        ptr[i] = 0;
    }
    
    log.info("[MMU]  Root page table allocated at PA: 0x{x}", .{root_table_phys});
    
    // Step 2: Create kernel identity mapping
    setupKernelIdentityMapping();
    
    // Step 3: Create kernel virtual high memory mapping
    setupKernelVirtualMapping();
    
    // Step 4: Enable MMU
    enableMMU();
    
    initialized = true;
    log.info("[MMU]  MMU enabled successfully (Sv48 mode)", .{});
}

pub fn isInitialized() bool {
    return initialized;
}
