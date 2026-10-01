/* DDR3, exercised through the whole SoC - the real command path this time,
 * not rtl/soc/ddr3_read_calib.v's own direct-signal-injection scheme, and
 * not a raw Wishbone-master testbench tap either (sim/tb_wb_ddr.v already
 * proved the module standalone, Phase 9 Stage 2 Part 1). This is the first
 * real CPU-issued access: rtl/soc/soc_top.v's own interconnect decodes
 * DDR3_BASE, arbitrates it the same way it arbitrates every other slave,
 * and rtl/soc/wb_ddr.v does the rest.
 *
 * Runs from block RAM, the same "the program's own home and the memory
 * under test are different devices" split sdramcheck.c's own header
 * explains - DDR3 has no loader of its own yet either.
 *
 * Deliberately not a sweep. Every miss here costs a real 16-byte block
 * fill (16 sequential single-byte controller calls, ~20 cycles each -
 * rtl/soc/wb_ddr.v's own header), so a handful of directed word accesses
 * mirroring sim/tb_wb_ddr.v's own cases - not sdramcheck.c's own
 * hundreds-of-KB sweep - is what a first data-path check needs: reachable
 * and correct, not yet a coverage sweep. (Instruction fetch from DDR3, which
 * is what Stage 2's "Done when" asks for, is software/soc/ddrexec.c.) A real full-part sweep is later,
 * separate work, the same way sdramcheck.c's own 32 MB sweep was split
 * from its 256 KB default.
 *
 * No libc - see software/soc/main.c's header for the incident that settled
 * that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"

static int errors = 0;

static void check(const char *what, uint32_t got, uint32_t want)
{
    if (got != want) {
        put_str("  FAIL "); put_str(what);
        put_str(": got "); put_hex(got);
        put_str(", expected "); put_hex(want);
        put_str("\n");
        errors++;
    } else {
        put_str("  ok   "); put_str(what); put_str("\n");
    }
}

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    volatile uint32_t *w0 = (volatile uint32_t *)(uintptr_t)(DDR3_BASE + 0x00);
    volatile uint32_t *w1 = (volatile uint32_t *)(uintptr_t)(DDR3_BASE + 0x04);
    volatile uint32_t *blk1 = (volatile uint32_t *)(uintptr_t)(DDR3_BASE + 0x10);
    volatile uint8_t  *b0  = (volatile uint8_t  *)(uintptr_t)(DDR3_BASE + 0x00);

    put_str("\n=== DDR3 real command path, through the CPU (Phase 9 Stage 2) ===\n\n");

    /* Store-then-load: the first access ever to reach the DDR3 window is a
     * real miss, filling a real 16-byte block through 16 real controller
     * calls (rtl/soc/wb_ddr.v). */
    *w0 = 0xDEADBEEFu;
    check("store-then-load, word 0 of block 0", *w0, 0xDEADBEEFu);

    /* A second word in the same, now-open block - a cache-hit-path store,
     * not a re-fill, and the first word must still read back right. */
    *w1 = 0x12345678u;
    check("store-then-load, word 1 of block 0", *w1, 0x12345678u);
    check("word 0 unchanged by word 1's own store", *w0, 0xDEADBEEFu);

    /* A different block - evicts the open one; the first block must still
     * be right after a real re-fill later. */
    *blk1 = 0xCAFEF00Du;
    check("store-then-load, a different block", *blk1, 0xCAFEF00Du);
    check("block 0's word 0 survives eviction and a real re-fill", *w0, 0xDEADBEEFu);
    check("block 0's word 1 survives eviction and a real re-fill", *w1, 0x12345678u);

    /* A single-byte access - proves the interconnect's own wb_sel plumbing
     * reaches this slave correctly, not just full-word accesses. */
    *b0 = 0x42u;
    check("single-byte store reaches the low byte", (uint32_t)*b0, 0x42u);
    check("the other three bytes of the word are undisturbed",
          *w0 & 0xFFFFFF00u, 0xDEADBE00u);

    put_str("\n---------------------------------------------\n");
    if (errors == 0) {
        put_str("DDR3 CPU-PATH TEST PASSED\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("DDR3 CPU-PATH TEST FAILED\n");
        *result = TEST_RESULT_FAIL;
    }
    put_str("---------------------------------------------\n");

    for (;;) { }
    return 0;
}
