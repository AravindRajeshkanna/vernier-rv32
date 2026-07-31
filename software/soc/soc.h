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
#define RAM_BASE    0x80000000u
#define RAM_SIZE    0x00040000u   /* 256 KB - must match soc_top.v RAM_BYTES */

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

/* ---- SPI (rtl/soc/wb_spi.v) ---- */
#define SPI_CTRL   REG32(SPI_BASE + 0x00)
#define SPI_DATA   REG32(SPI_BASE + 0x04)
#define SPI_STATUS REG32(SPI_BASE + 0x08)
#define SPI_CTRL_CS_ASSERT (1u << 0)
#define SPI_CTRL_DIV(n)    (((n) & 0xFFu) << 8)

/* ---- SD card image layout ----
 * Block 0 is a header written by software/soc/mkcard.py; the program image
 * itself starts at block 1. The boot ROM checks the magic and uses the
 * length rather than hardcoding an image size. */
#define SDIMG_MAGIC       0x31434F53u   /* 'S','O','C','1' little-endian */
#define SDIMG_HDR_BLOCK   0u
#define SDIMG_DATA_BLOCK  1u
#define SD_BLOCK_SIZE     512u

#endif /* SOC_H */
