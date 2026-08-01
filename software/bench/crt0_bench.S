/* Startup for benchmark images.
 *
 * The testbench resets the hart straight to this address (RESET_PC matches
 * link_bench.ld's ORIGIN), so this is the first instruction executed - there
 * is no boot ROM in the picture.
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
