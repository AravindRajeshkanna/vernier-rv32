/* Minimal newlib syscall stubs for a bare-metal target with no OS behind
 * it. Only _write/_read/_sbrk are overridden with real behavior (routing
 * through the UART, and a simple bump-allocator heap); everything else
 * newlib needs resolved to link (_close/_lseek/_fstat/_isatty/_kill/
 * _getpid) gets a minimal stub sufficient to satisfy the linker and
 * behave reasonably for a single "everything is the console" file
 * descriptor - there's no real filesystem or process model here.
 */
#include <errno.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>
#include "uart.h"

extern char _end[];
extern char _stack_top[];

static char *heap_ptr = 0;

void *_sbrk(int incr) {
    if (heap_ptr == 0) heap_ptr = _end;
    char *prev = heap_ptr;
    /* Leave a little headroom below the stack rather than growing the
     * heap right up to it. Routed through uintptr_t rather than direct
     * pointer arithmetic on _stack_top - GCC otherwise treats it as an
     * array of unknown-but-assumed-huge size and flags `-4096` as an
     * out-of-bounds index. */
    if ((uintptr_t)heap_ptr + incr > (uintptr_t)_stack_top - 4096) {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_ptr += incr;
    return prev;
}

int _write(int fd, const char *buf, int len) {
    (void)fd;
    for (int i = 0; i < len; i++) {
        if (buf[i] == '\n') uart_putc('\r'); /* CRLF for a real terminal */
        uart_putc(buf[i]);
    }
    return len;
}

int _read(int fd, char *buf, int len) {
    (void)fd;
    int n = 0;
    while (n < len) {
        buf[n++] = (char)uart_getc();
    }
    return n;
}

int _close(int fd) {
    (void)fd;
    return -1;
}

int _fstat(int fd, struct stat *st) {
    (void)fd;
    st->st_mode = S_IFCHR;
    return 0;
}

int _isatty(int fd) {
    (void)fd;
    return 1;
}

int _lseek(int fd, int offset, int whence) {
    (void)fd;
    (void)offset;
    (void)whence;
    return 0;
}

int _kill(int pid, int sig) {
    (void)pid;
    (void)sig;
    errno = EINVAL;
    return -1;
}

int _getpid(void) {
    return 1;
}

void _exit(int code) {
    (void)code;
    while (1) { }
}
