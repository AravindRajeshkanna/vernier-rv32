/* The NPU's DMA master racing the CPU for the shared bus - the load Phase 8
 * Stage 0 names and nothing else generates. software/soc/main.c's DMA tests
 * run the NPU alone; this one runs a bus-heavy CPU loop at the same time.
 *
 * Three timed phases, each ending with a GPIO_OUT write that the testbench
 * (sim/tb_ramboot.v with -DBUS_MONITOR) takes as "report and clear the bus
 * monitor":
 *
 *   1  the CPU loop alone
 *   2  one long NPU DMA job alone
 *   3  both at once: start the NPU job, run the CPU loop, then wait for the NPU
 *
 * The CPU loop re-reads a 1 KB buffer, exactly the size of the 256-word
 * direct-mapped data cache: with the cache on its loads hit and barely touch
 * the bus, with it off (sim_npuload_nodcache, which is how every build with
 * more than one hart runs) every load is a bus access. A first version swept
 * 8 KB, which misses either way and so could not tell the two apart. The NPU job is 32768 elements long, over the static
 * 32 KB of RAM that holds the program image (nothing writes there while it
 * runs), so its result can be computed in plain C beforehand and it overlaps
 * about half of the CPU loop. A first version used 2048 elements, finished in a
 * thirtieth of the loop, and measured nothing. The CPU polls the NPU only once
 * every few hundred cycles, since polling every cycle contends with the NPU
 * itself. Results are kept in variables and printed at the end, so the
 * console's own UART traffic does not land inside a measured phase. Both
 * results are checked, in all three phases, against values computed in plain C.
 *
 * No libc - see software/soc/main.c's header.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"

#define NPU_N      32768u
#ifdef NPU_SRC_SDRAM
/* The NPU's buffer in SDRAM, the CPU's code and data in block RAM: two memory
 * endpoints used at once, which is the case a network with more than one path
 * to memory exists for (Phase 8 Stage 3). The CPU fills the buffer first, so
 * every byte the job reads is defined, outside the timed phases. */
#define NPU_SRC    (SDRAM_BASE + 0x100000u)
#else
#define NPU_SRC    (RAM_BASE + 0x1000u)   /* static: program text, rodata, zeros */
#endif
#ifdef CPU_BUS_HEAVY
/* An 8 KB sweep, eight times the 256-word direct-mapped data cache: every load misses and
 * reaches the bus. Same number of loads as the default (16384), a different place to find them. */
#define CPU_WORDS  2048
#define CPU_PASSES 8
#else
#define CPU_WORDS  256
#define CPU_PASSES 64
#endif

static uint32_t buf[CPU_WORDS];

static inline uint32_t cycles(void)
{
    uint32_t v;
    __asm__ volatile ("rdcycle %0" : "=r"(v));
    return v;
}

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

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    uint32_t i;
    int32_t  npu_expected = 0;
    uint32_t cpu_expected, cs;
    uint32_t t0, cpu_alone, npu_alone, cpu_both, both_total;
    int      npu_still_busy;
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

    GPIO_DIR = 0xFFFFu;
    GPIO_OUT = 0x00FFu;                /* start measuring */

    t0 = cycles();
    cs = cpu_work();
    cpu_alone = cycles() - t0;
    GPIO_OUT = 1;
    if (cs != cpu_expected) ok = 0;

    t0 = cycles();
    npu_start();
    npu_wait();
    npu_alone = cycles() - t0;
    GPIO_OUT = 2;
    if ((int32_t)NPU_RESULT != npu_expected) ok = 0;

    t0 = cycles();
    npu_start();
    cs = cpu_work();
    cpu_both = cycles() - t0;
    npu_still_busy = (NPU_STATUS & NPU_STATUS_BUSY) != 0;
    npu_wait();
    both_total = cycles() - t0;       /* until the later of the two has finished */
    GPIO_OUT = 3;
    if (cs != cpu_expected) ok = 0;
    if ((int32_t)NPU_RESULT != npu_expected) ok = 0;

    put_str("\n=== NPU DMA racing the CPU (Phase 8 Stage 0) ===\n");
    put_str("  CPU loop alone:            "); put_dec((int)cpu_alone);  put_str(" cycles\n");
    put_str("  NPU DMA job alone:         "); put_dec((int)npu_alone);  put_str(" cycles\n");
    put_str("  CPU loop, NPU running:     "); put_dec((int)cpu_both);   put_str(" cycles\n");
    put_str("  (how long the NPU job took while the CPU ran is in the bus monitor's\n"
            "   'npu dma' row for phase 3: cycles asked, and how many it waited)\n");
    put_str("  both finished after:       "); put_dec((int)both_total); put_str(" cycles\n");
    put_str("  NPU still busy when the CPU loop ended: ");
    put_str(npu_still_busy ? "yes\n" : "no\n");

    put_str(ok ? "NPU-LOAD: PASS\n" : "NPU-LOAD: FAIL\n");
    *result = ok ? TEST_RESULT_PASS : TEST_RESULT_FAIL;
    for (;;) { }
    return 0;
}
