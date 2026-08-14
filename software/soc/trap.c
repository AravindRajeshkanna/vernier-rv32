/* The loud half of the RAM program's trap handling.
 *
 * crt0_ram.S takes the trap, fills in trap_info and decides whether anyone
 * asked for it. If nobody did, it lands here - on a private stack, so a wild
 * or overflowed sp cannot stop the report coming out - and this prints what
 * happened and stops the machine.
 *
 * Stopping is the point. The previous handler advanced mepc by 4 and returned
 * from *every* trap, which is right for the deliberate misaligned access the
 * acceptance test performs and wrong for anything else: a fault raised for any
 * other reason was stepped over and the program carried on with whatever state
 * that left behind. Nothing downstream could tell that had happened. This
 * turns that silent corruption into a report and a halt.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

/* .bss, so crt0_ram.S zeroes it before anything can trap. */
volatile uint32_t trap_info[TRAP_WORDS];

extern void trap_vector(void);

void trap_install(void) {
    __asm__ volatile ("csrw mtvec, %0" :: "r"((uintptr_t)trap_vector));
}

/* The causes this machine can actually raise, spelled out. Looking a number up
 * is a detour when you are stood at a bench with a board in front of you. */
static const char *cause_name(uint32_t mcause) {
    if (mcause & 0x80000000u) {
        switch (mcause & 0x7FFFFFFFu) {
            case 3:  return "machine software interrupt";
            case 7:  return "machine timer interrupt";
            case 11: return "machine external interrupt";
            default: return "interrupt";
        }
    }
    switch (mcause) {
        case 0:  return "instruction address misaligned";
        case 1:  return "instruction access fault";
        case 2:  return "ILLEGAL INSTRUCTION";
        case 3:  return "breakpoint";
        case 4:  return "load address misaligned";
        case 5:  return "load access fault";
        case 6:  return "store/AMO address misaligned";
        case 7:  return "store/AMO access fault";
        case 11: return "environment call from M-mode";
        default: return "unknown cause";
    }
}

void trap_report(void) {
    uint32_t mcause = TRAP_MCAUSE;

    put_str("\n*** UNEXPECTED TRAP - halted ***\n");
    put_str("  mcause  "); put_hex(mcause);
    put_str("  "); put_str(cause_name(mcause)); put_str("\n");
    put_str("  mepc    "); put_hex(TRAP_MEPC);
    put_str("   <- the faulting instruction\n");
    put_str("  mtval   "); put_hex(TRAP_MTVAL);
    put_str("   <- faulting address, or the instruction word\n");
    put_str("  ra      "); put_hex(TRAP_RA);
    put_str("   <- who called the faulting function\n");
    put_str("  sp      "); put_hex(TRAP_SP);
    put_str("\n");
    put_str("  traps   "); put_dec((int)TRAP_COUNT);
    put_str(" taken so far, 0 armed\n");

    /* Two things about sp that are always wrong and never obvious from the
     * bare number. A stack that has walked off the end of RAM keeps
     * "working", because wb_interconnect.v decodes on addr[31:24] alone and
     * wb_ram aliases the rest back to the start rather than faulting. And an
     * unaligned sp means something has already corrupted it, which usually
     * matters more than whatever finally faulted. */
    {
        uint32_t sp = TRAP_SP;
        if (sp < RAM_BASE || sp > RAM_BASE + RAM_SIZE)
            put_str("  NOTE: sp is outside the "
                    "64 KB of RAM the firmware is built for\n");
        if (sp & 3u)
            put_str("  NOTE: sp is not word-aligned - it was already corrupt\n");
    }

    /* Machine-checkable, so a simulation fails here instead of running out its
     * timeout with no verdict. */
    REG32(TEST_RESULT_ADDR) = TEST_RESULT_FAIL;

    put_str("HALTED\n");

    /* Nothing left to do but be visible about it. Alternating led[1:0] is a
     * pattern no boot stage produces (they are static values), so a board with
     * no serial cable attached still says "trapped" rather than just sitting
     * there the way a successful run also does. */
    for (;;) {
        volatile int d;
        GPIO_OUT = (GPIO_OUT & ~3u) | 1u;
        for (d = 0; d < 400000; d++) { }
        GPIO_OUT = (GPIO_OUT & ~3u) | 2u;
        for (d = 0; d < 400000; d++) { }
    }
}
