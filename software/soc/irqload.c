/* Interrupt traffic over the shared bus and the router fabric (Phase 8 Stage 3, Part 31).
 *
 * Stage 3's Done-when names three workloads that decide it: concurrent multi-hart Linux, an NPU
 * DMA racing CPU traffic, and real interrupt traffic. The first two have been measured (Parts 23
 * and 25 to 28). This is the third, built from the NPU-load program (npuload.c) so that its
 * forms and its numbers sit beside Part 25's.
 *
 * A periodic interrupt, from the general-purpose timer (rtl/soc/wb_timer.v), reaches hart 0
 * through the PLIC as a machine external interrupt. The handler (irqload_trap.S) is the shortest
 * a driver could write: claim, silence the timer, complete. Its first and last device accesses
 * read the timer's counter, which the wrap that raised the interrupt reset to 0, so each reading
 * is the number of cycles since the interrupt was raised:
 *
 *   lat    until the handler's first access reached the timer: pipeline, trap entry, whatever
 *          the hart was waiting for when the interrupt came, and the request's trip to the timer
 *   done   until the interrupt had been served (claim, clear, complete, and this reading)
 *
 * Four timed phases, each measured with the cycle counter:
 *
 *   1  the CPU loop alone                      (npuload.c's phase 1: the baseline)
 *   2  the same loop, interrupted every IRQ_PERIOD cycles
 *   3  the loop with the NPU's DMA job racing  (the baseline for phase 4)
 *   4  the same, interrupted
 *
 * What the interrupts cost is what they add to a fixed piece of work: (phase 2 - phase 1) over the
 * interrupts taken, and (phase 4 - phase 3) likewise. That only means something if the phases start
 * alike, so every one of them runs the loop once, untimed, first: the caches are warm, and in 2 and 4
 * the interrupts are already flowing, when timing starts. (A first version warmed only the interrupted
 * phases and not phase 3's baseline, and its racing figures came out cheaper than its own quiet ones by
 * the cost of refilling the caches.) The first interrupt of a timed interval is left out of lat and
 * done: it may have been raised while interrupts were masked for the snapshot, so its lat is not a
 * latency. Nothing is printed inside a timed phase, so the console's own traffic stays out.
 *
 * The NPU is kept busy: its DMA job is started again, by the loop, whenever the loop finds it idle (once
 * every 256 iterations), so it races for the whole of phases 3 and 4. npuload.c ran one job, which in
 * several forms ended before the loop did.
 *
 * The forms (-DNPU_SRC_SDRAM, -DCPU_BUS_HEAVY) are npuload.c's: where the NPU's buffer lives and
 * whether the loop fits the data cache. One hart, with its data cache on: a store always reaches the
 * interconnect (the cache is write-through) and a load does only if it misses, so the handler makes
 * 13 accesses that cannot be avoided (ten stores, three device loads), and the loop makes more when
 * the handler's stores displace its words from the cache's one-word lines. The handler's stack and
 * counters are in block RAM, and its device accesses go through the peripheral bridge.
 *
 * No libc - see software/soc/main.c's header.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"
#include "irqload.h"

/* irqload.h is read by the assembler too, so it holds plain numbers; make them agree with soc.h. */
_Static_assert(IRQ_TIMER_BASE == TIMER_BASE, "irqload.h: timer base");
_Static_assert(IRQ_PLIC_CLAIM_BASE + 4u == PLIC_CLAIM(PLIC_CTX_M), "irqload.h: PLIC claim register");

#ifndef IRQ_PERIOD
#define IRQ_PERIOD 2000u
#endif

/* GPIO_OUT marks the edges of the four timed intervals for the testbench, which can count the accesses in
 * each (-DREQ_COUNT; sim/tb_ramboot.v). The writes are just outside the intervals, and do nothing
 * when no testbench is watching. */
#define MARK_START 0x00FFu

#define NPU_N      32768u
#ifdef NPU_SRC_SDRAM
#define NPU_SRC    (SDRAM_BASE + 0x100000u)
#else
#define NPU_SRC    (RAM_BASE + 0x1000u)   /* static: program text, rodata, zeros */
#endif
#ifdef CPU_BUS_HEAVY
#define CPU_WORDS  2048
#define CPU_PASSES 8
#else
#define CPU_WORDS  256
#define CPU_PASSES 64
#endif

static uint32_t buf[CPU_WORDS];

/* The handler's state: it counts, logs two samples a time, and flags a claim that was not the timer's.
 * Not static, because the assembler refers to them by name. */
volatile uint32_t irq_n;
volatile uint32_t irq_bad;
volatile uint32_t irq_log[IRQ_LOG_MAX][2];
extern void irq_vector(void);

static inline uint32_t cycles(void)
{
    uint32_t v;
    __asm__ volatile ("rdcycle %0" : "=r"(v));
    return v;
}

static inline void irq_on(void)  { __asm__ volatile ("csrs mstatus, %0" :: "r"(1u << 3) : "memory"); }
static inline void irq_off(void) { __asm__ volatile ("csrc mstatus, %0" :: "r"(1u << 3) : "memory"); }

static uint32_t cpu_work(void)
{
    uint32_t acc = 1;
    uint32_t pass, i;
    for (pass = 0; pass < CPU_PASSES; pass++)
        for (i = 0; i < CPU_WORDS; i++)
            acc += buf[i] ^ i;
    return acc;
}

static void npu_start(void)
{
    NPU_A_ADDR = NPU_SRC;
    NPU_W_ADDR = NPU_SRC;
    NPU_LEN    = NPU_N;
    NPU_CTRL   = NPU_CTRL_START_DMA;
}

static void npu_wait(void)
{
    uint32_t k;
    while (NPU_STATUS & NPU_STATUS_BUSY)
        for (k = 0; k < 256; k++) __asm__ volatile ("" ::: "memory");
}

/* The same loop, with a look at the NPU every 256 iterations and its job started again if it has
 * finished. */
static uint32_t cpu_work_npu(void)
{
    uint32_t acc = 1;
    uint32_t pass, c, i;
    for (pass = 0; pass < CPU_PASSES; pass++)
        for (c = 0; c < CPU_WORDS; c += 256) {
            if (!(NPU_STATUS & NPU_STATUS_BUSY)) npu_start();
            for (i = c; i < c + 256; i++)
                acc += buf[i] ^ i;
        }
    return acc;
}

/* The timer raises its interrupt every IRQ_PERIOD cycles; interrupts stay masked in mstatus until
 * irq_on(). */
static void irq_setup(void)
{
    TIMER_CTRL   = 0;
    TIMER_IE     = 0;
    TIMER_IP     = 1;
    TIMER_PERIOD = IRQ_PERIOD;
    TIMER_COUNT  = 0;
    irq_n        = 0;
    irq_bad      = 0;
    REG32(PLIC_PRIORITY(IRQ_TIMER_SRC))   = 1u;
    REG32(PLIC_ENABLE(PLIC_CTX_M))        = 1u << IRQ_TIMER_SRC;
    REG32(PLIC_THRESHOLD(PLIC_CTX_M))     = 0u;
    __asm__ volatile ("csrw mtvec, %0" :: "r"((uintptr_t)irq_vector));
    __asm__ volatile ("csrs mie, %0"   :: "r"(1u << 11));        /* MEIE */
    TIMER_IE     = 1;
    TIMER_CTRL   = TIMER_CTRL_EN;
}

static void irq_teardown(void)
{
    uint32_t id;
    TIMER_CTRL = 0;
    TIMER_IE   = 0;
    TIMER_IP   = 1;
    REG32(PLIC_ENABLE(PLIC_CTX_M)) = 0u;
    id = REG32(PLIC_CLAIM(PLIC_CTX_M));                /* drain one that was already pending */
    if (id) REG32(PLIC_CLAIM(PLIC_CTX_M)) = id;
    __asm__ volatile ("csrc mie, %0" :: "r"(1u << 11));
    trap_install();
}

static void sort_u32(uint32_t *a, uint32_t n)
{
    uint32_t i, j, v;
    for (i = 1; i < n; i++) {
        v = a[i];
        for (j = i; j > 0 && a[j - 1] > v; j--) a[j] = a[j - 1];
        a[j] = v;
    }
}

static void put_kv(const char *k, uint32_t v)
{
    put_char(' '); put_str(k); put_char('='); put_dec((int)v);
}

/* Phase 2 or 4. `race` keeps the NPU job running. Prints one line, "IRQ phase=...", for
 * sim/irqload_matrix.sh. Returns 0 if anything was wrong. */
static int irq_phase(const char *name, int race, uint32_t base, uint32_t cpu_expected,
                     int32_t npu_expected)
{
    static uint32_t lat[IRQ_LOG_MAX], done[IRQ_LOG_MAX];
    uint32_t t0, el, n, i, cs, cs0, lat_sum = 0, done_sum = 0;
    int ok = 1;

    irq_setup();
    irq_on();
    if (race) npu_start();
    cs0 = race ? cpu_work_npu() : cpu_work();     /* warm-up: the loop, with the interrupts flowing */
    irq_off();
    irq_n = 0;                                    /* the log starts again here */
    if (race && !(NPU_STATUS & NPU_STATUS_BUSY)) npu_start();
    GPIO_OUT = MARK_START;
    t0 = cycles();
    irq_on();
    cs = race ? cpu_work_npu() : cpu_work();
    irq_off();
    el = cycles() - t0;
    GPIO_OUT = race ? 4u : 2u;
    n = irq_n;
    if (race) {
        npu_wait();
        if ((int32_t)NPU_RESULT != npu_expected) ok = 0;
    }
    if (irq_bad) ok = 0;
    irq_teardown();
    if (cs != cpu_expected || cs0 != cpu_expected) ok = 0;

    if (n < 12u || n > IRQ_LOG_MAX - 4u) ok = 0;
    if (n + 1u < el / IRQ_PERIOD || n > el / IRQ_PERIOD + 1u) ok = 0;   /* every period delivered */

    /* skip the first interrupt of the interval (see the header) */
    for (i = 1; i < n && ok; i++) {
        lat[i - 1]  = irq_log[i][0];
        done[i - 1] = irq_log[i][1];
        if (lat[i - 1] >= IRQ_PERIOD || done[i - 1] >= IRQ_PERIOD || done[i - 1] < lat[i - 1]) ok = 0;
        lat_sum  += lat[i - 1];
        done_sum += done[i - 1];
    }
    if (ok) {
        uint32_t m = n - 1u;
        sort_u32(lat, m);
        sort_u32(done, m);
        put_str("IRQ phase="); put_str(name);
        put_kv("period", IRQ_PERIOD); put_kv("base", base); put_kv("cycles", el); put_kv("n", n);
        put_kv("samples", m);
        put_kv("lat_sum", lat_sum);   put_kv("lat_min", lat[0]);   put_kv("lat_p50", lat[m / 2u]);
        put_kv("lat_p90", lat[(m * 9u) / 10u]);   put_kv("lat_max", lat[m - 1u]);
        put_kv("done_sum", done_sum); put_kv("done_p50", done[m / 2u]);
        put_kv("done_p90", done[(m * 9u) / 10u]); put_kv("done_max", done[m - 1u]);
        put_char('\n');
    } else {
        put_str("IRQ phase="); put_str(name); put_str(" FAILED");
        put_kv("n", n); put_kv("cycles", el); put_kv("bad", irq_bad); put_kv("cs_ok", cs == cpu_expected);
        put_kv("cs0_ok", cs0 == cpu_expected);
        put_char('\n');
    }
    return ok;
}

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    uint32_t i;
    int32_t  npu_expected = 0;
    uint32_t cpu_expected, cs;
    uint32_t t0, cpu_alone, cpu_race;
    int      ok = 1;

#ifdef NPU_SRC_SDRAM
    for (i = 0; i < NPU_N / 4; i++)
        ((volatile uint32_t *)(uintptr_t)NPU_SRC)[i] = i * 2246822519u;
#endif
    for (i = 0; i < NPU_N; i++) {
        int32_t b = ((const volatile int8_t *)(uintptr_t)NPU_SRC)[i];
        npu_expected += b * b;
    }
    for (i = 0; i < CPU_WORDS; i++)
        buf[i] = i * 2654435761u;
    cpu_expected = cpu_work();         /* the reference, untimed */

    put_str("\n=== Interrupt traffic (Phase 8 Stage 3, Part 31) ===\n");
    /* soc.h's register macros are not constant expressions, so irqload.h's offsets are checked here */
    if ((uintptr_t)&TIMER_COUNT != IRQ_TIMER_BASE + IRQ_TIMER_COUNT_OFF) ok = 0;
    if ((uintptr_t)&TIMER_IP    != IRQ_TIMER_BASE + IRQ_TIMER_IP_OFF)    ok = 0;

    GPIO_DIR = 0xFFFFu;
    GPIO_OUT = MARK_START;
    t0 = cycles();
    cs = cpu_work();
    cpu_alone = cycles() - t0;
    GPIO_OUT = 1;
    if (cs != cpu_expected) ok = 0;

    ok &= irq_phase("alone", 0, cpu_alone, cpu_expected, npu_expected);

    npu_start();                                   /* phase 3's warm-up, so that it starts as 2 and 4 do */
    cs = cpu_work_npu();
    npu_wait();
    if (cs != cpu_expected) ok = 0;
    npu_start();
    GPIO_OUT = MARK_START;
    t0 = cycles();
    cs = cpu_work_npu();
    cpu_race = cycles() - t0;
    GPIO_OUT = 3;
    npu_wait();
    if (cs != cpu_expected) ok = 0;
    if ((int32_t)NPU_RESULT != npu_expected) ok = 0;

    ok &= irq_phase("racing", 1, cpu_race, cpu_expected, npu_expected);

    put_str("IRQ baselines cpu_alone="); put_dec((int)cpu_alone);
    put_str(" cpu_npu_racing="); put_dec((int)cpu_race); put_char('\n');
    put_str(ok ? "IRQ-LOAD: PASS\n" : "IRQ-LOAD: FAIL\n");
    *result = ok ? TEST_RESULT_PASS : TEST_RESULT_FAIL;
    for (;;) { }
    return 0;
}
