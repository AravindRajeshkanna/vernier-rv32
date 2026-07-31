/* Boot ROM linker script for the SoC build.
 *
 * Much simpler than software/link.ld, and that is the point: the SoC has one
 * unified physical address space, so this is an ordinary linker script
 * rather than the two-regions-both-at-zero contortion the Harvard build
 * needs. .rodata lives in ROM and is read directly from there - no copy to
 * RAM, no fictitious LMA region.
 *
 * Sizes must match rtl/soc/soc_top.v (ROM_WORDS*4, RAM_BYTES) and
 * software/soc/soc.h.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 256K
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
        *(.srodata*)
    } > ROM

    /* The boot ROM is written to have no initialized data. Assert rather
     * than silently produce a broken image if that ever stops being true:
     * there is no ROM-to-RAM copy loop in crt0_rom.S, so a non-empty .data
     * would link fine and then read as garbage at run time. */
    .data : {
        *(.data*)
        *(.sdata*)
    } > RAM
    ASSERT(SIZEOF(.data) == 0,
           "boot ROM must have no initialized .data - crt0_rom.S has no copy loop")

    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    _end = .;

    PROVIDE(__global_pointer$ = _bss_start + 0x800);

    /* Boot stack sits in the low 4 KB of RAM that soc.h reserves, safely
     * below where the program image gets loaded. */
    _boot_stack_top = 0x80000FF0;
}
