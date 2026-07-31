/* Boot ROM startup. Runs from ROM at the reset vector with nothing else
 * initialized yet.
 *
 * Simpler than software/crt0.S because the boot ROM is deliberately built
 * with no .data and no .bss to speak of - but .bss is still zeroed, since
 * the compiler is free to place a zero-initialized local static there and
 * silently relying on RAM already being zero would be a trap waiting to
 * spring on real hardware (block RAM powers up undefined, unlike simulation).
 */
.section .text.start
.global _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    la sp, _boot_stack_top

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
