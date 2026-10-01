# Phase 6 — Debug infrastructure

**Half done, and it is the half that was blocking things.** `rtl/debug/` is a
JTAG TAP, a RISC-V Debug Transport Module and a Debug Module implementing
System Bus Access: four pins on the `gn` header to a bus master that reads and
writes any address the SoC decodes, without the CPU's cooperation.

That is what turns "the board prints nothing" from the end of an investigation
into the start of one. Every failure that has cost real time here — OpenSBI
hanging before its console came up, the boot ROM stopping silently, Linux
dying between `earlycon` and `ttyS0` — had its evidence sitting in memory with
no way to read it.

`make sim_jtag` drives the four pins as an adapter would and is in
`make verify`; `formal/fv_interconnect.v` proves the arbitration with the
fourth master.

**Before the timing margin: something in user mode depended on the fetch
path's behaviour during an ITLB walk - and for the simplest of four
attempts, it did not.** All four left the kernel boot untouched - within
1,301 cycles of each other to `Freeing unused` - and all made *user mode* at
least 150x slower, with the traps concentrating in `uart_write`. That is the
interrupt-driven tty path rather than the polled console one, which pointed
at UART interrupt delivery through the PLIC - the one link in the interrupt
chain never proved on hardware or in a bare-metal test on this design.
fpga/README.md has the four variants and the two wrong diagnoses that
preceded the right one: the `mip.SEIP` RMW latch-up of
[practices.md §45](../practices.md), which produces exactly "user mode crawls
in the interrupt-driven tty path" and arms on any reshuffle of the boot's
interleaving - which every one of the four fetch-path variants is, by
construction. Re-running the simplest of them - explicit gating instead of
an accidental cache hit, `rtl/cpu_core.v`'s `itlb_wait_stall` - on top of the
CSR fix settled it: both cores boot within 15,000 cycles of baseline, not
150x slower. [fpga/README.md has the numbers](../../fpga/README.md); the other
three variants were not re-run.

**Measured 2026-08-24: `BOARD=ulx3s85` closes 0 of 6 seeds**, routed
22.44-24.14 MHz against a 25 MHz constraint. The headline target now joins
`-plictest` in not building. The critical path is `CPU.pc`-sourced in four of
those six seeds and `BUSADAPT.dc_tag`-sourced in the other two, both 23 logic
levels deep and both routing-dominated. `fpga/README.md` has the numbers, the
two path shapes, and why this is not called a regression.

**The timing margin has stopped being a risk and started blocking work — and
the first fix for it had to be reverted.** `BOARD=ulx3s85-plictest` failed to close timing on four consecutive
seeds and could not be built. All three peripheral bitstreams now close on the
first seed at 25.28 MHz *with* the peripheral bridge's ack registered (#49) -
the margin was going into a combinational round trip from the CPU to an MMIO
slave and back into the stall network, not into the fetch path this file
previously blamed.

**That change is reverted, and the revert's diagnosis was wrong.** It broke
the Linux boot - supervisor-external interrupts went from 50 to 87,339 and
userspace never finished starting - but the claim/complete loop this file
said it disturbed was never disturbed: the bus trace shows 24 interrupts
claimed and completed correctly, then 87,339 claims of zero. The storm was a
latent CSR bug armed by *any* change to the boot's cycle-level interleaving:
an mip CSRRS/CSRRC computed its write-back from the OR'd live SEIP and
latched the PLIC's momentarily-high line into the software half, permanently.
Fixed in `rtl/csr_file.v` with the spec's own carve-out; `plictest` section
3b is the directed regression, and Linux boots to the marker with #49's
registered ack re-applied on top of the fix. **The registered ack is
re-landed**, with fresh nextpnr numbers: `ulx3s85` closes on seed 3 of 6 at
25.96 MHz routed (2026-08-26), and all three peripheral bitstreams still
close on the first seed at 25.28 MHz - unchanged, because the ack itself is
byte-for-byte what #49 shipped. [practices.md §45](../practices.md) is the
post-mortem.

**The timing margin is what gates the rest of it**, and one attempt at the
critical path has been made and reverted — `fpga/README.md` has the path, the
numbers and why the change did not ship. The measured chain is `pc` -> ITLB ->
`imem_addr` -> bus arbitration -> the stall that clocks the pipeline
registers, all in one cycle.

**A fetch pipeline stage addresses the first half of that chain, and the
second half is bigger.** Printed in full, both critical-path shapes converge
on a shared tail — bus arbitration through the stall network to the pipeline
register enables — worth about 22 ns of a 42.76 ns path, present in every
seed. The head a fetch stage would cut is ~19.9 ns on the four `pc`-sourced
seeds and nothing on the two sourced at the D-cache tag. 71% of the path is
routing, which is what one stall signal fanning out across the die looks
like. `fpga/README.md` has the full paths and the arithmetic.

**Halt, resume, and register (GPR/`dcsr`/`dpc`) access are now real, in
simulation, on `CORE=inorder`** — deliberately without the RISC-V debug
spec's full model. That model needs debug mode, `dcsr`, `dpc`, `dret` and a
debug ROM the core vectors into, all of which land on the fetch redirect and
the register file write port, on a design where two of six placement seeds
already fail to close 25 MHz - exactly the gate this section already named.
What shipped instead is deliberately smaller: halt is "freeze pipeline
*admission* in place" (one term added to the existing `pc_freeze`/hold
machinery, the same class of stall the pipeline already handles for a
load-use hazard or a busy divide), resume is un-freezing it, and register
access is a dedicated read/write port into `regfile.v`, active only while
genuinely halted - no debug ROM, no `dret`, no new address-space
reservation, nothing added to the fetch-redirect mux at all. `dcsr`/`dpc`
live as private registers in `rtl/cpu_core.v` rather than in `csr_file.v`,
specifically so ordinary M/S/U-mode software has no path to them - there is
no debug-mode instruction stream under this model that would ever need one.
`CORE=ooo` has no hart-control ports at all: `rtl/soc/soc_top.v` ties its
`halted` input to 0, so `dmstatus` keeps reporting it as running rather than
accepting `haltreq` and silently doing nothing. `make sim_cpu_halt` drives it
directly against `rtl/cpu_core.v`; `sim/tb_jtag.v`'s own `dmcontrol`/
`dmstatus` DMI round-trip is core-aware and checks the correct behavior for
each core.

**Register access now reaches all the way from the real DMI wire, not just
`rtl/cpu_core.v`'s own port.** `rtl/debug/dm.v` gained an Abstract Command
state machine (`abstractcs`/`command`/`data0`, RISC-V Debug Spec 0.13
SS3.6-3.7.1.1) that decodes Access-Register commands - 32-bit only, no
Program Buffer (`postexec` always reports `cmderr` = not-supported, since
there is nothing for it to execute) - and drives `rtl/cpu_core.v`'s existing
debug register port the same way `haltreq`/`resumereq` already do: single-
cycle turnaround, no Wishbone traffic, `cmderr` = halt/resume-required if the
hart is not genuinely halted first. `rtl/soc/soc_top.v` wires this
unconditionally; `CORE=ooo` refuses every command with that same
halt/resume-required error, honestly, the same rule its `dmstatus` already
followed. `sim/tb_jtag.v`'s stage 9 exercises it end-to-end over the actual
bit-banged JTAG protocol - halt, read/write a GPR, read `dcsr`/`dpc`, two
negative paths (an unsupported access size, an unrecognized `regno`), resume,
and confirm the debug-written value is what the hart actually picked up and
advanced past - which needed `sim/jtagram.hex` (the generated block-RAM
image every JTAG test boots from) to plant a real two-instruction increment
loop at `RESET_PC` instead of the illegal-instruction-trap-forever pattern
every earlier stage uses, since that pattern never writes a GPR and would
have let a no-op Abstract Command pass silently.

**Single-step is real too, and turned out simpler than the plan that shipped
the rest of this feared.** The worry was a race: wait for `instret_retire` to
decide when to re-halt, and by the time it fires several more instructions
could already be admitted behind the stepped one. The design that shipped
sidesteps that instead of solving it - it blocks admission again the instant
the one instruction is admitted (`dbg_step_admitted_r`, latched off the exact
same condition the ordinary admission path uses, one cycle after resume),
not when it retires, so a second instruction is never admitted in the first
place rather than being caught after the fact. `dcsr.step` is a real,
writable bit now (previously hardwired 0); writing it and then resuming
walks exactly one instruction and re-halts with `dcsr.cause` = 4 (step), not
3 (haltreq). `dcsr`/`dpc` gained real write paths as part of this - previously
a write to either reported `cmderr` = success over DMI while silently
changing nothing, because `rtl/cpu_core.v`'s debug-register mux only ever
wired up GPR writes. `sim/tb_cpu_halt.v` proves the mechanism precisely:
two single-steps around the 2-instruction test loop always execute the
`addi` exactly once and land `dpc` back where it started, whichever of the
loop's two instructions it started on - so the test does not need to know or
assume which instruction was next. `sim/tb_jtag.v`'s stage 9 proves the same
capability reaches over the real DMI wire, with `dm.v` needing zero changes
to carry it (Abstract Command already forwarded any `regno` generically).

**Fix the timing margin first** still applies to anything beyond this - any
FPGA timing/board claim for this path remains gated on Phase 3's unfinished
business, same as before. Nothing in halt, resume, register access, or
single-step touches the timing-critical fetch-redirect path at all; that is
what makes all four of them safe to ship before that margin is fixed.

Also missing, and cheaper: no debug adapter has been connected to a board.
The path is proven in simulation only.

**Re-measured 2026-08-31/09-01, all six seeds, same toolchain as
2026-08-26: 23.01-25.14 MHz, 1 of 6 closes.** This is the first synthesis
run since PR #79 added `dbg_halt_admit_block` to `pc_freeze`, and it is
close enough to the 2026-08-26 numbers (23.43-25.96 MHz, 1 of 3 sampled) to
call no regression, though stated as "indistinguishable from the
already-documented seed-to-seed noise" rather than "unchanged" - this
round's floor and ceiling both read a little lower. The critical-path shape
split inverted: four of six seeds are `dc_tag`-sourced and two are
`pc`-sourced now, against four-`pc`/two-`dc_tag` on 2026-08-24 - which
means a fetch pipeline stage would today move a smaller fraction of seeds
than this section's own arithmetic assumed when it was written. Investigated
and ruled out: extending #49's peripheral-ack registration to `wb_gpio.v`
and `wb_spi.v`, the two slaves still acking combinationally - neither
appears anywhere in the actual critical path of any of the six seeds.
`fpga/README.md`'s "A sixth attempt" has the full measurement, the ruled-out
avenue, and the D-cache-hit-path pipeline stage now named as the candidate
that would actually touch the now-dominant shape. No RTL changed.

**That candidate has a measured cost now, and it is not small.** CoreMark on
`CORE=inorder` hits the D-cache 96.3% of the time (59,457 of 61,759
accesses); the naive version of a two-cycle D-cache - every load waits for
an ack, hit or miss alike - costs one extra cycle per hit, **13.1% more
total cycles**. That is a real throughput cost on the common case, unlike
every timing fix actually shipped so far, which cost nothing measurable on
a cold path. `rtl/cpu_core.v`'s existing `load_use_stall` hazard check may
make a *latency-only* version cheaper - stalling only when the very next
instruction actually uses the loaded value, rather than on every load - but
that number is not measured, and building it is a materially bigger and
riskier change than a wait state. Not attempted; `fpga/README.md`'s "What a
D-cache hit pipeline stage would actually cost" has the full arithmetic and
names it as a real tradeoff (throughput vs. FPGA timing margin) rather than
a technical question with one right answer.

**Built, on explicit direction to proceed - functionally correct, costs
more than estimated, and does not close the margin by itself.**
`rtl/soc/cpu_wb.v` now takes one decode cycle before either a hit or a
miss proceeds, uniformly, so `dbus_wait` no longer reads `dc_present` on
the cycle a request starts. `make verify`/`make verify_ooo` both pass in
full, both cores, including 84/84 co-simulation traces against Spike each.
Cost: **16.6%**, not the earlier 13.1% estimate - CoreMark's cycle count
rose by exactly the total number of D-bus accesses (loads, stores and
uncached requests together), not just load hits, because the fix removes
`dc_present` from the critical path for misses and stores too, not only
hits. What it bought: `dc_tag` is gone from the critical path on every one
of 22 seeds tried (`CORE=inorder BOARD=ulx3s85`, 6 then 16 more) - the
mechanism works exactly as reasoned. What it did not buy: **zero of the 22
close 25 MHz** (best: 24.66 MHz) - the `pc`-sourced shape, previously the
minority contributor, is now the only one, and on its own it is not enough.
`fpga/README.md`'s "A seventh attempt" has the full measurement and names
this as the converse of the "What this means for the prescribed fix"
arithmetic from years earlier: closing this margin needs both the fetch
side and the data side, not either alone. Left on a branch, not merged -
whether a real ~16.6% cost is worth paying for a change that does not
close the margin *by itself* is a decision this project's own practice
keeps outside an autopilot round, same as the decision to attempt this fix
at all was.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

The debug module has not been shown driving a real board in this phase's own text; the timing closure of the primary board target is the standing hardware issue. Measured routing: `BOARD=ulx3s85` closed on seed 3 of 6 at 25.96 MHz on 2026-08-26, after failing all six seeds on 2026-08-24, and the critical-path attempts since are recorded above, including one left unmerged. PLIC interrupt delivery on hardware was never proved by a bare-metal test on this design.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

`make sim_jtag` drives the four pins as an adapter would and is in `make verify`, `make sim_cpu_halt` covers halt and resume, and `formal/fv_interconnect.v` proves the arbitration with the debug module as the fourth master.
