/* Console output for the RAM program, without libc.
 *
 * These touch nothing but the UART's TX register: no heap, no FILE, no
 * reentrancy structure, no state of any kind. That matters in two places.
 * The acceptance test uses them because a test of the SoC should not be able
 * to fail inside the C library (software/soc/main.c has the history). The
 * trap reporter uses them because it runs after something has already gone
 * wrong, and the one thing it must not do is depend on the machine still
 * being in good order.
 *
 * Line endings: put_char passes bytes through untouched, put_str turns '\n'
 * into CRLF so a real terminal behaves.
 */
#ifndef CONSOLE_H
#define CONSOLE_H

#include <stdint.h>

void put_char(char c);
void put_str(const char *s);
void put_pad(const char *s, int width);   /* left-justified in `width` cols */
void put_dec(int v);
void put_hex(uint32_t v);

#endif /* CONSOLE_H */
