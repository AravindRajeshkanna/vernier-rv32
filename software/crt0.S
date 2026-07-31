/* Minimal startup code for a bare-metal newlib-nano program on this
 * core: set up the global pointer and stack, zero .bss, call main, then
 * spin forever (there's no OS to return to). Verified against this
 * exact toolchain that nothing more is required for a non-C++,
 * single-threaded program - a trial `-nostartfiles` link's only
 * unresolved symbol was `_start` itself.
 *
 * `.text.start` is a dedicated section name so the linker script can
 * place this first in ROM, at address 0 - this core's reset PC.
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
