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

/* Trap vector for the *loaded program*.
 *
 * The boot ROM points mtvec here before jumping, because until the program
 * installs its own handler a fault has nowhere to go: mtvec still holds its
 * reset value, so the hart jumps to address 0 and quietly restarts the boot
 * ROM - or wanders off. On a board that presents as a program that produced
 * no output, with a lit trap LED and nothing else to go on. This turns that
 * into a printed cause, PC and faulting address.
 *
 * It never returns, so nothing is saved. The stack is reset to the ROM's own
 * rather than trusting whatever the faulting program left in sp - if the
 * fault *was* a wild sp, borrowing it to report the fault would hang instead.
 */
.section .text
.align 4
.global rom_trap_vector
rom_trap_vector:
    la sp, _boot_stack_top
    call rom_trap_report
1:  j 1b
