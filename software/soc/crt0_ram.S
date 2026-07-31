/* Startup for the RAM program.
 *
 * The boot ROM jumps to the very first byte of the loaded image, so this
 * must be linked first - hence the dedicated `.text.start` section, matched
 * by link_ram.ld.
 *
 * .bss is not carried in the SD image (it's NOLOAD), so zeroing it here
 * isn't an optimization - the image would otherwise start with whatever the
 * loader happened to leave in RAM.
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

halt:
    j halt
