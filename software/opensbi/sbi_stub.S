/* The three instructions OpenSBI needs before it can run.
 *
 * A RISC-V M-mode firmware is entered with a0 = hart ID and a1 = the address
 * of a flattened device tree. This core comes out of reset with every
 * register zero, so a1 = 0, and OpenSBI's generic platform - which is
 * entirely FDT-driven - has nothing to find. It does not limp along without
 * one; it cannot know what its console or timer even is.
 *
 * a0 is read from `mhartid` rather than hardcoded to 0, unlike a1: at
 * NUM_HARTS=1 (every board build, and every sim target before Phase 13
 * Stage 10) mhartid is always 0 so this made no observable difference, but
 * at NUM_HARTS=2 every hart resets into this exact same instruction stream
 * (soc_top.v's RESET_PC is shared), and `li a0, 0` would tell OpenSBI both
 * harts are hart 0 - the one thing a multi-hart SBI entry must never do,
 * since hart identity is how it tells the boot hart from every other one.
 *
 * So this sits at the reset vector, supplies both, and jumps. It is the
 * smallest possible stand-in for the boot ROM's eventual job of loading
 * firmware and handing it a device tree.
 *
 * The addresses are the layout software/opensbi/mkimage.py packs, and that
 * script checks they agree with the firmware's own ELF rather than trusting
 * this comment - practices.md section 11. Getting the DTB address wrong is
 * loud in the worst way: OpenSBI stops before printing anything, because
 * finding the console is the thing the FDT tells it how to do.
 *
 * 0x9008_0000 rather than something tidier because OpenSBI requires it. Its
 * linker script puts the read-write sections at the next power-of-2 boundary
 * above the read-only ones, and sbi_domain_init() then insists that
 * (_fw_rw_start - _fw_start) is itself a power of two and that _fw_start is
 * aligned to it. Both only hold if FW_TEXT_START is aligned to that rounded
 * size. Loaded at 0x9001_0000 the offset came out 0x70000, which is not a
 * power of two, and OpenSBI hung in sbi_hart_hang() with no console to say so.
 */
    .section .text
    .globl _start
_start:
    csrr    a0, mhartid             /* hart ID                */
    li      a1, 0x90008000          /* device tree blob       */
    li      t0, 0x90080000          /* OpenSBI's entry point  */
    jr      t0
