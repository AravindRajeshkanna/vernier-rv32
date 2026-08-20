/* Memory map and register definitions for the SoC build (rtl/soc/soc_top.v).
 *
 * This is the single source of truth shared by the boot ROM and the RAM
 * program. It has to stay in step with three other things by hand, since
 * nothing generates it: soc_top.v's `s_base` decode table, dts/soc.dts, and
 * the linker scripts in this directory.
 */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define ROM_BASE    0x00000000u
#define CLINT_BASE  0x02000000u
#define PLIC_BASE   0x03000000u
#define UART_BASE_A 0x04000000u
#define GPIO_BASE   0x05000000u
#define SPI_BASE    0x06000000u
#define FB_BASE     0x07000000u
#define RAM_BASE    0x80000000u
/* External SDRAM. Must match the S_SDRAM base byte in rtl/soc/soc_top.v and
 * the ORIGIN addresses in software/soc/link_sdram.ld. The window the
 * interconnect gives it is 16 MB, because wb_interconnect.v decodes
 * addr[31:24] alone; the part is 32 MB and the upper half is unreachable
 * until that decode grows a mask. Safe direction of error: a program linked
 * below this lands in unmapped space, which the interconnect acks with
 * zeros, so the CPU executes a zero word and traps immediately. */
#define SDRAM_BASE  0x90000000u
#define SDRAM_SIZE  0x01000000u
/* 64 KB. This is the size the *firmware* is built for, and it is
 * deliberately smaller than soc_top.v's 256 KB simulation default: 256 KB of
 * on-chip RAM costs 244 ECP5 block RAMs, more than the largest ECP5 has, so a
 * firmware that assumed it could never run on hardware. At 64 KB the whole
 * SoC fits an LFE5U-45F with room to spare. See fpga/README.md for the
 * measured block-RAM cost at each size. */
#define RAM_SIZE    0x00010000u

/* Low 4 KB of RAM is reserved for the boot ROM: its stack, and a result word
 * the testbench reads back directly. The loaded program starts above it. */
#define TEST_RESULT_ADDR  (RAM_BASE + 0x0000u)
#define BOOT_STACK_TOP    (RAM_BASE + 0x0FF0u)
#define PROGRAM_LOAD_ADDR (RAM_BASE + 0x1000u)

#define TEST_RESULT_PASS  0x50415353u   /* "PASS" */
#define TEST_RESULT_FAIL  0x4641494Cu   /* "FAIL" */

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

/* ---- UART (rtl/uart.v) ---- */
#define UART_TXDATA REG32(UART_BASE_A + 0x00)
#define UART_RXDATA REG32(UART_BASE_A + 0x04)
#define UART_STATUS REG32(UART_BASE_A + 0x08)
#define UART_TX_BUSY  (1u << 0)
#define UART_RX_VALID (1u << 1)

/* ---- GPIO (rtl/soc/wb_gpio.v) ---- */
#define GPIO_OUT REG32(GPIO_BASE + 0x00)
#define GPIO_IN  REG32(GPIO_BASE + 0x04)
#define GPIO_DIR REG32(GPIO_BASE + 0x08)
#define GPIO_IE  REG32(GPIO_BASE + 0x0C)
#define GPIO_IP  REG32(GPIO_BASE + 0x10)

/* Boot-stage code, shown on led[1:0] of fpga/soc_fpga.v. Every failure path
 * in the boot ROM prints to the UART and then stops, so with no serial cable
 * attached a failed boot and a good one look identical - both just sit there
 * with the heartbeat blinking. These two bits say which step was in progress
 * when things stopped.
 *
 * fpga/soc_fpga.v mirrors GPIO_OUT[1:0] onto the LEDs regardless of
 * GPIO_DIR, so this needs no pin configuration - just the write. On real
 * hardware GPIO pins 1:0 mirror the same two bits, which is harmless.
 *
 * These are *stages*, not error codes: the value left showing is the step
 * that did not finish.
 */
#define BOOT_STAGE_MASK   0x3u
#define BOOT_STAGE_EARLY  0u  /* ROM entered, console up                  */
#define BOOT_STAGE_SDINIT 1u  /* bringing up the SD card over SPI         */
#define BOOT_STAGE_HEADER 2u  /* reading and validating the image header  */
#define BOOT_STAGE_LOAD   3u  /* copying the image into RAM               */

#define BOOT_STAGE_SET(s) \
    (GPIO_OUT = (GPIO_OUT & ~BOOT_STAGE_MASK) | ((s) & BOOT_STAGE_MASK))

/* ---- SPI (rtl/soc/wb_spi.v) ---- */
#define SPI_CTRL   REG32(SPI_BASE + 0x00)
#define SPI_DATA   REG32(SPI_BASE + 0x04)
#define SPI_STATUS REG32(SPI_BASE + 0x08)
#define SPI_CTRL_CS_ASSERT (1u << 0)
#define SPI_CTRL_DIV(n)    (((n) & 0xFFu) << 8)

/* System clock, in Hz. This MUST agree with fpga/soc_fpga.v's CLK_HZ - it is
 * the same duplication hazard as RAM_SIZE vs RAM_BYTES above, and for the
 * same reason: software cannot read a synthesis parameter.
 *
 * It is only used to derive the SD initialization clock below. If you get it
 * wrong, get it wrong *high*: over-estimating makes SCK slower than intended,
 * which is harmless, while under-estimating can push the init clock above the
 * 400 kHz ceiling, which real cards reject.
 *
 * 25 MHz is the ULX3S oscillator and is what fpga/soc_fpga.v's CLK_HZ
 * defaults to. Change both together for another board.
 */
#define CPU_HZ 25000000u

/* SCK = CPU_HZ / (2 * (div + 1)).
 *
 * SD_INIT_DIV: the SD physical-layer spec requires the clock to stay in the
 * 100-400 kHz band from power-up until initialization completes (CMD0 through
 * ACMD41). A card clocked faster than that during init is entitled to ignore
 * the host entirely, and many do. This targets ~350 kHz, which stays inside
 * the band for every plausible CPU_HZ rather than sitting on the ceiling.
 *
 * SD_FAST_DIV: full speed once the card is initialized. The floor is 2, not
 * 0 - rtl/soc/wb_spi.v synchronizes MISO through two flops, so a half period
 * shorter than that samples the previous bit. 3 leaves a cycle of margin for
 * the card's own output delay. wb_spi.v fails the simulation outright if
 * firmware ever programs a divider below 2.
 */
#define SD_INIT_DIV ((CPU_HZ) / 700000u)
#define SD_FAST_DIV 3u

/* ---- Framebuffer (rtl/soc/wb_framebuffer.v) ----
 * 320x240, 8 bits per pixel, RRRGGGBB direct colour - no palette to program.
 * Pixel-doubled to a 640x480 raster on the way out.
 *
 * A pixel is one byte, so a plain store writes one; the buffer is linear with
 * no padding, so the address of (x,y) is FB_BASE + y*FB_WIDTH + x.
 *
 * These must agree with soc_top.v's FB_WIDTH/FB_HEIGHT parameters. Nothing
 * checks that they do - the same hazard as RAM_SIZE vs RAM_BYTES.
 */
#define FB_WIDTH   320u
#define FB_HEIGHT  240u
#define FB_PIXEL(x, y) (*(volatile uint8_t *)(uintptr_t)(FB_BASE + (y)*FB_WIDTH + (x)))

/* RRRGGGBB from 8-bit components, so callers can think in RGB rather than in
 * bit positions. The low bits of each component are discarded, which is what
 * 8bpp costs. */
#define FB_RGB(r, g, b) \
    ((uint8_t)((((r) & 0xE0u)) | (((g) & 0xE0u) >> 3) | (((b) & 0xC0u) >> 6)))

/* ---- SD card image layout ----
 * Block 0 is a header written by software/soc/mkcard.py; the program image
 * itself starts at block 1. The boot ROM checks the magic and uses the
 * length rather than hardcoding an image size. */
#define SDIMG_MAGIC       0x31434F53u   /* 'S','O','C','1' little-endian */
#define SDIMG_HDR_BLOCK   0u
#define SDIMG_DATA_BLOCK  1u
#define SD_BLOCK_SIZE     512u

#endif /* SOC_H */
