/* PMP enforcement, wired to a real access path for the first time.
 *
 * rtl/pmp.v's address-matching logic already has its own tests
 * (sim/tb_pmp.v, formal/fv_pmp.v) and riscv-tests' own rv32mi-p-pmpaddr
 * proves pmpcfg0-3/pmpaddr0-15 store and read back correctly - but neither
 * proves a real S-mode load, store, or fetch actually reaches the module
 * and takes a real trap. Nothing did, before this. That is the one thing
 * this program exists to check, and it does it the same way trapcheck.c
 * already proves the loud trap handler works: provoke the real thing on
 * purpose and score the run on whether the machine's own record of what
 * happened matches what was configured to happen.
 *
 * No MMU, no SDRAM - PMP checks the physical address directly, and a
 * physical-only program keeps the failure attributable to PMP specifically
 * rather than to Sv32 (already covered, at length, by mmutest.c).
 *
 * ---- What's configured ----
 *
 *   entry 0: NA4, 4 bytes at &wdeny_word, R=1 W=0 X=0 - store-denied,
 *            still readable, so the "did the store actually reach memory"
 *            check below is itself a legal access under this same config
 *   entry 1: NA4, 4 bytes at &rdeny_word, R=0 W=0 X=0 - fully closed
 *   entry 2: NA4, 4 bytes at &denied_code[0], R=1 W=1 X=0 - execute-denied,
 *            still readable/writable, so only the fetch itself is checked
 *   entry 3: NAPOT, the entire 32-bit space, R=W=X=1
 *
 * Priority is index order - entries 0-2 are checked before entry 3, so
 * their narrower regions win for the three words/instructions they cover,
 * and everything else (S-mode's own stack, the rest of its code, and
 * every other byte of RAM) falls through to entry 3. Entry 2 has to sit
 * *before* the catch-all for the same reason 0 and 1 do: PMP matching
 * stops at the first entry that matches, so a narrower, higher-priority
 * region has to have the lower index or the catch-all shadows it
 * completely. All four unlocked, so M-mode - trap_install(), trap_arm(),
 * and the handler in crt0_ram.S - is untouched by any of this; only the
 * S-mode accesses below are actually checked.
 *
 * An earlier version of this file used one fully-closed region for both the
 * load and store checks, including a same-region readback to prove a
 * denied store never reached memory - which is itself a denied read under
 * a fully-closed region, and produced a second, unarmed trap the test did
 * not expect. Splitting store-denial (readable) from load-denial (closed)
 * is the fix, found by hitting that exact failure rather than reasoned
 * out in advance.
 *
 * No libc - see software/soc/main.c's header for the incident that settled
 * that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

static int failures = 0;

static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 40);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

/* Three words this program owns, each a target for one part of the test -
 * not stack locals, so their addresses are stable across the mret and
 * don't depend on where S-mode's own stack pointer lands. All three get
 * their value from the program image at load time, not a runtime store:
 * once PMP is configured, a plain unarmed C assignment to `wdeny_word` or
 * `rdeny_word` would itself be a second, unintended denied access. */
static volatile uint32_t wdeny_word = 0x11111111u;
static volatile uint32_t rdeny_word = 0x22222222u;
static volatile uint32_t allow_word = 0xA5A5A5A5u;

/* The target of the fetch-denial check - hand-encoded, the same technique
 * software/soc/main.c's test_fence_i() already uses to build an
 * instruction in RAM, and for the same reason here: precise control over
 * exactly what is at each address, rather than trusting where a compiled
 * C function's first instruction happens to land.
 *
 * Word 0 (`addi a0, zero, 1`) is the denied instruction - it sits alone in
 * its own NA4 region below, so denying it denies exactly one fetch.
 * Word 1 (`ret`) is not denied - it falls through to the catch-all region
 * - and it matters that it is a *clean return*, not "the rest of some
 * real function": `trap_arm`'s shared handler resumes every armed trap at
 * `mepc+4`, which is correct for a denied load/store (mepc is the load/
 * store instruction itself, and the next instruction is wherever the
 * caller's own code continues) but would land *inside* a denied function's
 * body for a denied fetch - mepc is the callee's own first word, not the
 * call site. Landing on `ret` instead of the middle of real code with
 * whatever registers a real prologue expected already set up is what
 * keeps a correctly-denied fetch safe to resume from at all. */
static volatile uint32_t denied_code[2];

static void build_denied_code(void)
{
    denied_code[0] = 0x00100513u; /* addi a0, zero, 1 */
    denied_code[1] = 0x00008067u; /* jalr zero, 0(ra) == ret */
    __asm__ volatile ("fence.i" ::: "memory");
}

#define PMPCFG_A_NA4    (2u << 3)
#define PMPCFG_A_NAPOT  (3u << 3)
#define PMPCFG_R        (1u << 0)
#define PMPCFG_W        (1u << 1)
#define PMPCFG_X        (1u << 2)

static void configure_pmp(uint32_t wdeny_addr, uint32_t rdeny_addr, uint32_t xdeny_addr)
{
    uint32_t addr0 = wdeny_addr >> 2;   /* NA4: 4 bytes at wdeny_addr */
    uint32_t addr1 = rdeny_addr >> 2;   /* NA4: 4 bytes at rdeny_addr */
    uint32_t addr2 = xdeny_addr >> 2;   /* NA4: 4 bytes at xdeny_addr */
    uint32_t addr3 = 0xFFFFFFFFu;        /* NAPOT: the whole 32-bit space */
    uint32_t cfg0  = PMPCFG_A_NA4 | PMPCFG_R;              /* R only */
    uint32_t cfg1  = PMPCFG_A_NA4;                          /* none */
    uint32_t cfg2  = PMPCFG_A_NA4 | PMPCFG_R | PMPCFG_W;   /* R+W, no X */
    uint32_t cfg3  = PMPCFG_A_NAPOT | PMPCFG_R | PMPCFG_W | PMPCFG_X;
    uint32_t cfgword = cfg0 | (cfg1 << 8) | (cfg2 << 16) | (cfg3 << 24);

    /* Address before mode, matching riscv-tests' own INIT_PMP convention -
     * harmless either way here since none of these four start locked, but
     * there is no reason to diverge from the pattern the ISA suite itself
     * uses. */
    __asm__ volatile ("csrw pmpaddr0, %0" :: "r"(addr0));
    __asm__ volatile ("csrw pmpaddr1, %0" :: "r"(addr1));
    __asm__ volatile ("csrw pmpaddr2, %0" :: "r"(addr2));
    __asm__ volatile ("csrw pmpaddr3, %0" :: "r"(addr3));
    __asm__ volatile ("csrw pmpcfg0, %0"  :: "r"(cfgword));
}

static void s_mode_main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    uint32_t wdeny_addr = (uint32_t)(uintptr_t)&wdeny_word;
    uint32_t rdeny_addr = (uint32_t)(uintptr_t)&rdeny_word;
    uint32_t allow_addr = (uint32_t)(uintptr_t)&allow_word;
#ifndef CORE_OOO
    uint32_t xdeny_addr = (uint32_t)(uintptr_t)&denied_code[0];
#endif
    uint32_t dummy;

    put_str("  reached S-mode\n\n");

    /* ---- 1. a denied load takes a real load access fault (cause 5) ---- */
    trap_arm(1);
    __asm__ volatile ("lw %0, 0(%1)" : "=r"(dummy) : "r"(rdeny_addr) : "memory");
    report("denied load: exactly one trap",  TRAP_COUNT == 1);
    report("denied load: cause 5 (load access fault)", TRAP_MCAUSE == 5);
    report("denied load: mtval is the faulting address", TRAP_MTVAL == rdeny_addr);

    /* ---- 2. a denied store takes a real store access fault (cause 7),
     *         and - the point of it - never reaches memory. `wdeny_word`
     *         stays readable under entry 0's R=1/W=0, so the readback
     *         below is a legal access, not a second denied one. */
    trap_arm(1);
    __asm__ volatile ("sw %0, 0(%1)" :: "r"(0xDEADBEEFu), "r"(wdeny_addr) : "memory");
    report("denied store: exactly one trap", TRAP_COUNT == 2);
    report("denied store: cause 7 (store access fault)", TRAP_MCAUSE == 7);
    report("denied store: memory unchanged", wdeny_word == 0x11111111u);

    /* ---- 3. a denied fetch takes a real instruction access fault
     *         (cause 1), and - the point of it - never executes.
     *         `denied_code[0]`'s sentinel is seeded into `a0` explicitly
     *         via a register-pinned variable, not assumed to start at any
     *         particular value: if the fetch is genuinely denied, control
     *         resumes directly at `denied_code[1]` (`ret`) without ever
     *         touching `a0`, so the sentinel survives unchanged. If PMP
     *         failed to deny it, `denied_code[0]` (`addi a0, zero, 1`)
     *         would run first and overwrite it before the same `ret`.
     *
     *         CORE_OOO only enforces PMP on its data path so far
     *         (docs/roadmap.md's PMP entry) - fetch-side enforcement is
     *         CORE=inorder only this round, a real and currently-permanent
     *         asymmetry between the two cores, not something to paper
     *         over by skipping this test silently. Stated in the output
     *         either way, so a CORE_OOO run's shorter check list reads as
     *         a documented gap rather than four checks that quietly
     *         stopped existing. */
#ifndef CORE_OOO
    trap_arm(1);
    {
        register uint32_t a0_reg asm("a0") = 0xDEADBEEFu;
        uint32_t ran_result;
        __asm__ volatile ("jalr ra, 0(%1)"
                          : "+r"(a0_reg) : "r"(xdeny_addr) : "ra", "memory");
        /* Captured into an ordinary variable immediately, before any of the
         * report() calls below get a chance to clobber a0 for their own
         * arguments: a0 is caller-saved, and a register variable pinned to
         * one is not guaranteed to survive a function call in between, only
         * a genuine local is. */
        ran_result = a0_reg;
        report("denied fetch: exactly one trap", TRAP_COUNT == 3);
        report("denied fetch: cause 1 (instruction access fault)", TRAP_MCAUSE == 1);
        report("denied fetch: mtval is the faulting address", TRAP_MTVAL == xdeny_addr);
        report("denied fetch: instruction never ran", ran_result == 0xDEADBEEFu);
    }
#else
    put_str("  denied fetch: skipped - CORE_OOO has no fetch-side PMP yet\n");
#endif

    /* ---- 4. the open region still works normally - no trap armed, so an
     *         unexpected fault here is caught by crt0_ram.S's own loud,
     *         unarmed-trap handler, not by anything in this file */
    dummy = 0;
    __asm__ volatile ("lw %0, 0(%1)" : "=r"(dummy) : "r"(allow_addr) : "memory");
    report("open region: load reads the real value", dummy == 0xA5A5A5A5u);

    __asm__ volatile ("sw %0, 0(%1)" :: "r"(0x5A5A5A5Au), "r"(allow_addr) : "memory");
    report("open region: store took effect", allow_word == 0x5A5A5A5Au);

    put_str("\n");
    if (failures == 0) {
        put_str("PMP-TEST: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("PMP-TEST: FAIL (");
        put_dec(failures);
        put_str(")\n");
        *result = TEST_RESULT_FAIL;
    }
    for (;;) { }
}

int main(void)
{
    trap_install();

    put_str("\n=== PMP: a denied S-mode access takes a real access fault ===\n\n");

    build_denied_code();
    configure_pmp((uint32_t)(uintptr_t)&wdeny_word,
                  (uint32_t)(uintptr_t)&rdeny_word,
                  (uint32_t)(uintptr_t)&denied_code[0]);

    /* mstatus.MPP = 01 (S), mepc = s_mode_main, mret - same transition
     * mmutest.c/plictest.c already use. */
    __asm__ volatile(
        "li   t0, 3 << 11\n"
        "csrc mstatus, t0\n"
        "li   t0, 1 << 11\n"
        "csrs mstatus, t0\n"
        "csrw mepc, %0\n"
        "mret\n"
        :: "r"(s_mode_main) : "t0");

    /* mret does not return. */
    for (;;) { }
    return 0;
}
