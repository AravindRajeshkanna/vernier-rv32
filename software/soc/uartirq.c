/* An interrupt-driven UART transmitter.
 *
 * docs/roadmap.md Phase 3 has flagged "the interrupt is already wired to the
 * PLIC; the driver simply polls" as a backlog item, and until this file that
 * was exactly true: every put_char in this repository (software/soc/console.c)
 * spins on LSR.THRE before every single byte. rtl/uart.v has had a working
 * ETBEI interrupt since before this file, and software/soc/plictest.c proves
 * the PLIC delivers it - but proves it once, disarms the interrupt
 * immediately, and moves on. Nothing has ever used it to actually send
 * anything.
 *
 * This does: a ring buffer, an S-mode handler that drains it one byte per
 * interrupt, and - the actual point of "interrupt-driven" over "polled" - a
 * demonstration that the hart is free to do unrelated work the moment the
 * transfer is kicked off, rather than blocking on the UART's timing.
 *
 * S-mode delivery through PLIC context 1 is reused unchanged from
 * plictest.c, which is what's already proven; this file is not testing PLIC
 * delivery again, only what a driver does with it.
 *
 * No libc - see software/soc/main.c's header for why.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

#define UART_SRC 1   /* soc_top.v: irq_sources[0]; see plictest.c */

static int failures = 0;

static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 46);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

/* ---- the ring buffer: one producer (S-mode mainline), one consumer (the
 * interrupt handler) ----
 *
 * No lock needed for that shape, only a discipline: `head` is written only
 * by the producer and `tail` only by the consumer, each reads the other's
 * index but never writes it. Both are free-running; the count in flight is
 * head - tail. Bigger than any message this file sends, so "buffer full" -
 * a real driver's problem, not this test's - is never exercised here. */
#define TXBUF_SIZE 128   /* a power of two, so wrap is a mask, not a modulo */
static volatile uint8_t  txbuf[TXBUF_SIZE];
static volatile uint32_t tx_head, tx_tail;
static volatile uint32_t tx_irq_count;
static volatile int      tx_done;   /* set once the handler has fed the last
                                      * queued byte and disarmed the interrupt */

/* Queue one byte. Mainline-only; never called from the handler. */
static void tx_queue(uint8_t c)
{
    txbuf[tx_head & (TXBUF_SIZE - 1)] = c;
    tx_head++;
}

/* GCC emits the register save/restore and `sret` for this attribute - see
 * plictest.c, whose S-mode setup (context 1, mideleg, stvec) this reuses
 * unchanged. */
__attribute__((interrupt("supervisor")))
static void s_irq_handler(void)
{
    uint32_t id = REG32(PLIC_CLAIM(PLIC_CTX_S));

    tx_irq_count++;

    if (tx_tail != tx_head) {
        UART_THR = txbuf[tx_tail & (TXBUF_SIZE - 1)];
        tx_tail++;
    }
    if (tx_tail == tx_head) {
        /* Nothing left queued. THRE goes true again the moment this byte
         * finishes, and with ETBEI still enabled that reasserts the level
         * forever - the hazard rtl/uart.v's header warns about, and the one
         * plictest.c's handler already disarms for. "Nothing more to send"
         * is the only thing that gets to turn this interrupt off, which is
         * why this check runs after the write above: disarming here still
         * lets the byte just written finish going out. */
        UART_IER = 0u;
        tx_done = 1;
    }

    if (id) REG32(PLIC_CLAIM(PLIC_CTX_S)) = id;   /* complete */
}

static void s_mode_main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    static const char msg[] =
        "sent by the interrupt handler while main did something else\n";
    uint32_t i, spin;
    uint32_t work_done, done_at;
    uint32_t checksum = 0;

    put_str("\n=== interrupt-driven UART TX ===\n\n");

    REG32(PLIC_PRIORITY(UART_SRC))    = 3u;
    REG32(PLIC_ENABLE(PLIC_CTX_S))    = 1u << UART_SRC;
    REG32(PLIC_THRESHOLD(PLIC_CTX_S)) = 0u;

    for (i = 0; i < sizeof(msg) - 1u; i++)
        tx_queue((uint8_t)msg[i]);

    tx_irq_count = 0u;
    tx_done      = 0;

    UART_IER = 0x02u;   /* ETBEI: arms the first interrupt immediately, since
                          * THRE is already true with the transmitter idle */

    /* The unrelated work a real program would rather be doing than spinning
     * on LSR.THRE, standing in for it here as a plain checksum loop - sized
     * generously past what the transfer above needs, so the finish is
     * observed rather than assumed. `done_at` records the first iteration at
     * which the handler had already finished; it stays UINT32_MAX if the
     * transfer outlived the whole loop. */
    done_at = 0xFFFFFFFFu;
    for (work_done = 0; work_done < 5000u; work_done++) {
        checksum += work_done;
        if (tx_done && done_at == 0xFFFFFFFFu) done_at = work_done;
    }
    (void)checksum;

    /* Bounded safety net rather than an assumption: if the unrelated work
     * above finished before the transfer did, this waits for the rest of it
     * properly instead of reporting a race as a pass. */
    for (spin = 0; spin < 100000u && !tx_done; spin++) { }

    report("all bytes handed to the UART", tx_done);
    report("exactly one interrupt per byte sent",
           tx_irq_count == (uint32_t)(sizeof(msg) - 1u));
    report("transfer finished during the unrelated work",
           done_at < 5000u);

    put_str("  finished after ");
    if (done_at < 5000u) put_dec((int)done_at);
    else put_str("never");
    put_str(" of 5000 unrelated-work iterations (0 = beat the first check)\n");

    put_str("\n");
    if (failures == 0) {
        put_str("UART-IRQ-TEST: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("UART-IRQ-TEST: FAIL (");
        put_dec(failures);
        put_str(")\n");
        *result = TEST_RESULT_FAIL;
    }

    for (;;) { }
}

int main(void)
{
    trap_install();

    /* Delegate the supervisor external interrupt, point stvec at the
     * handler, enable SEIE in mie and SIE in mstatus, then drop to S-mode -
     * see plictest.c for why this is the shape that's already proven. */
    __asm__ volatile ("csrs mideleg, %0" :: "r"(1u << 9));
    __asm__ volatile ("csrw stvec, %0"   :: "r"(s_irq_handler));
    __asm__ volatile ("csrs mie, %0"     :: "r"(1u << 9));
    __asm__ volatile ("csrs mstatus, %0" :: "r"(1u << 1));   /* SIE */

    __asm__ volatile(
        "li   t0, 3 << 11\n"
        "csrc mstatus, t0\n"
        "li   t0, 1 << 11\n"        /* MPP = 01, supervisor */
        "csrs mstatus, t0\n"
        "csrw mepc, %0\n"
        "mret\n"
        :: "r"(s_mode_main) : "t0");

    for (;;) { }
}
