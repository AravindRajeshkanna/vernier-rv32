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
    csrr t0, mhartid
    bnez t0, park_hart

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

/* Secondary harts (Phase 13): park here immediately, before touching gp,
 * sp or .bss - all three are shared, single-instance resources (one stack,
 * one .bss image) that only make sense for the hart that owns them, and
 * mhartid is read first so a parked hart never risks racing hart 0's own
 * use of any of them.
 *
 * Spins on a fixed RAM word (hart_release_addr, software/soc/bootrom.c)
 * that hart 0 writes once it has finished loading a program and is ready
 * to jump. Relies on that word starting at 0, which simulation's own block
 * RAM model guarantees (rtl/soc/wb_ram.v zero-fills for simulation) but
 * real silicon does not - block RAM powers up undefined there - so this is
 * a simulation-only mechanism, matching `NUM_HARTS>1` itself: no real
 * board build has ever asked for a second hart. See
 * software/soc/bootrom.c's own comment on `hart_release_addr` and
 * docs/roadmap.md's Phase 13 entry.
 */
park_hart:
    la t1, hart_release_addr
1:
    lw t2, 0(t1)
    beqz t2, 1b
    mv a0, t0     /* a0 = mhartid - the RISC-V firmware entry convention */
    li a1, 0      /* a1 = 0 - no device tree carried by this path yet */
    jr t2

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
