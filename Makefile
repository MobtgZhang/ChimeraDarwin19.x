# ChimeraDarwin19.x — Makefile
# Default goal: make run-debug
# Targets: make run-debug | make run-release | make build | make clean | make image | make help

.DEFAULT_GOAL := run-debug

PROJECT_DIR := .
BUILD_DIR   := $(PROJECT_DIR)/build
ZIG         := zig

ARCH      ?= x86_64
LOG        ?= true
PREFIX    ?= $(BUILD_DIR)

# EFI binary names
EFI_NAME_x86_64   := BOOTX64
EFI_NAME_aarch64   := BOOTAA64
EFI_NAME_riscv64   := BOOTRISCV64
EFI_NAME_loong64   := BOOTLOONGARCH64
EFI_NAME            := $(EFI_NAME_$(ARCH))

# QEMU binaries
QEMU_BIN_x86_64   := qemu-system-x86_64
QEMU_BIN_aarch64   := qemu-system-aarch64
QEMU_BIN_riscv64   := qemu-system-riscv64
QEMU_BIN_loong64   := qemu-system-loongarch64
QEMU_BIN            := $(QEMU_BIN_$(ARCH))

# UEFI firmware
OVMF_x86_64   := /usr/share/qemu/OVMF.fd
OVMF_aarch64   := /usr/share/AAVMF/AAVMF_CODE.fd
OVMF_riscv64   := default
OVMF_loong64   := 
OVMF             := $(OVMF_$(ARCH))

# QEMU extra args
QEMU_EXTRA_x86_64  := -machine pc
QEMU_EXTRA_aarch64  := -machine virt -cpu cortex-a72
QEMU_EXTRA_riscv64  := -machine virt
QEMU_EXTRA_loong64  := 
QEMU_EXTRA           := $(QEMU_EXTRA_$(ARCH))

# ── Color codes (evaluated at make parse time via $(shell)) ──

C_RESET  := $(shell printf '\033[0m')
C_RED    := $(shell printf '\033[0;31m')
C_GREEN  := $(shell printf '\033[0;32m')
C_YELLOW := $(shell printf '\033[0;33m')
C_CYAN   := $(shell printf '\033[0;36m')

.PHONY: help run-debug run-release build clean image deps

help:
	@printf '%s\n' "$(C_CYAN)ChimeraDarwin19.x - Makefile$(C_RESET)" ""
	@printf '%s\n' "Usage: make [TARGET] [VARS...]"
	@printf '%s\n' ""
	@printf '%s\n' "$(C_GREEN)Targets:$(C_RESET)"
	@printf '  %-24s %s\n' "make (default)" "Build Debug and run in QEMU"
	@printf '  %-24s %s\n' "make run-debug" "Build Debug and run in QEMU"
	@printf '  %-24s %s\n' "make run-release" "Build ReleaseSafe and run in QEMU"
	@printf '  %-24s %s\n' "make build" "Build only (no QEMU)"
	@printf '  %-24s %s\n' "make clean" "Remove build artifacts"
	@printf '  %-24s %s\n' "make image" "Create bootable disk image"
	@printf '  %-24s %s\n' "make deps" "Check Zig toolchain"
	@printf '%s\n' ""
	@printf '%s\n' "$(C_GREEN)Variables:$(C_RESET)"
	@printf '  %-24s %s\n' "ARCH=x86_64" "Target arch (x86_64, aarch64, riscv64, loong64)"
	@printf '  %-24s %s\n' "LOG=true" "Enable logging (true/false)"
	@printf '  %-24s %s\n' "PREFIX=./build" "Installation prefix"
	@printf '%s\n' ""
	@printf '%s\n' "$(C_GREEN)Examples:$(C_RESET)"
	@printf '  %s\n' "make                         # default: x86_64 debug + QEMU"
	@printf '  %s\n' "make ARCH=aarch64 run-debug  # ARM64 debug + QEMU"
	@printf '  %s\n' "make ARCH=riscv64 build      # RISC-V build only"
	@printf '  %s\n' "make LOG=false run-release   # Release without debug output"

deps:
	@printf '%s\n' "$(C_CYAN)[DEPS] Checking Zig toolchain...$(C_RESET)"
	@command -v $(ZIG) >/dev/null 2>&1 || { printf '%s\n' "$(C_RED)[ERROR] Zig not found. Install Zig 0.15.2+ from https://ziglang.org$(C_RESET)"; exit 1; }
	@printf '%s %s\n' "$(C_GREEN)[DEPS] Zig found:$(C_RESET)" "$$($(ZIG) version)"

clean:
	@printf '%s\n' "$(C_CYAN)[CLEAN] Removing build artifacts...$(C_RESET)"
	@rm -rf "$(BUILD_DIR)" "$(PROJECT_DIR)/zig-cache" "$(PROJECT_DIR)/.zig-cache"
	@printf '%s\n' "$(C_GREEN)[CLEAN] Done.$(C_RESET)"

build: deps
	@printf '%s\n' "$(C_CYAN)[BUILD] Building ChimeraOS (arch=$(ARCH))...$(C_RESET)"
	$(ZIG) build --prefix "$(PREFIX)" -Darch=$(ARCH) -Dlog=$(LOG)
	@printf '%s\n' "$(C_GREEN)[BUILD] Done.$(C_RESET)"

run-debug: deps
	@printf '%s\n' "$(C_CYAN)[BUILD] Building ChimeraOS Debug (arch=$(ARCH))...$(C_RESET)"
	$(ZIG) build --prefix "$(PREFIX)" -Darch=$(ARCH) -Doptimize=Debug -Dlog=true
	@printf '%s\n' "$(C_GREEN)[BUILD] BOOTX64.efi ready.$(C_RESET)"
	@printf '%s\n' "$(C_CYAN)[QEMU] Launching QEMU...$(C_RESET)"
	@mkdir -p "$(PREFIX)/efi/boot"
	@cp "$(PREFIX)/bin/$(EFI_NAME).efi" "$(PREFIX)/efi/boot/" 2>/dev/null || \
	cp "$(PREFIX)/bin/$(EFI_NAME)" "$(PREFIX)/efi/boot/" 2>/dev/null || true
	$(QEMU_BIN) $(QEMU_EXTRA) $(if $(OVMF),-bios "$(OVMF)",) \
	-net none \
	-drive "format=raw,file=fat:rw:$(PREFIX)" \
	-m 256M -serial stdio -no-reboot -no-shutdown

run-release: deps
	@printf '%s\n' "$(C_CYAN)[BUILD] Building ChimeraOS ReleaseSafe (arch=$(ARCH))...$(C_RESET)"
	$(ZIG) build --prefix "$(PREFIX)" -Darch=$(ARCH) -Doptimize=ReleaseSafe -Dlog=false
	@printf '%s\n' "$(C_GREEN)[BUILD] BOOTX64.efi ready.$(C_RESET)"
	@printf '%s\n' "$(C_CYAN)[QEMU] Launching QEMU...$(C_RESET)"
	@mkdir -p "$(PREFIX)/efi/boot"
	@cp "$(PREFIX)/bin/$(EFI_NAME).efi" "$(PREFIX)/efi/boot/" 2>/dev/null || \
	cp "$(PREFIX)/bin/$(EFI_NAME)" "$(PREFIX)/efi/boot/" 2>/dev/null || true
	$(QEMU_BIN) $(QEMU_EXTRA) $(if $(OVMF),-bios "$(OVMF)",) \
	-net none \
	-drive "format=raw,file=fat:rw:$(PREFIX)" \
	-m 256M -serial stdio -no-reboot -no-shutdown

image: build
	@printf '%s\n' "$(C_CYAN)[IMAGE] Creating bootable disk image...$(C_RESET)"
	@bash "$(PROJECT_DIR)/scripts/create_image.sh"
	@printf '%s\n' "$(C_GREEN)[IMAGE] Disk image created: $(BUILD_DIR)/disk.img$(C_RESET)"
