OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4K }
SECTIONS {
    .text : { *(.text.start) *(.text*) } > RAM
}
