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

static void spi_cs(int assert_cs) {
    uint32_t ctrl = SPI_CTRL_DIV(0);
    if (assert_cs) ctrl |= SPI_CTRL_CS_ASSERT;
    SPI_CTRL = ctrl;
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

static int sd_init(void) {
    int i;
    uint8_t r;

    /* At least 74 clocks with CS deasserted so the card can wake up. */
    spi_cs(0);
    for (i = 0; i < 10; i++) spi_xfer(0xFF);

    spi_cs(1);

    /* CMD0 needs a real CRC7 - it's sent before CRC checking is turned off. */
    r = sd_cmd(0, 0x00000000u, 0x95);
    if (r != 0x01) { uart_puts("  CMD0 failed: "); uart_puthex(r); uart_puts("\r\n"); return -1; }

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

void main(void) {
    uint8_t *hdr = (uint8_t *)(uintptr_t)PROGRAM_LOAD_ADDR;  /* scratch */
    uint8_t *dst;
    uint32_t magic, length, blocks, i;
    void (*entry)(void);

    uart_puts("\r\n=== RV32IMA SoC boot ROM ===\r\n");
    uart_puts("SPI/SD init...\r\n");

    if (sd_init() != 0) {
        uart_puts("BOOT FAILED: no SD card\r\n");
        for (;;) { }
    }
    uart_puts("  card ready\r\n");

    /* Block 0 is the image header. Read it into the load area as scratch -
     * it is about to be overwritten by the image itself anyway. */
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
