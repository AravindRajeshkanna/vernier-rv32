/* `__div64_32`, isolated - the exact routine `sim_linux CORE=ooo` was found
 * stuck inside, run standalone against known-correct answers, in three
 * phases of increasing fidelity to how Linux actually reaches it.
 *
 * docs/roadmap.md's "Stage 1d was built anyway" section ("Update 3" through
 * "Update 5") has the full trail: bisecting `sim_linux CORE=ooo` on
 * `+maxcycles` and widening `sim/verilator_soc.cpp`'s control-flow-transfer
 * ring found the boot permanently stuck inside `lib/math/div64.c`'s
 * `__div64_32` - reached from the CFS/EEVDF scheduler's own vruntime
 * accounting (`dequeue_task_fair` -> ... -> `div_s64_rem`) during a task
 * switch, and never returning. `CORE=inorder`, identical kernel image, does
 * not get stuck there.
 *
 * `__div64_32`'s core loop is provably bounded - `d` is produced by doubling
 * a 64-bit value and then only ever right-shifted, so it must reach zero
 * within 64 iterations regardless of the operands - which makes "it doesn't
 * terminate" a claim about the CPU, not about the kernel's C code. This file
 * is the direct way to ask that question without a 90-million-cycle Linux
 * boot in the way: the exact function, copied verbatim from
 * `lib/math/div64.c` (comment included, for anyone diffing it against a
 * newer kernel), called with a spread of operands - including several
 * shaped like real vruntime/deadline deltas (nanosecond-scale dividends
 * against small integer weights) - checked against answers computed on the
 * host, not on this target, so a shared bug in the reference and the thing
 * under test cannot cancel out; then the same cases again with a machine
 * timer interrupt landing mid-loop (phase 2); then again with the timer
 * delegated through to S-mode the way OpenSBI actually does it, `mideleg`
 * and an `ecall` round trip included (phase 3), since that cross-privilege
 * bookkeeping is its own mechanism and this project has had a bug in
 * exactly that shape before (PR #52's `mip.SEIP`).
 *
 * All three phases pass on both cores as this file stands. That is real,
 * useful information, not a dead end: it rules out the routine's arithmetic
 * being data-independently wrong, and rules out both "an interrupt lands
 * mid-loop" and "the real cross-privilege delegation sequence happens
 * mid-loop" as sufficient on their own. What is left and not yet
 * reproduced here: the register pressure and live values
 * `dequeue_task_fair`'s own call chain puts around this exact call, which
 * calling the function fresh from a shallow stack cannot recreate, or a
 * specific micro-architectural timing window neither phase 2 nor phase 3
 * happened to land on.
 *
 * No libc - see software/soc/main.c's header for why.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

/* ---- verbatim from linux-6.18.45's lib/math/div64.c ----------------------
 *
 * Copied rather than linked against the real kernel build: this program is
 * freestanding and RAM-resident (software/soc/link_ram.ld), not a Linux
 * build artifact, and the point is to isolate the routine, not to relink
 * the kernel. Not touched beyond the type spellings (`uint64_t`/`uint32_t`
 * for `u64`/`u32`, `int64_t` for `s64`) needed outside kernel headers.
 */
static uint32_t div64_32(uint64_t *n, uint32_t base)
{
    uint64_t rem = *n;
    uint64_t b = base;
    uint64_t res, d = 1;
    uint32_t high = rem >> 32;

    /* Reduce the thing a bit first */
    res = 0;
    if (high >= base) {
        high /= base;
        res = (uint64_t) high << 32;
        rem -= (uint64_t) (high*base) << 32;
    }

    while ((int64_t)b > 0 && b < rem) {
        b = b+b;
        d = d+d;
    }

    do {
        if (rem >= b) {
            rem -= b;
            res += d;
        }
        b >>= 1;
        d >>= 1;
    } while (d);

    *n = res;
    return rem;
}

/* Dividend, divisor, expected quotient, expected remainder - all computed on
 * the host (Python's arbitrary-precision `//`/`%`), not on this target, so a
 * bug shared between this file's C and the target's compiled code cannot
 * make a wrong answer look right. A comment above each row says what it is
 * shaped like; the two 32-bit-boundary and two degenerate (dividend 0,
 * dividend < divisor) cases exist because `div64_32`'s own `if (high >=
 * base)` fast path and its main loop are different code, and both need
 * covering, not just the shape a real vruntime division happens to take. */
struct case_t {
    uint64_t dividend;
    uint32_t divisor;
    uint64_t want_q;
    uint32_t want_r;
    const char *note;
};

static const struct case_t cases[] = {
    /* ~1000s of ns / NICE_0_LOAD (1024) - an ordinary vruntime-style divide */
    { 0x000000E8D4A51000ULL, 0x00000400u, 0x000000003A352944ULL, 0x00000000u,
      "1e12 ns / 1024" },
    /* ~1e18 ns / 1e9 - a big dividend, mid-size divisor */
    { 0x0DE0B6B3A763FFFFULL, 0x3B9ACA00u, 0x000000003B9AC9FFULL, 0x3B9AC9FFu,
      "large / 1e9" },
    /* max 64-bit dividend, small divisor - most main-loop iterations */
    { 0xFFFFFFFFFFFFFFFFULL, 0x00000003u, 0x5555555555555555ULL, 0x00000000u,
      "UINT64_MAX / 3" },
    { 0xFFFFFFFFFFFFFFFFULL, 0x00000001u, 0xFFFFFFFFFFFFFFFFULL, 0x00000000u,
      "UINT64_MAX / 1" },
    /* degenerate: dividend 0, and dividend < divisor (skips the main loop's
     * subtract entirely on the first and only meaningful comparison) */
    { 0x0000000000000000ULL, 0x00003039u, 0x0000000000000000ULL, 0x00000000u,
      "0 / 12345" },
    { 0x0000000000000002ULL, 0x3B9ACA00u, 0x0000000000000000ULL, 0x00000002u,
      "2 / 1e9 (dividend < divisor)" },
    /* right at the 32-bit boundary, both sides of it */
    { 0x0000000100000000ULL, 0x00000002u, 0x0000000080000000ULL, 0x00000000u,
      "2^32 / 2" },
    { 0x00000000FFFFFFFFULL, 0xFFFFFFFFu, 0x0000000000000001ULL, 0x00000000u,
      "(2^32-1) / (2^32-1)" },
    /* takes the `if (high >= base)` fast-reduction path */
    { 0x00000B3A73CE2FF2ULL, 0x00000007u, 0x0000019AA2D44FFEULL, 0x00000000u,
      "high >= base path" },
    /* high bit set, small divisor */
    { 0x8000000000000000ULL, 0x00000003u, 0x2AAAAAAAAAAAAAAAULL, 0x00000002u,
      "high bit set / 3" },
    /* odd/arbitrary operands, no special structure */
    { 0x123456789ABCDEF0ULL, 0x9E3779B1u, 0x000000001D7495BFULL, 0x14510EE1u,
      "arbitrary operands" },
    { 0x00000002540BE400ULL, 0x00000499u, 0x000000000081A430ULL, 0x00000350u,
      "1e10 / 1177" },
    /* a day in ns / a millisecond - both scheduler-realistic and a clean
     * divisor relationship */
    { 0x00004E94914F0000ULL, 0x000003E8u, 0x000000141DD76000ULL, 0x00000000u,
      "86400s in ns / 1ms" },
    /* five seconds in ns / one second in ns - dividend a small multiple of
     * the divisor, few main-loop iterations */
    { 0x000000012A05F200ULL, 0x3B9ACA00u, 0x0000000000000005ULL, 0x00000000u,
      "5e9 / 1e9" },
};

#define N_CASES ((int)(sizeof(cases) / sizeof(cases[0])))

/* failures is file-scope, not local to main(), because phase 3 (below) runs
 * in S-mode, entered by a one-way `mret` main() never returns from - it has
 * to be the one that does the final PASS/FAIL report, and needs phases 1
 * and 2's tally to do it. */
static int failures = 0;

/* ---- phase 2: the same cases, with the machine timer interrupt live -----
 *
 * Phase 1 alone passing does not clear CORE=ooo: `sim_linux` found this loop
 * stuck while reached *from* a timer-tick-driven reschedule, and a
 * quiescent bare-metal loop with interrupts off cannot put the core in that
 * state - if the defect needs a trap landing mid-sequence in this specific,
 * densely register-dependent code (a pipeline flush/recovery corrupting one
 * of the many live values `div64_32`'s hand-scheduled loop carries between
 * instructions), only an actual interrupt arriving during it will show it.
 *
 * The interval is short and not a multiple of the loop's own length on
 * purpose, so successive calls catch the interrupt at a different point in
 * the instruction stream each time rather than always the same one -
 * walking the phase rather than fixing it.
 */
#define TIMER_INTERVAL   97u    /* cycles; short and coprime-ish with the loop */
#define STRESS_ROUNDS    400    /* * N_CASES calls, each with a live timer */

/* Phase 3's own interval, longer than phase 2's: an M-mode-only handler
 * (timer_isr, above) is two CSR writes and a return, comfortably inside 97
 * cycles on either core. Phase 3's chain is M-entry -> set STIP -> mret ->
 * S-entry -> ecall -> M-entry -> clear STIP -> mret -> S-resume -> sret -
 * four privilege-mode round trips, and 97 cycles is not always enough to
 * get all the way through it before the *next* interrupt is already due.
 * When that race is lost the timer never stops re-firing faster than the
 * handling can finish, no forward progress into the interrupted code ever
 * happens, and the run times out - which is what the first attempt at this
 * did, and it did it on CORE=inorder too, which is what said "this is the
 * test's own arithmetic, not a CPU defect" rather than something to chase
 * into the RTL. */
#define S_TIMER_INTERVAL 4000u

/* Phase 3's own round count, smaller than phase 2's: each delegated
 * interrupt costs four privilege-mode transitions instead of one direct
 * M-mode return, and sim/tb_ramboot.v's watchdog is a fixed wall of
 * simulated time, not a cycle count - 400 rounds here does not time out
 * because anything hangs, it times out because Icarus does not simulate
 * that many round trips fast enough to finish inside the budget. 20 rounds
 * (65 delegated interrupts, confirmed against CORE=inorder while narrowing
 * this down) proved the mechanism works at all; this is enough rounds to
 * walk the interrupt across meaningfully different points in the loop
 * without spending the whole watchdog budget getting there. */
#define STRESS_ROUNDS_P3 60

static volatile uint32_t *const mtimecmp_lo =
    (volatile uint32_t *)(uintptr_t)(CLINT_BASE + 0x4000u);
/* rtl/clint.v resets mtimecmp's high word to 0xFFFFFFFF (its whole 64-bit
 * reset value is "far future", so nothing fires right after reset) - which
 * this test's run is nowhere near long enough to reach on its own, so the
 * high word has to be brought down to 0 once, or mtip never asserts no
 * matter what the low word says. */
static volatile uint32_t *const mtimecmp_hi =
    (volatile uint32_t *)(uintptr_t)(CLINT_BASE + 0x4004u);
static volatile uint32_t *const mtime_lo =
    (volatile uint32_t *)(uintptr_t)(CLINT_BASE + 0xBFF8u);

static volatile uint32_t timer_ticks;

static void __attribute__((interrupt("machine"))) timer_isr(void)
{
    /* Rearm relative to *now*, not the last deadline: if this handler itself
     * ever runs long relative to TIMER_INTERVAL, rearming from the missed
     * deadline would fire again immediately and this test would measure its
     * own handler latency instead of the division loop. */
    *mtimecmp_lo = *mtime_lo + TIMER_INTERVAL;
    timer_ticks++;
}

/* ---- phase 3: the same cases again, delegated to S-mode -----------------
 *
 * Phase 2 asked "does an interrupt landing mid-loop break this" and the
 * answer was no. It could not ask the more specific question: Linux runs
 * this code in S-mode, and reaches the timer tick that leads into it via
 * OpenSBI's machine-to-supervisor delegation, not a direct M-mode handler -
 * this SoC has no Sstc, confirmed by dts/soc.dts's riscv,isa string, so the
 * pre-Sstc emulation shape applies: M-mode traps the real mtip, sets a
 * software mip.STIP bit for S-mode, and S-mode - unable to clear that bit
 * itself (csr_file.v's `sip` write path reaches only SSIP, matching real
 * hardware) - asks M-mode to clear it via an `ecall`, the same shape real
 * OpenSBI's SBI TIME extension uses. That cross-privilege bookkeeping is
 * its own mechanism, not just "an interrupt happened somewhere," and it is
 * the same general category as PR #52's `mip.SEIP` bug from earlier in this
 * project - a defect in the bookkeeping around a delegated interrupt, not
 * in the interrupt's arrival.
 *
 * `mideleg` bit 5 is supervisor timer interrupt delegation; cause 7
 * (machine timer) is never delegatable and always traps to M first
 * regardless, which is why the M-mode side still exists at all.
 */
static volatile uint32_t s_timer_ticks;

static volatile uint32_t dbg_m_count, dbg_s_count, dbg_m_other;

static void __attribute__((interrupt("machine"))) m_trap_handler(void)
{
    uint32_t mcause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(mcause));

    if (mcause == 0x80000007u) {
        dbg_m_count++;
        /* the real mtip: rearm (which clears it) and hand off to S-mode */
        *mtimecmp_lo = *mtime_lo + S_TIMER_INTERVAL;
        __asm__ volatile ("csrs mip, %0" :: "r"(1u << 5));   /* set STIP */
    } else if (mcause == 0x9u) {
        /* ecall from S: S-mode asking to have STIP cleared, the one thing
         * it cannot do to itself. Skip the ecall on the way back, the same
         * as every other synchronous cause this repository's handlers step
         * over. */
        uint32_t mepc;
        dbg_s_count++;
        __asm__ volatile ("csrc mip, %0" :: "r"(1u << 5));   /* clear STIP */
        __asm__ volatile ("csrr %0, mepc" : "=r"(mepc));
        mepc += 4;
        __asm__ volatile ("csrw mepc, %0" :: "r"(mepc));
    } else {
        dbg_m_other++;
    }
    /* Anything else should not happen in this test; leaving it alone rather
     * than guessing is the honest failure mode - it will show up as a hang
     * or a wrong answer, same as the defect this file is looking for. */
}

static void __attribute__((interrupt("supervisor"))) s_trap_handler(void)
{
    s_timer_ticks++;
    __asm__ volatile ("ecall" ::: "memory");
}

static void __attribute__((noreturn)) s_mode_phase3(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    int round, s_failures = 0;

    __asm__ volatile ("csrw stvec, %0" :: "r"((uintptr_t)s_trap_handler));
    __asm__ volatile ("csrs sie, %0" :: "r"(1u << 5));       /* STIE */
    __asm__ volatile ("csrs sstatus, %0" :: "r"(1u << 1));   /* SIE */

    for (round = 0; round < STRESS_ROUNDS_P3; round++) {
        int i;
        for (i = 0; i < N_CASES; i++) {
            uint64_t n = cases[i].dividend;
            uint32_t r = div64_32(&n, cases[i].divisor);
            if (n != cases[i].want_q || r != cases[i].want_r) {
                put_str("  FAILED  round=");
                put_dec(round);
                put_str(" case=");
                put_str(cases[i].note);
                put_str(" got q=");
                put_hex((uint32_t)(n >> 32));
                put_hex((uint32_t)n);
                put_str(" r=");
                put_hex(r);
                put_str(" s_ticks_so_far=");
                put_dec((int)s_timer_ticks);
                put_str("\n");
                s_failures++;
            }
        }
    }
    __asm__ volatile ("csrc sstatus, %0" :: "r"(1u << 1));

    put_str("phase 3: ");
    put_dec((int)s_timer_ticks);
    put_str(" delegated S-mode timer interrupts, ");
    put_dec(s_failures);
    put_str(" of ");
    put_dec(STRESS_ROUNDS_P3 * N_CASES);
    put_str(" calls wrong (M-mode traps ");
    put_dec((int)dbg_m_count);
    put_str(" mtip, ");
    put_dec((int)dbg_s_count);
    put_str(" ecall, ");
    put_dec((int)dbg_m_other);
    put_str(" other)\n");
    failures += s_failures;

    put_str("\n");
    if (failures == 0) {
        put_str("DIV64-TEST: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("DIV64-TEST: FAIL (");
        put_dec(failures);
        put_str(")\n");
        *result = TEST_RESULT_FAIL;
    }

    for (;;) { }
}

int main(void)
{
    int i;

    trap_install();

    put_str("\n=== __div64_32 isolated (docs/roadmap.md 'Update 3') ===\n");
    put_dec(N_CASES);
    put_str(" cases\n");

    for (i = 0; i < N_CASES; i++) {
        uint64_t n = cases[i].dividend;
        uint32_t r;
        int ok;

        put_str("  ");
        put_pad(cases[i].note, 32);

        r = div64_32(&n, cases[i].divisor);
        ok = (n == cases[i].want_q) && (r == cases[i].want_r);

        if (ok) {
            put_str("ok\n");
        } else {
            /* put_hex prints its own "0x"; two calls back to back read as
             * the high then low 32 bits of one 64-bit value. */
            put_str("FAILED  got q=");
            put_hex((uint32_t)(n >> 32));
            put_hex((uint32_t)n);
            put_str(" r=");
            put_hex(r);
            put_str("  want q=");
            put_hex((uint32_t)(cases[i].want_q >> 32));
            put_hex((uint32_t)cases[i].want_q);
            put_str(" r=");
            put_hex(cases[i].want_r);
            put_str("\n");
            failures++;
        }
    }

    put_str("\n");
    put_str("=== phase 2: same cases, ");
    put_dec(STRESS_ROUNDS);
    put_str(" rounds, machine timer interrupt live every ");
    put_dec((int)TIMER_INTERVAL);
    put_str(" cycles ===\n");

    __asm__ volatile ("csrw mtvec, %0" :: "r"((uintptr_t)timer_isr));
    *mtimecmp_hi = 0;
    *mtimecmp_lo = *mtime_lo + TIMER_INTERVAL;
    __asm__ volatile ("csrs mie, %0" :: "r"(1u << 7));      /* MTIE */
    __asm__ volatile ("csrs mstatus, %0" :: "r"(1u << 3));  /* MIE */

    {
        int round, stress_failures = 0;
        for (round = 0; round < STRESS_ROUNDS; round++) {
            for (i = 0; i < N_CASES; i++) {
                uint64_t n = cases[i].dividend;
                uint32_t r = div64_32(&n, cases[i].divisor);
                if (n != cases[i].want_q || r != cases[i].want_r) {
                    put_str("  FAILED  round=");
                    put_dec(round);
                    put_str(" case=");
                    put_str(cases[i].note);
                    put_str(" got q=");
                    put_hex((uint32_t)(n >> 32));
                    put_hex((uint32_t)n);
                    put_str(" r=");
                    put_hex(r);
                    put_str(" ticks_so_far=");
                    put_dec((int)timer_ticks);
                    put_str("\n");
                    stress_failures++;
                    /* Keep going - one divergence caught once could be a
                     * fluke of this run's exact timing; several, and where
                     * they cluster, is worth more than the first. */
                }
            }
        }
        __asm__ volatile ("csrc mstatus, %0" :: "r"(1u << 3));
        put_str("phase 2: ");
        put_dec((int)timer_ticks);
        put_str(" timer interrupts delivered, ");
        put_dec(stress_failures);
        put_str(" of ");
        put_dec(STRESS_ROUNDS * N_CASES);
        put_str(" calls wrong\n");
        failures += stress_failures;
    }

    put_str("\n");
    put_str("=== phase 3: same cases, delegated to S-mode, timer via ");
    put_str("mideleg + ecall, every ");
    put_dec((int)S_TIMER_INTERVAL);
    put_str(" cycles ===\n");

    /* mtvec now dispatches on mcause (machine timer vs. ecall from S) rather
     * than being timer_isr alone; mideleg only takes effect once we are
     * actually below M, which the mret below arranges. */
    __asm__ volatile ("csrw mtvec, %0" :: "r"((uintptr_t)m_trap_handler));
    __asm__ volatile ("csrw mideleg, %0" :: "r"(1u << 5));
    *mtimecmp_hi = 0;
    *mtimecmp_lo = *mtime_lo + S_TIMER_INTERVAL;
    __asm__ volatile ("csrs mie, %0" :: "r"(1u << 7));      /* MTIE */

    __asm__ volatile(
        "li   t0, 3 << 11\n"
        "csrc mstatus, t0\n"
        "li   t0, 1 << 11\n"        /* MPP = 01, supervisor */
        "csrs mstatus, t0\n"
        "csrw mepc, %0\n"
        "mret\n"
        :: "r"(s_mode_phase3) : "t0");

    /* unreachable: s_mode_phase3 reports and halts */
    for (;;) { }
}
