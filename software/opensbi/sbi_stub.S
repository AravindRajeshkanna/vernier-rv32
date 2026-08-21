/* The three instructions OpenSBI needs before it can run.
 *
 * A RISC-V M-mode firmware is entered with a0 = hart ID and a1 = the address
 * of a flattened device tree. This core comes out of reset with every
 * register zero, so a1 = 0, and OpenSBI's generic platform - which is
 * entirely FDT-driven - has nothing to find. It does not limp along without
 * one; it cannot know what its console or timer even is.
 *
 * So this sits at the reset vector, supplies both, and jumps. It is the
 * smallest possible stand-in for the boot ROM's eventual job of loading
 * firmware and handing it a device tree.
 *
 * The addresses are the layout software/opensbi/mkimage.py packs, and nothing
 * checks that the two agree - practices.md section 11. Getting the DTB
 * address wrong is loud: OpenSBI stops before printing anything, because
 * finding the console is the thing the FDT tells it how to do.
 */
    .section .text
    .globl _start
_start:
    li      a0, 0                   /* hart ID                */
    li      a1, 0x90008000          /* device tree blob       */
    li      t0, 0x90010000          /* OpenSBI's entry point  */
    jr      t0
