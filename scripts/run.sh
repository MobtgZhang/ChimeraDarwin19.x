#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${CHIMERA_BUILD_PREFIX:-$PROJECT_DIR/build}"

ARCH="x86_64"
MEMORY="256M"
DISPLAY_OPT=""
EXTRA_ARGS=()
AUTO_BUILD=true
GDB_SERVER=false
MONITOR=false
LOONG_MACHINE="virt"  # virt | 2k3000 | 3a5000 | 3a6000
FIRMWARE_DIR="${FIRMWARE_DIR:-}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Launch ChimeraOS in QEMU"
    echo ""
    echo "Options:"
    echo "  --arch ARCH      Target architecture: x86_64 (default), aarch64, riscv64, loong64, mips64el"
    echo "  --loong-machine  LoongArch machine type: virt (default), 2k3000, 3a5000, 3a6000"
    echo "  --firmware-dir   Path to Loongson Firmware repository (optional; system paths used if unset)"
    echo "  Env: CHIMERA_BUILD_PREFIX  Install prefix (e.g. zig-out) when invoked from zig build run"
    echo "  --no-build       Skip automatic rebuild before running"
    echo "  --memory SIZE    Set guest memory (default: 256M)"
    echo "  --headless       Run without graphical display"
    echo "  --debug          Enable QEMU GDB server on port 1234"
    echo "  --monitor        Enable QEMU monitor on stdio"
    echo "  -h, --help       Show this help message"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)           ARCH="$2"; shift 2 ;;
        --loong-machine)  LOONG_MACHINE="$2"; shift 2 ;;
        --firmware-dir)   FIRMWARE_DIR="$2"; shift 2 ;;
        --no-build)       AUTO_BUILD=false; shift ;;
        --memory)         MEMORY="$2"; shift 2 ;;
        --headless)       DISPLAY_OPT="-display none"; shift ;;
        --debug)          GDB_SERVER=true; shift ;;
        --monitor)        MONITOR=true; shift ;;
        -h|--help)        usage ;;
        *)                EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# Map architecture to EFI binary name and QEMU binary
case "$ARCH" in
    x86_64)
        EFI_NAME="BOOTX64"
        QEMU_BIN="qemu-system-x86_64"
        ;;
    aarch64|arm64)
        ARCH="aarch64"
        EFI_NAME="BOOTAA64"
        QEMU_BIN="qemu-system-aarch64"
        ;;
    riscv64)
        EFI_NAME="BOOTRISCV64"
        QEMU_BIN="qemu-system-riscv64"
        ;;
    loong64|loongarch64)
        ARCH="loong64"
        EFI_NAME="BOOTLOONGARCH64"
        QEMU_BIN="qemu-system-loongarch64"
        ;;
    mips64el|mips64)
        ARCH="mips64el"
        EFI_NAME="BOOTMIPS64"
        QEMU_BIN="qemu-system-mips64el"
        ;;
    *)
        echo "[QEMU] ERROR: Unknown architecture: $ARCH"
        echo "       Supported: x86_64, aarch64, riscv64, loong64, mips64el"
        exit 1
        ;;
esac

# Determine EFI binary path.  LoongArch64 / RISC-V64 use ELF→PE (.efi) via objcopy in build.zig.
case "$ARCH" in
    mips64el)
        EFI_BIN="$BUILD_DIR/bin/${EFI_NAME}"
        ;;
    *)
        EFI_BIN="$BUILD_DIR/bin/${EFI_NAME}.efi"
        ;;
esac

cd "$PROJECT_DIR"

# LoongArch QEMU virt machine requires at least 1G RAM
if [ "$ARCH" = "loong64" ] && [ "$MEMORY" = "256M" ]; then
    MEMORY="1G"
fi

# Auto-build
if $AUTO_BUILD; then
    echo "[QEMU] Building ChimeraOS for $ARCH..."
    zig build --prefix "$BUILD_DIR" -Darch="$ARCH"
fi

if [ ! -f "$EFI_BIN" ]; then
    echo "[QEMU] ERROR: $EFI_BIN not found."
    echo "       Run 'bash scripts/build.sh --arch $ARCH' first."
    exit 1
fi

# Setup EFI boot directory structure
mkdir -p "$BUILD_DIR/efi/boot"
cp "$EFI_BIN" "$BUILD_DIR/efi/boot/"

echo "[QEMU] Starting ChimeraOS ($ARCH)..."
echo "  Architecture: $ARCH"
echo "  EFI Binary  : $EFI_BIN"
echo "  Memory      : $MEMORY"
echo "  Serial      : stdio"
echo ""

# Build QEMU command based on architecture
case "$ARCH" in
    x86_64)
        # Locate OVMF firmware
        OVMF_MODE=""
        OVMF_CODE=""
        OVMF_VARS=""

        SPLIT_CANDIDATES=(
            "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
            "/usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd"
            "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
            "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
        )

        for pair in "${SPLIT_CANDIDATES[@]}"; do
            code="${pair%%:*}"
            vars="${pair##*:}"
            if [ -f "$code" ] && [ -f "$vars" ]; then
                OVMF_MODE="pflash"
                OVMF_CODE="$code"
                OVMF_VARS="$vars"
                break
            fi
        done

        if [ -z "$OVMF_MODE" ]; then
            COMBINED_CANDIDATES=(
                "/usr/share/ovmf/OVMF.fd"
                "/usr/share/qemu/OVMF.fd"
                "/usr/share/OVMF/OVMF.fd"
                "/usr/share/edk2/x64/OVMF.fd"
            )
            for fw in "${COMBINED_CANDIDATES[@]}"; do
                if [ -f "$fw" ]; then
                    OVMF_MODE="bios"
                    OVMF_CODE="$fw"
                    break
                fi
            done
        fi

        if [ -z "$OVMF_MODE" ]; then
            echo "[QEMU] ERROR: OVMF firmware not found."
            echo "       Install: sudo apt install ovmf"
            exit 1
        fi

        QEMU_ARGS=(
            "$QEMU_BIN"
            -net none
            -drive "format=raw,file=fat:rw:$BUILD_DIR"
            -m "$MEMORY"
            -serial stdio
            -no-reboot
            -no-shutdown
        )

        if [ "$OVMF_MODE" = "pflash" ]; then
            PFLASH_VARS="$BUILD_DIR/OVMF_VARS.fd"
            [ ! -f "$PFLASH_VARS" ] && cp "$OVMF_VARS" "$PFLASH_VARS"
            QEMU_ARGS+=(
                -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
                -drive "if=pflash,format=raw,file=$PFLASH_VARS"
            )
            echo "  Firmware  : $OVMF_CODE (pflash)"
        else
            QEMU_ARGS+=(-bios "$OVMF_CODE")
            echo "  Firmware  : $OVMF_CODE (bios)"
        fi
        ;;

    aarch64)
        # Locate AAVMF/EDK2 ARM firmware
        AAVMF_CODE=""
        AAVMF_CANDIDATES=(
            "/usr/share/AAVMF/AAVMF_CODE.fd"
            "/usr/share/edk2/aarch64/QEMU_EFI.fd"
            "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
            "/usr/share/edk2/aarch64/QEMU_CODE.fd"
        )
        for fw in "${AAVMF_CANDIDATES[@]}"; do
            if [ -f "$fw" ]; then
                AAVMF_CODE="$fw"
                break
            fi
        done

        if [ -z "$AAVMF_CODE" ]; then
            echo "[QEMU] ERROR: ARM64 UEFI firmware not found."
            echo "       Install: sudo apt install qemu-efi-aarch64"
            exit 1
        fi

        echo "  Firmware  : $AAVMF_CODE"

        QEMU_ARGS=(
            "$QEMU_BIN"
            -machine virt
            -cpu cortex-a72
            -bios "$AAVMF_CODE"
            -net none
            -drive "format=raw,file=fat:rw:$BUILD_DIR"
            -m "$MEMORY"
            -serial stdio
            -no-reboot
            -no-shutdown
        )
        ;;

    riscv64)
        # RISC-V UEFI firmware (U-Boot or EDK2)
        RISCV_FW=""
        RISCV_CANDIDATES=(
            "/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin"
            "/usr/share/opensbi/lp64/generic/firmware/fw_dynamic.bin"
            "/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin"
        )
        for fw in "${RISCV_CANDIDATES[@]}"; do
            if [ -f "$fw" ]; then
                RISCV_FW="$fw"
                break
            fi
        done

        echo "  Firmware  : ${RISCV_FW:-default}"

        QEMU_ARGS=(
            "$QEMU_BIN"
            -machine virt
            -net none
            -drive "format=raw,file=fat:rw:$BUILD_DIR"
            -m "$MEMORY"
            -serial stdio
            -no-reboot
            -no-shutdown
        )

        if [ -n "$RISCV_FW" ]; then
            QEMU_ARGS+=(-bios "$RISCV_FW")
        else
            QEMU_ARGS+=(-bios default)
        fi
        ;;

    loong64)
        # Locate LoongArch UEFI firmware for QEMU virt machine
        LOONG_EFI=""
        LOONG_VARS=""

        LOONG_FW_CANDIDATES=()
        if [ -n "$FIRMWARE_DIR" ]; then
            LOONG_FW_CANDIDATES+=("$FIRMWARE_DIR/LoongArchVirtMachine/QEMU_EFI.fd:$FIRMWARE_DIR/LoongArchVirtMachine/QEMU_VARS.fd")
        fi
        LOONG_FW_CANDIDATES+=(
            "/usr/share/edk2/loongarch64/QEMU_EFI.fd:/usr/share/edk2/loongarch64/QEMU_VARS.fd"
            "/usr/share/qemu/edk2-loongarch64-code.fd:/usr/share/qemu/edk2-loongarch64-vars.fd"
        )

        for pair in "${LOONG_FW_CANDIDATES[@]}"; do
            efi="${pair%%:*}"
            vars="${pair##*:}"
            if [ -f "$efi" ]; then
                LOONG_EFI="$efi"
                [ -f "$vars" ] && LOONG_VARS="$vars"
                break
            fi
        done

        if [ -z "$LOONG_EFI" ]; then
            echo "[QEMU] WARNING: LoongArch UEFI firmware not found, using QEMU built-in."
            echo "       For best results, clone https://github.com/loongson/Firmware"
            echo "       or set FIRMWARE_DIR to the firmware repository path."
            LOONG_EFI="default"
        fi

        echo "  Firmware  : $LOONG_EFI"
        echo "  Machine   : $LOONG_MACHINE"

        # Create a GPT ESP disk image for UEFI boot using mtools (no root needed).
        # UEFI firmware discovers \EFI\BOOT\BOOTLOONGARCH64.EFI on the ESP.
        LOONG_ESP_IMG="$BUILD_DIR/loong_esp.img"
        if [ -f "$EFI_BIN" ]; then
            echo "[QEMU] Creating UEFI ESP disk image..."
            PART_START_SECTOR=2048
            PART_END_SECTOR=131038
            PART_SECTORS=$((PART_END_SECTOR - PART_START_SECTOR + 1))
            PART_OFFSET=$((PART_START_SECTOR * 512))

            truncate -s 64M "$LOONG_ESP_IMG"
            sgdisk --clear \
                --new=1:${PART_START_SECTOR}:${PART_END_SECTOR} \
                --typecode=1:ef00 \
                --change-name=1:ESP \
                "$LOONG_ESP_IMG" >/dev/null 2>&1

            mformat -i "${LOONG_ESP_IMG}@@${PART_OFFSET}" -F -T "$PART_SECTORS" ::
            mmd -i "${LOONG_ESP_IMG}@@${PART_OFFSET}" ::/EFI
            mmd -i "${LOONG_ESP_IMG}@@${PART_OFFSET}" ::/EFI/BOOT
            mcopy -i "${LOONG_ESP_IMG}@@${PART_OFFSET}" \
                "$EFI_BIN" ::/EFI/BOOT/BOOTLOONGARCH64.EFI

            # startup.nsh auto-launches the kernel from EFI shell
            STARTUP_NSH=$(mktemp)
            echo 'FS0:\EFI\BOOT\BOOTLOONGARCH64.EFI' > "$STARTUP_NSH"
            mcopy -i "${LOONG_ESP_IMG}@@${PART_OFFSET}" "$STARTUP_NSH" ::/startup.nsh
            rm -f "$STARTUP_NSH"

            echo "  ESP Image : $LOONG_ESP_IMG"
        fi

        QEMU_ARGS=(
            "$QEMU_BIN"
            -machine virt
            -cpu la464
            -smp 4
            -net none
            -m "$MEMORY"
            -serial stdio
            -no-reboot
            -no-shutdown
        )

        # LoongArch QEMU virt machine only supports -bios, not pflash.
        if [ "$LOONG_EFI" != "default" ]; then
            QEMU_ARGS+=(-bios "$LOONG_EFI")
            echo "  FW Mode   : bios"
        else
            QEMU_ARGS+=(-bios default)
        fi

        # Attach ESP disk image for UEFI boot discovery
        if [ -f "$LOONG_ESP_IMG" ]; then
            QEMU_ARGS+=(
                -drive "file=$LOONG_ESP_IMG,format=raw,if=virtio"
            )
        fi

        # Add display and input devices for LoongArch virt.
        # Use virtio-vga (not virtio-gpu-pci) to get a direct linear
        # framebuffer via UEFI GOP instead of BLT-only mode.
        QEMU_ARGS+=(
            -device virtio-vga
            -device nec-usb-xhci,id=xhci,addr=0x1b
            -device usb-tablet,id=tablet,bus=xhci.0,port=1
            -device usb-kbd,id=keyboard,bus=xhci.0,port=2
        )

        case "$LOONG_MACHINE" in
            2k3000)
                echo "  Target HW : Loongson 2K3000 (QEMU virt emulation)"
                ;;
            3a5000)
                echo "  Target HW : Loongson 3A5000 + 7A1000/7A2000 (QEMU virt emulation)"
                ;;
            3a6000)
                echo "  Target HW : Loongson 3A6000 + 7A2000 (QEMU virt emulation)"
                ;;
            virt|*)
                echo "  Target HW : QEMU loongarch64 virt (generic)"
                ;;
        esac
        ;;

    mips64el)
        echo "  Firmware  : Malta ROM (non-UEFI)"
        echo "  NOTE: MIPS64el uses direct kernel load, not standard UEFI boot."

        QEMU_ARGS=(
            "$QEMU_BIN"
            -machine malta
            -net none
            -m "$MEMORY"
            -serial stdio
            -no-reboot
            -no-shutdown
            -kernel "$EFI_BIN"
        )
        ;;
esac

if $GDB_SERVER; then
    echo "[QEMU] GDB server listening on tcp::1234"
    QEMU_ARGS+=(-s -S)
fi

if $MONITOR; then
    QEMU_ARGS+=(-monitor telnet:127.0.0.1:55555,server,nowait)
    echo "[QEMU] Monitor: telnet 127.0.0.1 55555"
fi

if [ -n "$DISPLAY_OPT" ]; then
    # shellcheck disable=SC2206
    QEMU_ARGS+=($DISPLAY_OPT)
fi

QEMU_ARGS+=("${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}")

exec "${QEMU_ARGS[@]}"
