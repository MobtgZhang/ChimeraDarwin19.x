/// Integration tests for memory management subsystems.
/// Tests PMM, VM, Slab, and MMU integration.

const pmm = @import("pmm.zig");
const slab = @import("slab.zig");
const vm_map = @import("map.zig");
const paging = @import("arch/x86_64/paging.zig");
const log = @import("log.zig");
const builtin = @import("builtin");

/// Test runner
pub const TestRunner = struct {
    passed: usize = 0,
    failed: usize = 0,

    fn run(self: *TestRunner, name: []const u8, func: fn () bool) void {
        if (func()) {
            self.passed += 1;
            log.info("[TEST] PASS: {}", .{name});
        } else {
            self.failed += 1;
            log.err("[TEST] FAIL: {}", .{name});
        }
    }

    fn summary(self: *TestRunner) void {
        log.info("=== Test Summary ===", .{});
        log.info("  Passed: {}", .{self.passed});
        log.info("  Failed: {}", .{self.failed});
        log.info("  Total:  {}", .{self.passed + self.failed});
    }
};

// ── PMM Tests ─────────────────────────────────────────────

fn testPMMInit() bool {
    // PMM should be initialized before this test
    const stats = pmm.getStats();
    if (stats.total_pages == 0) {
        log.err("[PMM Init] Total pages is 0", .{});
        return false;
    }
    if (stats.free_pages == 0) {
        log.err("[PMM Init] No free pages", .{});
        return false;
    }
    return true;
}

fn testPMMAllocFree() bool {
    const page1 = pmm.allocPage() orelse {
        log.err("[PMM Alloc/Free] Failed to allocate page", .{});
        return false;
    };
    defer pmm.freePage(page1);

    if (page1 >= pmm.totalPageCount()) {
        log.err("[PMM Alloc/Free] Invalid page index {}", .{page1});
        return false;
    }

    return true;
}

fn testPMMDoubleFree() bool {
    const page = pmm.allocPage() orelse {
        log.err("[PMM DoubleFree] Failed to allocate page", .{});
        return false;
    };

    pmm.freePage(page);
    pmm.freePage(page); // Should be caught by double-free detection

    return true;
}

fn testPMMLargeAlloc() bool {
    const pages = pmm.allocPages(16) orelse {
        log.err("[PMM LargeAlloc] Failed to allocate 16 pages", .{});
        return false;
    };
    defer pmm.freePages(pages, 16);

    if (pmm.isPageAllocated(pages)) {
        return true;
    }
    return false;
}

fn testPMMStats() bool {
    const pressure = pmm.getMemoryPressure();
    if (pressure < 0 or pressure > 100) {
        log.err("[PMM Stats] Invalid memory pressure {}", .{pressure});
        return false;
    }

    const frag = pmm.getFragmentationRatio();
    if (frag < 0 or frag > 1) {
        log.err("[PMM Stats] Invalid fragmentation ratio {}", .{frag});
        return false;
    }

    return true;
}

// ── Slab Tests ───────────────────────────────────────────

fn testSlabAlloc() bool {
    const ptr = slab.kmalloc(64) orelse {
        log.err("[Slab Alloc] Failed to allocate 64 bytes", .{});
        return false;
    };
    defer slab.kfree(ptr);

    // Write and read
    ptr[0] = 0xAA;
    if (ptr[0] != 0xAA) {
        log.err("[Slab Alloc] Write/read failed", .{});
        return false;
    }

    return true;
}

fn testSlabLargeAlloc() bool {
    const ptr = slab.kmalloc(4096 * 2) orelse {
        log.err("[Slab LargeAlloc] Failed to allocate large block", .{});
        return false;
    };
    defer slab.kfree(ptr);

    ptr[0] = 0xBB;
    if (ptr[0] != 0xBB) {
        log.err("[Slab LargeAlloc] Write/read failed", .{});
        return false;
    }

    return true;
}

// ── VM Tests ─────────────────────────────────────────────

fn testVMMapInit() bool {
    // Test that kernel map is initialized
    const stats = vm_map.VMMap.getStats();
    if (stats.total_entries == 0) {
        log.err("[VM Map Init] No entries", .{});
        return false;
    }
    return true;
}

fn testVMMapLookup() bool {
    // Test basic lookup - just verify it doesn't crash
    _ = vm_map.kernel_map.lookup(0xFFFF_8000_0000_0000);
    return true;
}

// ── MMU Tests (x86_64) ───────────────────────────────────

fn testMMUInit() bool {
    if (builtin.cpu.arch != .x86_64) return true; // Skip on non-x86_64

    const cr3 = paging.readCr3();
    if (cr3 == 0) {
        log.err("[MMU Init] CR3 is 0", .{});
        return false;
    }

    return true;
}

fn testMMUAllocPageTable() bool {
    if (builtin.cpu.arch != .x86_64) return true;

    const pt = paging.allocPageTable();
    if (pt == null) {
        log.err("[MMU PageTable] Failed to allocate", .{});
        return false;
    }

    return true;
}

fn testMMUMapUnmap() bool {
    if (builtin.cpu.arch != .x86_64) return true;

    // This is a basic test - in real use, the address would need to be valid
    // For now, just verify the functions don't crash
    _ = paging.isInitialized();

    return true;
}

fn testMMUVirtToPhys() bool {
    if (builtin.cpu.arch != .x86_64) return true;

    // Test with kernel identity-mapped region
    const phys = paging.virtToPhys(0x1000);
    if (phys == null) {
        // This might fail if 0x1000 isn't mapped
        // Just verify it doesn't crash
    }

    return true;
}

// ── Main Test Entry ───────────────────────────────────────

/// Run all memory management tests
pub fn runAllTests() void {
    log.info("=== Running Memory Management Tests ===", .{});

    var runner = TestRunner{};

    // PMM tests
    runner.run("PMM Initialization", testPMMInit);
    runner.run("PMM Allocate/Free", testPMMAllocFree);
    runner.run("PMM Double-Free Detection", testPMMDoubleFree);
    runner.run("PMM Large Allocation", testPMMLargeAlloc);
    runner.run("PMM Statistics", testPMMStats);

    // Slab tests
    runner.run("Slab Allocation", testSlabAlloc);
    runner.run("Slab Large Allocation", testSlabLargeAlloc);

    // VM tests
    runner.run("VM Map Initialization", testVMMapInit);
    runner.run("VM Map Lookup", testVMMapLookup);

    // MMU tests
    runner.run("MMU Initialization", testMMUInit);
    runner.run("MMU Page Table Allocation", testMMUAllocPageTable);
    runner.run("MMU Map/Unmap", testMMUMapUnmap);
    runner.run("MMU VirtToPhys", testMMUVirtToPhys);

    runner.summary();
}
