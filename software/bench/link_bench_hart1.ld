/* Linker script for hart 1's own copy of the dual-hart CoreMark image
 * (Phase 15 Stage 5). See link_bench_hart0.ld's own header for why this
 * needs to be a completely separate link rather than a second .bss region
 * inside one shared binary.
 *
 * coremark_dispatch.S jumps every hart-1+ reset here; see that file's own
 * header for the exact instruction and why the two must agree.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80040000, LENGTH = 256K
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

    /* Top of the 512 KB RAM this harness uses (sim/tb_soc_2hart_coremark.v's
     * own RAM_BYTES(524288)). */
    _stack_top = 0x80080000;

    PROVIDE(_coremark_expected_hartid = 1);
}

ASSERT(_end <= 0x80080000,
       "hart 1's coremark image grew past the top of RAM")
