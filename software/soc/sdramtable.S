/* 96 KB of read-only data, so that the program in software/soc/sdramtest.c
 * is one that cannot be linked into 64 KB of block RAM.
 *
 * That is the whole point of it. docs/roadmap.md's Phase 2 is "done when the
 * SoC runs a program larger than 64 KB from external memory", and a test that
 * merely *writes* past 64 KB would not show it: block RAM's 16 MB window
 * aliases rather than faulting (see sim/tb_ramboot.v's header), so a sweep
 * over 256 KB of block RAM completes and reports success while quietly
 * writing the same 64 KB four times. Only a program whose own image exceeds
 * the block RAM can fail to be a block RAM program.
 *
 * Each word holds its own byte offset from the start of the table, so the
 * table checks itself with no generator script and no committed blob: a
 * dropped address bit, a row that lost its contents to a missed refresh, or a
 * 16-bit half landing in the wrong column all produce a word that does not
 * equal its index, and sdramtest.c reports the first one by address.
 */
    .section .rodata
    .balign 4
    .globl  sdram_table
    .globl  sdram_table_words
sdram_table:
    .set    off, 0
    .rept   24576                   /* 24576 * 4 = 98304 bytes = 96 KB */
    .word   off
    .set    off, off + 4
    .endr

    .balign 4
sdram_table_words:
    .word   24576
