# Phase 13 — Multi-core: both cores, one SoC

**The question this phase answers: `rtl/cpu_core.v` and
`rtl/ooo/core_ooo.v` are two complete, independently-verified core
implementations, but `CORE=inorder`/`CORE=ooo` make them mutually
exclusive at build time - only one hart exists in any given bitstream
or simulation. Could both be instantiated at once, as two harts sharing
this SoC's bus and peripherals, with Linux booting SMP across them?** A
real assessment was done this round rather than assumed either way -
close reading of the interconnect, PLIC, CLINT, boot ROM, and the
OpenSBI/Linux SMP path, not a guess from the architecture alone.

**More already points toward "yes" than the silent single-hart
assumption the previous table entry here implied.** `rtl/plic.v`
already parameterizes `NUM_CONTEXTS` (currently 2, wired to hart 0's
M-mode and S-mode) with per-context enable/threshold/claim arrays and a
standard strided memory map - bumping it to 4 and wiring two more `eip`
lines to a second `csr_file` instance is close to plug-in work, not a
redesign. `rtl/soc/wb_interconnect.v`'s slave-side decode is already
parameterized (`NUM_SLAVES`), and its master-side port list has grown
twice before by the same hand-edited pattern (the page-table-walker,
then the debug module) - a fifth and sixth master (a second core's
fetch/data ports) is mechanically the same kind of change. OpenSBI's
own `PLATFORM=generic` FDT-driven boot (`software/opensbi/README.md`)
has no repo-local hart-count assumption baked in; it reports whatever
`dts/soc.dts` describes.

**What is genuinely just plumbing, enumerated rather than waved at:**

- ~~`rtl/clint.v` has one global `mtimecmp`/`msip`, no hart-ID indexing
  anywhere~~ **Done (Stage 2, below):** `NUM_HARTS`-parameterized,
  standard per-hart-strided arrays, `mtime` still shared as a real CLINT's
  is. Not yet instantiated with `NUM_HARTS>1` anywhere.
- ~~`rtl/csr_file.v`'s `mhartid` is a `localparam` hardwired to 0, not a
  module parameter~~ **Done (Stage 2, below):** a `HARTID` parameter,
  threaded through `cpu_core.v`/`core_ooo.v`. Every instantiation still
  defaults it to 0.
- ~~`software/soc/bootrom.c` has no `mhartid` read anywhere and no
  spin-wait/mailbox gate - every existing test implicitly assumes it is
  the only thing executing from reset. The standard RISC-V SMP pattern
  (hart 0 proceeds, every other hart parks on a mailbox until released)
  does not exist here in any form yet~~ **Done (Stages 12-13, below):**
  `software/soc/crt0_rom.S` parks every non-zero hart on a RAM mailbox
  before it touches anything shared; `bootrom.c` reads its own `mhartid`
  and passes it (`a0`), plus a real device-tree address (`a1`, Stage 13),
  to whatever it jumps to. The mailbox itself is simulation-only - it
  needs RAM to start zeroed, true in simulation and not on real silicon -
  and unreached on every real board build, where `NUM_HARTS=1`.
- ~~`dts/soc.dts` declares one `cpu@0` node; a second hart needs its own
  `cpu@1` and interrupt controller node, and
  `software/linux/vernier_rv32.config` currently has `CONFIG_SMP`
  explicitly unset~~ **Done (Stages 10-11, below):** `cpu@1` node added,
  `CONFIG_SMP=y`, and a real kernel boots both harts to userspace.

**The one item on this list that is a real redesign, not more of the
same wiring: this SoC has no cache or reservation coherence protocol in
any form, because it has never needed one.** Two separate gaps, both
found by reading the code that would have to change, not inferred from
the architecture in the abstract:

- `rtl/soc/cpu_wb.v`'s write-through D-cache is explicitly commented as
  correct only in a single-master system - nothing snoops the bus for a
  second master's writes to a line either core has cached, and
  `rtl/soc/wb_ram.v`/`rtl/soc/wb_sdram.v` have no invalidation path to
  offer one.
- `rtl/cpu_core.v`'s LR/SC reservation is a private per-core register,
  invalidated only by that same core's own subsequent trap/SC/write.
  Two harts each holding a reservation on the same address, invisible
  to each other, is a direct violation of LR/SC's cross-hart contract,
  not a performance gap.

**A third, easy-to-miss consequence of the same root cause:**
`wb_interconnect.v`'s fixed-priority arbitration (debug > data > walker
> fetch) is not just a scheduling policy - its header documents that
AMO atomicity depends on there being exactly *one* data master, which
holds the bus continuously across an AMO's read and write phases. A
second, co-equal-priority data master can win arbitration in the idle
gap between those two phases and race the same address, which breaks
atomicity independently of the cache-coherence question above. Adding a
second hart's data port is not just "a fifth wire in the mux" the way
the walker and debug ports were - the priority scheme itself needs to
account for an in-flight AMO owning the bus for its whole
read-modify-write, not just its current single cycle-by-cycle grant.

**Stage 1: the interconnect's own AMO-atomicity assumption, fixed and
formally proven, before any second hart's data master exists to need
it.** The third consequence named just above is real, and closing it
does not need hart 1 to exist first - it is provable against
`rtl/soc/wb_interconnect.v` exactly as it stands today, the same
"verify the hard piece in isolation before wiring it to something real"
sequencing `rtl/pmp.v` itself used. Tracing it precisely surfaced a
sharper, more general finding than "a second data master would break
this": the *existing*, single-hart design was already one narrow
exception away from the same bug. `cpu_core.v` holds `dmem_is_amo` (and
so `cyc`) continuously across an AMO's whole read-then-write duration,
but the interconnect's lock unconditionally released the instant the
read phase's ack fired - safe today only because the sole thing that
could win the reopened arbitration in that one-cycle gap is the debug
module, asking once per JTAG transaction, rarely enough not to matter.
A second, *continuously running* data master would not be rare.

Fixed once, generally, rather than as a two-master special case: the
data master's own follow-up phase (detected as "my own ack fired last
cycle, and I am still asking" - not same-cycle `cyc`, which is high at
every ack regardless of whether anything follows, and so cannot tell an
AMO's second phase from an ordinary access finishing) now wins
arbitration unconditionally, including against the debug module.
Deliberately narrow to the data master specifically, not a general
"whoever still wants the bus keeps it" rule - fetch and the walker also
hold `cyc` continuously across their own back-to-back but *unrelated*
transactions, where losing arbitration between them is correct
behavior, not a bug a fix should close.

Two real missteps on the way there, both caught by the formal flow
refusing to pass rather than by reasoning it through by hand
beforehand: the first attempt kept the *existing* lock register held
across the gap, which does correctly protect a multi-cycle transfer's
own two phases but does nothing for a phase that acks in its own first
cycle (a zero-wait-state slave) - `formal/fv_interconnect.v`'s own new
property (10, below) refuted immediately. The second attempt fixed
that by triggering the same lock on *any* same-cycle ack for a master
still asking - which happened to also fire for the fetch master's own ordinary,
unrelated back-to-back transactions (the CPU is essentially always
still asking for the next instruction), and would have let fetch
monopolize the bus indefinitely the first time it got a foothold.
Neither was caught by inspection; both were caught by z3 refusing the
corresponding property. The version that finally holds is narrower than
either: a one-cycle, data-master-specific override, added directly to
the `want_*`/`sel_*` computation rather than to the lock register at
all, which is a different mechanism for a different moment (a
multi-cycle transfer already granted, versus the one-cycle gap right
after any ack).

`formal/fv_interconnect.v` gained one new property (10) proving the
data master's identity survives its own multi-phase sequence, and two
existing ones (4z, 6's debug case) needed a stated exception for
exactly this case - both refuted the naive versions of the fix before
being corrected to describe the new, intentional behavior rather than
the old, accidental one. All six formal modules PROVED at depth 12
afterward, `fv_interconnect` included.

**What this stage deliberately does not do:** instantiate a second
hart, extend the interconnect's own master count, or touch CLINT/
`mhartid`/the boot ROM/PLIC contexts - all of that plumbing, named
above, is unaffected by this fix and remains exactly as open as it was.
Nor does it touch the *cache*-coherence half of the "one real redesign"
finding - this closes the AMO-atomicity gap specifically, which turned
out to be provable and closeable on its own, independent of picking a
cache-coherence approach for the other half.

**Update: it wasn't actually fixed, and the formal proof above, while
true, was proving the wrong thing.** Phase 15's own Stage 5 (concurrent
dual-hart CoreMark) needed a console lock between two harts and built one
out of `amoswap.w` - the first time anything in this project put two
harts in real, sustained contention on a *plain* AMO rather than LR/SC.
It deadlocked permanently, reproducibly, within a handful of exchanges,
specifically under `CORE=ooo`. Traced with a cycle-accurate hand-built
repro (two harts hammering `amoswap.w` on one shared word) down to the
exact mechanism: this stage's own `d_continuing` detects "my own ack
fired last cycle, and I am still asking this cycle," and that condition
was **never once true** against real hardware timing, single hart or
many - confirmed by a full cycle trace over the repro, including several
completely uncontested single-hart exchanges. The paragraph above got
one specific thing wrong: `cpu_core.v` holding `dmem_is_amo` continuously
does *not* mean the interconnect's own `d_cyc` input stays continuous,
because `rtl/soc/cpu_wb.v` sits in between the two and was never part of
this stage's own model. `cpu_wb.v`'s own one-cycle decode bubble
(`dc_pending`, its own comment: "1 from the cycle *after* a fresh access
starts") drops the bus-level `d_cyc` for exactly one cycle at an AMO's
own read-to-write transition, every time, regardless of what the core's
own signal does underneath it. `formal/fv_interconnect.v`'s own property
10 proved this file correctly re-grants a master whose `d_cyc` genuinely
never drops - a true statement, checked against an unconstrained `d_cyc`
input that this stage's own reasoning assumed would match real hardware,
never against `cpu_wb.v`'s actual output. It didn't, and nothing caught
the gap between "proven in isolation" and "true of the assembled system"
until a real end-to-end test existed to notice.

Replaced with an explicit signal instead of a second, better-tuned
inference: each core now exports `dmem_amo_wrphase` (a direct copy of its
own `amo_wr_phase` register, wired straight from the core, bypassing
`cpu_wb.v` entirely), and the interconnect masks every other tier - every
other hart's own data master, walker, fetch, even the debug module - out
of the data tier for as long as any hart's own `d_amo_wrphase` is up.
`d_continuing`/`d_acked_prev`/`continuing_win` are gone; `formal/
fv_interconnect.v`'s own property 10 is rewritten around the new signal
(property 4d now), and properties 3 and 6 gained a stated exception for
the same reason property 4z already had one - a hart's own in-flight AMO
write phase can legitimately delay an unrelated request by the same
bounded few cycles, never an unbounded hang. All six formal modules
PROVE at depth 12 again, `fv_interconnect` included. A new permanent
regression test (`sim/tb_soc_2hart_amoswap.v`, all three of `CORE=inorder`/
`CORE=ooo`/`CORE=hetero`) puts two harts through exactly the scenario that
broke, checking a shared counter's own read-modify-store comes out at
*exactly* twice the iteration count - a number that can only ever be
*at or below* that if mutual exclusion genuinely failed, never above,
which is what makes "exactly" a real proof rather than a plausible-looking
one. Confirmed non-vacuous the hard way twice: once by disabling the fix
entirely (the new SoC-level test failed with a real lost update, not a
hang, this time), and once by discovering the *first* attempt at fixing
`sim/tb_interconnect_multihart.v`'s own existing directed test still
passed with the fix disabled - protected by an unrelated, pre-existing
one-cycle lag in the ordinary multi-cycle-transfer lock, not by anything
new - and rebuilding that test's own timing until it genuinely depended
on the new mechanism instead.

`LR`/`SC` was never affected by any of this - its own correctness comes
from `rtl/soc/reservation_monitor.v` invalidating a stale reservation,
not from bus-level exclusivity, and that mechanism is unrelated to
`d_continuing`/`d_amo_wrphase` either way.

**Stage 2: two of the four enumerated plumbing items, parameterized and
proven in isolation, with every real build still defaulting to exactly
today's single-hart behavior.** `rtl/clint.v` gained a `NUM_HARTS`
parameter (default 1): `msip`/`mtimecmp` became the standard per-hart-
strided arrays a real CLINT uses (`msip` for hart *h* at `0x0000 + 4h`,
`mtimecmp` at `0x4000 + 8h`), while `mtime` stays the one free-running
counter every hart shares, same as a real CLINT. `rtl/csr_file.v`'s
`mhartid` stopped being a hardwired `localparam` and became a `HARTID`
parameter (default 0) instead, threaded through as a same-named
parameter on `rtl/cpu_core.v` and `rtl/ooo/core_ooo.v` (passed straight
to their own `csr_file` instantiation). Neither `rtl/top.v` nor
`rtl/soc/soc_top.v` was touched - both keep instantiating with every
parameter at its default, so this stage changes no observed behavior in
any build that exists today; it only makes hart-ID-dependent behavior
*possible* to configure, which is a different thing from *building* it.

Proven, not just written: two new directed tests join `make verify`.
`sim/tb_mhartid.v` instantiates `csr_file` twice, `HARTID=0` and
`HARTID=3` side by side, and reads `mhartid` (CSR `0xF14`) back from
both - catching not just "the parameter is ignored" but the sneakier
"the two instances' values got swapped" failure a same-value smoke test
would miss. `sim/tb_clint_multihart.v` instantiates `clint` with
`NUM_HARTS=2` and confirms `msip`/`mtimecmp` land in independent
storage per hart (not aliased to one bit or one register) and that
`mtip` per hart tracks that hart's own `mtimecmp` against the one
shared `mtime`, then instantiates a second, `NUM_HARTS=1` copy - the
default every real build uses - and confirms it still responds to
exactly the old fixed offsets, including that hart 1's would-be
`mtimecmp` slot (meaningless at `NUM_HARTS=1`) is a bounds-checked
no-op rather than an accidental alias into hart 0's own register. Both
tests were run once with a deliberately reintroduced aliasing bug
first (indexing every hart's storage at a hardwired 0) to confirm they
actually fail before trusting them to pass - the same standard
`sim/tb_pmp_csr.v` set for this kind of isolated, pre-integration test.

**A real Verilator-only failure found and fixed along the way, not
present under Icarus:** the first version indexed `clint.v`'s new
per-hart arrays with the full, untruncated address-derived word index
(14 bits) against arrays that are only 1-2 entries deep at `NUM_HARTS=1`
- legal Verilog (array indices are unsigned integers, not slices, so an
oversized index just selects by value), and Icarus accepted it without
comment, but Verilator's own `WIDTHTRUNC` check - already strict enough
to fail the build over exactly this in the real `make verilator_check`
gate - correctly refused it. Fixed by narrowing the index to
`$clog2(NUM_HARTS)` bits (special-cased to 1 bit when `NUM_HARTS<=1`,
since `$clog2(1)` is 0), the same `CTXW`-style convention `rtl/plic.v`
already established for its own per-context arrays, for the same
reason.

**Left genuinely open, matching the plumbing list above exactly:**
`software/soc/bootrom.c` still has no `mhartid` read or spin-wait/
mailbox gate, and `dts/soc.dts` still declares only one `cpu@0` node
with `CONFIG_SMP` unset - both need a real second hart to test against
meaningfully, unlike the two pieces this stage closed, which could be
proven correct standalone. Nothing anywhere passes a non-default
`NUM_HARTS` or `HARTID` yet; a future hart 2 still has to actually wire
these parameters, not just find them already connected.

**Stage 3: the interconnect itself generalized to `NUM_HARTS`-wide ports,
formally proven at `NUM_HARTS=2`, before a second hart exists to connect
to them.** The problem statement much further above ("Adding a second
hart's data port is not just 'a fifth wire in the mux' the way the walker
and debug ports were - the priority scheme itself needs to account for an
in-flight AMO owning the bus...") is now out of date in the specific way
it predicted would be hard: `rtl/soc/wb_interconnect.v`'s `m0`-`m3` named
ports (one fetch, one data, one walker, one debug) became `NUM_HARTS`-wide
`f_*`/`d_*`/`w_*` vectors plus one still-singular `dbg_*` port, with the
fixed priority order (debug > data > walker > fetch) replicated per hart
via a plain "lowest hart index wins" tie-break within each tier, proven
safe rather than assumed (every candidate's own access is one bounded
transaction that then completes, the same reasoning the original order's
own fetch-starvation argument already used). `NUM_HARTS=1` - what
`rtl/soc/soc_top.v` still instantiates - collapses every array to exactly
the original four ports and behavior; nothing observable changes for the
SoC that exists today, confirmed by the full `make verify`/`make
verify_ooo` regression passing unchanged.

The part of the old problem statement that was genuinely hard, not just
unwritten yet: stage 1's per-master AMO-continuation override
(`m1_continuing`) had to become per-*hart* - hart A's own follow-up phase
must win against hart B's simultaneous request, but must not be
satisfiable by hart B's own activity, and the tie-break among ordinary
(non-continuing) requests needed its own defined order too, not just "the
one master that used to be named m1." `formal/fv_interconnect.v` was
generalized the same way, alongside the RTL, and proven at `NUM_HARTS=2`
specifically
(not `NUM_HARTS=1` - that configuration's correctness is exactly what the
existing simulation regression, exercising the real single-hart SoC end
to end, already establishes; formally proving it again would be strictly
weaker evidence than what those gates already provide, where
`NUM_HARTS=2` has nothing else in the tree exercising it yet). One
property was wrong on the first attempt, caught by the solver rather than
by inspection: it asserted a continuing hart's own `d_ack` bit directly,
which does not distinguish "arbitration granted this hart" from "the
slave's own ack happens to land this exact cycle" - a multi-wait-state
slave's continuing write phase can take more than one cycle to actually
ack, exactly like the original single-hart property already knew (it
checked `s_data_master`, never `m1_ack`, for the same reason) but the
generalization lost. Fixed by checking the granted-hart's identity via
the broadcast bus address instead, matching the original's own approach.
A new directed test, `sim/tb_interconnect_multihart.v`
(`sim_interconnect_multihart`, now in `make verify`), demonstrates both
new behaviors - cross-hart tier priority and per-hart AMO continuation -
against a real, 1-wait-state slave model over an actual cycle-by-cycle
trace, run once against a deliberately reintroduced cross-hart
continuation bug first to confirm it can fail before trusting it to pass.

**What this stage deliberately does not do:** instantiate a second hart,
give the boot ROM a mailbox gate, or add a second `cpu` node to
`dts/soc.dts` - those remain exactly as open as stage 2 left them. Nor
does the walker role change in kind: each hart still gets its own single
walker port, matching `rtl/soc/wb_ptw.v`'s existing one-port-per-core
shape - whether a second hart needs its own `wb_ptw.v` instance or that
module gains its own internal arbitration for more than one core's
walkers is a decision for whichever stage actually instantiates hart 1,
not this one.

**Stage 4: `rtl/plic.v`'s `NUM_CONTEXTS` default bumped from 2 to 4 - a
second hart's own M-mode/S-mode contexts - proven by the module's own
existing formal properties without changing them.** The plumbing list
above already named this as "close to plug-in work, not a redesign", and
that held: `plic.v`'s embedded formal properties (`formal/run.sh`'s
"plic" target - there is no separate wrapper, since the properties need
the module's own per-context arrays) are written generically over
`NUM_CONTEXTS` with `for` loops already, so proving the new value needed
no property changes at all, only the module's own bare default - which
`rtl/soc/soc_top.v` and `rtl/top.v` both override to `2` explicitly
regardless, so the real SoC's behavior is unaffected either way (the one
instantiation that did not already pin it, `rtl/top.v`, was given an
explicit `.NUM_CONTEXTS(2)` as part of this stage, matching
`soc_top.v`'s own existing discipline, so the default can move without
silently changing what that build's `eip` port produces). `make formal`
proves it clean at depth 12 with no other change required.

A new directed test, `sim/tb_plic_4ctx.v` (`sim_plic_4ctx`, now in `make
verify`), complements that proof with something the formal properties
do not independently check: the exact byte offsets a real driver
computes. The formal properties are stated in terms of each context's
own logical correctness (does `eip` reflect eligibility, does a claim
name the right source) and would still hold even if a stride bug moved
a context's window to the wrong address entirely, as long as some
consistent context answered some address - only a test that knows the
documented offset in advance (matching `software/soc/soc.h`'s own
`PLIC_ENABLE`/`PLIC_THRESHOLD`/`PLIC_CLAIM` macros) can catch that
class of bug. Confirmed to actually catch one: run once against a
deliberately shifted context-stride offset first, which the test
correctly fails, before trusting it to pass against the real file.

**What this stage deliberately does not do:** wire a second hart's `eip`
lines to a second `csr_file` instance, or instantiate a second hart at
all - those remain exactly as open as stage 3 left them, and are what
the plumbing list's own "wiring two more `eip` lines to a second
`csr_file` instance" phrase still refers to.

**Stage 5: a D-cache bypass in `rtl/soc/cpu_wb.v`, proving the chosen
correctness-first coherence approach against the actual scenario it
closes, before a second hart exists to need it.** This is the first
stage to touch the "one real redesign" half of the phase's own
assessment (the plumbing stages above were the other half) - and,
matching the decision already made for it, it is the smaller of the two
coherence gaps to close: a parameter, not a protocol. `DCACHE_ENABLE`
(default 1, unchanged for every real build) gates `dc_cacheable`
directly, so `DCACHE_ENABLE=0` makes `dc_present` always false, every
access fall through to the bus, and the fill/store sites - already
conditioned on `dc_cacheable` - never write the cache arrays at all.
Nothing about the cache's own structure changed; it is proven inert
when disabled, not removed.

The new directed test, `sim/tb_cpu_wb_dcache_bypass.v`
(`sim_cpu_wb_dcache_bypass`, now in `make verify`), earns its keep by
proving the actual failure this stage exists to prevent, not just that
the knob does not crash anything: two `cpu_wb` instances (one per
setting) share a stimulus sequence and each get a *foreign write* -
their own backing memory poked directly, never through either
instance's own Wishbone port, standing in for a second hart's own store
reaching the same physical address through a different bus master
entirely. `DCACHE_ENABLE=1` (correctly, for the single-master SoC that
exists today) then serves the *stale* cached value on the next load;
`DCACHE_ENABLE=0` correctly sees the foreign write. Confirmed to
actually catch a regression: run once against a version that ignored
the parameter entirely, which the test correctly failed, before
trusting it to pass against the real file.

**Two real testbench-timing bugs found and fixed while building the
test, neither in the RTL:** a store's own cache-fill update and this
testbench's slave-side ack register both update via non-blocking
assignment at the same clock edge, so the DUT's fill logic still sees
the *pre*-edge (not-yet-acked) value of `dwb_ack` at the exact cycle
`dbus_wait` first reads low - the actual cache write lands one edge
later. An earlier version of the test returned from a store the moment
`dbus_wait` cleared and immediately checked the line it had just
written, reading back 0. Fixed by waiting one further edge after a
*store* specifically; a *load*'s own hit path has no such cross-module
dependency (both `dbus_wait` and `dc_line` come from the DUT's own
already-updated registers), and adding the same extra wait there would
instead have broken the check, reading `rdata_q` - which a hit never
updates - one cycle after the value it was meant to catch had already
passed.

**What this stage deliberately does not do:** instantiate a second
hart, or close the *other* coherence gap the original assessment
named - `rtl/cpu_core.v`'s LR/SC reservation, a private per-core
register whose own cross-hart invalidation contract is a different
mechanism from anything a cache bypass addresses (a reservation needs
invalidating on *any* hart's store to the same address, cached or not -
"no caching" does not make that problem go away, it just removes one of
two gaps). That remains exactly as open as the original assessment left
it.

**Stage 6: `rtl/soc/reservation_monitor.v`, the cross-hart half of LR/SC's
contract, built and proven standalone before either core is wired to
it.** Stage 5 named this the coherence gap a cache bypass cannot close:
a reservation is a correctness primitive, not a performance feature, so
there is no "just disable it" option the way there was for the D-cache.
`rtl/cpu_core.v`'s `reservation_valid`/`reservation_addr` already
invalidate correctly on that same hart's own subsequent trap/SC/write
(`any_successful_write`) - the gap is specifically the case nothing
local can see: a *different* hart's write landing on an address this
hart still holds a reservation on.

The new module takes each hart's own held reservation and each hart's
own completed writes (a plain store, an SC's own write phase, or an
AMO's write phase - the same set `any_successful_write` already
aggregates for the single-hart case) and produces one invalidate pulse
per hart for the cycle any *other* hart's write matches its reservation.
Deliberately wired from each core's own write-completion signal rather
than tapped off the shared bus post-arbitration: the bus's own broadcast
address only carries which *master* currently owns it
(`rtl/soc/wb_interconnect.v`'s `s_data_master`), not which *hart*, and
turning that into a hart index would need the interconnect to expose one
it has no other use for. A hart's own write to its own reservation is
deliberately excluded from this module's own output - already correct,
already handled locally - so wiring this in later only ever adds a
cross-hart OR term to each core's existing clearing condition, not a
replacement for it.

Proven correct with a new directed test, `sim/tb_reservation_monitor.v`
(`sim_reservation_monitor`, now in `make verify`): a cross-hart write
invalidates, a write to a different address does not, a hart's own
write to its own reservation is correctly *not* flagged here (that
case belongs to existing local logic), no reservation held means
nothing to invalidate, and the symmetric and simultaneous two-hart
cases both hold. Confirmed to actually catch a regression: run once
against a version with the self-exclusion removed, which the test
correctly failed, before trusting it to pass against the real file.

**Not gated by the full `make verify`/`make verify_ooo` this round, and
that is a measured claim, not a shortcut:** this module is instantiated
by nothing else in the tree yet - confirmed by grepping for its own name
across every `.v` file, which finds only its own source and its own
test - so the two-core regression is provably unaffected by this change
regardless of whether it runs, the same reasoning that already governs
which gates a genuinely disconnected addition needs.

**What this stage deliberately does not do:** wire this module into
`rtl/cpu_core.v`/`rtl/ooo/core_ooo.v`, instantiate a second hart, or
touch the D-cache gap stage 5 already closed. Wiring a real core to
this module's inputs and OR-ing its output into that core's own
reservation-clearing condition remains open, for whichever stage
actually instantiates a second hart.

**Why this is stated as "plumbing plus one real redesign" rather than
scoped further this round.** Every other phase in this file has been
substantially "wire existing, verified pieces together" work - PMP's
own module predates every stage that enforced it, GPU stages extend an
existing Wishbone slave, Phase 12's peripherals follow an established
convention. Coherence is different in kind: there is no existing,
verified-in-isolation module to wire in, because nothing in this
project has ever had to reason about two masters observing the same
memory. Picking a shape (a real snoop/invalidation path into the
interconnect, dropping to no per-core caching as a simpler
correctness-first step, or something else) is a design decision on its
own, not a known quantity waiting to be assembled - the honest thing is
to name it as the load-bearing open question rather than pre-committing
to an answer before anyone has weighed the tradeoff.

**Also worth naming plainly: this would be a heterogeneous multi-core
system, not the usual "replicate one core N times" shape most SMP
designs are.** Running the in-order and out-of-order implementations as
two hardware-different harts under one Linux image means real per-hart
timing asymmetry (different IPC, different latency to the same
peripheral) that a kernel built assuming identical cores does not
usually have to reason about, even though Linux's own heterogeneous
scheduling support (big.LITTLE and similar) is real precedent that this
is not unprecedented in principle.

**Stage 7: `rtl/cpu_core.v`'s reservation state exposed as ports - the
"give the hard piece a real core to eventually connect to" half of what
stage 6 left open, not the wiring itself.** Five new ports: `resv_valid`/
`resv_addr` (mirroring the existing private `reservation_valid`/
`reservation_addr` registers outward), `store_fire`/`store_addr` (any
completed write this hart makes, gated the same way the existing
reservation-clearing logic already gates `any_successful_write` -
`store_fire = any_successful_write && !dbus_stall`, since that signal is
combinationally true for a multi-cycle write's entire duration, not just
its completion cycle, and `store_fire` has no enclosing `if/else-if`
chain of its own to borrow that distinction from), and
`resv_invalidate_ext` (an input, OR'd into the existing reservation-
clearing `always` block with the *highest* priority - checked ahead of
even the block's own `dbus_stall` "hold" branch, since that branch exists
to protect against a self-inflicted race in this hart's own SC ordering,
a different situation from a genuine external invalidation that must not
be held back by this hart's own local pipeline state).

Every real instantiation site - `rtl/soc/soc_top.v`, `rtl/top.v`,
`sim/tb_cpu_halt.v` - ties `resv_invalidate_ext` to `1'b0` explicitly and
leaves the four outputs unconnected, so single-hart behavior is
unchanged; `fpga/top_fpga.v` (already dead code no synthesis script
references - see its own header) was left as-is rather than touched for
symmetry with a build nothing runs. `rtl/soc/soc_top.v` and `rtl/top.v`
both instantiate `cpu_core`/`core_ooo` through one shared `` `ifdef
CORE_OOO ... `else ... `endif `` port-connection list, originally built
for the debug/hart-control ports (#79-81) - adding these new ports there
unconditionally would have broken the `CORE_OOO` build, since
`rtl/ooo/core_ooo.v` has none of them. Caught before any gate ran, by
re-reading the surrounding structure rather than by a compile failure;
fixed by extending each file's existing `` `ifndef CORE_OOO `` tie-off
block (the one already handling the debug ports) to cover these too,
rather than adding a second conditional block. `rtl/ooo/core_ooo.v`
itself is deliberately not touched this stage, matching the "in-order
first" sequencing PMP's own stages and the hart-control stages both
already established - it would need the equivalent ports in whichever
later stage actually wires a second, out-of-order-capable hart in.

Proven with a new directed test, `sim/tb_cpu_resv_ports.v`
(`sim_cpu_resv_ports`, now in `make verify`), that drives `cpu_core.v`
directly through a hand-assembled LR/SC program (encodings verified
against the field-packing formula, not hand-trusted) attempting the same
LR/SC pair on the same address twice: once left alone (the SC must
succeed), once with `resv_invalidate_ext` pulsed from *outside* the
module while the reservation is held, before the SC executes (the SC
must then fail). Checks the real architectural register file for the
SC's success/failure code, not just that `resv_valid` toggles, and
separately confirms `store_fire`/`store_addr` pulse exactly once - for
the first, successful SC's write, never for the second, failed one, since
a failed SC does not touch memory
(`amo_writes = ex_mem_is_amo_rmw || sc_success`). Confirmed non-vacuous
the same way stage 6's own test was: run once against a scratch copy with
the invalidate pulse skipped, which correctly failed all three of the
attempt-2 checks, before trusting the real version to pass.

**Gated by the full `make verify` and `make verify_ooo` this round**
(unlike stage 6): both `soc_top.v` and `top.v` were touched, even though
only inside their `` `ifndef CORE_OOO `` blocks, so `verify_ooo` is the
regression that proves the `CORE_OOO` build still compiles and passes
unaffected. Both gates are full green on the final tree - formal 6/6
proved, cosim 84/84 on both cores. Two earlier runs on the same,
otherwise-unchanged tree hit real gate failures that turned out to be
this project's own previously-documented, environment-level
nondeterminism, not a regression from this stage: a `verilator_check`
divergence on `sim_sdramboot` (the exact "RESOLVED - not a design
defect" signature a few phases up in this file - same tree, a rerun and
a clean-`main` control both landed on the passing numbers), and an
`rv32si-p-dirty XMATCH (expected to diverge but did not)` cosim failure
on `CORE=ooo` (the exact flip this file's own Update 6/7/8 history
already chased at length - a further full, dependency-graph-driven
`make verify_ooo` rerun reverted to the expected `XDIVERGE`). Neither
investigation was repeated from scratch; both were confirmed against the
existing written record rather than re-litigated.

**What this stage deliberately does not do:** connect
`rtl/soc/reservation_monitor.v` to anything, instantiate a second hart,
or touch `rtl/ooo/core_ooo.v`. Stage 6's own "what this stage
deliberately does not do" paragraph named "wire this module into
`rtl/cpu_core.v`/`rtl/ooo/core_ooo.v`, instantiate a second hart" as one
open item together - this stage is only the first half of the first part
of that: `cpu_core.v` now has somewhere for the monitor to plug in, but
nothing plugs it in yet, and `core_ooo.v` still has nowhere at all. Both
remain open for later stages.

**Stage 8: a real second hart's hardware in `rtl/soc/soc_top.v` - the
"instantiate a second hart" half of what stage 7 left open, still without
touching coherence.** A new `NUM_HARTS` parameter (default 1, today's
exact single-hart shape - every board build and every existing test) gates
a `generate for` loop adding harts `1..NUM_HARTS-1`, each getting its own
`cpu_core`/`core_ooo` (`HARTID(h)`), its own `cpu_wb` bus adapter and its
own `wb_ptw` page-table walker - the same three-instance shape hart 0 has
always had, parameterized on `h` rather than hardcoded, wired into
`rtl/soc/wb_interconnect.v`'s already-`NUM_HARTS`-wide vector ports
(Stage 3), `rtl/clint.v`'s already-`NUM_HARTS`-wide `mtip`/`msip_out`
(Stage 2), and `rtl/plic.v`'s `NUM_CONTEXTS` now pinned to `2*NUM_HARTS`
explicitly rather than a bare `2` (Stage 4's default already supported
this; nothing before this stage ever asked for more than 2). Hart 0's own
instantiation is otherwise unchanged, just reindexed onto slice 0 of each
now-`NUM_HARTS`-wide wire.

(Update: Phase 8 Part 5 later turned the data cache back on at any hart count,
with a snoop path in place of the bypass.) The D-cache bypass Stage 5 built
stops being a knob nothing exercises and starts being load-bearing: a new `HART_DCACHE_ENABLE` localparam forces
every hart's `DCACHE_ENABLE` to 0 the moment `NUM_HARTS>1`, since two real
masters now genuinely share memory and nothing here snoops a foreign
write into either one's cache - `NUM_HARTS=1` keeps today's
`DCACHE_ENABLE=1` untouched. `rtl/soc/reservation_monitor.v` (Stage 6) and
`cpu_core.v`'s reservation ports (Stage 7) are deliberately **not**
connected to anything yet - every hart, hart 0 included, still ties
`resv_invalidate_ext` to `1'b0` and leaves the four outputs unconnected,
exactly as before this stage. Cross-hart LR/SC is therefore still
completely unaddressed even with two harts now genuinely running: this
stage proves the memory system holds together with a second real master
on the bus, not that atomics are coherent between them.

Three things stay hart-0-only on purpose, stated plainly rather than
silently: hart control (`rtl/debug/dm.v` has no per-hart `hartsel` of its
own yet - harts `1..NUM_HARTS-1` get `dbg_haltreq`/`dbg_resumereq`/
`dbg_reg_valid`/`dbg_reg_we` tied to 0 and their status outputs left
unconnected); this module's own `trap` output (a single bit - a second
hart's own trap is not observable at `soc_top.v`'s boundary yet); and
`rtl/ooo/core_ooo.v` itself (already has `HARTID` from Stage 2, still
lacks the reservation ports Stage 7 gave only `cpu_core.v` - unaffected
either way this round, since nothing wires those ports to anything yet
regardless of core). `software/soc/bootrom.c` and `dts/soc.dts` are
untouched - neither knows a second hart exists.

**A real gate failure, found and fixed, unrelated to this stage's own
logic.** `rtl/plic.v`'s `NUM_CONTEXTS`, now arriving as the computed
expression `2*NUM_HARTS` rather than a bare literal `2`, tripped a new
Verilator `WIDTHEXPAND` warning in `plic.v`'s own `enable_off`/`ctx_off`
bounds checks (`enable_off < (NUM_CONTEXTS * 24'h80)` and the `ctx_off`
equivalent) - an unsized parameter multiplied against a 24-bit constant
infers a wider result type from a computed expression than from a
literal, even when the two evaluate to the identical value. The trusted
gate treats any Verilator warning here as fatal, so this failed
`make verify` outright on the first attempt. Fixed at the root in
`plic.v` itself, not by changing `soc_top.v`'s own expression: a new
`NUM_CONTEXTS_W8` localparam, explicitly 8 bits, used only in those two
comparisons - the same narrowing discipline `CTXW` already applies to the
context *index*, extended to the context *count*. Verified with a
standalone `verilator --lint-only -Wall` pass before re-running the full
gate, confirming the warning was gone rather than assuming the fix
worked.

Proven with a new directed test, `sim/tb_soc_2hart.v`
(`sim_soc_2hart`, now in `make verify`'s dependency list, gated under both
`CORE=inorder` and `CORE=ooo`): `RESET_PC` points straight into RAM,
preloaded with a small hand-assembled program (`sim/soc2hart.hex`,
generated the same field-packing way `sim/jtagram.hex` is, not
hand-typed hex) rather than booting through the real boot ROM, since
`bootrom.c` does not know a second hart exists yet. Each hart reads its
own `mhartid`, branches to its own path, and stores a hart-specific
sentinel to a hart-specific RAM word; the test checks both landed and
that hart 0 never trapped. Confirmed non-vacuous: a scratch control run
forcing `NUM_HARTS(1)` in the same testbench correctly failed exactly the
hart-1 check, with hart 0's own check still passing, before trusting the
real `NUM_HARTS(2)` version to pass. Both `make verify` and
`make verify_ooo` are fully green on the final tree - formal 6/6 proved,
cosim 84/84 on both cores, `verilator_check` clean.

**What this stage deliberately does not do:** connect
`rtl/soc/reservation_monitor.v` to either hart, give `rtl/ooo/core_ooo.v`
the reservation ports `cpu_core.v` has had since Stage 7, extend hart
control past hart 0, or touch `software/soc/bootrom.c`/`dts/soc.dts` -
nothing outside simulation can reach this second hart yet. All four
remain open for later stages.

**Stage 9: `rtl/soc/reservation_monitor.v` wired to both harts - cross-hart
LR/SC coherence, not just a second hart that runs.** Stages 6-8 built
every piece and left them unconnected: the monitor itself (Stage 6),
`cpu_core.v`'s ports for it (Stage 7), and a real second hart to have an
opinion at all (Stage 8). This stage is the wiring, and only the wiring -
five new vectors (`resv_valid`/`resv_addr`/`store_fire`/`store_addr`/
`resv_invalidate`) connect a `reservation_monitor #(.NUM_HARTS(NUM_HARTS))`
instance to every hart's own reservation ports, replacing the literal
`resv_invalidate_ext(1'b0)` tie-off every hart has carried since Stage 7.
`NUM_HARTS=1` still genuinely instantiates the monitor rather than
special-casing it away - with only one hart, the monitor's own
self-exclusion rule means `resv_invalidate[0]` is provably always 0, the
same "generalize, default preserves today's behavior" shape every other
Phase 13 stage already used. `CORE_OOO` ties every hart's monitor inputs
to constant 0 instead (`rtl/ooo/core_ooo.v` still has no reservation ports
of its own to drive them with - unaffected by this stage either way,
still zero cross-hart coherence, exactly as before it).

Proven by a new directed test, `sim/tb_soc_2hart_lrsc.v`
(`sim_soc_2hart_lrsc`, now in `make verify`'s dependency list, deliberately
built CORE=inorder-only regardless of `make verify_ooo`'s own ambient
`CORE=ooo` - `$(SOC_RTL_BASE)` and a bare `-g2012`, not
`$(IVFLAGS)`/`$(SOC_RTL)` - since `core_ooo.v` has nothing for this test to
prove): hart 0 executes `LR.W`, hart 1 performs a real handshake-gated
foreign write to the same address, and hart 0's subsequent `SC.W` must
fail. This is this same entry's own "Done when" bar's directed-test
requirement, now met - **for the in-order core only**; `CORE=ooo` has no
LR/SC coherence story of any kind yet, since it never got the reservation
ports in the first place.

**A real bug, caught in the test itself rather than the RTL, worth
recording as plainly as any RTL bug this file records.** The first
version of this test had hart 0 write its own "reservation is set" flag
right after the `LR.W`, to hand-shake with hart 1 - and it passed, for the
wrong reason: `rtl/cpu_core.v`'s reservation-clearing logic invalidates a
hart's own reservation on *any* successful write by that hart, to *any*
address (`any_successful_write`, address-independent, pre-existing
behavior this stage did not touch - see `docs/architecture.md`'s LR/SC
section). Hart 0's own flag write was clearing its own reservation before
hart 1 ever did anything, making the test vacuous. Caught the same way
every RTL directed test in this file earns trust: run against a version
that should fail. A scratch copy of `soc_top.v` with hart 0's
`resv_invalidate_ext` forced back to a constant 0 - simulating a
disconnected monitor - should have failed this test and instead still
passed, which was the tell. Fixed by redesigning hart 0 to make zero
writes between its `LR.W` and its `SC.W`: hart 1 instead uses a fixed,
generous delay-loop budget before its own foreign write, needing no
signal from hart 0 in that direction at all. Re-run against the same
disconnected-monitor scratch copy afterward: it correctly failed, both on
the foreign-write check and the SC-result check.

Both `make verify` and `make verify_ooo` are fully green on the final
tree - formal 6/6 proved, cosim 84/84 on both cores, `verilator_check`
clean.

**What this stage deliberately does not do, and what is not yet true even
though the coherence mechanism itself now is:** `software/soc/bootrom.c`
still does not know a second hart exists (this test bypasses the real boot
ROM entirely, the same way Stage 8's own test did); `dts/soc.dts` has no
`cpu@1` node yet either (Stage 10 gives it one); hart control is still
hart-0-only; and `rtl/ooo/core_ooo.v` still has no reservation ports at
all. **Proving the mechanism works is not the same as the system using
it** - nothing outside simulation can reach a second hart yet, and
OpenSBI/Linux have never seen one. Those remain the open items for later
stages.

**Stage 10: OpenSBI genuinely detects a second hart - the device-tree
half of what Stage 9 left open, not `software/soc/bootrom.c` and not
Linux.** Two changes, both small, both load-bearing. `dts/soc.dts` gains
a `cpu@1` node, matching `cpu@0`'s shape (`reg = <1>`, its own
`cpu1_intc`), and `clint0`'s/`plic0`'s `interrupts-extended` lists grow a
second pair of entries each, in hart order - matching `rtl/clint.v`'s
own per-hart `mtip`/`msip_out` convention (Stage 2) and
`rtl/soc/soc_top.v`'s own `plic_eip[2*h]`/`plic_eip[2*h+1]` convention
(Stage 8) exactly, so the position of each entry in the list is the same
hart-to-context mapping the hardware already uses, not a fresh
invention. `software/opensbi/sbi_stub.S` - the tiny test-harness stand-in
for the boot ROM that `make sim_opensbi`/`sim_linux` actually build
against, **not** `software/soc/bootrom.c`'s own real SD/UART-load path,
which nothing in this project's automated testing exercises yet either
way - had its hardcoded `li a0, 0` (hart ID) replaced with
`csrr a0, mhartid`. That one instruction matters more than it looks:
under `NUM_HARTS=1` it was a no-op (`mhartid` is always 0), which is
exactly why it went unnoticed until now, but at `NUM_HARTS=2` both harts
reset into this identical instruction stream, and the hardcoded version
would have told OpenSBI both harts are hart 0 - the one thing a
multi-hart SBI entry must never claim.

**A second real gate failure, same class as Stage 8's own PLIC one, in a
different module.** Building a new `NUM_HARTS=2` Verilator target
tripped a `WIDTHEXPAND` warning in `rtl/clint.v`'s `word_idx`/
`mtimecmp_hart` bounds checks - the identical mechanism Stage 8 already
fixed once in `rtl/plic.v` (an unsized `NUM_HARTS` parameter, once it
arrives via something other than a bare literal - a Makefile
`-GNUM_HARTS=2` override this time rather than a computed expression -
can get a wider inferred type than the literal default ever had). The
fix is not quite the same one, though, which is worth stating precisely
rather than assuming the precedent transfers unchanged: an 8-bit
narrowed copy (`plic.v`'s own `NUM_CONTEXTS_W8` shape) still tripped the
warning here, just on the *other* operand. Only a copy matching the
comparison's own width exactly - `NUM_HARTS_W14`, 14 bits, the same
width as `word_idx`/`mtimecmp_hart` - resolved it cleanly. Verified with
a standalone `verilator --lint-only -Wall` pass before rebuilding, the
same discipline Stage 8 used.

Proven by a new Makefile target, `sim_opensbi_2hart`
(`VERILATOR_2HART_BIN`, `NUM_HARTS=2`, built from `$(SOC_RTL_BASE)` for
the same CORE=inorder-only reasoning Stage 9's own
`sim_soc_2hart_lrsc` target used - `rtl/ooo/core_ooo.v` has nothing this
target would exercise differently either way): it boots the exact same
`sim/sbiimage.hex` `sim_opensbi` already builds - same OpenSBI binary,
same stub, same `dts/soc.dtb` - with only the `soc_top` build parameter
different, and checks for `Platform HART Count         : 2` in OpenSBI's
own printed banner. Like `sim_opensbi` itself, this is **not** part of
`make verify`/`make verify_ooo` - it needs OpenSBI's separately-cloned
source tree, the same reason `sim_opensbi` already sits outside the
automated gate - so it is run by hand, the same way.

**A real measurement, not a guess, decided the cycle budget.** A first
attempt at 40M cycles - `sim_opensbi`'s own budget - printed only the
ASCII banner and nothing else, which looked like a hang. Resolving the
looping PCs against the real `fw_jump.elf` with `addr2line` placed it
inside libfdt's `fdt_next_node`/`fdt_next_tag` - consistent with either
a genuine infinite loop or simply a slower walk now that `/cpus` has two
subnodes instead of one, and those two explanations are
indistinguishable from a PC trace alone. Distinguished empirically: a
400M-cycle run got much further - the full platform/domain/hart-info
block printed - before settling into a different, later loop
(`sbi_illegal_insn_handler`/`sbi_pmu_ctr_incr_fw`) that matches this
project's own already-documented "unrelated firmware feature-probe" trap
signature (`software/opensbi/README.md`'s own account). That confirmed
the 40M-cycle result was a budget problem, not a bug. A 100M-cycle run,
captured in full rather than through a truncating `tail`, confirmed
`Platform HART Count         : 2` prints correctly; the shipped target
uses 150M for real margin over that measurement, not the measurement
itself.

Also fixed, found while reading the file for this stage:
`dts/soc.dts`'s own top-of-file comment claimed the device tree "is
*not* consumed by anything in this project today" - false since
`software/opensbi/mkimage.py` has packed it into every `sim_opensbi`/
`sim_linux` image since the OpenSBI integration landed, well before this
stage. A stale claim from before that integration, never corrected.
Fixed to say what is actually true now: OpenSBI genuinely parses it at
runtime, while `software/soc/bootrom.c` and `software/soc/main.c` still
use `software/soc/soc.h`'s compiled-in memory map instead, since both
predate the device tree and have no reason to add a parser for one.

**What this stage deliberately does not do:** touch
`software/soc/bootrom.c` at all - the real board-boot path stays exactly
as unaware of a second hart as before, and safely so, since every real
board build still pins `NUM_HARTS=1`; enable `CONFIG_SMP` in
`software/linux/`; or attempt an actual Linux SMP boot. Those remain
fully open.

**Stage 11: a real kernel brings up a second hart - the last clause of
this phase's own "Done when" bar.** Two changes, both small: `software/
linux/vernier_rv32.config` flips `# CONFIG_SMP is not set` to
`CONFIG_SMP=y`, and the kernel is rebuilt against it - no `dts/soc.dts`
or RTL changes this stage, since Stage 10 already gave the device tree
its `cpu@1` node and the Makefile its `NUM_HARTS=2` Verilator variant
(`$(VERILATOR_2HART_BIN)`), both reused unchanged. The rebuilt kernel
still passes the existing ISA-vs-`rtl/` check (740,430 instructions,
nothing outside `rv32ima` plus the privileged set) - `CONFIG_SMP=y`
touches scheduling and synchronization code, not instruction selection,
so this was expected rather than a coincidence, but it was checked
rather than assumed.

Two boots were run, deliberately in this order. First, the SMP-configured
kernel against the *existing*, single-hart (`NUM_HARTS=1`) `make
sim_linux` target - proving `CONFIG_SMP=y` alone does not regress the
boot that already worked, even though the packed device tree (from
Stage 10) now describes a `cpu@1` node the single-hart hardware cannot
actually satisfy. It passed cleanly, reaching the existing boot marker
with the same first-trap signature as every prior single-hart run.
Second, the same kernel image against the real `NUM_HARTS=2` Verilator
DUT: Linux itself printed `smp: Brought up 1 node, 2 CPUs`, and
`/proc/cpuinfo` in the reached userspace shows both `processor : 0`
(hart 0) and `processor : 1` (hart 1), each with the full
`rv32ima_zicntr_zicsr_zifencei_zaamo_zalrsc` ISA string - a genuine SMP
boot to userspace, not a single-hart fallback silently accepted as a
pass.

**Also, incidentally, the first real stress test cross-hart LR/SC
coherence (Stage 9) has seen outside its own directed test.** Spinlocks
and RCU lean on working atomics constantly during SMP bring-up - a
broken `reservation_monitor.v` connection would far more plausibly hang
or corrupt state somewhere in this boot than pass quietly. It didn't.

The cycle budget needed real measurement, not a guess, in the same
spirit as Stage 10's own OpenSBI-only discovery. A first attempt at 250M
cycles timed out having gone no further than ordinary sysfs/kobject
setup work for the newly-registered second CPU - confirmed by resolving
the stuck PCs against `software/linux/build/vmlinux` with `addr2line`,
not assumed from the trace alone. A 600M-cycle run confirmed success at
cycle 286,259,012 - comfortably inside `sim_linux`'s own already-established
400M-cycle budget, which is what the new `sim_linux_2hart` target
actually ships with; no new number was invented for it.

`sim_linux_2hart` mirrors `sim_linux` exactly - same `$(LINUX_MARKER)`,
same `+checkuart` transmitter-drop check, same delimited-marker `grep`
discipline (`docs/practices.md`'s own "a suite that passes is not a
suite that ran the code" lesson already shaped `sim_linux`'s form, and
this reuses it rather than re-deriving it) - but builds against
`$(VERILATOR_2HART_BIN)` instead of `$(VERILATOR_BIN)`, and additionally
greps for both `processor\t: 0` and `processor\t: 1` (the literal tab
`/proc/cpuinfo` uses, checked byte-for-byte against a captured log with
`od -c` before trusting the pattern), so a boot that silently fell back
to one hart would fail this gate even if it still reached the marker.
Like `sim_opensbi_2hart` and `sim_linux` itself, this is **not** part of
`make verify`/`make verify_ooo` - it needs a kernel built from a
separately-fetched source tree - so it is run by hand, the same way.

This stage's own change is provably outside what `make verify`/
`make verify_ooo` could be affected by - one new, additive Makefile
target, not part of either gate's dependency list, plus the kernel
config - so the full gate was not re-run this round, the same measured
non-run Stage 6 already established precedent for.

**What this stage deliberately does not do:** touch
`software/soc/bootrom.c`, `rtl/ooo/core_ooo.v`, or hart control past
hart 0 - none of those needed to change for this specific clause to
close, and none of them did. `CORE=ooo` still has no cross-hart LR/SC
coherence and cannot boot SMP Linux at all. No board build changed -
every real synthesis target still pins `NUM_HARTS=1` and
`CONFIG_SMP` is a simulation-only kernel config choice until a board
build asks for it too. Those remain the genuinely open items, named
plainly rather than folded into a claim this stage did not earn.

**Stage 12: the boot ROM gets a real mailbox - closing the last bullet
of this phase's own opening plumbing list, after the "Done when" bar
itself was already fully closed by Stage 11.** Not part of that bar -
nothing in it asked for `software/soc/bootrom.c` - but this phase's own
opening assessment named the boot ROM's missing `mhartid` read and
mailbox gate as one of the genuinely-just-plumbing items, and it stayed
open through every stage since. `software/soc/crt0_rom.S` now reads
`mhartid` as the very first thing at `_start`, before touching `gp`,
`sp` or `.bss` - all three shared, single-instance resources that only
make sense for whichever hart owns them - and every non-zero hart
branches straight to a new `park_hart` label instead of proceeding into
any of that. `park_hart` spins on a fixed RAM word
(`hart_release_addr`, a new `volatile uint32_t` in `bootrom.c`) that
hart 0 writes once it has finished loading a program and is ready to
jump, releasing every parked hart to the same address.

**A second, genuinely separate bug surfaced by writing this: the boot
ROM's real jump to a loaded program never set `a0`/`a1` at all.** Every
`entry()` call in `bootrom.c` was a bare `void (*)(void)` call - a0/a1
held whatever the C code happened to leave in them, not the RISC-V
firmware entry convention (`a0`=hart ID, `a1`=device-tree address) any
real M-mode firmware, OpenSBI included, expects. This is unrelated to
multi-hart in origin - even the single, always-hart-0 case never got it
right - and was only found because giving secondary harts a correct
`a0` required first making hart 0's own `a0` correct. Fixed together:
`entry`'s type changed to `void (*)(uint32_t, uint32_t)`, `main()` reads
its own `mhartid` once via inline asm, and all three jump sites
(RAM-preload fast path, UART load, SD card) now call `entry(hartid, 0)`
- `a1` stays explicitly, honestly 0, since nothing this ROM loads
carries a device tree yet. That remaining gap - teaching the real boot
ROM to locate and pass one - is a separate, larger piece of work, not
attempted here.

Both mechanisms are explicitly simulation-only, stated plainly in both
files' own new comments rather than left implicit: `hart_release_addr`
relies on RAM starting at 0, which `rtl/soc/wb_ram.v`'s own
simulation-only zero-fill guarantees and real silicon does not (block
RAM powers up undefined there) - harmless on every real board build
regardless, since `NUM_HARTS=1` there means `park_hart` is simply
unreached code.

Proven by a new directed test, `sim/tb_ramboot_2hart.v`
(`sim_ramboot_2hart`, now in `make verify`'s dependency list, built from
`$(SOC_RTL)` so it runs under both `make verify` and `make verify_ooo` -
`bootrom.c`/`crt0_rom.S` have no `CORE_OOO`-specific behavior, unlike
the reservation-port tests Stages 7 and 9 needed pinned to
`CORE=inorder`), that boots through the *real* boot ROM path with
`NUM_HARTS=2` - not `sim/tb_soc_2hart.v`'s `RESET_PC`-into-RAM shortcut
(Stage 8) and not `software/opensbi/sbi_stub.S`'s own hardcoded-address
stand-in (Stage 10), both of which bypass the boot ROM entirely. A
hand-assembled payload reads `a0` directly - proving the hand-off
itself, not just that `mhartid` exists - and each hart writes a
hart-specific sentinel to a hart-specific RAM word, with hart 0 waiting
for hart 1's sentinel before writing the same "PASS" magic word
`sim_ramboot`'s own acceptance test already uses. Confirmed non-vacuous:
a scratch boot ROM built with the `park_hart` branch removed, run
against the identical test, produced visibly garbled console output -
two harts' own banners interleaving character-by-character, exactly
what an unparked concurrent boot looks like - and failed rather than
passing. Both `make verify` and `make verify_ooo` are fully green on the
final tree, including every existing single-hart test
(`sim_ramboot`/`sim_soc`/`trapcheck`/`sim_linux` among them) that also
exercises this same rebuilt boot ROM and was unaffected.

**What this stage deliberately does not do:** teach the boot ROM to
locate or pass a device tree (`a1` stays 0), extend this mailbox
mechanism to real hardware (it is simulation-only by construction), or
touch `dts/soc.dts`, `rtl/ooo/core_ooo.v`, or hart control. Those remain
open, named plainly.

**Done when:** a coherence approach is picked and stated as a decision
(not a default) - **done, Stage 5's D-cache bypass plus Stage 9's
monitor wiring** - ~~both harts are visible to OpenSBI/Linux via the
device tree~~ - **done, Stage 10 for OpenSBI (`Platform HART Count :
2`) and Stage 11 for Linux (`smp: Brought up 1 node, 2 CPUs`)** -
~~`CONFIG_SMP=y` boots to userspace with both harts detected and
idle-looping correctly (not just hart 0 alive)~~ - **done, Stage 11 -
`sim_linux_2hart`, `/proc/cpuinfo` shows both harts, `CORE=inorder`
only** - and ~~a directed test demonstrates the specific hazard the
chosen coherence approach claims to close - an LR/SC pair split across
both harts behaving per spec, at minimum~~ - **done, Stage 9,
`sim/tb_soc_2hart_lrsc.v`, `CORE=inorder`.** Every clause of this bar is
closed for the in-order core, in simulation. `software/soc/bootrom.c`
gained real `mhartid`/mailbox awareness of a second hart separately
(Stage 12, above) - not part of this bar, but the last item this
phase's own opening plumbing list had left open.

**Stage 13: the boot ROM gets a real device tree to hand onward -**
also not part of the coherence bar above, but the other half of Stage
12's own unfinished business: `a0` (hart ID) was fixed to a real value
there, while `a1` (device tree address) stayed a literal 0 at all three
of `bootrom.c`'s jump sites, exactly the gap
`software/opensbi/sbi_stub.S`'s own comment already named as "the boot
ROM's eventual job." `software/soc/gen_dtb_blob.py` embeds this
project's own `dts/soc.dtb` (built by `make dtb`) into the boot ROM's
own image as a plain `.rodata` byte array - no new loading mechanism,
since the boot ROM's 16 KB budget has ample room (the DTB is ~3 KB) to
carry its own copy alongside the code that already lives there. All
three jump sites now pass its real address instead of 0.

Proving this mattered more than writing it: `a0`/`a1` reach `entry()`'s
own stack frame at the boot ROM level, but `software/soc/crt0_ram.S` -
the startup code every loaded program shares - discarded both within a
few instructions (its `.data`-copy loop reuses `a0`-`a2` as scratch,
and `main()` is called with no arguments at all), so nothing was ever
actually checking whether a real value reached a program instead of
being silently dropped in transit. Fixed by preserving both in `s0`/
`s1` across the existing setup loops and publishing them into two new
`.bss`-resident globals (`boot_hartid`, `boot_dtb_addr`) once `.bss`
itself is actually zeroed - defined in `crt0_ram.S` itself, not
expected of each of the several programs that link against it, since
most never look at either.

`software/soc/main.c`'s new `test_boot_dtb()` checks three real things
through the actual boot path a program was loaded by, not by reading
`crt0_ram.S` and trusting it: the hart ID is this board's own real
value (0), the device-tree address falls inside the boot ROM's own 16
KB rather than being merely non-zero, and the four bytes there are the
real flattened-device-tree magic number (`0xd00dfeed`) - a structural
check, not a null check. Both the RAM-preload and SD-card jump sites
(`make sim_ramboot`, `make sim_soc`) exercise it, since both load
`main.c`'s own acceptance test; the UART path loads a different,
smaller payload that does not, but shares the identical `bootrom.c`
fix, already confirmed identical by inspection across all three call
sites. Confirmed non-vacuous by mutation: dropping the `a1`
preservation in `crt0_ram.S` (substituting a literal 0 for the
preserved value) made the same check fail.

**What this still does not do:** the boot ROM's three loading paths
still only ever load a plain RAM program (`PROGRAM_LOAD_ADDR`, block
RAM) - none of them can load OpenSBI into SDRAM the way
`software/opensbi/sbi_stub.S`'s own minimal stand-in does for
`make sim_opensbi`/`make sim_linux`. Handing a *loaded program* a real
device tree and *loading OpenSBI itself* over the real boot path are
two different gaps; this stage closes the first, not the second, and
sits alongside Stage 12's own mailbox as boot-path plumbing rather
than a `NUM_HARTS>1` capability. `CORE=ooo` coherence, hart control
past hart 0, and an actual board build with `NUM_HARTS>1` all remain
open, and none of them were ever part of what the coherence bar above
asked for either.

**Stage 14: hart control past hart 0 - `rtl/debug/dm.v`'s own `hartsel`
reaches every hart, not just hart 0.** The third of Phase 13's own named
loose ends, and the one closest to a real redesign of the three: unlike
Stage 13's boot-path plumbing, this touches `rtl/debug/dm.v` itself,
the RISC-V Debug Spec's own `dmcontrol.hartsello` field, honored for the
first time (previously accepted and silently ignored). `haltreq`/
`resumereq`/`halted` become `NUM_HARTS`-wide - `haltreq`/`resumereq`
one-hot on whichever hart `hartsel` currently names, matching the
spec's own model of controlling one hart at a time. The Abstract
Command register port (GPR/`dcsr`/`dpc` access) stays scalar on `dm.v`'s
own side - it only ever talks to one hart's register port at a time -
with `rtl/soc/soc_top.v` fanning it out and muxing it back per hart
using `hartsel`, the same per-hart-wiring shape every other signal in
that file already has (`resv_valid`, the Wishbone master triples, and
now this).

**A real correctness property, not just wiring: a debugger addressing
hart 1 must not be able to read or write hart 0's registers, even
while both happen to be halted at once.** `rtl/soc/soc_top.v` gates
each hart's own `dbg_reg_valid` input on `hartsel == that hart`, not
merely on `dbg_reg_valid` alone - the difference between "the DM issued
a command" and "the DM issued a command *for this hart*." Confirmed
non-vacuous by mutation: hardcoding hart 0's own gate to ignore
`hartsel` and always accept `dbg_reg_valid` (a plausible real mistake -
it is exactly what the tie-off used to be, before this stage) made the
cross-hart isolation check below fail, corrupting hart 0's own register
with hart 1's write.

`sim/tb_jtag.v` now builds `NUM_HARTS=2` and proves the real thing, not
just that `hartsel` accepts a write: hart 0 is halted first (the
existing single-hart test sequence, unchanged), then hart 1 - never
touched before this point - is confirmed running, halted independently,
and given its own sentinel register value distinct from hart 0's own
(`0xCAFE_0001` against hart 0's pre-existing `0xCAFE_F00D`). Switching
`hartsel` back to hart 0 and reading its own `x5` proves it is *not*
`0xCAFE_0001` - the actual cross-hart isolation property, not merely
"hart 1's own write succeeded." Hart 1's own sentinel is then confirmed
to have survived the round trip unchanged, and both harts resume
independently. Every pre-existing single-hart check in this file still
passes unchanged, proving `hartsel` defaulting to hart 0 on reset keeps
every existing single-hart workflow working exactly as before.

**What this still does not do:** `CORE=ooo` still has no debug register
port on any hart, regardless of which one a host selects - the tie-off
now honestly reports `cmderr`=halt/resume-required for every hart, not
just hart 0. No hasel/hart-array group selection (the spec's own way to
control several harts as one operation) - only one hart at a time,
which is what a real debugger session actually does. `software/soc/
bootrom.c` and `dts/soc.dts` still do not know a second hart exists.
`CORE=ooo` coherence and an actual board build with `NUM_HARTS>1`
remain open, closing out every item Phase 13 itself ever named as
still open except those two.

**Stage 15: `rtl/ooo/core_ooo.v` gains the same reservation ports
`cpu_core.v` has had since Stage 7 - proven in isolation, not yet wired
for real cross-hart use, the same "ports first, wiring later" sequencing
Stage 7 → Stage 9 already used once for the in-order core.** `CORE=ooo`
has had zero cross-hart LR/SC coherence story of any kind since Phase 13
began - `resv_valid`/`resv_addr`/`store_fire`/`store_addr`/
`resv_invalidate_ext` simply did not exist on this core. This stage adds
them, identically named and shaped to `cpu_core.v`'s own, so
`rtl/soc/soc_top.v` can eventually wire either core into the same
`rtl/soc/reservation_monitor.v` instance without special-casing either
one. `resv_valid`/`resv_addr` are a direct passthrough of the private
`reservation_valid`/`reservation_addr` registers this core has always
had. The new reservation-clearing branch (`resv_invalidate_ext`, checked
ahead of every existing branch, mirroring `cpu_core.v`'s own justified
ordering) is provably inert everywhere today: every existing build ties
the input to 0, so this stage changes no currently-passing test's own
functional outcome - confirmed by running the same directed cosim/formal
suite unchanged. It does, as the next two sections cover, require
explicitly tying off the new ports wherever `core_ooo.v` was already
instantiated without them - a mandatory Verilog port is not optional
regardless of whether anything is wired to it yet.

**Why this was safe to add without touching the pipeline's own
speculative machinery:** AMO/LR/SC get an ordinary ROB entry at dispatch
like any other instruction, but execute only once genuinely at the ROB
head - architecturally impossible for a speculative or since-flushed
instruction to ever touch the reservation. Neither a trap, an interrupt,
nor a mispredict-driven recovery can preempt an in-flight AMO's own bus
transaction (a previously-fixed real bug in exactly this area already
guarantees it). This extension is additive wiring plus two new signals,
not a rearchitecture.

**The one genuinely OOO-specific piece: `store_fire`/`store_addr` are not
simply `cpu_core.v`'s own terms re-exported.** This core has a
single-entry store buffer a plain store retires into *before* its write
actually reaches the bus - by the time that buffered write lands,
`rob_head` has already advanced to a different, younger instruction, so
`store_addr` must come from the store buffer's own address register for
that case (`sb_addr`), not wherever the ROB head is sitting on by then
(`head_mem_phys_addr`, used for the direct-store/AMO case instead).
Separately, this core's own internal `dmem_we_amo` stays asserted for
every cycle of a multi-cycle AMO write wait, not just the completing one
- a raw port built from it would pulse "landed" once per wait cycle
rather than once per write; `amo_done` already means "this phase's own
transaction just acked," so `dmem_we_amo && amo_done` is the correct
one-cycle pulse.

`rtl/top.v` - the flat, zero-latency harness `make verify`'s base gate
already builds - needed the identical fix Stage 7 made to this same file
for the identical reason: an explicit tie-off for the new ports (an
unconnected Verilog input floats/reads as X, which would poison every
test that instantiates this module), applied to both core types now
rather than only `cpu_core.v`.

**A second, real instance of the same gap, caught only by running the
actual gate rather than by inspection.** `rtl/soc/soc_top.v`'s own
`` `ifdef CORE_OOO `` instantiation of `core_ooo` (hart 0 and the
harts-1..N-1 generate loop) was deliberately left unwired this stage -
the plan for this work explicitly scoped real cross-hart wiring to a
later stage. What that plan missed: Verilog ports are not optional
regardless of whether anything meaningful is connected to them, and
Icarus (`make verify`) tolerates an unconnected port silently enough
that the omission built and passed clean - but Verilator's own build
(`make verilator_sdramboot`, part of `make verify_ooo`) reports a missing
pin connection as a fatal error, not a warning, and failed outright.
Fixed the same way `rtl/top.v` was: an explicit tie-off
(`.resv_valid()`, `.resv_addr()`, `.store_fire()`, `.store_addr()`,
`.resv_invalidate_ext(1'b0)`) on both `core_ooo` instantiations, leaving
the real per-hart wiring in the `` `else `` branch (still `cpu_core.v`
only) completely unchanged. Confirmed by rebuilding
`make verilator_sdramboot` for both `CORE=inorder` and `CORE=ooo`
directly before re-running the full gates.

Proven by a new standalone test, `sim/tb_ooo_resv_ports.v`
(`sim_ooo_resv_ports`, unconditionally in `make verify`'s dependency
list - it always exercises `core_ooo.v` regardless of ambient `CORE=`),
modeled directly on Stage 7's own `sim/tb_cpu_resv_ports.v` with one
addition that test's own zero-latency memory model structurally cannot
make: a small, self-contained wait-state injector (the same "prove the
hard piece in isolation" role `sim/tb_reservation_monitor.v` already
plays), needed because a plain store is only ever absorbed into the
store buffer when its own write has to wait. Three checks: (1) the same
baseline Stage 7 already proves - LR.W/SC.W with no interference, SC
succeeds, exactly one `store_fire` pulse at the right address; (2) the
same external-invalidation case - a foreign invalidation pulsed
mid-window clears the reservation and makes SC fail; (3) new - a plain
store to a *different* address than the held reservation, followed by
filler ALU instructions so `rob_head` genuinely advances past it before
the buffered write drains, checking `store_fire` pulses once with
`store_addr` reporting the store's *own* address, not the reservation's
and not wherever the ROB head has moved on to.

Confirmed non-vacuous three separate ways, one mutation per check,
matching this project's own per-assertion "make it fail first"
discipline: disabling the `resv_invalidate_ext` branch made check 2 wrongly
report success (3 failures, cascading correctly into the aggregate pulse
count too); dropping the `sb_addr` mux (using `head_mem_phys_addr`
unconditionally - what a naive port of `cpu_core.v`'s own single-arm
`store_addr` would look like) made check 3 report the wrong address, and
only that check; replacing the qualified `amo_write_completing` with the
raw, multi-cycle-high `dmem_we_amo` made check 1's pulse count exceed one
for a single write. All three mutations were reverted and the test
reconfirmed passing before this was written down. Both `make verify` and
`make verify_ooo` are fully green on the final tree.

**What this stage deliberately does not do:** wire these ports into
`rtl/soc/soc_top.v`'s own `reservation_monitor` instance - every
`CORE=ooo` build today still ties `resv_invalidate_ext` to 0 and ignores
the three outputs, exactly as before this stage, so `CORE=ooo` still has
no *cross-hart* coherence of any kind yet. That is deliberately a
separate stage (mirroring Stage 9's own split from Stage 7), since it
carries its own real risk - a live two-hart hazard, not an isolated
port - and deserves its own gate and its own directed proof rather than
being folded into this one. Hart-control/debug register ports for
`core_ooo.v` remain a separate, still-open gap, untouched by this stage.
No new formal property was added - matching Stages 6/7/9's own choice to
prove this exact feature by directed simulation only, on the other core.

**Stage 16: those ports wired for real - `CORE=ooo` has genuine
cross-hart LR/SC coherence now, the same bar Stage 9 already proved for
the in-order core.** `rtl/soc/soc_top.v`'s `resv_valid`/`resv_addr`/
`store_fire`/`store_addr`/`resv_invalidate_ext` connections move from a
core-specific `` `ifdef CORE_OOO ``/`` `ifndef CORE_OOO `` split (tie off
for `CORE=ooo`, real wiring for `cpu_core.v` only) to a single,
unconditional connection - both cores expose identically-shaped ports
now (Stage 15), so neither needs special-casing here any more than
`NUM_HARTS` itself does. `dbg_*` (hart control) stays split by core
type, untouched - that remains a separate, still-open gap.

`sim/tb_soc_2hart_lrsc.v` - Stage 9's own directed cross-hart hazard
test - gains real CORE=ooo coverage the same way: its Makefile rule
moves from a hardcoded, always-in-order `$(SOC_RTL_BASE)`/`-g2012` build
(deliberately bypassing the ambient `CORE=` variable, since there was
nothing for it to test before this stage) to the ordinary
`$(SOC_RTL)`/`$(IVFLAGS)` every other sim target already uses - a strict
no-op under the default `CORE=inorder` (confirmed: both variables are
empty there, so the generated build command is byte-for-byte the same),
and for the first time a genuine test of `core_ooo.v`'s own cross-hart
coherence under `make verify_ooo`'s own ambient `CORE=ooo`, rather than
silently re-testing the in-order core redundantly as it did before this
stage. The test's own hand-assembled program needed no changes: hart 0's
SC has always been gated behind polling a flag hart 1 sets only after
its own foreign write, so correctness never depended on the delay loop's
exact length, and the existing cycle budget passed on its first run
against `CORE=ooo` with no adjustment needed - measured, not assumed.

**Confirmed non-vacuous the same way Stage 9 confirmed it for the other
core, run again here specifically for `CORE=ooo`:** forcing hart 0's own
`resv_invalidate_ext` connection to a constant 0 in a scratch copy of
`soc_top.v` (simulating a disconnected monitor) made the test fail
exactly as it should - hart 0's SC wrongly succeeded (`rd=0` instead of
`1`), and its own now-successful write overwrote the shared address with
its own data, changing what the "foreign write landed" check itself saw
too. Reverted and reconfirmed passing before this was written down.

**What this stage deliberately does not do:** `CORE=ooo` still cannot
boot SMP Linux (untouched by this stage - `software/soc/bootrom.c` and
`dts/soc.dts` still don't know a second hart exists, for either core),
and still has no debug register port on any hart, regardless of which
core. No board build has ever asked for `NUM_HARTS>1` on either core.
Those remain the genuinely open items - this stage closes the coherence
gap specifically, not the rest of what a second hart would need to be
useful outside simulation.

**Stage 17: `CORE=ooo` boots the same `CONFIG_SMP=y` Linux to userspace
on both harts too - measured, not assumed, and it passed on the first
attempt.** With coherence wired for real (Stage 16), the one remaining
piece was mechanical rather than architectural: `sim_linux_2hart` and
`sim_opensbi_2hart` share one Verilator build rule
(`$(VERILATOR_2HART_BIN)`) that was still hardcoded to `$(SOC_RTL_BASE)`
with no `$(CORE_DEFINES)` - the exact same always-in-order hazard
`sim_soc_2hart_lrsc`'s own Makefile rule had before Stage 16, just not
yet fixed here. Fixed the identical way: `$(SOC_RTL)`/`$(CORE_DEFINES)`
replace the hardcoded in-order-only set, and `$(VERILATOR_2HART_MDIR)`
gained a `_$(CORE)` suffix (matching `$(VERILATOR_MDIR)`'s own existing
convention) so an in-order and an `ooo` 2-hart build no longer clobber
each other's output directory. Confirmed a strict no-op for
`CORE=inorder` by re-running `sim_linux_2hart` there directly - identical
pass, identical marker.

**Every other piece of the software stack was already confirmed
core-agnostic, not assumed to be** - checked directly, not inferred:
`software/soc/crt0_rom.S`'s hart dispatch is a plain `mhartid` CSR read;
`software/soc/bootrom.c`'s mailbox and device-tree hand-off take a
generic `hartid`/`boot_dtb` pair at every jump site; `dts/soc.dts`'s
`cpu0`/`cpu1` both declare the same architectural `riscv,isa` string, not
an implementation-specific one; `software/opensbi/build-opensbi.sh` uses
OpenSBI's own `PLATFORM=generic`, driven entirely by the device tree; and
`software/linux/vernier_rv32.config`'s `CONFIG_SMP=y` has no core-specific
Kconfig symbol anywhere. None of these needed a single change - the gap
really was confined to the one Makefile rule.

**The genuinely open question this stage actually answered by running
it, not by inspection:** whether `core_ooo.v`'s cross-hart coherence and
its own memory-ordering machinery would hold up under *real* concurrent
SMP Linux bring-up - spinlocks, RCU, and scheduler IPIs from two
simultaneously-running out-of-order harts, not one directed hazard test.
This core has a documented history of exactly this class of bug: a real
AMO-ordering defect that corrupted a kernel rwsem word took 15 rounds to
root-cause before single-hart `CORE=ooo` Linux boot was even reliable
(see the "Known defects" entry this file already tracks). That history
made this stage's own outcome genuinely uncertain going in, not a
formality - and `make sim_linux_2hart CORE=ooo` passed on its first run:
both harts print their own `/proc/cpuinfo` entry, `smp: Brought up 1
node, 2 CPUs` appears in the kernel's own log, and
`VERNIER-RV32-LINUX-BOOT-OK` is reached at cycle 276,918,694 - close to
the in-order core's own 286,259,012 for the identical milestone, and well
inside the existing 400M-cycle budget with no adjustment needed.
`sim_opensbi_2hart CORE=ooo` was run too, for completeness: it times out
against its own cycle budget by design (OpenSBI has no payload to hand
off to here, matching `sim_opensbi`'s own single-hart behavior), but its
banner-text check - `Platform HART Count : 2`, `Boot HART Base ISA :
rv32ima` - passes the same way it always has.

**What this stage deliberately does not do:** neither `sim_linux_2hart`
nor `sim_opensbi_2hart` is part of `make verify`/`make verify_ooo` (both
need a cloned OpenSBI/Linux source tree, the same reason their
single-hart equivalents are not either) - this is a manually-run proof,
not a gated regression, matching every other Linux/OpenSBI target in
this file. `CORE=ooo` still has no debug register port on any hart, and
no board build has ever asked for `NUM_HARTS>1` on either core - those
remain the genuinely open items.

**Stage 18: `rtl/ooo/core_ooo.v` gains the same halt/resume/single-step/
register-access ports `cpu_core.v` has had since Phase 6 - proven in
isolation, not yet wired for real use, mirroring the exact "ports first,
wiring later" sequencing Stages 15 -> 16 already used for cross-hart
coherence on this same core.** `CORE=ooo` has had zero hart-control story
of any kind since Phase 6 - `dbg_haltreq`/`dbg_resumereq`/`dbg_halted`/
`dbg_reg_*` simply did not exist on this core, and `rtl/soc/soc_top.v`'s
own tie-off reported every hart as permanently running, every Abstract
Command as `CMDERR_HALTRESUME`, honestly rather than silently. This stage
adds them, identically named and shaped to `cpu_core.v`'s own, so
`rtl/debug/dm.v` can eventually reach either core's hart-control ports
without any change of its own - confirmed by direct read that `dm.v`
already forwards `cmd_regno` completely generically and gates only on
`sel_halted`, with zero GPR/dcsr/dpc-specific logic anywhere in it.

**The one place a literal port of `cpu_core.v`'s own design would have
been wrong, found before writing a line of RTL:** this core has a
4-deep fetch buffer (FB) between IF and dispatch, and fetch/PC
advancement is completely independent of dispatch admission -
`dispatch_can_go` (the natural, `cpu_core.v`-mirroring hook point) has no
fetch term at all, and the `pc` register only freezes once the FB itself
stops filling. Gating dispatch alone would have let `pc` and the FB run
up to four words ahead of whatever the ROB had actually drained -
`rob_empty` would hold with no single unambiguous resume address. The
correct hook is `fb_push` (the FB's own fill condition), not
`dispatch_can_go`: block only new fetch admission; leave dispatch,
execute, retire, and recovery completely untouched, so everything
already in flight drains through the pipeline exactly the way
`cpu_core.v`'s own "halting drains the pipeline instead of killing it"
already works, just anchored one stage earlier. Once `fb_push` is
blocked, the FB drains to empty for free as dispatch keeps popping it;
once the FB and the ROB are both empty, `pc` has been frozen since the
halt request and is the single, unambiguous resume address.

**A second, genuinely OOO-specific quiescence term, found by tracing the
store-buffer mechanism the LR/SC coherence work (Stage 15) already
named:** a plain store retires from the ROB the instant it hands off to
the one-entry store buffer, before its write actually reaches the bus.
`rob_empty` can therefore be true while a write this hart already
reported as retired is still physically draining - `cpu_core.v` never
needed a separate term for this because its own quiescence check already
holds a store for its whole in-flight duration instead of retiring it
early. `core_ooo.v`'s own quiescence needs an explicit `!sb_valid` term
`cpu_core.v` never needed; AMOs and out-of-order loads need no
equivalent (both already complete their register/bus effect no later
than retirement).

**GPR access, verified safe once quiescent, and one genuine design
divergence from `cpu_core.v`'s own single-array mux:** `rtl/ooo/
regfile_phys.v` is addressed by *physical* register number; the live
architectural-to-physical mapping is `rat[]` in `core_ooo.v`, not a
second architectural register file. `rat[]`'s only two writers -
dispatch and the mispredict/exception recovery walk - are both provably
inert for the entire halted window (dispatch requires the fetch buffer
non-empty, which stays blocked; recovery requires a non-empty ROB).
Every physical-register write from every completion class was traced
and lands no later than the cycle its own ROB entry stops being
counted, so `rob_empty` is sufficient proof every GPR write has already
landed. A debug read/write goes through `rat[dbg_gpr_idx]`, not the raw
regno directly - `regfile_phys.v` gained one new combinational read port
(`dbg_rs_a`/`dbg_rdata_a`, mirroring `rtl/regfile.v`'s own `dbg_rs`/
`dbg_rdata`) for reads, and debug writes reuse the existing Class-S
write port via a priority mux at the `core_ooo.v` instantiation boundary
- safe because that port's own real driver (`cdbS_valid`) is provably 0
whenever the core is genuinely halted.

Proven by a new standalone test, `sim/tb_ooo_halt.v` (`sim_ooo_halt`,
unconditionally in `make verify`'s dependency list - it always exercises
`core_ooo.v` regardless of ambient `CORE=`), modeled on `sim/
tb_cpu_halt.v`'s own 2-instruction increment-loop program and its full
check list (freeze, dcsr/dpc read, unrecognized-regno error, debug
write/read-back, resume-and-continue, and single-step - two full
stepped iterations, confirmed to retire exactly one instruction each),
plus one check neither `cpu_core.v` nor its own test has an equivalent
of: halt requested while a store is still draining must not take effect
until the store buffer clears.

**A real, non-vacuous test bug caught by the mutation itself, not by
inspection - worth recording as plainly as any RTL bug this file
records.** The first version of the store-buffer check reused the
shared increment-loop program, waited for the store to begin its bus
request, then polled once for the ROB/fetch-buffer to both drain before
checking `dbg_halted`. It passed - including against a deliberately
mutated `dbg_pipeline_quiescent` with `!sb_valid` removed, which should
have failed and did not. Tracing why: fetch and dispatch race far ahead
of a store's own bus completion (confirmed by a direct signal trace, not
assumed) - by the time the shared loop's own store even reached the bus,
several loop iterations were already dispatched, so the ROB/fetch buffer
never actually drained close to empty until long after the store buffer
had already cleared on its own, making the check vacuous regardless of
the RTL's own correctness. Fixed two ways: check 0 now runs its own
small, isolated program (one store followed immediately by a self-jump,
so nothing further is ever admitted once fetch is blocked), and the
check itself polls continuously for as long as the store buffer holds -
not a single check at the instant quiescence is first observed, which
would pass regardless of the mutation for an unrelated reason (a
registered output always lags the condition that sets it by at least
one cycle; only continuous polling can distinguish "one cycle of the
usual registered lag" from "several cycles because `sb_valid` is
genuinely part of the gate"). Confirmed non-vacuous afterward, the same
mutation now caught, and reconfirmed passing before this was written
down.

Six further mutations, one per remaining check, each confirmed to fail
only the check meant to catch it: dropping the fetch-admission gate
entirely (freeze), swapping the two `dcsr.cause` literals, forcing every
regno to appear valid, dropping the debug-write arms from the register
mux, using the raw regno instead of `rat[dbg_gpr_idx]` (the RAT-
indirection bug - caught specifically by "the value was genuinely
executed from," not by the read-back check alone, since a debug read of
the same wrong mapping is internally consistent), and re-blocking
single-step admission off `dispatch_can_go` instead of `fb_push` (a
real, demonstrable bug: a one-cycle window where `fb_count` has already
reflected a push but the step-admitted latch has not yet caught up,
letting a second, unwanted instruction through). `rtl/top.v`'s tie-off
was made unconditional (mirroring Stage 15's identical fix to this same
file), and `rtl/soc/soc_top.v`'s two `core_ooo` instantiation sites were
given explicit, still-inert tie-offs for the same reason Stage 15
needed them - confirmed via `make verilator_sdramboot CORE=ooo`
directly, not assumed, since this is exactly the class of regression
that stage already hit once. Both `make verify` and `make verify_ooo`
are fully green on the final tree.

**What this stage deliberately does not do:** wire these ports into a
real `rtl/debug/dm.v` - every `CORE=ooo` build still ties every new port
off exactly as before this stage, so `CORE=ooo` still has no *reachable*
hart-control story through the real DMI path yet. That is deliberately a
separate stage (mirroring Stage 16's own split from Stage 15), since it
carries its own real risk - `sim/tb_jtag.v`'s own cross-hart isolation
and Abstract Command assertions running against a real second core, not
an isolated port - and deserves its own gate and its own proof rather
than being folded into this one. No new formal property was added -
matching every hart-control and coherence stage before it on this
project's own choice to prove this exact class of feature by directed
simulation only.

**Stage 19: those ports wired for real - `CORE=ooo` has genuine
halt/resume/single-step/register access now, over the real DMI protocol,
the same bar Phase 6 already set for the in-order core.** `rtl/soc/
soc_top.v`'s `dbg_haltreq`/`dbg_resumereq`/`dbg_halted`/`dbg_reg_*`
connections move from a core-specific `` `ifdef CORE_OOO ``/`` `ifndef
CORE_OOO `` split (tie off for `CORE=ooo`, real wiring for `cpu_core.v`
only) to a single, unconditional connection - both cores expose
identically-shaped ports now (Stage 18), so neither needs special-casing
here any more than the reservation ports already stopped needing it at
Stage 16. `rtl/debug/dm.v` itself needed no change at all: confirmed by
direct read that it only ever forwards `cmd_regno` generically and gates
on `sel_halted`, with zero GPR/dcsr/dpc-specific logic anywhere in it -
the same "already core-agnostic" finding Stage 17 made for OpenSBI and
the kernel.

`sim/tb_jtag.v` - the existing protocol-level test that already proves
this for `cpu_core.v` (halt/resume over `dmcontrol`/`dmstatus`, Abstract
Command register access, single-step over DMI, and cross-hart isolation
with a real second hart) - gains real `CORE=ooo` coverage the same way:
its own `` `ifdef CORE_OOO `` branches (which previously asserted the
honest-refusal behavior - `haltreq` accepted and ignored, every Abstract
Command answered `CMDERR_HALTRESUME`) are removed, and the same real
assertions the in-order branch already used now apply unconditionally to
whichever core the ambient build selects. **Passed against `CORE=ooo` on
the first run** - every check that already passed for `cpu_core.v`
passed identically here too, including the two-hart cross-hart isolation
sequence (both harts real `core_ooo` instances, one halted and
register-accessed while the other keeps running, each resumed
independently without disturbing the other).

**Confirmed non-vacuous by mutating the new wiring itself, not just
re-relying on Stage 18's own port-level mutations** (which proved the
mechanism, not this stage's own connection of it): tying hart 0's
`dbg_haltreq` connection back to a constant 0 in a scratch copy of
`soc_top.v` - simulating the wiring never having happened - produced 21
cascading failures through `sim/tb_jtag.v`, starting from the very first
halt request and propagating through every check downstream of it.
Reverted and reconfirmed passing before this was written down.

**What this stage deliberately does not do:** attach a real `openocd`+
`gdb` to either core - this project's own debug-spec deviations (no
debug ROM, no Program Buffer, no `ebreak`-triggered entry) are unchanged
and apply equally to both cores now. No board build has ever asked for
hart control on `NUM_HARTS>1`. Those remain the genuinely open items -
this stage closes the wiring gap specifically, the last piece Phase 13
named as still open for `CORE=ooo`.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

None. No board build has ever asked for `NUM_HARTS>1` on either core: every real synthesis target pins `NUM_HARTS=1`. Nothing in this phase is confirmed on silicon.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Every "Done when" clause is closed in simulation for the in-order core, and the later stages extend the reservation, debug and SMP work to `CORE=ooo`: two harts, cross-hart LR/SC through `rtl/soc/reservation_monitor.v`, OpenSBI detecting the second hart, and a `CONFIG_SMP=y` kernel bringing it up to userspace, all gated by `make verify` and `make verify_ooo`. The stage accounts above list what each one did and did not cover.
