/* First-stage bootloader, executed straight out of the boot ROM at the
 * reset vector.
 *
 * Job: bring up the console, initialize the SD card over SPI, pull the
 * program image off it into RAM, and jump to it. This is the standard SoC
 * boot structure in miniature - the ROM is small, fixed at synthesis time,
 * and knows nothing about the program except where to find it and where to
 * put it.
 *
 * Deliberately freestanding: no libc, no printf, no .data. Everything it
 * prints is a string constant that stays in ROM (readable directly, since
 * the SoC has one unified address space), and the only RAM it touches is its
 * own stack and the image it is loading. That keeps the ROM small and means
 * the loader can't be broken by a program image that hasn't been copied in
 * yet.
 *
 * Every failure below prints a reason and then stops. On a bench with no
 * serial cable that is invisible, so each step also publishes a two-bit
 * stage code through BOOT_STAGE_SET, which fpga/soc_fpga.v shows on
 * led[1:0]. Whatever is left displayed is the step that did not finish. See
 * soc.h for the codes.
 */
#include <stdint.h>
#include "soc.h"

static void uart_putc(char c) {
    while (!(UART_LSR & UART_LSR_THRE)) { }
    UART_THR = (uint32_t)(unsigned char)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void uart_puthex(uint32_t v) {
    static const char digits[] = "0123456789ABCDEF";
    int i;
    uart_puts("0x");
    for (i = 28; i >= 0; i -= 4)
        uart_putc(digits[(v >> i) & 0xF]);
}

/* ---- SPI primitives ---- */

/* One byte out, one byte in. The SPI peripheral's DATA write blocks on the
 * bus until the transfer completes, so there is no status polling here - the
 * store simply doesn't retire until the byte has been shifted. */
static uint8_t spi_xfer(uint8_t v) {
    SPI_DATA = v;
    return (uint8_t)SPI_DATA;
}

/* Chip select, preserving the clock divider.
 *
 * This used to write SPI_CTRL_DIV(0) unconditionally, which meant every
 * chip-select change silently reset SCK to its maximum. Read-modify-write
 * instead - CTRL reads back - so the two settings are independent and no
 * static state is needed to remember the current speed (this is a
 * freestanding ROM with no .data). */
static void spi_cs(int assert_cs) {
    uint32_t ctrl = SPI_CTRL & ~SPI_CTRL_CS_ASSERT;
    if (assert_cs) ctrl |= SPI_CTRL_CS_ASSERT;
    SPI_CTRL = ctrl;
}

static void spi_set_div(uint32_t div) {
    SPI_CTRL = (SPI_CTRL & SPI_CTRL_CS_ASSERT) | SPI_CTRL_DIV(div);
}

/* Send a command frame and return the R1 response byte.
 *
 * A card may take a few byte-times to answer (the NCR window), so poll for
 * the first byte with bit 7 clear rather than assuming the response is
 * immediate. */
static uint8_t sd_cmd(uint8_t cmd, uint32_t arg, uint8_t crc) {
    int i;
    uint8_t r;

    spi_xfer(0xFF);
    spi_xfer(0x40 | cmd);
    spi_xfer((uint8_t)(arg >> 24));
    spi_xfer((uint8_t)(arg >> 16));
    spi_xfer((uint8_t)(arg >> 8));
    spi_xfer((uint8_t)arg);
    spi_xfer(crc);

    for (i = 0; i < 16; i++) {
        r = spi_xfer(0xFF);
        if ((r & 0x80) == 0) return r;
    }
    return 0xFF;
}

/* Bring the card up.
 *
 * The clock rate matters here and is not a performance question. The SD
 * physical-layer spec requires SCK to stay within 100-400 kHz from power-up
 * until initialization completes; a card clocked faster during this window is
 * entitled to ignore the host, and real ones do. This code originally ran the
 * whole sequence at the divider's maximum - f_clk/2, megahertz - and worked
 * only because sim/sd_card_model.v has no timing requirements at all. That
 * model now rejects an out-of-spec init clock, so this cannot silently
 * regress.
 *
 * Slow for the handshake, fast for bulk transfer once the card is ready. */
static int sd_init(void) {
    int i;
    uint8_t r;

    spi_set_div(SD_INIT_DIV);

    /* Wake-up clocks with CS deasserted. The spec minimum is 74; this sends
     * 128, because real cards are happier with more and the cost is
     * microseconds. Simulation never cared - sim/sd_card_model.v has no
     * power-up state to come out of - which is exactly why the original 80
     * went unquestioned. */
    spi_cs(0);
    for (i = 0; i < 16; i++) spi_xfer(0xFF);

    spi_cs(1);

    /* CMD0, retried. A real card frequently ignores the first one or two
     * after power-up, and a host that gives up after one attempt reports "no
     * card" for a card that is present and about to be perfectly fine. The
     * model answers immediately, so one attempt always sufficed in
     * simulation. CMD0 needs a real CRC7 - it is sent before CRC checking is
     * turned off.
     *
     * 0xFF back means the card did not respond at all (MISO idles high
     * through its pull-up); 0x01 is the idle state we want. Anything else is
     * a card that answered but is unhappy. */
    for (i = 0; i < 10; i++) {
        r = sd_cmd(0, 0x00000000u, 0x95);
        if (r == 0x01) break;
        /* A few more clocks between attempts; some cards need the idle time. */
        spi_xfer(0xFF);
    }
    if (r != 0x01) {
        uart_puts("  CMD0 failed after 10 tries: ");
        uart_puthex(r);
        uart_puts(r == 0xFF ? "  (no response at all - card absent,\r\n"
                              "     not seated, or not SPI-capable)\r\n"
                            : "  (card answered but not idle)\r\n");
        return -1;
    }

    /* CMD8: 2.7-3.6V, check pattern 0xAA. Response is R7 - R1 plus 4 bytes. */
    r = sd_cmd(8, 0x000001AAu, 0x87);
    if (r != 0x01) { uart_puts("  CMD8 failed: "); uart_puthex(r); uart_puts("\r\n"); return -1; }
    for (i = 0; i < 4; i++) spi_xfer(0xFF);

    /* ACMD41 until the card leaves the idle state. */
    for (i = 0; i < 1000; i++) {
        sd_cmd(55, 0x00000000u, 0x65);
        r = sd_cmd(41, 0x40000000u, 0x77);
        if (r == 0x00) break;
    }
    if (r != 0x00) { uart_puts("  ACMD41 failed\r\n"); return -1; }

    /* CMD58 (READ_OCR): confirm CCS, i.e. that CMD17 takes a block number
     * rather than a byte offset. */
    r = sd_cmd(58, 0x00000000u, 0xFD);
    if (r != 0x00) { uart_puts("  CMD58 failed\r\n"); return -1; }
    for (i = 0; i < 4; i++) spi_xfer(0xFF);

    /* Initialized: the 400 kHz ceiling no longer applies, so shift up for the
     * block reads that follow. Everything above this point is a few hundred
     * bytes; everything below it is the whole program image. */
    spi_set_div(SD_FAST_DIV);

    return 0;
}

/* Read one 512-byte block into `dst`. */
static int sd_read_block(uint32_t block, uint8_t *dst) {
    int i;
    uint8_t r;

    r = sd_cmd(17, block, 0xFF);
    if (r != 0x00) return -1;

    /* Wait for the start-of-block token. */
    for (i = 0; i < 2048; i++) {
        r = spi_xfer(0xFF);
        if (r == 0xFE) break;
        if (r != 0xFF) return -1;   /* an error token */
    }
    if (r != 0xFE) return -1;

    for (i = 0; i < (int)SD_BLOCK_SIZE; i++)
        dst[i] = spi_xfer(0xFF);

    spi_xfer(0xFF);   /* CRC16, not checked */
    spi_xfer(0xFF);

    return 0;
}

/* Point mtvec at the ROM's handler, so a fault in the loaded program is
 * reported rather than silently restarting the machine. The program is free
 * to install its own vector afterwards - software/soc/main.c does - and this
 * only covers the window before it does. */
extern void rom_trap_vector(void);
static void install_rom_trap_vector(void) {
    __asm__ volatile ("csrw mtvec, %0" :: "r"((uintptr_t)&rom_trap_vector));
}

/* Reached from rom_trap_vector when the loaded program faults before it has
 * installed its own handler. Prints what happened and stops - there is
 * nothing sensible to resume. */
void rom_trap_report(void);
void rom_trap_report(void) {
    uint32_t mcause, mepc, mtval;
    __asm__ volatile ("csrr %0, mcause" : "=r"(mcause));
    __asm__ volatile ("csrr %0, mepc"   : "=r"(mepc));
    __asm__ volatile ("csrr %0, mtval"  : "=r"(mtval));

    uart_puts("\r\n*** TRAP in the loaded program ***\r\n");
    uart_puts("  mcause "); uart_puthex(mcause);
    /* The causes this is most likely to see, spelled out - looking them up
     * is a detour when you are stood at a bench. */
    switch (mcause) {
        case 0:  uart_puts("  instruction address misaligned"); break;
        case 1:  uart_puts("  instruction access fault");       break;
        case 2:  uart_puts("  ILLEGAL INSTRUCTION");            break;
        case 4:  uart_puts("  load address misaligned");        break;
        case 5:  uart_puts("  load access fault");              break;
        case 6:  uart_puts("  store/AMO address misaligned");   break;
        case 7:  uart_puts("  store/AMO access fault");         break;
        case 11: uart_puts("  environment call from M-mode");   break;
        default: break;
    }
    uart_puts("\r\n  mepc   "); uart_puthex(mepc);
    uart_puts("   <- the faulting instruction\r\n");
    uart_puts("  mtval  "); uart_puthex(mtval);
    uart_puts("   <- faulting address, or the instruction word\r\n");
    for (;;) { }
}


/* ---- UART image loader --------------------------------------------------
 *
 * See soc.h for the protocol. This is what lets a program run out of external
 * SDRAM on a board: nothing else can put one there, because a bitstream
 * initialises block RAM at configuration time and SDRAM comes up empty.
 */

#define LE32(p) ((uint32_t)(p)[0]        | ((uint32_t)(p)[1] << 8) | \
                 ((uint32_t)(p)[2] << 16) | ((uint32_t)(p)[3] << 24))

static uint32_t rdcycle(void) {
    uint32_t v;
    __asm__ volatile ("rdcycle %0" : "=r"(v));
    return v;
}

/* Receive one byte, or give up after `ms`. Returns -1 on timeout.
 *
 * `rdcycle` is 64-bit architecturally and this reads the low half only, which
 * wraps every ~172 seconds at 25 MHz. Unsigned subtraction makes the wrap
 * harmless for any interval shorter than that, and every interval here is
 * measured in milliseconds. */
static int uart_getc_timeout(uint32_t ms) {
    uint32_t start = rdcycle();
    uint32_t limit = ms * (CPU_HZ / 1000u);
    while ((rdcycle() - start) < limit) {
        if (UART_LSR & UART_LSR_DR)
            return (int)(UART_RBR & 0xFFu);
    }
    return -1;
}

/* CRC32, the ordinary reflected one (poly 0xEDB88320), computed a bit at a
 * time. No table: 1 KB of ROM matters here and 8 iterations per byte does
 * not, because the per-chunk acknowledgement means the loader is never
 * racing the line. */
static uint32_t crc32_step(uint32_t crc, uint8_t b) {
    int k;
    crc ^= b;
    for (k = 0; k < 8; k++)
        crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(crc & 1u)));
    return crc;
}

/* Where an image is allowed to land. Block RAM and SDRAM only - a header that
 * named the ROM, a peripheral or nothing at all would otherwise be obeyed,
 * and the failure would be a board that writes a UART register 100,000 times
 * and then jumps into space. */
static int uartload_addr_ok(uint32_t addr, uint32_t len) {
    uint32_t end;
    if (len == 0u) return 0;
    end = addr + len;
    if (end < addr) return 0;                                   /* wrapped */
    if (addr >= RAM_BASE   && end <= RAM_BASE   + RAM_SIZE)   return 1;
    if (addr >= SDRAM_BASE && end <= SDRAM_BASE + SDRAM_SIZE) return 1;
    return 0;
}

/* Returns the entry address, or 0 if no host knocked. Anything that goes
 * wrong *after* a knock prints a reason and stops, rather than falling
 * through to the card: at that point a host is definitely there, definitely
 * trying to load something, and silently booting something else instead is
 * the least useful thing this could do. */
static uint32_t uartload(void) {
    uint8_t  hdr[16];
    uint32_t magic, addr, len, want_crc, crc = 0xFFFFFFFFu;
    uint32_t got, i;
    uint8_t *dst;
    int c;

    /* 1. the knock */
    c = uart_getc_timeout(UARTLOAD_WINDOW_MS);
    if (c != (int)UARTLOAD_PROBE) return 0u;
    uart_putc((char)UARTLOAD_ACK);

    /* **Nothing is printed from here until the transfer is over.**
     *
     * The console and the protocol share one wire, and the host reads the
     * next byte after each chunk expecting an acknowledgement. A progress
     * message in between would arrive first and be read as one.
     *
     * So during a transfer this ROM emits acknowledgements and nothing else.
     * Every failure below sends its NAK *before* its explanation, so the host
     * sees the NAK where it is looking for it and a human reads the reason on
     * the console afterwards.
     *
     * The ordering is still what makes a failure legible, but it is no longer
     * what makes the protocol unambiguous - UARTLOAD_ACK and UARTLOAD_NAK are
     * ASCII control codes now, which nothing here ever prints. This comment
     * used to justify the rule by observing that "UART LOAD FAILED" contains
     * the old NAK byte 'E'. That was true and it was the smaller half of the
     * problem: the old ACK was 'K', and "KB" appears in the console output of
     * every program in this repository, so console text could impersonate an
     * *acknowledgement* to a host that had not even reached this code. See
     * software/soc/soc.h. */

    /* 2. the header.
     *
     * Skip any further probes first. The host knocks repeatedly and cannot
     * know the exact moment we answered, so one more is very likely already
     * on the wire - and would otherwise be read as the magic's first byte,
     * which is precisely how this failed the first time it ran. The header
     * begins with 'S' and a probe is 'U', so they cannot be confused. */
    do {
        c = uart_getc_timeout(UARTLOAD_BYTE_TIMEOUT_MS);
        if (c < 0) {
            uart_putc((char)UARTLOAD_NAK);
            uart_puts("UART LOAD FAILED: header timed out\r\n");
            for (;;) { }
        }
    } while (c == (int)UARTLOAD_PROBE);
    hdr[0] = (uint8_t)c;

    for (i = 1; i < sizeof(hdr); i++) {
        c = uart_getc_timeout(UARTLOAD_BYTE_TIMEOUT_MS);
        if (c < 0) {
            uart_putc((char)UARTLOAD_NAK);
            uart_puts("UART LOAD FAILED: header timed out\r\n");
            for (;;) { }
        }
        hdr[i] = (uint8_t)c;
    }
    magic    = LE32(hdr + 0);
    addr     = LE32(hdr + 4);
    len      = LE32(hdr + 8);
    want_crc = LE32(hdr + 12);

    if (magic != UARTLOAD_MAGIC) {
        uart_putc((char)UARTLOAD_NAK);
        uart_puts("UART LOAD FAILED: bad magic ");
        uart_puthex(magic);
        uart_puts("\r\n");
        for (;;) { }
    }
    if (!uartload_addr_ok(addr, len)) {
        uart_putc((char)UARTLOAD_NAK);
        uart_puts("UART LOAD FAILED: ");
        uart_puthex(len);
        uart_puts(" bytes at ");
        uart_puthex(addr);
        uart_puts(" is not inside RAM or SDRAM\r\n");
        for (;;) { }
    }
    uart_putc((char)UARTLOAD_ACK);

    /* 3. the image, one byte at a time, every one acknowledged.
     *
     * Stop-and-wait, because rtl/uart.v's receiver is one byte deep - see
     * soc.h. The acknowledgement is what stops the host sending byte N+1
     * before byte N has been read out of the register, and it is the only
     * thing that makes this independent of how fast the line is relative to
     * this loop. */
    BOOT_STAGE_SET(BOOT_STAGE_LOAD);
    dst = (uint8_t *)(uintptr_t)addr;
    for (got = 0; got < len; got++) {
        c = uart_getc_timeout(UARTLOAD_BYTE_TIMEOUT_MS);
        if (c < 0) {
            uart_puts("UART LOAD FAILED: stopped after ");
            uart_puthex(got);
            uart_puts(" of ");
            uart_puthex(len);
            uart_puts(" bytes\r\n");
            for (;;) { }
        }
        dst[got] = (uint8_t)c;
        crc = crc32_step(crc, (uint8_t)c);
        uart_putc((char)UARTLOAD_ACK);
    }
    crc ^= 0xFFFFFFFFu;

    /* 4. the check. A serial line with no parity and no flow control will
     * eventually hand over a byte that is not the one that was sent, and a
     * loader that jumps into it anyway turns that into a wild branch. */
    if (crc != want_crc) {
        uart_putc((char)UARTLOAD_NAK);
        uart_puts("UART LOAD FAILED: CRC ");
        uart_puthex(crc);
        uart_puts(" want ");
        uart_puthex(want_crc);
        uart_puts("\r\n");
        for (;;) { }
    }
    uart_putc((char)UARTLOAD_ACK);

    /* The wire is ours again. */
    uart_puts("\r\nUART loader: ");
    uart_puthex(len);
    uart_puts(" bytes at ");
    uart_puthex(addr);
    uart_puts(", CRC ok\r\n  starting program\r\n\r\n");
    return addr;
}

void main(void) {
    uint8_t *hdr = (uint8_t *)(uintptr_t)PROGRAM_LOAD_ADDR;  /* scratch */
    uint8_t *dst;
    uint32_t magic, length, blocks, i;
    void (*entry)(void);

    BOOT_STAGE_SET(BOOT_STAGE_EARLY);

    uart_puts("\r\n=== RV32IMA SoC boot ROM ===\r\n");

    /* If RAM already holds a program, run it and skip the card entirely.
     *
     * This exists for hardware bring-up. The SD path is the last unproven
     * part of the system, and until it works it blocks testing everything
     * that comes after it - RAM, atomics, traps, timers, GPIO, the
     * framebuffer. Preloading the image into the bitstream (see
     * RAM_INIT_FILE / PRELOAD_RAM in fpga/soc_fpga.v) removes the card from
     * the picture so the rest can be exercised on real silicon.
     *
     * The test is simply whether the first word is a plausible instruction.
     * Block RAM with no init data comes up all zeros, and 0x00000000 is not
     * a legal RISC-V instruction, so zero means "nothing preloaded" and
     * anything else means somebody put a program there. 0xFFFFFFFF is
     * rejected too - it is not legal either, and it is what uninitialized or
     * failed-to-load memory tends to read as.
     *
     * On a normal build nothing is preloaded, this reads zero, and the SD
     * path runs exactly as before. */
    {
        uint32_t first = *(volatile uint32_t *)(uintptr_t)PROGRAM_LOAD_ADDR;
        if (first != 0x00000000u && first != 0xFFFFFFFFu) {
            uart_puts("RAM already holds a program (first word ");
            uart_puthex(first);
            uart_puts(")\r\n  skipping SD, starting it\r\n\r\n");
            install_rom_trap_vector();
            entry = (void (*)(void))(uintptr_t)PROGRAM_LOAD_ADDR;
            entry();
            for (;;) { }
        }
    }

    /* A host on the serial line outranks the card. It is the only way to get
     * a program into external SDRAM - see soc.h - and if somebody is actively
     * trying to load one, booting whatever happens to be on an SD card
     * instead would be the wrong answer. Costs one short window on every boot
     * that nobody knocks at. */
    {
        uint32_t uart_entry = uartload();
        if (uart_entry != 0u) {
            install_rom_trap_vector();
            /* Same reason as the card path below: the image arrived through
             * the data side and is about to be fetched. */
            __asm__ volatile ("fence.i" ::: "memory");
            entry = (void (*)(void))(uintptr_t)uart_entry;
            entry();
            for (;;) { }
        }
    }

    uart_puts("SPI/SD init...\r\n");

    BOOT_STAGE_SET(BOOT_STAGE_SDINIT);
    if (sd_init() != 0) {
        uart_puts("BOOT FAILED: no SD card\r\n");
        for (;;) { }
    }
    uart_puts("  card ready\r\n");

    /* Block 0 is the image header. Read it into the load area as scratch -
     * it is about to be overwritten by the image itself anyway. */
    BOOT_STAGE_SET(BOOT_STAGE_HEADER);
    if (sd_read_block(SDIMG_HDR_BLOCK, hdr) != 0) {
        uart_puts("BOOT FAILED: header read error\r\n");
        for (;;) { }
    }

    magic  = (uint32_t)hdr[0] | ((uint32_t)hdr[1] << 8) |
             ((uint32_t)hdr[2] << 16) | ((uint32_t)hdr[3] << 24);
    length = (uint32_t)hdr[4] | ((uint32_t)hdr[5] << 8) |
             ((uint32_t)hdr[6] << 16) | ((uint32_t)hdr[7] << 24);

    if (magic != SDIMG_MAGIC) {
        uart_puts("BOOT FAILED: bad magic ");
        uart_puthex(magic);
        uart_puts("\r\n");
        for (;;) { }
    }

    blocks = (length + SD_BLOCK_SIZE - 1) / SD_BLOCK_SIZE;
    uart_puts("  image ");
    uart_puthex(length);
    uart_puts(" bytes -> ");
    uart_puthex(PROGRAM_LOAD_ADDR);
    uart_puts("\r\n");

    BOOT_STAGE_SET(BOOT_STAGE_LOAD);
    dst = (uint8_t *)(uintptr_t)PROGRAM_LOAD_ADDR;
    for (i = 0; i < blocks; i++) {
        if (sd_read_block(SDIMG_DATA_BLOCK + i, dst + i * SD_BLOCK_SIZE) != 0) {
            uart_puts("BOOT FAILED: block read error\r\n");
            for (;;) { }
        }
    }

    spi_cs(0);

    uart_puts("  loaded, starting program\r\n\r\n");

    /* The program was just written to RAM through the *data* path, and we are
     * about to execute it. RISC-V requires FENCE.I between the two: nothing
     * makes a store visible to instruction fetch on its own. rtl/soc/cpu_wb.v
     * holds a direct-mapped instruction cache, and `fence_i` is what clears
     * it.
     *
     * This was missing while that cache was a single tagged word, and was
     * safe only by accident - the loader never *fetched* from the addresses
     * it was writing, so there was nothing stale to serve. That is a property
     * of this loader's control flow rather than of the architecture, and it
     * stops being true the moment anything executes from RAM before the copy
     * (a resident second-stage loader would do it). Correct by construction
     * costs one instruction here. */
    __asm__ volatile ("fence.i" ::: "memory");

    entry = (void (*)(void))(uintptr_t)PROGRAM_LOAD_ADDR;
    entry();

    for (;;) { }
}
