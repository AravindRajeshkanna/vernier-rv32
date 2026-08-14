/* Linker script for the RAM program - the image the boot ROM pulls off SD, or
 * that a preloading bitstream bakes in.
 *
 * ---- Why .data is loaded at one address and lives at another ----
 *
 * .data used to sit immediately after .text, at the address it was loaded to,
 * and was never re-initialised. That is fine exactly once. Block RAM is
 * initialised at FPGA *configuration* time, so pressing reset re-runs the
 * program over memory the previous run already wrote: _start zeroes .bss, and
 * nothing restored .data. The second run started with .data holding whatever
 * the first run left there.
 *
 * That cost a long time to find, because what it broke was newlib's stdio and
 * nothing else. `__sinit` returns early if `_impure_data.__cleanup` is
 * non-NULL, and __sinit *sets* __cleanup on success - so run 2 saw its own
 * guard from run 1, skipped initialisation, and left stdout permanently
 * unusable. printf then returned -1 and printed nothing, which looked exactly
 * like printf hanging. The SD path hid it completely, because there the loader
 * copies the whole image on every boot.
 *
 * So the initial values now live in LOAD, which nothing ever writes, and .data
 * runs in RUN, which crt0_ram.S copies into on every startup. The program
 * survives a reset because it rebuilds its own writable state.
 *
 * The image on the wire is unchanged: .data's *load* address still follows
 * .text contiguously, so `objcopy -O binary` still produces one flat blob and
 * the loader still copies it to PROGRAM_LOAD_ADDR knowing nothing about
 * sections.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    /* One 64 KB RAM, split so .data's initial values have an address of their
     * own. The origin must match PROGRAM_LOAD_ADDR in software/soc/soc.h - the
     * loader jumps to a hardcoded address, so a mismatch would branch into the
     * middle of the image rather than its entry point.
     *
     * LOAD: .text, .rodata, and the pristine copy of .data. Read-only at
     *       runtime, which is what makes it a safe place to keep the copy.
     * RUN:  .data and .bss as the program actually uses them, then the heap.
     *
     * The 4 KB hole between them at 0x8000_8000 is deliberate: it is the
     * region software/soc/main.c's memory tests hammer. Keeping it outside
     * both regions means those tests cannot reach code, initial values, or
     * live data no matter how the program grows - the linker enforces it
     * rather than a comment asking nicely. */
    LOAD (rx) : ORIGIN = 0x80001000, LENGTH = 28K   /* ..0x8000_8000 */
    RUN  (rw) : ORIGIN = 0x80009000, LENGTH = 24K   /* ..0x8000_F000 */
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text*)
        *(.rodata*)
        *(.srodata*)
        . = ALIGN(4);
    } > LOAD

    /* > RUN AT> LOAD is the whole fix: addressed in RUN, carried in LOAD.
     * Word-aligned at both ends because crt0_ram.S copies it a word at a
     * time. */
    .data : ALIGN(4) {
        _sdata = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        _edata = .;
    } > RUN AT> LOAD

    _sidata = LOADADDR(.data);
    _eidata = LOADADDR(.data) + SIZEOF(.data);

    .bss (NOLOAD) : {
        _bss_start = .;

        /* A private stack for the fatal-trap reporter (crt0_ram.S switches to
         * it before calling trap_report). It exists so that a report still
         * comes out when the fault being reported is a wild or overflowed sp -
         * which is precisely the case where the report is worth most, and the
         * one where reusing the faulting code's stack would double-fault.
         *
         * Inside .bss so crt0 zeroes it and it costs nothing in the image;
         * 512 bytes because the reporter's whole call graph is trap_report and
         * console.c. At the *front* of .bss deliberately: at the back, its top
         * would coincide with _end, which is where syscalls.c starts the heap,
         * and two things growing in opposite directions from one address is a
         * question nobody should have to answer twice. */
        . = ALIGN(16);
        _trap_stack_bottom = .;
        . = . + 512;
        _trap_stack_top = .;

        *(.bss*)
        *(.sbss*)
        *(COMMON)
        _bss_end = .;
    } > RUN

    _end = .;

    PROVIDE(__global_pointer$ = _bss_start + 0x800);

    /* Stack grows down from the top of RAM.
     *
     * 64 KB, not the 256 KB soc_top.v provides in simulation: see
     * software/soc/soc.h's RAM_SIZE for why the firmware targets the smaller
     * size. Simulation is unaffected - the firmware simply uses the low 64 KB
     * of a larger memory. */
    _stack_top = 0x80010000;

    /* Both of these are enforced by the region lengths above; they are spelled
     * out because "RUN overflowed by 112 bytes" does not tell you which of the
     * program's neighbours it has started standing on. */
    ASSERT(_eidata <= 0x80008000,
           "program image has grown into the memory-test region at 0x80008000")
    ASSERT(_end <= 0x8000F000,
           ".bss reaches the heap ceiling - no room left for a heap")
}
