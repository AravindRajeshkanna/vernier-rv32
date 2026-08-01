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

/* Minimal M-mode trap handler.
 *
 * Records mcause/mtval and counts entries, then skips the faulting
 * instruction and returns. Deliberately uses mscratch plus a fixed scratch
 * word rather than pushing a stack frame: the tests that trigger it are
 * checking memory behavior, and a handler that touched the stack could
 * perturb what it is meant to be observing.
 *
 * Skipping by mepc+4 is only valid because every trap this handler is
 * expected to see comes from a 4-byte instruction that should not be
 * retried (a deliberately misaligned access).
 */
.section .text
.align 4
.global trap_vector
trap_vector:
    csrw  mscratch, t0
    la    t0, trap_info
    sw    t1, 12(t0)          /* stash t1 in the scratch area */
    csrr  t1, mcause
    sw    t1, 0(t0)
    csrr  t1, mtval
    sw    t1, 4(t0)
    lw    t1, 8(t0)
    addi  t1, t1, 1
    sw    t1, 8(t0)           /* entry counter */
    csrr  t1, mepc
    addi  t1, t1, 4
    csrw  mepc, t1
    lw    t1, 12(t0)
    csrr  t0, mscratch
    mret
