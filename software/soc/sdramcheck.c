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

/* How much of the part to sweep. Overridable at build time, because the two
 * things that run this image want opposite sizes and only one of them is the
 * interesting one.
 *
 *   256 KB (the default)  four times the block RAM this program runs from,
 *                         and small enough that `make sim_sdramcheck` under
 *                         Icarus stays inside a few minutes.
 *   32 MB                 the whole part, which is the size that says
 *                         anything about running a kernel out of it.
 *                         `make sdramfullimage`, and BOARD=ulx3s85-sdramfull.
 *
 * The difference is not "more of the same", and the coverage line printed at
 * startup is there to say so. rtl/soc/wb_sdram.v maps wb_adr[24:12] to the
 * row, wb_adr[11:10] to the bank and wb_adr[9:1] to the column, so a 256 KB
 * sweep reaches rows 0..63 of 8192 and **never drives row address bits
 * A6..A12 high at all**. Every bank and every column, one two-hundredth of
 * the rows.
 *
 * (Those three ranges are duplicated from wb_sdram.v's header - practices
 * section 11. Safe direction of error is *over*-stating the shift, which
 * under-reports coverage and makes this look worse than it is; under-stating
 * it would claim rows that were never touched.)
 */
#ifndef SWEEP_BYTES
#define SWEEP_BYTES 0x00040000u
#endif

#define SDRAM_ROW_SHIFT 12u          /* wb_adr[24:12] is the row      */
#define SDRAM_ROWS      8192u        /* 13 row bits                   */
#define SDRAM_BANKS     4u           /* wb_adr[11:10]                 */
#define SDRAM_COLS      512u         /* wb_adr[9:1]                   */

/* mtime, which counts once per system clock in rtl/clint.v. Used here to
 * *measure* the two intervals this program used to assert - the retention gap
 * and the idle - rather than deriving them from a spin count and a comment.
 * The two comments on the idle loop below disagreed with each other about
 * whether it was 10 ms or 100 ms, which is what a number nobody measured
 * looks like after a while. */
static inline uint32_t now_ticks(void)
{
    return *(volatile uint32_t *)(uintptr_t)(CLINT_BASE + 0xBFF8u);
}

static uint32_t ticks_to_ms(uint32_t ticks)
{
    return ticks / (CPU_HZ / 1000u);
}

static int failures = 0;

static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 30);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

/* `report()` with a number built into the label.
 *
 * The address-uniqueness line used to be the string literal "256 KB unique
 * addresses" next to a `#define SWEEP_BYTES 0x40000`, which was true and one
 * edit away from not being. Raising the sweep would have produced a test that
 * passed while reporting a coverage it had not done - the exact failure
 * practices section 1 and section 26 are about, and worse than either,
 * because the wrong number would have been *printed on a board* and believed.
 */
static char *u32_dec(char *p, uint32_t v)
{
    char tmp[10];
    int n = 0;
    do { tmp[n++] = (char)('0' + (v % 10u)); v /= 10u; } while (v);
    while (n) *p++ = tmp[--n];
    return p;
}

static void report_size(uint32_t kb, const char *tail, int ok)
{
    char buf[40];
    char *p = buf;
    const char *t;
    if (kb >= 1024u && (kb % 1024u) == 0u) {
        p = u32_dec(p, kb / 1024u);
        *p++ = ' '; *p++ = 'M'; *p++ = 'B'; *p++ = ' ';
    } else {
        p = u32_dec(p, kb);
        *p++ = ' '; *p++ = 'K'; *p++ = 'B'; *p++ = ' ';
    }
    for (t = tail; *t && (p - buf) < (int)sizeof(buf) - 1; t++) *p++ = *t;
    *p = '\0';
    report(buf, ok);
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
    uint32_t i;
    uint32_t t_write_start, t_read_start;
    int ok;

    trap_install();

    put_str("\n=== external SDRAM check (running from block RAM) ===\n");
    put_str("SDRAM window at ");
    put_hex(SDRAM_BASE);
    put_str(", sweeping ");
    put_dec((int)(SWEEP_BYTES / 1024));
    put_str(" KB of ");
    put_dec((int)(SDRAM_SIZE / 1024));
    put_str(" KB, against ");
    put_dec((int)(RAM_SIZE / 1024));
    put_str(" KB of block RAM\n");

    /* What the sweep size means in the part's own coordinates.
     *
     * "256 KB of SDRAM works" was the claim this program has been making on
     * silicon, and it is true and much smaller than it sounds: the row is
     * wb_adr[24:12], so 256 KB is 64 of 8192 rows and seven of the thirteen
     * row address bits are never driven high. Printing the ranges makes the
     * limit visible in the output of the *short* run too, instead of leaving
     * it to be worked out from a memory map by somebody who has already
     * decided the memory is fine.
     *
     * The banks and columns are fully covered by anything over 4 KB, so they
     * are stated once and not belaboured. */
    {
        uint32_t rows = (SWEEP_BYTES + (1u << SDRAM_ROW_SHIFT) - 1u)
                        >> SDRAM_ROW_SHIFT;
        uint32_t bits = 0, r = rows - 1u;
        while (r) { bits++; r >>= 1; }
        put_str("  rows 0..");
        put_dec((int)(rows - 1u));
        put_str(" of ");
        put_dec((int)SDRAM_ROWS);
        put_str(", all ");
        put_dec((int)SDRAM_BANKS);
        put_str(" banks, all ");
        put_dec((int)SDRAM_COLS);
        put_str(" columns\n");
        if (rows < SDRAM_ROWS) {
            put_str("  the dense sweep leaves row address bits A");
            put_dec((int)bits);
            put_str("..A12 low; test 3 drives them\n");
        }
        put_str("\n");
    }

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

    /* ---- 3. every row, one word each ----
     *
     * The dense sweep below is bounded by how long a simulation can take, and
     * that bound lands in the worst possible place: rtl/soc/wb_sdram.v maps
     * wb_adr[24:12] to the row, so 256 KB reaches 64 of 8192 rows and leaves
     * seven of the thirteen row address bits permanently low. Two hundred
     * times more memory than has ever been proved, sitting behind address
     * lines that have never been driven high through the CPU.
     *
     * The gap is *which bits toggle*, not how many bytes are touched, and
     * those are separable. One word in each of the 8192 rows drives every row
     * address bit and catches any row aliasing onto another - for 8192 writes
     * and 8192 reads, which costs a simulation nothing and runs in
     * `make verify` under Icarus alongside everything else. The dense sweep
     * stays what it is: a volume and retention test. Its full-part build
     * cannot run under Icarus - 8 million words is hours - so it runs under
     * Verilator instead (`make verilator_sdramfull`, about a minute), which
     * is what keeps BOARD=ulx3s85-sdramfull from being a bitstream nobody has
     * executed.
     *
     * Written entirely and then read entirely, for the same reason the sweep
     * below is: a per-word write-then-read passes even if every row aliases
     * onto one.
     */
    {
        uint32_t bad = 0, first_bad = 0;
        for (i = 0; i < SDRAM_ROWS; i++) {
            uint32_t a = SDRAM_BASE + (i << SDRAM_ROW_SHIFT);
            *(volatile uint32_t *)a = pattern(a);
        }
        for (i = 0; i < SDRAM_ROWS; i++) {
            uint32_t a = SDRAM_BASE + (i << SDRAM_ROW_SHIFT);
            if (*(volatile uint32_t *)a != pattern(a)) {
                if (!bad) first_bad = a;
                bad++;
            }
        }
        if (bad) {
            put_str("  ");
            put_dec((int)bad);
            put_str(" of ");
            put_dec((int)SDRAM_ROWS);
            put_str(" rows wrong, first at ");
            put_hex(first_bad);
            put_str(" (row ");
            put_dec((int)((first_bad - SDRAM_BASE) >> SDRAM_ROW_SHIFT));
            put_str(")\n");
        }
        report("all 8192 rows, one word each", bad == 0);
    }

    /* ---- 4. address uniqueness ----
     * Written entirely, then read entirely. A per-word write-then-read passes
     * even if every address aliases onto one location, which is exactly the
     * failure block RAM's 16 MB window has — sim/tb_ramboot.v's header is
     * about that at length. */
    t_write_start = now_ticks();
    for (i = 0; i < SWEEP_BYTES; i += 4)
        *(volatile uint32_t *)(SDRAM_BASE + i) = pattern(SDRAM_BASE + i);
    t_read_start = now_ticks();

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
    report_size(SWEEP_BYTES / 1024u, "unique addresses", ok);

    /* How long the low rows actually held their contents, measured rather
     * than argued.
     *
     * The write pass runs from the bottom of the sweep to the top and the
     * read-back does the same, so address 0 was written a whole write pass
     * before it was read - and at 32 MB that is seconds of continuous traffic
     * through the same controller, not the fraction of a millisecond a 256 KB
     * sweep gives it. That is the interval a kernel cares about, and it is
     * the one thing the short sweep could never test no matter how many times
     * it passed.
     *
     * mtime counts once per system clock here (rtl/clint.v), so this is only
     * a real duration if `timebase-frequency` and CPU_HZ agree - the same
     * assumption dts/soc.dts documents. 32 bits of it wraps after 171 s at
     * 25 MHz, well past any sweep this program can do. */
    put_str("  ");
    put_dec((int)ticks_to_ms(t_read_start - t_write_start));
    put_str(" ms between writing the lowest address and reading it back\n");

    /* ---- 5. byte and halfword lanes ----
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

    /* ---- 6. survives an idle period ----
     * Catches a refresh that stops entirely in the SoC configuration
     * specifically - different arbitration, different traffic from the
     * CPU-less probe - and is kept short so the simulated run of this same
     * image stays usable.
     *
     * The duration is *measured* now. The two comments that used to describe
     * this loop said "~100 ms" and "~10 ms", four lines apart, because both
     * were derived from a spin count and neither from a clock. A retention
     * test whose retention interval is unknown is a formality, and this one
     * had drifted into being one without anybody editing it. */
    {
        volatile uint32_t *w = (volatile uint32_t *)(SDRAM_BASE + 0x1000u);
        volatile uint32_t  spin;
        uint32_t t0, idle_ms;
        *w = 0x5AA55AA5u;
        t0 = now_ticks();
        for (spin = 0; spin < CPU_HZ / 400u; spin++) { }
        idle_ms = ticks_to_ms(now_ticks() - t0);
        ok = (*w == 0x5AA55AA5u);
        put_str("  idled ");
        put_dec((int)idle_ms);
        put_str(" ms\n");
        report("survives an idle", ok);
    }

    /* ---- 7. block RAM is still fine ----
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
