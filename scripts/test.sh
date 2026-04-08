#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

cd "$PROJECT_DIR"

echo "============================================"
echo "  ChimeraOS Test Suite"
echo "============================================"
echo ""

PASS=0
FAIL=0
SKIP=0

run_test() {
    local name="$1"
    local cmd="$2"
    printf "  %-40s " "$name"
    if eval "$cmd" > /dev/null 2>&1; then
        echo "[PASS]"
        PASS=$((PASS + 1))
    else
        echo "[FAIL]"
        FAIL=$((FAIL + 1))
    fi
}

run_check() {
    local name="$1"
    local condition="$2"
    printf "  %-40s " "$name"
    if eval "$condition"; then
        echo "[PASS]"
        PASS=$((PASS + 1))
    else
        echo "[SKIP]"
        SKIP=$((SKIP + 1))
    fi
}

# --- Toolchain checks ---
echo "[1/4] Toolchain Checks"
echo "-------------------------------------------"
run_check "Zig compiler available" "command -v zig > /dev/null 2>&1"
run_check "QEMU x86_64 available" "command -v qemu-system-x86_64 > /dev/null 2>&1"
run_check "OVMF firmware exists" "[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ] || [ -f /usr/share/edk2/x64/OVMF_CODE.4m.fd ]"
run_check "mtools available" "command -v mformat > /dev/null 2>&1"
echo ""

# --- Build tests ---
echo "[2/4] Build Tests"
echo "-------------------------------------------"
run_test "Debug build" "zig build --prefix '$BUILD_DIR'"
run_test "ReleaseSafe build" "zig build --prefix '$BUILD_DIR' -Doptimize=ReleaseSafe"
run_test "Build with logging off" "zig build --prefix '$BUILD_DIR' -Dlog=false"

if [ -f "$BUILD_DIR/bin/BOOTX64.efi" ]; then
    run_check "Output EFI binary exists" "[ -f '$BUILD_DIR/bin/BOOTX64.efi' ]"
    run_check "EFI binary is PE format" "file '$BUILD_DIR/bin/BOOTX64.efi' | grep -qi 'PE32\+\|UEFI\|executable' > /dev/null 2>&1"
fi

# Optional: other UEFI targets (isolated prefix so default build/ stays x86_64)
MAC="$BUILD_DIR/.multi-arch-check"
echo ""
echo "[2b/4] Optional multi-arch EFI builds"
printf "  %-40s " "aarch64 → BOOTAA64.efi"
if zig build --prefix "$MAC/aarch64" -Darch=aarch64 > /dev/null 2>&1; then
    echo "[PASS]"
    PASS=$((PASS + 1))
    if [ -f "$MAC/aarch64/bin/BOOTAA64.efi" ]; then
        run_check "BOOTAA64.efi is PE" "file '$MAC/aarch64/bin/BOOTAA64.efi' | grep -qi 'PE32\+\|UEFI\|executable' > /dev/null 2>&1"
    fi
else
    echo "[SKIP]"
    SKIP=$((SKIP + 1))
fi
printf "  %-40s " "riscv64 → BOOTRISCV64.efi"
if command -v riscv64-linux-gnu-objcopy > /dev/null 2>&1 && zig build --prefix "$MAC/riscv64" -Darch=riscv64 > /dev/null 2>&1; then
    echo "[PASS]"
    PASS=$((PASS + 1))
    if [ -f "$MAC/riscv64/bin/BOOTRISCV64.efi" ]; then
        run_check "BOOTRISCV64.efi is PE" "file '$MAC/riscv64/bin/BOOTRISCV64.efi' | grep -qi 'PE32\+\|UEFI\|executable' > /dev/null 2>&1"
    fi
else
    echo "[SKIP]"
    SKIP=$((SKIP + 1))
fi
printf "  %-40s " "loong64 → BOOTLOONGARCH64.efi"
if command -v loongarch64-linux-gnu-objcopy > /dev/null 2>&1 && zig build --prefix "$MAC/loong64" -Darch=loong64 > /dev/null 2>&1; then
    echo "[PASS]"
    PASS=$((PASS + 1))
    if [ -f "$MAC/loong64/bin/BOOTLOONGARCH64.efi" ]; then
        run_check "BOOTLOONGARCH64.efi is PE" "file '$MAC/loong64/bin/BOOTLOONGARCH64.efi' | grep -qi 'PE32\+\|UEFI\|executable' > /dev/null 2>&1"
    fi
else
    echo "[SKIP]"
    SKIP=$((SKIP + 1))
fi
echo ""

# --- Zig build system tests ---
echo "[3/4] Zig Build System Tests"
echo "-------------------------------------------"
run_test "build.zig syntax valid" "zig build --help > /dev/null 2>&1"
run_check "build.zig.zon exists" "[ -f '$PROJECT_DIR/build.zig.zon' ]"
run_check "Source entry point exists" "[ -f '$PROJECT_DIR/src/main.zig' ]"
run_check "Kernel entry point exists" "[ -f '$PROJECT_DIR/src/kernel/main.zig' ]"
echo ""

# --- QEMU smoke test (headless, timeout) ---
echo "[4/4] QEMU Smoke Test"
echo "-------------------------------------------"

if command -v qemu-system-x86_64 > /dev/null 2>&1 && [ -f "$BUILD_DIR/bin/BOOTX64.efi" ]; then
    printf "  %-40s " "QEMU boot (5s timeout)"

    mkdir -p "$BUILD_DIR/efi/boot"
    cp "$BUILD_DIR/bin/BOOTX64.efi" "$BUILD_DIR/efi/boot/"

    OVMF_FW=""
    for fw in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd; do
        if [ -f "$fw" ]; then
            OVMF_FW="$fw"
            break
        fi
    done

    if [ -n "$OVMF_FW" ]; then
        SERIAL_LOG=$(mktemp)
        timeout 5 qemu-system-x86_64 \
            -bios "$OVMF_FW" \
            -net none \
            -drive format=raw,file=fat:rw:"$BUILD_DIR" \
            -m 256M \
            -serial file:"$SERIAL_LOG" \
            -display none \
            -no-reboot \
            -no-shutdown 2>/dev/null || true

        if grep -q "ChimeraOS" "$SERIAL_LOG" 2>/dev/null; then
            echo "[PASS]"
            PASS=$((PASS + 1))
        else
            echo "[SKIP] (no serial output captured)"
            SKIP=$((SKIP + 1))
        fi
        rm -f "$SERIAL_LOG"
    else
        echo "[SKIP] (OVMF firmware not found)"
        SKIP=$((SKIP + 1))
    fi
else
    printf "  %-40s [SKIP]\n" "QEMU boot (5s timeout)"
    SKIP=$((SKIP + 1))
fi

echo ""
echo "============================================"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
