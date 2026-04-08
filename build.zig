const std = @import("std");

const ArchTarget = enum {
    x86_64,
    aarch64,
    riscv64,
    loong64,
};

fn archInfo(a: ArchTarget) struct {
    cpu_arch: std.Target.Cpu.Arch,
    os_tag: std.Target.Os.Tag,
    efi_name: []const u8,
    qemu_bin: []const u8,
    root_source: []const u8,
} {
    return switch (a) {
        .x86_64 => .{
            .cpu_arch = .x86_64,
            .os_tag = .uefi,
            .efi_name = "BOOTX64",
            .qemu_bin = "qemu-system-x86_64",
            .root_source = "src/main.zig",
        },
        .aarch64 => .{
            .cpu_arch = .aarch64,
            .os_tag = .uefi,
            .efi_name = "BOOTAA64",
            .qemu_bin = "qemu-system-aarch64",
            .root_source = "src/main.zig",
        },
        // riscv64/loong64: Zig cannot link riscv64-uefi / loong64-uefi PE (UnsupportedCoffArchitecture).
        // Build freestanding ELF + GNU objcopy to pei-* + fix_pe_imagebase.py.
        .riscv64 => .{
            .cpu_arch = .riscv64,
            .os_tag = .freestanding,
            .efi_name = "BOOTRISCV64",
            .qemu_bin = "qemu-system-riscv64",
            .root_source = "src/main_riscv64.zig",
        },
        .loong64 => .{
            .cpu_arch = .loongarch64,
            .os_tag = .freestanding,
            .efi_name = "BOOTLOONGARCH64",
            .qemu_bin = "qemu-system-loongarch64",
            .root_source = "src/main_loong64.zig",
        },
    };
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const is_debug = optimize == .Debug;

    const enable_logging = b.option(
        bool,
        "log",
        "Enable kernel logging (default: true for Debug, false for Release)",
    ) orelse is_debug;

    const arch_choice = b.option(
        ArchTarget,
        "arch",
        "Target architecture (default: x86_64)",
    ) orelse .x86_64;

    const info = archInfo(arch_choice);

    const options = b.addOptions();
    options.addOption(bool, "enable_logging", enable_logging);

    const target = b.resolveTargetQuery(.{
        .cpu_arch = info.cpu_arch,
        .os_tag = info.os_tag,
    });

    const exe = b.addExecutable(.{
        .name = info.efi_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(info.root_source),
            .target = target,
            .optimize = optimize,
            // LoongArch64 UEFI: PIC forces PC-relative jump tables and
            // data references so the binary works at any load address
            // without relocation entries (PE .reloc section is empty).
            .pic = if (arch_choice == .loong64 or arch_choice == .riscv64) true else null,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });

    if (arch_choice == .loong64) {
        exe.linker_script = b.path("src/loong64_uefi.ld");
    }
    if (arch_choice == .riscv64) {
        exe.linker_script = b.path("src/riscv64_uefi.ld");
    }

    b.installArtifact(exe);

    // LoongArch64 / RISC-V64: ELF → PE/COFF via GNU objcopy + ImageBase fix.
    if (arch_choice == .loong64) {
        const objcopy = b.addSystemCommand(&.{
            "loongarch64-linux-gnu-objcopy",
            "-O",
            "pei-loongarch64",
            "--strip-debug",
            "--subsystem",
            "efi-app",
            "--remove-section=.comment",
            "--remove-section=.eh_frame",
            "--remove-section=.eh_frame_hdr",
        });
        objcopy.addArtifactArg(exe);
        const efi_out = objcopy.addOutputFileArg(b.fmt("{s}.efi", .{info.efi_name}));

        const fix_pe = b.addSystemCommand(&.{
            "python3",
            "scripts/fix_pe_imagebase.py",
        });
        fix_pe.addFileArg(efi_out);
        fix_pe.step.dependOn(&objcopy.step);

        const efi_install = b.addInstallBinFile(efi_out, b.fmt("{s}.efi", .{info.efi_name}));
        efi_install.step.dependOn(&fix_pe.step);
        b.getInstallStep().dependOn(&efi_install.step);
    }
    if (arch_choice == .riscv64) {
        const objcopy = b.addSystemCommand(&.{
            "riscv64-linux-gnu-objcopy",
            "-O",
            "pei-riscv64-little",
            "--strip-debug",
            "--subsystem",
            "efi-app",
            "--remove-section=.comment",
            "--remove-section=.eh_frame",
            "--remove-section=.eh_frame_hdr",
        });
        objcopy.addArtifactArg(exe);
        const efi_out = objcopy.addOutputFileArg(b.fmt("{s}.efi", .{info.efi_name}));

        const fix_pe = b.addSystemCommand(&.{
            "python3",
            "scripts/fix_pe_imagebase.py",
        });
        fix_pe.addFileArg(efi_out);
        fix_pe.step.dependOn(&objcopy.step);

        const efi_install = b.addInstallBinFile(efi_out, b.fmt("{s}.efi", .{info.efi_name}));
        efi_install.step.dependOn(&fix_pe.step);
        b.getInstallStep().dependOn(&efi_install.step);
    }

    const prefix = b.install_prefix;

    // Setup EFI directory structure and run QEMU
    const run_step = b.step("run", "Run Darwin 19.x Z-Kernel in QEMU");

    const efi_boot_dir = "efi/boot";

    const setup_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\mkdir -p "{[p]s}/{[e]s}"
            \\if [ -f "{[p]s}/bin/{[n]s}.efi" ]; then cp "{[p]s}/bin/{[n]s}.efi" "{[p]s}/{[e]s}/"
            \\elif [ -f "{[p]s}/bin/{[n]s}" ]; then cp "{[p]s}/bin/{[n]s}" "{[p]s}/{[e]s}/"
            \\fi
        ,
            .{ .p = prefix, .e = efi_boot_dir, .n = info.efi_name }),
    });
    setup_cmd.step.dependOn(b.getInstallStep());

    const qemu_cmd = switch (arch_choice) {
        .x86_64 => blk: {
            const cmd = b.addSystemCommand(&.{
                info.qemu_bin,
                "-bios",
                "/usr/share/OVMF/OVMF_CODE_4M.fd",
                "-net",
                "none",
                "-drive",
                b.fmt("format=raw,file=fat:rw:{s}", .{prefix}),
                "-m",
                "256M",
                "-serial",
                "stdio",
                "-no-reboot",
                "-no-shutdown",
            });
            break :blk cmd;
        },
        .aarch64 => blk: {
            const cmd = b.addSystemCommand(&.{
                info.qemu_bin,
                "-machine",
                "virt",
                "-cpu",
                "cortex-a72",
                "-bios",
                "/usr/share/AAVMF/AAVMF_CODE.fd",
                "-net",
                "none",
                "-drive",
                b.fmt("format=raw,file=fat:rw:{s}", .{prefix}),
                "-m",
                "256M",
                "-serial",
                "stdio",
                "-no-reboot",
                "-no-shutdown",
            });
            break :blk cmd;
        },
        .riscv64 => blk: {
            const cmd = b.addSystemCommand(&.{
                info.qemu_bin,
                "-machine",
                "virt",
                "-bios",
                "default",
                "-net",
                "none",
                "-drive",
                b.fmt("format=raw,file=fat:rw:{s}", .{prefix}),
                "-m",
                "256M",
                "-serial",
                "stdio",
                "-no-reboot",
                "-no-shutdown",
            });
            break :blk cmd;
        },
        .loong64 => blk: {
            const install_base = if (std.fs.path.isAbsolute(prefix)) prefix else b.pathResolve(&.{ b.build_root.path orelse ".", prefix });
            const cmd = b.addSystemCommand(&.{
                "bash", "scripts/run.sh", "--arch", "loong64", "--no-build", "--memory", "1G",
            });
            cmd.setCwd(b.path(""));
            cmd.setEnvironmentVariable("CHIMERA_BUILD_PREFIX", install_base);
            break :blk cmd;
        },
    };

    qemu_cmd.step.dependOn(&setup_cmd.step);
    run_step.dependOn(&qemu_cmd.step);

    // Disk image creation step
    const img_step = b.step("image", "Create bootable disk image");
    const img_cmd = b.addSystemCommand(&.{
        "bash", "scripts/create_image.sh",
    });
    img_cmd.step.dependOn(b.getInstallStep());
    img_step.dependOn(&img_cmd.step);
}
