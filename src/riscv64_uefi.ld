/* RISC-V 64 UEFI: 4 KiB section alignment for PE/COFF after objcopy. */

ENTRY(_start)

SECTIONS
{
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

    /* Stack: LLD rejects ALIGN after (NOLOAD); align inside the section. */
    .stack (NOLOAD) :
    {
        . = ALIGN(4096);
        . += 128 * 1024;
        PROVIDE(__stack_top = .);
    }

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame)
        *(.eh_frame_hdr)
        *(.note.*)
    }
}
