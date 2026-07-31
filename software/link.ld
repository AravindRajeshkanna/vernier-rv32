/* Two-region Harvard linker script: ROM (this core's imem, fetch-only)
 * and RAM (dmem) are both based at address 0, matching the two separate
 * physical arrays imem.v/dmem.v actually are - not a runtime mux, a
 * static fact of the hardware (see ARCHITECTURE.md). LENGTH must match
 * rtl/top.v's IMEM_WORDS*4 / DMEM_BYTES defaults (32K/32K).
 *
 * Read-only data (.rodata) has to live in RAM, not ROM: this CPU's imem
 * is fetch-only with no load path into it at all (no LPM-style
 * instruction, unlike e.g. AVR), so a string literal has to be somewhere
 * an ordinary `lw`/`lb` can actually reach it.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM     (rx)  : ORIGIN = 0x00000000, LENGTH = 32K
    RAM     (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
    /* Fictitious, never-loaded-from region purely so the linker has a
     * distinct load address (LMA) to assign .data - it and ROM otherwise
     * both legitimately start at 0 as *run* addresses (VMA), which is
     * exactly the point of this Harvard layout, but ld's overlap check
     * operates on LMA and doesn't know these are two separate physical
     * memories. Nothing here is ever actually loaded from RAM_LMA;
     * objcopy is told to extract by VMA, not LMA (see the root
     * Makefile's `--only-section` invocations). */
    RAM_LMA (rx)  : ORIGIN = 0x10000000, LENGTH = 32K
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
    } > ROM

    .data : {
        *(.rodata*)
        *(.srodata*)
        *(.data*)
        *(.sdata*)
    } > RAM AT> RAM_LMA

    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    _end = .;

    /* Standard RISC-V gp-relative-addressing anchor - some small data
     * may be addressed relative to `gp` rather than absolutely; this
     * needs to land within +/-2KB of wherever the compiler actually put
     * that data, hence anchoring it at the data/bss boundary rather than
     * an arbitrary fixed address. */
    PROVIDE(__global_pointer$ = _bss_start + 0x800);

    /* Stack grows down from the top of RAM. */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
