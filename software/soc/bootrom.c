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
    while (UART_STATUS & UART_TX_BUSY) { }
    UART_TXDATA = (uint32_t)(unsigned char)c;
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

    entry = (void (*)(void))(uintptr_t)PROGRAM_LOAD_ADDR;
    entry();

    for (;;) { }
}
