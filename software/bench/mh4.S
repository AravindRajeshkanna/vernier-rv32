/* Four harts, one image: atomics, a lock, LR/SC, cache coherence and reservations (Phase 8 Stage 3, Part 34).
 *
 * Every multi-hart test in this repository before this one ran two harts. Stage 3 asks for "a real check that the
 * reservation monitor and any future coherence traffic still work correctly once real routing sits between the
 * harts and the bus", at the size the network exists for: four or more. Nothing in rtl/soc/ is written for two
 * (reservation_monitor.v compares every hart's stores against every other's reservation, the data caches snoop
 * the memories and not the harts, the router fabric's ids have room for 14 masters at four harts), and a test
 * that only runs two harts cannot tell a design that scales from one that happens to work for a pair. See
 * sim/tb_soc_4hart.v and docs/roadmap/phase-08-noc.md, Part 34.
 *
 * One image, run by every hart from RESET_PC (every hart has the same one); `mhartid` picks the part. A hart with
 * an id of `nharts` or more parks, so the same image runs on one to four harts. Every phase ends in a barrier
 * (an AMO counter, polled with ordinary loads), and hart 0 checks the shared state after it:
 *
 *   P1  amoadd:  every hart adds 1 to one word `rounds` times: the word must end at nharts * rounds.
 *   P2  a lock:  amoswap spinlock around a plain load, add and store of another word, `rounds` times each: the
 *                word must end at nharts * rounds. Fails if the AMO is not atomic or a release is not seen.
 *   P3  LR/SC:   every hart increments a third word with lr/sc and retries, `rounds` times: it must end at
 *                nharts * rounds. The failed SCs are counted; a run in which none failed proved nothing about
 *                contention, and the testbench says so.
 *   P4  a ring:  a token goes round the harts by plain stores: hart h waits until SEQ equals its turn, checks
 *                the word the previous hart wrote, writes its own, and sets SEQ to the next turn. A cache that
 *                never sees another hart's store spins forever, or reads a stale word.
 *   P5  reservations, with every hart but 0 holding one on the same word (an LR and nothing that writes
 *                before the SC, because any write a hart makes clears its own reservation):
 *        5a  hart 0 stores to the word:       every holder's SC must fail.
 *        5b  hart 0 does an AMO on the word:  every holder's SC must fail.
 *        5c  nobody touches it but the holders: exactly one of their SCs may succeed (each success is a store
 *                that must kill the others' reservations, which is the part that is about more than two).
 *
 * The shared data sits at `base` in the mailbox: block RAM (0x8001_0000) or SDRAM (0x9000_0000). The mailbox,
 * the barrier, the error counter and the results stay in block RAM so that the testbench reads them directly;
 * hart 0 copies what it checked into the results, so the testbench never has to look inside the SDRAM.
 *
 * Mailbox (0x8000_0800, one word each):
 *    +0   nharts   how many harts take part (1 to 4)
 *    +4   base     start of the shared data
 *    +8   rounds   iterations of P1, P2 and P3 per hart
 *    +12  ring     rounds of P4
 *    +16  sets     rounds of each of 5a, 5b and 5c
 * Barrier 0x8000_0840; error count 0x8000_0880 (every hart adds to it, and it must end at 0).
 * Results, from 0x8000_0900, 64 bytes a hart (hart h at 0x8000_0900 + 64 * h):
 *    +0   status   0 running, 1 finished (written last)
 *    +4   scfail   failed SCs in P3
 *    +8   errors   what this hart found wrong, in total
 * and hart 0's observations, from 0x8000_0A00:
 *    +0   C1  +4 C2  +8 C3  +12 SC failures in P3 (all harts)  +16 SEQ at the end of P4
 *    +20  SC successes in 5c, summed over its rounds
 *    +24  the last value 5a wrote  +28 the phases hart 0 found wrong (bit n = P(n+1))
 */
.equ MAILBOX,  0x80000800
.equ BARRIER,  0x80000840
.equ ERRORS,   0x80000880
.equ RESULTS,  0x80000900
.equ OBSERVED, 0x80000A00

/* offsets from `base` */
.equ O_C1,   0x000
.equ O_LOCK, 0x040
.equ O_C2,   0x080
.equ O_C3,   0x0C0
.equ O_SCF,  0x0E0
.equ O_SEQ,  0x100
.equ O_RING, 0x140
.equ O_W,    0x200
.equ O_FLAG, 0x240
.equ O_GO,   0x280
.equ O_SUCC, 0x2C0

.section .text.start
.global _start
_start:
    csrr  s0, mhartid
    li    s1, MAILBOX
    lw    s2, 4(s1)                 /* base */
    lw    s3, 8(s1)                 /* rounds */
    lw    s4, 12(s1)                /* ring rounds */
    lw    s8, 16(s1)                /* sets */
    lw    s1, 0(s1)                 /* nharts */
    bgeu  s0, s1, park              /* not taking part */
    li    s5, 0                     /* barriers passed */
    li    s7, 0                     /* this hart's failed SCs (P3) */
    li    s9, 0                     /* this hart's own error count */

/* The shared words start at zero, which block RAM does and the SDRAM does not: its model (and the chip) powers
 * up with whatever it holds, so a first version that took the zero for granted spun forever in P3 on an SC
 * whose result was X. Hart 0 clears them, and nobody touches them before the barrier. */
    bnez  s0, init_done
    mv    t0, s2
    addi  t1, s2, 0x300
init_zero:
    sw    zero, 0(t0)
    addi  t0, t0, 4
    bne   t0, t1, init_zero
init_done:
    jal   ra, barrier

/* ---- P1: amoadd ---- */
    li    s6, 0
p1:
    bgeu  s6, s3, p1_done
    addi  t0, s2, O_C1
    li    t1, 1
    amoadd.w x0, t1, (t0)
    addi  s6, s6, 1
    j     p1
p1_done:
    jal   ra, barrier
    bnez  s0, p1_after
    addi  t0, s2, O_C1
    lw    t1, 0(t0)
    li    t2, OBSERVED
    sw    t1, 0(t2)
    mul   t3, s1, s3
    beq   t1, t3, p1_after
    jal   ra, bad_phase_1
p1_after:

/* ---- P2: a lock around a plain increment ---- */
    li    s6, 0
p2:
    bgeu  s6, s3, p2_done
    addi  t0, s2, O_LOCK
p2_acquire:
    li    t1, 1
    amoswap.w t2, t1, (t0)
    bnez  t2, p2_acquire
    fence
    addi  t3, s2, O_C2
    lw    t4, 0(t3)
    addi  t4, t4, 1
    sw    t4, 0(t3)
    fence
    amoswap.w x0, x0, (t0)          /* release */
    addi  s6, s6, 1
    j     p2
p2_done:
    jal   ra, barrier
    bnez  s0, p2_after
    addi  t0, s2, O_C2
    lw    t1, 0(t0)
    li    t2, OBSERVED
    sw    t1, 4(t2)
    mul   t3, s1, s3
    beq   t1, t3, p2_after
    jal   ra, bad_phase_2
p2_after:

/* ---- P3: LR/SC increments ---- */
    li    s6, 0
p3:
    bgeu  s6, s3, p3_done
    addi  t0, s2, O_C3
p3_retry:
    lr.w  t1, (t0)
    addi  t1, t1, 1
    sc.w  t2, t1, (t0)
    beqz  t2, p3_ok
    addi  s7, s7, 1                 /* a failed SC */
    j     p3_retry
p3_ok:
    addi  s6, s6, 1
    j     p3
p3_done:
    addi  t0, s2, O_SCF
    amoadd.w x0, s7, (t0)
    li    t0, RESULTS
    slli  t1, s0, 6
    add   t0, t0, t1
    sw    s7, 4(t0)
    jal   ra, barrier
    bnez  s0, p3_after
    addi  t0, s2, O_C3
    lw    t1, 0(t0)
    li    t2, OBSERVED
    sw    t1, 8(t2)
    addi  t0, s2, O_SCF
    lw    t4, 0(t0)
    sw    t4, 12(t2)
    mul   t3, s1, s3
    beq   t1, t3, p3_after
    jal   ra, bad_phase_3
p3_after:

/* ---- P4: a token round the ring ---- */
    li    s6, 0
p4:
    bgeu  s6, s4, p4_done
    mul   t0, s6, s1
    add   t0, t0, s0                /* my turn: round * nharts + hart */
    addi  t1, s2, O_SEQ
p4_wait:
    lw    t2, 0(t1)
    bne   t2, t0, p4_wait
    fence
    beqz  t0, p4_write              /* the very first turn has no predecessor */
    addi  t3, s0, -1                /* the previous hart: h - 1, or the last one for hart 0 */
    bgez  t3, p4_prev
    addi  t3, s1, -1
p4_prev:
    slli  t3, t3, 2
    addi  t4, s2, O_RING
    add   t4, t4, t3
    lw    t5, 0(t4)                 /* what it wrote */
    addi  t6, t0, -1
    addi  t6, t6, 0x100             /* its turn plus a tag */
    beq   t5, t6, p4_write
    addi  s9, s9, 1                 /* a stale or wrong word */
p4_write:
    addi  t3, t0, 0x100
    slli  t4, s0, 2
    addi  t5, s2, O_RING
    add   t4, t4, t5
    sw    t3, 0(t4)
    fence                           /* the data before the token */
    addi  t3, t0, 1
    sw    t3, 0(t1)
    addi  s6, s6, 1
    j     p4
p4_done:
    jal   ra, barrier
    bnez  s0, p4_after
    addi  t0, s2, O_SEQ
    lw    t1, 0(t0)
    li    t2, OBSERVED
    sw    t1, 16(t2)
    mul   t3, s1, s4
    beq   t1, t3, p4_after
    jal   ra, bad_phase_4
p4_after:

/* ---- P5: reservations held by every hart but 0 ---- */
    li    t0, 2
    bltu  s1, t0, p5_done           /* one hart has nobody to invalidate it */

    /* 5a: hart 0 stores to the word */
    li    s6, 0
p5a:
    bgeu  s6, s8, p5a_done
    jal   ra, barrier
    beqz  s0, p5a_writer
    addi  t0, s2, O_W
    lr.w  t1, (t0)
    addi  t2, s2, O_FLAG
    addi  t5, s6, 1
p5a_poll:
    lw    t3, 0(t2)                 /* reads only: a load does not clear a reservation */
    bne   t3, t5, p5a_poll
    sc.w  t4, t1, (t0)
    bnez  t4, p5a_next              /* failed, as it must */
    addi  s9, s9, 1                 /* the SC succeeded over a foreign store */
    j     p5a_next
p5a_writer:
    jal   ra, delay
    addi  t0, s2, O_W
    addi  t1, s6, 0x500
    sw    t1, 0(t0)
    li    t2, OBSERVED
    sw    t1, 24(t2)
    fence
    addi  t2, s2, O_FLAG
    addi  t3, s6, 1
    sw    t3, 0(t2)
p5a_next:
    addi  s6, s6, 1
    j     p5a
p5a_done:

    /* 5b: hart 0 does an AMO on the word */
    li    s6, 0
p5b:
    bgeu  s6, s8, p5b_done
    jal   ra, barrier
    beqz  s0, p5b_writer
    addi  t0, s2, O_W
    lr.w  t1, (t0)
    addi  t2, s2, O_FLAG
    addi  t5, s6, 0x101             /* flags of 5b are 0x101, 0x102, ... so as not to repeat 5a's */
p5b_poll:
    lw    t3, 0(t2)
    bne   t3, t5, p5b_poll
    sc.w  t4, t1, (t0)
    bnez  t4, p5b_next
    addi  s9, s9, 1
    j     p5b_next
p5b_writer:
    jal   ra, delay
    addi  t0, s2, O_W
    li    t1, 7
    amoadd.w x0, t1, (t0)
    fence
    addi  t2, s2, O_FLAG
    addi  t3, s6, 0x101
    sw    t3, 0(t2)
p5b_next:
    addi  s6, s6, 1
    j     p5b
p5b_done:

    /* 5c: only the holders write: at most one SC of a round may succeed */
    li    s6, 0
p5c:
    bgeu  s6, s8, p5c_done
    jal   ra, barrier
    beqz  s0, p5c_go
    addi  t0, s2, O_W
    lr.w  t1, (t0)
    addi  t2, s2, O_GO
    addi  t5, s6, 1
p5c_poll:
    lw    t3, 0(t2)
    bne   t3, t5, p5c_poll
    sc.w  t4, t1, (t0)
    bnez  t4, p5c_next
    addi  t6, s2, O_SUCC            /* a success: count it */
    li    t1, 1
    amoadd.w x0, t1, (t6)
    j     p5c_next
p5c_go:
    jal   ra, delay
    addi  t2, s2, O_GO
    addi  t3, s6, 1
    sw    t3, 0(t2)
p5c_next:
    addi  s6, s6, 1
    j     p5c
p5c_done:
    jal   ra, barrier
    bnez  s0, p5_done
    addi  t0, s2, O_SUCC
    lw    t1, 0(t0)
    li    t2, OBSERVED
    sw    t1, 20(t2)
    bne   t1, s8, p5_bad            /* exactly one success a round */
    j     p5_done
p5_bad:
    jal   ra, bad_phase_5
p5_done:

/* ---- finish ---- */
    jal   ra, barrier
    beqz  s9, finish_ok
    li    t0, ERRORS
    amoadd.w x0, s9, (t0)
finish_ok:
    li    t0, RESULTS
    slli  t1, s0, 6
    add   t0, t0, t1
    sw    s9, 8(t0)
    fence
    li    t1, 1
    sw    t1, 0(t0)                 /* status last */
park:
    j     park

/* ---- helpers ---- */

/* Wait until every hart taking part has got here: the counter reaches (barriers passed) * nharts. Polled with
 * loads, so it can go past the target while a slow hart is still looking, which is why it is a >=. */
barrier:
    addi  s5, s5, 1
    fence
    li    t0, BARRIER
    li    t1, 1
    amoadd.w x0, t1, (t0)
    mul   t2, s5, s1
barrier_wait:
    lw    t3, 0(t0)
    bltu  t3, t2, barrier_wait
    fence
    ret

/* Long enough for every holder to have done its LR. */
delay:
    csrr  t0, cycle
    addi  t0, t0, 700
delay_wait:
    csrr  t1, cycle
    bltu  t1, t0, delay_wait
    ret

/* What hart 0 found wrong: note the phase, and count it as an error. */
bad_phase_1:
    li    t0, 1
    j     bad_phase
bad_phase_2:
    li    t0, 2
    j     bad_phase
bad_phase_3:
    li    t0, 4
    j     bad_phase
bad_phase_4:
    li    t0, 8
    j     bad_phase
bad_phase_5:
    li    t0, 16
bad_phase:
    li    t1, OBSERVED
    lw    t2, 28(t1)
    or    t2, t2, t0
    sw    t2, 28(t1)
    addi  s9, s9, 1
    ret
