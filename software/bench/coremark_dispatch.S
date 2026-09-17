/* Shared reset-vector dispatcher for the dual-hart CoreMark harness
 * (Phase 15 Stage 5). Both harts fetch this same instruction stream at
 * RESET_PC (rtl/soc/soc_top.v gives every hart the identical RESET_PC
 * parameter - see that file's hart-0 instantiation and its g_hart generate
 * loop, and every existing NUM_HARTS=2 test already relies on this). Each
 * hart reads its own real mhartid and jumps to its own independently-linked
 * CoreMark image - see link_bench_hart0.ld/link_bench_hart1.ld for the two
 * target addresses, which MUST match the two immediates below exactly. A
 * duplicated constant across three files: if they drift, a hart jumps into
 * the middle of the other hart's image instead of its own _start, and
 * core_portme.c's COREMARK_DUAL_HART check in portable_init() is what
 * catches that mismatch at runtime.
 *
 * Both targets are 4 KiB-aligned by construction, so a single lui produces
 * the exact address with no addi needed.
 */
.section .text.start
.global _start
_start:
    csrr t0, mhartid
    bnez t0, hart1
    lui  t1, 0x80001      /* hart 0 -> 0x8000_1000, link_bench_hart0.ld's ORIGIN */
    jr   t1
hart1:
    lui  t1, 0x80040      /* hart 1 -> 0x8004_0000, link_bench_hart1.ld's ORIGIN */
    jr   t1
