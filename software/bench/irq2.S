/* Interrupt service beside a hart that streams through memory (Phase 8 Stage 3, Part 32).
 *
 * Part 31 took a periodic interrupt on one hart with the NPU's DMA racing it. This puts a second hart
 * in the NPU's place: hart 0 runs a loop and takes the interrupt, hart 1 sweeps an array far bigger
 * than its data cache one word at a time (Part 27's stream2.S, whose loop it repeats), so that hart 1
 * keeps the interconnect busy for the whole of hart 0's window. Whether hart 1 is there, whether hart
 * 0 is interrupted, where hart 1's array lives, and the interrupt period are all in the mailbox, so
 * one image covers every row of the matrix (sim/irq2_matrix.py). See sim/tb_soc_2hart_irq.v.
 *
 * Hart 0 does what software/soc/irqload.c does, in assembly because nothing else is linked here:
 * it fills a 1 KB buffer, then runs passes over it (each pass sums buf[i] ^ i, 256 word loads, and is
 * a fixed piece of work) for a window of cycles, counting the passes. Interrupted, the timer
 * (rtl/soc/wb_timer.v) raises an interrupt every `period` cycles, delivered through the PLIC to hart
 * 0 as a machine external interrupt; the handler claims, silences the timer, completes, and logs two
 * readings of the timer's counter - which the wrap that raised the interrupt reset to 0 - so each is
 * the number of cycles since the interrupt was raised:
 *    lat    until the handler's first access reached the timer
 *    done   until the interrupt had been served (claim, clear, complete, and this reading)
 * The handler is irqload_trap.S's, with absolute addresses. It takes three interrupts in a warm-up before
 * the barrier so that its code is cached when the window starts, and the first interrupt of the window is
 * left out of the statistics by the testbench (it may have been pending since the barrier).
 *
 * The cache starts warm. Hart 1's initialisation stores invalidate entries of hart 0's data cache, which
 * snoops other harts' stores by index (rtl/soc/cpu_wb.v), and whether the last of them land before or
 * after hart 0 is ready depends on how long hart 0's own set-up took, which differs between a run with the
 * interrupt and one without (the warm-up takes interrupts). A first version started the window straight
 * after the barrier, and an uninterrupted window began with a pass of 256 misses that an interrupted one
 * did not: the baseline was dearer than it should have been, and the cost of an interrupt came out
 * about 4 cycles too low. So hart 0 runs one more pass after the barrier, untimed, and its window starts
 * about 2,000 cycles after hart 1's.
 *
 * The window ends at the first pass boundary after `window` cycles; interrupts are masked, the cycle
 * counter read and the interrupt count taken there, so `elapsed` and `n` describe the same stretch of time. What
 * the interrupts cost is what they add to the passes: (elapsed - passes * cycles-a-pass-takes-uninterrupted)
 * over n, which the matrix works out from a run with the interrupts off. The data caches are on (every
 * hart's has been since Phase 8 Part 5, and they snoop each other's stores) and the loop's buffer is the
 * size of one, so its loads hit and only the handler's stores and device loads, and the loop's re-reads of
 * the words the handler displaced, reach the interconnect, as in software/soc/irqload.c; hart 1's array
 * is four times its cache, so nearly all of its loads do.
 *
 * One image, run by both harts from RESET_PC (every hart has the same one). The mailbox and the
 * results are words of RAM the testbench writes before reset ends and reads when hart 0 is done:
 *
 * Mailbox (0x8000_0800, one word each):
 *    +0   mode      bit 1 set: hart 1 streams; clear: it parks and does nothing (hart 0 always runs)
 *    +4   irq       1: hart 0 takes the timer interrupt; 0: the timer is never started
 *    +8   period    the timer's period in cycles
 *    +12  window    cycles the window lasts
 *    +16  base1     start of hart 1's array
 *    +20  nwords    hart 1's array length in words, a multiple of 64
 *    +24  nactive   how many harts the barrier waits for (1 or 2)
 * Barrier counter: 0x8000_0840. Interrupt log, 8 bytes an interrupt (lat, done): 0x8000_1000 for 256.
 * The handler's counters: 0x8000_1800 interrupts taken, 0x8000_1804 non-timer claims.
 * Hart 0's results, from 0x8000_0900 (status written last):
 *    +0   status    0 running, 1 finished and the checksum right, 2 the checksum wrong
 *    +4   passes    passes over the buffer in the window
 *    +8   elapsed   cycles from the start of the window to the end of the last pass
 *    +12  start     hart 0's cycle counter at the start of the window
 *    +16  n         interrupts taken in the window (the log holds the first 256)
 *    +20  bad       1 if the handler ever claimed something other than the timer
 *    +24  acc       the checksum the loop reached
 *    +28  want      the checksum it should have: 1 + passes * (one pass's sum, taken before the window)
 * Hart 1's results, from 0x8000_0920, are stream2.S's: status, blocks, cycles, start, failblk, got, want.
 */
.equ MAILBOX,    0x80000800
.equ BARRIER,    0x80000840
.equ RES0,       0x80000900
.equ RES1,       0x80000920
.equ IRQ_LOG,    0x80001000
.equ IRQ_N,      0x80001800
.equ IRQ_BAD,    0x80001804
.equ VBUF,       0x80002000
.equ STACK0,     0x80003000
.equ TIMER,      0x08000000
.equ PLIC,       0x03000000
.equ PLIC_CLAIM, 0x03200000
.equ LOG_MAX,    256

.section .text.start
.global _start
_start:
    csrr  s0, mhartid
    li    s1, MAILBOX
    bnez  s0, hart1

/* ---- hart 0: the loop, and the interrupt ---- */
hart0:
    li    sp, STACK0
    lw    s3, 4(s1)                 /* irq */
    lw    s4, 8(s1)                 /* period */
    lw    s5, 12(s1)                /* window */

    li    t0, 0                     /* buf[i] = i * 2654435761 */
    li    t2, 256
    li    t3, 0x9E3779B1
    li    t6, VBUF
fill:
    mul   t1, t0, t3
    slli  t4, t0, 2
    add   t4, t4, t6
    sw    t1, 0(t4)
    addi  t0, t0, 1
    bne   t0, t2, fill

    jal   ra, pass                  /* one pass's sum, before anything interrupts it */
    mv    s7, a0

    beqz  s3, ready                 /* not interrupted: no timer, no PLIC */
    li    t0, TIMER
    sw    zero, 0(t0)               /* CTRL = 0 */
    sw    zero, 0x10(t0)            /* IE = 0 */
    li    t1, 1
    sw    t1, 0x14(t0)              /* IP: write 1 to clear */
    sw    s4, 8(t0)                 /* PERIOD */
    sw    zero, 4(t0)               /* COUNT = 0 */
    li    t0, PLIC
    li    t1, 1
    sw    t1, 12(t0)                /* priority of source 3, the timer's, = 1 */
    li    t2, 0x2000
    add   t2, t2, t0
    li    t1, 8
    sw    t1, 0(t2)                 /* context 0 (hart 0, M) enables source 3 */
    li    t2, 0x200000
    add   t2, t2, t0
    sw    zero, 0(t2)               /* context 0's threshold = 0 */
    la    t1, irq_vector
    csrw  mtvec, t1
    li    t1, 0x800
    csrs  mie, t1                   /* MEIE */
    li    t0, TIMER
    li    t1, 1
    sw    t1, 0x10(t0)              /* IE = 1 */
    sw    t1, 0(t0)                 /* CTRL = EN: the timer runs from here */

    /* warm-up: take three interrupts with the loop running, so that the handler's code is cached */
    csrsi mstatus, 8
warm:
    jal   ra, pass
    li    t0, IRQ_N
    lw    t1, 0(t0)
    li    t2, 3
    bltu  t1, t2, warm
    csrci mstatus, 8
    sw    zero, 0(t0)               /* the count and the log start again at the window */

ready:
    fence                           /* the barrier: nobody starts the window before every hart is ready */
    li    t0, BARRIER
    li    t1, 1
    amoadd.w x0, t1, (t0)
    lw    t2, 24(s1)                /* nactive */
wait0:
    lw    t3, 0(t0)
    bne   t3, t2, wait0
    fence
    jal   ra, pass                  /* untimed: see the header, "the cache starts warm" */

    csrr  s8, cycle                 /* the start of the window */
    li    s9, 0                     /* passes */
    li    s10, 1                    /* the checksum */
    csrsi mstatus, 8
loop0:
    jal   ra, pass
    add   s10, s10, a0
    addi  s9, s9, 1
    csrci mstatus, 8                /* masked, so the time and the count below are of the same stretch */
    csrr  t5, cycle
    sub   t5, t5, s8
    bgeu  t5, s5, finish
    csrsi mstatus, 8
    j     loop0

finish:
    li    t1, IRQ_N
    lw    s11, 0(t1)                /* interrupts taken in the window */
    li    t1, IRQ_BAD
    lw    t6, 0(t1)
    mul   t0, s9, s7
    addi  t0, t0, 1                 /* the checksum it should have */
    li    t2, RES0
    sw    s9, 4(t2)
    sw    t5, 8(t2)
    sw    s8, 12(t2)
    sw    s11, 16(t2)
    sw    t6, 20(t2)
    sw    s10, 24(t2)
    sw    t0, 28(t2)
    li    t1, 1
    beq   t0, s10, 1f
    li    t1, 2
1:  fence
    sw    t1, 0(t2)                 /* status last */
    j     park

/* One pass over the buffer: a0 = sum of buf[i] ^ i. A leaf, using only a-registers. */
pass:
    li    a1, VBUF
    li    a2, 0
    li    a3, 256
    li    a0, 0
1:  lw    a4, 0(a1)
    xor   a4, a4, a2
    add   a0, a0, a4
    addi  a1, a1, 4
    addi  a2, a2, 1
    bne   a2, a3, 1b
    ret

/* ---- the handler (software/soc/irqload_trap.S, with absolute addresses) ---- */
    .align 4
irq_vector:
    csrw  mscratch, t0              /* park t0; no memory has been touched yet */
    li    t0, TIMER
    lw    t0, 4(t0)                 /* lat: cycles since the wrap, as the timer saw it */
    csrw  sscratch, t0
    addi  sp, sp, -20
    sw    t1, 0(sp)
    sw    t2, 4(sp)
    sw    t3, 8(sp)
    sw    t4, 12(sp)
    csrr  t1, mscratch
    sw    t1, 16(sp)                /* the interrupted code's t0 */

    li    t1, PLIC_CLAIM
    lw    t2, 4(t1)                 /* claim: which source */
    li    t3, TIMER
    li    t4, 1
    sw    t4, 0x14(t3)              /* silence the timer (write 1 to clear) */
    sw    t2, 4(t1)                 /* complete */
    lw    t3, 4(t3)                 /* done: cycles since the wrap, with the interrupt served */
    csrr  t4, sscratch              /* lat */

    addi  t2, t2, -3
    beqz  t2, 1f
    li    t1, IRQ_BAD               /* a claim that was not the timer's: say so */
    li    t2, 1
    sw    t2, 0(t1)
1:  li    t1, IRQ_N
    lw    t2, 0(t1)
    addi  t0, t2, 1
    sw    t0, 0(t1)                 /* one more interrupt taken */
    li    t0, LOG_MAX
    bgeu  t2, t0, 3f                /* past the end of the log: counted, not logged */
    slli  t2, t2, 3
    li    t1, IRQ_LOG
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

3:  li    t0, 0x800                 /* the log is full: stop taking interrupts (MEIE), so a handler that   */
    csrc  mie, t0                   /* cannot silence its device ends the run instead of starving the loop */
    j     2b

/* ---- hart 1: stream2.S's loop, or park ---- */
hart1:
    lw    t0, 0(s1)
    andi  t0, t0, 2
    beqz  t0, park

    li    s2, RES1
    lw    s3, 16(s1)                /* base1 */
    lw    s5, 20(s1)                /* nwords */
    lw    s8, 12(s1)                /* window */
    slli  s7, s5, 2
    add   s7, s7, s3                /* end of the array */
    li    s9, 4096                  /* how much a block's sum grows from one block to the next */

    mv    t0, s3                    /* a[i] = i */
    li    t1, 0
init1:
    sw    t1, 0(t0)
    addi  t0, t0, 4
    addi  t1, t1, 1
    bne   t0, s7, init1

    fence
    li    t0, BARRIER
    li    t1, 1
    amoadd.w x0, t1, (t0)
    lw    t2, 24(s1)                /* nactive */
wait1:
    lw    t3, 0(t0)
    bne   t3, t2, wait1
    fence

    csrr  s6, cycle                 /* the start of the window */
    mv    a0, s3                    /* read pointer */
    li    a1, 2016                  /* the sum block 0 should have */
    li    s4, 0                     /* blocks read */
block:
    addi  a5, a0, 256               /* end of this 64-word block */
    li    a4, 0
inner:
    lw    t0, 0(a0)
    lw    t1, 4(a0)
    lw    t2, 8(a0)
    lw    t3, 12(a0)
    lw    t4, 16(a0)
    lw    t5, 20(a0)
    lw    t6, 24(a0)
    lw    a3, 28(a0)
    add   t0, t0, t1
    add   t2, t2, t3
    add   t4, t4, t5
    add   t6, t6, a3
    add   t0, t0, t2
    add   t4, t4, t6
    add   t0, t0, t4
    add   a4, a4, t0
    addi  a0, a0, 32
    bne   a0, a5, inner

    bne   a4, a1, bad
    addi  s4, s4, 1
    add   a1, a1, s9
    bne   a0, s7, nowrap
    mv    a0, s3                    /* back to the start of the array */
    li    a1, 2016
nowrap:
    csrr  t0, cycle
    sub   t0, t0, s6
    bltu  t0, s8, block             /* until the window is over */

    sw    s4, 4(s2)
    sw    t0, 8(s2)
    sw    s6, 12(s2)
    li    t1, 1
    fence
    sw    t1, 0(s2)                 /* status last */
    j     park

bad:
    csrr  t0, cycle
    sub   t0, t0, s6
    sw    s4, 4(s2)
    sw    t0, 8(s2)
    sw    s6, 12(s2)
    sw    s4, 16(s2)
    sw    a4, 20(s2)
    sw    a1, 24(s2)
    li    t1, 2
    fence
    sw    t1, 0(s2)

park:
    j     park
