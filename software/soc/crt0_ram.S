/* Startup and trap entry for the RAM program.
 *
 * The boot ROM jumps to the very first byte of the loaded image, so this
 * must be linked first - hence the dedicated `.text.start` section, matched
 * by link_ram.ld.
 *
 * Both loops below exist for the same reason: **this code can run more than
 * once over the same memory.** Block RAM is initialised when the FPGA is
 * configured, not when the CPU is reset, so pressing reset re-enters here with
 * RAM exactly as the previous run left it. Neither .bss nor .data can be
 * assumed to hold anything.
 *
 * .bss is also not carried in the image at all (it's NOLOAD), so on a first
 * run it holds whatever the loader left behind.
 */
#include "trap.h"

.section .text.start
.global _start
_start:
    .option push
    .option norelax
    la gp, __global_pointer$
    .option pop

    la sp, _stack_top

    /* Copy .data from its load image to where it runs.
     *
     * Without this the program works exactly once per FPGA configuration.
     * Everything with an initial value - newlib's reentrancy structure above
     * all - keeps whatever the previous run wrote, and the failures that
     * follows are silent and bizarre: stdout that reports errors and prints
     * nothing, because __sinit found its own "already initialised" guard still
     * set from last time. See link_ram.ld for the full account.
     *
     * Word-at-a-time; link_ram.ld aligns both ends of .data to make that
     * legal. */
    la a0, _sidata
    la a1, _sdata
    la a2, _edata
1:
    bge a1, a2, 2f
    lw a3, 0(a0)
    sw a3, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    j 1b
2:

    la a0, _bss_start
    la a1, _bss_end
3:
    bge a0, a1, 4f
    sw zero, 0(a0)
    addi a0, a0, 4
    j 3b
4:
    /* Open PMP before running anything, the same "permit all" shape real
     * firmware (OpenSBI's generic platform init) already does on its own -
     * entry 0, NAPOT, the entire 32-bit space, R+W+X, unlocked.
     *
     * Every program linked against this file now runs under real PMP
     * enforcement the moment it drops to S-mode (rtl/cpu_core.v's PMP
     * section, docs/roadmap.md's PMP entry): once any PMP hardware exists,
     * an S/U-mode access matching no entry is *denied* by default, and
     * none of software/soc/'s own test programs - mmutest.c, plictest.c,
     * uartirq.c, div64test.c - ever had a reason to configure PMP, since
     * it did not exist when they were written. Skipping this line is
     * exactly the failure `software/soc/mmutest.c` hit first: its very
     * first S-mode store took a real, unarmed access fault, because
     * nothing had opened anything for it. This is unlocked, so any
     * program that wants narrower behavior (`software/soc/pmptest.c`) is
     * free to reconfigure PMP from scratch before its own `mret` - nothing
     * here locks it out.
     *
     * Harmless for a program that never leaves M-mode: M-mode bypasses an
     * unlocked PMP entry regardless of what it says. */
    li   t0, -1
    csrw pmpaddr0, t0
    li   t0, (3 << 3) | 7    /* A=NAPOT(11), R=1 W=1 X=1 */
    csrw pmpcfg0, t0

    call main

halt:
    j halt

/* Minimal M-mode trap entry.
 *
 * Records the trap in trap_info, then takes one of two paths depending on
 * whether anyone armed it.
 *
 * **Armed** (trap_info's expect count is non-zero): consume one arming, skip
 * the faulting instruction, return. This is the path the acceptance test's
 * deliberate misaligned access takes, and skipping by mepc+4 is only valid
 * because that is a 4-byte instruction which must not be retried.
 *
 * **Unarmed**: nobody asked for this trap, so it is a defect. Hand off to
 * trap_report, which prints the record and stops the machine.
 *
 * That split is the whole point of this file. The handler used to take the
 * first path unconditionally, which made every unexpected fault - an illegal
 * instruction, a misaligned access inside library code, a jump into nothing -
 * indistinguishable from a successful test: mepc += 4, resume, corrupt
 * whatever depended on the instruction that never ran. A trap nobody expected
 * now stops the machine and says so.
 *
 * Registers: the armed path may only touch t0 (parked in mscratch) and t1
 * (parked in trap_info), because it has to return to code that owns every
 * other register - and it deliberately does not build a stack frame, since
 * the tests that provoke it are watching memory that a frame would disturb.
 * The unarmed path never returns, so it is free with registers, and it
 * switches to its own stack before calling C.
 */
.section .text
.align 4
.global trap_vector
trap_vector:
    csrw  mscratch, t0
    la    t0, trap_info
    sw    t1, TRAP_O_SCRATCH(t0)

    csrr  t1, mcause
    sw    t1, TRAP_O_MCAUSE(t0)
    csrr  t1, mtval
    sw    t1, TRAP_O_MTVAL(t0)
    csrr  t1, mepc
    sw    t1, TRAP_O_MEPC(t0)
    sw    sp, TRAP_O_SP(t0)
    sw    ra, TRAP_O_RA(t0)

    lw    t1, TRAP_O_COUNT(t0)
    addi  t1, t1, 1
    sw    t1, TRAP_O_COUNT(t0)

    lw    t1, TRAP_O_EXPECT(t0)
    beqz  t1, .Lunexpected

    /* Armed: consume one, step over the faulting instruction, resume. */
    addi  t1, t1, -1
    sw    t1, TRAP_O_EXPECT(t0)
    csrr  t1, mepc
    addi  t1, t1, 4
    csrw  mepc, t1
    lw    t1, TRAP_O_SCRATCH(t0)
    csrr  t0, mscratch
    mret

.Lunexpected:
    /* A second trap while reporting the first means the reporter itself
     * faulted, and going round again would produce an endless stream of
     * half-printed reports instead of one readable one. */
    lw    t1, TRAP_O_FATAL(t0)
    bnez  t1, .Ldouble_fault
    li    t1, 1
    sw    t1, TRAP_O_FATAL(t0)

    /* A private stack, so the report still comes out when what faulted was
     * the stack pointer itself. The original sp is already in the record. */
    la    sp, _trap_stack_top
    call  trap_report               /* does not return */

.Ldouble_fault:
    /* Last resort: one byte, straight at the UART, then stop. Anything that
     * involved a call or a memory structure could fault a third time.
     *
     * 0x04000000 is UART_BASE_A. The UART is an ns16550 with reg-shift 2, so
     * +0x14 is LSR and bit 5 is THRE ("holding register empty") - see
     * software/soc/soc.h, which cannot be included here because its register
     * macros are C. Nothing checks that these agree; the cost of them not
     * agreeing is that this prints nothing, which is the situation it already
     * exists to improve on.
     *
     * Note the polarity flipped with the register map: the old STATUS bit 0
     * was tx_*busy* and this waits for THRE to go *high*. A mechanical
     * search-and-replace that kept `bnez` would spin forever here, in the one
     * path that only runs when everything else has already failed.
     */
    li    t0, 0x04000000
1:  lw    t1, 0x14(t0)
    andi  t1, t1, 0x20
    beqz  t1, 1b
    li    t1, '!'
    sw    t1, 0(t0)
2:  j     2b
