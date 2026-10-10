# Roadmap

Phases, ordered by what each one unblocks rather than by how interesting it is,
with one exception: Phase 1 is ordered first because it is a redesign of the
machine every later phase builds on, and is cheaper to do before they widen the
surface it has to preserve.
Each phase states what is already true, so the gap between "done" and "next" is
visible rather than implied — the same standard `fpga/README.md` applies to
hardware claims.

Nothing here is a schedule. This is a single-maintainer project and the phases
are dependency order, not dates.

This file is the index. Each phase has its own file in this folder, and each phase file ends with three sections:

- **Known defects**: open and resolved defects that belong to that phase.
- **Hardware**: what has run on a physical board, and what has not.
- **Software**: what has been shown in simulation or by formal proof.

Defects that are not tied to one phase are in [Common known defects](#common-known-defects) below.

## Phases

| Phase | Title | Where it stands |
|---|---|---|
| 0 | [Proven on silicon](phase-00-proven-on-silicon.md) | The in-order core, SoC and acceptance test running on a ULX3S at 25 MHz. Done. |
| 1 | [Superscalar issue and out-of-order execution](phase-01-superscalar-ooo.md) | `rtl/ooo/core_ooo.v`, a second core with the same ports as `cpu_core.v`. Built and green in simulation; never run on a board. |
| 2 | [Break the memory ceiling](phase-02-memory-ceiling.md) | SDRAM controller and loader, past 64 KB of block RAM. Done, on silicon. |
| 3 | [Make it fast enough to be interesting](phase-03-performance.md) | Instruction and data caches, measured in CoreMark cycles. |
| 4 | [Video out](phase-04-video-out.md) | Framebuffer to a monitor over GPDI. Built and routed; nothing has driven a real monitor yet. |
| 5 | [Run software this project did not write](phase-05-third-party-software.md) | OpenSBI and Linux. Booted to userspace on a ULX3S. |
| 6 | [Debug infrastructure](phase-06-debug.md) | JTAG, debug transport and system bus access. Half done; timing margin on the primary board is the gating issue. |
| 7 | [Close the boot path](phase-07-boot-path.md) | Boot from an SD card. Open; the SD card has never answered on hardware. |
| 8 | [Network-on-Chip interconnect](phase-08-noc.md) | Stage 0 closed: measured under CoreMark, an NPU DMA job and Linux SMP, two harts saturate the bus, almost all of it to one memory. Decision, confirmed by the maintainer: no network yet; work the levers first. The first, a snooping data cache, is built and cuts two-hart CoreMark by 11 to 13% and its bus use from 67 and 78% to 45 and 52%, and, once it also covered the SDRAM window (Part 6), cuts the two-hart Linux boot by 41 to 47% and leaves the second hart costing about 7% instead of 67%; the bus is still 93 to 94% busy, and most of it is now instruction fetch: a 1024-word instruction cache would cut the boot another 16% but costs 27% more LUTs and 3 MHz, so the next lever was a different instruction-side design, not a bigger cache. That is now built (Parts 8 to 11): 87–90% of instruction-cache misses are the next sequential word, so the SDRAM controller streams a four-word burst, the interconnect holds the bus for it, and the instruction cache fetches a line; Linux boots to userspace 21% (one in-order hart), 19% (one wide) and 28% (two wide) shorter, but the two in-order harts 6% longer, with the bus still about 93% busy. Part 12 measured what the harts do and tried inverting the arbiter's priority: it does not help, so arbitration is not the lever and the saturated bus is. What remains: the data side's stores (two thirds to four fifths of its bus time; a data-side line fill was measured in Part 13 and is not worth building, so a store buffer is the candidate, a larger design decision), a larger cache, and DDR3. Stage 1 has begun at the maintainer's request (Parts 15 to 20, Stage 1 met in simulation): packet-based network interfaces with a four-word burst, a one-node network, and a drop-in fabric that matches the bus on random traffic and now runs the whole SoC verification suite and Linux (`make INTERCONNECT=noc`), on both cores and with two harts, at a measured 16 to 41% more cycles. The rest is a plan. Stage 2 has been built at the maintainer's request (Parts 21 to 23): a packet router with a crossbar, proved formally; a fabric built on routers that matches the bus on random traffic; and the SoC, Linux included, on both cores and with two harts, over it (`make INTERCONNECT=xbar`). Measured: 22 to 25% more cycles than the bus with one hart, 20 to 67% with two, so the bus wins on this SoC, as Stage 0's one-memory finding predicted. Stage 3 has begun (Parts 24 and 25): the router honours traffic classes with an aging bound, proved and tested, off by default; and the NPU's DMA racing a hart, measured: with two memories the router fabric isolates them completely where the bus lets the NPU slow the CPU 11.7%, but its longer latency (44% on a cache-missing loop) costs more than the isolation saves, so the bus is still faster. Part 26: dual-hart CoreMark with the harts in one memory and in two: the router fabric is 41 to 46% slower per iteration when they share a memory and 14 to 17% slower when they do not (and moving a hart to SDRAM makes hart 0 10% faster on the fabric but slower on the bus), the data caches' late-ack guard costs nothing measurable, and the bus is still ahead. Part 27: two harts streaming through memory, the first workload to keep the bus busy: with the arrays in two memories the router fabric isolates the harts completely (each at its rate alone) where the bus lets an SDRAM stream pull a block-RAM stream down to 0.45, but it adds 4.0 cycles to every word read, so the pair is 3% slower (10% on the out-of-order core), by arithmetic about a third of a cycle (a cycle) from break-even. Part 28: the four cycles measured stage by stage and half of them cut by an opt-in bypass in the slave interface (off by default, proved): two harts streaming from two memories now read 22% faster than on the bus (16% on the out-of-order core), the in-order two-hart Linux boot takes 2.9% fewer cycles, and everything else is still behind (CoreMark 2 to 20% per iteration, the wide pair's boot 36%); an estimated 3.5% more LUTs and two more logic levels, not a timing figure. Part 29: the fabric's area, measured by place-and-route for the first time: 74,133 LUTs in a one-hart SoC (88% of an 85F, 119% more than the bus), nearly all in two routers whose FIFOs are one flat array (per-input arrays cut the response router 89% in an experiment), so it did not finish routing and had no Fmax; and a logic-free edit moves the bus build's Fmax by 1.4 MHz, so differences of about 2 MHz between netlists are not attributable. Part 30: each router input's FIFO in an array of its own, held equal to the original by a formal equivalence proof, takes the fabric to 41,439 LUTs (49% of an 85F, +7,629 over the bus) with an Fmax in step with the bus's (20.2 MHz mean over six seeds against 18.1, inside the netlist noise; the CPU's chain is the critical path). Part 31: interrupt traffic, the last workload in Stage 3's Done-when: a periodic timer interrupt through the PLIC costs 86 cycles on the bus, 173 on the router fabric and 129 with the bypass (the fabric's 4.0 cycles, 2.0 with the bypass, on each of the 21.8 accesses an interrupt makes), and with the NPU's DMA racing from SDRAM the bus's cost rises 74% while the fabric's does not move, so the bypassed fabric then costs 13% less than the bus. Part 32: the same on two harts, with hart 1 streaming SDRAM beside the interrupt: the bus's cost rises 61% (82% on the wide core), the fabric's does not move, and the bypassed fabric costs 8% less than the bus (27% less on the wide core). The rest is a plan. |
| 9 | [DDR](phase-09-ddr.md) | A hand-written DDR3 PHY and controller for the ECPIX-5. Stage 2's "Done when" is closed in simulation, at this scale; the phase's own bar (Linux from DDR3 on a real ECPIX-5) is not met, and no real DDR3 chip has seen it. |
| 10 | [GPU](phase-10-gpu.md) | A 2D fill, copy and line engine in the framebuffer. Stages 1 to 3 shipped in simulation. |
| 11 | [DSP](phase-11-dsp.md) | A fixed-point FIR peripheral. Done in simulation. |
| 12 | [Peripheral interfaces (I2C, timers, PWM)](phase-12-peripherals.md) | Timer and PWM done in simulation; I2C not started. |
| 13 | [Multi-core: both cores, one SoC](phase-13-multicore.md) | Two harts, cross-hart atomics, SMP Linux. Done in simulation for both cores. |
| 14 | [Neural processing (quantized inference)](phase-14-npu.md) | An NPU peripheral with DMA. Done in simulation. |
| 15 | [Heterogeneous multi-core](phase-15-heterogeneous.md) | Both core types in one SoC (`CORE=hetero`). Done in simulation. |

Work that sits outside the phase order is in [Beyond the phases](beyond-the-phases.md).

## Common known defects

Open, unscheduled, and written down so they are not rediscovered. These entries cut across phases (the verification flow, the simulators and CI); defects that belong to one phase are in that phase's file.

**HEAD no longer closes 25 MHz, and real-scale synthesis no longer finishes.**
Measured 2026-10-02 while bumping the synthesis bundle, and not attributed.
At current HEAD, with the framebuffer shrunk to 8x8, no placement seed of
either oss-cad-suite bundle closes 25 MHz (17.4 to 19.1 MHz); the same method
on the 2026-08-26 commit `efee7bf` gave 23.8 to 24.3 MHz, so the drop is in the
RTL since then, not the toolchain. The critical path is routing-dominated
(11.78 ns logic, 40.52 ns routing) from the `ex_mem_rd` forwarding register
through the MMU address adder to the CSR file. Separately, full-scale
(320x240) synthesis does not finish within an hour: Yosys is converting
`wb_framebuffer.v` memories to registers. Bisected on 2026-10-03: the drop falls between 2026-09-03 and
2026-09-20 but the window is cannot be built on this bundle (Yosys aborts or
stalls), and the PMP accounts for about 13,000 of the 19,000 LUTs added.
The PMP match was then rewritten in word space (proved equal to the original):
33,218 LUTs and +1.67 MHz on average over six seeds, still short of 25 MHz.
After that, the critical path is one combinational chain: execute-stage
address, instruction-side MMU, I-cache tag compare, the memory stall network.
Shortening it means registering part of that chain, a pipeline-timing
decision for the maintainer. The area growth in the NPU, `csr_file` and
framebuffer is the other lever. The full account is in [fpga/README.md](../../fpga/README.md#re-measured-2026-10-02-the-bundle-bump-and-a-regression-it-did-not-cause).

**The intermittent `ISA-TIMEOUT` under `make verify`.** Still undiagnosed -
this update adds evidence, not a cause, and is not claiming otherwise; that
distinction is the whole reason [practices.md](../practices.md) §7 uses this
exact entry as its running example of a self-reporting workaround that is
not a fix.

The original investigation (commit `c60699b`, before `CORE=ooo` existed as a
target at all) ran 4 full passes of the suite - one standalone plus three in
a loop, 328 test executions - and found the suite fully deterministic:
byte-identical results every time, no timeout. This round ran the same
experiment at roughly 100x that scale and on the core that did not exist
yet when it was first written down: 200 passes each, `CORE=inorder` and
`CORE=ooo`, 32,400 total test executions, still zero occurrences and still
byte-identical within each core. `$random`/`$urandom` do not appear
anywhere in the RTL or in `sim/tb_isa.v`, so a fixed simulator binary
running a fixed program has no internal source of run-to-run variation to
begin with - which is consistent with both investigations seeing none.

One genuinely new lead, not a conclusion: `docs/toolchain.md` recorded this
machine's Homebrew `icarus-verilog` as `14.0 (devel)` and it is now `12.0
(stable)` - confirmed drifted, not measured wrong, since Verilator's
recorded version matches the installed one exactly and only Icarus's does
not (`docs/toolchain.md` §3 and §10 have the correction and the reasoning).
That is the same class of mechanism the resolved sdramboot
`verilator_check` discrepancy bisected to just above - "same commit, same
RTL, different result" is only explicable by something outside the repo,
and a Homebrew formula moving underneath a long-lived project is exactly
that. It is offered here as a plausible contributing explanation for why
two occurrences years apart have never recurred on demand, not as proof:
unlike the SDRAM case, there is no historical commit to check this
regression against, so this cannot be bisected the same way. If it recurs,
`iverilog -V` against `docs/toolchain.md` is worth checking before assuming
the RTL is at fault.

**Update: another ~5x on the historically relevant core, still zero -
and one new hypothesis investigated and its simplest form ruled out.**
The two actual historical occurrences both predate `CORE=ooo` as a target,
so `CORE=inorder` is where a reproduction would matter most. This round ran
2,000 full passes of the suite on it alone - roughly 168,000 individual
test executions, about 5x the 32,400 total across both cores the previous
round managed - on the current toolchain (`Icarus Verilog 12.0 (stable)`,
re-checked with `iverilog -V` against `docs/toolchain.md` before starting,
matching exactly - no further drift since the correction above). Zero
timeouts, over roughly 8.5 hours of wall time.

The new hypothesis: Icarus's own documented simulation semantics allow the
relative execution order of multiple processes activated by the same event
to be implementation-defined where the language does not otherwise order
them - the general "Verilog race condition" every textbook on the subject
covers, not an Icarus-specific bug. If `cpu_core.v` had so much as one
place mixing blocking assignment into a clocked `always @(posedge clk)`
block - the classic, mechanically-detectable shape that turns this from a
theoretical hazard into a live one - a scheduler change between Icarus
versions could plausibly resolve the ambiguity differently and explain
"reproduced under an old version, never again under a newer one" without
needing `$random` anywhere, consistent with everything found so far.
Checked, not assumed: `verilator --lint-only -Wall` against `cpu_core.v`
and everything it includes reports nothing in Verilator's `BLKSEQ`
category (blocking assignment in a sequential block) at all. That rules
out the simplest, most mechanical version of this hypothesis for the one
core the historical reports actually concern - it does not rule out a
subtler variant (say, across the `posedge`-triggered blocks of
`cpu_core.v` and a testbench/harness file, rather than within one file),
which this round did not have time to chase further.

Net position unchanged from the entry above: still not reproduced, on
either the toolchain-drift explanation or this new one, and still not
claimed as resolved.


**RESOLVED - not a design defect. Bisected to a toolchain/environment
difference on the machine that first investigated it, not to any commit in
this repository.** `make verilator_check` now passes deterministically,
cycle for cycle (`2109474`/`10759`, both simulators, four consecutive runs)
on `main` - and, decisively, **also passes at the exact commit this entry
was written against** (`5a7e610`, checked out directly and re-run rather
than assumed). Icarus's own number at that commit is `2109474`, not the
`1845770` originally recorded here; nothing in `sim/sdram_model.v`,
`sim/tb_sdramboot.v`, `sim/verilator_soc.cpp`, or `rtl/soc/wb_sdram.v` has
changed since #70, well before this entry, so the RTL and testbenches at
that commit are byte-for-byte what they were when the mismatch was first
seen. Same code, same commit, different result: the only thing that can
explain that is the Icarus Verilog build the original run used, not
anything this project controls - confirming the "environment-specific to
this development machine's Icarus/Verilator versions" half of the hedge
this entry already carried, and ruling out the other half (genuine
nondeterminism) and the empirical-bisection plan below it, since there is
no design-level divergence left to bisect toward. Current environment:
Icarus Verilog 12.0 (stable), Verilator 5.050. `sim/verilator_soc.cpp`'s
`SdramModel` was not the bug `verilator_compare.py`'s own failure message
speculates it would be - it never diverged from `sim/sdram_model.v` in the
first place. Left here, struck rather than deleted, as the record of what
this entry used to say:


**`make verify_ooo`/`make verify`'s `verilator_check` step fails on
`sim_sdramboot`: Icarus and Verilator disagree on cycle count and refresh
count for the same test.** Found while gating #76 (the `CORE=ooo` Linux-boot
fix - unrelated to it, confirmed by reproducing this identically on a clean
`main` with none of that fix's changes present, a real control rather than
an assumption). `cycles 1845770 (icarus) vs 2109474 (verilator)`, `refreshes
9414 vs 10759` - Verilator takes 263,704 more cycles, roughly 14%, to reach
the same result word. Not reproduced in this project's own CI (GitHub
Actions' "SoC, firmware and traps" checks passed cleanly on #76, including
this same test) - environment-specific to this development machine's
Icarus/Verilator versions, or genuinely nondeterministic in a way CI's run
happened not to trigger; not yet distinguished. Ruled out so far by reading
`sim/sdram_model.v` against its C++ port in `sim/verilator_soc.cpp`
(`SdramModel`) line for line: the protocol FSM, timing constants, and
refresh-triggering logic (purely reactive to the real `wb_sdram.v`
controller's own command issuance in both cases - neither model decides to
refresh on its own) all match. The harness code that drives `SdramModel::edge()`
- the half-period clock-offset arithmetic modeling the SDRAM part's 180°-shifted
clock (`fpga/sdram_clk_out.v`) - also reads correctly on inspection. Closing
this needs the same kind of empirical bisection that found the AMO race in
Update 15, not more static reading: instrument both testbenches to find the
first cycle their observable state (bank state, refresh count, or the
read/write sequence itself) actually diverges, rather than only the final
tally.


**`sim/program.hex` is 440 instructions of recovered source.**
`sim/program.S` reassembles to it byte for byte and `make check-program`
holds that, but the labels are named for byte offsets because the original had
no symbol names to recover. Anyone extending the core regression will be
working with that.

**Update, Round 6: the combinational loop this entry opens with is closed -
`CORE=ooo` now has a real, if far too low, measured Fmax (8.68 MHz against
a 25 MHz target).** The account below, through Round 5, is preserved
exactly as it was written and is still the real history of how that loop
was found, chased, and eventually closed - "Round 6," further down this
same entry, has the real evidence and the current, accurate status.


**RESOLVED - `sim_uartirq`, the newlib probe (`sim_probe`), and
`sim_div64test` are now gated in CI's "SoC, firmware and traps" job, both
cores** - three named steps added directly to `.github/workflows/ci.yml`,
each its own `make sim_<target>` plus a `grep -q "RAMBOOT TEST PASSED"`
check, matching every other step in that job. Left here, struck rather than
deleted, as the record of what this entry used to say:

**And that fix changes nothing in CI, because CI does not call these
targets at all.** `.github/workflows/*.yml` never runs plain `make verify`
or `make verify_ooo` - the "SoC, firmware and traps" job reimplements a
curated, explicit list of individual steps instead, each its own `make
<target>` plus its own `grep` check written directly in the workflow file.
`grep -rn "sim_uartirq\|sim_probe\|sim_div64test" .github/workflows/`
returns nothing: all three are absent from that list, on either core, by
any path. This is not new - `.github/workflows/*.yml` already carries a
comment recording the same class of gap once before, about a different
check: "the self-checking probes... were only ever running in someone's
local `make verify`", until the device-tree-FIFO bug made that obvious and
the fix was adding a named step for it. `sim_uartirq` and `sim_probe` are
old absences, unrelated to this change. `sim_div64test` is not - it is the
regression test this same stage (Update 4/5, and the PR that shipped it)
built specifically to guard the `__div64_32` finding, and it currently
provides no protection in CI at all: a future change that broke it would
still show every check above green. Documented rather than fixed here, on
the same reasoning as the entry above it - this is a Makefile PR, and
`.github/workflows/*.yml` is deliberately not touched by it.
