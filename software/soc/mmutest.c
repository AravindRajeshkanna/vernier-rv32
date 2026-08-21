/* Sv32 with the page tables in external SDRAM, and the top half of the part
 * reachable at all.
 *
 * Two changes are under test here and they are deliberately in one program,
 * because each one is what makes the other observable.
 *
 *   1. **The walkers are bus masters.** They used to read PTEs through a
 *      private second port on wb_ram.v's block RAM, so a page table could
 *      live in block RAM and nowhere else. An SDRAM has one port. Linux puts
 *      page tables in DRAM. rtl/soc/wb_ptw.v is the fix; this is the program
 *      that would not have worked before it.
 *   2. **The SDRAM window is 32 MB, not 16.** wb_interconnect.v decoded
 *      addr[31:24] by equality, so one base byte bought one 16 MB slave and
 *      the upper half of a 32 MB part was unmapped. It now decodes through a
 *      per-slave mask.
 *
 * The root page table is placed in SDRAM, above the old 16 MB ceiling, so a
 * failure of either change stops this program rather than degrading it
 * quietly:
 *
 *   - without (1) the first translated access walks into block RAM instead,
 *     reads whatever happens to be at that offset - almost certainly not a
 *     valid PTE - and takes a page fault the test did not arm;
 *   - without (2) the whole table is above the decode ceiling, matches no
 *     slave, and reads back as 1024 zero PTEs, because wb_interconnect.v acks
 *     unmapped addresses with zeros on purpose. All invalid, and again a
 *     fault where none was armed.
 *
 * Both failures are loud. Neither is a wrong answer that could be mistaken
 * for a passing run, which is what practices.md section 1 asks of a test.
 *
 * ---- What runs where ----
 *
 * The program itself lives in block RAM (link_ram.ld) and starts in M-mode
 * with translation off. That is what lets it build a page table in SDRAM
 * using physical addresses before anything depends on the table being right.
 * It then enters S-mode, where *instruction fetch is translated too* - so
 * from that point every fetch and every load and store that misses the TLB
 * costs a walk into SDRAM, and simply continuing to execute is the check.
 *
 * No libc - see software/soc/main.c's header for the incident that settled
 * that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

/* ---- Sv32 ----
 *
 * A 32-bit VA is VPN[1] (31:22) | VPN[0] (21:12) | offset. A level-1 leaf
 * PTE maps 4 MB - a "megapage" - which is what every entry here is, so one
 * 1024-entry root table covers the whole address space and there is no second
 * level to walk. That is not laziness: the point of the test is *where the
 * PTE was read from*, and one level keeps the failure attributable.
 *
 * PTE layout: PPN[1] (31:20) | PPN[0] (19:10) | RSW (9:8) | D A G U X W R V.
 * A megapage needs PPN[0] == 0, which mmu.v checks (`misaligned1`) and faults
 * on if it is not.
 */
#define PTE_V (1u << 0)
#define PTE_R (1u << 1)
#define PTE_W (1u << 2)
#define PTE_X (1u << 3)
#define PTE_U (1u << 4)
#define PTE_A (1u << 6)
#define PTE_D (1u << 7)

/* A and D are set on every entry because this core does not update them in
 * hardware - mmu.v's perm_ok() faults on a missing A, and on a missing D for
 * a store. Linux sets them itself for the same reason on cores like this. */
#define PTE_LEAF_RW (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
#define PTE_LEAF_RO (PTE_V | PTE_R |         PTE_X | PTE_A | PTE_D)

#define MEGAPAGE_SHIFT 22
#define PTE_COUNT      1024

/* The root table lives in the *upper* half of the part - the half that did
 * not exist before the decode was masked - and that placement is the point.
 * Every PTE this machine reads from now on comes from above 0x9100_0000, so
 * a decode that still stopped at 16 MB does not merely make one test address
 * unreachable: it makes the whole page table read back as zeros (unmapped
 * addresses are acked with zeros by design), every entry invalid, and the
 * first translated access faults. There is no version of that failure that
 * looks like a pass. */
#define ROOT_PA (SDRAM_BASE + 0x01000000u)   /* 0x9100_0000, first byte above 16 MB */

/* The two mapped test addresses sit in the lower half, in different
 * megapages so they can carry different permissions. They are down here
 * only so the simulated part can stay small: sdram_model.v backs storage up
 * to MEM_WORDS and errors beyond it, and every megapage the model has to
 * cover costs simulator memory. */
#define RW_VA (SDRAM_BASE + 0x00400000u)   /* 0x9040_0000 */
#define RO_VA (SDRAM_BASE + 0x00800000u)   /* 0x9080_0000, the next megapage but one */

#define MAGIC_RW 0x5A7A5A7Au
#define MAGIC_RO 0xC0DEFACEu

static int failures = 0;

static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 30);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

static inline uint32_t megapage_index(uint32_t va)
{
    return va >> MEGAPAGE_SHIFT;
}

/* satp: MODE (31) | ASID (30:22) | PPN (21:0). MODE 1 is Sv32. */
static inline uint32_t satp_for(uint32_t root_pa)
{
    return (1u << 31) | (root_pa >> 12);
}

/* ---- the S-mode half ----
 *
 * Everything from here on is fetched through the MMU, so reaching the first
 * instruction of s_mode_main() is already a statement: the instruction walker
 * read a PTE out of SDRAM and it was the right one.
 */
static void s_mode_main(void)
{
    volatile uint32_t *rw = (volatile uint32_t *)RW_VA;
    volatile uint32_t *ro = (volatile uint32_t *)RO_VA;
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;

    /* Executing at all means fetch was translated through SDRAM. Say so
     * explicitly rather than leaving it implied by the absence of a hang -
     * and note that put_str() is itself running translated. */
    report("fetch translated via SDRAM", 1);

    /* A load whose PTE came out of SDRAM, above the old 16 MB ceiling. The
     * value itself was written physically, before satp went on. */
    report("load through SDRAM PTE", *rw == MAGIC_RW);

    /* And a store, to prove W was honoured rather than merely present. */
    *rw = ~MAGIC_RW;
    report("store through SDRAM PTE", *rw == ~MAGIC_RW);

    /* The read-only megapage still reads. */
    report("read-only page reads", *ro == MAGIC_RO);

    /* Writing it must fault. This is the check that says the permission bits
     * came from the PTE this program wrote into SDRAM, rather than from
     * anything the walker might have invented: the two megapages differ only
     * in the W bit of one word of external memory.
     *
     * The fault is a *store page fault*, cause 15, and with no delegation it
     * is taken in M-mode. crt0_ram.S's handler resumes an armed trap at
     * mepc+4, and its mret restores MPP - which the trap set to S - so
     * control comes back here still in S-mode. */
    TRAP_EXPECT = 1;
    TRAP_MCAUSE = 0;
    *ro = 0xDEADBEEFu;
    report("store to read-only faults", TRAP_EXPECT == 0 && TRAP_MCAUSE == 15);
    report("read-only page unchanged", *ro == MAGIC_RO);

    put_str("\n");
    if (failures == 0) {
        put_str("MMU-SDRAM: PASS\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("MMU-SDRAM: FAIL (");
        put_dec(failures);
        put_str(")\n");
        *result = TEST_RESULT_FAIL;
    }

    for (;;) { }
}

int main(void)
{
    volatile uint32_t *root = (volatile uint32_t *)ROOT_PA;
    volatile uint32_t *rw_phys = (volatile uint32_t *)RW_VA;
    volatile uint32_t *ro_phys = (volatile uint32_t *)RO_VA;
    uint32_t i;

    /* The RAM program's own trap handler, in place of the boot ROM's. Without
     * it the ROM's handler is still installed and every trap - including the
     * one this test provokes on purpose - is reported as a fault in the
     * loaded program and the machine stops. Every other program under
     * software/soc/ does this first, for the same reason. */
    trap_install();

    put_str("\n=== Sv32 with page tables in SDRAM ===\n");
    put_str("root table at ");
    put_hex(ROOT_PA);
    put_str(" - above the old 16 MB ceiling\n\n");

    /* ---- 1. the upper half of the part exists ----
     *
     * Physical, M-mode, no translation involved: this writes and reads back
     * the word the root table is about to occupy. Before the decode was
     * masked this address matched no slave, and an unmapped access is acked
     * with zeros rather than left to hang - so the read returned 0, which is
     * exactly what this catches.
     */
    root[0] = MAGIC_RW;
    report("32 MB window reachable", root[0] == MAGIC_RW);

    *rw_phys = MAGIC_RW;
    *ro_phys = MAGIC_RO;
    report("test pages seeded", *rw_phys == MAGIC_RW && *ro_phys == MAGIC_RO);

    /* ---- 2. an identity map, in SDRAM ---- */
    for (i = 0; i < PTE_COUNT; i++)
        root[i] = (i << (MEGAPAGE_SHIFT - 12 + 10)) | PTE_LEAF_RW;
    root[megapage_index(RO_VA)] =
        (megapage_index(RO_VA) << (MEGAPAGE_SHIFT - 12 + 10)) | PTE_LEAF_RO;

    /* Read one back through the same physical path that just wrote it, so a
     * broken *table* is separated from a broken *walk* before satp goes on. */
    report("page table reads back",
           root[megapage_index(RW_VA)] ==
               ((megapage_index(RW_VA) << (MEGAPAGE_SHIFT - 12 + 10)) | PTE_LEAF_RW));

    /* ---- 3. into S-mode ----
     *
     * satp is written from M-mode, where it has no effect on this code, and
     * SFENCE.VMA discards anything the TLB cached while the table was being
     * built. mstatus.MPP = 01 (S) and mret hands control to s_mode_main with
     * translation live for fetch as well as data.
     */
    __asm__ volatile("csrw satp, %0" :: "r"(satp_for(ROOT_PA)));
    __asm__ volatile("sfence.vma");

    put_str("  entering S-mode\n\n");

    __asm__ volatile(
        "li   t0, 3 << 11\n"        /* MPP mask                       */
        "csrc mstatus, t0\n"        /* clear both bits                */
        "li   t0, 1 << 11\n"        /* MPP = 01, supervisor           */
        "csrs mstatus, t0\n"
        "csrw mepc, %0\n"
        "mret\n"
        :: "r"(s_mode_main) : "t0");

    /* mret does not return. */
    for (;;) { }
}
