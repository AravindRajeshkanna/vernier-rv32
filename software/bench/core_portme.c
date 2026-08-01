/* CoreMark platform hooks for this SoC. See core_portme.h for the choices. */
#include "coremark.h"
#include "core_portme.h"

#include <stdint.h>
#include <stdio.h>

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
#endif
#if PROFILE_RUN
volatile ee_s32 seed1_volatile = 0x8;
volatile ee_s32 seed2_volatile = 0x8;
volatile ee_s32 seed3_volatile = 0x8;
#endif
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* The hart's own retired-cycle counter. This is the same register the ISA
 * test suite checks (rv32mi-p-zicntr) and the same one the SoC acceptance
 * test compares against the CLINT, so a wrong number here would already have
 * been caught elsewhere - which is what makes it trustworthy as a timer. */
static inline ee_u32 read_cycle(void)
{
    ee_u32 v;
    __asm__ volatile("csrr %0, cycle" : "=r"(v));
    return v;
}

static CORE_TICKS start_ticks, total_ticks;

void
start_time(void)
{
    start_ticks = read_cycle();
}

void
stop_time(void)
{
    total_ticks = read_cycle() - start_ticks;
}

CORE_TICKS
get_time(void)
{
    return total_ticks;
}

/* CoreMark divides the tick count by this to report seconds. Reporting
 * cycles directly (divider of 1) is the truthful thing to do in simulation:
 * there is no wall clock, and inventing one by dividing by an assumed clock
 * frequency would turn a hard number into a guess. Read every "secs" field
 * in the output below as "cycles". */
ee_u32 default_num_contexts = 1;

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)ticks;
}

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;

    if (sizeof(ee_ptr_int) != sizeof(ee_u8 *))
        ee_printf("ERROR! Please define ee_ptr_int to a type that holds a "
                  "pointer!\n");
    if (sizeof(ee_u32) != 4)
        ee_printf("ERROR! Please define ee_u32 to a 32b unsigned type!\n");

    p->portable_id = 1;
}

/* CoreMark decides validity itself, by recomputing CRCs over its own results
 * and printing "Correct operation validated" or "Errors detected". That
 * verdict lives in a local inside core_main and is not reachable from here,
 * so sim/tb_bench.v watches the UART byte stream for it instead. Matching on
 * the benchmark's own statement is better than inventing a second one: it
 * cannot drift out of step with what CoreMark actually concluded. */
void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
