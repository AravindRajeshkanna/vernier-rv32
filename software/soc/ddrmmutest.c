/* Sv32 with the page table in DDR3, and a genuinely translated (not
 * identity) virtual address resolving to a real DDR3 physical frame - an
 * attempt at proof that a *paged* caller, not just a bare-metal physical
 * one, reaches DDR3 through the real interconnect.
 *
 * ---- History: this used to hang, and the hang was this program's, not
 * the walker's ----
 * Parts 3 to 6 of docs/roadmap/phase-09-ddr.md chased a hang after `mret` into
 * S-mode: the walker (cleared), the D-cache (cleared), the UART's timing
 * (cleared). None of them was at fault. `s_mode_main` prints through the
 * UART at 0x0400_0000, and this program never mapped it: the virtual address
 * walks to root[16], which is a DDR3 location nothing had ever written.
 * Icarus returns `x` for such a location (sim/ddr3_dq_model.v, on purpose),
 * and rtl/mmu.v always makes a second-level read after the first, forming
 * its address from the first-level entry - so the `x` became the bus
 * address, the interconnect's decode and grant became `x`, and the walker
 * waited in its second-level state for a grant that never came. Measured by
 * watching the data MMU: state 3, `pte1_r` and `ptw_addr` both `xxxxxxxx`,
 * `ptw_req` high, `ptw_gnt` `x`, from the cycle of the first console access
 * after `mret` for as long as the run lasted. Real hardware would not hang
 * there (an address that decodes to no slave is acknowledged with zero data,
 * rtl/soc/wb_interconnect.v), but it would walk whatever bits DDR3 powered
 * up with - which is why this program maps what S-mode touches instead of
 * relying on the entries it leaves alone never being read.
 *

 * ---- Part 12: execution and faults, the two halves Part 11 left untried ----
 * Part 11 made the data side work (a store and a load through a translated
 * DDR3 page, the UART through a two-level DDR3 table). Two things a Linux boot
 * from DDR3 needs were still unchecked, and are now:
 *
 *   - Execution: a small routine is copied into DDR3 (physically, before
 *     paging) and called in S-mode at its *virtual* address, so the fetch goes
 *     through the instruction MMU's walker and out of DDR3. It reports its own
 *     pc with `auipc`, which has to be the virtual address - a fetch that
 *     ignored translation, or ran a stale copy elsewhere, would give another.
 *   - Faults: entries whose contents are *defined* as invalid (written as
 *     zero, not left unwritten) must raise the right page fault with the right
 *     address - at the root (a load and a store) and at the second level (the
 *     root points at the DDR3-resident table, whose entry is zero). The
 *     deliberate traps use the same armed-trap mechanism as the acceptance
 *     test (software/soc/trap.h); the handler runs in M-mode, which does not
 *     translate, and resumes S-mode after the faulting instruction.
 *
 * Mirrors software/soc/mmutest.c's own two claims - "the walkers are bus
 * masters" and "the window is bigger than the old ceiling" - one more time,
 * against a third kind of slave: DDR3 is neither block RAM nor SDRAM, is
 * addressed one real byte at a time (rtl/soc/wb_ddr.v's own header), and
 * did not exist as a page-table walker target until this program.
 *
 * ---- Deliberately sparse, not a copy of mmutest.c's own exhaustive sweep
 * ----
 * mmutest.c identity-maps all 1024 megapages, because its own root table
 * lives in SDRAM, which answers a miss in a handful of cycles. This root
 * table lives in DDR3, where each real controller call unwritten by
 * design (rtl/soc/ddr3_ecp5_top.v's own model returns `x` for a location
 * that was never written, sim/ddr3_dq_model.v) costs real time to fill.
 * Only the entries this program actually walks into are ever written:
 * one megapage for the code/stack/result word (still in block RAM, needed
 * for fetch to keep working once paging is on), one that translates a
 * genuinely different VA onto DDR3, and the console's way to the UART - a
 * pointer in the root table to a level-2 table that also lives in DDR3,
 * whose one 4 KB leaf maps the UART's page. That last one is new (it was
 * missing, and its absence was the hang above) and makes the walk of a
 * DDR3-resident table two levels deep for the first time. The other
 * entries stay unwritten, which is only safe because nothing in S-mode
 * touches them: the same "no test builds more than it needs to prove its
 * own claim" discipline `sim/tb_wb_ddr.v`'s own directed cases follow.
 *
 * Icarus-only, like mmutest.c: this relies on an unwritten DDR3 location
 * reading as a real unknown value if anything ever touched it by mistake
 * (it does not, on a passing run) - Verilator has no such state.
 *
 * No libc - see software/soc/main.c's header for the incident that settled
 * that.
 */
#include <stdint.h>
#include "soc.h"
#include "console.h"
#include "trap.h"

#define PTE_V (1u << 0)
#define PTE_R (1u << 1)
#define PTE_W (1u << 2)
#define PTE_X (1u << 3)
#define PTE_A (1u << 6)
#define PTE_D (1u << 7)
/* A and D are set explicitly - this core does not update them in hardware
 * (mmu.v's perm_ok() faults on a missing one), the same reasoning
 * mmutest.c's own header gives. */
#define PTE_LEAF_RWX (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)

#define MEGAPAGE_SHIFT 22
#define PTE_COUNT      1024

/* The root table: the very first byte of the new window, the same
 * "meaningful boundary" placement mmutest.c's own ROOT_PA uses (first byte
 * above the old 16 MB ceiling, there; here, first byte of the window that
 * did not exist as a walker target at all before Part 2). */
#define ROOT_PA (DDR3_BASE + 0x00000000u)

/* The real DDR3 physical frame under test - a different 16-byte block than
 * the root table itself (offset 0x1000, comfortably clear of the table's
 * own 4 KB), so writing the table and writing the test word are two
 * distinct real block fills, not one aliased together by accident. */
#define TEST_PA (DDR3_BASE + 0x00001000u)

/* The level-2 table that maps the UART's page: 4 KB aligned, in DDR3, clear
 * of the root table (+0x000..0xFFF) and of the test frame (+0x1000). */
#define L2_PA (DDR3_BASE + 0x00002000u)

/* Part 12. The routine lives at CODE_PA (clear of the root table, the L2
 * table and the test frame) and is reached through the same translated
 * megapage as the test frame, so CODE_VA is TEST_VA's megapage plus the same
 * offset. TEST_VA is defined below; the two stay in step by construction. */
#define CODE_OFFSET 0x00004000u
#define CODE_PA     (DDR3_BASE + CODE_OFFSET)

/* Virtual addresses whose page-table entries are written as zero, so that the
 * contents are defined (an unwritten DDR3 location reads as `x` in simulation,
 * which hangs the walker: the Part 11 lesson). FAULT_VA_ROOT is an invalid
 * root entry (index 320); FAULT_VA_L2 is the UART megapage's second page
 * (vpn0 = 1), whose level-2 entry is zero under a valid root pointer. */
#define FAULT_VA_ROOT 0x50000000u
#define FAULT_VA_L2   (UART_BASE_A + 0x1000u)

/* An unused virtual megapage - not RAM_BASE, not SDRAM_BASE, not
 * DDR3_BASE itself - chosen so this is a genuine translation, not an
 * identity map that would not distinguish "the walk happened" from "the
 * address always meant this." */
#define TEST_VA 0x40000000u

static inline uint32_t satp_for(uint32_t root_pa)
{
    return (1u << 31) | (root_pa >> 12);   /* MODE=1 (Sv32) | PPN */
}

/* A level-1 leaf's PPN[0] must be 0, so the megapage index (PA >> 22) goes
 * into PPN[1] alone, at bit 20 - not bit 10, which is where a 4 KB page's
 * *full* PFN would start (mmutest.c's own level-2 table, `<< 10`, is the
 * other case; conflating the two is exactly the kind of Sv32 encoding
 * mistake worth checking against a working reference rather than
 * re-deriving from the spec text alone - caught here before this was ever
 * run, by checking mmutest.c's own `(MEGAPAGE_SHIFT - 12 + 10)` shift). */
static inline uint32_t megapage_pte(uint32_t phys_megapage_base)
{
    return ((phys_megapage_base >> MEGAPAGE_SHIFT) << (MEGAPAGE_SHIFT - 12 + 10))
           | PTE_LEAF_RWX;
}

/* A level-1 entry that points at a level-2 table: valid, and R=W=X=0. */
static inline uint32_t table_pte(uint32_t table_pa)
{
    return ((table_pa >> 12) << 10) | PTE_V;
}

/* A 4 KB leaf for a device page: read/write, never execute. */
static inline uint32_t device_page_pte(uint32_t phys_page_base)
{
    return ((phys_page_base >> 12) << 10) | (PTE_V | PTE_R | PTE_W | PTE_A | PTE_D);
}

#define MAGIC 0x5A7A5A7Au

/* The routine that runs out of DDR3. Position-independent by construction (only
 * register arithmetic, an `auipc`, and a pc-relative branch), so it runs
 * unchanged at the virtual address it is called at: it stores its own pc
 * through the pointer in a0, adds 3 twenty times behind a taken backward
 * branch, and returns 60. It sits in .rodata (the program image) and is copied
 * into DDR3 by main(), because nothing else loads DDR3. */
extern const uint32_t ddr_code_start[], ddr_code_end[];
__asm__(
    "    .section .rodata\n"
    "    .balign 4\n"
    "    .globl ddr_code_start\n"
    "ddr_code_start:\n"
    "    auipc t2, 0\n"
    "    sw    t2, 0(a0)\n"
    "    li    t0, 0\n"
    "    li    t1, 20\n"
    "1:  addi  t0, t0, 3\n"
    "    addi  t1, t1, -1\n"
    "    bnez  t1, 1b\n"
    "    mv    a0, t0\n"
    "    ret\n"
    "    .globl ddr_code_end\n"
    "ddr_code_end:\n"
    "    .text\n");

static int failures = 0;
static void report(const char *name, int ok)
{
    put_str("  ");
    put_pad(name, 40);
    put_str(ok ? "ok\n" : "FAILED\n");
    if (!ok) failures++;
}

/* Executing this at all means fetch, the stack, and TEST_RESULT_ADDR all
 * translated correctly through the RAM_BASE megapage - the same "reaching
 * the first instruction is itself a check" mmutest.c's own header notes. */
static void s_mode_main(void)
{
    volatile uint32_t *test = (volatile uint32_t *)TEST_VA + (0x1000 / 4);
    volatile uint32_t *result = (volatile uint32_t *)TEST_RESULT_ADDR;

    put_str("\n  fetch translated via the RAM megapage - reaching here proves it\n");

    *test = MAGIC;
    report("store through a DDR3-backed PTE", 1);
    report("load through a DDR3 PTE reads back", *test == MAGIC);

    /* ---- Part 12: execute out of DDR3, through the instruction MMU ---- */
    {
        volatile uint32_t pc_seen = 0;
        uint32_t (*fn)(volatile uint32_t *) =
            (uint32_t (*)(volatile uint32_t *))(uintptr_t)(TEST_VA + CODE_OFFSET);
        uint32_t r = fn(&pc_seen);
        report("code fetched through a DDR3 PTE runs", r == 60);
        report("... at its virtual address", pc_seen == TEST_VA + CODE_OFFSET);
    }

    /* ---- Part 12: page faults through DDR3-resident tables ---- */
    {
        volatile uint32_t *bad_root = (volatile uint32_t *)FAULT_VA_ROOT;
        volatile uint32_t *bad_l2   = (volatile uint32_t *)FAULT_VA_L2;
        uint32_t n = TRAP_COUNT;

        trap_arm(1);
        (void)*bad_root;                         /* one lw: resumed at mepc+4 */
        report("load, invalid root entry: cause 13",
               TRAP_COUNT == n + 1 && TRAP_MCAUSE == 13u);
        report("... and mtval is the address", TRAP_MTVAL == FAULT_VA_ROOT);

        trap_arm(1);
        *bad_root = 1;                           /* one sw */
        report("store, invalid root entry: cause 15",
               TRAP_COUNT == n + 2 && TRAP_MCAUSE == 15u && TRAP_MTVAL == FAULT_VA_ROOT);

        trap_arm(1);
        (void)*bad_l2;
        report("load, invalid L2 entry: cause 13",
               TRAP_COUNT == n + 3 && TRAP_MCAUSE == 13u && TRAP_MTVAL == FAULT_VA_L2);

        trap_arm(1);
        *bad_l2 = 1;
        report("store, invalid L2 entry: cause 15",
               TRAP_COUNT == n + 4 && TRAP_MCAUSE == 15u && TRAP_MTVAL == FAULT_VA_L2);
    }

    put_str("\n---------------------------------------------\n");
    if (failures == 0) {
        put_str("DDR3 PAGED-ACCESS TEST PASSED\n");
        *result = TEST_RESULT_PASS;
    } else {
        put_str("DDR3 PAGED-ACCESS TEST FAILED\n");
        *result = TEST_RESULT_FAIL;
    }
    put_str("---------------------------------------------\n");

    for (;;) { }
}

int main(void)
{
    volatile uint32_t *root = (volatile uint32_t *)ROOT_PA;
    volatile uint32_t *test_phys = (volatile uint32_t *)TEST_PA;

    trap_install();

    put_str("\n=== Sv32 with the page table in DDR3 (Phase 9 Stage 2, Parts 3-12) ===\n");
    put_str("root table at "); put_hex(ROOT_PA);
    put_str(", translating "); put_hex(TEST_VA);
    put_str(" -> "); put_hex(TEST_PA); put_str("\n\n");

    /* ---- 1. the root table itself is real, real-controller-backed
     * storage, not identity-mapped block RAM wearing a DDR3 address ---- */
    root[0] = MAGIC;
    report("DDR3 window reachable physically", root[0] == MAGIC);
    root[0] = 0;   /* clear - index 0 is never a real PTE this test uses */

    /* ---- 2. two real PTEs, and nothing else in the table ----
     * index 512 covers RAM_BASE (0x8000_0000 >> 22): identity, for
     * fetch/stack/result. Index (TEST_VA >> 22) = 256 translates onto
     * DDR3's own physical megapage. The other 1022 entries stay unwritten
     * - never walked into by this test. */
    root[0x80000000u >> MEGAPAGE_SHIFT] = megapage_pte(0x80000000u);
    root[TEST_VA >> MEGAPAGE_SHIFT]     = megapage_pte(DDR3_BASE);

    report("RAM megapage PTE reads back",
           root[0x80000000u >> MEGAPAGE_SHIFT] == megapage_pte(0x80000000u));
    report("DDR3 megapage PTE reads back",
           root[TEST_VA >> MEGAPAGE_SHIFT] == megapage_pte(DDR3_BASE));

    /* The console, for S-mode: root[16] points at a level-2 table in DDR3 and
     * its entry for the UART's page is a 4 KB leaf (identity: VA == PA, so
     * soc.h's UART registers work unchanged). */
    volatile uint32_t *l2 = (volatile uint32_t *)L2_PA;
    root[UART_BASE_A >> MEGAPAGE_SHIFT] = table_pte(L2_PA);
    l2[(UART_BASE_A >> 12) & 0x3FFu]     = device_page_pte(UART_BASE_A);
    report("UART level-1 pointer reads back",
           root[UART_BASE_A >> MEGAPAGE_SHIFT] == table_pte(L2_PA));
    report("UART level-2 leaf reads back",
           l2[(UART_BASE_A >> 12) & 0x3FFu] == device_page_pte(UART_BASE_A));

    /* ---- Part 12 setup, still physical: the routine into DDR3, and the two
     * entries that must fault written as zero (invalid, but defined). ---- */
    {
        volatile uint32_t *code = (volatile uint32_t *)CODE_PA;
        uint32_t words = (uint32_t)(ddr_code_end - ddr_code_start);
        for (uint32_t i = 0; i < words; i++) code[i] = ddr_code_start[i];
        __asm__ volatile ("fence.i" ::: "memory");   /* the I-cache must not hold stale words */
        root[FAULT_VA_ROOT >> MEGAPAGE_SHIFT] = 0;
        l2[(FAULT_VA_L2 >> 12) & 0x3FFu]      = 0;
        int same = 1;
        for (uint32_t i = 0; i < words; i++) if (code[i] != ddr_code_start[i]) same = 0;
        report("routine copied into DDR3 reads back", same);
        report("invalid entries read back as zero",
               root[FAULT_VA_ROOT >> MEGAPAGE_SHIFT] == 0 && l2[(FAULT_VA_L2 >> 12) & 0x3FFu] == 0);
    }

    /* Seed the physical frame under test before satp goes on, the same
     * "separate a broken table from a broken walk" reasoning mmutest.c's
     * own header gives - though here the read-back check is the S-mode
     * load itself, since the whole point is that it comes back translated. */
    *test_phys = 0;
    put_str("  test frame seeded physically\n");

    __asm__ volatile("csrw satp, %0" :: "r"(satp_for(ROOT_PA)));
    __asm__ volatile("sfence.vma");
    put_str("  satp written, sfence.vma done - entering S-mode\n");

    __asm__ volatile(
        "li   t0, 3 << 11\n"        /* MPP mask            */
        "csrc mstatus, t0\n"
        "li   t0, 1 << 11\n"        /* MPP = 01 (S)         */
        "csrs mstatus, t0\n"
        "csrw mepc, %0\n"
        "mret\n"
        :: "r"(s_mode_main) : "t0");

    for (;;) { }
    return 0;
}
