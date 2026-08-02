/* Linker script for the RAM program - the image the boot ROM pulls off SD.
 *
 * Everything (.text, .rodata, .data) is one contiguous run starting at
 * PROGRAM_LOAD_ADDR, because the loader copies it as a single flat blob and
 * has no idea about sections. .bss follows but is NOLOAD, zeroed at startup
 * by crt0_ram.S instead of being carried in the image.
 *
 * The origin here must match PROGRAM_LOAD_ADDR in software/soc/soc.h - the
 * loader jumps to a hardcoded address, so a mismatch would branch into the
 * middle of the image rather than its entry point.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    /* 0x8000_0000..0x8000_0FFF is reserved for the boot ROM (its stack and
     * the testbench result word), so this starts at +0x1000. */
    RAM (rwx) : ORIGIN = 0x80001000, LENGTH = 60K
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
        *(.srodata*)
    } > RAM

    .data : {
        *(.data*)
        *(.sdata*)
    } > RAM

    .bss (NOLOAD) : {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _bss_end = .;
    } > RAM

    _end = .;

    PROVIDE(__global_pointer$ = _bss_start + 0x800);

    /* Stack grows down from the top of RAM, well clear of .bss and of the
     * region the memory tests hammer (which runs to RAM_BASE+0x9000).
     *
     * 64 KB, not the 256 KB soc_top.v provides in simulation: see
     * software/soc/soc.h's RAM_SIZE for why the firmware targets the smaller
     * size. Simulation is unaffected - the firmware simply uses the low 64 KB
     * of a larger memory. */
    _stack_top = 0x80010000;
}
