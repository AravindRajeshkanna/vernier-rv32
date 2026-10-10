/* Linker script for the two-hart interrupt program (Phase 8 Stage 3, Part 32). The program sits at
 * RESET_PC, which every hart shares. The 2 KB region ends where the testbench's mailbox starts
 * (0x8000_0800); the ASSERT turns a program that grew into it into a build failure instead of a
 * silent overlap. See irq2.S for the memory map. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    CODE (rx) : ORIGIN = 0x80000000, LENGTH = 2K
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
    } > CODE
}

ASSERT(SIZEOF(.text) <= 2048,
       "irq2.S grew into the mailbox at 0x8000_0800")
