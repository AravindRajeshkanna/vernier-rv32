# Phase 15 — Heterogeneous multi-core: both core types, at once, in one SoC

**Stages 0 through 5 are all done now; only the extensions Stage 5's own
account names remain a plan, not an account.** This phase was written
down as a pure design-space discussion first, the same reasoning that put
one in Phases 8-11 before any of them had a line of RTL - but unlike
those, the first stages shipped in quick succession, the mechanism
(Stages 0-1) and its own highest-risk correctness question (Stage 2,
cross-hart coherence) both turning out more tractable than the original
plan below assumed, Stage 3's own two halves needing genuinely different
amounts of work and shipping in two separate passes as a result (see that
stage's own account for why), Stage 4 needing no code change at all, and
Stage 5 - measurement - surfacing a real, previously-undiscovered defect
in Phase 13's own cross-hart AMO atomicity claim, closed as its own
standalone fix rather than folded quietly into this phase's own account
(see that stage's own entry for the full story, and `phase-13-multicore.md`'s
Phase 13 entry, corrected in place, for the fix itself). The "Stage N:"
entries for 0 through 5, including both halves of Stage 3, are real
completed accounts, exactly like every other phase in this file; the
remaining bullets (Stage 5's own named cache/contention-separation gap)
are still a plan, and are marked as such at their own header.

**This is not a new idea - Phase 13 named it and set it aside on purpose.**
Stage 6's own account of building `rtl/soc/reservation_monitor.v` says so
directly: *"this would be a heterogeneous multi-core system, not the
usual 'replicate one core N times' shape most SMP designs are... real
per-hart timing asymmetry... that a kernel built assuming identical cores
does not usually have to reason about."* Phase 13 then spent nineteen
stages building the homogeneous case first - two harts of the *same*
type, proven for both `cpu_core.v` and `rtl/ooo/core_ooo.v`
independently - which is the right order (prove coherence and SMP boot
once, on the simpler pairing, before adding a second axis of
difference) but leaves the harder, originally-named case exactly where
Stage 6 left it: unstarted.

**What Phase 13 leaves this phase to build on, precisely, not
assumed:** both cores now share one port list (Stages 15-19 spent
themselves closing that gap specifically - reservation ports, hart
control, register access, all identical shapes on both), `rtl/soc/
wb_interconnect.v` and the CLINT/PLIC already take `NUM_HARTS` as a real
parameter rather than a hardcoded pair, `rtl/soc/reservation_monitor.v`
already arbitrates cross-hart LR/SC for any number of masters, the boot
ROM's mailbox already parks an arbitrary non-zero hart until hart 0
releases it, and `dts/soc.dts`'s per-hart `cpu@` nodes and OpenSBI's own
FDT-driven hart detection already scale past two. None of that was
heterogeneous-aware when it was built - it was built to replicate one
core type - but nothing about how it was built assumes the two harts run
the *same* Verilog module, which is what makes this phase "wire existing
plumbing to a real asymmetry" rather than a second Phase 13 from
scratch.

**What was genuinely new turned out smaller than it first looked - a
third value, not a general per-hart array.** `CORE=inorder` versus
`CORE=ooo` was a *global, compile-time* choice, not a per-hart one:
`rtl/soc/soc_top.v` selected which module to instantiate with a single
`` `ifdef CORE_OOO ``/`` `else `` that both hart 0's own instantiation
and the `h = 1..NUM_HARTS-1` generate loop's own copy of the same
`` `ifdef `` read identically - every hart in a given build was the same
type, by construction. The plan below originally assumed closing that
gap needed a real per-hart type parameter (an array, or a two-bit field
per hart). Stage 1 found a narrower fix sufficient for the one topology
Stage 0 actually locked (hart 0 fixed, every hart from 1 upward fixed) -
see that stage's own account below for what shipped instead, and why a
general per-hart array remains real, unclaimed future work rather than
something this stage quietly did anyway.

**Cache policy is not an open decision here the way it reads in a
generic multi-core plan - Phase 13 already made it, for a directly
applicable reason.** `rtl/soc/soc_top.v`'s own `HART_DCACHE_ENABLE`
localparam (line 313) is `(NUM_HARTS > 1) ? 0 : 1` - **every hart's
private D-cache is already disabled outright the moment a second hart
exists**, precisely because two real bus masters sharing memory with no
snoop path is exactly the hazard a private cache would hide. That
decision was made for the homogeneous case and needs no new reasoning to
carry over to the heterogeneous one - the memory-correctness question
this phase actually opens is narrower than "pick a cache policy": it is
whether an in-order hart's own store-then-drain ordering and an
out-of-order hart's store buffer (the same `sb_valid` this project's own
hart-control work already had to reason about precisely, in Phase 13
Stage 18) interleave safely at `rtl/soc/reservation_monitor.v`'s
existing arbitration point, which is a verification question, not a new
design.

**Stage 0: the design lock.** Both cores still passed `make verify`/
`make verify_ooo` independently before anything else started - a
regression check, not new work, and confirmed rather than assumed given
how much of this file's own Phase 13 material this phase leans on. The
one real open topology question was settled the way the original plan
named as the natural default: hart 0 = `cpu_core.v` (the silicon-proven
path, keeping every existing single-hart/homogeneous build's own hart-0
behavior unchanged) and every hart from 1 upward = `rtl/ooo/core_ooo.v`.
Fixed at build time, not itself parameterized (no `HART0_TYPE`/
`HART1_TYPE`) - Stage 1 found this was enough to prove the mechanism
without inventing a configuration space nothing has asked for yet; a
fully general per-hart type array stays real, named future work (Stage 6
in the original plan, still there, still unstarted).

**Stage 1: dual instantiation - a new `CORE=hetero` build, not a new
parameter.** `rtl/soc/soc_top.v`'s hart-0 instantiation needed no change
at all: it already reads `` `ifdef CORE_OOO ``/`` `else ``, and the new
`-DCORE_HETERO` define is a *different* macro, so hart 0 falls through
to its existing `` `else `` (`cpu_core.v`) automatically. Only the
`h = 1..NUM_HARTS-1` generate loop's own copy of that `ifdef` gained a
third arm - `` `ifdef CORE_HETERO `` (→ `core_ooo.v`) `` `elsif CORE_OOO ``
(→ `core_ooo.v`, the existing homogeneous case) `` `else `` (→
`cpu_core.v`) - so every hart from 1 upward is the wide core under
`CORE=hetero` while hart 0 stays the proven one, and nothing about the
bus adapter, page-table walker, reservation ports, or hart-control wiring
in that same loop needed to know which module `CPU` resolved to - all of
it already treated "hart h's own CPU" generically. The Makefile's own
`CORE` variable gained a third branch alongside `inorder`/`ooo`, reusing
`CORE=ooo`'s exact `CORE_RTL`/`VERILATOR_LINT_FLAGS` values (both harts'
`core_ooo.v` instances need the same UNOPTFLAT waiver the homogeneous
wide-core build already carries) with a distinct `CORE_DEFINES`.

**Verified two ways, not just "it built."** `sim/tb_soc_2hart.v`'s
existing smoke test (the same one Phase 13's Stage 8 already proved for the
homogeneous pairing) needed zero changes to prove hart 0 and hart 1 each
run a trivial program and reach the bus - it only ever reads `mhartid`
and writes a hart-specific sentinel, which is core-agnostic by
construction, so it already proved elaboration and reset under
`CORE=hetero` the first time it was pointed at that build. But that
same test would pass identically if `CORE_HETERO`'s own generate-loop
selection had a bug and quietly gave hart 1 a second `cpu_core.v`
instead - the sentinel values look the same either way. A second,
`` `ifdef CORE_HETERO ``-guarded check closes that gap: hart 1's own
`rob_count` (`core_ooo.v`'s reorder-buffer occupancy register, with no
equivalent anywhere in `cpu_core.v`) is read hierarchically and checked
for a defined, non-X value - a real proof of module identity, since
referencing it against the wrong module is a hard Icarus compile error,
not a silent pass. Confirmed non-vacuous by mutation: temporarily
pointing `CORE_HETERO`'s own generate-loop arm at `cpu_core.v` instead
produced exactly that - `error: Unable to bind wire/reg/memory
'DUT.g_hart['sd1].CPU.rob_count'` - reverted and reconfirmed clean
before this was written down.

**`make verify` and `make verify_ooo` both green on the resulting tree**
(Linux boot passed, formal 6/6 proved, riscv-tests 82 passed/2 xfail,
cosim 84/84 traces match) - the new `sim_soc_2hart_hetero` target is
gated in `verify`'s own dependency list unconditionally, so it runs
under both existing `CORE` values too, and neither existing single-core
build nor either existing homogeneous `NUM_HARTS=2` pairing changed at
all. The "verification surface genuinely grows" cost this phase's own
plan named below as worth stating honestly turned out to be one reused
test, not a new one - real cost, but smaller than a first reading of
that caution might suggest.

**What Stage 1 deliberately does not do:** cross-hart coherence between
the two hart types (the next stage, below), boot firmware/device-tree/
OpenSBI awareness of a mixed pair, Linux SMP on one, or any measurement
at all - this stage proves the mechanism elaborates, resets, and runs
independent code on both hart types at once, the same "prove the
mechanism first" role every multi-stage feature in this file plays for
its own first stage.

**Stage 2: coherence and atomics under real asymmetry - both
directions, not one.** `sim/tb_soc_2hart_lrsc.v` (Phase 13 Stage 9's own
cross-hart hazard, already proven twice for the two homogeneous
pairings) needed zero changes to prove one real asymmetric direction the
moment it was built against `CORE=hetero`: hart 0 (`cpu_core.v`) holds
an LR reservation, hart 1 (`core_ooo.v`) makes the foreign write that
has to invalidate it. That test's own program is plain RV32IA and its
checks only read RAM, so it was already core-agnostic by construction -
the same reuse Stage 1 found for `sim/tb_soc_2hart.v`.

**The other direction needed a genuinely new test, not a symmetric
re-run.** An out-of-order hart holding the reservation while an
in-order hart writes is not the mirror image of the case above in any
sense that matters here - `core_ooo.v`'s own `resv_invalidate_ext`
handling had only ever been proven in isolation (`sim/
tb_ooo_resv_ports.v`, Stage 15) and against another `core_ooo.v` hart
(Stage 16), never against a plain, synchronous in-order writer
specifically. `sim/tb_soc_2hart_lrsc_swap.v` is the existing program
with exactly one word changed - the branch that assigns roles by
`mhartid` is `BEQ` there instead of `BNE`, so hart 0 now takes the
delay-then-write path and hart 1 takes the LR/SC path - every address
and expected value stays identical, since neither cares which hart
reaches it, only which role each hart plays. **Both directions passed
on the first attempt - no new coherence bug found**, matching Stage 17's
own first-attempt SMP boot and Stage 19's own first-attempt real DMI
path, a pattern worth naming rather than assuming was guaranteed each
time.

**Verified as real proofs, not test-shaped decorations.** Both new
tests gained the same `rob_count`-based module-identity check Stage 1's
own `sim/tb_soc_2hart.v` check introduced, confirming hart 1 is
genuinely `core_ooo.v` and not a `cpu_core.v` the generate loop's own
`CORE_HETERO` arm quietly mis-selected. The swap direction's own
*coherence* claim was checked separately from that identity claim, by a
second, targeted mutation: forcing hart 1's own `resv_invalidate_ext`
input to a constant 0 in `rtl/soc/soc_top.v` (simulating a disconnected
monitor for that one hart) made the swap test fail with a real cascading
result - the SC succeeded when it should not have, and its own store
overwrote the foreign-write sentinel already sitting at the same
address - while the original (non-swapped) direction's own test stayed
completely unaffected, confirming the mutation's scope was correctly
isolated to hart 1's own reception path rather than something broader.
Reverted and reconfirmed clean before this was written down.

**`make verify` and `make verify_ooo` both green** (Linux boot passed,
formal 6/6 proved, riscv-tests 82 passed/2 xfail, cosim 84/84 traces
match) - both new targets (`sim_soc_2hart_lrsc_hetero`,
`sim_soc_2hart_lrsc_swap_hetero`) hardcode their own file list and
`-DCORE_HETERO`, the same pattern Stage 1 established, and are gated in
`verify`'s own dependency list unconditionally. A local, non-CI-gated
check also confirmed `CORE=hetero` still verilates clean under
`--lint-only -Wall` (the same checks `make code-quality` already runs
for `CORE=inorder`/`CORE=ooo`) - not wired into that job as a third
permanent configuration in this PR, left as a scoped, named follow-up
rather than conflated with Phase 15's own work here.

**What Stage 2 deliberately does not do:** boot firmware/device-tree/
OpenSBI awareness of a mixed pair, Linux SMP on one, or any measurement
- all still Stage 3 onward, below. Ordinary (non-atomic) cross-hart
loads/stores between the two hart types were already exercised
incidentally by both new tests' own foreign-write step, but nothing
here specifically stresses concurrent, unsynchronized ordinary traffic
the way the LR/SC hazard stresses atomics - that remains open too.

**Update: the ordinary-loads-stores gap named above is closed now, by a
real, dedicated directed-hazard test, not left standing.** A new
`sim/tb_soc_2hart_ordinary.v` proves both directions in one program -
hart 0 writes a word, hart 1 reads it back; hart 1 writes a second
word, hart 0 reads that back - matching the flag-poll handshake shape
`sim/tb_soc_2hart_lrsc.v` already established, with the same "tuned,
not generous delay" technique (20 iterations here, not that file's own
200) so each write and the other hart's own concurrent pipeline state
land close together in real time, a real hazard rather than an
eventually-consistent non-event. One program suffices for both
directions here, unlike the LR/SC pair above: ordinary loads/stores
have no core-type-specific internal mechanism to be asymmetric about
the way LR/SC's own per-core reservation-invalidation logic does, which
is what actually forced the LR/SC swap test to be a second, separate
file. Genuinely new coverage, not an extension of an existing Phase 13
test - no cross-hart ordinary load/store hazard test existed anywhere
in this project before this one, homogeneous pairings included.

Passed on the first attempt against the real hardware, and verified as
a real proof, not a test-shaped decoration, the same way Stage 2's own
two tests above were: a real mutation to `rtl/soc/wb_interconnect.v`
(aliasing every hart's own data-bus address to hart 0's) produced
exactly the real, cascading failure a broken interconnect should -
hart 1 reading garbage instead of hart 0's write, hart 0 reading
garbage instead of hart 1's write, and hart 1's own write itself
corrupted - three real check failures, not one. Reverted and
reconfirmed clean before this was written down. Gated three ways,
matching this stage's own established pattern: `sim_soc_2hart_ordinary`
(ambient `$(CORE)`, so it runs against both homogeneous pairings too)
and `sim_soc_2hart_ordinary_hetero` (hardcoded file list,
`-DCORE_HETERO`), both in `verify`'s own dependency list
unconditionally. `make verify`/`make verify_ooo` both green (Linux
boot passed, formal 6/6 proved, riscv-tests 82/2 xfail, cosim 84/84
traces match) - no regression on any existing path.

**Stage 3, first half: the real boot-ROM mailbox, under real asymmetry.**
`sim/tb_ramboot_2hart.v` (Phase 13 Stage 12's own directed test, the first
one to boot two harts through the *actual* boot ROM - `software/soc/
crt0_rom.S`'s `park_hart` and `software/soc/bootrom.c`'s
`hart_release_addr` mailbox - rather than every other multi-hart test's
own RESET_PC-into-RAM shortcut) needed zero changes to prove the mailbox
holds when the parked hart is a genuinely different microarchitecture
from the one that released it: `bootrom.c`/`crt0_rom.S` are plain C/asm
with no per-hart-type behavior, so the existing payload already proves
hart 0 (`cpu_core.v`) running the real ROM boot sequence and releasing
hart 1 (`core_ooo.v`) to it, the same reuse Stages 1 and 2 both found for
their own testbenches. The new `sim_ramboot_2hart_hetero` target hardcodes
its own file list and `-DCORE_HETERO`, the same pattern every other
`_hetero` target in this phase uses, and is gated in `verify`'s own
dependency list unconditionally. The same `rob_count`-based module-identity
check Stage 1 introduced was added directly to `sim/tb_ramboot_2hart.v`,
confirmed non-vacuous the same way: temporarily breaking the generate
loop's own `CORE_HETERO` arm produced the expected hard Icarus compile
error (`Unable to bind wire/reg/memory 'DUT.g_hart['sd1].CPU.rob_count'`),
reverted and reconfirmed clean before this was written down. Passed on the
first attempt. `make verify` and `make verify_ooo` both green (Linux boot
passed, formal 6/6 proved, riscv-tests 82 passed/2 xfail, cosim 84/84
traces match), zero regression on any existing configuration.

**Stage 3, second half: the device-tree `compatible` strings turned out to
need more than two lines, and shipping the two-line version would have
been a live correctness trap, not a shortcut.** The plan below assumed
this was a small fix - give `cpu0`/`cpu1` a `compatible` string that
actually names which microarchitecture each hart is, instead of the
identical `"riscv"` both nodes carry today. Mechanically this works:
`cc -E -x assembler-with-cpp` (the same mode the Linux kernel's own
`arch/riscv/boot/dts` tree relies on, specifically because it passes a
`#foo = <...>;` device-tree property through unrecognized while still
treating `#ifdef`/`#else`/`#endif` as real conditionals) can drive
per-`$(CORE)` compatible strings through `dtc` cleanly - confirmed against
the real `dts/soc.dts` file under all three of `$(CORE_DEFINES)`'s values
with zero new warnings before any RTL or Makefile change was made. What
stopped this from shipping is what `dts/soc.dtb` actually feeds: it
compiles into `software/soc/dtb_blob.h`, embedded unconditionally into
`software/soc/bootrom.elf` - not gated on `$(CORE)` at all today, because
its content has never depended on `$(CORE)` before - and `bootrom.elf` is
what nearly every boot-ROM test in `verify`/`verify_ooo` links against
(`sim_ramboot`, `sim_probe`, `sim_rerun`, `trapcheck`, `sim_uart16550`,
`sim_plic`, `sim_pmptest`, `sim_uartirq`, `sim_div64test`,
`sim_mmusdram`, `sim_sdramcheck`, `sim_uartload`, and now this stage's own
`sim_ramboot_2hart_hetero`). Making `dts/soc.dtb`'s own content vary with
`$(CORE)` without also making that whole chain `$(CORE)`-suffixed (the way
every other CORE-dependent artifact in this Makefile already is -
`obj_dir_soc_$(CORE)`, `sim/coverage_$(CORE).dat`, and so on) means Make's
own mtime-based dependency tracking has no way to notice the *variable*
changed between two manual invocations: running `make verify` and then
`make verify_ooo` in the same tree - exactly how this project's own gate
discipline runs them - would silently leave the first run's compatible
strings baked into `bootrom.elf` for the second, a stale, wrong answer
embedded across every single boot-ROM test transitively, not confined to
the two `cpu@` nodes it was meant to fix. That is a bigger, real
infrastructure change (a `$(CORE)`-suffixed `dtb_blob.h`/`bootrom.elf`
pipeline) than "rename two strings," and it is exactly the kind of thing
this project's own practice insists on naming rather than shipping around
- so it stays open, named precisely, rather than closed with a change that
would have looked done and instead been a silent trap for the next person
who ran both gates back to back. Revisiting it alongside Stage 4's own new
`sim_opensbi_hetero`/`sim_linux_hetero` boot targets (which need a real,
correctly-scoped answer to the same question anyway) is the planned path,
not a separate, disconnected fix.

**Stage 3, third part: the `$(CORE)`-suffixed pipeline, built for real.**
Once Stage 5 was done, this came back as the next named item. The fix is
exactly the infrastructure change the second half above said it would have
to be, not a smaller version of it: `dts/soc.dts` is now piped through
`cc -E -x assembler-with-cpp -P $(CORE_DEFINES)` before `dtc` ever sees it
(confirmed byte-identical to the old direct `dtc` compile when no define is
set, before anything else changed), producing `dts/soc_$(CORE).dtb` -
`#ifdef CORE_OOO` on `cpu0`'s own `compatible` line (mirroring
`rtl/soc/soc_top.v`'s own hart-0 `ifdef` exactly: only `CORE=ooo` changes
it), `#if defined(CORE_OOO) || defined(CORE_HETERO)` on `cpu1`'s (mirroring
the generate loop's own `` `ifdef CORE_HETERO ... `elsif CORE_OOO ``
exactly). Both now say `"riscv-fpga-cpu,cpu-inorder", "riscv"` or
`"riscv-fpga-cpu,cpu-ooo", "riscv"` - the required `"riscv"` fallback stays,
since the vendor string is strictly additive, never a replacement for what
the RISC-V device-tree binding actually requires.

Suffixed all the way down, not just at the `.dtb`: `software/soc/
dtb_blob_$(CORE).h` (the header's own generator, `gen_dtb_blob.py`, now
takes its source `.dtb` path as an argument instead of a hardcoded
constant), `software/soc/bootrom_$(CORE).elf` (`bootrom.c`'s own
`#include "dtb_blob.h"` became `#include DTB_BLOB_HEADER`, a macro the
Makefile always defines - `-DDTB_BLOB_HEADER='"dtb_blob_$(CORE).h"'` - the
same "computed, not hardcoded" idiom `$(CORE_DEFINES)` itself already is),
and `sim/bootrom_$(CORE).hex`. Every one of the fourteen boot-ROM tests the
second half's own account named by name now depends on
`sim/bootrom_$(CORE).hex` instead of a shared `sim/bootrom.hex` - a real
`make verify` then `make verify_ooo` in the same tree now builds and keeps
*both* `bootrom_inorder.hex` and `bootrom_ooo.hex` side by side, never
overwriting one with the other's content, closing the exact staleness trap
this stage's own second half stopped short of shipping around.

The four testbenches that reference the boot ROM's own hex file by name
(`sim/tb_ramboot.v`, `sim/tb_soc.v`, `sim/tb_ramboot_2hart.v`, `sim/
tb_uartload.v`) took a `` `define ROM_IMAGE "bootrom.hex" `` default,
mirroring `RAM_IMAGE`'s own already-established convention in the same
files exactly, with every Makefile recipe that compiles them now passing
`-DROM_IMAGE='"bootrom_$(CORE).hex"'`. `sim_ramboot_2hart_hetero` is the
one target that needs the hetero-flavored ROM specifically, regardless of
whichever `$(CORE)` its own outer `make verify`/`make verify_ooo`
invocation is running under (matching its own pre-existing hardcoded
`-DCORE_HETERO`) - since `sim/bootrom_$(CORE).hex` is a *static* rule
parameterized by whatever `$(CORE)` means for the whole outer `make`
invocation, not a real per-target parameter, its own recipe now runs
`$(MAKE) sim/bootrom_hetero.hex CORE=hetero` first, the same recursive-
sub-make idiom `verify_ooo` itself already uses for the analogous reason.

**A real staleness bug, found by testing this stage's own first attempt,
not a hypothetical one.** `sim/sbiimage.hex` and `sim/linuximage.hex`
(OpenSBI/Linux boot images) were deliberately left as fixed filenames in
that attempt - reasoning that neither OpenSBI nor Linux keys any real
*behavior* off the vendor-specific half of the `compatible` string (both
match the required `"riscv"` fallback that is always still there), so a
stale one embedded here would be cosmetic, not the kind of silent
correctness trap the `verify`-gated boot-ROM pipeline above was actually
about. That reasoning was wrong about what "cosmetic" means in practice:
a real `make verify` (`CORE=inorder`) followed by `make verify_ooo` in the
same tree left `sim/linuximage.hex` newer than its own `dts/soc_ooo.dtb`
prerequisite (rebuilt minutes earlier, by hand, mid-development) - Make's
own mtime tracking correctly saw no reason to rebuild it, and a live
`CONFIG_SMP=y` Linux boot under `CORE=ooo` printed `/proc/cpuinfo`'s
`uarch : riscv-fpga-cpu,cpu-inorder`, a genuinely false claim about which
hart type was actually running underneath it. The boot itself was never
in question - OpenSBI and Linux both still worked correctly regardless of
which compatible string they were handed - but a false line in a real
kernel's own `/proc/cpuinfo` is exactly the "stale, wrong answer" this
whole stage exists to close, not an exception to it just because nothing
downstream acts on the string. Fixed by giving both the same treatment as
`bootrom_$(CORE).hex`: `sim/sbiimage_$(CORE).hex`, `sim/linuximage_$(CORE)
.hex`, and every consumer (`sim_opensbi`, `sim_opensbi_2hart`, `sim_linux`,
`sim_linux_2hart`, `sbiimage`, `linuximage`, `linuxpayload`) updated to
match. `linux_trapdiff` - which genuinely does need one shared image
booted on two different core binaries, comparing trap behavior rather
than device-tree content - now pins that one shared image to
`sim/linuximage_inorder.hex` explicitly, via the same recursive
`$(MAKE) ... CORE=inorder` sub-build idiom `sim_ramboot_2hart_hetero`
already established above, rather than reading whatever the ambient
`$(CORE)` happens to mean. `software/linux/build/sdram.bin` (the flat
binary `linuxpayload` reports for a real board flash) stays a fixed name
on purpose: no board build has ever asked for anything but `CORE=inorder`
(`rtl/ooo/core_ooo.v`'s own measured Fmax, once one existed to measure -
see "CORE=ooo has no Fmax," Round 6 - still fails the board's 25 MHz
requirement by a wide margin), so there is no second `$(CORE)` value it
could ever go stale against outside simulation.

`fpga/synth/synth_ecp5.sh` (which already threads its own `$CORE` through
to `$(CORE_RTL)`/`$(CORE_DEFINES)` for the RTL file list) now copies
`sim/bootrom_$CORE.hex` instead of a now-nonexistent `sim/bootrom.hex`;
`fpga/synth/vivado.tcl` always uses `sim/bootrom_inorder.hex`, since that
script's own RTL file list hardcodes `rtl/cpu_core.v` unconditionally and
has never had a `$CORE` of its own to read.

**Verified against the real pass criterion, not just "it compiled" - and
re-verified after the `sbiimage`/`linuximage` correction above, not just
before it.** A live `CONFIG_SMP=y` Linux boot's own `/proc/cpuinfo` shows
`uarch : riscv-fpga-cpu,cpu-inorder` for hart 0 under `CORE=inorder` and
`uarch : riscv-fpga-cpu,cpu-ooo` under `CORE=ooo` - the compatible string
reaching all the way from `dts/soc.dts` through the whole rebuilt
pipeline into a real kernel's own sysfs-adjacent output, correctly
different between the two, not just decoded back by `dtc` in isolation
and not just correct by coincidence on whichever one happened to build
first. `make verify` and `make verify_ooo` both green, run again after
the correction: formal 6/6 proved, riscv-tests 82 passed/2 xfail, cosim
84/84 traces match, `sim_ramboot_2hart_hetero`'s own `rob_count` identity
check still passes, and every boot-ROM test in both gates' dependency
lists passed with its own `$(CORE)`-correct ROM image.

**A real, previously-unremarked-on mismatch, noticed along the way and
named rather than fixed here.** `dts/soc.dts`'s own `cpu@1` node has
always been declared unconditionally, regardless of `NUM_HARTS` - its own
comment says it "describes hardware that exists under `make sim_opensbi`/
`sim_linux`," which is imprecise: those are the *single-hart*
(`NUM_HARTS=1`) targets, and a full `make verify` run with a Linux image
already built reads `dmesg` printing `CPU1: failed to come online` before
correctly settling on `smp: Brought up 1 node, 1 CPU` and reaching
userspace anyway. This predates this stage entirely - nothing here added,
removed, or gated `cpu@1`'s own presence, only the `compatible` string on
nodes that already existed either way - so it is unrelated to what this
stage fixes and not a regression from it, confirmed by the fact that
`LINUX BOOT PASSED` regardless. It is a real, previously-unnamed instance
of the same "a lie nothing (yet) acts on is still a lie" pattern this
file's own `memory@80000000` node comment already calls out for a
different node, now noticed for `cpu@1` too. Fixing it would need a
`NUM_HARTS`-aware conditional in the same `dts/soc.dts` pipeline this
stage just built the mechanism for - real, plausible future work, but a different
question from the one this stage answers, so it is named here rather than
folded in.

**Stage 4: Linux SMP on a genuinely asymmetric pair - and no code change
at all.** `sim_opensbi_2hart` and `sim_linux_2hart` were already
`$(CORE)`-generic, not hardcoded, since Phase 13 Stage 17 gave them that
shape specifically so `CORE=ooo`'s own homogeneous wide-core pair could
reuse them without a separate target - `$(VERILATOR_2HART_BIN)`'s own
`$(SOC_RTL)`/`$(CORE_DEFINES)` already read whatever `$(CORE)` the
invocation sets, and its own `$(VERILATOR_2HART_MDIR) =
obj_dir_soc_2hart_$(CORE)` already keeps every core's build in its own
output directory. Running `make sim_opensbi_2hart CORE=hetero` and
`make sim_linux_2hart CORE=hetero` directly - no new Makefile target,
no `_hetero` suffix, no hardcoded file list, unlike every prior Phase 15
stage's own tests - proved both questions at once: OpenSBI's own FDT-
driven platform detection (`Platform HART Count : 2`, `Boot HART Base
ISA : rv32ima`) and the existing `CONFIG_SMP=y` kernel image, completely
unmodified, booting both harts to userspace (`smp: Brought up 1 node,
2 CPUs`, `/proc/cpuinfo` showing `processor 0` and `processor 1`, one
`cpu_core.v` and one `core_ooo.v` underneath). Neither test needed
hardening the way earlier stages' own hardcoded-file-list pattern did,
because neither is gated inside `verify`'s own unconditional dependency
list in the first place - both are already stand-alone, hand-run targets
(the same reason `sim_opensbi`/`sim_linux` themselves are not in
`verify`), so there is no ambient-`$(CORE)` ambiguity to guard against;
whoever runs the command chooses `$(CORE)` explicitly every time.

Passed on the first attempt, both boots - no scheduler warning, no RCU
stall, no soft lockup, no divergence from the homogeneous baseline's own
UART/trap accounting beyond ordinary cycle-count noise (289,104,077
cycles to the completion marker here versus the homogeneous pairing's
own documented 286,259,012 - a 1% difference, not a symptom of anything).
That answers this stage's own two questions plainly: the mailbox and the
device-tree both already generalized past the homogeneous case (Stage 3
proved the mailbox half of that; this stage is the device-tree half,
proved by using it rather than a new statement about it), and the
default scheduler's assumption of interchangeable CPUs did not surface
anything worse than the throughput asymmetry this phase's own plan
already expected - though a *quantified* answer to how large that
asymmetry actually is remains Stage 5's own job, not this one's: nothing
here ran a sustained workload, only a boot sequence.

**What Stage 4 deliberately does not do:** measure anything. This stage
answers "does it boot, and does anything break" - both yes/no questions
- not "how much slower/faster." Stage 5, below, is where a real workload
gets affinitized and timed.

**Stage 5: measurement - and a real, previously-undiscovered defect
found on the way to it.** The plan below originally called for CoreMark
"affinitized to the in-order hart alone, the OoO hart alone, and both
together, compared against the homogeneous pairs Phase 13 already
measured" - a premise that turned out false on inspection: Phase 13
never measured a homogeneous 2-hart CoreMark pairing, only each core
type alone, single-hart. Closing that gap needed genuinely new
infrastructure - two harts running CoreMark *concurrently*, not one
after the other - since this SoC has one UART and CoreMark's own
`core_main.c` cannot be modified (`software/bench/fetch-coremark.sh`:
"the benchmark's own five source files are used unmodified").

Building that infrastructure surfaced a real bug before it ever
produced a number: the natural choice for a cross-hart console lock,
`amoswap.w`, deadlocked permanently under `CORE=ooo`. That turned out to
be a genuine, previously-undiscovered gap in this SoC's own plain-AMO
cross-hart atomicity, unrelated to anything Phase 15 itself built -
Phase 13's own Stage 1 (`phase-13-multicore.md`'s Phase 13 entry, corrected in
place) had formally proved a mechanism that never actually engaged
against real hardware timing, because nothing before this had ever put
two harts in real, sustained contention on a plain AMO to notice. Fixed
as its own standalone PR, ahead of and independent of this stage, with
a real regression test of its own (`sim/tb_soc_2hart_amoswap.v`) - see
that fix's own account for the full story. Named here because Stage 5
is what found it, not because Phase 15 caused it or fixed it.

**The harness, once the lock actually worked**: `software/bench/
coremark_dispatch.S` (a five-instruction reset-vector stub, shared by
both harts, reading `mhartid` to jump each to its own linked image),
two completely independent links of the same port layer
(`software/bench/link_bench_hart0.ld`/`link_bench_hart1.ld` - a
statically-linked binary bakes fixed addresses for every global, so the
*same* compiled `.text` run by two harts would always reference the
*same* physical `.bss`/stack regardless of which hart executed it; two
separate links is what gives each hart's own working state a genuinely
private address), and a spinlock in `core_portme.c`'s own
`stop_time()`/`portable_fini()` (acquired only after each hart's own
timed region has already finished, so the actual measurement stays
completely lock-free) serializing the one thing that is genuinely
shared hardware: the UART. `sim/tb_soc_2hart_coremark.v` loads the
dispatcher and both harts' own images into one RAM array at three
different offsets (`$readmemh`'s own three-argument form, one call per
image, no merge step needed) and reads each hart's own raw cycle count
directly from RAM rather than parsing it out of the UART report text -
the same RAM-resident-sentinel pattern `sim/tb_ramboot_2hart.v` already
uses. Not gated in `verify` - the same reasoning the existing single-hart
`coremark` target already has for its own absence (a real CI job of its
own, `coremark-2hart`, matrixed over all three `CORE` values, run in
parallel rather than serialized into `verify`'s own critical path).

**Real numbers, fresh on the current tree, not old ones from Phase 1:**

| Configuration | Hart 0 | Hart 1 | Pair wall-clock | Sum (work done) |
|---|---|---|---|---|
| Single-hart baseline, `cpu_core.v` alone (cached) | 419,621 | - | - | - |
| Single-hart baseline, `core_ooo.v` alone (cached) | 360,481 | - | - | - |
| `CORE=inorder` (homogeneous in-order pair) | `cpu_core.v`: 502,529 | `cpu_core.v`: 534,774 | 727,564 | 1,037,303 |
| `CORE=ooo` (homogeneous wide pair) | `core_ooo.v`: 440,467 | `core_ooo.v`: 470,994 | 673,368 | 911,461 |
| `CORE=hetero` (the mixed pair) | `cpu_core.v`: 508,725 | `core_ooo.v`: 463,080 | 696,894 | 971,805 |

All three configurations validated cleanly on the first attempt - no new
coherence bug, no CRC mismatch, no trap - matching Stage 2's own
"passed on the first attempt" precedent and worth naming again rather
than assuming it was guaranteed.

**Read honestly, not smoothed over:**

- **Concurrent-and-cacheless costs real cycles, and this stage cannot
  cleanly separate how much of that is contention versus the cache
  itself.** `HART_DCACHE_ENABLE = (NUM_HARTS > 1) ? 0 : 1` (Phase 13's
  own decision, unrelated to this stage) turns the D-cache off the
  moment a second hart exists, so every dual-hart number above is being
  compared against a single-hart baseline that had a cache Phase 13
  already decided is unsafe to give a second hart. `cpu_core.v` costs
  17-21% more running concurrently and cacheless than alone and cached
  (502,529-508,725 versus 419,621); `core_ooo.v` costs 22-31% more
  (440,467-470,994 versus 360,481). No configuration exists in this
  project that isolates the two effects - a fair "contention alone" cost
  would need a dual-hart run with the cache forced back on, which is not
  something Phase 13's own coherence reasoning says is safe to build
  casually. Reported as one combined number because that is what was
  actually measured, not decomposed into a made-up split.
- **Bus-priority position gives a real, measurable ~6-7% edge to
  whichever hart is hart 0 - except when the other hart's own
  microarchitecture is enough to overcome it.** In both homogeneous
  pairs, hart 0 (lower index, `rtl/soc/wb_interconnect.v`'s own
  "lowest asking hart wins" tie-break) finishes 6.4-6.9% ahead of hart 1
  running the identical program. In the mixed pair, hart 1
  (`core_ooo.v`, the lower-priority position) finishes *ahead* of hart 0
  (`cpu_core.v`) anyway - `core_ooo.v`'s own real per-iteration speed
  advantage (13.7% faster than `cpu_core.v`, single-hart and cached:
  360,481 vs 419,621) is large enough to overcome a bus-priority
  disadvantage that cost the *slower* homogeneous hart only ~6-7%.
- **The wall-clock column is not a pure concurrency measurement - it
  includes serialized console output by construction.** Both harts'
  own final CoreMark report (~15 lines of UART text each) is
  deliberately serialized by this stage's own console lock, acquired
  only after each hart's own *timed* region ends - so the per-hart
  cycle counts above are clean, but "pair wall-clock" also counts
  whichever hart reports second waiting for the first hart's own report
  to finish transmitting. The per-hart numbers, not the wall-clock
  column, are this stage's own real measurement.
- **The mixed pair's own aggregate throughput lands between the two
  homogeneous pairs, not below both** - a mixed pair doing 971,805
  cycles of combined work in 696,894 wall-clock cycles is worse than
  the all-`core_ooo.v` pair (911,461 in 673,368) and better than the
  all-`cpu_core.v` pair (1,037,303 in 727,564), which is the unsurprising
  but real answer: mixing one faster core with one slower one lands
  between running two of each. Reported plainly either way, matching
  Phase 1's own precedent of reporting an unglamorous result rather than
  a flattering one.

**What Stage 5 deliberately does not do:** run on real hardware (no
board build has ever asked for `NUM_HARTS>1`, matching every other
Phase 15 stage), run more than one CoreMark iteration, separate the
cache-loss cost from the contention cost (named above as a real,
unclosed gap), or say anything about fairness in
`rtl/soc/wb_interconnect.v`'s own fixed-priority arbitration scheme
beyond measuring its one observed consequence here.

**Stage 3 continued - closed.** The device-tree `compatible`-string
pipeline named here as deferred is done - see "Stage 3, third part" above
for the full account (the `$(CORE)`-suffixed `dts/soc_$(CORE).dtb` →
`dtb_blob_$(CORE).h` → `bootrom_$(CORE).elf` → `sim/bootrom_$(CORE).hex`
chain, `make verify`/`make verify_ooo` both green). No item remains open
under this heading; the one thing that stage's own account found along
the way (`dts/soc.dts`'s `cpu@1` node being unconditional regardless of
`NUM_HARTS`, so a single-hart `sim_linux` boot prints `CPU1: failed to
come online` before settling on one CPU and reaching userspace anyway) is
named there, not here - a different, lower-severity question than the one
this bullet used to describe, and not something this phase's own "Done
when" bar requires closing.

**Named honestly, not folded into the plan above as if already
mitigated:** `rtl/ooo/core_ooo.v`'s own measured Fmax (Phase 1's own
place-and-route entry, "CORE=ooo has no Fmax," Round 6: the
combinational-loop defect closed, but the real number it uncovered - 8.68
MHz - still fails the board's 25 MHz requirement by a wide margin) is not
yet a real board configuration - a heterogeneous board build inherits that
exactly as the homogeneous OoO-only one already does, and this phase does
not change it. No board build has ever asked for `NUM_HARTS>1` of any kind
yet, so
"on real hardware" is not a near-term claim for this phase either,
matching where Phase 13 itself still stands. And the verification
surface does genuinely grow by a third configuration on top of the two
homogeneous ones already gated - Stage 1's own cost turned out to be one
reused test, not a new one, but Stage 2 added two real new directed
tests (`sim_soc_2hart_lrsc_hetero`, `sim_soc_2hart_lrsc_swap_hetero`) and
Stage 3's own first half added a third (`sim_ramboot_2hart_hetero`), and
`make verify_ooo` already exists specifically because a regression in one
core must not hide behind the other - a third, mixed configuration is one
more place that could happen, worth stating plainly rather than assuming
existing CI time absorbs it for free. Stage 4 is the exception, not a
change to that pattern: it added no new gated test at all, since
`sim_opensbi_2hart`/`sim_linux_2hart` already run by hand, on demand,
against whichever `$(CORE)` the person running them picks - the same
reason they were never in `verify` to begin with. Stage 5 grew the
surface again, but outside `verify` entirely - its own `coremark-2hart`
CI job, matrixed over all three `CORE` values, the same "a real job of
its own, run in parallel" shape the existing single-hart `coremark` job
already has, for the same wall-clock-cost reason.

**Done when:** ✅ **closed, in simulation, at this scale.** One
elaboration - simulation first, matching every other phase's own bar
before a board build is attempted - contains a real `cpu_core.v` hart
and a real `core_ooo.v` hart at once (Stage 1, module identity
mutation-confirmed); cross-hart LR/SC and ordinary loads/stores between
them are proven correct under the same directed-hazard standard
`sim/tb_soc_2hart_lrsc.v` already set (Stage 2, both LR/SC directions
and, per that stage's own later "Update," a dedicated ordinary-
load/store hazard test too, all three mutation-confirmed); OpenSBI and
a `CONFIG_SMP=y` Linux boot to userspace seeing both (Stage 4, first
attempt, `smp: Brought up 1 node, 2 CPUs`); and neither existing
single-core build nor either existing homogeneous `NUM_HARTS=2` pairing
regresses (`make verify`/`make verify_ooo` green at every stage above,
the same "the knob exists so a regression in one cannot hide behind the
other" standard `make verify_ooo`'s own Makefile comment already states
for the two cores today, extended to the third configuration this
phase adds). Not yet done, and not required by this bar's own wording:
confirmation on real hardware - no board build has ever asked for
`NUM_HARTS>1` of any kind, matching where Phase 13 itself still stands.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

None. No board build has ever asked for `NUM_HARTS>1` of any kind, so the mixed pair has not run on silicon, matching where Phase 13 stands.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Stages 0 to 5 are done in simulation: the design lock, the `CORE=hetero` dual instantiation, coherence and atomics across the asymmetric pair, the boot-ROM mailbox and device-tree work, Linux SMP on the pair (`make sim_linux_2hart CORE=hetero`), and the measurement stage. `make verify` and `make verify_ooo` stay green for every single-core and homogeneous configuration.
