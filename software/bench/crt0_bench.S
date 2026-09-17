/* Startup for benchmark images.
 *
 * The testbench resets the hart straight to this address (RESET_PC matches
 * link_bench.ld's ORIGIN), so this is the first instruction executed - there
 * is no boot ROM in the picture. The dual-hart harness (Phase 15 Stage 5,
 * link_bench_hart0.ld/link_bench_hart1.ld) reuses this file unchanged: there
 * RESET_PC points at coremark_dispatch.S instead, which jumps each hart
 * straight to its own copy of this same _start - this file only ever
 * references linker-provided symbols (__global_pointer$, _stack_top,
 * _bss_start/_bss_end), never a hardcoded address, so it needs no hart
 * awareness of its own.
 *
 * .bss is NOLOAD, so it is not carried in the image and has to be zeroed
 * here. CoreMark's results array lives there, and starting it with whatever
 * the memory array happened to hold would corrupt the CRCs it validates
 * itself against.
 */
.section .text.start
.global _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    la sp, _stack_top

    la a0, _bss_start
    la a1, _bss_end
1:
    bge a0, a1, 2f
    sw zero, 0(a0)
    addi a0, a0, 4
    j 1b
2:
    call main

    /* CoreMark's main returns. Spin rather than falling into whatever bytes
     * follow - the testbench decides when the run is over, from the console
     * output, and needs the hart to still be alive and quiet until then. */
halt:
    j halt
