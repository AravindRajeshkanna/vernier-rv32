/* Memory-bound streaming on up to four harts at once (Phase 8 Stage 3, Part 35).
 *
 * Part 27's workload (software/bench/stream2.S) with the parameter block widened from two harts to four, and
 * nothing else changed: each hart sweeps an array far bigger than its data cache, one word at a time, so that
 * nearly every load is a single-word read on the interconnect, for a fixed number of cycles. The harts' arrays
 * can be in the same memory or in two (the testbench chooses the base addresses), a hart can be run alone, and
 * the measure is how many words each gets through in the same window. A hart's rate alone against its rate
 * beside the others is the interference; the same figures over the bus and the router fabric are the
 * comparison. Part 27 ran two harts and guessed that the bus and the fabric might cross over at four, where
 * more masters raise the bus's contention and not the fabric's per-word cost. See sim/tb_soc_4hart_stream.v and
 * docs/roadmap/phase-08-noc.md, Part 35.
 *
 * One image, run by every hart from RESET_PC (every hart has the same one). It keeps all its state in
 * registers and in per-hart words of a RAM mailbox, so nothing needs a second link, as CoreMark does.
 *
 * The data cache is 256 words, direct-mapped, one word per entry (rtl/soc/cpu_wb.v), so an array of
 * 1024 words (4 KB) misses on every load of every pass: the entry a load wants was last used by the
 * word 1 KB behind it.
 *
 * Parameter block, written by the testbench before reset ends (0x8000_0200, one word each):
 *    +0   mode      bit h set: hart h streams; a hart whose bit is clear parks and does nothing
 *    +4   window    cycles each hart streams for, counted from the barrier
 *    +8   nwords    array length in words, a multiple of 64
 *    +12  start     the cycle count at which every window opens
 *    +16  base0     start of hart 0's array
 *    +20  base1     start of hart 1's array
 *    +24  base2     start of hart 2's array
 *    +28  base3     start of hart 3's array
 * (stream2.S has the window and nwords the other way round, a barrier counter at 0x8000_0240 and only two bases;
 * the two programs are not interchangeable.) Result block, 32 bytes per hart from 0x8000_0300:
 *    +0   status    0 running, 1 finished and every sum right, 2 a sum was wrong, 3 its array was not written by
 *                   the start time (written last)
 *    +4   blocks    64-word blocks read in the window
 *    +8   cycles    cycles from the start of the window to the end of the last block
 *    +12  start     the hart's cycle counter at the start of the window (written when the window opens)
 *    +16  failblk   (status 2) which block
 *    +20  got       (status 2) the sum it read
 *    +24  want      (status 2) the sum it should have read
 *
 * The array holds a[i] = i, written by each hart before the window, so a block of 64 words starting
 * at word 64*b sums to 4096*b + 2016, and each block's sum is checked as it is read: a word that is
 * stale, from the wrong address, or missing from a burst changes the sum. The check costs one
 * compare per 64 words and is inside the window on purpose, so what is measured is the loop that
 * is checked.
 */
.section .text.start
.global _start
_start:
    csrr  s0, mhartid
    li    s1, 0x80000200            /* parameter block */
    lw    t0, 0(s1)                 /* mode */
    srl   t0, t0, s0
    andi  t0, t0, 1
    beqz  t0, park                  /* not streaming */

    slli  s2, s0, 5                 /* this hart's result block */
    li    t1, 0x80000300
    add   s2, s2, t1
    slli  t1, s0, 2
    add   t1, t1, s1
    lw    s3, 16(t1)                /* this hart's array base: base0 at +16, base1 at +20, and so on */
    lw    s5, 8(s1)                 /* nwords */
    lw    s8, 4(s1)                 /* window */
    slli  s7, s5, 2
    add   s7, s7, s3                /* end of the array */
    li    s9, 4096                  /* how much a block's sum grows from one block to the next */

    /* a[i] = i */
    mv    t0, s3
    li    t1, 0
init:
    sw    t1, 0(t0)
    addi  t0, t0, 4
    addi  t1, t1, 1
    bne   t0, s7, init

    /* Start: every window opens at the same cycle count, agreed in advance (the mailbox's `start`), not when
     * the last hart has finished its array. Part 27's barrier did the second, and with four harts a hart that
     * the interconnect keeps starving cannot even read the barrier's counter for thousands of cycles, so it
     * started late and counted its uncontended tail as if it had been contended (the first measurement of
     * Part 35: a window start skew of 16,654 cycles of 200,000). All the harts read the same clock, which
     * counts from the same reset. A hart whose array is not written by then says so (status 3) and the
     * testbench fails the run. */
    fence
    lw    t2, 12(s1)                /* start */
    csrr  t0, cycle
    bgeu  t0, t2, late
wait:
    csrr  t0, cycle
    bltu  t0, t2, wait

    csrr  s6, cycle                 /* start of the window */
    sw    s6, 12(s2)                /* so that the testbench sees a hart that should have been parked streaming */
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
    sw    t1, 0(s2)                 /* status last: the testbench reads the rest once this is set */
    j     park

late:
    li    t1, 3
    fence
    sw    t1, 0(s2)
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
