/* Entry point for the initramfs' /init.
 *
 * The kernel enters a userspace ELF with sp pointing at the argument block
 * and every other register unspecified, so there are exactly two things to
 * do before C: hand main the stack pointer, and never return.
 *
 * There is no libc here, deliberately - see software/linux/README.md. That
 * means no crt1.o, so this is the whole of the runtime: no __libc_start_main,
 * no constructors, no atexit, no gp.
 *
 * `.option norelax` and -mno-relax matter more than they look. The linker's
 * relaxation turns absolute symbol references into gp-relative ones, and gp
 * is set by crt1.o - which is not here. Without this, a string constant is
 * addressed off a register holding whatever the kernel left in x3.
 */
    .option norelax
    .section .text.startup, "ax", @progbits
    .globl _start
    .type  _start, @function
_start:
    mv      a0, sp                  /* argc, then argv[], then envp[] */
    tail    init_main               /* init_main never returns        */
    .size _start, . - _start
