# Phase 8 — Network-on-Chip interconnect

**Stage 0 is closed (Parts 1 to 4 below, with the maintainer's confirmation of its
decision: no network yet); Stage 1 onward is a plan, not an account, and nothing about any of it is blocked on a
board.** `rtl/soc/wb_interconnect.v` is a real,
existing file this project can measure and extend today. `wb_interconnect.v` is a shared
Wishbone B4 bus with priority arbitration, already parameterized for
`NUM_HARTS` (Phase 13's own real 2-hart configuration proves it), with a
growing list of real masters (per-hart fetch/data, the page-table walkers,
the debug module, the NPU's own DMA port) and slaves (ROM, RAM, SDRAM,
every peripheral). It is simple, has real formally-proved properties
(`formal/fv_interconnect.v`), and boots Linux SMP today - real strengths
this plan does not propose discarding lightly. Its real limit is a single
shared bus: contention grows quickly past 2-4 masters, and there is no
spatial locality or parallel transactions the way a real network fabric
would provide. A full NoC is judged worth building mainly once this project
targets 4 or more harts, several accelerators at once, or DDR alongside
multiple high-bandwidth DMA masters - not before: at 1-2 cores with modest
accelerators, or when the measured bottleneck is memory latency or core IPC
rather than interconnect contention, the current bus stays the right
choice, the same "don't build what the measurement doesn't justify" standard
this file already holds every other phase to.

**Stage 0 - measure the current bus before designing its replacement.**
Real numbers under real multi-master load - Linux SMP running, the NPU's own
DMA active alongside CPU traffic, multi-hart atomics contending - come
first, not a topology chosen from intuition. This stage also writes down
the real requirements a NoC would have to satisfy (target scale, whether
latency or bandwidth matters more, what LR/SC and any future cache coherence
need from the network, and this board's own real FPGA resource budget - the
85F is constrained) and picks a topology on that basis: a lightweight mesh
or ring with Wishbone-compatible network interfaces is the plan's own
starting recommendation, keeping existing masters and slaves close to
unchanged, with a small crossbar or an AXI-based fabric named as real
alternatives if the measurements point that way instead. **Done when:** a
written decision, backed by real baseline numbers measured on the current
bus under real multi-master stress, not assumed from its own known
shared-bus limits.

**Update, Part 1: the first measurements of the shared bus, under two-hart
CoreMark.** `sim/bus_monitor.v` is a passive observer of
`rtl/soc/wb_interconnect.v`: it reads each master's request and grant and the
slave strobes, drives nothing, and is not part of any synthesised design. Per
master it counts cycles asked, granted, and asked-but-held-by-someone-else
(waited); overall it counts cycles the bus was in use, and in use while a
master waited. It is attached to `sim/tb_bench.v` (one hart, `make coremark`)
and `sim/tb_soc_2hart_coremark.v` (two harts running separate CoreMark images
at once, `make sim_soc_2hart_coremark`); both validate the CoreMark CRC. No RTL
changed. All numbers are simulation cycles.

| | Cycles (whole run) | Bus in use | In use with a master waiting | Fetch waited / asked | Data waited / asked |
|---|---|---|---|---|---|
| 1 hart, in-order | 529,414 | 19.9% | 0.45% | 0% | 4.6% |
| 1 hart, wide | 461,382 | 23.3% | 2.4% | 12.2% | 5.4% |
| 2 harts, in-order + in-order | 727,564 | 67.0% | 19.6% | 39.9% / 40.8% | 17.4% / 17.4% |
| 2 harts, wide + wide | 673,368 | 78.5% | 35.0% | 58.2% / 54.6% | 25.0% / 20.2% |
| 2 harts, in-order + wide | 696,894 | 71.6% | 27.2% | 23.9% / 57.5% | 13.6% / 32.4% |

Time a hart spent waiting for the bus, as a share of the run: 0.45% (one
in-order hart), 2.4% (one wide hart), 10.0% and 11.2% (two in-order harts), 20.5%
and 18.8% (two wide harts). CoreMark's own cycle count per hart rose from
419,621 (one in-order hart) to 502,529 and 534,774 (+19.8%, +27.4%), and from
360,481 (one wide hart) to 440,467 and 470,994 (+22.2%, +30.7%).

Two things stand out. **The bus is already contended at two harts**: a master
is waiting in 20 to 35% of all cycles, against under 3% with one hart. And
**about 96% of the cycles the bus is busy are accesses to one slave, the block
RAM** (468,030 of 487,552 in-order; 503,760 of 528,424 wide; 478,122 of 498,683
mixed); the UART is the only other slave with real traffic (about 2%).

What this does and does not show. It is measured that two harts contend and
that the traffic goes almost entirely to one slave. It is an inference, not a
measurement, that a crossbar or network would not help much here: they let
traffic to *different* slaves proceed in parallel, and nearly all of this goes
to one single-port RAM, so the queue would move rather than vanish. It is also
not isolated (Part 2 below does) how much of the +20 to +30% is bus contention
and how much is the second effect in this configuration: with more than one hart the data cache is
bypassed (`HART_DCACHE_ENABLE` in `rtl/soc/soc_top.v`, because nothing snoops
it), which by itself raises bus demand. One in-order hart with its data cache
uses 19.9% of bus cycles; two harts without it use 33.5% each. A one-hart run
with the data cache off is the comparison that separates the two, and has not
been done. Extrapolating the 33.5% per hart, a third in-order hart would ask
for more than the bus has; that is arithmetic on one workload, not a
measurement.

**This does not close Stage 0.** Its "Done when" asks for a written decision
backed by baselines under real multi-master stress, and the plan names Linux
SMP running and the NPU's DMA racing CPU traffic. Neither has been measured:
the NPU DMA checks in `software/soc/main.c` run alone, and no Linux run has the
monitor attached. The reading so far is only a direction to test: the measured
bottleneck is one RAM slave plus the cache-bypass cost of having two harts, so
the cheaper things to try first are a second RAM port or banking, and a
coherent data cache, before a network.

**Update, Part 2: the cache-bypass confounder, separated.** Part 1 could not
say how much of the two-hart slowdown was the second hart and how much was the
data cache every multi-hart build has to switch off. `make coremark_nodcache`
runs the same single-hart CoreMark with the data cache disabled by `defparam`
in the testbench (`sim/tb_bench.v`, `-DNO_DCACHE`), so there is no RTL change
and one hart can be compared with two on equal terms. CoreMark validates on both
cores.

| One hart | CoreMark cycles | Bus in use | In use with a master waiting |
|---|---|---|---|
| in-order, data cache on | 419,621 | 19.9% | 0.45% |
| in-order, data cache off | 474,504 | 37.9% | 0.96% |
| wide, data cache on | 360,481 | 23.3% | 2.4% |
| wide, data cache off | 397,216 | 46.5% | 4.8% |

Taking Part 1's two-hart CoreMark cycles (in-order 502,529 and 534,774; wide
440,467 and 470,994) against these:

| | Total slowdown, one hart with cache to two harts | Of which, losing the data cache | Of which, the second hart |
|---|---|---|---|
| in-order | +19.8% and +27.4% | +13.1% | +5.9% and +12.7% |
| wide | +22.2% and +30.7% | +10.2% | +10.9% and +18.6% |

(The factors multiply: 1.131 x 1.059 is the 1.198 above.) So **roughly half to
two thirds of the two-hart slowdown is the data cache being off, not the second
hart.** The cache bypass also **about doubles the bus traffic of a single hart**
(19.9% to 37.9% of bus cycles in-order, 23.3% to 46.5% wide), which is where
most of the 67% to 78% bus use with two harts comes from. The contention
between harts is real but smaller than Part 1 suggested: a master is waiting in
20 to 35% of cycles with two harts, against 1 to 5% with one hart and no cache,
about twenty times as much in-order.

This sharpens the reading, and still only points a direction. Measured: the
second hart costs 6 to 19% on this workload, and turning the data cache off
costs 10 to 13% and doubles bus traffic. Inference, not measured: a coherent
data cache would roughly halve each hart's bus demand, and if so the shared bus
would saturate at about five harts instead of about three (arithmetic on 19.9%
and 37.9% per hart, ignoring the slowdown feedback). Either way the evidence so
far argues for fixing coherence and the single RAM port before building a
network, and does not yet show a case for the network. Stage 0 is still not
closed: Linux SMP and the NPU's DMA are not measured.

**Update, Part 3: the NPU's DMA master racing a CPU loop.** Stage 0 names this
load and the earlier parts did not generate it: the NPU DMA checks in
`software/soc/main.c` run the NPU alone. `software/soc/npuload.c`
(`make sim_npuload`, and `make sim_npuload_nodcache` with the data cache off as
every multi-hart build has it) times a CPU loop that re-reads a 1 KB buffer and
one 32768-element NPU DMA job over static RAM, first each alone, then together,
with `sim/bus_monitor.v` reporting each phase through a GPIO marker
(`sim/tb_ramboot.v` with `-DBUS_MONITOR`; without the define the preprocessed
testbench is unchanged, so no other test sees it). The NPU result and the CPU
checksum are checked in all three phases. Single hart, simulation cycles.

| | CPU loop alone | CPU loop, NPU running | Bus in use | A master waiting | NPU bus-request cycles per grant |
|---|---|---|---|---|---|
| in-order, data cache on | 115,084 | 115,101 (+0.015%) | 28.5% | 0.00% | 1.000 |
| in-order, data cache off | 131,468 | 131,484 (+0.012%) | 49.9% | 0.05% | 1.002 |
| wide, data cache on | 98,894 | 98,907 (+0.013%) | 33.4% | 0.05% | 1.001 |
| wide, data cache off | 98,894 | 98,954 (+0.06%) | 66.4% | 16.2% | 1.247 |

The NPU job alone takes about 66,200 cycles and holds the bus on every other
cycle (32,768 granted bus cycles). The NPU sits lowest in the arbitration
order by design, and it shows: the CPU barely notices it, and where there is
contention the NPU absorbs it. Only the last row has any: with the wide core's
loads all going to the bus, the two together ask for two thirds of the bus,
the CPU's data master waits in 19.5% of its requests (it cannot pre-empt a
transfer already under way) and the NPU job needs 40,867 request cycles to do
32,768 cycles of work, about a quarter longer. The wide core hides the delay
(+0.06%); the in-order core would not, but its combined load never reached
that level here.

Putting the three parts together, the measured pattern is that waiting stays
negligible up to about half the bus in use (0.00 to 0.05% at 28 to 50%) and
rises steeply at about two thirds (16 to 20% waiting at 66 to 67%, in both the
NPU and the two-hart runs). That is one workload per point, a rule of thumb
and not a model, but it is consistent across three different loads.

**Not yet measured, so Stage 0 is still not closed: Linux SMP.** No Linux run
has the monitor attached. Until it does, the reading stays a direction and not
the written decision the "Done when" asks for: the shared bus is a real limit
at two cache-less harts or a cache-less wide hart plus the NPU, the traffic is
almost all to one RAM, and the cheaper fixes to try before a network are a
second RAM port or banking and a coherent data cache.

**Update, Part 4: the shared bus under Linux, one hart and two, and what
Stage 0 now says.** The monitor is ported into the Verilator harness
(`sim/verilator_soc.cpp`, `+busmon`, and `+busmon_every=N` for a line per
window) so a boot can be measured at Verilator speed. `make busmon_check` runs
the SDRAM boot under both Icarus and Verilator and requires the two monitors to
agree; they agree to three decimal places on every counter (cycle counts one
apart). The runs are `make sim_linux` and `make sim_linux_2hart` with
`SIM_EXTRA='+busmon +busmon_every=25000000'`, to the userspace marker, both
cores. Simulation cycles, ULX3S-style SDR SDRAM model.

| | Cycles to userspace | Bus in use | A master waiting | SDRAM's share of busy cycles |
|---|---|---|---|---|
| 1 hart, in-order | 226.5 M | 89.7% | 12.6% | 99.5% |
| 1 hart, wide | 226.0 M | 91.3% | 37.3% | 99.5% |
| 2 harts, in-order | 286.2 M (+26%) | 99.6% | 87.2% | 99.8% |
| 2 harts, wide | 312.5 M (+38%) | 99.7% | 89.7% | 99.8% |

Contention grows through the boot: the share of cycles with a master waiting
rises from 5.9% to 16% (one in-order hart), 22% to 47% (one wide hart), 69% to
97% (two in-order harts) and 73% to 98% (two wide harts), first window to last.
With two harts, hart 1's instruction fetch is granted 17.6 M of the 159.6 M
cycles it asks for (11%; it waits in 89% of its requests, 91% on the wide core),
while hart 0's fetch waits in 33 to 43%. That is the arbiter's fixed priority at
work (the lower hart index wins), and it is a fairness cost, not a deadlock:
both harts reach userspace.

What the numbers support. **The shared bus is the limit for Linux SMP**: two
harts keep it busy on 99.6 to 99.7% of cycles and one hart already uses about
90%. This also contradicts the opening of this phase, which expected the
current bus to be the right choice at one or two cores with modest
accelerators; at two harts running Linux it is saturated. **But almost all of
that traffic is to one slave**: 99.5 to 99.8% of busy cycles are the SDRAM's
strobe (and 95 to 96% were the RAM's under CoreMark in Parts 1 and 2). "Bus in use"
is occupancy, not bandwidth: the classic bus is held for the whole of each
access, including the SDRAM's own latency, so a saturated bus here mostly
means a saturated memory.

What follows from that is an inference, and is labelled as one. A network gives
parallel paths between different endpoints. This workload has one endpoint, so
a faster fabric would move the queue and not remove it; the levers the data
points at are less traffic (a coherent data cache: Part 2 showed that losing the
cache roughly doubles a hart's bus demand, which suggests, but does not
show, that a coherent one would roughly halve it), more memory bandwidth (the DDR3 of Phase 9, or a
second RAM port or banking), fairer arbitration, and overlapping memory latency
with several requests in flight. That last one is the one thing a network or a
pipelined bus could offer here, and whether the SDRAM controller could use it
has not been measured.

**Stage 0, written down.** Measured across Parts 1 to 4: two harts already
contend heavily under every load tried (CoreMark, an NPU DMA job, Linux), the
contention knee sits at about two thirds of the bus in use, and in every
workload 95 to 99.8% of the traffic goes to a single memory slave. The decision
this supports is **not to start Stage 1** (the network interface), and instead to
work the levers above, in the order of what each would remove: coherent data
cache first, then memory bandwidth, then arbitration fairness. Revisit when
there are several memory endpoints, or accelerators with high-bandwidth DMA to
different slaves, which is also this phase's own stated trigger. That is a
decision about whether a phase gets built, so it is the maintainer's to confirm;
until they do, Stage 0's "Done when" (a written decision backed by baselines
measured under real multi-master stress) is met in content and not marked
closed, and Stages 1 to 5 stay a plan.

**Update: confirmed, Stage 0 closed.** The maintainer confirmed this decision
on 2026-10-03: do not start Stage 1, and work the levers above in the order
given. Stage 0's "Done when" is met and closed, in simulation, at this scale.
Stages 1 to 5 remain a plan, now explicitly behind the trigger above (several
memory endpoints, or high-bandwidth DMA to different slaves). The levers
themselves are not yet started; the first is a coherent data cache.

**Stage 1 - a network interface and a real packet format.** The boundary
between today's Wishbone masters/slaves and tomorrow's network: a real
packet format (address, data, command, source/destination ID, and room for
a QoS tag), and real Wishbone-to-NoC network interfaces on both the master
and slave side. The existing single-bus behavior stays expressible as a
degenerate one-node network, and LR/SC/AMO semantics have to survive
crossing this new boundary intact - a real, non-negotiable requirement
given Phase 13's own hard-won cross-hart atomicity work. **Done when:** a
real master reaches a real slave through these network interfaces with the
same functional behavior the bus provides today, proven by directed tests
covering round-trip correctness, per-master ordering, and real back-pressure
- formal properties where the design admits them, the same bar every
controller in this tree is already held to.

**Stage 2 - the smallest router that could replace the bus.** A real router
(wormhole or virtual-cut-through, 2-5 ports) in the smallest topology that
says anything real - a 2x2 mesh, a small crossbar, or a ring, whichever
Stage 0's own measurements favor - carrying a real first configuration: two
harts, memory, and one accelerator. The classic `wb_interconnect.v` stays
selectable throughout, so every existing test keeps passing against it
while the new path is proven separately. **Done when:** that same
`NUM_HARTS=2` configuration runs correctly over the NoC in simulation,
Linux SMP still reaches userspace on it, and real latency/bandwidth/area
numbers are recorded against the classic bus, not estimated.

**Stage 3 - scaling past the minimal case.** Real growth to four or more
nodes, a real quality-of-service mechanism (priority, virtual channels, or
simple traffic classes) so bulk DMA cannot starve CPU fetch traffic, and a
real check that the reservation monitor and any future coherence traffic
still work correctly once real routing sits between the harts and the bus.
Multiple real memory endpoints (on-chip RAM alongside SDRAM or a future DDR
path) need sensible routing too. **Done when:** a measured improvement (or
an honestly-recorded, acceptable trade-off) under real multi-master
workloads - concurrent multi-hart Linux, NPU DMA racing CPU traffic, real
interrupt traffic - with zero regression anywhere in the existing
verification suite.

**Stage 4 - software should not need to know.** Device tree and memory-map
updates if node IDs or address decoding change, OpenSBI and Linux SMP
booting unchanged (or with configuration differences only, not code
changes), and optionally, real performance counters (packets, stalls,
contention) exposed through CSRs or MMIO so the numbers above stop being a
one-time measurement and become something software can watch continuously.
**Done when:** a full Linux boot, single- and multi-hart, works on the NoC
configuration with a real transcript and real performance numbers recorded,
the same standard Phase 5's own OpenSBI/Linux work already set.

**Stage 5 - real hardware, and a build-time choice that keeps both paths
alive.** Timing closed on a real target (ULX3S today, ECPIX-5 once Phase 9
gets there), router buffering and pipeline stages tuned for the ECP5's own
real resources, and a real, permanent build switch - `INTERCONNECT=bus` for
the classic path (the default for small configurations), `INTERCONNECT=noc`
for the new one - rather than a one-way migration that leaves smaller
configurations paying a NoC's own real area cost for no real benefit.
Adaptive routing, better topologies, or cache-coherence extensions are named
here as real later work, not committed to. **Done when:** the NoC
configuration builds and runs on real hardware, both build paths stay
stable, and every claim about it follows this project's own measured, not
estimated, standard.

**What decides whether any of this actually gets built.** Stage 0's own
measurement is the real gate, not a schedule: this plan is worth pursuing
once real contention under 4+ harts or several high-bandwidth accelerators
actually shows up in that measurement, and not before - matching every
other "don't build what the numbers don't justify" judgment this file
already makes elsewhere (Phase 1's own honest CoreMark result being the
closest precedent: a real design built, real numbers measured, and the
measurement itself deciding what came next rather than the plan's own
initial expectation).

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

Not started: nothing here has been run on a board. Stage 5 (timing closed on a real target, a build-time choice that keeps both interconnects) is the hardware stage.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Stage 0 has begun: `sim/bus_monitor.v` measures the existing shared bus, and Parts 1 to 4 record it under one- and two-hart CoreMark, with and without the data cache, under an NPU DMA job racing a CPU loop, and under one- and two-hart Linux boots. The written Stage 0 decision is in Part 4 and the maintainer confirmed it on 2026-10-03: no network yet, work the levers instead. Stage 0 is closed. Stages 1 onward are a plan.
