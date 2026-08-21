#include <stdint.h>
#include "uart.h"

/* Must match rtl/top.v's UART_BASE_HI decode window (0x0400_0000) and
 * rtl/uart.v's register map. */
#define UART_BASE   ((volatile uint32_t *)0x04000000)
/* ns16550, reg-shift 2 - see rtl/uart.v. Word indices here, so [n] is
 * register n. */
#define UART_THR (UART_BASE[0])
#define UART_RBR (UART_BASE[0])
#define UART_LSR (UART_BASE[5])
#define LSR_DR   0x01u
#define LSR_THRE 0x20u


void uart_putc(char c) {
    while (!(UART_LSR & LSR_THRE)) { }
    UART_THR = (uint32_t)(unsigned char)c;
}

int uart_rx_ready(void) {
    return (UART_LSR & LSR_DR) != 0;
}

int uart_getc(void) {
    while (!(UART_LSR & LSR_DR)) { }
    return (int)(UART_RBR & 0xFF);
}
