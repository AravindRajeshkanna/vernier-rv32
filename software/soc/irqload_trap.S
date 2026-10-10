/* The interrupt handler for software/soc/irqload.c (Phase 8 Stage 3, Part 31).
 *
 * The shortest handler a driver could honestly write for a PLIC interrupt: claim, silence the
 * device, complete. Around that it takes two readings of the timer's own counter, which is how the
 * program tells how long the interrupt took to be served.
 *
 * The counter runs 0..PERIOD-1 and the wrap that sets the timer's interrupt flag also sets it to 0
 * (rtl/soc/wb_timer.v), so a value read d cycles after the wrap is d. The first reading is the first
 * thing this does that reaches a device, before it has touched memory, and the value is the time the
 * interrupt took to arrive: pipeline, trap entry, and anything the hart was waiting for when the
 * interrupt came (a cache refill over the interconnect, say), plus the request's trip to the timer.
 * The second is taken as soon as the claim has been completed, so the difference between the two is the
 * time to serve the interrupt. Both are logged for irqload.c to summarise afterwards.
 *
 * Only t0 to t4 are used, and they are saved on the interrupted code's stack. Nothing here is a
 * function call, so nothing else is. Past the end of the log it masks the interrupt (MEIE) as well, so
 * that a handler which cannot silence its device ends the run, and fails the program's count, instead of
 * starving the code it interrupts.
 */
#include "irqload.h"

    .section .text
    .align 4
    .global irq_vector
irq_vector:
    csrw  mscratch, t0                  /* park t0; no memory has been touched yet            */
    li    t0, IRQ_TIMER_BASE
    lw    t0, IRQ_TIMER_COUNT_OFF(t0)   /* lat: cycles since the wrap, as the timer saw it    */
    csrw  sscratch, t0                  /* park it                                            */
    addi  sp, sp, -20
    sw    t1, 0(sp)
    sw    t2, 4(sp)
    sw    t3, 8(sp)
    sw    t4, 12(sp)
    csrr  t1, mscratch
    sw    t1, 16(sp)                    /* the interrupted code's t0                          */

    li    t1, IRQ_PLIC_CLAIM_BASE
    lw    t2, 4(t1)                     /* claim: which source                                */
    li    t3, IRQ_TIMER_BASE
    li    t4, 1
    sw    t4, IRQ_TIMER_IP_OFF(t3)      /* silence the timer (write 1 to clear)               */
    sw    t2, 4(t1)                     /* complete                                           */
    lw    t3, IRQ_TIMER_COUNT_OFF(t3)   /* done: cycles since the wrap, with the IRQ served   */
    csrr  t4, sscratch                  /* lat                                                */

    addi  t2, t2, -IRQ_TIMER_SRC
    beqz  t2, 1f
    la    t1, irq_bad                   /* a claim that was not the timer's: say so           */
    li    t2, 1
    sw    t2, 0(t1)
1:  la    t1, irq_n
    lw    t2, 0(t1)
    addi  t0, t2, 1
    sw    t0, 0(t1)                     /* one more interrupt taken                           */
    li    t0, IRQ_LOG_MAX
    bgeu  t2, t0, 3f                    /* past the end of the log: counted, not logged       */
    slli  t2, t2, 3
    la    t1, irq_log
    add   t1, t1, t2
    sw    t4, 0(t1)
    sw    t3, 4(t1)

2:  lw    t1, 0(sp)
    lw    t2, 4(sp)
    lw    t3, 8(sp)
    lw    t4, 12(sp)
    lw    t0, 16(sp)
    addi  sp, sp, 20
    mret

3:  li    t0, 0x800                     /* the log is full: stop taking interrupts (MEIE), so a   */
    csrc  mie, t0                       /* handler that cannot silence its device ends the run   */
    j     2b                            /* instead of starving the program it interrupts         */
