/* Linker script for hart 0's own copy of the dual-hart CoreMark image
 * (Phase 15 Stage 5). Identical in shape to link_bench.ld (the existing
 * single-hart benchmark script) - only the region and _stack_top differ,
 * placing this hart's whole program (.text/.data/.bss/stack) at a distinct
 * physical address from hart 1's own copy (link_bench_hart1.ld), which is
 * what makes running them concurrently safe: a statically-linked C binary
 * bakes fixed absolute addresses for every global into its compiled
 * instructions, so two harts executing the *same* compiled .text would
 * always reference the *same* physical .bss/stack regardless of which hart
 * ran it. Two completely separate links, not two harts sharing one, is what
 * gives each hart's own start_ticks/total_ticks/stack-resident CoreMark
 * working set a genuinely private address.
 *
 * coremark_dispatch.S jumps every hart-0 reset here; see that file's own
 * header for the exact instruction and why the two must agree.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80001000, LENGTH = 252K
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

    /* Top of this hart's own 252 KB region - link_bench_hart1.ld's own
     * ORIGIN, so the two regions are exactly adjacent with no gap and no
     * overlap. */
    _stack_top = 0x80040000;

    /* core_portme.c's portable_init() reads this back via mhartid and
     * fails loudly if they disagree - a real, mechanical proof that
     * coremark_dispatch.S actually sent this hart to *its own* image, not
     * just that mhartid itself reads correctly (which it would regardless
     * of which image ended up executing). */
    PROVIDE(_coremark_expected_hartid = 0);
}

ASSERT(_end <= 0x80040000,
       "hart 0's coremark image grew into hart 1's own region")
