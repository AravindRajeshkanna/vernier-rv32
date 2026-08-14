/* Does the loud trap handler actually work?
 *
 * The handler in crt0_ram.S is a diagnostic instrument: everything it is meant
 * to find, it finds by stopping the machine and printing. An instrument that
 * silently does nothing is worse than no instrument, because the next person
 * to run a program under it and see no report will conclude nothing faulted.
 * So this program provokes faults on purpose and the run is scored on whether
 * the report comes out, byte for byte.
 *
 * One fault per run, since a correct handler halts on the first one. Which
 * fault is chosen at compile time; sim/trapcheck.sh builds and runs all of
 * them and checks each report:
 *
 *   TRAPCHECK=1  a misaligned load nobody armed  -> mcause 4
 *   TRAPCHECK=2  an illegal instruction          -> mcause 2
 *   TRAPCHECK=3  the same, with sp already wild  -> the report still comes out
 *   TRAPCHECK=4  a trap *during* the report      -> one '!', and no loop
 *
 * Case 2 is the one that matters for the question this was built to answer.
 * An illegal instruction used to be handled by advancing mepc past it and
 * resuming - so a program that executed something the CPU does not implement
 * carried on with a register never written, and nothing anywhere said so.
 *
 * Case 3 is the reason crt0_ram.S switches to a private stack before calling
 * the reporter. With a wild sp, a reporter that built a stack frame on the
 * faulting code's stack would fault again inside the report; the run would end
 * with the double-fault '!' and no diagnosis. It should end with a full one.
 *
 * Case 4 is that '!' path itself, which is otherwise code nobody has ever
 * executed - and it is the code that runs when everything else has failed, so
 * "probably fine" is not good enough for it. A genuine double fault is hard to
 * arrange on purpose; setting the in-report flag by hand reaches the same
 * branch, which is what needs proving: one byte, and a halt rather than an
 * endless stream of half-written reports.
 *
 * Before any of that, this checks the *armed* path still behaves - a handler
 * that halted on everything would break the acceptance test's misaligned-access
 * check, and would pass the tests below while doing it.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

#ifndef TRAPCHECK
#define TRAPCHECK 1
#endif

int main(void) {
    uint32_t addr = RAM_BASE + 0x8101u;    /* deliberately not word-aligned */
    uint32_t dummy;

    trap_install();

    put_str("\n=== trap handler check ===\n");

    /* ---- the armed path, which must still resume ---- */
    trap_arm(1);
    __asm__ volatile ("lw %0, 0(%1)" : "=r"(dummy) : "r"(addr) : "memory");

    if (TRAP_COUNT != 1 || TRAP_EXPECT != 0 || TRAP_MCAUSE != 4) {
        put_str("  FAIL armed trap did not resume as expected\n");
        REG32(TEST_RESULT_ADDR) = TEST_RESULT_FAIL;
        for (;;) { }
    }
    put_str("  ok   an armed trap is recorded and resumed\n");

    /* ---- and now one nobody armed ---- */
    put_str("  provoking an unarmed trap, case ");
    put_dec(TRAPCHECK);
    put_str("\n");

#if TRAPCHECK == 1
    __asm__ volatile ("lw %0, 0(%1)" : "=r"(dummy) : "r"(addr) : "memory");
#elif TRAPCHECK == 2
    /* Not an encoding this machine implements, and not one it ever will:
     * all-zero is architecturally illegal. */
    __asm__ volatile (".word 0x00000000");
#elif TRAPCHECK == 3
    /* Wreck sp first. Misaligned, so any attempt to build a frame on it faults
     * again - which is the situation the reporter's private stack exists for.
     * Nothing after this can return, and nothing needs to. */
    __asm__ volatile (
        "li  sp, 0x80008001\n"
        "li  t0, 0x80008101\n"
        "lw  t0, 0(t0)\n"
        ::: "t0", "memory");
#elif TRAPCHECK == 4
    /* Publish the verdict first. The double-fault path deliberately does
     * nothing but emit one byte and stop - it cannot be trusted to touch
     * memory, which is the whole reason it exists - so nothing after this
     * point can write the result word, and without it the run would end in a
     * timeout rather than a verdict. */
    REG32(TEST_RESULT_ADDR) = TEST_RESULT_FAIL;

    /* Tell the handler a report is already in progress, then fault. This is
     * the state a genuine double fault leaves behind, reached directly. */
    trap_info[TRAP_O_FATAL / 4] = 1;
    __asm__ volatile ("lw %0, 0(%1)" : "=r"(dummy) : "r"(addr) : "memory");
#else
#error "TRAPCHECK must be 1, 2, 3 or 4"
#endif

    /* Only reachable if the handler resumed from a trap nobody armed - the
     * exact behavior this program exists to rule out. */
    put_str("  FAIL the handler resumed from an unarmed trap\n");
    REG32(TEST_RESULT_ADDR) = TEST_RESULT_FAIL;
    for (;;) { }
    return 0;
}
