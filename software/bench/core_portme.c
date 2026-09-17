/* CoreMark platform hooks for this SoC. See core_portme.h for the choices. */
#include "coremark.h"
#include "core_portme.h"

#include <stdint.h>
#include <stdio.h>

#ifdef COREMARK_DUAL_HART
/* Phase 15 Stage 5: two harts each run their own, completely independent
 * link of this exact source file (link_bench_hart0.ld / link_bench_hart1.ld
 * - see either one's own header for why a single shared link can't work),
 * so every ordinary global above (seed*_volatile, start_ticks, total_ticks)
 * already lives at a different physical address per hart - no per-hart
 * indexing needed there. The one thing that IS genuinely shared hardware is
 * rtl/uart.v: one instance, not one per hart. CoreMark's own core_main.c
 * calls ee_printf at several points, unmodifiably (software/bench/
 * fetch-coremark.sh: the benchmark's own five source files are used
 * unmodified) - two harts printing concurrently with no coordination would
 * interleave their UART_THR writes byte-by-byte and corrupt both harts' own
 * output, breaking the exact-substring verdict detection every CoreMark
 * testbench in this repo relies on.
 *
 * These addresses must agree exactly with coremark_dispatch.S's own layout
 * comment and sim/tb_soc_2hart_coremark.v's own copies - a duplicated
 * constant across three files, per docs/practices.md section 11. */
#define COREMARK_LOCK_ADDR    0x80000100u
#define COREMARK_RESULT0_ADDR 0x80000104u
#define COREMARK_RESULT1_ADDR 0x80000108u

/* Same scoping trick software/soc/main.c's own ASM_ATOMIC macro uses:
 * COREMARK_CFLAGS carries -march=rv32im_zicsr_zifencei (no 'a'), because
 * this toolchain ships no rv32ima multilib - asking for one globally makes
 * the linker fall back to a 64-bit libc and fail. The CPU implements A
 * regardless of what the libc was built for; only the assembler needs
 * convincing, scoped to just these instructions. */
#define ASM_ATOMIC(insn) ".option push\n.option arch, +a\n" insn "\n.option pop"

static inline uint32_t
coremark_hart_id(void)
{
    uint32_t id;
    __asm__ volatile("csrr %0, mhartid" : "=r"(id));
    return id;
}

/* Test-and-set spinlock, amoswap.w-based. No fairness requirement: each
 * hart acquires exactly once, ever, in stop_time() below, to make its own
 * final report atomic relative to the other's - a plain amoswap loop is
 * sufficient, no LR/SC retry-on-fail logic needed. */
static inline void
coremark_lock_acquire(void)
{
    volatile uint32_t *lock = (volatile uint32_t *)COREMARK_LOCK_ADDR;
    uint32_t got;
    do {
        __asm__ volatile (ASM_ATOMIC("amoswap.w %0, %2, (%1)")
                          : "=r"(got) : "r"(lock), "r"(1u) : "memory");
    } while (got != 0);
}

static inline void
coremark_lock_release(void)
{
    volatile uint32_t *lock = (volatile uint32_t *)COREMARK_LOCK_ADDR;
    __asm__ volatile (ASM_ATOMIC("amoswap.w zero, zero, (%0)")
                      :: "r"(lock) : "memory");
}
#endif /* COREMARK_DUAL_HART */

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* The hart's own retired-cycle counter. This is the same register the ISA
 * test suite checks (rv32mi-p-zicntr) and the same one the SoC acceptance
 * test compares against the CLINT, so a wrong number here would already have
 * been caught elsewhere - which is what makes it trustworthy as a timer. */
static inline ee_u32 read_cycle(void)
{
    ee_u32 v;
    __asm__ volatile("csrr %0, cycle" : "=r"(v));
    return v;
}

static CORE_TICKS start_ticks, total_ticks;

void
start_time(void)
{
    start_ticks = read_cycle();
}

void
stop_time(void)
{
    total_ticks = read_cycle() - start_ticks;

#ifdef COREMARK_DUAL_HART
    /* sim/tb_soc_2hart_coremark.v reads this word directly rather than
     * parsing the exact cycle count out of the UART report text - the same
     * RAM-resident-sentinel pattern sim/tb_ramboot_2hart.v already uses.
     * Each hart writes only its own word, so this needs no lock.
     *
     * The lock below is acquired here, after the timed region above has
     * already finished, specifically so the actual measurement stays
     * completely lock-free and uncontended - only the *reporting* that
     * follows (core_main.c's own ~15 ee_printf calls, unmodifiable) needs
     * to be serialized against the other hart's own report. Released in
     * portable_fini(), the last portme call core_main.c makes - confirmed
     * by direct reading, nothing else calls into this file between
     * stop_time() and portable_fini(). */
    volatile uint32_t *result = (volatile uint32_t *)
        (coremark_hart_id() == 0 ? COREMARK_RESULT0_ADDR : COREMARK_RESULT1_ADDR);
    *result = total_ticks;

    coremark_lock_acquire();
#endif
}

CORE_TICKS
get_time(void)
{
    return total_ticks;
}

/* CoreMark divides the tick count by this to report seconds. Reporting
 * cycles directly (divider of 1) is the truthful thing to do in simulation:
 * there is no wall clock, and inventing one by dividing by an assumed clock
 * frequency would turn a hard number into a guess. Read every "secs" field
 * in the output below as "cycles". */
ee_u32 default_num_contexts = 1;

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks;
}

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a "
                  "pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");

#ifdef COREMARK_DUAL_HART
    /* A real, mechanical proof that coremark_dispatch.S actually sent this
     * hart to *its own* independently-linked image - not just that mhartid
     * itself reads correctly, which it would regardless of which image
     * ended up executing. _coremark_expected_hartid is a linker-provided
     * symbol (link_bench_hart0.ld/link_bench_hart1.ld), baked into this
     * specific build at link time; comparing it against a live mhartid read
     * here is the same "hard proof, not a plausible-looking pass" standard
     * sim/tb_soc_2hart.v's own rob_count check already sets for Phase 15. */
    extern const char _coremark_expected_hartid[];
    if (coremark_hart_id() != (uint32_t)(uintptr_t)_coremark_expected_hartid)
        ee_printf("ERROR! hart %u is running the image linked for hart %u - "
                  "coremark_dispatch.S sent it to the wrong address!\n",
                  (unsigned)coremark_hart_id(),
                  (unsigned)(uintptr_t)_coremark_expected_hartid);
#endif

    p->portable_id = 1;
}

/* CoreMark decides validity itself, by recomputing CRCs over its own results
 * and printing "Correct operation validated" or "Errors detected". That
 * verdict lives in a local inside core_main and is not reachable from here,
 * so sim/tb_bench.v watches the UART byte stream for it instead. Matching on
 * the benchmark's own statement is better than inventing a second one: it
 * cannot drift out of step with what CoreMark actually concluded. */
void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
#ifdef COREMARK_DUAL_HART
    coremark_lock_release();
#endif
}
