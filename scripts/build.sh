#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

cd "$PROJECT_DIR"

OPTIMIZE=""
LOGGING=""

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --release        Build in ReleaseSafe mode"
    echo "  --release-fast   Build in ReleaseFast mode"
    echo "  --release-small  Build in ReleaseSmall mode"
    echo "  --log            Force enable logging"
    echo "  --no-log         Force disable logging"
    echo "  --clean          Remove build artifacts before building"
    echo "  --image          Also create bootable disk image"
    echo "  -h, --help       Show this help message"
    exit 0
}

CLEAN=false
IMAGE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)        OPTIMIZE="-Doptimize=ReleaseSafe"; shift ;;
        --release-fast)   OPTIMIZE="-Doptimize=ReleaseFast"; shift ;;
        --release-small)  OPTIMIZE="-Doptimize=ReleaseSmall"; shift ;;
        --log)            LOGGING="-Dlog=true"; shift ;;
        --no-log)         LOGGING="-Dlog=false"; shift ;;
        --clean)          CLEAN=true; shift ;;
        --image)          IMAGE=true; shift ;;
        -h|--help)        usage ;;
        *)                echo "Unknown option: $1"; usage ;;
    esac
done

if $CLEAN; then
    echo "[BUILD] Cleaning build artifacts..."
    rm -rf "$BUILD_DIR/bin" "$BUILD_DIR/efi" "$PROJECT_DIR/zig-cache" "$PROJECT_DIR/.zig-cache"
fi

echo "[BUILD] Building ChimeraOS..."
echo "  Project : $PROJECT_DIR"
echo "  Output  : $BUILD_DIR"
[ -n "$OPTIMIZE" ] && echo "  Optimize: $OPTIMIZE"
[ -n "$LOGGING" ]  && echo "  Logging : $LOGGING"

# shellcheck disable=SC2086
zig build --prefix "$BUILD_DIR" $OPTIMIZE $LOGGING

if [ -f "$BUILD_DIR/bin/BOOTX64.efi" ]; then
    echo "[BUILD] Success: $BUILD_DIR/bin/BOOTX64.efi"
    ls -lh "$BUILD_DIR/bin/BOOTX64.efi"
else
    echo "[BUILD] ERROR: BOOTX64.efi not found in output"
    exit 1
fi

if $IMAGE; then
    echo ""
    bash "$SCRIPT_DIR/create_image.sh"
fi
