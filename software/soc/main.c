/* The program the boot ROM loads off SD into RAM and jumps to.
 *
 * This is the SoC's actual acceptance test. It runs entirely from RAM,
 * across the Wishbone bus - so simply reaching its first line of output
 * already proves the interconnect, boot ROM, storage path and RAM all work
 * together.
 *
 * Output goes straight to the UART's TX register rather than through
 * newlib's printf. That is not stylistic: on hardware this program reached
 * main and then stopped dead on its first printf, while direct writes came
 * out fine. An acceptance test should exercise the SoC, not the C library,
 * and a libc fault should not be able to look like a hardware failure.
 *
 * Result is reported two ways: printed for a human, and written as a magic
 * word to a fixed address the testbench reads back, so `make sim_soc` can
 * pass or fail automatically rather than relying on someone eyeballing the
 * console.
 */
#include <stdint.h>
#include "soc.h"

static int failures = 0;

/* Written by trap_vector in crt0_ram.S: {mcause, mtval, entry count, t1 scratch}. */
volatile uint32_t trap_info[4];
extern void trap_vector(void);

#define CSRR(csr) ({ uint32_t v_; __asm__ volatile ("csrr %0, " csr : "=r"(v_)); v_; })


/* ---- output, without libc ----
 *
 * This test used newlib's printf until it was run on hardware, where it
 * reached main and then stopped dead on the first printf. Progress markers
 * written straight to the UART came out; printf did not. So the peripheral,
 * the bus, the CPU and every line of this project's own code were working,
 * and the failure was inside newlib - which pulls in malloc, _sbrk and a
 * reentrancy structure, none of which a test that prints thirteen fixed
 * lines has any need for.
 *
 * Rather than debug someone else's allocator on a bring-up board, the output
 * is now these four functions, which touch nothing but the TX register. That
 * is also the right dependency for an acceptance test: it should exercise
 * the SoC, not the C library, and a libc fault should not be able to
 * masquerade as a hardware failure.
 *
 * printf still works in simulation, and software/main.c still uses it - this
 * is a change to what the *hardware* test depends on, not a claim that
 * newlib is broken everywhere. */
static void mark(char c) {
    while (UART_STATUS & UART_TX_BUSY) { }
    UART_TXDATA = (uint32_t)(unsigned char)c;
}

static void put_str(const char *s) {
    while (*s) {
        if (*s == '\n') mark('\r');
        mark(*s++);
    }
}

/* Left-justified in `width` columns, so the ok/FAIL column lines up the way
 * the printf format string used to make it. */
static void put_pad(const char *s, int width) {
    int n = 0;
    while (s[n]) n++;
    put_str(s);
    while (n++ < width) mark(' ');
}

static void put_dec(int v) {
    char buf[12];
    int i = 0;
    if (v < 0) { mark('-'); v = -v; }
    if (v == 0) { mark('0'); return; }
    while (v > 0) { buf[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i > 0) mark(buf[--i]);
}

static void put_hex(uint32_t v) {
    static const char digits[] = "0123456789ABCDEF";
    int i;
    put_str("0x");
    for (i = 28; i >= 0; i -= 4) mark(digits[(v >> i) & 0xF]);
}


static void check(const char *name, int ok) {
    put_str("  ");
    put_pad(name, 28);
    put_str(ok ? " ok\n" : " FAIL\n");
    if (!ok) failures++;
}

/* ---------------------------------------------------------------------
 * Memory tests
 * ------------------------------------------------------------------- */

/* Region to hammer: above this program's own image, below the stack. */
#define TEST_REGION_BASE (RAM_BASE + 0x8000u)
#define TEST_REGION_WORDS 1024u

/* Every bit of a word must be independently settable - catches stuck bits and
 * shorted data lines. */
static int test_walking_ones(void) {
    volatile uint32_t *p = (volatile uint32_t *)(uintptr_t)TEST_REGION_BASE;
    int i;
    for (i = 0; i < 32; i++) {
        uint32_t pattern = 1u << i;
        *p = pattern;
        if (*p != pattern) return 0;
    }
    *p = 0xFFFFFFFFu;
    if (*p != 0xFFFFFFFFu) return 0;
    *p = 0x00000000u;
    if (*p != 0x00000000u) return 0;
    return 1;
}

/* Store each word's own address in it, then read the whole region back. A
 * plain fill-and-check passes even if two addresses alias; storing something
 * unique per location is what actually catches a dropped address bit. */
static int test_address_uniqueness(void) {
    volatile uint32_t *p = (volatile uint32_t *)(uintptr_t)TEST_REGION_BASE;
    uint32_t i;
    for (i = 0; i < TEST_REGION_WORDS; i++)
        p[i] = TEST_REGION_BASE + i * 4u;
    for (i = 0; i < TEST_REGION_WORDS; i++)
        if (p[i] != TEST_REGION_BASE + i * 4u) return 0;
    return 1;
}

/* Sub-word accesses go through the bus adapter's byte-lane shifting, which
 * is entirely new code in the SoC build - the pre-bus design just handed the
 * raw byte address to the memory. Every lane needs checking, not just lane 0. */
static int test_byte_half_access(void) {
    volatile uint8_t  *b = (volatile uint8_t  *)(uintptr_t)(TEST_REGION_BASE + 0x40);
    volatile uint16_t *h = (volatile uint16_t *)(uintptr_t)(TEST_REGION_BASE + 0x50);
    volatile uint32_t *w = (volatile uint32_t *)(uintptr_t)(TEST_REGION_BASE + 0x40);
    int i;

    for (i = 0; i < 4; i++) b[i] = (uint8_t)(0xA0 + i);
    if (*w != 0xA3A2A1A0u) return 0;
    for (i = 0; i < 4; i++) if (b[i] != (uint8_t)(0xA0 + i)) return 0;

    h[0] = 0x1234;
    h[1] = 0x5678;
    if (*(volatile uint32_t *)(uintptr_t)(TEST_REGION_BASE + 0x50) != 0x56781234u) return 0;
    if (h[0] != 0x1234 || h[1] != 0x5678) return 0;

    return 1;
}

/* ---------------------------------------------------------------------
 * Atomics - the interesting one for the bus
 * ------------------------------------------------------------------- */

/* An AMO is a read-modify-write, which on a bus means two transactions with
 * `cyc` held across both. Nothing else in this program exercises that path,
 * and the compiler won't emit AMOs on its own, hence inline asm.
 *
 * `.option arch, +a` turns the atomic extension on for just these
 * instructions. It has to be scoped like this rather than passed as
 * -march=rv32ima, because this toolchain ships no rv32ima multilib - asking
 * for one globally makes the linker fall back to a 64-bit libc and fail. The
 * CPU implements A regardless of what the libc was built for; only the
 * assembler needed convincing. */
#define ASM_ATOMIC(insn) ".option push\n.option arch, +a\n" insn "\n.option pop"

static volatile uint32_t *const atomic_cell =
    (volatile uint32_t *)(uintptr_t)(TEST_REGION_BASE + 0x80);

static int test_amo_rmw(void) {
    uint32_t old;

    *atomic_cell = 100;

    __asm__ volatile (ASM_ATOMIC("amoadd.w %0, %2, (%1)")
                      : "=r"(old) : "r"(atomic_cell), "r"(23) : "memory");
    if (old != 100 || *atomic_cell != 123) return 0;

    __asm__ volatile (ASM_ATOMIC("amoswap.w %0, %2, (%1)")
                      : "=r"(old) : "r"(atomic_cell), "r"(999) : "memory");
    if (old != 123 || *atomic_cell != 999) return 0;

    return 1;
}

/* The reservation should survive an untouched load-reserved, so the
 * store-conditional succeeds and actually writes. */
static int test_lr_sc_success(void) {
    uint32_t old, sc_result;

    *atomic_cell = 999;

    __asm__ volatile (ASM_ATOMIC("lr.w %0, (%1)")
                      : "=r"(old) : "r"(atomic_cell) : "memory");
    __asm__ volatile (ASM_ATOMIC("sc.w %0, %2, (%1)")
                      : "=r"(sc_result) : "r"(atomic_cell), "r"(42) : "memory");

    return old == 999 && sc_result == 0 && *atomic_cell == 42;
}

/* An intervening ordinary store must break the reservation, so the SC fails
 * and leaves memory holding the intervening value. */
static int test_lr_sc_failure(void) {
    uint32_t old, sc_result;

    *atomic_cell = 7;

    __asm__ volatile (ASM_ATOMIC("lr.w %0, (%1)")
                      : "=r"(old) : "r"(atomic_cell) : "memory");
    *atomic_cell = 55;
    __asm__ volatile (ASM_ATOMIC("sc.w %0, %2, (%1)")
                      : "=r"(sc_result) : "r"(atomic_cell), "r"(99) : "memory");

    return old == 7 && sc_result == 1 && *atomic_cell == 55;
}

/* ---------------------------------------------------------------------
 * GPIO - driven pins read back through the pad
 * ------------------------------------------------------------------- */

/* This test used to drive the low 8 pins and expect to read them on the high
 * 8, which worked because sim/tb_soc.v fed gpio_out straight back into
 * gpio_in. On a board there is no such wire: gpio[15:8] is {gn[1:0],
 * gp[13:8]}, header pins with PULLMODE=NONE and nothing plugged into them.
 * It was the one check that failed the first time this program ran on
 * hardware, and it was measuring a testbench, not a SoC - it never touched a
 * pad at all.
 *
 * What replaces it needs no external wiring, so it means the same thing in
 * both places: an enabled bidirectional pin reads back the value it drives.
 * That covers the whole chain - bus write, OUT register, direction register,
 * output driver, the physical pad, the input buffer, the two-flop
 * synchronizer, bus read - which is strictly more than the loopback did.
 *
 * Two complementary patterns, so every pin is required to be both 0 and 1.
 * That is what makes this rigorous without assuming a pull direction: a pin
 * that is not really being driven settles at *some* level, and no single
 * level matches both 0x5A5A and 0xA5A5. A direction register stuck at zero,
 * an output driver that never enables, a pin shorted to either rail, and a
 * GPIO_IN that returns a constant all fail. */
static int test_gpio(void) {
    static const uint32_t pattern[2] = { 0x5A5Au, 0xA5A5u };
    int ok = 1;
    int i;

    GPIO_DIR = 0xFFFFu;                  /* drive every pin */

    for (i = 0; i < 2; i++) {
        uint32_t got;
        GPIO_OUT = pattern[i];
        /* Two flops of input synchronizer plus the pad round trip: give it a
         * few cycles before believing what we read. */
        for (volatile int d = 0; d < 20; d++) { }
        got = GPIO_IN & 0xFFFFu;
        if (got != pattern[i]) {
            /* Print the mismatch. A bare FAIL on a bring-up board says only
             * that something is wrong; the differing bits say which pins. */
            put_str("    drove ");
            put_hex(pattern[i]);
            put_str(" read ");
            put_hex(got);
            put_str(" differ ");
            put_hex(got ^ pattern[i]);
            put_str("\n");
            ok = 0;
        }
    }

    /* The registers themselves - bus decode rather than pins. */
    if (GPIO_DIR != 0xFFFFu) ok = 0;
    if (GPIO_OUT != 0xA5A5u) ok = 0;

    /* Hand the header back undriven, so nothing plugged in afterwards meets
     * a pin still being driven by a test that has finished. */
    GPIO_DIR = 0x0000u;
    GPIO_OUT = 0x0000u;
    return ok;
}

/* ---------------------------------------------------------------------
 * CLINT timer
 * ------------------------------------------------------------------- */

/* mtime must actually advance. Reading it twice and requiring the second
 * read to be larger is a weak check, but it is the one that catches the
 * peripheral being unreachable across the new bus, which is what matters
 * here - the timer's interrupt behavior is already covered by the
 * pre-existing core regression test. */
static int test_timer(void) {
    volatile uint32_t *mtime = (volatile uint32_t *)(uintptr_t)(CLINT_BASE + 0xBFF8u);
    uint32_t t0 = *mtime;
    uint32_t t1;
    for (volatile int i = 0; i < 50; i++) { }
    t1 = *mtime;
    return t1 > t0;
}

/* misa must advertise every extension the hardware actually implements -
 * firmware reads it to decide what the hart can do. This used to claim 'I'
 * only, silently under-selling M and A. */
static int test_misa(void) {
    uint32_t misa = CSRR("misa");
    if ((misa >> 30) != 1) return 0;            /* MXL=1 => 32-bit */
    if (!(misa & (1u << 8)))  return 0;         /* I */
    if (!(misa & (1u << 12))) return 0;         /* M */
    if (!(misa & (1u << 0)))  return 0;         /* A */
    return 1;
}

/* cycle/time/instret must exist and advance. `time` in particular has to be
 * the same clock the CLINT compares mtimecmp against, since SBI timer code
 * reads one and programs the other. */
static int test_counters(void) {
    uint32_t c0 = CSRR("cycle"), t0 = CSRR("time"), i0 = CSRR("instret");
    for (volatile int i = 0; i < 50; i++) { }
    if (CSRR("cycle")   <= c0) return 0;
    if (CSRR("time")    <= t0) return 0;
    if (CSRR("instret") <= i0) return 0;
    /* `time` must track the CLINT's mtime, not a private counter. */
    {
        volatile uint32_t *mtime = (volatile uint32_t *)(uintptr_t)(CLINT_BASE + 0xBFF8u);
        uint32_t via_csr = CSRR("time");
        uint32_t via_mmio = *mtime;
        if (via_mmio < via_csr || (via_mmio - via_csr) > 5000u) return 0;
    }
    return 1;
}

/* A misaligned access must trap rather than being silently mis-executed -
 * that trap is what lets M-mode firmware emulate the access. */
static int test_misaligned_trap(void) {
    uint32_t base = trap_info[2];
    uint32_t addr = TEST_REGION_BASE + 0x101u;   /* deliberately not word-aligned */
    uint32_t dummy;

    __asm__ volatile ("lw %0, 0(%1)" : "=r"(dummy) : "r"(addr) : "memory");
    if (trap_info[2] != base + 1) return 0;
    if (trap_info[0] != 4) return 0;             /* load address misaligned */
    if (trap_info[1] != addr) return 0;          /* mtval = faulting address */

    __asm__ volatile ("sw %0, 0(%1)" :: "r"(dummy), "r"(addr) : "memory");
    if (trap_info[2] != base + 2) return 0;
    if (trap_info[0] != 6) return 0;             /* store address misaligned */

    /* An aligned access of the same size must still be fine. */
    addr = TEST_REGION_BASE + 0x100u;
    __asm__ volatile ("lw %0, 0(%1)" : "=r"(dummy) : "r"(addr) : "memory");
    return trap_info[2] == base + 2;
}

/* FENCE.I must make freshly-written instructions visible. cpu_wb.v keeps a
 * one-entry fetch buffer, so without the invalidation this returns the stale
 * word - which is exactly how a bootloader that overwrites and re-runs code
 * would break. */
/* Framebuffer: byte writes, word writes, and readback.
 *
 * This proves the *CPU's* path to the framebuffer - address decode, byte
 * lanes, wait states. It says nothing about scan-out, which has no CPU-visible
 * effect and is verified separately by sim/tb_video.v. Both halves are needed:
 * this one would pass on a buffer nothing ever displays. */
static int test_framebuffer(void) {
    unsigned x, y;

    /* Byte writes at the corners: catches a decode that drops high address
     * bits, and byte-lane selection at both ends of a word. */
    FB_PIXEL(0, 0)                          = 0xE0;   /* red    */
    FB_PIXEL(FB_WIDTH - 1, 0)               = 0x1C;   /* green  */
    FB_PIXEL(0, FB_HEIGHT - 1)              = 0x03;   /* blue   */
    FB_PIXEL(FB_WIDTH - 1, FB_HEIGHT - 1)   = 0xFF;   /* white  */

    if (FB_PIXEL(0, 0)                        != 0xE0) return 0;
    if (FB_PIXEL(FB_WIDTH - 1, 0)             != 0x1C) return 0;
    if (FB_PIXEL(0, FB_HEIGHT - 1)            != 0x03) return 0;
    if (FB_PIXEL(FB_WIDTH - 1, FB_HEIGHT - 1) != 0xFF) return 0;

    /* Each byte lane of one word, written individually and read back
     * together - a lane that lands in the wrong position shows here. */
    for (x = 0; x < 4; x++)
        FB_PIXEL(x, 1) = (uint8_t)(0x11u * (x + 1));
    for (x = 0; x < 4; x++)
        if (FB_PIXEL(x, 1) != (uint8_t)(0x11u * (x + 1))) return 0;

    /* A word write, read back as bytes: 4 pixels at once is the fast path
     * any drawing code will use. */
    *(volatile uint32_t *)(uintptr_t)(FB_BASE + 2 * FB_WIDTH) = 0x44332211u;
    if (FB_PIXEL(0, 2) != 0x11 || FB_PIXEL(1, 2) != 0x22 ||
        FB_PIXEL(2, 2) != 0x33 || FB_PIXEL(3, 2) != 0x44) return 0;

    /* Leave something on screen rather than debris: a colour ramp, so a
     * board with a display attached later shows an obviously-correct image
     * instead of an ambiguous one. */
    for (y = 0; y < FB_HEIGHT; y++)
        for (x = 0; x < FB_WIDTH; x++)
            FB_PIXEL(x, y) = FB_RGB(x * 255u / FB_WIDTH,
                                    y * 255u / FB_HEIGHT,
                                    128u);
    return 1;
}

static int test_fence_i(void) {
    /* Build a two-instruction function in RAM: `li a0, 0x5A; ret`. */
    volatile uint32_t *code = (volatile uint32_t *)(uintptr_t)(TEST_REGION_BASE + 0x200);
    int (*fn)(void) = (int (*)(void))(uintptr_t)code;

    code[0] = 0x05A00513u;   /* addi a0, zero, 0x5A */
    code[1] = 0x00008067u;   /* jalr zero, 0(ra)  == ret */
    __asm__ volatile ("fence.i" ::: "memory");
    if (fn() != 0x5A) return 0;

    /* Rewrite it and prove the new value is seen only after another fence. */
    code[0] = 0x02D00513u;   /* addi a0, zero, 0x2D */
    __asm__ volatile ("fence.i" ::: "memory");
    return fn() == 0x2D;
}

int main(void) {
    mark('M');          /* reached main at all */

    __asm__ volatile ("csrw mtvec, %0" :: "r"((uintptr_t)trap_vector));

    mark('V');          /* installed our own trap vector */
    mark('\r'); mark('\n');

    put_str("\n=== SoC acceptance test ===\n");
    put_str("Running from RAM at ");
    put_hex((uint32_t)(uintptr_t)main);
    put_str("\n\n");

    check("RAM walking ones",      test_walking_ones());
    check("RAM address uniqueness", test_address_uniqueness());
    check("RAM byte/half access",  test_byte_half_access());
    check("AMO read-modify-write", test_amo_rmw());
    check("LR/SC success",         test_lr_sc_success());
    check("LR/SC broken by store", test_lr_sc_failure());
    check("GPIO pin readback",     test_gpio());
    check("framebuffer read/write", test_framebuffer());
    check("CLINT mtime advances",  test_timer());
    check("misa reports I+M+A",    test_misa());
    check("cycle/time/instret",    test_counters());
    check("misaligned access traps", test_misaligned_trap());
    check("FENCE.I invalidates",   test_fence_i());

    put_str("\n");
    put_dec(failures);
    put_str(" failure(s)\n");
    put_str(failures == 0 ? "SOC-TEST: PASS\n" : "SOC-TEST: FAIL\n");

    REG32(TEST_RESULT_ADDR) = failures == 0 ? TEST_RESULT_PASS : TEST_RESULT_FAIL;

    for (;;) { }
    return 0;
}
