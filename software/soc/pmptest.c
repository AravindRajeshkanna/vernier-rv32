/* PMP enforcement, wired to a real access path for the first time.
 *
 * rtl/pmp.v's address-matching logic already has its own tests
 * (sim/tb_pmp.v, formal/fv_pmp.v) and riscv-tests' own rv32mi-p-pmpaddr
 * proves pmpcfg0-3/pmpaddr0-15 store and read back correctly - but neither
 * proves a real S-mode load or store actually reaches the module and takes
 * a real trap. Nothing did, before this. That is the one thing this
 * program exists to check, and it does it the same way trapcheck.c already
 * proves the loud trap handler works: provoke the real thing on purpose and
 * score the run on whether the machine's own record of what happened
 * matches what was configured to happen.
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
 *   entry 2: NAPOT, the entire 32-bit space, R=W=X=1
 *
 * Priority is index order - entries 0 and 1 are checked before entry 2, so
 * their narrower regions win for the two words they cover, and everything
 * else (S-mode's own stack, code, and every other byte of RAM) falls
 * through to entry 2. All three unlocked, so M-mode - trap_install(),
 * trap_arm(), and the handler in crt0_ram.S - is untouched by any of this;
 * only the S-mode accesses below are actually checked.
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

#define PMPCFG_A_NA4    (2u << 3)
#define PMPCFG_A_NAPOT  (3u << 3)
#define PMPCFG_R        (1u << 0)
#define PMPCFG_W        (1u << 1)
#define PMPCFG_X        (1u << 2)

static void configure_pmp(uint32_t wdeny_addr, uint32_t rdeny_addr)
{
    uint32_t addr0 = wdeny_addr >> 2;   /* NA4: 4 bytes at wdeny_addr */
    uint32_t addr1 = rdeny_addr >> 2;   /* NA4: 4 bytes at rdeny_addr */
    uint32_t addr2 = 0xFFFFFFFFu;        /* NAPOT: the whole 32-bit space */
    uint32_t cfg0  = PMPCFG_A_NA4 | PMPCFG_R;                       /* R only */
    uint32_t cfg1  = PMPCFG_A_NA4;                                   /* none */
    uint32_t cfg2  = PMPCFG_A_NAPOT | PMPCFG_R | PMPCFG_W | PMPCFG_X;
    uint32_t cfgword = cfg0 | (cfg1 << 8) | (cfg2 << 16);

    /* Address before mode, matching riscv-tests' own INIT_PMP convention -
     * harmless either way here since none of these three start locked, but
     * there is no reason to diverge from the pattern the ISA suite itself
     * uses. */
    __asm__ volatile ("csrw pmpaddr0, %0" :: "r"(addr0));
    __asm__ volatile ("csrw pmpaddr1, %0" :: "r"(addr1));
    __asm__ volatile ("csrw pmpaddr2, %0" :: "r"(addr2));
    __asm__ volatile ("csrw pmpcfg0, %0"  :: "r"(cfgword));
}

static void s_mode_main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    uint32_t wdeny_addr = (uint32_t)(uintptr_t)&wdeny_word;
    uint32_t rdeny_addr = (uint32_t)(uintptr_t)&rdeny_word;
    uint32_t allow_addr = (uint32_t)(uintptr_t)&allow_word;
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

    /* ---- 3. the open region still works normally - no trap armed, so an
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

    configure_pmp((uint32_t)(uintptr_t)&wdeny_word,
                  (uint32_t)(uintptr_t)&rdeny_word);

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
