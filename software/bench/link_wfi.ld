/* Linker script for the waiting-wfi program (Phase 8 Stage 4, Part 38). The program sits at RESET_PC, which every hart
 * shares. The 2 KB region ends at 0x8000_0800, below the result and flag words (0x8000_0900 is the lowest); the ASSERT
 * turns a program that grew past it into a build failure instead of a silent overlap. See wfi.S for the memory map. */
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
       "wfi.S grew past 0x8000_0800, towards the results at 0x8000_0900")
