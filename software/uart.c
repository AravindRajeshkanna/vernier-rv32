#include <stdint.h>
#include "uart.h"

/* Must match rtl/top.v's UART_BASE_HI decode window (0x0400_0000) and
 * rtl/uart.v's register map. */
#define UART_BASE   ((volatile uint32_t *)0x04000000)
#define UART_TXDATA (UART_BASE[0])
#define UART_RXDATA (UART_BASE[1])
#define UART_STATUS (UART_BASE[2])

#define STATUS_TX_BUSY  (1u << 0)
#define STATUS_RX_VALID (1u << 1)

void uart_putc(char c) {
    while (UART_STATUS & STATUS_TX_BUSY) { }
    UART_TXDATA = (uint32_t)(unsigned char)c;
}

int uart_rx_ready(void) {
    return (UART_STATUS & STATUS_RX_VALID) != 0;
}

int uart_getc(void) {
    while (!(UART_STATUS & STATUS_RX_VALID)) { }
    return (int)(UART_RXDATA & 0xFF);
}
