/* Instruction fetch from DDR3 - Phase 9 Stage 2, Part 9. Stage 2's "Done when"
 * bar is "a CPU executes real code out of the new DDR path". Every DDR3 test
 * before this one (ddrcheck.c, ddratomics.c, ddrmmutest.c) ran from block RAM
 * and only used DDR3 as data memory, so nothing had ever fetched an
 * instruction through rtl/soc/wb_ddr.v.
 *
 * Nothing loads DDR3, so this program does it itself: the functions marked
 * .ddrtext are linked to run at DDR3_BASE (.ddrtext in software/soc/link_ram.ld) and
 * carried in the RAM image; main() copies them across with ordinary stores,
 * executes fence.i, and calls them. That exercises the write path, the
 * instruction cache's fill from a 16-byte-block slave, and a taken branch,
 * a call and a return inside DDR3.
 *
 * No libc - see software/soc/main.c's header.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"

#define IN_DDR __attribute__((section(".ddrtext"), noinline))

extern uint32_t _sddrtext[], _eddrtext[], _siddrtext[];

/* Returns the pc it is executing at, so the test can check the code really
 * ran from DDR3 and not from a stale copy somewhere else. */
IN_DDR static uint32_t where_am_i(void)
{
    uint32_t pc;
    __asm__ volatile ("auipc %0, 0" : "=r"(pc));
    return pc;
}

IN_DDR static uint32_t mix(uint32_t x)
{
    return (x << 3) ^ (x >> 2) ^ 0x5bd1e995u;
}

/* A loop (taken backward branch), a nested call, and enough instructions to
 * span several 16-byte blocks. */
IN_DDR uint32_t ddr_work(uint32_t n)
{
    uint32_t acc = 1;
    for (uint32_t i = 0; i < n; i++)
        acc = mix(acc + i);
    return acc;
}

IN_DDR uint32_t ddr_pc(void)
{
    return where_am_i();
}

static uint32_t ram_mix(uint32_t x)
{
    return (x << 3) ^ (x >> 2) ^ 0x5bd1e995u;
}

static uint32_t ram_work(uint32_t n)
{
    uint32_t acc = 1;
    for (uint32_t i = 0; i < n; i++)
        acc = ram_mix(acc + i);
    return acc;
}

static int errors = 0;
static void check(const char *what, int ok)
{
    put_str("  "); put_str(what); put_str(ok ? ": ok\n" : ": FAILED\n");
    if (!ok) errors++;
}

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    volatile uint32_t *dst = (volatile uint32_t *)(uintptr_t)DDR3_BASE;

    put_str("\n=== Code fetched from DDR3 (Phase 9 Stage 2, Part 9) ===\n\n");

    for (uint32_t *s = _siddrtext, *e = _siddrtext + (_eddrtext - _sddrtext); s < e; s++)
        *dst++ = *s;
    __asm__ volatile ("fence.i" ::: "memory");

    uint32_t pc = ddr_pc();
    check("code runs at a DDR3 address", pc >= DDR3_BASE && pc < DDR3_BASE + 0x1000);
    check("loop, call and return inside DDR3, cold",  ddr_work(40) == ram_work(40));
    check("same code again, instruction cache warm",  ddr_work(40) == ram_work(40));
    check("a different trip count",                   ddr_work(7)  == ram_work(7));

    put_str("\n---------------------------------------------\n");
    if (errors == 0) {
        put_str("DDR3 EXEC TEST PASSED\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("DDR3 EXEC TEST FAILED\n");
        *result = TEST_RESULT_FAIL;
    }
    put_str("---------------------------------------------\n");

    for (;;) { }
    return 0;
}
