/* Linker script for benchmark images.
 *
 * Unlike software/soc/link_ram.ld, this links at the very base of RAM and is
 * loaded straight into the memory array by the testbench rather than being
 * pulled off the simulated SD card by the boot ROM. That is not a shortcut
 * taken to avoid the boot path - the boot path is exercised by `make
 * sim_soc` and stays exercised. It is because shifting a ~30 KB image in
 * over bit-banged SPI costs roughly a million simulated cycles before the
 * benchmark starts, which would dominate the very number being measured.
 *
 * sim/tb_bench.v sets RESET_PC to match ORIGIN, so the hart begins executing
 * here directly with no boot ROM involved.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 256K
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

    /* CoreMark's MEM_STACK method puts its whole working set on the stack,
     * so this needs real headroom - it is the top of the 256 KB region, well
     * clear of .bss. */
    _stack_top = 0x80040000;
}
