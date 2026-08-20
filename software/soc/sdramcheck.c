/* External SDRAM, exercised through the whole SoC — from a program that lives
 * in block RAM.
 *
 * This is the second of the two hardware bring-up steps, and the split is the
 * point of it.
 *
 *   fpga/ulx3s_sdram.v   no CPU at all. Drives rtl/soc/wb_sdram.v directly and
 *                        answers one question: does the controller talk to the
 *                        chip. Five LEDs, `BOARD=ulx3s-sdram`.
 *   this program         the CPU, the caches, the interconnect and the byte-lane
 *                        shifting in cpu_wb.v are now all in the path, and the
 *                        console can say which of them broke.
 *
 * **It runs from block RAM, not from SDRAM**, and that is not a limitation of
 * the test — it is the only thing that can run at all right now. A bitstream
 * initialises block RAM at FPGA configuration time; SDRAM is external and comes
 * up holding nothing. Getting a program *into* SDRAM needs a loader (the SD path,
 * or a UART one), neither of which exists yet. `make sim_sdramboot` proves code
 * execution out of SDRAM in simulation, where the testbench can simply preload
 * the model. See docs/roadmap.md Phase 2.
 *
 * Result is reported twice, as everything here does it: printed for a human, and
 * written as a magic word to the address sim/tb_ramboot.v reads back, so the
 * simulated version of this exact image is machine-checkable.
 *
 * No libc — see software/soc/main.c's header for the incident that settled that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

/* 256 KB, four times the block RAM this program is running from. Big enough
 * that no aliasing failure can hide, small enough that the simulated run of the
 * same image stays inside a minute. The board does this in about a tenth of a
 * second. */
#define SWEEP_BYTES 0x00040000u

static int failures = 0;

static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 30);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

/* Every address bit reaches the data, so a swapped or stuck address line
 * produces a value belonging to a different address rather than one that
 * happens to look plausible. */
static inline uint32_t pattern(uint32_t addr)
{
    return (addr ^ 0xA5A5A5A5u) + (addr >> 3);
}

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    volatile uint32_t *sdram  = (volatile uint32_t *)SDRAM_BASE;
    uint32_t i, bad_at;
    int ok;

    trap_install();

    put_str("\n=== external SDRAM check (running from block RAM) ===\n");
    put_str("SDRAM window at ");
    put_hex(SDRAM_BASE);
    put_str(", sweeping ");
    put_dec((int)(SWEEP_BYTES / 1024));
    put_str(" KB against ");
    put_dec((int)(RAM_SIZE / 1024));
    put_str(" KB of block RAM\n\n");

    /* ---- 1. a single word ----
     * If this fails, nothing below will mean anything, and the probe with no
     * CPU in it is the thing to flash next. */
    sdram[0] = 0xDEADBEEFu;
    {
        uint32_t v = sdram[0];
        if (v != 0xDEADBEEFu) {
            put_str("  read ");
            put_hex(v);
            put_str(" want 0xDEADBEEF, differing bits ");
            put_hex(v ^ 0xDEADBEEFu);
            put_str("\n");
        }
        report("single word", v == 0xDEADBEEFu);
    }

    /* ---- 2. walking ones ----
     * One data bit at a time. A stuck or swapped DQ line fails here and passes
     * the single-word check about half the time. */
    ok = 1;
    for (i = 0; i < 32; i++) {
        sdram[64] = 1u << i;
        if (sdram[64] != (1u << i)) ok = 0;
    }
    report("walking ones, 32 bits", ok);

    /* ---- 3. address uniqueness ----
     * Written entirely, then read entirely. A per-word write-then-read passes
     * even if every address aliases onto one location, which is exactly the
     * failure block RAM's 16 MB window has — sim/tb_ramboot.v's header is
     * about that at length. */
    for (i = 0; i < SWEEP_BYTES; i += 4)
        *(volatile uint32_t *)(SDRAM_BASE + i) = pattern(SDRAM_BASE + i);

    /* Every mismatch, not the first. A single failing word says almost
     * nothing; the *shape* of a thousand of them says which side is wrong,
     * and the first version of this program stopped at one and threw the rest
     * away. What is accumulated:
     *
     *   bad_bits    which data bits ever came back wrong. One bit means one
     *               slow DQ line; all of them means something structural.
     *   bad_split   how many failures were in a bit that *differs between the
     *               two halves of the word*. A 32-bit access is two 16-bit
     *               burst beats, so if the capture edge sits too close to the
     *               beat boundary the failing bit takes the other beat's
     *               value - and only ever on bits where the two beats differ.
     *               That signature is the reason for the clock change in
     *               fpga/sdram_clk_out.v, and this is what confirms or
     *               refutes it on a board rather than in an argument.
     */
    {
        uint32_t bad_bits = 0, bad_count = 0, bad_split = 0, first = 0;
        for (i = 0; i < SWEEP_BYTES; i += 4) {
            uint32_t a = SDRAM_BASE + i;
            uint32_t got = *(volatile uint32_t *)a;
            uint32_t want = pattern(a);
            uint32_t diff = got ^ want;
            if (diff) {
                if (!bad_count) first = a;
                bad_count++;
                bad_bits |= diff;
                /* bits where the low and high halves of the word disagree */
                if (diff & ((want ^ (want >> 16)) & 0xFFFFu)) bad_split++;
                if (diff & (((want ^ (want >> 16)) & 0xFFFFu) << 16)) bad_split++;
            }
        }
        if (bad_count) {
            put_str("  ");
            put_dec((int)bad_count);
            put_str(" of ");
            put_dec((int)(SWEEP_BYTES / 4));
            put_str(" words wrong; bits seen bad ");
            put_hex(bad_bits);
            put_str("\n  of those, ");
            put_dec((int)bad_split);
            put_str(" were bits that differ between the two burst halves\n");
            put_str("  first at ");
            put_hex(first);
            put_str(": reads ");
            put_hex(*(volatile uint32_t *)first);
            put_str(" want ");
            put_hex(pattern(first));
            put_str("\n");

            /* Re-read the first failing address several times without
             * rewriting it. Identical wrong values every time means the write
             * stored the wrong thing; values that vary mean the read path is
             * catching the bus in transition. Those want different fixes, and
             * nothing else here distinguishes them. */
            {
                uint32_t r0 = *(volatile uint32_t *)first;
                uint32_t varies = 0, k;
                for (k = 0; k < 64; k++)
                    if (*(volatile uint32_t *)first != r0) varies = 1;
                put_str(varies ? "  re-reads disagree - the READ path is marginal\n"
                               : "  re-reads agree - the stored value is wrong (WRITE path)\n");
            }
        }
        ok = (bad_count == 0);
    }
    report("256 KB unique addresses", ok);

    /* ---- 4. byte and halfword lanes ----
     * A 32-bit word is two 16-bit SDRAM columns with their own DQM pair, and
     * cpu_wb.v additionally shifts sub-word data into the addressed lane. The
     * two shifts have to compose; this is where they are checked through the
     * CPU's own store path rather than at the bus. */
    {
        volatile uint32_t *w = (volatile uint32_t *)(SDRAM_BASE + 0x800u);
        volatile uint8_t  *b = (volatile uint8_t  *)(SDRAM_BASE + 0x800u);
        volatile uint16_t *h = (volatile uint16_t *)(SDRAM_BASE + 0x800u);

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

    /* ---- 5. survives an idle period ----
     * A short one. Real retention is the probe's job: it idles ~100 ms with no
     * CPU in the way, which is what makes its led[4] a retention test rather
     * than a formality. This is here to catch a refresh that stops entirely in
     * the SoC configuration specifically — different arbitration, different
     * traffic — and is kept short so the simulated run of this same image
     * stays usable. */
    {
        volatile uint32_t *w = (volatile uint32_t *)(SDRAM_BASE + 0x1000u);
        volatile uint32_t  spin;
        *w = 0x5AA55AA5u;
        /* ~10 ms at 25 MHz. `volatile` so it is not optimised away. */
        for (spin = 0; spin < CPU_HZ / 400u; spin++) { }
        report("survives a short idle", *w == 0x5AA55AA5u);
    }

    /* ---- 6. block RAM is still fine ----
     * The verdict below is written there, so this is what makes the verdict
     * worth reading. */
    {
        volatile uint32_t *r = (volatile uint32_t *)(RAM_BASE + 0x100u);
        *r = 0xC0FFEE00u;
        report("block RAM still reachable", *r == 0xC0FFEE00u);
    }

    put_str("\n");
    if (failures == 0) {
        put_str("SDRAM-CHECK: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("SDRAM-CHECK: FAIL (");
        put_dec(failures);
        put_str(")\n");
        *result = TEST_RESULT_FAIL;
    }

    for (;;) { }
}
