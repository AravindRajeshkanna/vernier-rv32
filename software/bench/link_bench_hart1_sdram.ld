/* Hart 1's CoreMark image linked into SDRAM instead of block RAM (Phase 8
 * Stage 3): hart 0 runs from block RAM, hart 1 from external SDRAM, so the
 * two harts' instruction and data traffic goes to two different memories.
 * Otherwise identical to link_bench_hart1.ld, below (whose header gives the
 * reasons each hart needs its own complete link). Loaded into the SDRAM model
 * by sim/tb_soc_2hart_coremark_split.v; coremark_dispatch_split.S sends hart 1
 * here. */
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
    RAM (rwx) : ORIGIN = 0x90000000, LENGTH = 256K
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

    /* Top of the 256 KB of SDRAM this image has. */
    _stack_top = 0x90040000;

    PROVIDE(_coremark_expected_hartid = 1);
}

ASSERT(_end <= 0x90040000,
       "hart 1's coremark image grew past the 256 KB it has in SDRAM")
