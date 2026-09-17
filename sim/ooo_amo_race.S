/* Throwaway diagnostic (Phase 15 Stage 5 investigation), not part of the
 * shipped test suite. Both harts hammer amoswap.w on one shared lock word,
 * increment a shared counter inside the "critical section", then release.
 */
.section .text.start
.global _start
_start:
    csrr t0, mhartid
    lui  t1, 0x80000
    addi t1, t1, 0x100      /* lock addr: 0x8000_0100 */
    li   t2, 0
    li   t3, 5000
loop:
    li   t4, 1
acquire:
    amoswap.w t5, t4, (t1)
    bnez t5, acquire

    lui  t6, 0x80000
    addi t6, t6, 0x10C      /* shared counter: 0x8000_010C */
    lw   a0, 0(t6)
    addi a0, a0, 1
    sw   a0, 0(t6)

    sw   zero, 0(t1)        /* release */

    beqz t0, win0
    lui  a1, 0x80000
    addi a1, a1, 0x108      /* hart1 wins: 0x8000_0108 */
    j    countwin
win0:
    lui  a1, 0x80000
    addi a1, a1, 0x104      /* hart0 wins: 0x8000_0104 */
countwin:
    lw   a2, 0(a1)
    addi a2, a2, 1
    sw   a2, 0(a1)

    addi t2, t2, 1
    blt  t2, t3, loop
halt:
    j halt
