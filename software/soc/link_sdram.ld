/* Linker script for a program that runs entirely out of external SDRAM.
 *
 * The point of docs/roadmap.md's Phase 2 is that 64 KB of block RAM is what
 * stands between this SoC and anything larger, so this script exists to place
 * a program that *cannot* fit there: software/soc/sdramtable.S alone is 96 KB
 * of .rodata, and the linker will refuse the build rather than let it
 * silently shrink.
 *
 * Same LOAD/RUN split as link_ram.ld, and for the same reason - crt0_ram.S
 * copies .data out of a read-only pristine copy on every startup, so the
 * program survives a reset instead of inheriting whatever the last run left
 * in .data. See link_ram.ld's header for the newlib incident that put it
 * there; nothing about that reasoning changes when the memory is SDRAM,
 * except that SDRAM does not even come back from reset holding the old
 * contents in the first place, which would turn the same bug into something
 * far harder to recognise.
 *
 * Addresses must agree with SDRAM_BASE in software/soc/soc.h and with the
 * S_SDRAM base byte in rtl/soc/soc_top.v. Safe direction of error: a program
 * linked *below* the SDRAM base lands in unmapped space and the interconnect
 * acks it with zeros, so the CPU executes zero words and traps on an illegal
 * instruction - loud, and at the first instruction.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    /* LOAD: .text, .rodata (including the 96 KB table), and the pristine
     *       copy of .data.
     * RUN:  .data, .bss, heap and stack.
     *
     * The gap from 0x9010_0000 is where sdramtest.c's memory sweep runs. It
     * is outside both regions on purpose, exactly as link_ram.ld keeps its
     * 4 KB test hole outside both: the sweep writes a quarter of a megabyte
     * of patterns, and the linker - not a comment - is what guarantees it
     * cannot reach code or live data however the program grows. */
    LOAD (rx) : ORIGIN = 0x90000000, LENGTH = 512K   /* ..0x9008_0000 */
    RUN  (rw) : ORIGIN = 0x90080000, LENGTH = 512K   /* ..0x9010_0000 */
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
        *(.srodata*)
        . = ALIGN(4);
    } > LOAD

    .data : ALIGN(4) {
        _sdata = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _edata = .;
    } > RUN AT> LOAD

    _sidata = LOADADDR(.data);
    _eidata = LOADADDR(.data) + SIZEOF(.data);

    .bss (NOLOAD) : {
        _bss_start = .;

        /* The fatal-trap reporter's private stack - see link_ram.ld for why
         * it is at the front of .bss rather than the back. */
        . = ALIGN(16);
        _trap_stack_bottom = .;
        . = . + 512;
        _trap_stack_top = .;

        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > RUN

    . = ALIGN(8);
    _end = .;

    PROVIDE(__global_pointer$ = _bss_start + 0x800);

    /* Stack at the top of RUN, growing down towards the heap. */
    _stack_top = ORIGIN(RUN) + LENGTH(RUN);

    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
