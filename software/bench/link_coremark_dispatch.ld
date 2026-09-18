/* Linker script for the shared reset-vector dispatcher, dual-hart CoreMark
 * harness (Phase 15 Stage 5). See coremark_dispatch.S's own header for what
 * this does and why it has to sit exactly at RESET_PC.
 *
 * The 256-byte region leaves the dispatcher room to grow a little without
 * colliding with core_portme.c's own COREMARK_LOCK_ADDR (0x8000_0100,
 * immediately past the end of this region) - the ASSERT below is what turns
 * a collision into a build failure instead of a silent, wrong overlap.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    DISPATCH (rx) : ORIGIN = 0x80000000, LENGTH = 256
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
    } > DISPATCH
}

ASSERT(SIZEOF(.text) <= 256,
       "coremark_dispatch.S grew past the console-lock word at 0x8000_0100")
