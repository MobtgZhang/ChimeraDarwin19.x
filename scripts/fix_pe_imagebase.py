#!/usr/bin/env python3
"""
Fix PE/COFF ImageBase for LoongArch64 UEFI applications.

GNU objcopy sets ImageBase=0 when converting ELF to PE/COFF, but the
LoongArch ELF sections are linked at ~0x01000000.  This produces a
19 MB SizeOfImage that UEFI cannot allocate at address 0.

This script rebases the PE to ImageBase=<lowest section VMA aligned down>,
adjusting EntryPoint, SizeOfImage, BaseOfCode, and all section RVAs.
"""

import struct
import sys


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <pe-file> [output-file]", file=sys.stderr)
        sys.exit(1)

    in_path = sys.argv[1]
    out_path = sys.argv[2] if len(sys.argv) > 2 else in_path

    with open(in_path, "rb") as f:
        data = bytearray(f.read())

    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]

    sig = data[e_lfanew : e_lfanew + 4]
    if sig != b"PE\x00\x00":
        print("Not a PE file", file=sys.stderr)
        sys.exit(1)

    coff_off = e_lfanew + 4
    num_sections = struct.unpack_from("<H", data, coff_off + 2)[0]
    opt_hdr_size = struct.unpack_from("<H", data, coff_off + 16)[0]
    opt_off = coff_off + 20

    magic = struct.unpack_from("<H", data, opt_off)[0]
    if magic != 0x20B:
        print(f"Not PE32+ (magic=0x{magic:04X})", file=sys.stderr)
        sys.exit(1)

    old_ep = struct.unpack_from("<I", data, opt_off + 16)[0]
    old_base_of_code = struct.unpack_from("<I", data, opt_off + 20)[0]
    old_image_base = struct.unpack_from("<Q", data, opt_off + 24)[0]
    sect_align = struct.unpack_from("<I", data, opt_off + 32)[0]
    old_size_of_image = struct.unpack_from("<I", data, opt_off + 56)[0]

    sec_hdr_off = opt_off + opt_hdr_size
    min_va = 0xFFFFFFFF
    max_end = 0
    for i in range(num_sections):
        so = sec_hdr_off + i * 40
        va = struct.unpack_from("<I", data, so + 12)[0]
        vs = struct.unpack_from("<I", data, so + 8)[0]
        min_va = min(min_va, va)
        end = va + vs
        if end > max_end:
            max_end = end

    # Only rebase if sections are far from 0 (e.g. linked at 16 MB).
    # After rebasing, the first section's RVA must still be >= SectionAlignment
    # (so it doesn't overlap with PE headers at RVA 0).
    candidate = (min_va // sect_align) * sect_align
    first_section_rva_after = min_va - candidate
    if candidate > 0 and first_section_rva_after >= sect_align:
        new_image_base = candidate
    else:
        new_image_base = old_image_base
    delta = new_image_base - old_image_base

    print(f"Fixing PE/COFF for UEFI:")

    if delta != 0:
        new_ep = old_ep - delta
        new_base_of_code = old_base_of_code - delta
        new_size_of_image = old_size_of_image - delta

        print(f"  Rebasing ImageBase: 0x{old_image_base:016X} -> 0x{new_image_base:016X}")
        print(f"  EntryPoint:      0x{old_ep:08X} -> 0x{new_ep:08X}")
        print(f"  BaseOfCode:      0x{old_base_of_code:08X} -> 0x{new_base_of_code:08X}")
        print(f"  SizeOfImage:     0x{old_size_of_image:08X} -> 0x{new_size_of_image:08X}")

        struct.pack_into("<I", data, opt_off + 16, new_ep)
        struct.pack_into("<I", data, opt_off + 20, new_base_of_code)
        struct.pack_into("<Q", data, opt_off + 24, new_image_base)
        struct.pack_into("<I", data, opt_off + 56, new_size_of_image)
    else:
        new_size_of_image = old_size_of_image
        print(f"  ImageBase 0x{old_image_base:016X} is already optimal")

    # Clear RELOCS_STRIPPED (bit 0) so UEFI can relocate the image.
    # Our LoongArch code uses PC-relative addressing, so no fixups
    # are actually needed; we just need the loader to accept the binary.
    old_chars = struct.unpack_from("<H", data, coff_off + 18)[0]
    new_chars = old_chars & ~0x0001  # clear IMAGE_FILE_RELOCS_STRIPPED
    struct.pack_into("<H", data, coff_off + 18, new_chars)
    print(f"  Characteristics: 0x{old_chars:04X} -> 0x{new_chars:04X} (cleared RELOCS_STRIPPED)")

    for i in range(num_sections):
        so = sec_hdr_off + i * 40
        name = data[so : so + 8].rstrip(b"\x00").decode("ascii", errors="replace")
        old_va = struct.unpack_from("<I", data, so + 12)[0]
        new_va = old_va - delta
        struct.pack_into("<I", data, so + 12, new_va)
        print(f"  Section {name:16s}: RVA 0x{old_va:08X} -> 0x{new_va:08X}")

    # Check if .reloc already exists; skip adding if so.
    has_reloc = False
    for i in range(num_sections):
        so = sec_hdr_off + i * 40
        name = data[so : so + 8].rstrip(b"\x00")
        if name == b".reloc":
            has_reloc = True
            break

    if has_reloc:
        print("  .reloc section already present, skipping addition")
        with open(out_path, "wb") as f:
            f.write(data)
        print(f"Written to {out_path}")
        return

    # Append a minimal empty .reloc section.  UEFI PE/COFF loader
    # expects a Base Relocation Directory when RELOCS_STRIPPED is clear.
    # An empty directory (single block with SizeOfBlock=8) satisfies this.
    reloc_rva = new_size_of_image  # place at end of virtual image
    reloc_raw_offset = len(data)
    reloc_block = struct.pack("<II", 0, 8)  # PageRVA=0, BlockSize=8 (empty)
    file_align = struct.unpack_from("<I", data, opt_off + 36)[0]
    pad_len = (file_align - (len(reloc_block) % file_align)) % file_align
    reloc_data = reloc_block + b"\x00" * pad_len

    # Add .reloc section header (increase NumberOfSections)
    struct.pack_into("<H", data, coff_off + 2, num_sections + 1)

    reloc_hdr = struct.pack(
        "<8sIIIIIIHHI",
        b".reloc\x00\x00",
        len(reloc_block),        # VirtualSize
        reloc_rva,               # VirtualAddress (RVA)
        len(reloc_data),         # SizeOfRawData
        reloc_raw_offset,        # PointerToRawData
        0, 0, 0, 0,             # relocations/linenumbers pointers and counts
        0x42000040,              # Characteristics: INITIALIZED_DATA | DISCARDABLE | MEM_READ
    )

    # Update Base Relocation Directory entry (data directory index 5)
    dd_off = opt_off + 112 + 5 * 8  # 112 = fixed opt header size, entry 5
    struct.pack_into("<II", data, dd_off, reloc_rva, len(reloc_block))
    print(f"  Added .reloc section: RVA=0x{reloc_rva:08X}, size={len(reloc_block)}")

    # Update SizeOfImage to include .reloc
    aligned_reloc = ((len(reloc_block) + sect_align - 1) // sect_align) * sect_align
    struct.pack_into("<I", data, opt_off + 56, new_size_of_image + aligned_reloc)

    # Overwrite padding after existing section headers (do NOT insert,
    # which would shift all section data and break PointerToRawData).
    insert_pos = sec_hdr_off + num_sections * 40
    size_of_headers = struct.unpack_from("<I", data, opt_off + 60)[0]
    if insert_pos + 40 > size_of_headers:
        print("ERROR: no room for .reloc section header in PE headers", file=sys.stderr)
        sys.exit(1)
    data[insert_pos : insert_pos + 40] = reloc_hdr

    # Append relocation data at end of file
    data.extend(reloc_data)

    with open(out_path, "wb") as f:
        f.write(data)

    print(f"Written to {out_path}")


if __name__ == "__main__":
    main()
