/* The Phase 2 acceptance test: a program that runs entirely out of external
 * SDRAM and is too big to have been a block RAM program.
 *
 * docs/roadmap.md's Phase 2 is "done when the SoC runs a program larger than
 * 64 KB from external memory, and sim_ramboot's 64 KB assumption is no longer
 * the binding constraint". Each of those is checked here rather than asserted:
 *
 *   1. .text and .rodata are linked at 0x9000_0000 and the image is over
 *      96 KB, so every instruction executed is fetched from SDRAM and the
 *      program could not have been loaded into block RAM at all.
 *   2. software/soc/sdramtable.S's 96 KB of self-describing words are read
 *      back and checked, which is 24576 loads that block RAM never sees.
 *   3. A 256 KB sweep beyond the program proves address uniqueness over four
 *      times the whole block RAM.
 *   4. Byte and halfword accesses are checked separately, because a 32-bit
 *      word crosses two 16-bit SDRAM columns with their own DQM lanes and a
 *      byte write is where that goes wrong.
 *
 * Result is reported twice, exactly as software/soc/main.c does it: printed
 * for a human, and written as a magic word to the fixed address the testbench
 * reads back - into *block RAM*, deliberately, so the verdict does not depend
 * on the thing under test still working.
 *
 * No libc. See main.c's header for the incident that settled that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

extern const uint32_t sdram_table[];
extern const uint32_t sdram_table_words;
extern char _start[];
extern char _end[];
/* End of the *loaded* image: .data's initial values are the last thing in
 * LOAD, so this is where the file stops. `_end` is in the RUN region and is
 * half a megabyte further on, which would report the linker script's layout
 * rather than the program's size. */
extern char _eidata[];

/* The sweep region, from software/soc/link_sdram.ld. Outside both LOAD and
 * RUN, so it cannot reach code or live data however the program grows - the
 * linker enforces it rather than this comment. */
#define SWEEP_BASE  0x90100000u
#define SWEEP_BYTES 0x00040000u          /* 256 KB = 4x the board's block RAM */

static int failures = 0;

static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 30);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

/* A pattern with every address bit contributing, so an address line stuck
 * high or low, or two swapped, produces a mismatch rather than a value that
 * happens to be right. */
static inline uint32_t pattern(uint32_t addr)
{
    return (addr ^ 0xA5A5A5A5u) + (addr >> 3);
}

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    uint32_t i, n, bad_at;
    int ok;

    trap_install();

    put_str("\n=== SDRAM acceptance test ===\n");

    put_str("Running from ");
    put_hex((uint32_t)(uintptr_t)_start);
    put_str(" .. ");
    put_hex((uint32_t)(uintptr_t)_end);
    put_str("\nLoaded image is ");
    put_dec((int)((uint32_t)(uintptr_t)_eidata - (uint32_t)(uintptr_t)_start) / 1024);
    put_str(" KB, against ");
    put_dec((int)(RAM_SIZE / 1024));
    put_str(" KB of block RAM\n\n");

    /* ---- 1. this really is SDRAM ----
     * Cheap, and it is the assumption every other check rests on. If the
     * linker script and the SoC's slave base ever drift apart, everything
     * below would still pass out of block RAM and mean nothing. */
    report("code is above SDRAM_BASE",
           (uint32_t)(uintptr_t)_start >= SDRAM_BASE);
    report("image exceeds block RAM",
           ((uint32_t)(uintptr_t)_eidata - (uint32_t)(uintptr_t)_start) > RAM_SIZE);

    /* ---- 2. 96 KB of read-only data, read back from SDRAM ---- */
    n      = sdram_table_words;
    ok     = 1;
    bad_at = 0;
    for (i = 0; i < n; i++) {
        if (sdram_table[i] != i * 4) {
            ok = 0;
            bad_at = i;
            break;
        }
    }
    if (!ok) {
        put_str("  table word ");
        put_dec((int)bad_at);
        put_str(" at ");
        put_hex((uint32_t)(uintptr_t)&sdram_table[bad_at]);
        put_str(" reads ");
        put_hex(sdram_table[bad_at]);
        put_str(" want ");
        put_hex(bad_at * 4);
        put_str("\n");
    }
    report("96 KB .rodata reads back", ok);

    /* ---- 3. 256 KB of unique addresses ----
     * Written entirely, then read entirely, rather than word-by-word
     * write-then-read: a per-word check passes even if every address aliases
     * onto one another, which is exactly the failure mode block RAM's 16 MB
     * window has and which sim/tb_ramboot.v's header describes at length. */
    for (i = 0; i < SWEEP_BYTES; i += 4)
        *(volatile uint32_t *)(SWEEP_BASE + i) = pattern(SWEEP_BASE + i);

    ok     = 1;
    bad_at = 0;
    for (i = 0; i < SWEEP_BYTES; i += 4) {
        if (*(volatile uint32_t *)(SWEEP_BASE + i) != pattern(SWEEP_BASE + i)) {
            ok = 0;
            bad_at = SWEEP_BASE + i;
            break;
        }
    }
    if (!ok) {
        put_str("  sweep mismatch at ");
        put_hex(bad_at);
        put_str(": reads ");
        put_hex(*(volatile uint32_t *)bad_at);
        put_str(" want ");
        put_hex(pattern(bad_at));
        put_str("\n");
    }
    report("256 KB unique addresses", ok);

    /* ---- 4. byte and halfword lanes ----
     * A 32-bit word is two 16-bit SDRAM columns, each with its own DQM pair,
     * so a sub-word store is the one access where the controller has to mask
     * the right beat. sim/tb_sdram.v checks this at the bus; this checks it
     * through the CPU's own store path as well, because cpu_wb.v shifts
     * sub-word data into the addressed lane on the way out and the two
     * shifts have to compose. */
    {
        volatile uint32_t *w = (volatile uint32_t *)(SWEEP_BASE);
        volatile uint8_t  *b = (volatile uint8_t  *)(SWEEP_BASE);
        volatile uint16_t *h = (volatile uint16_t *)(SWEEP_BASE);

        *w = 0x11223344u;
        b[0] = 0x99; ok  = (*w == 0x11223399u);
        b[1] = 0x88; ok &= (*w == 0x11228899u);
        b[2] = 0x77; ok &= (*w == 0x11778899u);
        b[3] = 0x66; ok &= (*w == 0x66778899u);
        report("byte lanes", ok);

        *w = 0xAAAA5555u;
        h[0] = 0x1234; ok  = (*w == 0xAAAA1234u);
        h[1] = 0x5678; ok &= (*w == 0x56781234u);
        report("halfword lanes", ok);
    }

    /* ---- 5. block RAM still works, from a program that does not live in it
     * The verdict below is written there, so this is not decoration: it is
     * the check that makes the verdict trustworthy. */
    {
        volatile uint32_t *r = (volatile uint32_t *)(RAM_BASE + 0x100u);
        *r = 0xC0FFEE00u;
        report("block RAM still reachable", *r == 0xC0FFEE00u);
    }

    put_str("\n");
    if (failures == 0) {
        put_str("SDRAM-TEST: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("SDRAM-TEST: FAIL (");
        put_dec(failures);
        put_str(")\n");
        *result = TEST_RESULT_FAIL;
    }

    for (;;) { }
}
