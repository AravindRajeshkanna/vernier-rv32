# Beyond the phases

**PMP**, which [SECURITY.md](../../SECURITY.md) lists as a known gap rather than
an oversight.

**Stage 1: CSR storage and the address-matching module, both verified in
isolation - not wired to any access path.** `pmpcfg0-3`/`pmpaddr0-15`
(`rtl/csr_file.v`) with correct WARL/lock semantics, including the
TOR-couples-previous-pmpaddr quirk (locking entry `i` as TOR also freezes
`pmpaddr[i-1]`, since that register is entry `i`'s own range's bottom
boundary) - nothing else in this project's test suite reaches that corner,
so it has its own directed test (`make sim_pmp_csr`) alongside the address
matcher's (`make sim_pmp`, `formal/fv_pmp.v`).

Real evidence, not just "it elaborates": riscv-tests' own
`rv32mi-p-pmpaddr` - previously in `tests/expected-failures.txt`, needing
exactly this - now passes outright, on both cores. `tests/cosim.py` no
longer pins Spike to `--pmpregions=0`; both sides now default to 16 regions
and 4-byte granularity, and match trace for trace, including this test's
own CSRRS/CSRRC read-modify-write sequences.

**Deliberately not wired to any fetch/load/store path yet, and this is the
real reason the whole feature stops here for now.** Per spec, once any PMP
hardware exists, an access from S or U mode that matches no entry is
*denied* by default - a rule that only bites once enforcement exists, but
then bites every existing S/U-mode test simultaneously, including the
Linux boot, since nothing in this project's boot flow itself configures a
PMP region.

That risk is why this round built spec-faithful, real WARL storage rather
than a shortcut - real firmware's own generic PMP init should open a
permissive region on its own, without this project's boot ROM or OpenSBI
port needing a single new line. Checked, not assumed: re-ran
`make sim_opensbi` after this round's CSR work landed. OpenSBI's own probe
(`csrw pmpcfg0,zero; csrw pmpaddr0,-1; csrr t0,pmpaddr0` - the identical
technique riscv-tests' own `pmpaddr.S` uses) now reports `Boot HART PMP
Count: 16`, up from 0 before this round, and its domain configuration adds
one region beyond what it already printed with no PMP present: `Domain0
Region05 : 0x00000000-0xffffffff M: () S/U: (R,W,X)` - a single, maximal
NAPOT-style region granting S/U full read/write/execute across the entire
32-bit space, sitting below the higher-priority regions that already
protect the firmware's own scratch/text and the PLIC's window from S/U
(`software/opensbi/README.md` has the full capture). That is exactly the
shape a future enforcement round needs already in place: OpenSBI writes
it unconditionally as part of its normal generic-platform boot path, no
project-specific change required to get it.

What this does *not* yet establish: this configuration currently has zero
effect, because nothing reads `pmpcfg`/`pmpaddr` outside `csr_file.v` -
`Region05` sitting in OpenSBI's own printed domain table is not the same
claim as "an actual load from S-mode against that region would be let
through once a real `pmp` check exists on the data path." Confirming that
needs the same scrutiny this project's practice applies everywhere else
(`docs/practices.md` §44's "every peripheral test passed, only the Linux
boot caught it" is exactly the risk here) - a real enforcement round, with
`rtl/pmp.v` actually wired to a real access path and the full Linux boot
re-run under it, not another read of a boot banner. Wiring enforcement in
is therefore its own round: instantiate `rtl/pmp.v` on the data path first
(off the timing-critical fetch path Phase 3 spent so long on), gate the
trap causes it needs (1/5/7 - instruction/load/store access fault - are
not yet in `medeleg`'s mask), and re-run the full Linux boot before
claiming anything works. Instruction-fetch enforcement, which does sit on
that critical path, is further out still and needs its own Fmax
measurement the way the D-cache pipeline stage got one.

**Stage 2: enforcement, on `CORE=inorder`'s data path, verified against a
full Linux boot - not wired into instruction fetch, and not wired into
`CORE=ooo` at all.** `rtl/pmp.v` is now instantiated in `cpu_core.v`,
checked against `mem_phys_addr` (the same resolved physical address the
existing MMU page-fault check already uses) once it is genuinely
meaningful - either no translation was needed, or a walk just resolved
without a page fault. A denied access raises cause 5 (load) or 7
(store/AMO access fault), gated into the same `commit_ok`/`synchronous_trap`
priority chain the misalignment and page-fault checks already use, at
lower priority than both: misalignment is checked before translation even
starts, and a page fault is checked as part of translation, before PMP has
a real physical address to check at all. `MEDELEG_MASK` gained causes
1/5/7 alongside the existing set, for the same reason 0/4/6 were added
when *their* traps were implemented - a cause that can be raised but not
delegated always lands in M-mode, and real firmware (OpenSBI's generic
init) delegates almost everything to S-mode.

**A real, if narrow, gap found and fixed while wiring this in, that
applied to the existing page-fault path too, not just PMP.**
`ex_mem_is_load`'s own latch was `id_ex_valid && id_ex_is_load`, with no
`commit_ok` gate - unlike `ex_mem_mem_we`/`ex_mem_is_amo`, which already
had one. A faulting *load* (misaligned, page fault, or now a PMP access
fault) still latched `ex_mem_is_load` true, which one cycle later still
asserts a real `dmem_re` to the bus - the register write-back was already
blocked by `ex_mem_reg_we`'s own gate, but the bus read (and any side
effect a real device's read has, like a UART RX FIFO pop) would still
happen. Harmless for the page-fault path in every test this project runs
today, since nothing has ever page-faulted a load against a device with a
real read side effect - but PMP's whole point is preventing a physical
access, not just an architectural one, so shipping it with the identical
gap the MMU path already had felt like inheriting a defect rather than
being consistent with precedent. Fixed by adding the same `commit_ok` gate
`ex_mem_mem_we`/`ex_mem_is_amo` already carry.

**A real bug in `rtl/pmp.v` itself, caught by Verilator where Icarus said
nothing.** `make sim_opensbi`'s Verilator build failed on a `WIDTHEXPAND`
warning in the NAPOT region-size computation - a folded expression
(`base + (({1'b0, napot_mask} + 33'd1) << 2)`) that Icarus accepted without
comment. Fixed by computing the 33-bit region size as its own named wire
before any arithmetic touches it, rather than relying on Verilog's
self-determined-width inference to get a folded expression right - the
same class of "one simulator's silence is not the same claim as the
other's" lesson `docs/toolchain.md` and this file's own SDRAM
`verilator_check` saga have already made once each, now made a third time
by a different tool pair (Icarus vs. Verilator, not Icarus-version vs.
Icarus-version).

**Deliberately scoped to `CORE=inorder`, matching Phase 6's own precedent
for exactly this kind of decision.** `rtl/ooo/core_ooo.v`'s load/store
path is ROB-based and speculative - `load_via_head`, `issL_can_start`,
early completion through the CDB - architecturally nothing like
`cpu_core.v`'s single in-flight access, and this project's own history
with that core (the Class-B/head-arbitration UART-IRQ race, the AMO
completion-ordering bugs `docs/practices.md` and this file's "Stage 1d"
section both catalog at length) is exactly the record that argues against
extending a security-boundary change onto it under the same time budget as
the in-order round. Hart control (halt/resume/register access,
`docs/debug.md`) already set this precedent: `CORE=inorder` only,
`core_ooo.v` explicitly left for "a separate, harder problem for a future
round." PMP enforcement follows the same call, for the same reason.
Concretely: `core_ooo.v`'s own independent `csr_addr_ok` already serves
`pmpcfg`/`pmpaddr` reads and writes (stage 1 added it there too), but
nothing on that core's data path ever computes a PMP fault, so every
access there is unconditionally allowed regardless of what is configured -
not "less enforced," genuinely unenforced. `SECURITY.md` states this
precisely rather than letting "verify_ooo passes" be read as "PMP works on
both cores."

**`software/soc/pmptest.c`: a directed test that a denied access actually
takes a fault, which nothing before this round checked.** `rv32mi-p-
pmpaddr` only exercises CSR read/write/WARL correctness; nothing in the
ISA suite or cosim ever configures a PMP region that denies something and
checks the denial. This test does, using `trap_arm`/`TRAP_MCAUSE` the same
way `trapcheck.c` already proves the loud M-mode trap handler works: three
PMP regions (a store-denied-but-readable word, a fully-closed word, and a
maximal open-everything NAPOT region), an `mret` into S-mode, a denied
load (checked: exactly one trap, cause 5, correct `mtval`), a denied store
(checked: exactly one trap, cause 7, and - the actual point of it - the
memory word genuinely unchanged), and two ordinary accesses to the open
region proving enforcement didn't also break what should still work.
Confirmed to fail without the enforcement wiring, not just asserted:
temporarily excluding `pmp_fault_now` from `synchronous_trap` and
rebuilding reproduces exactly the five failures the trap-detection checks
would predict, restored immediately after. Two real bugs in the test
itself, not the RTL, found the same way: an early version wrote a sentinel
value to the fully-closed word from S-mode *before* arming a trap for it,
which is itself a denied, unarmed store and halted the run on a trap the
test had no explanation for; a second version tried to verify a denied
store hadn't reached memory by reading the same fully-closed word, which
is a denied *read* under a fully-closed region and hit the identical
failure mode. Splitting store-denial (kept readable) from load-denial
(fully closed) into two separate regions is what actually fixed it, found
by hitting each failure rather than reasoned out in advance. Wired into
`verify`'s dependency list, and deliberately built against `cpu_core.v`
directly (`$(SOC_RTL_BASE)`, not the CORE-switching `$(SOC_RTL)`) so it
keeps testing the in-order core's real enforcement even when
`make verify_ooo` runs the rest of that target list against `core_ooo.v` -
otherwise this exact test would fail under `verify_ooo` for a true but
misleading reason (nothing there enforces anything, so every trap-count
check would come back wrong), which is not the same claim as a regression.

**A second Verilator-only build failure, caught by the same discipline as
the first - trust the full sequential gate, not a standalone check.**
`rtl/ooo/core_ooo.v` carries its own, independent `csr_file` instantiation
(the same duplication stage 1 already found once for `csr_addr_ok`), and
it didn't connect the two new `pmpcfg_out`/`pmpaddr_out` ports at all.
Icarus tolerates an unconnected output silently; Verilator's `PINMISSING`
check does not, and turned it into a fatal error the moment
`make verify_ooo` tried to build `CORE=ooo`'s Verilator target - a failure
mode invisible to every Icarus-only check this round had already run,
including `sim_pmp`/`sim_pmp_csr`/`sim_pmptest` and the full riscv-tests
suite on both cores. Fixed by connecting both ports the same way
`mmu.v`'s own `.pa_va()` already does for a port nothing consumes -
`core_ooo.v` has no PMP enforcement wired in, so nothing there needs
these values yet, but the port has to be accounted for regardless.

**A third finding, and the most consequential one: every one of this
project's own S-mode test programs - not riscv-tests, this project's own
`software/soc/*.c` - broke the instant enforcement went live, because
none of them had ever had a reason to configure PMP.** `rv32*-p-*` and
`vernier-p-*` all inherit riscv-tests' own `INIT_PMP` boilerplate (stage
1's entry above), so they were never at risk. `software/soc/mmutest.c`,
`plictest.c`, `uartirq.c`, and `div64test.c` are this project's own
programs, predate PMP entirely, and share one thing riscv-tests-derived
code does not: `crt0_ram.S`, a startup routine this project wrote, with
no reason to touch PMP until this round. The first full trusted
`make verify_ooo` → `make verify` sequence run after fixing the two builds
above caught it precisely where that gap actually lived:
`sim_mmusdram FAILED` - `mmutest.c`'s very first S-mode store took a real,
unarmed `mcause 7` (store access fault), because nothing had ever opened
a region for it to write into. Not a bug in PMP - `rtl/pmp.v` did exactly
what it was configured to do, which was nothing, for an S-mode access
matching no entry. The fix is centralized, not per-test: `crt0_ram.S`
itself now opens the same maximal, unlocked "permit all" NAPOT region
real firmware (OpenSBI's generic init) opens on its own, right before
`call main` - every program linked against this file gets it
automatically, the same way every program that boots through OpenSBI
already did without this project's own boot ROM needing a line for it.
Unlocked, so `pmptest.c`'s own `configure_pmp()` is still free to
overwrite it with a narrower configuration for its own test - and does,
without needing to know this default exists. Re-verified individually
(`sim_mmusdram`, `sim_pmptest`, `sim_plic`, `sim_uartirq` all pass again)
before trusting the fix and re-running the full sequence.

**A fourth finding, from that re-run: `sim/tb_top.v`'s own legacy
regression - the fastest thing that can fail, run first by `make verify`
- has exactly the same gap, in code with no maintained source to patch.**
`sim/program.hex` is hand-assembled and predates PMP by the project's
entire history; its Part 8 (translated S/U-mode load/store) and Part 10
(the S/U privilege round trip) both took real, unarmed PMP access faults
the instant `rtl/pmp.v` reached a real access path, corrupting the
expected-cause comparisons the testbench's own trap handler checks
against - `fail word` came back `0x000001c4` instead of `0`, several
distinct check bits at once, not an incidental one-instruction shift like
the earlier, already-documented U-bit-enforcement change above. The
program itself cannot safely take the `crt0_ram.S` fix: it is "440
instructions of recovered source" (this file's own "Known defects"
entry) with U-mode and S-mode code and hand-tuned page tables interleaved
at exact byte offsets - the Part 13 note further up this file already
documents that even *reading* which permission bit a fault checks is
"impossible here without regenerating the program." Fixed the same way
`sim/tb_top.v` already reaches `DUT.CPU.mispredict_count` for its own BTB
check: a direct hierarchical deposit into `DUT.CPU.CSR.pmpaddr_r[0]`/
`pmpcfg0_r` right after reset releases, before the program's first
instruction - the same maximal open NAPOT region `crt0_ram.S` and
`pmptest.c` both use, standing in for the M-mode boot code this
hand-assembled program never had a reason to include. Confirmed to
restore the *exact* pre-PMP behavior, not just "a passing result with a
new expected value": `fail word` back to `0`, `BTB mispredict_count` back
to the already-documented 53 (`CORE=inorder`) / 54 (`CORE=ooo`) baseline
unchanged - the right outcome, since with PMP genuinely open the program
runs exactly the control-flow path it always did.

Checked for the same gap everywhere else before trusting the round
finished, not assumed clear because two fixes had already been found:
every other testbench's own driven program was traced to its actual
source. `jtagram.hex` (`sim_jtag`) is a two-instruction increment loop,
M-mode only. `software/main.c`/`crt0.S` (`sim_software`), CoreMark
(`sim`/`coremark`), `uartprog.c` (`sim_uartload`), and `sdramtest.c`
(`sim_sdramboot`) are all M-mode only by direct inspection (zero
occurrences of `mret`/`MPP` in any of them) - PMP is a no-op for a
program that never leaves M-mode, regardless of what runtime it links
against. `sim_ooo_csr_hazard` drives a synthetic instruction stream
directly from the testbench, not a linked program at all. Nothing else
in the tree enters S or U mode outside `crt0_ram.S`-linked programs and
`sim/program.hex`.

**The decisive check: the full trusted `make verify_ooo` then
`make verify` sequence, not a standalone run of either.** This project's
own hard-learned rule for exactly this kind of claim (`tests/cosim.py`'s
`rv32si-p-dirty` saga, most recently) is that only a clean,
dependency-graph-driven sequential run is trustworthy evidence - a
standalone `make sim_linux`, or any individual target run by hand, can
silently reuse a stale build the real gate would have caught. Run in
full, after every fix above: riscv-tests 82/82 (2 xfail) and cosim 84/84
on both cores, `VERNIER-RV32-LINUX-BOOT-OK` on both
(`CORE=ooo` at cycle 136,256,193, `CORE=inorder` at 136,661,281 - both
within noise of the no-enforcement baseline stage 1 measured), formal
6/6 on both, and every `sim_*` target including the newly-fixed `sim` and
`sim_mmusdram` - `EXIT=0` for the whole sequence, the first time this
round reached that. `CORE=ooo`'s own riscv-tests/cosim/Linux boot all
pass *unchanged* by any of this, which is the expected, honest result of
"nothing there checks PMP at all" (this file's "Deliberately scoped to
`CORE=inorder`" entry above) rather than evidence enforcement also works
on the wide core.

**Stage 3: enforcement on `CORE=ooo`'s data path too - the "separate,
harder problem for a future round" stage 2 and `docs/debug.md`'s hart
control both named, picked up once it was the next unblocked, explicitly
named item.** `rtl/ooo/core_ooo.v` gets its own `pmp` instances - two of
them, not one, because this core's data path is not one access at a
time the way `cpu_core.v`'s is.

**Why two PMP checks, not one.** `core_ooo.v`'s header explains the
split this has to respect: a load may issue out of order, ahead of
older instructions, once its address is known and no older pending
store might alias it - but only when it needs no MMU translation (a
load needing one already takes `load_via_head` instead, deferring to
the ROB head, per the existing comment above `issL_misaligned`).
Everything else - stores, AMO/LR/SC, and any load that took
`load_via_head` for its own reasons - executes only at the ROB head.
These are two structurally different places or a PMP-denied access can
first become known, so each needs its own instance: `PMP_ISSL`, checked
against `issL_addr_calc` (already guaranteed physical - see above) at
issue time, folded into the same `rob_is_trap_event`/`rob_trap_cause`
mechanism `issL_misaligned` already uses (cause 4 outranks cause 5,
mirroring `issL_pmp_fault`'s own gating on `!issL_misaligned`); and
`PMP_HEAD`, checked against `head_mem_phys_addr` once it is genuinely a
physical address (`head_pmp_pa_valid`, the exact same "not mid-walk,
not a faulted walk's garbage result" gate `cpu_core.v`'s own
`pmp_pa_valid` uses), folded into `head_synchronous_trap`/
`head_cause_for_csr`/`head_val_for_csr` at the identical priority
`cpu_core.v` already established: misalignment, then a page fault, then
PMP. Both a PMP-denied store and a PMP-denied AMO needed their own
bus-access gate added - `head_plain_store_now` and `amo_active` each
already excluded `head_mem_misaligned`/`head_mmu_fault_now` for exactly
this reason (a misaligned or page-faulted access must not touch the bus
before its trap is taken), so `!head_pmp_fault_now` joins the same list
rather than becoming a new kind of check. `head_load_owns_port` and
`loadL_can_start` needed the identical treatment on the load side.

**The one real design question this needed answering, not just
implementing: is a privilege value read at issue time - before an
out-of-order load's true position in program order is settled - safe to
check PMP against?** Privilege only ever changes via ECALL/EBREAK/
MRET/SRET/an interrupt, and every one of those is head-only and
triggers `recovery_fire` on retirement - the identical ROB-walk squash
mechanism a resolved branch misprediction uses. So a load issued out of
order, ahead of an older not-yet-retired privilege change, reads
whatever `effective_priv_for_data` was live at that moment; if that
privilege *was* about to change, the load itself is younger than the
instruction causing the change and gets squashed by that same
mechanism before its trap fields are ever acted on. A wrong PMP verdict
computed under a since-stale privilege can only ever belong to an
entry that never retires - the existing recovery path, unmodified,
already makes this safe, the same way it already makes a
speculatively-wrong branch prediction safe. Verified rather than only
argued: the full trusted gate below includes both cores' complete
Linux boots, the one workload in this project's own history
(`kernel/locking/rwsem.c`'s AMO race, this file's Class-S notes above)
that has actually found a real ordering bug in this exact core.

**`sim_pmptest` itself had to stop hardcoding `cpu_core.v`.** Stage 2's
own account above records the deliberate choice: `sim_pmptest` was
built against `$(SOC_RTL_BASE)` (always `cpu_core.v`, plain `-g2012`),
not the CORE-switching `$(SOC_RTL)`/`$(IVFLAGS)`, specifically so it
kept meaning the same thing whether invoked under `make verify` or
`make verify_ooo` - back when `core_ooo.v` enforced nothing, the exact
same test running against it would have failed every trap-count check
for a true but misleading reason. That reason is gone now, and leaving
the hardcoding in place would have meant `make verify_ooo` never once
touched `core_ooo.v`'s own new enforcement logic, silently. Switched to
`$(SOC_RTL)`/`$(IVFLAGS)`, matching every other core-sensitive test
(`sim_plic`, `sim_mmusdram`).

**Confirmed to fail without the enforcement wiring - the same discipline
stage 2 used, applied to this core specifically.** `git stash`ed just
`rtl/ooo/core_ooo.v`'s changes, rebuilt, and ran `sim_pmptest` directly
under `CORE=ooo` against the now-`$(SOC_RTL)`-based recipe:

```
denied load: exactly one trap           FAILED
denied load: cause 5 (load access fault)FAILED
denied load: mtval is the faulting addressFAILED
denied store: exactly one trap          FAILED
denied store: cause 7 (store access fault)FAILED
denied store: memory unchanged          FAILED
open region: load reads the real value  ok
open region: store took effect          ok
PMP-TEST: FAIL (6)
```

- exactly the six denial checks failing, the two open-region checks
still passing, precisely what "PMP CSRs are real but nothing consults
them" predicts. Restored, rebuilt, re-ran: all eight checks pass.
`crt0_ram.S`'s existing "permit all" open region (added in stage 2,
already running inertly on every `CORE=ooo` build since nothing
consulted it) needed no change at all - it was already correct, just
waiting for something to check it.

**Stage 4: instruction-fetch enforcement, `CORE=inorder` only - the item
stage 1 itself named as "further out still," picked up once it was the
next unblocked, explicitly named PMP work.** `rtl/cpu_core.v` gets a
third `pmp` instance, checked against `fetch_phys_addr` - the same
address `imem_addr` already uses - with `.is_fetch(1'b1)` and `.priv`
always `current_priv` directly, never `effective_priv_for_data`: MPRV
relocates loads and stores, never fetch, a distinction the ITLB
instantiation right above it already states explicitly. The fault is
discovered in IF (`fetch_pmp_fault_now`, mirroring `itlb_fault_now`
exactly) and registered one stage later into a new IF/ID pipeline field
(`if_id_pmp_fetch_fault`, alongside the existing `if_id_ifetch_fault`),
because a PMP-denied fetch still has to decode into *something* in ID
before `suppress_effects` can act on it - the same reason an ITLB page
fault already works this way. Cause 1 (instruction access fault) is
folded into the same `is_trap_event`/`d_trap_cause` computation the
page-fault case (cause 12) already uses, at the priority stage 2
established for the data path: a page fault outranks a PMP fault,
enforced here by construction (`fetch_pmp_fault_now` is already gated on
`!itlb_fault`) rather than only by the ternary's own ordering.

**No misalignment case to gate on, unlike the data path.** This ISA has
no compressed extension, so every fetch is word-aligned by construction
- one less thing stage 4 needs, not an oversight.

**`software/soc/pmptest.c` gained a fourth checked region and a fourth
directed check**, execute-denied rather than read/write-denied: a
hand-encoded two-instruction sequence (`addi a0, zero, 1` then `ret`,
the same technique `main.c`'s `test_fence_i()` already uses, chosen for
exact address control rather than trusting where a compiled function's
first instruction lands) with only its first word inside a fourth NA4
region. Landing exactly on the second word (`ret`) when the trap's
shared `mepc+4` resume fires matters specifically here, unlike a denied
load or store: `mepc` is the *callee's own first instruction*, not the
call site, so resuming into the middle of a real compiled function
(with whatever registers its own prologue expected) would be unsafe,
where landing on a clean, unconditional return is not. A sentinel
(`0xDEADBEEF`) seeded into `a0` via a register-pinned variable proves
the denied instruction never ran - if it had, `addi a0, zero, 1` would
have overwritten it before the same `ret`.

**A test bug of exactly the kind `docs/practices.md` names, caught by
the same discipline it prescribes.** The first version of this check
compared the sentinel against `a0` again several `report()` calls
later - but `a0` is caller-saved, and each `report()` call is itself a
function call that is free to clobber it for its own string-pointer
argument. GCC's own documentation states plainly that a variable pinned
to a specific hard register is not guaranteed to survive an intervening
call unless that register is callee-saved; a0 is not. Fixed by capturing
the result into an ordinary local immediately after the asm block,
before any `report()` call could touch it - the fix took longer to find
than to make, and was found by reading the actual disassembly rather
than reasoning about the C in the abstract.

**Asymmetric between cores, on purpose, and `sim_pmptest` had to learn
to say so rather than silently mean different things by "pass" on
each.** `CORE=ooo` enforces PMP on its data path (stage 3) but not on
fetch - a real, currently-permanent gap this stage does not close,
named here rather than left to be discovered by a failing CI job.
`pmptest.c` compiles the fetch-denial checks out entirely under
`-DCORE_OOO` (now reaching the firmware compile for the first time -
see the Makefile's own comment on why) and prints an explicit "skipped"
line instead, so a `CORE=ooo` run's shorter check list reads as a
documented asymmetry rather than four checks that quietly stopped
existing. This needed its own Makefile fix, found by hitting it: with
`pmptest.elf`'s C content now genuinely core-dependent for the first
time, `make`'s dependency tracking had no way to know a rebuild was
needed on a bare core switch, since none of the recipe's *listed*
prerequisites changed - only its command line did. `verify_ooo`'s own
`rm -f` line, already there for exactly this reason on the Verilog side,
gained the same treatment for `pmptest.elf` and its derived `.bin`/
`.hex`.

**Verified against the full trusted gate on both cores**, including
both complete Linux boots, unchanged from every prior PMP stage's own
standard of evidence - simulation only, per the scope confirmed at the
start of this stage.

**The Fmax measurement this stage named as its own precondition could
not be completed this round - stated here rather than left silent.**
Real FPGA synthesis (`./fpga/synth/synth_ecp5.sh`, board-targeted, no
board attached) reaches yosys's own `CHECK` pass and then crashes
(`std::out_of_range: vector`, inside yosys itself) while processing
`rtl/soc/wb_framebuffer.v` - the same, previously-hidden crash this
file's own PMP entry two stages up in "Beyond the phases" already
disclosed as unresolved when fixing that file's async-reset synthesis
break. Confirmed unrelated to this stage's own change: the identical
crash reproduces on a synthesis of `wb_framebuffer.v` in isolation, with
none of this stage's `cpu_core.v` changes anywhere in the build. This is
therefore a pre-existing, tree-wide blocker on real synthesis for
*anything*, not a cost this stage's own fetch-side PMP logic introduces
- but it does mean the specific Fmax number stage 1 asked for is not yet
measurable, and this stage ships with that checklist item honestly
unticked rather than guessed at. Resolving the deeper crash is its own,
separate round.

**Stage 5: enforcement on `CORE=ooo`'s instruction fetch, closing the
asymmetry stage 3/4 both named as still open.** `rtl/ooo/core_ooo.v`
gains a fourth `pmp` instance, `PMP_FETCH`, checked against
`fetch_phys_addr` with `.is_fetch(1'b1)` and `.priv(current_priv)` -
byte-for-byte the same instantiation `cpu_core.v` already carries for
`CORE=inorder`'s fetch, not a new design. The one real adaptation is
where the fault has to be *carried*: `cpu_core.v` has a single `if_id`
pipeline register between IF and ID, but `core_ooo.v` fetches into a
4-deep buffer (`fb_pc`/`fb_instr`/`fb_fault`/...) that can hold several
outstanding fetches before ID ever sees the oldest one - so
`fetch_pmp_fault_now` is captured into a new parallel array,
`fb_pmp_fault[fb_tail]`, at the exact same `fb_push` moment
`fb_fault[fb_tail] <= itlb_fault_now` already captures the page-fault
case, and read back the same way at the buffer's head
(`if_id_pmp_fetch_fault = fb_pmp_fault[fb_head]`). ID-stage priority is
unchanged from `cpu_core.v`'s own ordering: page fault (cause 12)
outranks PMP (cause 1), enforced both by construction
(`fetch_pmp_pa_valid` already excludes a faulted or in-flight
translation) and by explicit ternary order, matching the reasoning
`cpu_core.v`'s own comment gives for doing both rather than relying on
mutual exclusivity alone.

**`software/soc/pmptest.c` lost its `#ifndef CORE_OOO` entirely, rather
than gaining a second, parallel enforcement check.** The four
fetch-denial assertions stage 4 wrote already say exactly what this
core needs proven (exactly one trap, cause 1, correct `mtval`, the
denied instruction never ran) - nothing about them was inorder-specific,
so the honest fix for "this core doesn't enforce this yet" was always
going to be deleting the guard once it stopped being true, not writing
a second copy. The Makefile followed the same direction: `pmptest.c`'s
*C source* no longer differs by core at all, so `$(CORE_DEFINES)`
reaching its compile (and `verify_ooo`'s extra `rm -f` for its derived
`.elf`/`.bin`/`.hex`, both added specifically for stage 4's asymmetry)
are reverted along with it - carrying either forward would have been
solving a problem that no longer exists.

**A real, pre-existing `core_ooo.v` bug, found by this stage's own test
rather than introduced by it.** The first run of the ported fetch-denial
check failed all three trap-identity assertions while still passing
"instruction never ran" - a denied fetch was correctly kept from
retiring its register write, but no trap was ever taken at all
(`TRAP_COUNT`/`TRAP_MCAUSE`/`TRAP_MTVAL` all stayed at the *previous*
check's values). `d_is_alu_class` - which routes an instruction through
Class B's fast ALU retirement instead of the ROB-head synchronous-trap
check - already excluded `illegal` for exactly this reason (its own
comment documents an identical bug, found earlier, for an illegal
R-type opcode), but never excluded `d_fetch_fault`/`d_pmp_fetch_fault`:
the *bits* of a faulting fetch are whatever the denied region or
unmapped memory really holds, not a synthetic illegal encoding, so
nothing guaranteed they decode as illegal the way most fetch-fault targets'
all-zero memory happens to (opcode `000_0000` matches no valid RV32I
major opcode). Every fetch-fault test before this one pointed at
memory that decoded that way by accident; `denied_code[0]` is
deliberately a real, well-formed `addi` (chosen so the test proves
clean non-execution rather than trusting a decode accident), which is
what finally exercised the gap. Fixed the same way the `illegal` case
was: `d_is_alu_class` now excludes `d_fetch_fault`/`d_pmp_fetch_fault`
too. This also means the pre-existing ITLB instruction-fetch page-fault
path had the identical latent gap for any implementation that ever
pointed a faulting fetch at a non-illegal-shaped instruction word - and,
caught only after this stage looked like it was ready to ship, it turns
out something already did.

**Correction, found by CI rather than by this stage's own gate: it was
already reachable, and already silently wrong, on `CORE=ooo` before this
stage touched anything.** `sim/tb_top.v`'s own Part 13 - `mret`-into-U-mode
landing on a supervisor-only page, an existing, unrelated test predating
this PR entirely - is exactly this shape: the faulting instruction there
also decodes non-illegal, confirmed by instrumenting `d_fetch_fault`
directly rather than assumed. CI's flat "RTL (no toolchain)" job flagged
it first, as a hard-coded `BTB mispredict_count` mismatch (`expect 54:
53`) this branch had not touched; a clean `main` checkout reproduced 54
(matching), isolating the shift to this stage's own `d_is_alu_class`
change by bisection, not guesswork. With the trap now genuinely firing
for Part 13 too, the CPU redirects to the handler immediately instead of
incorrectly falling through the fault first (measured, not derived: 660
-> 657 out-of-order ALU issues, 19580 -> 19581 retired) - fewer dynamic
control-flow decisions, one fewer mispredict. `sim/tb_top.v`'s own
`EXPECT_MISPREDICTS` has exactly this precedent already, from an earlier,
narrower version of the same bug (excluding `illegal` alone): "a real
control-flow change anywhere in program.hex will legitimately move this
number, at which point it should be recomputed, not bumped blindly."
Recomputed here the same way, with the mechanism behind the new number
stated in the same comment, not just the number itself. `CORE_OOO` and
the in-order baseline now happen to land on the same count (53) - kept as
two separate `ifdef` arms rather than collapsed into one, since nothing
about *why* they agree guarantees they still will after the next
legitimate change to either core.

**Verified against the full trusted gate on both cores**, matching
every prior PMP stage's own standard of evidence - simulation only, the
same scope every stage since stage 2 has confirmed.

**No new Fmax claim made or needed.** Stage 4 already disclosed that
real FPGA synthesis is blocked tree-wide by a separate, pre-existing
yosys crash (`std::out_of_range: vector` in `wb_framebuffer.v`, two
entries up in this same "Beyond the phases" section) unrelated to any
PMP work - that blocker is unchanged by this stage and not re-litigated
here.

`SECURITY.md`, `docs/architecture.md`, `docs/comparison.md`,
`docs/soc.md` and `software/opensbi/README.md` all named the
`CORE=ooo`-fetch gap explicitly as of stage 4; all five are corrected
here rather than left describing a gap that no longer exists.

**Documentation had no gate at all.** Every other layer of this project -
RTL, firmware, the ISA suite, formal proofs - runs through `make verify` or
a CI job. `docs/`, `README.md`, `SECURITY.md` and the rest had none: a
broken internal `#anchor` link, a skipped heading level, or a real typo
could sit in the tree indefinitely, found only if someone happened to click
the link. One already had: `docs/practices.md` linked
`[§1](#1-a-test-that-cannot-fail-is-testing-the-testbench)`, a heading that
had been renamed to "1. A test must be able to fail" at some point without
updating the cross-reference. `markdownlint-cli2` found it in the same
first pass that found everything else - not a special case, just the first
thing a link-fragment checker was ever pointed at this repo.

Two tools, `make lint-markdown` and `make lint-vale` (`make lint` runs
both), gated in CI as their own job. Both deliberately narrower than their
defaults, calibrated against the real ~13,000-line corpus rather than
assumed to fit:

**markdownlint**, default ruleset, then measured: a first pass against
every tracked `*.md` file returned just over a thousand findings, 96% of
them three rules (line-length, fenced-code-language, table-column-style)
that don't describe a defect here at all - this project's prose is
deliberately long-form and not hard-wrapped, most unlabeled fences are
terminal transcripts rather than code in some language, and the existing
tables predate a very new pipe-style rule. Those three, and six more that
turned out to share one root cause (a bare `-` or `+` used as a mid-
sentence clause connector, which CommonMark's parser cannot distinguish
from a list marker once an unwrapped paragraph happens to break a line
right after one), are disabled with the reasoning next to each one in
`.markdownlint-cli2.yaml`. What was left, checked individually rather than
bulk-disabled: one broken link (fixed, above), one heading level skipped
from h2 straight to h4 (fixed), two fenced blocks missing a blank line
before them (fixed), and a handful of genuinely intentional structures
(a numbered list resuming at 3 after an interjecting paragraph, two
stacked blockquotes, a duplicate section heading reused under two
different parents) configured as such rather than silenced.

**Vale**, deliberately *not* built on a third-party style pack. `write-
good`, `proselint`, and the Google/Microsoft house styles are written
against corporate documentation and flag exactly what this project's
causally-reasoned, first-person-adjacent prose does on purpose - passive
voice, long sentences, informal asides. Pointing one at this repo would
either bury real findings under hundreds of stylistic ones on day one, or
need every rule muted individually until nothing was left checked. Instead
this uses only Vale's own bundled base style, for the two checks that are
useful regardless of voice: real misspellings and repeated words. The
spelling check's own dictionary does not know this project's technical
vocabulary (`testbench`, `bitstream`, `netlist`, `nextpnr`, `mux`, and
~285 more) - `.vale/styles/config/vocabularies/Vernier/accept.txt` is that
vocabulary, built by running the checker against the real corpus and
checking every flagged word by hand rather than accepting the list on
faith. Two were traced to their actual meaning first: `netlink` is the
Linux kernel mechanism quoted in the Linux-boot investigation, not a typo
for `netlist`, and `Intergalaktik` is the ULX3S board's manufacturer.
`Vale.Terms` - a separate check the same vocabulary file also drives,
enforcing one canonical casing per entry - is explicitly off: checked
directly, turning it on produced false positives on every pair this
project's vocabulary genuinely needs both casings of (`OR` the boolean
operator vs. `or` the conjunction, `PID` the process ID vs. `pid` the
struct field, `XFAIL` the literal string this project's own tooling prints
vs. "xfail" the word for it in prose).

Both tools verified to actually catch something, not just to run clean: a
deliberately broken link fragment and a deliberately misspelled/repeated-
word sentence were each confirmed to fail their respective check before
being reverted, the same "make the test fail first" discipline this
project applies everywhere else.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

Nothing in this section is a hardware claim; it collects work that sits outside the phase order.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

See the entries above; none of them names a simulation target of its own that is not described where it is used.
