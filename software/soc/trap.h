/* The RAM program's trap record - the layout crt0_ram.S writes and C reads.
 *
 * Two views of the same words, because the handler runs at a point where
 * nothing is safe to call and so has to lay them down by hand. Byte offsets
 * for the assembler, word indices for C. Nothing checks that the two halves
 * agree, so change them together.
 *
 * The record exists because the handler is *loud*: a trap nobody asked for
 * stops the machine and prints this, rather than stepping over the faulting
 * instruction and carrying on. The old handler always stepped over, which is
 * correct for the one trap the acceptance test provokes on purpose and quietly
 * wrong for every other - an illegal instruction, a stray misaligned access
 * inside library code, a wild jump all became "mepc += 4, resume", and the
 * program ran on in whatever state that left. TRAP_O_EXPECT is what separates
 * the two: code that wants a trap arms one first, and only an armed trap is
 * resumed.
 */
#ifndef TRAP_H
#define TRAP_H

/* Byte offsets into trap_info, for crt0_ram.S. */
#define TRAP_O_MCAUSE   0
#define TRAP_O_MTVAL    4
#define TRAP_O_COUNT    8    /* traps taken, of any kind                     */
#define TRAP_O_SCRATCH  12   /* the handler's parking space for t1           */
#define TRAP_O_MEPC     16
#define TRAP_O_SP       20   /* sp as the faulting code left it              */
#define TRAP_O_RA       24
#define TRAP_O_EXPECT   28   /* traps still armed; 0 means "this one is a bug" */
#define TRAP_O_FATAL    32   /* set once the reporter starts, to catch a loop */

#define TRAP_WORDS      9

#ifndef __ASSEMBLER__
#include <stdint.h>

extern volatile uint32_t trap_info[TRAP_WORDS];

#define TRAP_MCAUSE  trap_info[TRAP_O_MCAUSE  / 4]
#define TRAP_MTVAL   trap_info[TRAP_O_MTVAL   / 4]
#define TRAP_COUNT   trap_info[TRAP_O_COUNT   / 4]
#define TRAP_MEPC    trap_info[TRAP_O_MEPC    / 4]
#define TRAP_SP      trap_info[TRAP_O_SP      / 4]
#define TRAP_RA      trap_info[TRAP_O_RA      / 4]
#define TRAP_EXPECT  trap_info[TRAP_O_EXPECT  / 4]

/* Arm `n` traps. The next `n` traps are resumed at mepc+4 and recorded; the
 * one after that is treated as a fault and halts the machine.
 *
 * Only correct for a trap you provoked deliberately with a 4-byte instruction
 * that must not be retried - which is what "expected" means here. */
static inline void trap_arm(uint32_t n) { TRAP_EXPECT = n; }

/* Point mtvec at the loud handler. Do this before running anything you want
 * a diagnosis from; until it happens, traps land in the boot ROM's handler. */
void trap_install(void);

/* Entered from crt0_ram.S on an unarmed trap. Prints the record and stops. */
void trap_report(void) __attribute__((noreturn));

#endif /* __ASSEMBLER__ */
#endif /* TRAP_H */
