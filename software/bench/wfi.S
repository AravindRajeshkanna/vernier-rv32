/* A wfi that waits (Phase 8 Stage 4, Part 38).
 *
 * Both cores execute wfi as a no-op, which the privileged specification allows, and Part 37 found what that
 * costs on a shared interconnect: the harts that are waiting for work poll, and the poll takes the cycles
 * the hart that has work needs. This is the test of the cure, a wfi that stops the hart until an interrupt it
 * has enabled is pending (the build parameter WFI_WAIT of cpu_core.v and core_ooo.v, soc_top's WFI_WAIT). It
 * fails, by design, on a wfi that does not wait. See sim/tb_soc_wfi.v.
 *
 * Hart 0 runs six tests and measures, with its cycle counter, how long the wfi took; hart 1 does what hart 0
 * cannot do to itself (it sends the software interrupt, and sets the timer, at fixed delays). The wake-up
 * condition is the specification's: any interrupt that is enabled in mie and pending in mip, whatever
 * mstatus.MIE says; only an enabled interrupt may end the wait.
 *
 *    T1   the timer, 3,000 cycles ahead, with interrupts globally off. The wfi must last about 3,000 cycles.
 *    T2   the timer already due. The wfi must fall through at once: a wait must not wait for nothing.
 *    T3   a software interrupt from hart 1 after 4,000 cycles (the path a sleeping hart is woken by).
 *    T4   a software interrupt from hart 1 after 2,000 cycles but not enabled in mie, then, after another 4,000, the
 *         timer, which is. The wfi must last about 6,000 cycles: a pending interrupt that is not enabled
 *         does not wake it.
 *    T5   the timer, 2,500 cycles ahead, with interrupts globally on. The interrupt must be taken once the wfi has
 *         completed: mepc is the instruction after it, as the specification says, and not the wfi (which
 *         would run again after the handler's mret, and wait for an interrupt that never comes).
 *    T6   a wfi in user mode, which is illegal here: it must trap at once, not wait.
 *
 * One image, run by both harts from RESET_PC. Flag word: 0x8000_0A00 (the test phase, written by hart 0 and
 * read by hart 1). Results, one word each, hart 0's from 0x8000_0900 and hart 1's from 0x8000_0940 (status last):
 *    +0   status      0 running, 1 finished
 *    +4   T1          cycles the wfi took
 *    +8   T2
 *    +12  T3
 *    +16  T4
 *    +20  T5          cycles from before the wfi to the instruction after it
 *    +24  T5 count    interrupts the handler took
 *    +28  T5 mepc     the handler's mepc
 *    +32  T5 want     the address of the instruction after the wfi
 *    +36  T5 handler  the handler's cycle counter minus the cycle counter before the wfi
 *    +40  T6 cause    mcause of the trap the user-mode wfi took (2, illegal instruction)
 *    +44  T6          cycles from the mret to user mode to the machine-mode code the handler returned to
 *    +48  bad         traps that were not expected
 *    +52  bad cause   mcause of the last of them
 */
    .equ CLINT,      0x02000000
    .equ CMP0,       0x02004000          /* mtimecmp of hart 0 (the high word is at +4) */
    .equ MTIME,      0x0200BFF8          /* mtime, low word */
    .equ RES0,       0x80000900
    .equ RES1,       0x80000940
    .equ FLAGS,      0x80000A00

    .equ R_STATUS,   0
    .equ R_T1,       4
    .equ R_T2,       8
    .equ R_T3,       12
    .equ R_T4,       16
    .equ R_T5,       20
    .equ R_T5N,      24
    .equ R_T5MEPC,   28
    .equ R_T5WANT,   32
    .equ R_T5H,      36
    .equ R_T6CAUSE,  40
    .equ R_T6,       44
    .equ R_BAD,      48
    .equ R_BADCAUSE, 52

    /* Spin until n more cycles have gone by. Uses t0 and t1. */
    .macro DELAY n
    csrr    t0, cycle
    li      t1, \n
    add     t0, t0, t1
1:  csrr    t1, cycle
    bltu    t1, t0, 1b
    .endm

    /* mtimecmp := mtime + n; the high word is held at all ones while the low word changes, so that no
     * half-written value is ever below mtime. s4 is CMP0 and s5 is MTIME. Uses t0 and t1. */
    .macro ARM n
    lw      t0, 0(s5)
    li      t1, \n
    add     t0, t0, t1
    li      t1, -1
    sw      t1, 4(s4)
    sw      t0, 0(s4)
    sw      zero, 4(s4)
    .endm

    /* mtimecmp := all ones: the timer never fires. Uses t1. */
    .macro DISARM
    li      t1, -1
    sw      t1, 4(s4)
    sw      t1, 0(s4)
    .endm

    .section .text.start
    .globl _start
_start:
    csrr    a0, mhartid
    bnez    a0, hart1

/* ---- hart 0: the tests ---- */
hart0:
    la      t0, trap_handler
    csrw    mtvec, t0
    li      s0, CLINT
    li      s4, CMP0
    li      s5, MTIME
    li      s1, FLAGS
    li      s2, RES0
    DISARM
    csrci   mstatus, 8                   /* interrupts globally off, for T1 to T4 and T6 */

    /* T1 */
    li      t0, 0x80                     /* MTIE */
    csrw    mie, t0
    ARM     3000
    csrr    a1, cycle
    wfi
    csrr    a2, cycle
    sub     a2, a2, a1
    sw      a2, R_T1(s2)
    DISARM

    /* T2: due already (mtimecmp 0), so mip.MTIP is set before the wfi */
    li      t1, -1
    sw      t1, 4(s4)
    sw      zero, 0(s4)
    sw      zero, 4(s4)
    csrr    a1, cycle
    wfi
    csrr    a2, cycle
    sub     a2, a2, a1
    sw      a2, R_T2(s2)
    DISARM

    /* T3: hart 1 sends the software interrupt 4,000 cycles after it sees phase 3 */
    li      t0, 8                        /* MSIE */
    csrw    mie, t0
    li      t0, 3
    sw      t0, 0(s1)
    csrr    a1, cycle
    wfi
    csrr    a2, cycle
    sw      zero, 0(s0)                  /* take the software interrupt away: msip[0] := 0 */
    sub     a2, a2, a1
    sw      a2, R_T3(s2)

    /* T4: only the timer is enabled; hart 1 raises the software interrupt after 2,000 cycles (pending, not
     * enabled) and the timer 4,000 later */
    li      t0, 0x80                     /* MTIE only */
    csrw    mie, t0
    li      t0, 4
    sw      t0, 0(s1)
    csrr    a1, cycle
    wfi
    csrr    a2, cycle
    sw      zero, 0(s0)
    sub     a2, a2, a1
    sw      a2, R_T4(s2)
    DISARM

    /* T5: the timer with interrupts on; the handler counts it and puts the timer away */
    sw      zero, R_T5N(s2)
    la      t0, t5_after
    sw      t0, R_T5WANT(s2)
    ARM     2500
    csrr    a1, cycle
    sw      a1, R_T5H(s2)                /* the handler subtracts this from its own reading */
    csrsi   mstatus, 8
    wfi
t5_after:
    csrr    a2, cycle
    csrci   mstatus, 8
    sub     a2, a2, a1
    sw      a2, R_T5(s2)
    DISARM

    /* T6: a wfi in user mode traps at once. The handler sends the hart back to machine mode at u_return. */
    li      t0, -1
    csrw    pmpaddr0, t0                 /* user mode may touch all of memory (NAPOT, rwx) */
    li      t0, 0x1f
    csrw    pmpcfg0, t0
    la      t0, u_code
    csrw    mepc, t0
    li      t0, 0x1800
    csrc    mstatus, t0                  /* MPP := user */
    csrr    a1, cycle
    mret
u_code:
    wfi
    j       u_code
u_return:
    csrr    a2, cycle
    sub     a2, a2, a1
    sw      a2, R_T6(s2)

    li      t0, 1
    fence
    sw      t0, R_STATUS(s2)
park0:
    j       park0

/* ---- the trap handler (hart 0). It uses t5 and t6 only. ---- */
    .balign 4
trap_handler:
    csrr    t5, mcause
    li      t6, 0x80000007               /* machine timer interrupt */
    bne     t5, t6, not_timer
    csrr    t6, cycle
    lw      t5, R_T5H(s2)
    sub     t6, t6, t5
    sw      t6, R_T5H(s2)                /* handler cycle - cycle before the wfi */
    csrr    t6, mepc
    sw      t6, R_T5MEPC(s2)
    li      t6, -1
    sw      t6, 4(s4)                    /* put the timer away: mtimecmp := all ones */
    sw      t6, 0(s4)
    lw      t6, R_T5N(s2)
    addi    t6, t6, 1
    sw      t6, R_T5N(s2)
    mret
not_timer:
    li      t6, 2                        /* illegal instruction: the user-mode wfi */
    bne     t5, t6, unexpected
    sw      t5, R_T6CAUSE(s2)
    la      t6, u_return
    csrw    mepc, t6
    li      t6, 0x1800
    csrs    mstatus, t6                  /* MPP := machine */
    mret
unexpected:
    lw      t6, R_BAD(s2)
    addi    t6, t6, 1
    sw      t6, R_BAD(s2)
    sw      t5, R_BADCAUSE(s2)
1:  j       1b

/* ---- hart 1: the helper ---- */
hart1:
    li      s0, CLINT
    li      s4, CMP0
    li      s1, FLAGS
    li      s3, RES1
w3: lw      t0, 0(s1)
    li      t1, 3
    bltu    t0, t1, w3                   /* phase 3 or later: a hart 0 that did not wait must not leave this behind */
    DELAY   4000
    li      t0, 1
    sw      t0, 0(s0)                    /* msip[0] := 1 */
w4: lw      t0, 0(s1)
    li      t1, 4
    bltu    t0, t1, w4
    DELAY   2000
    li      t0, 1
    sw      t0, 0(s0)                    /* pending in mip, not enabled in mie */
    DELAY   4000
    li      t1, -1
    sw      t1, 4(s4)
    sw      zero, 0(s4)
    sw      zero, 4(s4)                  /* hart 0's mtimecmp := 0: the timer is due */
    li      t0, 1
    sw      t0, R_STATUS(s3)
park1:
    j       park1
