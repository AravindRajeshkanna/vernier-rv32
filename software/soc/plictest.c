/* The PLIC's standard register map, and an external interrupt delivered to
 * S-mode.
 *
 * Three changes are under test and they had to land together, because each
 * one is useless without the others:
 *
 *   1. **The standard register layout.** rtl/plic.v used to put threshold at
 *      0x3000 and claim at 0x3004 - offsets of this project's own invention.
 *      Every stock driver (OpenSBI's, Linux's) computes 0x200000 + 0x1000*ctx
 *      from the base address in the device tree and finds nothing there.
 *   2. **A second context.** Context 0 is hart 0 M-mode, context 1 is hart 0
 *      S-mode. Linux takes external interrupts in S-mode; one M-mode context
 *      has nowhere to deliver them.
 *   3. **mip.SEIP.** It was hardwired to zero, so context 1 had nowhere to
 *      arrive even once it existed. It is now the spec's OR of a
 *      software-writable bit and the controller's pin.
 *
 * ---- What had tested this before ----
 *
 * The register plumbing: `sim/program.S`, the hand-assembled core regression,
 * which writes priorities, a threshold and an enable mask and then claims -
 * at raw addresses, which is why it does not turn up in a grep for "plic".
 * It moved to the new offsets alongside this change.
 *
 * The *delivery*: nothing. No program in this repository has ever taken an
 * external interrupt, in either privilege mode. The formal properties in
 * rtl/plic.v prove the claim encoder picks the right source; nothing proved
 * a hart ever sees the line. docs/practices.md section 26 is about the last
 * time that distinction cost two bugs.
 *
 * No libc - see software/soc/main.c's header for the incident that settled
 * that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

/* soc_top.v: irq_sources = {5'b0, 1'b0, gpio_irq, uart_irq}, so bit 0 of that
 * vector is source 1 and bit 1 is source 2. This comment said bit 0 was tied
 * low, which was true when it was written and stopped being true when the
 * UART got an interrupt - and that is exactly why the UART's delivery went
 * untested until a Linux userspace failure pointed here.
 *
 * Duplicated from the RTL with no check that they agree -
 * practices.md section 11. Getting it wrong fails loudly: the claim returns a
 * different ID than the one this file asks about. */
#define GPIO_SRC 2
#define UART_SRC 1

static int failures = 0;

static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 34);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

/* Written by the S-mode handler, read by S-mode code after it returns. */
static volatile uint32_t s_claimed_id;
static volatile uint32_t s_irq_count;

static inline uint32_t read_mip(void)
{
    uint32_t v;
    __asm__ volatile ("csrr %0, mip" : "=r"(v));
    return v;
}

/* Wait for mip.SEIP to reach `want`, up to `limit` polls.
 *
 * Polling rather than reading once, because the hardware never promised
 * once. A store to GPIO_OUT has to cross the bus, loop back through
 * `gpio_dir` in the testbench, get edge-detected into the GPIO's `ip_r`,
 * become `pending` in the PLIC and then come out of its priority encoder -
 * several cycles after the store instruction retires. The first version of
 * this test read `mip` on the very next instruction and reported a working
 * design as broken.
 *
 * The bound is what keeps it a test: a version that spun forever would hang
 * instead of failing, and a failure that hangs tells you nothing. */
static int wait_seip(int want, uint32_t limit)
{
    uint32_t i;
    for (i = 0; i < limit; i++)
        if ((int)((read_mip() >> 9) & 1u) == want) return 1;
    return 0;
}

/* GCC emits the register save/restore and `sret` for this attribute, which is
 * the whole reason to use it: an S-mode handler that clobbered a caller's
 * register would corrupt the code it interrupted, and that is a bug worth not
 * writing by hand in a test whose subject is something else. */
__attribute__((interrupt("supervisor")))
static void s_irq_handler(void)
{
    uint32_t id = REG32(PLIC_CLAIM(PLIC_CTX_S));

    s_claimed_id = id;
    s_irq_count++;

    /* Stop the source re-asserting. Both of the sources this test uses are
     * *level* inputs to the PLIC, so completing alone would hand the
     * interrupt straight back: the GPIO's pending bit has to be cleared, and
     * the UART's IER bit has to be turned off, because rtl/uart.v derives its
     * irq from `ier_r[1] && thre` combinationally and THRE is true whenever
     * the transmitter is idle.
     *
     * That is not a workaround. It is what a driver does, and it is the
     * property that makes a level-triggered controller safe: there is no edge
     * to miss, and no way to clear the interrupt except by fixing what caused
     * it. */
    GPIO_IP = 0xFFFFu;          /* write-1-to-clear */
    UART_IER = 0u;              /* drop ETBEI, and with it uart_irq */
    REG32(PLIC_ENABLE(PLIC_CTX_S)) = 0;

    if (id) REG32(PLIC_CLAIM(PLIC_CTX_S)) = id;   /* complete */
}

static void s_mode_main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    uint32_t spin;

    /* Reaching here at all means mret to S-mode worked; the interrupt is the
     * subject. Raise it by giving the GPIO a rising edge on a pin it is
     * driving - tb_ramboot.v loops gpio_out back to gpio_in through gpio_dir. */
    GPIO_OUT = 0x0001u;

    for (spin = 0; spin < 100000u && s_irq_count == 0u; spin++) { }

    report("S-mode took the interrupt", s_irq_count == 1u);
    report("claimed the right source", s_claimed_id == GPIO_SRC);

    /* ---- and now the UART's, which is the one Linux depends on ----
     *
     * Everything above proves the PLIC delivers *a* source. This proves it
     * delivers source 1, driven by rtl/uart.v, which is a different claim and
     * the one that had never been made anywhere: the Linux boot on hardware
     * only ever *probed* the controller, and its console output goes through
     * the 8250 driver's polled path. `/init` writing to /dev/console is the
     * first thing in the whole system that waits on this interrupt.
     *
     * ETBEI is the easiest trigger there is. `thre` is true whenever the
     * transmitter is idle, so enabling the interrupt asserts it immediately -
     * no data has to move and nothing has to be timed.
     */
    s_irq_count  = 0u;
    s_claimed_id = 0xFFFFFFFFu;

    REG32(PLIC_PRIORITY(UART_SRC)) = 3u;
    REG32(PLIC_ENABLE(PLIC_CTX_S)) = 1u << UART_SRC;

    UART_IER = 0x02u;           /* ETBEI: interrupt while THR is empty */

    for (spin = 0; spin < 100000u && s_irq_count == 0u; spin++) { }

    report("S-mode took the UART interrupt", s_irq_count == 1u);
    report("claimed source 1, the UART", s_claimed_id == UART_SRC);

    put_str("\n");
    if (failures == 0) {
        put_str("PLIC-TEST: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("PLIC-TEST: FAIL (");
        put_dec(failures);
        put_str(")\n");
        *result = TEST_RESULT_FAIL;
    }

    for (;;) { }
}

int main(void)
{
    uint32_t mip;

    trap_install();

    put_str("\n=== PLIC: standard layout, S-mode context ===\n\n");

    /* ---- 1. the registers answer where the spec says they are ---- */
    REG32(PLIC_PRIORITY(GPIO_SRC)) = 4u;
    report("priority reads back", REG32(PLIC_PRIORITY(GPIO_SRC)) == 4u);

    /* Context 1's enable block is at 0x2000 + 0x80, which is the offset a
     * one-context PLIC did not have at all. */
    REG32(PLIC_ENABLE(PLIC_CTX_S)) = 1u << GPIO_SRC;
    report("context 1 enable reads back",
           REG32(PLIC_ENABLE(PLIC_CTX_S)) == (1u << GPIO_SRC));

    /* And the context block at 0x200000, which is the offset that made the
     * old map undrivable. Threshold 0 lets anything through; M-mode's is set
     * to the maximum so this interrupt cannot land there instead - if the
     * contexts were not really independent, that would show up as the
     * S-mode delivery below never happening. */
    REG32(PLIC_THRESHOLD(PLIC_CTX_S)) = 0u;
    REG32(PLIC_THRESHOLD(PLIC_CTX_M)) = 7u;
    report("context thresholds read back",
           REG32(PLIC_THRESHOLD(PLIC_CTX_S)) == 0u &&
           REG32(PLIC_THRESHOLD(PLIC_CTX_M)) == 7u);

    /* ---- 2. mip.SEIP, the software-writable half ---- */
    __asm__ volatile ("csrs mip, %0" :: "r"(1u << 9));
    mip = read_mip();
    report("mip.SEIP settable by M-mode", (mip & (1u << 9)) != 0u);

    __asm__ volatile ("csrc mip, %0" :: "r"(1u << 9));
    mip = read_mip();
    report("mip.SEIP clears again", (mip & (1u << 9)) == 0u);

    /* ---- 3. mip.SEIP, the hardware half ---- */
    GPIO_DIR = 0xFFFFu;
    GPIO_IP = 0xFFFFu;      /* clear anything latched already */
    GPIO_IE  = 0x0001u;
    report("no interrupt pending yet", (read_mip() & (1u << 9)) == 0u);

    /* This is the check that says context 1's line is wired to SEIP and not
     * merely computed: nothing writes mip here. */
    GPIO_OUT = 0x0001u;
    report("PLIC context 1 raises SEIP", wait_seip(1, 1000u));

    /* Put it back so S-mode can take the *same* interrupt deliberately.
     * Checking that it *drops* matters as much as checking it rises: while
     * the rise was failing, this check was passing vacuously, on a bit that
     * had never been set. */
    GPIO_OUT = 0x0000u;
    GPIO_IP = 0xFFFFu;
    report("SEIP drops when cleared", wait_seip(0, 1000u));

    /* ---- 3b. the read-modify-write carve-out ----
     *
     * "Only the software-writable SEIP bit participates in the
     * read-modify-write sequence of a CSRRS or CSRRC instruction" - the
     * privileged spec, on mip. The csrc below is OpenSBI's timer handler in
     * miniature: an RMW on mip that has nothing to do with SEIP, issued at a
     * moment when the PLIC's line happens to be high.
     *
     * Without the carve-out the RMW's old value is the OR, so bit 9 writes
     * back as 1 into the software half - where nothing ever clears it,
     * because every later RMW reads the stuck bit back and rewrites it. From
     * then on mip.SEIP is 1 no matter what the PLIC says, and an S-mode
     * kernel takes an external trap, claims 0, returns, and takes it again,
     * forever: 87,339 spurious traps in one 400M-cycle Linux boot. Whether a
     * given build storms depends on whether *some* mip RMW in a 10^8-cycle
     * boot lands inside *some* cycles-wide window where the line is high -
     * which is why the storm kept being attributed to whatever RTL change
     * most recently reshuffled the timing, rather than to the CSR file.
     *
     * Sections 2 and 3 pass on RTL with this bug: 2 exercises the software
     * half with the line low, 3 the hardware half with the software half
     * clear. Only both at once - the line high *during* the RMW - reaches
     * it. */
    GPIO_OUT = 0x0001u;
    report("line high again, for the RMW", wait_seip(1, 1000u));

    __asm__ volatile ("csrc mip, %0" :: "r"(1u << 5));   /* STIP - not SEIP */

    GPIO_OUT = 0x0000u;
    GPIO_IP = 0xFFFFu;
    report("RMW under a high line: no latch", wait_seip(0, 1000u));

    /* ---- 4. delivery to S-mode ---- */
    /* Delegate the supervisor external interrupt, point stvec at the handler,
     * enable SEIE in mie and SIE in mstatus (which is sstatus.SIE seen from
     * M-mode), then drop to S-mode. */
    __asm__ volatile ("csrs mideleg, %0" :: "r"(1u << 9));
    __asm__ volatile ("csrw stvec, %0"   :: "r"(s_irq_handler));
    __asm__ volatile ("csrs mie, %0"     :: "r"(1u << 9));
    __asm__ volatile ("csrs mstatus, %0" :: "r"(1u << 1));   /* SIE */

    put_str("  entering S-mode\n\n");

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
