/// LoongArch64 interrupt and exception setup.
///
/// LoongArch uses a CSR-based interrupt model:
///   - 13 local interrupt sources (SWI0-1, HWI0-7, TI, IPI, PCOV)
///   - ECFG.LIE enables individual sources
///   - CRMD.IE is the global interrupt gate
///   - EENTRY holds the base address of the exception handler
///
/// External device IRQs are routed through the Extended I/O Interrupt
/// Controller (EIOINTC) on multi-core Loongson chips; the EIOINTC maps
/// device IRQs to CPU HWI lines.

const csr = @import("csr.zig");
const serial = @import("serial.zig");
const log = @import("../../../lib/log.zig");

/// Exception handler entry — must be 4K-aligned (LoongArch requirement).
/// Handles timer interrupts inline; for all other exceptions, calls
/// exceptionPanic which prints diagnostic info and halts the CPU.
export fn exception_entry() align(4096) callconv(.naked) void {
    asm volatile (
        \\addi.d $sp, $sp, -48
        \\st.d   $ra, $sp, 40
        \\st.d   $a0, $sp, 32
        \\st.d   $a1, $sp, 24
        \\st.d   $t0, $sp, 16
        \\st.d   $t1, $sp, 8
        // Read ESTAT
        \\csrrd  $t0, 0x5
        // Extract ECODE (bits [21:16]): 0 = interrupt, non-zero = exception
        \\srli.d $t1, $t0, 16
        \\andi   $t1, $t1, 0x3F
        \\bnez   $t1, 2f
        // ECODE == 0: this is an interrupt — check timer (IS bit 11)
        \\andi   $t1, $t0, 0x800
        \\beqz   $t1, 3f
        // Clear timer interrupt
        \\li.w   $t0, 1
        \\csrwr  $t0, 0x44
        \\b      3f
        \\2:
        // Non-zero ECODE: a real exception — call panic handler
        \\or     $a0, $t0, $zero
        \\csrrd  $a1, 0x6
        \\bl     exceptionPanic
        \\3:
        // Restore context and return
        \\ld.d   $t1, $sp, 8
        \\ld.d   $t0, $sp, 16
        \\ld.d   $a1, $sp, 24
        \\ld.d   $a0, $sp, 32
        \\ld.d   $ra, $sp, 40
        \\addi.d $sp, $sp, 48
        \\ertn
    );
}

var in_panic: bool = false;

/// Called from exception_entry when a non-interrupt exception is caught.
/// Prints diagnostic information to serial and halts the CPU.
/// Uses if-else instead of switch to avoid jump-table codegen whose
/// absolute addresses break under PE/COFF base relocation.
export fn exceptionPanic(estat: u64, era: u64) callconv(.c) noreturn {
    if (in_panic) {
        while (true) asm volatile ("idle 0");
    }
    in_panic = true;

    const badv = csr.read(csr.BADV);
    const ecode: u64 = (estat >> 16) & 0x3F;
    const esubcode: u64 = (estat >> 22) & 0x1FF;

    serial.writeString("\r\n!!! LoongArch EXCEPTION !!!\r\n");
    serial.writeString("  ECODE : 0x");
    writeHex8(ecode);
    serial.writeString(" (");
    serial.writeString(ecodeDescIfElse(ecode));
    serial.writeString(")\r\n  ESUB  : 0x");
    writeHex8(esubcode);
    serial.writeString("\r\n  ERA   : 0x");
    writeHex64(era);
    serial.writeString("\r\n  BADV  : 0x");
    writeHex64(badv);
    serial.writeString("\r\n  ESTAT : 0x");
    writeHex64(estat);
    serial.writeString("\r\n--- halted ---\r\n");

    while (true) asm volatile ("idle 0");
}

fn writeHex64(val: u64) void {
    var shift: i8 = 60;
    while (shift >= 0) : (shift -= 4) {
        serial.writeByte(hexDigit(@intCast((val >> @as(u6, @intCast(shift))) & 0xF)));
    }
}

fn writeHex8(val: u64) void {
    serial.writeByte(hexDigit(@intCast((val >> 4) & 0xF)));
    serial.writeByte(hexDigit(@intCast(val & 0xF)));
}

fn hexDigit(v: u8) u8 {
    if (v < 10) return '0' + v;
    return 'a' + v - 10;
}

/// Uses if-else chains to avoid compiler-generated jump tables whose
/// absolute-address entries break when the PE/COFF is base-relocated.
fn ecodeDescIfElse(ecode: u64) []const u8 {
    if (ecode == 0x0) return "INT";
    if (ecode == 0x1) return "PIL";
    if (ecode == 0x2) return "PIS";
    if (ecode == 0x3) return "PIF";
    if (ecode == 0x4) return "PME";
    if (ecode == 0x5) return "PNR";
    if (ecode == 0x6) return "PNX";
    if (ecode == 0x7) return "PPI";
    if (ecode == 0x8) return "ADEF";
    if (ecode == 0x9) return "ADEM";
    if (ecode == 0xA) return "ALE";
    if (ecode == 0xB) return "BCE";
    if (ecode == 0xC) return "SYS";
    if (ecode == 0xD) return "BRK";
    if (ecode == 0xE) return "INE";
    if (ecode == 0xF) return "IPE";
    if (ecode == 0x10) return "FPD";
    if (ecode == 0x11) return "SXD";
    if (ecode == 0x12) return "ASXD";
    if (ecode == 0x13) return "FPE";
    if (ecode == 0x3F) return "TLBR";
    return "???";
}

pub fn init() void {
    // Set exception entry point (EENTRY) — must be 4K-aligned
    const entry_addr = @intFromPtr(&exception_entry);
    if (entry_addr & 0xFFF != 0) {
        log.warn("[IRQ]  Exception entry not 4K-aligned (0x{x})", .{entry_addr});
    }
    csr.write(csr.EENTRY, entry_addr);

    // Enable timer interrupt in ECFG.LIE (bit 11 = TI)
    const ecfg = csr.read(csr.ECFG);
    csr.write(csr.ECFG, ecfg | csr.ECFG_LIE_TI);

    // Set TLB refill exception entry to the same handler for now
    csr.write(csr.TLBRENTRY, entry_addr);

    log.info("[IRQ]  LoongArch exception vectors configured", .{});
    log.info("[IRQ]    EENTRY = 0x{x}", .{entry_addr});
    log.info("[IRQ]    ECFG   = 0x{x}", .{csr.read(csr.ECFG)});
}

pub fn enableIrq(irq: u32) void {
    if (irq >= 13) return;
    const ecfg = csr.read(csr.ECFG);
    csr.write(csr.ECFG, ecfg | (@as(u64, 1) << @as(u6, @intCast(irq))));
}

pub fn disableIrq(irq: u32) void {
    if (irq >= 13) return;
    const ecfg = csr.read(csr.ECFG);
    csr.write(csr.ECFG, ecfg & ~(@as(u64, 1) << @as(u6, @intCast(irq))));
}

pub fn pendingIrqs() u64 {
    return csr.read(csr.ESTAT) & csr.ESTAT_IS_MASK;
}

pub fn clearTimerIrq() void {
    csr.write(csr.TICLR, csr.TICLR_CLR);
}
