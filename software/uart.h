#ifndef UART_H
#define UART_H

/* Thin driver over rtl/uart.v's memory-mapped registers - both
 * syscalls.c (for printf/scanf, via _write/_read) and any code that
 * wants the peripheral directly go through these same three functions. */

void uart_putc(char c);
int  uart_getc(void);
int  uart_rx_ready(void);

#endif
