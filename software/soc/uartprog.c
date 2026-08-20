/* A small program that exists to be sent over the wire.
 *
 * `make sim_uartload` proves the boot ROM's UART loader end to end, and what
 * that test is about is the *protocol* - the knock, the header, the CRC, the
 * per-chunk acknowledgement - not how much SDRAM works. Sending
 * software/soc/sdramtest.c's 99 KB at four clocks per bit costs four million
 * simulation cycles before anything is checked, and `make sim_sdramcheck` and
 * `make sim_sdramboot` already cover the size and the memory respectively.
 * So this is deliberately tiny, and each layer stays fast enough to run.
 *
 * On a *board* the image to send is the big one:
 *
 *   ./software/soc/uartload.py /dev/cu.usbserial-XXXX software/soc/sdramtest.bin
 *
 * What it checks is only what the loader is responsible for:
 *
 *   1. it is executing from SDRAM, not from the block RAM the ROM lives
 *      beside - the linker put it at 0x9000_0000 and the ROM jumped there
 *   2. its own .rodata reads back correctly, so the bytes that arrived over
 *      the wire are the bytes that were sent. The CRC already said so; this
 *      says it again from the other side, after the image has been through
 *      SDRAM rather than only through the UART
 *   3. block RAM still works, which is where the verdict goes
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

extern char _start[];

/* Each word holds its own index, so a byte that arrived wrong, a halfword in
 * the wrong SDRAM column, or an image loaded at the wrong offset all produce
 * a word that does not match. 256 words is enough to cross a row boundary
 * (512 columns x 2 bytes = 1 KB) without making the image big. */
#define TABLE_WORDS 256
static const uint32_t table[TABLE_WORDS] = {
#define R4(n)   (n)+0, (n)+1, (n)+2, (n)+3
#define R16(n)  R4((n)), R4((n)+4), R4((n)+8), R4((n)+12)
#define R64(n)  R16((n)), R16((n)+16), R16((n)+32), R16((n)+48)
    R64(0), R64(64), R64(128), R64(192)
};

int main(void)
{
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;
    volatile uint32_t *ram    = (volatile uint32_t *)(RAM_BASE + 0x100u);
    int failures = 0;
    uint32_t i;

    trap_install();

    put_str("\n=== loaded over UART, running from SDRAM ===\n");
    put_str("_start is at ");
    put_hex((uint32_t)(uintptr_t)_start);
    put_str("\n\n");

    if ((uint32_t)(uintptr_t)_start < SDRAM_BASE) {
        put_str("  running from SDRAM        FAILED\n");
        failures++;
    } else {
        put_str("  running from SDRAM        ok\n");
    }

    for (i = 0; i < TABLE_WORDS; i++) {
        if (table[i] != i) {
            put_str("  table word ");
            put_dec((int)i);
            put_str(" reads ");
            put_hex(table[i]);
            put_str("\n");
            failures++;
            break;
        }
    }
    put_str("  image arrived intact      ");
    put_str(failures ? "FAILED\n" : "ok\n");

    *ram = 0xC0FFEE00u;
    put_str("  block RAM still reachable ");
    if (*ram == 0xC0FFEE00u) {
        put_str("ok\n");
    } else {
        put_str("FAILED\n");
        failures++;
    }

    put_str("\n");
    if (failures == 0) {
        put_str("UART-LOAD: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("UART-LOAD: FAIL\n");
        *result = TEST_RESULT_FAIL;
    }

    for (;;) { }
}
