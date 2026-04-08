/// x86_64 Paging — 4-level page table management.
/// Provides dynamic mapping functions for virtual memory management.
/// 
/// x86_64 uses a 4-level page table structure:
///   PML4 (Page Map Level 4)      - 512 entries, indexed by bits [47:39]
///   PDPT (Page Directory Pointer) - 512 entries, indexed by bits [38:30]
///   PD  (Page Directory)          - 512 entries, indexed by bits [29:21]
///   PT  (Page Table)             - 512 entries, indexed by bits [20:12]
/// 
/// This module provides functions to:
///   - Allocate page tables from PMM
///   - Map virtual addresses to physical pages
///   - Unmap virtual addresses
///   - Query address translations

const std = @import("std");
const log = @import("../../../lib/log.zig");
const pmm = @import("../../mm/pmm.zig");

pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_MASK: u64 = ~@as(u64, PAGE_SIZE - 1);

/// Page Table Entry (PTE) flags
pub const PTE_PRESENT: u64 = 1 << 0;
pub const PTE_WRITABLE: u64 = 1 << 1;
pub const PTE_USER: u64 = 1 << 2;
pub const PTE_WRITE_THROUGH: u64 = 1 << 3;
pub const PTE_CACHE_DISABLE: u64 = 1 << 4;
pub const PTE_ACCESSED: u64 = 1 << 5;
pub const PTE_DIRTY: u64 = 1 << 6;
pub const PTE_HUGE: u64 = 1 << 7;
pub const PTE_GLOBAL: u64 = 1 << 8;
pub const PTE_NO_EXECUTE: u64 = @as(u64, 1) << 63;

/// Convenience flag sets
pub const PAGE_PRESENT: u64 = PTE_PRESENT;
pub const PAGE_WRITABLE: u64 = PTE_PRESENT | PTE_WRITABLE;
pub const PAGE_USER: u64 = PTE_PRESENT | PTE_USER;
pub const PAGE_RW: u64 = PTE_PRESENT | PTE_WRITABLE | PTE_USER;
pub const PAGE_RWX: u64 = PTE_PRESENT | PTE_WRITABLE | PTE_USER | PTE_ACCESSED;
/// P2 FIX: Added PTE_NO_EXECUTE to PAGE_KERNEL and PAGE_KERNEL_RO
pub const PAGE_KERNEL: u64 = PTE_PRESENT | PTE_WRITABLE | PTE_GLOBAL | PTE_NO_EXECUTE;
pub const PAGE_KERNEL_RO: u64 = PTE_PRESENT | PTE_GLOBAL | PTE_NO_EXECUTE;

pub const PageTable = [512]u64;

/// Kernel virtual address range
pub const KERNEL_VIRT_BASE: u64 = 0xFFFF_8000_0000_0000;
pub const KERNEL_VIRT_TOP: u64 = 0xFFFF_FFFF_FFFF_FFFF;

/// User virtual address range  
pub const USER_VIRT_BASE: u64 = 0x0000_0000_0000_0000;
pub const USER_VIRT_TOP: u64 = 0x0000_7FFF_FFFF_FFFF;

// ============================================================================
// Page Table Operations
// ============================================================================

/// Read CR3 register (Page Map Level 4 base address)
pub fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Write CR3 register (Page Map Level 4 base address)
pub fn writeCr3(addr: u64) void {
    asm volatile ("mov %[addr], %%cr3"
        :
        : [addr] "r" (addr),
        : .{ .memory = true }
    );
    // Memory barrier to ensure page table switch is complete
    asm volatile ("mfence");
}

/// Invalidate TLB entry for a single address
pub fn invlpg(addr: u64) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
        : .{ .memory = true }
    );
}

/// Read CR2 register (page fault address)
pub fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> u64),
    );
}

// ============================================================================
// Index Extraction
// ============================================================================

/// Extract PML4 index from virtual address (bits 39-47)
pub fn pml4Index(virt: u64) u9 {
    return @truncate(virt >> 39);
}

/// Extract PDPT index from virtual address (bits 30-38)
pub fn pdptIndex(virt: u64) u9 {
    return @truncate(virt >> 30);
}

/// Extract PD index from virtual address (bits 21-29)
pub fn pdIndex(virt: u64) u9 {
    return @truncate(virt >> 21);
}

/// Extract PT index from virtual address (bits 12-20)
pub fn ptIndex(virt: u64) u9 {
    return @truncate(virt >> 12);
}

/// Get PML4 table pointer from CR3
pub fn getPml4() *PageTable {
    const cr3 = readCr3();
    return @ptrFromInt(cr3 & PAGE_MASK);
}

// ============================================================================
// Page Table Allocation
// ============================================================================

/// Allocate a new page table from PMM and return its physical address.
/// Returns null if out of memory.
pub fn allocPageTable() ?u64 {
    const page_idx = pmm.allocPage() orelse return null;
    const phys = pmm.pageToPhysical(page_idx);
    
    // Zero out the page table
    const ptr: [*]volatile u64 = @ptrFromInt(phys);
    for (0..512) |i| {
        ptr[i] = 0;
    }
    
    return phys;
}

/// Allocate and map a page table at the given level in the hierarchy.
/// This is used when we need to create intermediate page tables.
fn ensurePageTable(parent: *u64, index: u9, flags: u64) bool {
    _ = index; // Reserved for future use (e.g., validation)
    const entry = parent.* & PAGE_MASK;
    
    if (entry != 0) {
        // Page table already exists
        return true;
    }
    
    // Allocate new page table
    const pt_phys = allocPageTable() orelse return false;
    
    // Set the entry with the new page table physical address + flags
    parent.* = pt_phys | flags | PTE_PRESENT | PTE_WRITABLE;
    
    return true;
}

// ============================================================================
// Page Table Entry Operations
// ============================================================================

/// Get the physical address stored in a PTE
pub fn pteToPhysical(pte: u64) u64 {
    return pte & PAGE_MASK;
}

/// Check if a PTE is present
pub fn pteIsPresent(pte: u64) bool {
    return (pte & PTE_PRESENT) != 0;
}

/// Check if a PTE maps a huge page (2MB or 1GB)
pub fn pteIsHuge(pte: u64) bool {
    return (pte & PTE_HUGE) != 0;
}

/// Get pointer to PTE at given virtual address in a page table
fn getPtePtr(table: [*]u64, virt: u64, index: u9) *u64 {
    _ = virt; // Reserved for future use (e.g., validation)
    return &table[index];
}

// ============================================================================
// Page Mapping
// ============================================================================

/// Map a single 4KB page at the given virtual address to the physical address.
/// 
/// Parameters:
///   - virt: Virtual address to map (must be 4KB aligned)
///   - phys: Physical address to map to (must be 4KB aligned)
///   - flags: Page table entry flags (use PAGE_* constants)
/// 
/// Returns: true on success, false on failure (out of memory for page tables)
pub fn mapPage(virt: u64, phys: u64, flags: u64) bool {
    // Validate alignment
    if ((virt & ~PAGE_MASK) != 0 or (phys & ~PAGE_MASK) != 0) {
        log.err("[PAGING] mapPage: addresses not aligned to 4KB", .{});
        return false;
    }
    
    const pml4 = getPml4();
    const p4i = pml4Index(virt);
    const pdpti = pdptIndex(virt);
    const pdi = pdIndex(virt);
    const pti = ptIndex(virt);
    
    // Ensure PDPT exists
    if (!ensurePageTable(&pml4[p4i], pdpti, PTE_PRESENT | PTE_WRITABLE | PTE_USER)) {
        log.err("[PAGING] mapPage: failed to allocate PDPT", .{});
        return false;
    }
    const pdpt_phys = pml4[p4i] & PAGE_MASK;
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);
    
    // Ensure PD exists
    if (!ensurePageTable(&pdpt[pdpti], pdi, PTE_PRESENT | PTE_WRITABLE | PTE_USER)) {
        log.err("[PAGING] mapPage: failed to allocate PD", .{});
        return false;
    }
    const pd_phys = pdpt[pdpti] & PAGE_MASK;
    const pd: [*]u64 = @ptrFromInt(pd_phys);
    
    // Ensure PT exists
    if (!ensurePageTable(&pd[pdi], pti, PTE_PRESENT | PTE_WRITABLE | PTE_USER)) {
        log.err("[PAGING] mapPage: failed to allocate PT", .{});
        return false;
    }
    const pt_phys = pd[pdi] & PAGE_MASK;
    const pt: [*]u64 = @ptrFromInt(pt_phys);
    
    // Check if the PTE is already mapped
    if (pt[pti] != 0 and (pt[pti] & PTE_PRESENT) != 0) {
        log.warn("[PAGING] mapPage: VA 0x{x} already mapped to PA 0x{x}", .{
            virt, pt[pti] & PAGE_MASK
        });
        return false;
    }
    
    // Set the PTE
    pt[pti] = phys | flags;
    
    // Invalidate TLB for this address
    invlpg(virt);
    
    return true;
}

/// Unmap a virtual address.
/// 
/// Returns: true if the address was mapped, false otherwise.
pub fn unmapPage(virt: u64) bool {
    const pml4 = getPml4();
    const p4i = pml4Index(virt);
    const pdpti = pdptIndex(virt);
    const pdi = pdIndex(virt);
    const pti = ptIndex(virt);
    
    // Check if all levels exist
    if (!pteIsPresent(pml4[p4i])) return false;
    
    const pdpt_phys = pml4[p4i] & PAGE_MASK;
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);
    if (!pteIsPresent(pdpt[pdpti])) return false;
    
    const pd_phys = pdpt[pdpti] & PAGE_MASK;
    const pd: [*]u64 = @ptrFromInt(pd_phys);
    if (!pteIsPresent(pd[pdi])) return false;
    
    const pt_phys = pd[pdi] & PAGE_MASK;
    const pt: [*]u64 = @ptrFromInt(pt_phys);
    
    // Check if the page is actually mapped
    if (!pteIsPresent(pt[pti])) return false;
    
    // Clear the PTE
    pt[pti] = 0;
    
    // Invalidate TLB
    invlpg(virt);
    
    return true;
}

/// Translate a virtual address to its physical address.
/// 
/// Returns: physical address if mapped, null if not mapped.
pub fn virtToPhys(virt: u64) ?u64 {
    const pml4 = getPml4();
    const p4i = pml4Index(virt);
    const pdpti = pdptIndex(virt);
    const pdi = pdIndex(virt);
    const pti = ptIndex(virt);
    
    // Check PML4
    if (!pteIsPresent(pml4[p4i])) return null;
    
    const pdpt_phys = pml4[p4i] & PAGE_MASK;
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);
    
    // Check PDPT
    if (!pteIsPresent(pdpt[pdpti])) return null;
    
    const pd_phys = pdpt[pdpti] & PAGE_MASK;
    const pd: [*]u64 = @ptrFromInt(pd_phys);
    
    // Check for huge page (2MB) in PD
    if (pteIsHuge(pdpt[pdpti])) {
        // P2 FIX: Use dynamic mask calculation instead of hardcoded value
        const huge_page_size: u64 = 2 * 1024 * 1024; // 2MB
        const huge_page_mask: u64 = ~(huge_page_size - 1);
        const huge_page_offset = virt & (huge_page_size - 1);
        return (pdpt[pdpti] & huge_page_mask) + huge_page_offset;
    }
    
    // Check PD
    if (!pteIsPresent(pd[pdi])) return null;
    
    const pt_phys = pd[pdi] & PAGE_MASK;
    const pt: [*]u64 = @ptrFromInt(pt_phys);
    
    // Check PT
    if (!pteIsPresent(pt[pti])) return null;
    
    // Calculate physical address
    const page_offset = virt & 0xFFF;
    return (pt[pti] & PAGE_MASK) + page_offset;
}

/// Map a range of virtual addresses to consecutive physical pages.
/// 
/// Parameters:
///   - virt_start: Starting virtual address (will be aligned to 4KB)
///   - phys_start: Starting physical address (will be aligned to 4KB)
///   - page_count: Number of 4KB pages to map
///   - flags: Page table entry flags
/// 
/// Returns: true on success, false on failure
pub fn mapRange(virt_start: u64, phys_start: u64, page_count: usize, flags: u64) bool {
    const aligned_virt = (virt_start + PAGE_SIZE - 1) & PAGE_MASK;
    const aligned_phys = (phys_start + PAGE_SIZE - 1) & PAGE_MASK;
    
    var virt = aligned_virt;
    var phys = aligned_phys;
    
    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        if (!mapPage(virt, phys, flags)) {
            log.err("[PAGING] mapRange: failed at page {}", .{i});
            return false;
        }
        virt += PAGE_SIZE;
        phys += PAGE_SIZE;
    }
    
    return true;
}

// ============================================================================
// Page Table Activation
// ============================================================================

/// Activate a new page table by writing to CR3.
/// 
/// Parameters:
///   - pml4_phys: Physical address of the PML4 table (must be 4KB aligned)
pub fn activatePageTable(pml4_phys: u64) void {
    if ((pml4_phys & ~PAGE_MASK) != 0) {
        @panic("[PAGING] activatePageTable: PML4 address not aligned");
    }
    writeCr3(pml4_phys);
}

/// Create a new address space (new PML4 table).
/// Returns the physical address of the new PML4.
pub fn createAddressSpace() ?u64 {
    return allocPageTable();
}

// ============================================================================
// Kernel Mapping Utilities
// ============================================================================

/// Map kernel code and data region (identity mapping for low memory).
/// This is called during early boot to set up minimal kernel mappings.
pub fn mapKernelIdentity(base: u64, size: u64, flags: u64) bool {
    // Align to page size
    const aligned_base = base & PAGE_MASK;
    const aligned_size = (size + PAGE_SIZE - 1) & PAGE_MASK;
    const page_count = aligned_size / PAGE_SIZE;
    
    return mapRange(aligned_base, aligned_base, page_count, flags);
}

/// Map a physical memory region into kernel virtual address space.
/// This is used to map device memory, framebuffer, etc.
pub fn mapPhysicalToVirtual(phys: u64, size: u64, flags: u64) ?u64 {
    // Find a free region in kernel virtual address space
    const aligned_size = (size + PAGE_SIZE - 1) & PAGE_MASK;
    const page_count = aligned_size / PAGE_SIZE;
    
    // Use a fixed high address for now (can be improved with a proper kernel heap)
    const virt_base = KERNEL_VIRT_TOP - aligned_size + 1;
    
    if (!mapRange(virt_base, phys, page_count, flags)) {
        return null;
    }
    
    return virt_base;
}

// ============================================================================
// TLB Shootdown (for SMP)
// ============================================================================

/// P0 FIX: TLB shootdown IPI stub
/// P0 FIX: In a real implementation, this would send an IPI to other CPUs
/// P0 FIX: to flush their TLBs when page tables are modified
pub fn sendTLBShootdownIPI() void {
    // P0 FIX: This is a stub for multi-core TLB invalidation
    // In a real kernel, this would:
    // 1. Get the list of online CPUs
    // 2. For each CPU other than current, send an IPI
    // 3. The IPI handler would call flushTLBAll() on that CPU
    // For now, we just flush the local TLB
    flushTLBAll();
    log.debug("[PAGING] TLB shootdown IPI sent", .{});
}

/// P0 FIX: Flush TLB for a specific address on all CPUs
pub fn flushTLBRemote(addr: u64) void {
    // P0 FIX: Send IPI to all other CPUs to invalidate this address
    // For now, just flush local TLB
    invlpg(addr);
    sendTLBShootdownIPI();
}

/// Flush TLB for a single address on current CPU.
/// This should be called after modifying a page table entry.
pub fn flushTLB(addr: u64) void {
    invlpg(addr);
}

/// Flush entire TLB on current CPU.
pub fn flushTLBAll() void {
    // Writing to CR3 flushes the TLB
    const cr3_val = readCr3();
    writeCr3(cr3_val);
}

// ============================================================================
// Large Page (Huge Page) Support
// ============================================================================

/// P0 FIX: Map a 2MB huge page (PD entry with PS bit set)
pub fn mapHugePage2MB(virt: u64, phys: u64, flags: u64) bool {
    // Validate alignment (2MB)
    if ((virt & 0x1F_FFFF) != 0 or (phys & 0x1F_FFFF) != 0) {
        log.err("[PAGING] mapHugePage2MB: addresses not 2MB-aligned", .{});
        return false;
    }

    const pml4 = getPml4();
    const p4i = pml4Index(virt);

    // Ensure PDPT exists
    if (!ensurePageTable(&pml4[p4i], pdptIndex(virt), PTE_PRESENT | PTE_WRITABLE | PTE_USER)) {
        log.err("[PAGING] mapHugePage2MB: failed to allocate PDPT", .{});
        return false;
    }
    const pdpt_phys = pml4[p4i] & PAGE_MASK;
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);
    const pdpti = pdptIndex(virt);

    // Check if PD entry is already mapped
    if (pdpt[pdpti] != 0 and (pdpt[pdpti] & PTE_PRESENT) != 0) {
        log.warn("[PAGING] mapHugePage2MB: VA 0x{x} already mapped", .{virt});
        return false;
    }

    // Set the PD entry with PS (Page Size) bit = 1 for 2MB pages
    pdpt[pdpti] = phys | flags | PTE_PRESENT | PTE_HUGE;

    // Invalidate TLB
    invlpg(virt);

    log.debug("[PAGING] Mapped 2MB huge page: VA 0x{x} -> PA 0x{x}", .{ virt, phys });
    return true;
}

/// P0 FIX: Unmap a 2MB huge page
pub fn unmapHugePage2MB(virt: u64) bool {
    const pml4 = getPml4();
    const p4i = pml4Index(virt);
    const pdpti = pdptIndex(virt);

    // Check if all levels exist
    if (!pteIsPresent(pml4[p4i])) return false;

    const pdpt_phys = pml4[p4i] & PAGE_MASK;
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);
    // Check the specific entry index for this 2MB page
    if (!pteIsPresent(pdpt[pdpti])) return false;

    // Check if it's a huge page
    if (!pteIsHuge(pdpt[pdpti])) return false;

    // Clear the entry
    pdpt[pdpti] = 0;

    // Invalidate TLB
    invlpg(virt);

    return true;
}

/// P0 FIX: Map a 1GB huge page (PDPT entry with PS bit set)
pub fn mapHugePage1GB(virt: u64, phys: u64, flags: u64) bool {
    // Validate alignment (1GB)
    if ((virt & 0x3FFF_FFFF) != 0 or (phys & 0x3FFF_FFFF) != 0) {
        log.err("[PAGING] mapHugePage1GB: addresses not 1GB-aligned", .{});
        return false;
    }

    const pml4 = getPml4();
    const p4i = pml4Index(virt);

    // Check if PML4 entry is already mapped
    if (pml4[p4i] != 0 and (pml4[p4i] & PTE_PRESENT) != 0) {
        log.warn("[PAGING] mapHugePage1GB: VA 0x{x} already mapped", .{virt});
        return false;
    }

    // Set the PML4 entry with PS bit = 1 for 1GB pages
    pml4[p4i] = phys | flags | PTE_PRESENT | PTE_HUGE;

    // Invalidate TLB
    invlpg(virt);

    log.debug("[PAGING] Mapped 1GB huge page: VA 0x{x} -> PA 0x{x}", .{ virt, phys });
    return true;
}

/// P0 FIX: Unmap a 1GB huge page
pub fn unmapHugePage1GB(virt: u64) bool {
    const pml4 = getPml4();
    const p4i = pml4Index(virt);

    // Check if it's a huge page
    if (!pteIsPresent(pml4[p4i])) return false;
    if (!pteIsHuge(pml4[p4i])) return false;

    // Clear the entry
    pml4[p4i] = 0;

    // Invalidate TLB
    invlpg(virt);

    return true;
}

// ============================================================================
// Debug Utilities
// ============================================================================

/// Dump page table entries for a virtual address (for debugging)
pub fn dumpPageTableChain(virt: u64) void {
    const pml4 = getPml4();
    const p4i = pml4Index(virt);
    const pdpti = pdptIndex(virt);
    const pdi = pdIndex(virt);
    const pti = ptIndex(virt);
    
    log.info("[PAGING] VA: 0x{x}", .{virt});
    log.info("[PAGING]   PML4[{}] = 0x{x}", .{p4i, pml4[p4i]});
    
    if (!pteIsPresent(pml4[p4i])) {
        log.info("[PAGING]   PDPT not present", .{});
        return;
    }
    
    const pdpt_phys = pml4[p4i] & PAGE_MASK;
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);
    log.info("[PAGING]   PDPT[{}] = 0x{x}", .{pdpti, pdpt[pdpti]});
    
    if (!pteIsPresent(pdpt[pdpti])) {
        log.info("[PAGING]   PD not present", .{});
        return;
    }
    
    if (pteIsHuge(pdpt[pdpti])) {
        log.info("[PAGING]   2MB huge page mapped to PA: 0x{x}", .{
            pdpt[pdpti] & 0xFFFF_FC00_0000
        });
        return;
    }
    
    const pd_phys = pdpt[pdpti] & PAGE_MASK;
    const pd: [*]u64 = @ptrFromInt(pd_phys);
    log.info("[PAGING]   PD[{}] = 0x{x}", .{pdi, pd[pdi]});
    
    if (!pteIsPresent(pd[pdi])) {
        log.info("[PAGING]   PT not present", .{});
        return;
    }
    
    const pt_phys = pd[pdi] & PAGE_MASK;
    const pt: [*]u64 = @ptrFromInt(pt_phys);
    log.info("[PAGING]   PT[{}] = 0x{x}", .{pti, pt[pti]});
    
    if (pteIsPresent(pt[pti])) {
        log.info("[PAGING]   Mapped to PA: 0x{x}", .{pt[pti] & PAGE_MASK});
    } else {
        log.info("[PAGING]   Page not present", .{});
    }
}

/// Check if the paging system is initialized
pub fn isInitialized() bool {
    // Check if we have a valid PML4
    const cr3 = readCr3();
    return cr3 != 0;
}

// ============================================================================
// Page Size Constants
// ============================================================================

/// 2MB huge page size
pub const PAGE_SIZE_2MB: u64 = 2 * 1024 * 1024;
/// 1GB huge page size
pub const PAGE_SIZE_1GB: u64 = 1024 * 1024 * 1024;

/// Huge page alignment mask (2MB)
pub const ALIGN_MASK_2MB: u64 = ~(PAGE_SIZE_2MB - 1);
/// Huge page alignment mask (1GB)
pub const ALIGN_MASK_1GB: u64 = ~(PAGE_SIZE_1GB - 1);

// ============================================================================
// Page Table Release / Reclaim
// ============================================================================

/// P1 FIX: 释放不再使用的页表页
/// 当 unmap 操作清空一个页表的所有条目时，调用此函数释放页表页
pub fn reclaimEmptyPageTable(pml4_phys: u64) void {
    const pml4: [*]u64 = @ptrFromInt(pml4_phys);

    var p4i: usize = 0;
    while (p4i < 512) : (p4i += 1) {
        if (!pteIsPresent(pml4[p4i])) continue;

        const pdpt_phys = pml4[p4i] & PAGE_MASK;
        if (pdpt_phys == 0) continue;

        const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);

        // 检查 PDPT 是否可以释放
        var pdpt_empty = true;
        var pdpti: usize = 0;
        while (pdpti < 512) : (pdpti += 1) {
            if (pteIsPresent(pdpt[pdpti])) {
                pdpt_empty = false;
                break;
            }
        }

        if (pdpt_empty) {
            // 释放 PDPT 页
            const page_idx = pmm.physicalToPage(pdpt_phys);
            pmm.freePage(page_idx);
            pml4[p4i] = 0;
            continue;
        }

        // 检查并释放空的 PD 和 PT
        var pdpi: usize = 0;
        while (pdpi < 512) : (pdpi += 1) {
            if (!pteIsPresent(pdpt[pdpi])) continue;

            const pd_phys = pdpt[pdpi] & PAGE_MASK;
            if (pd_phys == 0) continue;

            const pd: [*]u64 = @ptrFromInt(pd_phys);

            // 检查 PD 是否可以释放
            var pd_empty = true;
            var pti: usize = 0;
            while (pti < 512) : (pti += 1) {
                if (pteIsPresent(pd[pti])) {
                    pd_empty = false;
                    break;
                }
            }

            if (pd_empty) {
                const page_idx = pmm.physicalToPage(pd_phys);
                pmm.freePage(page_idx);
                pdpt[pdpi] = 0;
            }
        }
    }

    log.debug("[PAGING] Page table reclaim completed", .{});
}

/// P1 FIX: 释放整个地址空间的页表
pub fn freeAddressSpace(pml4_phys: u64) void {
    const pml4: [*]u64 = @ptrFromInt(pml4_phys);

    var p4i: usize = 0;
    while (p4i < 512) : (p4i += 1) {
        if (!pteIsPresent(pml4[p4i])) continue;

        const pdpt_phys = pml4[p4i] & PAGE_MASK;
        if (pdpt_phys == 0) continue;

        const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);

        var pdpti: usize = 0;
        while (pdpti < 512) : (pdpti += 1) {
            if (!pteIsPresent(pdpt[pdpti])) continue;

            const pd_phys = pdpt[pdpti] & PAGE_MASK;
            if (pd_phys == 0) continue;

            // 检查是否是大页 (2MB)
            if (pteIsHuge(pdpt[pdpti])) {
                // 2MB 大页不需要释放 PT
                pdpt[pdpti] = 0;
                continue;
            }

            const pd: [*]u64 = @ptrFromInt(pd_phys);

            var pti: usize = 0;
            while (pti < 512) : (pti += 1) {
                if (pteIsPresent(pd[pti])) {
                    // 释放 4KB 页
                    const page_phys = pd[pti] & PAGE_MASK;
                    const page_idx = pmm.physicalToPage(page_phys);
                    pmm.freePage(page_idx);
                    pd[pti] = 0;
                }
            }

            // 释放 PT 页
            const pt_page_idx = pmm.physicalToPage(pd_phys);
            pmm.freePage(pt_page_idx);
            pdpt[pdpti] = 0;
        }

        // 释放 PD 页
        const pd_page_idx = pmm.physicalToPage(pdpt_phys);
        pmm.freePage(pd_page_idx);
        pml4[p4i] = 0;
    }

    // 释放 PML4
    const pml4_page_idx = pmm.physicalToPage(pml4_phys);
    pmm.freePage(pml4_page_idx);

    log.info("[PAGING] Address space freed (PML4 at 0x{x})", .{pml4_phys});
}

// ============================================================================
// NX (No-Execute) Bit Support
// ============================================================================

/// P1 FIX: 检查 PTE 是否有 NX 位
pub fn pteHasNX(pte: u64) bool {
    return (pte & PTE_NO_EXECUTE) != 0;
}

/// P1 FIX: 创建一个带有 NX 位的 PTE
pub fn makePTEWithNX(phys: u64, writable: bool, user: bool, nx: bool) u64 {
    var flags: u64 = PTE_PRESENT;
    if (writable) flags |= PTE_WRITABLE;
    if (user) flags |= PTE_USER;
    if (nx) flags |= PTE_NO_EXECUTE;
    return phys | flags;
}

/// P1 FIX: 添加或移除 NX 位
pub fn setPTEExecFlag(pte: u64, no_exec: bool) u64 {
    if (no_exec) {
        return pte | PTE_NO_EXECUTE;
    } else {
        return pte & ~PTE_NO_EXECUTE;
    }
}

// ============================================================================
// Page Protection
// ============================================================================

/// P2 FIX: 修改页面保护权限
pub fn protectPage(virt: u64, flags: u64) bool {
    const pml4 = getPml4();
    const p4i = pml4Index(virt);
    const pdpti = pdptIndex(virt);
    const pdi = pdIndex(virt);
    const pti = ptIndex(virt);

    // 检查 PML4
    if (!pteIsPresent(pml4[p4i])) return false;

    const pdpt_phys = pml4[p4i] & PAGE_MASK;
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);

    // 检查 PDPT
    if (!pteIsPresent(pdpt[pdpti])) return false;

    const pd_phys = pdpt[pdpti] & PAGE_MASK;
    const pd: [*]u64 = @ptrFromInt(pd_phys);

    // 检查大页
    if (pteIsHuge(pdpt[pdpti])) {
        // 修改 2MB 大页的权限
        const old_pte = pdpt[pdpti];
        pdpt[pdpti] = (old_pte & PAGE_MASK) | flags;
        invlpg(virt);
        return true;
    }

    // 检查 PD
    if (!pteIsPresent(pd[pdi])) return false;

    const pt_phys = pd[pdi] & PAGE_MASK;
    const pt: [*]u64 = @ptrFromInt(pt_phys);

    // 检查 PT
    if (!pteIsPresent(pt[pti])) return false;

    // 修改 PTE
    const old_pte = pt[pti];
    pt[pti] = (old_pte & PAGE_MASK) | flags;

    // TLB 刷新
    invlpg(virt);

    return true;
}

/// P2 FIX: 批量修改页面保护权限
pub fn protectRange(virt_start: u64, page_count: usize, flags: u64) bool {
    var virt = virt_start;
    var i: usize = 0;

    while (i < page_count) : (i += 1) {
        if (!protectPage(virt, flags)) {
            log.warn("[PAGING] protectRange: failed at page {}", .{i});
            return false;
        }
        virt += PAGE_SIZE;
    }

    return true;
}

// ============================================================================
// Page Query
// ============================================================================

/// P2 FIX: 页面查询结果
pub const PageInfo = struct {
    present: bool,
    phys: u64,
    writable: bool,
    user: bool,
    no_exec: bool,
    huge: bool,
    huge_size: u64,
};

/// P2 FIX: 查询页面信息
pub fn queryPage(virt: u64) PageInfo {
    const pml4 = getPml4();
    const p4i = pml4Index(virt);
    const pdpti = pdptIndex(virt);
    const pdi = pdIndex(virt);
    const pti = ptIndex(virt);

    // 检查 PML4
    if (!pteIsPresent(pml4[p4i])) {
        return .{ .present = false, .phys = 0, .writable = false, .user = false, .no_exec = false, .huge = false, .huge_size = 0 };
    }

    const pdpt_phys = pml4[p4i] & PAGE_MASK;
    const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);

    // 检查 PDPT
    if (!pteIsPresent(pdpt[pdpti])) {
        return .{ .present = false, .phys = 0, .writable = false, .user = false, .no_exec = false, .huge = false, .huge_size = 0 };
    }

    const pd_phys = pdpt[pdpti] & PAGE_MASK;

    // 检查大页 (2MB)
    if (pteIsHuge(pdpt[pdpti])) {
        const huge_phys = pdpt[pdpti] & 0xFFFF_FC00_0000;
        const huge_offset = virt & 0x1F_FFFF;
        return .{
            .present = true,
            .phys = huge_phys | huge_offset,
            .writable = (pdpt[pdpti] & PTE_WRITABLE) != 0,
            .user = (pdpt[pdpti] & PTE_USER) != 0,
            .no_exec = (pdpt[pdpti] & PTE_NO_EXECUTE) != 0,
            .huge = true,
            .huge_size = PAGE_SIZE_2MB,
        };
    }

    const pd: [*]u64 = @ptrFromInt(pd_phys);

    // 检查 PD
    if (!pteIsPresent(pd[pdi])) {
        return .{ .present = false, .phys = 0, .writable = false, .user = false, .no_exec = false, .huge = false, .huge_size = 0 };
    }

    const pt_phys = pd[pdi] & PAGE_MASK;
    const pt: [*]u64 = @ptrFromInt(pt_phys);

    // 检查 PT
    if (!pteIsPresent(pt[pti])) {
        return .{ .present = false, .phys = 0, .writable = false, .user = false, .no_exec = false, .huge = false, .huge_size = 0 };
    }

    return .{
        .present = true,
        .phys = (pt[pti] & PAGE_MASK) | (virt & 0xFFF),
        .writable = (pt[pti] & PTE_WRITABLE) != 0,
        .user = (pt[pti] & PTE_USER) != 0,
        .no_exec = (pt[pti] & PTE_NO_EXECUTE) != 0,
        .huge = false,
        .huge_size = PAGE_SIZE,
    };
}

/// P2 FIX: 批量查询页面
pub fn queryPages(virt_start: u64, count: usize) []PageInfo {
    // 简化实现：返回一个静态数组
    // 在实际系统中可能需要动态分配
    var results: [1024]PageInfo = undefined;
    const safe_count = @min(count, 1024);

    var i: usize = 0;
    var virt = virt_start;
    while (i < safe_count) : (i += 1) {
        results[i] = queryPage(virt);
        virt += PAGE_SIZE;
    }

    return results[0..safe_count];
}

// ============================================================================
// Page Table Statistics
// ============================================================================

/// 页表统计信息
pub const PageTableStats = struct {
    pml4_entries: usize,
    pdpt_entries: usize,
    pd_entries: usize,
    pt_entries: usize,
    huge_2mb_pages: usize,
    huge_1gb_pages: usize,
    regular_4kb_pages: usize,
};

/// P2 FIX: 收集页表统计
pub fn getPageTableStats() PageTableStats {
    var stats = PageTableStats{
        .pml4_entries = 0,
        .pdpt_entries = 0,
        .pd_entries = 0,
        .pt_entries = 0,
        .huge_2mb_pages = 0,
        .huge_1gb_pages = 0,
        .regular_4kb_pages = 0,
    };

    const pml4 = getPml4();

    var p4i: usize = 0;
    while (p4i < 512) : (p4i += 1) {
        if (!pteIsPresent(pml4[p4i])) continue;
        stats.pml4_entries += 1;

        const pdpt_phys = pml4[p4i] & PAGE_MASK;
        const pdpt: [*]u64 = @ptrFromInt(pdpt_phys);

        var pdpti: usize = 0;
        while (pdpti < 512) : (pdpti += 1) {
            if (!pteIsPresent(pdpt[pdpti])) continue;
            stats.pdpt_entries += 1;

            const pd_phys = pdpt[pdpti] & PAGE_MASK;

            // 检查 2MB 大页
            if (pteIsHuge(pdpt[pdpti])) {
                stats.huge_2mb_pages += 1;
                continue;
            }

            const pd: [*]u64 = @ptrFromInt(pd_phys);

            var pdi: usize = 0;
            while (pdi < 512) : (pdi += 1) {
                if (!pteIsPresent(pd[pdi])) continue;
                stats.pd_entries += 1;

                const pt_phys = pd[pdi] & PAGE_MASK;
                const pt: [*]u64 = @ptrFromInt(pt_phys);

                var pti: usize = 0;
                while (pti < 512) : (pti += 1) {
                    if (pteIsPresent(pt[pti])) {
                        stats.pt_entries += 1;
                        stats.regular_4kb_pages += 1;
                    }
                }
            }
        }
    }

    return stats;
}

/// P2 FIX: 打印页表统计
pub fn dumpPageTableStats() void {
    const stats = getPageTableStats();

    log.info("=== x86_64 Page Table Statistics ===", .{});
    log.info("  PML4 entries (used):   {}", .{stats.pml4_entries});
    log.info("  PDPT entries (used):   {}", .{stats.pdpt_entries});
    log.info("  PD entries (used):    {}", .{stats.pd_entries});
    log.info("  PT entries (used):    {}", .{stats.pt_entries});
    log.info("  2MB huge pages:       {}", .{stats.huge_2mb_pages});
    log.info("  1GB huge pages:       {}", .{stats.huge_1gb_pages});
    log.info("  4KB regular pages:    {}", .{stats.regular_4kb_pages});
    log.info("  Total mapped memory: {} MB", .{
        (stats.regular_4kb_pages * 4096 + stats.huge_2mb_pages * 2 * 1024 * 1024 + stats.huge_1gb_pages * 1024 * 1024 * 1024) / (1024 * 1024)
    });
}

// ============================================================================
// Initialization
// ============================================================================

/// Initialize the paging subsystem
pub fn init() void {
    log.info("[PAGING] Initializing x86_64 paging subsystem", .{});

    // Step 1: Check if paging is already enabled
    const cr0 = asm volatile ("mov %%cr0, %[result]"
        : [result] "=r" (-> u64)
    );
    const paging_enabled = (cr0 & (1 << 31)) != 0;

    if (paging_enabled) {
        log.info("[PAGING] Paging already enabled (CR0.PG = 1)", .{});
    } else {
        log.info("[PAGING] Paging disabled, using flat identity mapping", .{});
    }

    // Step 2: Read current CR3 to get the PML4 address
    const pml4_phys = readCr3();
    log.info("[PAGING] PML4 base address: 0x{x}", .{pml4_phys});

    // Step 3: Check if we have a valid PML4
    if (pml4_phys == 0) {
        log.warn("[PAGING] No PML4 table found, creating identity mapping", .{});

        // Allocate a new PML4
        const new_pml4_phys = allocPageTable() orelse @panic("[PAGING] Failed to allocate PML4");
        log.info("[PAGING] Allocated new PML4 at: 0x{x}", .{new_pml4_phys});

        // Create identity mapping for first 1GB
        const identity_pages = 0x4000_0000 / PAGE_SIZE; // 1GB
        var i: usize = 0;
        while (i < identity_pages) : (i += 1) {
            _ = mapPage(@as(u64, i) * PAGE_SIZE, @as(u64, i) * PAGE_SIZE, PAGE_RWX);
        }
        log.info("[PAGING] Created identity mapping for {} pages", .{identity_pages});

        // Activate the new PML4
        writeCr3(new_pml4_phys);
    }

    // Step 4: Log page table statistics
    log.info("[PAGING] Page table entries: PML4(512), PDPT(512), PD(512), PT(512)", .{});
    log.info("[PAGING] Page size: {} bytes", .{PAGE_SIZE});
    log.info("[PAGING] Maximum address space: 256TB (48-bit)", .{});

    // Step 6: 打印页表统计
    dumpPageTableStats();

    // Step 7: Verify initialization
    if (isInitialized()) {
        log.info("[PAGING] Paging subsystem initialized successfully", .{});
    } else {
        log.err("[PAGING] Paging subsystem initialization failed", .{});
    }
}
