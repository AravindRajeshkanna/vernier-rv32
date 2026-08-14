/* Why does newlib die on this board?
 *
 * The acceptance test used to print through newlib's printf. On hardware it
 * reached main and then stopped dead on the first one; markers written
 * straight at the UART came out, printf did not. That was worked around by
 * dropping libc from the acceptance test - the right call for the test, and
 * not an answer to the question. This program is the answer.
 *
 * It is a ladder. Each rung prints a single character *before* it runs, then a
 * human-readable line after it succeeds, so a run that stops tells you which
 * rung it stopped on even if the line never finished. The rungs are ordered so
 * that consecutive ones differ by one dependency:
 *
 *   1  reached main, loud trap handler installed
 *   2  where the heap is, and where RAM actually ends
 *   3  the heap window, written and read back directly - no libc involved
 *   4  _sbrk, this project's own code
 *   5  memory _sbrk handed out
 *   6  malloc/free - newlib's allocator, on top of _sbrk
 *   7  snprintf - newlib's formatter, no heap and no stdio
 *   8  puts - stdio: __sinit, a FILE, and _write
 *   9  printf - the thing that was blamed
 *   A  stdout's own state afterwards: buffered, or handed down and lost?
 *   B  _write called directly, with stdio taken out of the picture
 *
 * Rungs A and B were added after the first board run, which found something
 * the ladder alone could not name: 8 and 9 *succeed* on hardware and print
 * nothing, while every direct write around them arrives. printf does not hang
 * and never did - the original "stopped dead on the first printf" was printf
 * being the only output channel, so producing nothing and stopping looked
 * identical. A and B split what is left: bytes stuck in stdio's buffer, or
 * bytes handed to _write and lost below it.
 *
 * So a failure localizes rather than just happening: rung 3 failing is RAM,
 * rung 4 is our _sbrk, rung 6 is the allocator, rung 7 is the formatter,
 * rung 8 is stdio setup, rung 9 is the last mile.
 *
 * The other half of the diagnosis is crt0_ram.S. Its handler used to advance
 * mepc by 4 and return from every trap, so a fault inside newlib was stepped
 * over and the program carried on corrupted - a hypothesis this program could
 * not have tested, because the evidence was being destroyed as it was
 * produced. The handler is now loud: an unarmed trap prints mcause/mepc/mtval
 * and halts. Rung 1 installs it before any libc code runs, so if newlib faults
 * anywhere below, the report says where and why.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "soc.h"
#include "console.h"
#include "trap.h"

extern char _end[];
extern char _stack_top[];
extern char _sidata[], _eidata[];   /* .data's initial values, in the image  */
extern char _sdata[], _edata[];     /* .data where it actually runs          */
extern void *_sbrk(int incr);
extern int _write(int fd, const char *buf, int len);

static int failures = 0;

static void ok(const char *what) {
    put_str("  ok   ");
    put_str(what);
    put_str("\n");
}

static void bad(const char *what) {
    put_str("  FAIL ");
    put_str(what);
    put_str("\n");
    failures++;
}

static uint32_t read_sp(void) {
    uint32_t v;
    __asm__ volatile ("mv %0, sp" : "=r"(v));
    return v;
}

/* How much RAM is really there?
 *
 * wb_interconnect.v decodes on addr[31:24] alone, so the whole 16 MB window at
 * 0x8000_0000 reaches wb_ram, which then indexes with only as many address
 * bits as its size needs. An access past the end therefore *aliases* back to
 * the start instead of faulting - silently, with no bus error to catch.
 *
 * That is one of exactly two ways this program's world differs between the
 * simulation and the board: sim/tb_soc.v gives the SoC 256 KB, fpga/soc_fpga.v
 * gives it 64 KB. Anything that runs off the end of RAM therefore works in
 * simulation and quietly corrupts low memory on hardware, which is a shape
 * that fits "worked in sim, died on the board" exactly.
 *
 * Measured rather than assumed: write a marker, then look for its echo at
 * successively larger offsets. The first offset that echoes is the wrap point,
 * and therefore the real size. */
static uint32_t measure_ram_bytes(void) {
    volatile uint32_t *base = (volatile uint32_t *)(uintptr_t)(RAM_BASE + 0x8000u);
    uint32_t size;

    *base = 0xC0FFEE00u;
    /* Up to 8 MB, staying inside the 16 MB window that decodes to RAM at all -
     * past it the interconnect acks with zero and this would prove nothing. */
    for (size = 0x1000u; size <= 0x800000u; size <<= 1) {
        volatile uint32_t *alias =
            (volatile uint32_t *)(uintptr_t)(RAM_BASE + 0x8000u + size);
        uint32_t save = *alias;
        *alias = 0xDEADBEEFu;
        if (*base == 0xDEADBEEFu) return size;
        *alias = save;
    }
    return 0;
}

/* Write a pattern across a span and read it back. Every 256th word plus the
 * last, which is enough to catch a span that is not backed by memory without
 * spending a simulation's worth of cycles on it. */
static int span_is_good(uint32_t lo, uint32_t hi) {
    volatile uint32_t *p;
    uint32_t a;

    for (a = lo; a + 4 <= hi; a += 256) {
        p = (volatile uint32_t *)(uintptr_t)a;
        *p = a ^ 0xA5A5A5A5u;
    }
    p = (volatile uint32_t *)(uintptr_t)(hi - 4);
    *p = (hi - 4) ^ 0xA5A5A5A5u;

    for (a = lo; a + 4 <= hi; a += 256) {
        p = (volatile uint32_t *)(uintptr_t)a;
        if (*p != (a ^ 0xA5A5A5A5u)) return 0;
    }
    p = (volatile uint32_t *)(uintptr_t)(hi - 4);
    if (*p != ((hi - 4) ^ 0xA5A5A5A5u)) return 0;
    return 1;
}

int main(void) {
    uint32_t heap_lo, heap_hi, ram_bytes, ram_top;

    /* Sampled here and nowhere else: __sinit *sets* __cleanup when it succeeds,
     * so after any stdio call a healthy system also reads non-NULL and the
     * value says nothing. Only its value before stdio has been touched
     * distinguishes "the guard was clear and __sinit ran" from "the guard was
     * already set and __sinit returned without doing anything". Reading it
     * late is how this probe nearly reported the opposite of the truth. */
    uint32_t cleanup_at_entry = (uint32_t)(uintptr_t)_REENT_CLEANUP(_impure_ptr);

    /* ---- 1: alive, and traps are loud from here on ---- */
    put_char('1');
    trap_install();
    put_str("\n=== newlib probe ===\n");
    put_str("  running at "); put_hex((uint32_t)(uintptr_t)main);
    put_str(", sp "); put_hex(read_sp());
    put_str("\n");

    /* ---- 0: is the program in RAM the one that was built, and did crt0
     *         rebuild .data from it? ----
     *
     * The checksum covers the image: .text plus .data's *initial values*.
     * Neither is written at runtime, so unlike the old layout this number is
     * stable across reruns and a change in it means real corruption rather
     * than the program's own footprints.
     *
     * The comparison below is the one that matters. .data now lives at an
     * address the image does not cover, and crt0_ram.S copies the initial
     * values into it on every startup - which is what makes the program
     * survive a reset. If that copy did not happen, .data holds whatever the
     * previous run left, newlib's __sinit sees its own guard from last time,
     * and stdout is dead for the rest of the run. This says so directly
     * instead of leaving it to be inferred from rung 8 printing nothing. */
    put_char('0');
    {
        const volatile uint32_t *img =
            (const volatile uint32_t *)(uintptr_t)PROGRAM_LOAD_ADDR;
        uint32_t words = ((uint32_t)(uintptr_t)_eidata - PROGRAM_LOAD_ADDR) / 4u;
        uint32_t dwords = (uint32_t)(_edata - _sdata) / 4u;
        uint32_t sum = 0, i;
        int copied = 1;

        for (i = 0; i < words; i++)
            sum = ((sum << 1) | (sum >> 31)) ^ img[i];

        put_str("  image "); put_dec((int)words);
        put_str(" words at "); put_hex(PROGRAM_LOAD_ADDR);
        put_str("..."); put_hex((uint32_t)(uintptr_t)_eidata);
        put_str("\n  rotate-xor checksum "); put_hex(sum);
        put_str("\n  .data runs at "); put_hex((uint32_t)(uintptr_t)_sdata);
        put_str(", loaded from "); put_hex((uint32_t)(uintptr_t)_sidata);
        put_str(", "); put_dec((int)dwords); put_str(" words\n");

        for (i = 0; i < dwords; i++) {
            uint32_t want = ((const volatile uint32_t *)(uintptr_t)_sidata)[i];
            uint32_t have = ((const volatile uint32_t *)(uintptr_t)_sdata)[i];
            if (want != have) {
                put_str("    word "); put_dec((int)i);
                put_str(" at "); put_hex((uint32_t)(uintptr_t)_sdata + i * 4u);
                put_str(": want "); put_hex(want);
                put_str(" have "); put_hex(have); put_str("\n");
                copied = 0;
            }
        }
        if (copied) ok("crt0 rebuilt .data from the image");
        else        bad("crt0 did not rebuild .data - this run inherited the last one's");
    }

    /* ---- 2: the map ---- */
    put_char('2');
    heap_lo = (uint32_t)(uintptr_t)_end;
    /* syscalls.c's ceiling: it refuses to grow the heap into the last 4 KB
     * below the stack. Duplicated here rather than exported, because the point
     * is to check the number that code actually uses. */
    heap_hi = (uint32_t)(uintptr_t)_stack_top - 4096u;
    ram_bytes = measure_ram_bytes();
    ram_top = RAM_BASE + ram_bytes;

    put_str("\n  _end (heap base)   "); put_hex(heap_lo);
    put_str("\n  heap ceiling       "); put_hex(heap_hi);
    put_str("\n  _stack_top         "); put_hex((uint32_t)(uintptr_t)_stack_top);
    put_str("\n  RAM measured       "); put_hex(ram_bytes);
    put_str(" bytes, top "); put_hex(ram_top);
    put_str("\n  firmware assumes   "); put_hex(RAM_SIZE);
    put_str("\n\n");

    if (ram_bytes == 0)
        bad("RAM size could not be measured");
    else if (ram_bytes < RAM_SIZE)
        bad("RAM is SMALLER than the firmware assumes - "
            "the stack and heap ceiling are past the end");
    else
        ok("RAM is at least the size the firmware assumes");

    if (heap_hi > ram_top || (uint32_t)(uintptr_t)_stack_top > ram_top)
        bad("heap window or stack lies beyond the end of RAM");
    else
        ok("heap window and stack lie inside RAM");

    /* ---- 3: is the heap window real memory, before libc touches it? ---- */
    put_char('3');
    if (span_is_good(heap_lo, heap_hi)) ok("heap window reads back what is written");
    else                                bad("heap window does not hold data");

    /* ---- 4: _sbrk, our code ---- */
    put_char('4');
    {
        char *first = (char *)_sbrk(0);
        char *got   = (char *)_sbrk(1024);
        put_str("  _sbrk(0) "); put_hex((uint32_t)(uintptr_t)first);
        put_str("  _sbrk(1024) "); put_hex((uint32_t)(uintptr_t)got);
        put_str("\n");
        if (got == (char *)-1)                 bad("_sbrk refused 1024 bytes");
        else if (got != first)                 bad("_sbrk(0) and _sbrk(1024) disagree");
        else                                   ok("_sbrk handed out 1024 bytes");

        /* ---- 5: and is that memory usable? ---- */
        put_char('5');
        if (got != (char *)-1 &&
            span_is_good((uint32_t)(uintptr_t)got, (uint32_t)(uintptr_t)got + 1024u))
            ok("_sbrk's block reads back what is written");
        else
            bad("_sbrk's block does not hold data");
    }

    /* ---- 6: newlib's allocator ---- */
    put_char('6');
    {
        void *a = malloc(1024);
        put_str("  malloc(1024) -> "); put_hex((uint32_t)(uintptr_t)a); put_str("\n");
        if (a == NULL) {
            bad("malloc returned NULL");
        } else {
            memset(a, 0x5A, 1024);
            if (((unsigned char *)a)[0] == 0x5A && ((unsigned char *)a)[1023] == 0x5A)
                ok("malloc'd block reads back what is written");
            else
                bad("malloc'd block does not hold data");
            free(a);
            ok("free returned");
        }
    }

    /* ---- 7: the formatter, with no heap and no stdio behind it ---- */
    put_char('7');
    {
        char buf[64];
        int n = snprintf(buf, sizeof buf, "%d %x %s", -42, 0xABCDu, "str");
        put_str("  snprintf -> \""); put_str(buf); put_str("\" n=");
        put_dec(n); put_str("\n");
        if (n == 12 && strcmp(buf, "-42 abcd str") == 0) ok("snprintf formats correctly");
        else                                             bad("snprintf produced the wrong text");
    }

    /* ---- 8: stdio - __sinit, a FILE, a buffer, and _write ----
     *
     * The return value matters as much as the text. On the board these two
     * rungs *succeed* and emit nothing: `puts` and `printf` both return a
     * sensible count and their output never reaches the UART, while every
     * direct write around them arrives. So "printf hangs" was never the right
     * reading of the original failure - the program ran straight past it. It
     * only looked like a hang because printf was the sole output channel, so
     * "produced no output" and "stopped" were the same observation. */
    put_char('8');
    {
        int n = puts("  puts: this line came out of newlib's stdio");
        put_str("  puts returned "); put_dec(n); put_str("\n");
        if (n < 0) bad("puts reported an error");
        else       ok("puts returned without error");
    }

    /* ---- 9: the thing that was blamed ---- */
    put_char('9');
    {
        int n = printf("  printf: %d %s 0x%08lx\n",
                       1234, "formatted", (unsigned long)0xDEADBEEFu);
        int f = fflush(stdout);
        put_str("  printf returned "); put_dec(n);
        put_str(", fflush returned "); put_dec(f); put_str("\n");
        if (n < 0) bad("printf reported an error");
        else       ok("printf returned without error");
    }

    /* ---- A: stdout's own state, after all that ----
     *
     * Two ways for output to vanish while the call reports success, and this
     * tells them apart. If bytes are still sitting in the buffer (`_p` past
     * `_bf._base`) then stdio never handed them to `_write` and the fflush did
     * nothing; if the buffer is empty then `_write` was called and the bytes
     * were lost below it. `_write` here is the FILE's own hook, which is what
     * stdio actually calls - if that is not our syscall, nothing else about
     * this matters. */
    put_char('A');
    {
        uint32_t flags = (uint32_t)stdout->_flags;

        /* The reentrancy structure first, because it decides whether stdout
         * was ever going to work. __sinit returns early when __cleanup is
         * already non-NULL, and __cleanup is statically NULL in .data - so a
         * non-NULL value here means the image's tail is not what was built,
         * and rung 0's checksum says so independently. A NULL __cleanup with
         * a still-zeroed stdout means the opposite: the image is fine and
         * __sinit itself is where to look next.
         *
         * _stdout is printed from the structure as well as through the
         * `stdout` macro, so a disagreement between them is visible rather
         * than assumed away. */
        put_str("  _impure_ptr  "); put_hex((uint32_t)(uintptr_t)_impure_ptr);
        put_str("\n  __cleanup at entry  "); put_hex(cleanup_at_entry);
        put_str(cleanup_at_entry ? "  NON-NULL: __sinit skipped itself,"
                                   " so .data's tail is not what was built"
                                 : "  NULL: __sinit was free to run");
        put_str("\n  __cleanup now       ");
        put_hex((uint32_t)(uintptr_t)_REENT_CLEANUP(_impure_ptr));
        put_str("  (__sinit sets this on success - only the entry value means"
                " anything)\n");
        put_str("  ->_stdout    "); put_hex((uint32_t)(uintptr_t)_impure_ptr->_stdout);
        put_str("\n  stdout       "); put_hex((uint32_t)(uintptr_t)stdout);
        put_str("\n  _impure_data live contents (19 words):\n");
        {
            const volatile uint32_t *d =
                (const volatile uint32_t *)(uintptr_t)_impure_ptr;
            int i;
            for (i = 0; i < 19; i++) {
                put_str("    "); put_hex((uint32_t)(uintptr_t)&d[i]);
                put_str("  "); put_hex(d[i]); put_str("\n");
            }
        }

        uint32_t base  = (uint32_t)(uintptr_t)stdout->_bf._base;
        uint32_t p     = (uint32_t)(uintptr_t)stdout->_p;

        /* newlib's __S* bits (stdio.h). Decoded one at a time rather than as
         * a mode, because they are not a mode: an earlier version of this
         * printed "fully buffered" for 0x40 by testing __SLBF and __SNBF and
         * falling through, which named a buffering scheme for a FILE whose
         * only set bit was the *error* flag. The absence of __SWR is the
         * finding; calling it "fully buffered" hid it. */
        put_str("  stdout _flags "); put_hex(flags); put_str(" ");
        if (flags & 0x0001u) put_str("__SLBF(line-buffered) ");
        if (flags & 0x0002u) put_str("__SNBF(unbuffered) ");
        if (flags & 0x0004u) put_str("__SRD ");
        if (flags & 0x0008u) put_str("__SWR ");
        if (flags & 0x0010u) put_str("__SRW ");
        if (flags & 0x0020u) put_str("__SEOF ");
        if (flags & 0x0040u) put_str("__SERR ");
        if (flags & 0x0080u) put_str("__SMBF(malloc'd buffer) ");
        if (!(flags & 0x0008u))
            put_str("\n  NO __SWR: this FILE was never set up for writing "
                    "- __sinit did not run");
        put_str("\n  _bf._base    "); put_hex(base);
        put_str(" size "); put_dec(stdout->_bf._size);
        put_str("\n  _p           "); put_hex(p);
        put_str(" -> "); put_dec((int)(p - base)); put_str(" byte(s) pending\n");
        put_str("  _w           "); put_dec(stdout->_w);
        put_str("\n  _file        "); put_dec(stdout->_file);
        /* These two are *expected* to differ: the hook is newlib's __swrite,
         * which calls _write_r, which calls ours. Both are printed so the
         * chain can be checked against the ELF rather than assumed - a hook
         * that is null, or in RAM the image never loaded, would explain
         * everything downstream of it. */
        put_str("\n  _write hook  "); put_hex((uint32_t)(uintptr_t)stdout->_write);
        put_str("  (newlib's __swrite)");
        put_str("\n  our _write   "); put_hex((uint32_t)(uintptr_t)&_write);
        put_str("\n");

        if (base != 0 && p > base)
            bad("bytes are still in stdout's buffer - stdio never called _write");
        else
            ok("stdout's buffer is empty - stdio did hand the bytes down");
    }

    /* ---- B: the syscall layer on its own, with stdio removed ----
     *
     * This is the same `_write` that syscalls.c gives newlib, called directly.
     * If this text appears, then the UART, the driver and the syscall all work
     * and everything above them is stdio's business. If it does not, the fault
     * is below stdio and stdio was never the culprit at all. */
    put_char('B');
    {
        static const char msg[] = "  _write: called directly, no stdio\n";
        int n = _write(1, msg, (int)(sizeof msg - 1));
        put_str("  _write returned "); put_dec(n); put_str("\n");
        if (n != (int)(sizeof msg - 1)) bad("_write returned the wrong count");
        else                            ok("_write returned the right count");
    }

    put_str("\n");
    put_dec(failures);
    put_str(" failure(s)\n");
    put_str(failures == 0 ? "NEWLIB-PROBE: PASS\n" : "NEWLIB-PROBE: FAIL\n");
    put_str("  traps taken: "); put_dec((int)TRAP_COUNT); put_str("\n");
    put_str("  deepest sp:  "); put_hex(read_sp()); put_str("\n");

    REG32(TEST_RESULT_ADDR) = failures == 0 ? TEST_RESULT_PASS : TEST_RESULT_FAIL;

    for (;;) { }
    return 0;
}
