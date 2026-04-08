/* LoongArch64 UEFI linker script.
 *
 * Forces 4 KiB section alignment required by the UEFI PE/COFF loader.
 * The resulting ELF is post-processed by objcopy + fix_pe_imagebase.py
 * to produce a valid EFI application.
 */

ENTRY(_start)

SECTIONS
{
    /* Start at 0x1000: PE headers occupy RVA 0x0 .. SizeOfHeaders. */
    . = 0x1000;

    .rodata ALIGN(4096) :
    {
        *(.rodata .rodata.*)
    }

    .text ALIGN(4096) :
    {
        *(.text .text.*)
    }

    .got ALIGN(4096) :
    {
        *(.got .got.*)
    }

    .data ALIGN(4096) :
    {
        *(.data .data.*)
    }

    .bss ALIGN(4096) :
    {
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.note.*)
    }
}
