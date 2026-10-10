/* Constants shared by irqload.c and irqload_trap.S (Phase 8 Stage 3, Part 31).
 *
 * Plain numbers, with no C suffixes, because the assembler reads this file too and cannot read
 * soc.h's register macros. irqload.c checks every one of them against soc.h at compile time, so
 * the two cannot drift apart quietly (practices.md section 11).
 */
#ifndef IRQLOAD_H
#define IRQLOAD_H

#define IRQ_TIMER_BASE       0x08000000   /* soc.h TIMER_BASE                               */
#define IRQ_TIMER_COUNT_OFF  0x04         /* TIMER_COUNT: 0 at the wrap that raises the IRQ */
#define IRQ_TIMER_IP_OFF     0x14         /* TIMER_IP: write 1 to clear                     */
#define IRQ_PLIC_CLAIM_BASE  0x03200000   /* PLIC_CLAIM(PLIC_CTX_M) is this + 4             */
#define IRQ_TIMER_SRC        3            /* the timer's PLIC source: irq_sources[2] + 1    */
#define IRQ_LOG_MAX          256          /* samples the handler can log                    */

#endif
