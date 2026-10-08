/* Linker script for the two-hart streaming program (Phase 8 Stage 3, Part 27). The program sits at
 * RESET_PC, which every hart shares. The 512-byte region ends where the testbench's parameter block
 * starts (0x8000_0200); the ASSERT turns a program that grew into it into a build failure instead of
 * a silent overlap. See stream2.S for the mailbox layout. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    CODE (rx) : ORIGIN = 0x80000000, LENGTH = 512
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
    } > CODE
}

ASSERT(SIZEOF(.text) <= 512,
       "stream2.S grew into the parameter block at 0x8000_0200")
