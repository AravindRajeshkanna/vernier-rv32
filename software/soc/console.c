/* See console.h for why these exist rather than printf. */
#include <stdint.h>
#include "soc.h"
#include "console.h"

void put_char(char c) {
    while (UART_STATUS & UART_TX_BUSY) { }
    UART_TXDATA = (uint32_t)(unsigned char)c;
}

void put_str(const char *s) {
    while (*s) {
        if (*s == '\n') put_char('\r');
        put_char(*s++);
    }
}

void put_pad(const char *s, int width) {
    int n = 0;
    while (s[n]) n++;
    put_str(s);
    while (n++ < width) put_char(' ');
}

void put_dec(int v) {
    char buf[12];
    int i = 0;
    if (v < 0) { put_char('-'); v = -v; }
    if (v == 0) { put_char('0'); return; }
    while (v > 0) { buf[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i > 0) put_char(buf[--i]);
}

void put_hex(uint32_t v) {
    static const char digits[] = "0123456789ABCDEF";
    int i;
    put_str("0x");
    for (i = 28; i >= 0; i -= 4) put_char(digits[(v >> i) & 0xF]);
}
