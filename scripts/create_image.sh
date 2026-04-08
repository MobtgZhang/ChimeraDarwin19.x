#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
IMAGE="$BUILD_DIR/chimera-os.img"
EFI_BIN="$BUILD_DIR/bin/BOOTX64.efi"

if [ ! -f "$EFI_BIN" ]; then
    echo "ERROR: $EFI_BIN not found. Run 'zig build' first."
    exit 1
fi

echo "Creating ChimeraOS bootable disk image..."

# Create 64MB image
dd if=/dev/zero of="$IMAGE" bs=1M count=64 status=none

# Create FAT32 filesystem (mtools)
if command -v mformat &> /dev/null; then
    mformat -i "$IMAGE" -F ::
    mmd -i "$IMAGE" ::/EFI
    mmd -i "$IMAGE" ::/EFI/BOOT
    mcopy -i "$IMAGE" "$EFI_BIN" ::/EFI/BOOT/BOOTX64.EFI
    echo "Disk image created: $IMAGE"
    echo ""
    echo "Run with QEMU:"
    echo "  qemu-system-x86_64 -bios /usr/share/OVMF/OVMF_CODE_4M.fd \\"
    echo "    -drive format=raw,file=$IMAGE -m 256M -serial stdio"
else
    echo "mtools not found. Creating image via loopback (requires sudo)..."
    LOOP=$(sudo losetup -f --show "$IMAGE")
    sudo mkfs.fat -F 32 "$LOOP"
    MOUNT_DIR=$(mktemp -d)
    sudo mount "$LOOP" "$MOUNT_DIR"
    sudo mkdir -p "$MOUNT_DIR/EFI/BOOT"
    sudo cp "$EFI_BIN" "$MOUNT_DIR/EFI/BOOT/BOOTX64.EFI"
    sudo umount "$MOUNT_DIR"
    sudo losetup -d "$LOOP"
    rmdir "$MOUNT_DIR"
    echo "Disk image created: $IMAGE"
fi
