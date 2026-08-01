/* CoreMark port for this SoC.
 *
 * Based on CoreMark's `barebones` template. The three things a port has to
 * supply are a clock, an output path, and a memory method; this one uses the
 * hart's own `cycle` counter, newlib-nano's printf over the UART, and the
 * stack.
 *
 * Deliberate choices worth knowing about:
 *
 * - HAS_FLOAT 0. CoreMark's reporting code prints iterations/sec and elapsed
 *   seconds as floats. newlib-nano's printf drops float formatting unless
 *   linked with -u _printf_float, which drags in a large chunk of libc for
 *   two cosmetic numbers. With floats off, CoreMark reports ticks and
 *   iterations as integers - the benchmark itself is fixed-point throughout
 *   and its results are unaffected.
 *
 * - The timer is `cycle`, not wall-clock. There is no wall clock here: this
 *   runs in simulation, where "seconds" is whatever the testbench's clock
 *   period says it is. Counting cycles is the honest unit, and it is also
 *   the unit that means anything when comparing two versions of the RTL.
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#include <stddef.h>

#define HAS_FLOAT  0
#define HAS_TIME_H 0
#define USE_CLOCK  0
#define HAS_STDIO  1
#define HAS_PRINTF 1

#ifndef COMPILER_VERSION
#define COMPILER_VERSION "GCC" __VERSION__
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STACK"
#endif

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef ee_u32         ee_ptr_int;
typedef size_t         ee_size_t;

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

/* 32 bits of `cycle` is ~43 seconds at 100 MHz and vastly more simulated time
 * than any run here will use, so the counter cannot wrap mid-benchmark. */
#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#ifndef SEED_METHOD
#define SEED_METHOD SEED_VOLATILE
#endif

/* MEM_STACK avoids needing a working malloc/sbrk for the benchmark's own
 * data. syscalls.c does provide a bump allocator, but keeping the benchmark
 * off it means a heap bug cannot be mistaken for a CPU bug. */
#ifndef MEM_METHOD
#define MEM_METHOD MEM_STACK
#endif

#ifndef MULTITHREAD
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0
#endif

#ifndef MAIN_HAS_NOARGC
#define MAIN_HAS_NOARGC 1
#endif
#ifndef MAIN_HAS_NORETURN
#define MAIN_HAS_NORETURN 0
#endif

/* How many benchmark contexts to run. One, since this is a single hart. */
extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#define PERFORMANCE_RUN 1
#endif

#endif /* CORE_PORTME_H */
