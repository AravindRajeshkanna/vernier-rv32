# Phase 8 — Network-on-Chip interconnect

**Not started - everything below is a plan, not an account, and nothing
about it is blocked on a board.** `rtl/soc/wb_interconnect.v` is a real,
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

Not started. Stage 5 (timing closed on a real target, a build-time choice that keeps both interconnects) is the hardware stage; nothing has been run on a board.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Not started. Stage 0 is a measurement of the existing shared bus under real multi-master load, which is the first simulation work and has not been done.
