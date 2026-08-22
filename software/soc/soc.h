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
/* The standard PLIC register map, which rtl/plic.v now implements. These
 * offsets are the spec's, not this project's: a stock driver - OpenSBI's,
 * Linux's - computes exactly these from the base address in the device tree,
 * which is the whole reason the layout changed.
 *
 * Contexts: 0 is hart 0 M-mode, 1 is hart 0 S-mode. dts/soc.dts declares the
 * same pairing in `interrupts-extended`, and nothing checks that the two
 * agree - practices.md section 11. Safe direction of error does not really
 * exist here: getting it wrong points a driver at the other privilege
 * level's threshold register, which fails silently by never delivering. */
#define PLIC_PRIORITY(src)      (PLIC_BASE + 0x000000u + 4u * (src))
#define PLIC_PENDING            (PLIC_BASE + 0x001000u)
#define PLIC_ENABLE(ctx)        (PLIC_BASE + 0x002000u + 0x80u * (ctx))
#define PLIC_THRESHOLD(ctx)     (PLIC_BASE + 0x200000u + 0x1000u * (ctx))
#define PLIC_CLAIM(ctx)         (PLIC_BASE + 0x200004u + 0x1000u * (ctx))
#define PLIC_CTX_M   0
#define PLIC_CTX_S   1
#define UART_BASE_A 0x04000000u
#define GPIO_BASE   0x05000000u
#define SPI_BASE    0x06000000u
#define FB_BASE     0x07000000u
#define RAM_BASE    0x80000000u
/* External SDRAM. Must match the S_SDRAM base byte in rtl/soc/soc_top.v and
 * the ORIGIN addresses in software/soc/link_sdram.ld. The window is the
 * whole 32 MB part: wb_interconnect.v decodes addr[31:24] through a per-slave
 * mask, and soc_top.v gives this slave 0xFE, so it answers to 0x90 and 0x91
 * alike. It was 16 MB while the decode was a bare equality. Safe direction of
 * error: a program linked beyond this lands in unmapped space, which the
 * interconnect acks with zeros, so the CPU executes a zero word and traps
 * immediately rather than aliasing back onto itself. */
#define SDRAM_BASE  0x90000000u
#define SDRAM_SIZE  0x02000000u
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
/* ns16550, reg-shift 2 (register n at offset 4n) - see rtl/uart.v. These
 * names are the datasheet's, not this project's, which is the point: the
 * whole reason the map changed is that OpenSBI and Linux already have
 * drivers for it. dts/soc.dts declares the same `reg-shift` and nothing
 * checks that the two agree - practices.md section 11. */
#define UART_RBR REG32(UART_BASE_A + 0x00)   /* read: data; write: THR   */
#define UART_THR REG32(UART_BASE_A + 0x00)
#define UART_DLL REG32(UART_BASE_A + 0x00)   /* when LCR.DLAB            */
#define UART_IER REG32(UART_BASE_A + 0x04)
#define UART_DLM REG32(UART_BASE_A + 0x04)   /* when LCR.DLAB            */
#define UART_IIR REG32(UART_BASE_A + 0x08)   /* read                     */
#define UART_FCR REG32(UART_BASE_A + 0x08)   /* write                    */
#define UART_LCR REG32(UART_BASE_A + 0x0C)
#define UART_MCR REG32(UART_BASE_A + 0x10)
#define UART_LSR REG32(UART_BASE_A + 0x14)
#define UART_MSR REG32(UART_BASE_A + 0x18)
#define UART_SCR REG32(UART_BASE_A + 0x1C)

/* LSR bits worth naming. DR says a byte is waiting in RBR; THRE says the
 * transmit holding register will accept one. */
#define UART_LSR_DR   0x01u
#define UART_LSR_OE   0x02u
#define UART_LSR_THRE 0x20u
#define UART_LSR_TEMT 0x40u
#define UART_LCR_DLAB 0x80u

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

/* ---- UART image loader ----
 *
 * How a program gets into SDRAM on a board. It is the only way, and that is
 * the point of it: a bitstream initialises block RAM at FPGA configuration
 * time, and external SDRAM comes up holding nothing, so until this existed
 * the 32 MB proven in fpga/README.md could hold data and never code.
 *
 * Protocol, host -> board unless stated. Everything little-endian.
 *
 *   1. host sends UARTLOAD_PROBE repeatedly; the ROM answers UARTLOAD_ACK
 *      once, and only inside a short window after reset (below)
 *   2. host sends the 16-byte header: magic, load address, length, CRC32
 *   3. ROM answers UARTLOAD_ACK, or UARTLOAD_NAK and a printed reason
 *   4. host sends the image **one byte at a time**, waiting for an
 *      UARTLOAD_ACK after each
 *   5. ROM checks the CRC over everything received, then jumps
 *
 * ---- Why stop-and-wait, a byte at a time ----
 *
 * Because rtl/uart.v's receiver is one byte deep: `rx_data_reg` plus a valid
 * bit, no FIFO. A byte that arrives before the previous one has been read is
 * simply lost.
 *
 * This started as 256-byte chunks with an acknowledgement after each, on the
 * reasoning that the acknowledgement removed any assumption about the
 * receiver keeping up with the line. **It did not.** It bounded the
 * assumption to one chunk and left it otherwise intact - inside a chunk the
 * host still sends continuously, and the ROM needs roughly 70 cycles a byte
 * to poll, store to SDRAM and fold the byte into a CRC. At 115200 on a 25 MHz
 * board a byte arrives every 2,170 cycles, so there is 31x of margin and it
 * works; in simulation the testbench runs the UART at four clocks per bit, a
 * byte arrives every 40 cycles, and the ROM is 1.8x too slow. The first run
 * lost bytes inside the first chunk and stalled.
 *
 * Acknowledging every byte removes the assumption instead of bounding it: the
 * host cannot send byte N+1 until byte N has been read out of the register.
 * It costs a round trip per byte - roughly 87 seconds for a 500 KB image at
 * 115200 instead of 43 - which is nothing for something run once per test
 * cycle, and it is correct at any line rate on any receiver.
 */
/* The two bytes the *board* sends are ASCII control codes, and that is the
 * whole point of them.
 *
 * They used to be 'K' and 'E'. The console and the protocol share one wire,
 * so every byte the board sends is either a protocol reply or console text,
 * and the host has nothing but the value to tell them apart. 'K' is 0x4B, and
 * the word "KB" appears in the output of every program in this repository -
 * "64 KB of RAM", "sweeping 256 KB of 32768 KB". So a host knocking at a
 * board that is *printing* rather than listening reads the 'K' of "KB" as an
 * acknowledgement, sends its header into a program that is not reading, and
 * then reports whatever came next:
 *
 *     ROM answered
 *     error: unexpected reply 0x42 ('B') after header
 *
 * which is the 'B' of "KB", and which reads as a protocol fault on a board
 * that was working correctly and running something else. It cost a bench
 * session. docs/practices.md section 36.
 *
 * 0x06 and 0x15 are ACK and NAK in ASCII, and neither this ROM nor anything
 * it loads ever prints a control character - the console emits printable
 * ASCII plus CR and LF. So a protocol byte can no longer be manufactured by
 * something printing, which is the only ambiguity that has ever bitten here.
 *
 * UARTLOAD_PROBE stays printable: it travels host->board, and the board only
 * reads it inside the loader, where console text cannot arrive. The ROM also
 * relies on it differing from the magic's first byte ('S') to skip late
 * knocks, and 'U' is as good a value for that as any. */
#define UARTLOAD_MAGIC    0x55434F53u   /* 'S','O','C','U' little-endian */
#define UARTLOAD_PROBE    0x55u         /* 'U' - host knocking            */
#define UARTLOAD_ACK      0x06u         /* ASCII ACK - never printed      */
#define UARTLOAD_NAK      0x15u         /* ASCII NAK - never printed      */

/* How long after reset the ROM listens for a knock, in milliseconds.
 *
 * Short on purpose. Every boot that is *not* loading pays it - including
 * `make sim_soc`, which goes on to the card - and the host is expected to be
 * probing continuously, so it only has to be wide enough to catch a knock,
 * not wide enough for a human to start a script. If you miss it, press reset;
 * that is the same gesture the rest of this board's bring-up already uses.
 *
 * Timed from `rdcycle` rather than the CLINT, so it needs nothing brought up
 * first and does not depend on the timebase agreeing with CPU_HZ. */
#define UARTLOAD_WINDOW_MS  20u

/* Abort a transfer that stops mid-way rather than hanging with the console
 * silent. practices.md section 13: fail fast, and say what to do. */
#define UARTLOAD_BYTE_TIMEOUT_MS 200u

/* ---- SD card image layout ----
 * Block 0 is a header written by software/soc/mkcard.py; the program image
 * itself starts at block 1. The boot ROM checks the magic and uses the
 * length rather than hardcoding an image size. */
#define SDIMG_MAGIC       0x31434F53u   /* 'S','O','C','1' little-endian */
#define SDIMG_HDR_BLOCK   0u
#define SDIMG_DATA_BLOCK  1u
#define SD_BLOCK_SIZE     512u

#endif /* SOC_H */
