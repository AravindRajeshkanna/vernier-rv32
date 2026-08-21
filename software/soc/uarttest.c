/* The ns16550 register map, and the UART's interrupt reaching the hart.
 *
 * rtl/uart.v used to be three registers of this project's own design. Every
 * program here drove it the same way - poll one status bit, write one data
 * register - so converting it to an ns16550 left most of the new surface
 * untested by construction: nothing in this repository sets DLAB, programs a
 * divisor, reads IIR, or enables an interrupt. A driver written elsewhere
 * does all four in its first hundred instructions.
 *
 * That is the gap docs/practices.md section 26 is about, so this closes it
 * deliberately rather than waiting for OpenSBI to find it.
 *
 * The interrupt half also tests something no other program does: the whole
 * chain from a peripheral, through PLIC source 1, to a bit in `mip`. Source 1
 * was reserved for the UART and tied low for as long as the UART had no
 * interrupt to raise.
 *
 * No libc - see software/soc/main.c's header for the incident that settled
 * that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

#define UART_SRC 1      /* soc_top.v: irq_sources[0] is source 1 */

static int failures = 0;

static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 34);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

static inline uint32_t read_mip(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mip" : "=r"(v));
    return v;
}

/* Wait for the transmitter to drain.
 *
 * Needed because this program's own console output is the thing that makes it
 * busy: put_char polls THRE *before* writing, so the instant after a report()
 * returns, the last character is still going out and THRE is 0. The first
 * version of this test checked THRE immediately after printing a line and
 * reported the hardware as broken for being correct. */
static int wait_thre(uint32_t limit)
{
    uint32_t i;
    for (i = 0; i < limit; i++)
        if (UART_LSR & UART_LSR_THRE) return 1;
    return 0;
}

/* Wait for mip.MEIP to reach `want`. Polled for the reason plictest.c polls:
 * the peripheral -> PLIC -> mip path is several cycles deep and the hardware
 * never promised the next instruction would see it. */
static int wait_meip(int want, uint32_t limit)
{
    uint32_t i;
    for (i = 0; i < limit; i++)
        if ((int)((read_mip() >> 11) & 1u) == want) return 1;
    return 0;
}

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    uint32_t saved_dll, saved_dlm;

    trap_install();

    put_str("\n=== ns16550 register map ===\n\n");

    /* ---- the scratch register ----
     * This is how a driver decides whether there is a UART here at all: SCR
     * is storage with no side effects, so a value written and read back means
     * something is answering. Two patterns, so a bus that returns the last
     * value or a constant does not pass. */
    UART_SCR = 0xA5u;
    report("SCR holds 0xA5", (UART_SCR & 0xFFu) == 0xA5u);
    UART_SCR = 0x5Au;
    report("SCR holds 0x5A", (UART_SCR & 0xFFu) == 0x5Au);

    /* ---- LSR ----
     * Nothing has been sent, so the transmitter is empty and nothing has been
     * received. THRE is the bit every put_char in this repository now polls. */
    {
        /* Sampled together, once the transmitter has drained, because reading
         * them either side of a report() would put a character in flight in
         * between and the second read would honestly say "busy". */
        uint32_t lsr;
        int idle = wait_thre(1000u);
        lsr = UART_LSR;
        report("LSR: THRE sets when idle", idle);
        report("LSR: TEMT tracks THRE", (lsr & UART_LSR_TEMT) != 0u);
        report("LSR: DR clear with no input", (lsr & UART_LSR_DR) == 0u);
    }

    /* ---- DLAB aliasing ----
     * The one genuinely surprising thing about this map: with LCR bit 7 set,
     * offsets 0 and 4 stop being the data and interrupt-enable registers and
     * become the two halves of the divisor latch. A driver programming the
     * baud rate depends on it; getting it wrong means a byte written as data
     * silently sets the baud rate instead. */
    /* **Nothing may print between here and the LCR write below.** With DLAB
     * set, offset 0 is DLL, not THR - so a put_char in this window does not
     * emit a character, it silently reprograms the baud rate. That is the
     * hazard this section exists to test, and the first version of this test
     * walked straight into it: the three report() calls in here produced no
     * output at all and set the divisor to the low byte of their own text.
     *
     * Results are therefore accumulated and reported after DLAB is clear. */
    {
        int dlab_ok, reset_ok, latch_ok;

        /* Drain first. Changing the divisor mid-character garbles it, and
         * before rtl/uart.v's period comparison became `>=` it wedged the
         * transmitter outright - which is how this line came to be here. */
        (void)wait_thre(1000u);

        UART_LCR = UART_LCR_DLAB;
        dlab_ok  = (UART_LCR & UART_LCR_DLAB) != 0u;

        saved_dll = UART_DLL & 0xFFu;
        saved_dlm = UART_DLM & 0xFFu;
        reset_ok  = (saved_dll == 0u && saved_dlm == 0u);

        UART_DLL = 0x0Du;
        UART_DLM = 0x01u;
        latch_ok = ((UART_DLL & 0xFFu) == 0x0Du) &&
                   ((UART_DLM & 0xFFu) == 0x01u);

        /* Back to 0 before clearing DLAB. 0 is not a legal divisor on real
         * silicon, and rtl/uart.v uses that to mean "keep CLKS_PER_BIT" -
         * which is what every testbench here runs at. Leaving 0x10D set would
         * put the console at 269 clocks per bit and the rest of this
         * program's output would arrive at a rate the testbench is not
         * decoding, which looks like a hang rather than a wrong baud rate. */
        UART_DLL = 0x00u;
        UART_DLM = 0x00u;
        UART_LCR = 0x03u;                 /* 8N1, DLAB clear */

        report("LCR.DLAB reads back", dlab_ok);
        report("divisor resets to 0", reset_ok);
        report("divisor latch reads back", latch_ok);
        report("LCR: 8N1 with DLAB clear", (UART_LCR & 0xFFu) == 0x03u);
    }

    /* ---- IIR ----
     * With no interrupts enabled, bit 0 reads 1: "none pending". Bits 7:6 are
     * 00, which is how a part with no FIFOs identifies itself - a driver that
     * checks will not try to use FIFO mode. */
    UART_IER = 0x00u;
    report("IIR: no interrupt pending", (UART_IIR & 0x01u) == 0x01u);
    report("IIR: reports no FIFO", (UART_IIR & 0xC0u) == 0x00u);

    /* ---- MSR ----
     * A constant here: there are no modem pins on this board, and a driver
     * that waits for CTS before transmitting would otherwise wait forever. */
    report("MSR: CTS/DSR/DCD asserted", (UART_MSR & 0xB0u) == 0xB0u);

    /* ---- the interrupt, end to end ----
     * UART -> PLIC source 1 -> mip.MEIP. Nothing writes mip here; if the
     * bit moves, the wire exists.
     *
     * ETBEI is used rather than the receive interrupt because it needs no
     * external stimulus: the transmitter is idle, so THRE is already true and
     * enabling the interrupt is enough. mstatus.MIE stays clear throughout -
     * this checks that the interrupt is *pending*, deliberately without
     * taking it, because a level interrupt with no handler would re-enter
     * forever. */
    REG32(PLIC_PRIORITY(UART_SRC))      = 3u;
    REG32(PLIC_ENABLE(PLIC_CTX_M))      = 1u << UART_SRC;
    REG32(PLIC_THRESHOLD(PLIC_CTX_M))   = 0u;

    report("MEIP clear before enabling", (read_mip() & (1u << 11)) == 0u);

    UART_IER = 0x02u;                     /* ETBEI: transmitter empty */
    report("UART raises PLIC source 1", wait_meip(1, 1000u));
    /* Wait for the line above to finish printing before asking IIR what it is
     * reporting: while the transmitter is busy THRE is false, and the honest
     * answer would be "no interrupt". */
    {
        int idle = wait_thre(1000u);
        report("IIR names the THRE interrupt",
               idle && ((UART_IIR & 0x0Fu) == 0x02u));
    }

    UART_IER = 0x00u;
    report("MEIP drops when IER cleared", wait_meip(0, 1000u));

    put_str("\n");
    if (failures == 0) {
        put_str("UART16550-TEST: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("UART16550-TEST: FAIL (");
        put_dec(failures);
        put_str(")\n");
        *result = TEST_RESULT_FAIL;
    }

    for (;;) { }
}
