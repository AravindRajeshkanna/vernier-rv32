/* Atomics against DDR3 - Phase 9 Stage 2 Part 7. Stage 2's own plan named
 * this explicitly: "Caches, atomics, and LR/SC get re-verified against the
 * new controller's own latency profile, not assumed unaffected." Part 2
 * proved a plain load/store round trip; nothing before this part ever
 * issued an AMO or an LR/SC pair against `rtl/soc/wb_ddr.v`.
 *
 * Mirrors software/soc/main.c's own test_amo_rmw/test_lr_sc_success/
 * test_lr_sc_failure exactly (same asm, same three cases) - the interesting
 * question isn't new atomics semantics, it's whether they survive a slave
 * whose own read and write transactions each cost far more real bus cycles
 * than RAM's. An AMO is a read-modify-write held together by the
 * interconnect's own amo_wrphase lock (rtl/soc/wb_interconnect.v), not by
 * anything DDR3-specific - if that lock has any implicit assumption about
 * how long a transaction takes, a real DDR3 write-through (up to ~80
 * cycles, four single-byte controller calls) or a real block-fill miss
 * (up to ~320 cycles, sixteen) is exactly the kind of latency that would
 * expose it, where RAM's own single-cycle response never could.
 *
 * No libc - see software/soc/main.c's own header for the incident that
 * settled that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"

#define ASM_ATOMIC(insn) ".option push\n.option arch, +a\n" insn "\n.option pop"

/* A real DDR3 physical address, distinct from every cell Part 2's own
 * ddrcheck.c touched (block 0/1) - its own block, so nothing here depends
 * on what that test left behind. */
static volatile uint32_t *const atomic_cell =
    (volatile uint32_t *)(uintptr_t)(DDR3_BASE + 0x00002000u);

static int errors = 0;
static void check(const char *what, int ok)
{
    put_str("  "); put_str(what); put_str(ok ? ": ok\n" : ": FAILED\n");
    if (!ok) errors++;
}

static int test_amo_rmw(void)
{
    uint32_t old;

    *atomic_cell = 100;

    __asm__ volatile (ASM_ATOMIC("amoadd.w %0, %2, (%1)")
                      : "=r"(old) : "r"(atomic_cell), "r"(23) : "memory");
    if (old != 100 || *atomic_cell != 123) return 0;

    __asm__ volatile (ASM_ATOMIC("amoswap.w %0, %2, (%1)")
                      : "=r"(old) : "r"(atomic_cell), "r"(999) : "memory");
    if (old != 123 || *atomic_cell != 999) return 0;

    return 1;
}

static int test_lr_sc_success(void)
{
    uint32_t old, sc_result;

    *atomic_cell = 999;

    __asm__ volatile (ASM_ATOMIC("lr.w %0, (%1)")
                      : "=r"(old) : "r"(atomic_cell) : "memory");
    __asm__ volatile (ASM_ATOMIC("sc.w %0, %2, (%1)")
                      : "=r"(sc_result) : "r"(atomic_cell), "r"(42) : "memory");

    return old == 999 && sc_result == 0 && *atomic_cell == 42;
}

static int test_lr_sc_failure(void)
{
    uint32_t old, sc_result;

    *atomic_cell = 7;

    __asm__ volatile (ASM_ATOMIC("lr.w %0, (%1)")
                      : "=r"(old) : "r"(atomic_cell) : "memory");
    *atomic_cell = 55;
    __asm__ volatile (ASM_ATOMIC("sc.w %0, %2, (%1)")
                      : "=r"(sc_result) : "r"(atomic_cell), "r"(99) : "memory");

    return old == 7 && sc_result == 1 && *atomic_cell == 55;
}

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;

    put_str("\n=== Atomics against DDR3 (Phase 9 Stage 2, Part 7) ===\n\n");

    check("AMO read-modify-write against DDR3", test_amo_rmw());
    check("LR/SC success against DDR3", test_lr_sc_success());
    check("LR/SC broken by an intervening store, against DDR3", test_lr_sc_failure());

    put_str("\n---------------------------------------------\n");
    if (errors == 0) {
        put_str("DDR3 ATOMICS TEST PASSED\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("DDR3 ATOMICS TEST FAILED\n");
        *result = TEST_RESULT_FAIL;
    }
    put_str("---------------------------------------------\n");

    for (;;) { }
    return 0;
}
