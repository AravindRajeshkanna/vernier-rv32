# Phase 8 — Network-on-Chip interconnect

**Stage 0 is closed (Parts 1 to 4 below, with the maintainer's confirmation of its
decision: no network yet). Stage 1 is built and its Done-when met in simulation (Parts 15 to 20: the network interfaces, a
packet format with a four-word burst, a one-node network, a drop-in fabric that runs the SoC, Linux included, on both cores and with two harts, at a measured 16 to 41% more cycles, and formal properties of the node and both interfaces);
Stage 2's Done-when is met in simulation (Parts 21 to 23: a packet router, a fabric built on routers, and the SoC and Linux, one and two harts, over it); the measured result is that the bus wins, by 16 to 67% in cycles. Stage 3 has begun (Part 24: traffic classes in the router); Stages 4 onward are a plan, not an account, and nothing about any of it is blocked on a
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
themselves are not yet started; the first is a coherent data cache (done: Part 5 below).

**Update, Part 5: the first lever, a coherent data cache, and what it does not
reach.** Each hart's data cache is write-through, so every write to memory
crosses the shared bus; `rtl/soc/wb_interconnect.v` now reports each write that
completes on it (`snoop_wr`, `snoop_adr`, and `snoop_src_d`, which hart issued
it), and `rtl/soc/cpu_wb.v` drops the line at that word's index unless the write
was its own hart's. The index alone is compared, not the tag: a different line
at the same index is dropped too, which costs a refill and saves a second read
port on the tag array. With that in place `HART_DCACHE_ENABLE` in
`rtl/soc/soc_top.v` is 1 at any `NUM_HARTS`; the bypass it forced above one hart
is gone.

The test came first. `make sim_soc_2hart_coherence` (and `_hetero`) runs
`sim/gen_soc2hart_coh.py`'s program: six words cross between two harts, three
each way, each already in the reader's cache. With the cache forced on and no
snoop it fails (hart 0 spins on a cached `done` word, read as a hit on every
poll); with the bypass it passes; with the snoop it passes on both builds.
Mutations, each run on a freshly built binary: hart 0's snoop tied low fails
three checks, hart 1's tied low fails the re-read of `Z`, a wrong snoop index
fails. One thing it does not catch: a hart also invalidating on its own writes
(a hit-rate bug, not a correctness one). The second round exists because the
first version of the program left hart 1's snoop untested: tying it low still
passed. `make verify` and `make verify_ooo` pass, `formal/run.sh
fv_interconnect` still proves, and the existing cross-hart LR/SC, AMO and
ordinary-access tests pass with the cache on.

Measured on the Part 1 workload, two harts running separate CoreMark images,
against the same tree without this change (which reproduces Part 1's numbers
exactly: 727,564 and 673,368 cycles):

| | Pair cycles | Bus in use | A master waiting | Hart 0 / hart 1 iteration |
|---|---|---|---|---|
| In-order pair, before | 727,564 | 67.0% | 19.6% | 502,529 / 534,774 |
| In-order pair, coherent cache | 644,154 (-11.5%) | 45.1% | 11.1% | 434,074 / 451,483 |
| Wide pair, before | 673,368 | 78.5% | 35.0% | 440,467 / 470,994 |
| Wide pair, coherent cache | 587,360 (-12.8%) | 52.4% | 18.2% | 373,576 / 393,182 |

A hart's CoreMark iteration is now 3.4% and 7.6% slower than one in-order hart
alone (419,621), against 19.8% and 27.4% before; for the wide core 3.6% and 9.1%
against 22.2% and 30.7% (360,481 alone). The CRCs validate on all four runs.

**What it does not reach: Linux.** The same two-hart boot, `make
sim_linux_2hart` with the Part 4 flags, on the tree with and without this
change gives identical results to the cycle (376,246,210 cycles, 99.67% of
cycles with the bus in use, 88.59% with a master waiting). The data cache only
covers block RAM and the boot ROM (`dc_cacheable` in `rtl/soc/cpu_wb.v`:
`addr[31:24]` of `0x80` or `0x00`), and Linux's memory is the SDRAM window, which
no data cache here covers. So the coherent cache helps the workloads that run
from block RAM and does nothing for the one that showed saturation (Part 6 below
extends it to SDRAM). That
changes the order of the levers: for Linux the cache would first have to cover
the SDRAM range, which is a larger and separately measured step (the cache is
256 words), and the memory-bandwidth and arbitration levers are not behind it.

**Two corrections to the account above.** Part 4's 286.2 M cycles to userspace
(two in-order harts) does not reproduce on today's tree: it is 376.2 M, with or
without this change. Something between Part 4 and now moved it (the kernel went
from 6.18.45 to 6.18.54 in the interim, among other changes), and which one has
not been isolated, so Part 4's cycle counts are history and its occupancy
percentages are the figures to compare. And the Stage 0 recommendation to do
the coherent cache first rested on Part 2's CoreMark result, which this
confirms; it did not examine whether Linux's memory is cached at all.

Not established here: the mixed in-order and wide pair under CoreMark, the
area and clock cost of the snoop path (it is one more write to a flag vector per
hart and a few gates; not synthesised), anything on a board, and a formal proof
of coherence (the evidence is directed simulation with mutations).

**Update, Part 6: the cache covers SDRAM, and Linux gets the benefit.** Part 5
found that the data cache covered only block RAM and the boot ROM, so Linux
(which runs in the SDRAM window) never touched it. The cacheable predicate in
`rtl/soc/cpu_wb.v` (`dc_cacheable`) and the snoop's matching one
(`snoop_cacheable`) now also cover `0x90` and `0x91`, the 32 MB SDRAM window; the
cache itself is unchanged (256 words, direct-mapped, write-through). That is the
whole RTL change.

The test came first again. `make sim_soc_2hart_coherence_sdram` (and
`_sdram_hetero`) is the same program with the shared words in SDRAM at
`0x9000_0200` and the SDRAM model attached; code still runs from block RAM, and
each hart mirrors what it observed into block RAM so one set of checks serves
both variants. With SDRAM uncached it passes; with SDRAM cacheable but the
snoop still limited to block RAM it fails four checks (both harts stall on a
stale cached word); with both it passes.

Two-hart and one-hart Linux boots to userspace, `+busmon` as in Part 4, against
the same tree without the change (simulation cycles, ULX3S-style SDR SDRAM
model):

| | Cycles, before | Cycles, after | Bus in use, before to after | A master waiting, before to after |
|---|---|---|---|---|
| 1 hart, in-order | 225.5 M | 186.5 M (-17.3%) | 89.7% to 81.1% | 12.5% to 8.3% |
| 1 hart, wide | 224.4 M | 184.4 M (-17.8%) | 91.3% to 83.2% | 37.2% to 24.9% |
| 2 harts, in-order | 376.2 M | 199.4 M (-47.0%) | 99.7% to 93.0% | 88.6% to 74.0% |
| 2 harts, wide | 379.2 M | 223.5 M (-41.1%) | 99.8% to 94.3% | 90.6% to 78.3% |

All four reach userspace, both harts in the two-hart runs. The second hart
now costs about 7% more cycles to boot (in-order: 199.4 M against 186.5 M)
where it cost 67% before (376.2 M against 225.5 M), and the bus is no longer
saturated, with a margin of about 6 to 7% of cycles.

What this does and does not show. **Linux's own atomics and shared kernel data
now go through a cache that has to be coherent, and the evidence is the
directed test above plus these boots, not a proof**: a boot reaching userspace
would not necessarily notice a stale line. The directed test covers plain loads
and stores across the two harts in SDRAM; cross-hart LR/SC and AMOs were at
first tested in block RAM only (`sim_soc_2hart_lrsc`, `_amoswap`), so atomics
in SDRAM rested on the boots until the follow-up after this paragraph. Reading a one-hart run's own gain (-17%) as the cost of
SDRAM latency on a hart that was never contended is an inference. Not covered:
the DDR3 window (`0xA0`) is still uncached, a cache bigger than 256 words (a
larger one would help more and costs block RAM), anything on a board, the area
and clock cost of the wider predicate. The bus is still 93 to 94% busy with two
harts, so the other two levers (memory bandwidth, arbitration fairness) remain,
though with less urgency than Part 4 showed. One measurement note: the control
run of the one-hart in-order boot printed the marker line split by a bus-monitor
window and so failed the gate's grep on it; the boot itself finished (`stopon`
seen), so it is counted here.

**Follow-up to Part 6: the atomics tests, run with the data in SDRAM.**
`sim_soc_2hart_amoswap_sdram` and `sim_soc_2hart_lrsc_sdram` (each with a
`_hetero` build) re-run the two existing programs with their one base-register
word changed from `0x8000_0000` to `0x9000_0000`, the SDRAM model attached, and
the testbench reading the words back from the model. With SDRAM uncached all
four pass. With SDRAM cacheable but the snoop still limited to block RAM, the
AMO test loses updates (counter 102, expected 200: its plain read-modify-write
of the shared counter reads a stale line) and the LR/SC test lets hart 0's SC
succeed when the cross-hart write should have failed it, on both pairs; with
both ranges they pass. So cross-hart atomics and a mutex-protected shared
counter are now directed-tested in the memory Linux uses, not just booted on.
Still not covered: DDR3, a larger cache, and a proof.

**Update, Part 7: where the bus time goes now, and what the instruction side
would buy.** With the data cache on and covering SDRAM, the two-hart in-order
Linux boot (199.4 M cycles, Part 6) spends its bus time mostly on instruction
fetch: hart 0 and hart 1 fetches are granted 102.8 M and 16.3 M cycles of about
185 M busy, against 31.5 M and 24.3 M for data and 9.3 M and 1.2 M for the
page-table walkers. The instruction cache (`ic_*` in `rtl/soc/cpu_wb.v`) is 256
words, word-granular, with no spatial locality: straight-line code always
misses. So the instruction side is the biggest remaining lever, and the first
question is how big, measured as a ceiling by enlarging that cache on a copy of
the tree and booting the same two-hart Linux (nothing committed):

| Instruction cache | Cycles to userspace | Bus in use | A master waiting | Hart 0 fetch granted |
|---|---|---|---|---|
| 256 words (today) | 199.4 M | 93.0% | 74.0% | 102.8 M |
| 1024 words | 167.4 M (-16.0%) | 90.6% | 69.4% | 68.2 M |
| 4096 words | 136.6 M (-31.5%) | 84.8% | 51.7% | 36.3 M |

Both enlarged builds reach userspace. The ceiling is real and large. **But the
cheap way to get it costs the wrong things.** The cache is distributed LUT RAM,
read asynchronously (its own comment explains why a block RAM would add a wait
state to every hit). Synthesised for the ULX3S 85F at the framebuffer's
diagnostic 8x8 size, three placement seeds each, the same tool bundle: today's
tree gives 33,130 TRELLIS_COMB and 20.56 / 19.87 / 20.67 MHz (mean 20.37); the
1024-word cache gives 42,070 TRELLIS_COMB (+8,940, +27%) and 16.45 / 18.02 /
17.26 MHz (mean 17.24, -3.1 MHz), worse on every seed. That is about 11.6 LUTs a
word, several times the "256 entries is roughly 900 LUT4s" the cache's own
comment used to say. A 64-entry build (31,837 LUT4s, 20.35 MHz on one seed)
fills in the curve: 6.7 LUTs a word from 64 to 256, 11.6 from 256 to 1024, so
the cost per word rises with size. The comment and the Phase 3 account now carry
the measured figures. The design already misses 25 MHz, and the instruction-cache tag compare
is on its critical path (Part 5's path reading), so a bigger LUT-RAM cache
spends area and clock for cycles. Both figures are for one hart's cache; with
two harts the area doubles.

What this supports, as an inference and not a measurement: a bigger plain
LUT-RAM instruction cache is the wrong trade, and the lever is a different
instruction-side design - spatial locality (fetching several words per bus
access, which also needs the SDRAM controller to burst more than the word it
does now) or a block-RAM cache that fetches ahead to hide the synchronous
read. Either is a design project, not a parameter, and neither is measured here.

**Arbitration fairness, re-measured and left alone.** Part 4's fairness cost is
unchanged by the caches: hart 1's instruction fetch is granted 16.3 M of the
128.2 M cycles it asks for (12.7%, against 13.2% before) and waits on 87% of its
requests, because the arbiter's fixed priority puts hart 1's fetch last. Whether
to change it is not clear from these numbers. A fairer arbiter gives hart 1 bus
cycles that hart 0 then does not get, and during an SMP boot hart 1 is mostly in
its idle loop (this is a hypothesis; instructions retired per hart were not
measured), so the cycles may be worth more to hart 0. A CoreMark pair, where
both harts do real work, is already nearly even (iterations of 434,074 and
451,483 cycles). There is no workload here on which a fairness change has been
shown to help, so none is proposed.

Not established: area and clock for the 4096-word cache (not synthesised), any
change to the data cache's size, the SDRAM controller's burst length, anything
on a board.

**Update, Part 8: how much of the instruction side line fills could take.**
Part 7 named line fills (fetching several words per bus access) as one of two
instruction-side designs and chose it to measure first. The instruction cache is
word-granular, so the first question is how much spatial locality its misses
have. Measured, on a copy of the tree (nothing committed), by logging each hart's
fetch stream during the Linux boot and feeding it to shadow caches of the same 256-word capacity
with 1, 2, 4 and 8-word lines, counting their misses (a miss is one bus
transfer today, one fill for a line cache). Cumulative at cycle 167.8 M of the boot, in
millions; "real" is the actual cache's fills and "sequential" the share of those whose
address is the previous miss plus 4:

| | Fetch events | Real misses | Sequential | 1-word shadow | 2-word | 4-word | 8-word |
|---|---|---|---|---|---|---|---|
| 1 hart | 39.9 | 13.24 | 87% | 12.46 | 7.02 | 4.14 | 2.61 |
| 2 harts, hart 0 | 34.0 | 11.10 | 89% | 10.38 | 5.70 | 3.28 | 2.05 |
| 2 harts, hart 1 | 30.9 | 1.66 | 90% | 1.55 | 0.85 | 0.48 | 0.30 |

**Almost every miss is the next word after the previous miss, so a 4-word line
cuts the number of fills by about two thirds and an 8-word line by about four
fifths**, at the same capacity. The 1-word shadow lands 5 to 7% below the real
cache's miss count (a different definition of a fetch event, and re-fetches after a
redirect), which is the size of this method's error. For scale, the bigger caches
of Part 7 cut hart 0's fetch bus time by 34% (1024 words) and 65% (4096).

What that is worth depends on how a line is fetched, which is not measured here.
The SDRAM controller (`rtl/soc/wb_sdram.v`) runs burst length 2 and CAS latency 2
with one open row, and one word fetch holds the bus for roughly 8 cycles (an
estimate: hart 0's fetch was granted 102.8 M cycles in the whole boot against
about 13 M misses by this snapshot's rate). Fetching a 4-word line as four such
reads would cost four times that and save nothing. Fetching it as one 8-beat
burst would add about six cycles to one read instead of repeating the whole
sequence three more times: on the order of 13 to 14 cycles against roughly 31.
**That would be a bus-time saving of about half** (3.3 M fills of about 13 cycles
against 11.1 M word fetches of about 8: 43 M against 89 M cycles), plus the
core no longer stalling on each word. These are inferences from the table and
the controller's structure, not simulations of a design.

So the build, if the maintainer wants it, is in this order and each is its own
change: (1) burst support in `wb_sdram.v` (a mode-register change and a way for
single-word reads, which the data cache, walkers and DMA still make, to end the
burst early), with the SDRAM model and its tests extended; (2) a line-fill
state machine in the instruction cache of `rtl/soc/cpu_wb.v`, with the
interconnect holding the bus across the fill; (3) the same Linux boots
re-measured. A side effect worth having: a 4-word-line cache of 256 words has 64
tags, a quarter of today's tag array, and the tag compare is on the critical path
(Part 5).

Not established: any of the build's cost or speedup; the two-hart boot time
effect (only bus time and fills are estimated); how the data side and walkers
share a burst-mode controller; and whether the shadow caches' handling of
redirects matches a real fill FSM's.

**Update, Part 9: line fills, step 1 - the SDRAM controller streams a
four-word burst.** The maintainer chose line fills after Part 8; the first of its
three changes is in `rtl/soc/wb_sdram.v`, and nothing else uses it yet. A new
input, `wb_burst`, asks for the four consecutive words of a 16-byte-aligned line
as four `wb_ack` pulses, one word with each. No mode-register change was needed:
the part already runs burst length 2 and CAS latency 2, and a READ command can
be issued every cycle, so the controller issues four READ commands two cycles apart on
the line's four column pairs and the data bus is never idle. A write, or a read
that is not 16-byte aligned, ignores the hint and is one ordinary transfer, so a
master that ties `wb_burst` low sees the same controller as before (`soc_top.v`
and the standalone SDRAM board top do).

Measured in `sim/tb_sdram.v` against the protocol-checking model, on an open
row: **a four-word line takes 12 cycles as a burst and 24 as four reads**, half,
with the first word at the same time a single read would deliver it. That is a
little better than Part 8's inference (13 to 14 against about 31) because a read
on an open row is six cycles, not the eight that Part 8 averaged across row
misses and arbitration; the saving for lines that start on an open row is the
factor of two, and lines that open a row save less. The new tests also read
every one of the 64 lines in a 1 KB span (including the last line of a row),
start a burst on a different row and bank, run 64 lines back to back through
refreshes, and check that a misaligned burst request, or one with `wb_we`, gives
exactly one ack and that nothing is acked after a burst. The model's own protocol
checks (tRCD, tRAS, refresh interval, row containment) pass throughout. Five
deliberate mutations of the controller each fail the test: the hint disabled, the
column offset wrong, the last read command dropped, only the last word acked, and the
alignment check removed. `make verify` and `make verify_ooo` pass with the port
tied low in the SoC.

What is still to do, each its own change: (2) the interconnect has to carry the
request to the SDRAM and hold the bus across all four acks (its lock releases on
the first), and the instruction cache in `rtl/soc/cpu_wb.v` needs a line-fill
state machine that issues a burst for SDRAM addresses and fills four words; (3)
re-measure the Linux boots. The Verilator C++ SDRAM model (`SdramModel` in
`sim/verilator_soc.cpp`) uses the same pipelined-read logic and should accept
bursts, but nothing has issued one to it yet. Not established: any effect on the
SoC, since no master asks for a burst, and area or clock cost (the controller
gained two states and three small registers; not synthesised).

**Update, Part 10: line fills, step 2a - the interconnect carries a burst.**
The second of the line-fill changes is split in two, and this is its first half:
`rtl/soc/wb_interconnect.v` now carries a four-word burst from a fetch master to
the SDRAM and keeps the bus for all four acks; the instruction cache's line-fill
state machine (step 2b) is what will ask for one. A `BURST_SLAVES` mask names the
slaves that can burst (`soc_top.v` sets it to the SDRAM), each hart's fetch master
gets an `f_burst` input, and the selected master's request is passed to the
slaves as `s_burst`, but only when the address decodes to a burst-capable slave,
so a hint aimed anywhere else never reaches it. The lock, which released on the
first ack, now counts four for a burst. That is the whole point of the change:
acks follow the selection and the selection follows the lock, so a lock released
after the first ack would hand words two to four to whichever master won the next
arbitration. `soc_top.v` connects `s_burst` to the controller and ties every
`f_burst` low, so the SoC behaves as it did.

Verification. `make sim_interconnect_burst` runs two harts' fetch masters
bursting SDRAM lines while hart 1's data master makes single reads of SDRAM and
of a one-wait RAM with idle gaps (so a data request, which outranks fetch, lands
in the middle of a burst), all against the real controller and model, with a
monitor that fails if any other master is acked between a burst's first and
fourth ack, and a check that a hint to a slave that cannot burst is not passed
on. Four mutations each fail it: the lock released on the first ack (the
pre-burst behaviour: acks to another master and wrong words), released after the
third, `s_burst` never signalled, and no slave-capability gating. The formal
check gains the same property (no ack to any other master while a burst is
between its first and fourth ack) and proves it, and fails on the first-ack
mutant; to state it, "in flight" in `formal/fv_interconnect.v` now includes a
burst's middle, since the lock still holds the bus there, and the legal-master
assumptions say a pending request keeps its burst flag and address. Two earlier
versions of that property failed on inputs no master produces (a request whose
burst flag changed before its ack), which is why those assumptions exist.

One constraint the test taught, and worth keeping: **a master must hold `cyc`
through the rising edge that sees its ack.** The interconnect releases a lock
only at an edge where it samples `cyc`/`stb` together with the slave's ack. My
first testbench dropped `cyc` at the falling edge, in the middle of the cycle in
which the ack was visible, and the lock never released and the whole bus
deadlocked. Every real master here is registered and drops after the edge
(`rtl/soc/cpu_wb.v` does), so nothing in the SoC is affected, but it is the
kind of thing a new master has to know.

Still to do: (2b) the line-fill state machine in the instruction cache, which
becomes the first master to ask; (3) the Linux boots re-measured. Not
established: any effect on the SoC, since no master asks; area or clock cost of
the lock's two extra registers (not synthesised).

**Update, Part 11: line fills, step 2b - the instruction cache fetches a line,
and what it did to Linux.** `rtl/soc/cpu_wb.v`'s instruction cache is the first
master to ask for a burst. A miss in the SDRAM window fetches the whole
16-byte-aligned line as one burst and caches all four words; a miss anywhere else
(block RAM, the boot ROM, DDR3) is still one word. Each word keeps its own tag
and valid bit and the four words of an aligned line land in four consecutive
entries, so a filled line behaves exactly as a 4-word-line cache of the same 256
words, the shape Part 8 measured. The core takes its word on that word's own ack
and carries on while the rest of the line arrives behind it. `soc_top.v` connects
each hart's new `iwb_burst` to the interconnect's `f_burst`.

Two things in the fill needed care, and the test checks both: a FENCE.I while a
line is in flight poisons the whole line (the poison lasts to the fourth ack),
including a FENCE.I that lands on a non-final ack cycle, which clears the valid
bits but would not by itself stop the words after it; and the word an ack carries
is the line's base plus the ack count, not the request address.

Verification. `make sim_cpu_wb_ifill` drives the cache with a core model against
a bursting bus slave and a protocol monitor (request, burst flag and address held
to the last ack; a burst 16-byte aligned and inside the SDRAM window; four acks to
a burst, one to anything else). It checks 16 sequential words are four fills with
16 acks and then all hit; a mid-line start fills the whole line; block RAM, ROM
and DDR3 stay single-word; a redirect before the first ack and a core that moves
on mid-burst leave both lines whole and right; FENCE.I before the first ack and on
a non-final ack leaves nothing stale; and a slow slave (latency 7, three idle
cycles between acks). Seven mutations each fail it: the fill disabled, the word
address ignoring the count, poison dropped after the first ack, the count not
advancing, bursts outside SDRAM, a burst address not aligned to the line, and no
poison for a FENCE.I on an ack cycle. `make verify` and `make verify_ooo` pass.
Writing this test found two mistakes of my own and no bug in the RTL: a bus slave
model that treated the ack cycle's still-asserted request as a new transfer, and a
core model that kept presenting an address after taking its word, so the line was
legitimately fetched again.

The Verilator harness needed a change: `+checkreads` compares every SDRAM read the
interconnect completes with the memory at the bus address, and a burst's second to
fourth acks carry words at base + 4, 8, 12 while the address stays at the base, so
it reported 612 "wrong words", three per burst. It now computes the word's address
from the interconnect's own ack count (`sim/verilator_soc.cpp`, with `s_burst` and
`burst_acks` exposed in `sim/verilator_soc.vlt`), and `make verilator_check`
passes: 91,014 SDRAM reads checked, all matching the part, and 2,257,908
instruction fetches matching memory. It is also the first time the C++ SDRAM model
has served pipelined reads, and the Icarus and Verilator runs agree on cycles.

Linux boots to userspace, `+busmon` as in Part 4, against the tree before line
fills (simulation cycles):

| | Cycles, before | Cycles, after | Bus in use, before to after |
|---|---|---|---|
| 1 hart, in-order | 186.5 M | 146.9 M (-21.2%) | 81.1% to 72.9% |
| 1 hart, wide | 184.4 M | 149.3 M (-19.0%) | 83.2% to 77.6% |
| 2 harts, in-order | 199.4 M | 212.2 M (+6.4%) | 93.0% to 93.0% |
| 2 harts, wide | 223.5 M | 159.9 M (-28.5%) | 94.3% to 91.9% |

All four reach userspace, both harts in the two-hart runs. Against the original
shared bus with no SDRAM caching (Part 4's tree, Part 6's table) the boots are now
35% (1 hart, in-order), 33% (1 hart, wide), 44% (2 harts, in-order) and 58% (2
harts, wide) shorter.

**The two-hart in-order boot got slower, and the table says why.** Hart 0's
instruction fetch was granted 77.4 M bus cycles, down from 102.8 M (-25%), as the
fills intended. But hart 1, which the fixed arbiter had starved to about 13% of
the fetch cycles it asked for, was granted 39.5 M, up from 16.3 M, and its
page-table walker 4.8 M, up from 1.2 M: it is doing several times more work, on a
bus that was already saturated (93.0% in use before and after). Hart 0 and the boot
finish later because hart 1 now takes bus time hart 0 used to get. That reading is
an inference from the counters, not isolated: the work hart 1 does is not measured
and may be mostly its idle loop. The wide pair does not show it. The fairness
question Part 7 left alone looked live again as a result of this change; Part 12
measures it and withdraws that.

Cost. Synthesised for the ULX3S 85F at the framebuffer's diagnostic 8x8 size, three
placement seeds each, one tool bundle: the tree before this change is 33,634
TRELLIS_COMB and 18.64 to 19.39 MHz (mean 19.12); with line fills 33,347
(-287) and 18.89 to 20.84 MHz (mean 20.10), the difference inside the seed spread.
(That tree is 504 LUTs above the one Part 7 measured, 33,130, before the two
earlier steps added the controller's and interconnect's burst logic.) Not
established: anything on a board; the Linux effect with the data side bursting
too; and whether the in-order two-hart result is fixed by arbitration or by
something else.

**Update, Part 12: what the two harts do after line fills, and why
arbitration is not the lever.** Part 11 left a question open: the two-hart
in-order boot got 6.4% slower when hart 1, previously starved, started getting the
bus. Whether that extra work was useful, or hart 1's idle loop taking bus time hart
0 needed, decides whether arbitration matters. Measured on a copy of the tree
(nothing committed) by sampling each hart's physical fetch address every 64th
instruction through the boot, mapping it to a kernel symbol with `System.map`
(the Image loads at `0x9040_0000` for virtual `0xC000_0000`), and attributing the
cycles between samples to the sampled symbol. The idle path here is `do_idle`,
`default_idle_call`, `arch_cpu_idle`, the context-tracking and RCU idle
functions around them, and `cpu_startup_entry`; a judgement, and the weights are
statistical. Share of cycles, two in-order harts, after line fills:

| | Idle path | Other kernel | OpenSBI |
|---|---|---|---|
| Hart 0, whole boot | 27% | 54% | 19% |
| Hart 1, whole boot | 16% | 52% | 32% |
| Hart 0, after cycle 100 M | 49% | 45% | 6% |
| Hart 1, after cycle 100 M | 8% | 83% | 10% |

So **hart 1's extra work is real work**: after cycle 100 M it spends 83% of its
time in kernel code outside the idle path, mostly sysfs and device initialisation
(`kernfs_add_one`, `__kernfs_new_node`, `idr_get_free`, `memset`,
`kmem_cache_alloc`, `__div64_32`), and it spends 32% of the whole boot parked in
the firmware before the kernel brings it up. Hart 0 is idle for about half the late
boot. That reverses Part 11's worry that hart 1 was taking bus time from hart 0's
useful work, and suggested the opposite remedy: if the boot waits on hart 1, giving
hart 1 the bus first should shorten it. That was tested by inverting the arbiter's
tie-break so hart 1 wins every tier (also on a copy):

| Two harts | Cycles, hart 0 first (today) | Cycles, hart 1 first |
|---|---|---|
| In-order | 212.2 M | 225.0 M (+6.0%) |
| Wide | 159.9 M | 156.3 M (-2.2%) |

It does not help: the in-order boot is 6% slower and the wide one 2% faster, which
is inside what the change of who waits can explain. The bus is 93.3% and 91.7% in
use in the two runs, as it is today, so what the boot is bound by is the bandwidth
of one saturated bus and not which hart is served first; moving priority moves the
waiting and not the total. The per-master table says the same: hart 1's fetch
bus time rises from 39.5 M to 84.2 M and hart 0's falls from 77.4 M to 42.0 M, and
the sum is about 120 M cycles either way.

What this settles for Phase 8: **arbitration fairness is not a lever worth pulling
at this scale**, and Part 11's reading that it was live is withdrawn. The levers that
remain reduce traffic or add bandwidth: the instruction side still takes about 59%
of the busy bus cycles after line fills (hart 0 and hart 1 fetch: 77.4 M and 39.5 M
of 197 M), the data side about 34% (36.2 M and 31.5 M), and the page-table walkers
about 6%; a data-side line fill (measured in Part 13 and not worth it: stores, not load
misses, are the data side's bus time), a larger cache (Part 7 priced it) and the
DDR3 of Phase 9 are the candidates. Not established: how the boot's critical path divides
between the harts (only each hart's time use), whether a different policy than
strict priority (a time-sliced or weighted one) behaves differently from either
fixed order, and anything on a board.

**Update, Part 13: the data side, measured before building: a line fill is the
wrong lever, and stores are the right one.** Part 12 left the data side as the
next candidate (about a third of the busy bus cycles), and a data-cache line
fill, the obvious twin of the instruction side's, was recommended. Before building
it, the same two measurements were taken on a copy of the tree (nothing
committed): shadow data caches of the same 256-word capacity (1, 2, 4 and 8-word
lines) fed each hart's real SDRAM *load* stream, and the data master's bus-held
cycles counted by kind. Cumulative at cycle 134.2 M of the one-hart boot and at
201.3 M of the two-hart in-order boot (it ends at 212.2 M); `loads` are SDRAM
loads, `real` the cache's actual load misses:

| | Loads | Real misses (share sequential) | 1-word shadow | 4-word | 8-word |
|---|---|---|---|---|---|
| 1 hart | 8.90 M | 0.739 M (19%) | 0.911 M | 0.646 M (-29%) | 0.610 M |
| 2 harts, hart 0 | 10.03 M | 1.024 M (20%) | 1.137 M | 0.728 M (-36%) | 0.657 M |
| 2 harts, hart 1 | 7.91 M | 0.645 M (17%) | 0.635 M | 0.504 M (-21%) | 0.457 M |

The load hit rate is already about 92%, and only 17 to 20% of the misses are the
next sequential word (87 to 90% on the instruction side), so a 4-word line removes
21 to 36% of an already small number of misses, against 68% on the instruction side.
The shadow caches ignore stores and snooped writes, so they overstate the miss
count slightly (1-word shadow against real: 0.911 M against 0.739 M in the one-hart
run).

The bus-held cycles say where the data side's time actually goes. Cycles the data
master held the bus, by kind (these include the cycles spent waiting for a grant):

| | Stores | Load misses | Atomics | Uncached loads |
|---|---|---|---|---|
| 1 hart | 27.7 M (68%) | 8.4 M (21%) | 3.6 M (9%) | 1.7 M (4%) |
| 2 harts, hart 0 | 44.1 M (65%) | 14.9 M (22%) | 4.7 M (7%) | 2.1 M (3%) |
| 2 harts, hart 1 | 45.5 M (79%) | 10.2 M (18%) | 2.3 M (4%) | 0 |

**Stores are two thirds to four fifths of the data side's bus time**, not load
misses. The data cache is write-through, so every store is its own SDRAM write
transaction of about eight cycles (27.7 M cycles for 3.5 M stores, in the one-hart
run). A line fill could save at most a third of the load-miss share, a few percent
of the data side and about 2% of the bus; it is not worth the fill state machine
and its coherence cases (a store or a snooped write landing mid-fill).

What the numbers point to instead is the store path: **a store buffer that posts
stores and merges adjacent ones into a burst write**, so the core does not wait
for each write and a run of stores costs one transaction. That is a larger and
riskier change than a line fill, and its correctness is the whole difficulty, not
its speed: stores must stay ordered with later loads to the same address (forward
from the buffer, or drain before the load), the buffer must drain before an atomic
(AMO or LR/SC), before FENCE and FENCE.I, and before any access that is not to
cacheable memory (device registers stay strictly ordered); a snooped write from the
other hart must still invalidate correctly; and a trap or the debug halt must not
lose a posted store. The SDRAM controller would also need a four-word write burst
(it streams reads today). None of that is built or estimated here, and the saving
is not measured: eight cycles a store is an upper bound on what posting could
hide, and how many stores are adjacent is not counted. This is a design decision
for the maintainer, not an autopilot step.

Not established: any of the above on a board; the effect on the wide core (all the
measurements are in-order); how many stores are adjacent (the merge benefit); and
the atomics' and uncached loads' share, which is small here but is a fixed cost
any store buffer has to drain around.

**Update, Part 14: how adjacent are the stores, the number a store buffer's
value hangs on.** Part 13 found stores are two thirds to four fifths of the data
side's bus time and named a store buffer that merges adjacent stores into a burst
write as the candidate, noting that how many stores are adjacent had not been
counted. Counted now, on a copy of the tree (nothing committed): each SDRAM store
against the previous one, and as runs of stores to one 16-byte line with no other
data access of that hart in between, the most a four-word write burst could
merge. Cumulative at cycle 134.2 M of the one-hart boot and 201.3 M of the
two-hart in-order boot:

| | Stores | Same line as the previous store | Runs of 1 | 2 | 3 | 4 or more | Transactions if runs merged |
|---|---|---|---|---|---|---|---|
| 1 hart | 3.37 M | 50% | 1.14 M | 0.43 M | 0.14 M | 0.24 M | 1.95 M (-42%) |
| 2 harts, hart 0 | 3.68 M | 47% | 1.38 M | 0.52 M | 0.13 M | 0.22 M | 2.25 M (-39%) |
| 2 harts, hart 1 | 4.11 M | 80% | 0.55 M | 1.49 M | 0.06 M | 0.10 M | 2.20 M (-46%) |

(Runs of four or more are split at four; the run lengths add up to the store
count exactly.) Roughly half the stores sit in the same line as the one before, and
hart 1 is dominated by pairs of adjacent stores: 1.49 M runs of exactly two.

What that is worth, as a bound and not a measurement. A single store costs about
eight cycles on the bus (27.7 M cycles for 3.37 M stores in the one-hart run).
Assuming a merged write of k words costs 8 + 2(k - 1) cycles, by analogy with the
read burst (Part 9: 12 cycles for four words against 24 for four reads), merging
every run perfectly would take the one-hart stores from about 27 M bus cycles to
about 18 M (-32%), hart 0 of the two-hart run from about 29 M to 21 M (-29%) and
hart 1 from about 33 M to 21 M (-35%). Stores are about a quarter of the busy bus
cycles (Part 13: roughly 35% for the data side, two thirds to four fifths of it
stores), so **merging alone is worth about 7 to 9% of the bus**. That is a ceiling:
it assumes a buffer deep enough to hold stores until each run completes and no
ordering event cutting runs short, and the write-burst cost is assumed, not
simulated (the controller has no write burst).

The other benefit is separate and larger when the bus is not the limit: **posting**.
Today the core waits out each store's eight cycles, which in the one-hart boot is
about 27 M of 134 M cycles, 20% of the run. A buffer that lets the core carry on
could hide up to that much on one hart, if it never fills and nothing forces a
drain. On two saturated harts it would not shorten the boot by that much, since the
bus is the limit and posting does not reduce its load.

So a store buffer is worth building if one-hart (and lightly loaded) speed matters,
with the merge a modest 7 to 9% of the bus on top, and little for the saturated
two-hart boot beyond the merge. The cost is the one Part 13 listed: ordering with
later loads, drains before atomics, FENCE and device accesses, snooped writes, and
a trap or debug halt not losing a posted store. This is the maintainer's decision.

Not established: that merging runs of this kind is achievable in a real buffer (run
boundaries here are idealised), the write burst's real cost, the wide core, and
anything on a board.

**Update, Part 15: Stage 1 begun - the network interfaces, a packet format and a
one-node network, outside the SoC.** The maintainer asked for Stage 1 to proceed
(2026-10-05), after Stage 0's decision to work the memory levers first; this is
the first slice of it, and it changes nothing in the SoC. Three new files carry
the Stage 1 boundary:

- `rtl/soc/noc_ni_master.v`: a Wishbone slave port facing one master, turning its
  `cyc & stb` into a request packet and the response packet into its `ack` (or
  `err`, with the read data).
- `rtl/soc/noc_ni_slave.v`: takes a request packet, performs it as a Wishbone
  master against one slave, and returns the answer as a response packet. It
  accepts a request only when idle, so a second one waits in the network.
- `rtl/soc/noc_node1.v`: the degenerate one-node network. It carries one
  transaction at a time, as the bus does: take a request, route it by `dst`,
  wait for the response, return it by `src`. A `dst` that names no slave is
  answered with an error by the node itself, the equivalent of the bus's
  decode-error ack.

The packet is one 80-bit word (82 since Part 16 added burst and last bits) for request and response alike: `lock`, `we`
(`err` in a response), byte enables, a 2-bit `qos`, 4-bit `src` and `dst`, 32-bit
address, 32-bit data. `qos` is carried end to end and echoed in the response,
and nothing arbitrates on it; that is Stage 3.

**Atomics.** A bus holds `cyc` across an AMO's two phases and the arbiter keeps
everyone else out; a network cannot see that, so the master says it in the packet.
The `lock` bit means "more from this master follows": the node then accepts
nobody else until a request with `lock` clear from the same master has been
carried, and the slave interface keeps `cyc` high with `stb` low in the gap, which
is the pattern the slaves see from a locked bus today. The master interface takes
the bit as a sideband input (`wb_lock`) because only the core knows an AMO's read
is the first of two; wiring that to `dmem_is_amo` is the integration step, not
done here.

**Evidence.**

- `make sim_noc_ni` (`sim/tb_noc_ni.v`), part of `make verify`. Two masters and two
  slaves with random wait states: 600 random reads and writes each (random byte
  enables, back to back and with gaps) on private words, every read checked
  against a per-master reference, which is round-trip correctness and per-master
  ordering; every word read back at the end; a slave error and an unmapped address
  both returned as errors with the network still working afterwards; then both
  masters make 80 locked read-modify-write increments of one shared word and the
  total is exactly 160, with the slave seen holding `cyc` in the gap (811 cycles).
  Part B puts a channel that randomly refuses to pass a request or a response for a
  cycle between one master interface and one slave interface (800 transfers, the
  request refused in 449 cycles) and checks that no packet changes while waiting,
  that the slave interface is never ready while busy, and that the master interface
  never takes an unsolicited response.
- Mutation: removing the owner lock, never opening it, dropping `cyc` between
  phases, ignoring byte enables, ignoring `we`, dropping the error, answering an
  unmapped address with an ack, sending the response to the wrong master, dropping
  `dst`, and returning the wrong read data are each caught. Two mutants survived at
  first (a master interface always ready for a response, a slave interface always
  ready for a request): at system level they are equivalent, since the node only
  offers a request when the interface is idle, so the handshake checks above were
  added and now catch them.
- Formal: `formal/fv_noc_node.v` proves for the node, over all sixteen `dst`
  values, at depth 12: at most one slave asked and only the one named; one request
  taken per cycle and only while idle; a response goes to the master that asked and
  only while one is outstanding; while a locked sequence is open nobody but its
  owner is taken; the three phases of a transaction are disjoint. Four cover
  statements are reached, and removing the lock, sending the response to the wrong master, asking
  both slaves and accepting while busy are each refuted. Writing it caught a bug in
  the property itself: a sum of three one-bit terms wrapped and passed everything.

**What this does not establish.** The interfaces are not wired into `soc_top`, so
no core runs through them, and nothing has been measured: the extra latency of
the packet round trip against the bus is unknown (the node adds several cycles
per transaction by construction, which on a bus that is 93% busy would matter, and
that is the reason the trigger stays where Stage 0 put it). Stage 1's "same
functional behaviour as the bus" is shown against a Wishbone memory model, not
against `wb_interconnect.v` and the real slaves; the burst transfer the SDRAM now
supports (Part 9) had no packet form yet (Part 16 adds one); the master interface needs a master that holds
its request until acked; LR/SC's reservation monitor is untouched, since it
watches the bus and no bus is between the harts yet. Stages 2 to 5 remain a plan.

**Update, Part 16: the packet carries a four-word burst.** Part 15's closing note
said the SDRAM's burst (Part 9) had no packet form, so an instruction line fill
could not cross the new boundary. This closes that, and only that: the packet is
now 82 bits, with a `burst` bit in a request (a four-word read of the 16-byte
line at `adr`) and a `last` bit in a response. A burst is one request answered by
four response packets, in address order, the fourth marked `last`; every other
response is a single packet with `last` set. The three blocks change as follows.

- `noc_ni_master.v` takes a `wb_burst` sideband, holds the master's request
  through four acks (one per packet), and ends the transaction on the packet
  marked `last`.
- `noc_ni_slave.v` holds `stb` and the address steady until the slave's fourth
  ack, tells the slave it is a burst through `wb_burst`, and turns each ack into
  a packet. A Wishbone ack cannot be refused, so the packets wait in a four-entry
  queue; a new request is taken only when the queue is empty. An error ends a
  burst early, and its packet is marked `last`.
- `noc_node1.v` cycles between waiting for a beat and delivering it until the
  `last` beat has gone, and takes no other request in between, which is the
  property the bus's burst lock (Part 9) provides.

**Evidence.** `make sim_noc_ni` now also runs 60 four-word bursts from one master
(both slaves, both lines) while the other does 200 ordinary reads and writes,
every word checked against what was stored and in order; a burst that meets a
slave error after two words (and must end there, with the network afterwards still
returning the right data); a burst to an unmapped address (answered with one error
packet); and bursts mixed into the randomly stalling channel test. A monitor
checks that an error response is always marked `last`. Mutation: ending the
transaction after every beat, taking a new request after each beat, marking every
beat or no beat `last`, an error that is not marked `last`, a burst that ends
after three beats, dropping the burst flag at either interface, a queue that
overwrites one slot, and taking a request while the queue is not empty are each
caught. Four needed test fixes to be caught, none an RTL fix: the memory model's
burst counter carried over between requests (so a one-beat "burst" repeated looked
like a real one), its error word was the burst's last beat, a check read only
the error flag and not the data after it, and an error that was not marked `last`
needed a monitor, since a master that has already seen the error cannot tell.
`formal/fv_noc_node.v` is widened for the 82-bit packet: a transaction now stays
open until its `last` packet has been delivered, so the existing properties (no
request taken while one is open, a response only to its requester, the lock) also
say that nothing falls inside a burst; a mutant that takes a request after each
beat is refuted, and a cover statement reaches a burst's middle beat.

**What this does not establish.** Still outside the SoC and still against a
Wishbone memory model: nothing here runs the real SDRAM controller or the
instruction cache's line fill through the packets, and the queue's depth is the
burst length, so a longer burst (the DDR3 path's) needs it widened. Latency is
unmeasured.

**Update, Part 17: a fabric that stands where the bus stands.** Parts 15 and 16 tested
the interfaces and the node against a memory model. Stage 1's Done-when asks for
the same functional behaviour as the bus, so this builds
`rtl/soc/wb_noc_fabric.v`: the same ports and decode as `wb_interconnect.v`, with
every master behind a master interface, every slave behind a slave interface and
the node between them. Nothing in `soc_top` uses it yet.

How the bus's behaviour is kept. Master IDs follow the bus's priority (debug, then
each hart's data, walker and fetch, then the NPU) and the node serves the lowest,
so the tiers and the lowest-hart tie-break are the same. The AMO gap is closed by
a new `hold` input on the node, driven by `d_amo_wrphase`: only that hart's data
master may be taken, even while it has nothing to offer (a core cannot lock on an
AMO's read, since it does not know yet that a write follows; it raises the hold when
the read is acked, which the bus relies on too). An unmapped address comes back from
the node as an error and the fabric turns it into the bus's ack with zero data. A
fetch master's `f_burst` becomes a burst only for a slave in `BURST_SLAVES`. The
slaves' shared wires are rebuilt as the OR of the slave interfaces' outputs, each
gated by its own `stb`, and `snoop_wr`, `snoop_adr`, `snoop_src_d` and
`s_data_master` are rebuilt from the slave side and the node's record of whose
transaction is out.

**Evidence.**

- The bus's own burst test, unchanged, passes with the fabric in the bus's place
  (`make sim_interconnect_burst_noc`), against the real SDRAM controller and its
  model: four-word bursts to the master that asked, in order, and nobody else acked
  in between.
- `make sim_noc_fabric` (`sim/tb_noc_fabric.v`) runs two copies of one system on
  the same random traffic, one around the bus and one around the fabric: two
  harts' data, walker and fetch masters, the debug master and the NPU's, a
  burst-capable RAM with wait states, a one-wait RAM, a device that acks in the cycle
  it is addressed, and an unmapped range. Each master follows a seeded script, so
  both copies see the same requests. The 300 operations per master include random
  byte-lane writes, reads, line bursts, unmapped reads and writes, and AMO
  increments in the bus's real protocol. All eight masters' logs of what they read
  are identical (about 2,500 values), every slave ends in identical contents, the
  72 AMO increments are all present in the counters on both sides, and the
  snooped-write and data-master tallies match.
- Mutation of the fabric: no hold, the hold on the wrong hart, burst for every slave,
  burst for none, no error-to-ack conversion, a lost snoop source, a snoop without
  its ack, the data-master flag off or including walkers, and dropped byte lanes are
  each caught. `fv_noc_node` gains the hold property (only the held master is
  taken, with a cover for a hold overriding a waiting master); removing the hold
  from the node is refuted.

**What differs from the bus, deliberately.** A write to an address nothing decodes
is acked by both but reported to the snoopers only by the bus; it changes no memory.
A master that holds `cyc` with `stb` low outranks others on the bus and is invisible
here, which the cores only do in an AMO's gap, where the hold now stands in; the test
found that its own data master left `cyc` up between transfers and so hung the bus
copy, a test fault the bus's own rule makes plain. Timing is not equal and not
compared: a transaction costs a few cycles more through the packets.

**What this does not establish.** No core runs through it: `soc_top` still builds
the bus, so Linux, CoreMark, the two-hart tests and the formal properties of
`wb_interconnect.v` have not been run against the fabric, and the priority order is
proved by construction (the node serves the lowest ID) rather than tested, since
random private-word traffic does not depend on it. The cost is unmeasured. Wiring it
in behind a build switch, running the existing system tests over it and measuring the
cycles it costs is the next Stage 1 step.

**Update, Part 18: the SoC runs over the network, and what it costs.** The fabric
from Part 17 is now selectable in `soc_top`: `make INTERCONNECT=noc` builds the
SoC with `wb_noc_fabric` where `wb_interconnect` stood (the same instance name and
ports; the bus stays the default, and nothing else chooses). `make verify_noc` runs
the whole `make verify` suite over it, clearing the built simulations first since
they are keyed on the core and not the interconnect. This is the Stage 5
build switch in its first form, and Stage 1's Done-when run against the real
system.

**Evidence.** `make verify_noc` exits 0: the boot ROM and SD path, the preloaded-RAM
boots, the trap checks, the SDRAM and DDR3 paths, the MMU and PMP tests, the PLIC and UART
tests, the debug module, both-hart tests (coherence, AMOs, LR/SC, the hetero pair),
the NPU, the Verilator harness with its read checker (cycle for cycle identical to
Icarus) and the Linux boot to userspace all pass over the packet network. `make verify` on the
bus still exits 0.

**The cost, measured.** Linux boots to userspace in 186,736,140 cycles over the
network against 146,914,531 over the bus, **27% more** (one in-order hart, with the
instruction-cache line fills of Parts 8 to 11). The SDRAM boot check, a different
mix, takes 2,887,812 cycles against 2,262,170, 28% more. A transaction through the
interfaces and node costs a handful of cycles more than on the bus, and the bus's own
saturation (Part 7) means no part of it is hidden. That is the price of the packet
form at one node, before any router; Stage 2's reason to exist would be to win it
back by carrying transactions in parallel, which a single memory (Stage 0) gives it
little to do.

**Two tests had timing assumptions the extra latency broke, neither a defect.**
`sim_uartload_ddr3` sends at 4 clocks per bit, a simulation shortcut, so the boot
ROM has about 40 cycles per byte and no FIFO: over the network it loses bytes at 6
clocks per bit and keeps up at 8, so the network build sends at 8 (the real baud is
about 217 clocks per bit). `sim_div64test`'s timer fires every 97 cycles and its
handler has to finish inside that; over the network it never gets past it, passes at
200 and 400, and the network build uses 200 (the threshold between 97 and 200 was
not located). Both are macros that only the network build sets.

**What this does not establish.** `make verify_noc` is run by hand: CI runs the bus
build and no network job yet, so a change that breaks only the network build would
not turn CI red. `verify_ooo` over the network (the wide core) and the two-hart Linux
boot were not run over it; the Verilator `+busmon` monitor reads bus internals that
the network stand-in only approximates (a master is counted as granted while the node
has its request at a slave). Nothing here measures area or timing: the fabric's LUTs
and its effect on the 25 MHz target are unknown, and the cost above is cycles only.

**Update, Part 19: the wide core and the second hart over the network.** Part 18 left
two things not yet run over the packet network: the wide core's suite and a two-hart Linux
boot. Both now pass. `make verify_noc CORE=ooo` exits 0, and Linux reaches userspace
on both harts over the network with the in-order pair and with the wide pair
(`make sim_linux_2hart INTERCONNECT=noc`).

**The cost, measured on the bus and on the network from the same tree** (cycles to
userspace):

| Configuration | Bus | Network | Network costs |
|---|---|---|---|
| 1 hart, in-order | 146,914,531 | 186,736,140 | +27.1% |
| 1 hart, wide | 149,304,491 | 191,667,924 | +28.4% |
| 2 harts, in-order | 212,175,721 | 246,170,878 | +16.0% |
| 2 harts, wide | 159,893,093 | 226,199,579 | +41.5% |

One hart costs about 27 to 28% on either core. Two in-order harts cost the least (16%)
and two wide harts the most (41.5%), which the measurement does not explain: the
in-order pair was already the slow one on the bus (Part 11 found its second hart
no longer starved once line fills arrived), and the wide pair is the one the bus
served best, so it may simply have the most to lose from a serial extra
few cycles per transaction. That is a guess, not a measured cause; the number to
trust is the one in the table.

**One test was fragile, and is fixed.** `test_gpt`'s timer check (`software/soc/main.c`)
read `COUNT` twice around a 40-iteration loop and required the second reading to be
larger, with the timer wrapping at 100. That holds only if the loop takes under 100
cycles, so it passed on the bus and on the in-order core over the network by the
phase of the wrap, and failed on the wide core over the network, where each loop
iteration's stack store takes longer. It now reads with a free-running count (period
0) so wrapping cannot spoil it, and waits for the wraparound and its interrupt-pending
bit by polling within a generous bound instead of a fixed loop count. The test is in
every core's and both interconnects' suites; all four combinations pass it, and the bus
suites (`make verify`, `make verify_ooo`) pass with it.

**What this does not establish.** The same caveats as Part 18: no CI job builds the
network, so it is run by hand; area and timing are unmeasured; `+busmon` only
approximates grants. The suites `verify_noc` and `verify_noc CORE=ooo` ran before a final
no-logic edit (explicit four-bit casts on two parameters of the fabric, to satisfy a
Verilator width lint that only the two-hart builds reached); after it, the fabric's
own tests, its lint, and both two-hart Linux boots were rerun and pass, and the two
full network suites were not.

**Update, Part 20: the interfaces are proved too, and Stage 1's Done-when is met.**
Parts 15 to 19 proved the one-node network formally (`formal/fv_noc_node.v`) and
tested the interfaces. Stage 1's Done-when also asks for formal properties "where the
design admits them", and the interfaces admit the ones that matter: lost or invented
data.

- `formal/fv_noc_ni_slave.v` proves, over a legal environment (an offered request stays
  until taken, a burst is a read, the slave acks only to a strobe): the strobe is up
  exactly while a request is outstanding and `cyc` also across a locked pair's gap; a
  request is taken only when nothing is outstanding and every response packet of the
  last has left; every ack becomes exactly one packet and the queue never holds more
  than four (so a burst cannot overflow it); a transaction's last packet is marked and
  nothing is queued behind it; an error is always last; and every response carries this
  interface's own ID as sender.
- `formal/fv_noc_ni_master.v` proves, over a legal master (it keeps its request until
  acked) and a legal network (a response only to a request that was sent, an offered one
  stays): one request at a time; the response is accepted exactly while one is awaited;
  an ack or error reaches the master only with a response that is there and while it is
  asking, never both; and the request packet carries exactly what the master asked for.
- Both are proved at depth 12 with their cover statements reached (a full queue, a
  burst's last beat, an error, a locked request, a burst's middle beat). Ten mutants
  are each refuted: an error not marked last, a burst that ends early, a request taken
  while packets are queued, a queue that loses a beat, `cyc` dropped in the lock gap, a
  wrong sender ID, a second request allowed, a master interface always ready for a
  response, a dropped lock bit, and an ack without a strobe. `make formal` now proves
  11 targets.

**Stage 1, against its own Done-when.** A real master reaches a real slave through the
network interfaces with the bus's functional behaviour (Parts 17 to 19: the bus's own
burst test, a side-by-side random comparison with the bus, and the whole verification
suite and Linux over it on both cores with one and two harts); the directed tests cover
round-trip correctness, per-master ordering (a master's reads see its own writes) and
back-pressure (a randomly stalling channel, slave wait states, a queue that fills);
LR/SC/AMO survive the crossing (the hold, and the two-hart atomics tests over the
network); and the node and both interfaces carry formal properties. **That meets the
Done-when, in simulation.** What it does not do, and the cost it carries, is in Parts
17 to 19: 16 to 41% more cycles, nothing run on a board, no area or timing figure, and no CI job
for the network build. Stage 2 (a real router) stays behind the phase's own trigger,
which Stage 0's measurement says has not occurred: the bus is saturated by one memory,
and a network does not add a second.

**Update, Part 21: Stage 2 begun - a packet router.** The maintainer asked for Stage 2
(2026-10-08), which Stage 0's own measurement said would buy little (one memory takes
95 to 99.8% of the traffic, so a network has nothing to carry in parallel); this builds
it and measures it against the bus, as the Done-when asks, and does not claim a win in
advance. The first piece is the router, on its own.

`rtl/soc/noc_router.v` has NUM_IN input ports and NUM_OUT output ports joined by a
crossbar. Each input has a small FIFO whose head packet's `dst` names the output it
wants; each output serves, per cycle, the lowest-numbered input that wants it (the same
fixed priority as the bus and the one-node network). So packets bound for *different*
outputs move in the same cycle, which `noc_node1.v`, carrying one transaction at a time,
cannot do. A packet is one flit (a whole request or one beat of a response), so there is
no path to hold across cycles as a wormhole router holds one, and no virtual channels:
nothing here is wider than one transfer. A grant is held until the receiver takes it, so
an offer never changes while it waits. Packets between one input and one output keep their
order. The two ways of keeping an AMO's phases together carry over: a `lock` packet makes
its source the owner of that output until a packet with `lock` clear from it has gone, and
the `hold` input (raised by a core when an AMO's read is acked) closes the output the
holder last used to everyone else, leaving the other outputs open. A `dst` that is no
port is taken, discarded and flagged (a sticky flag, `misroute` in the code) rather than left to hang.

**Evidence.**

- `make sim_noc_router` (`sim/tb_noc_router.v`, in `make verify`): three inputs, three
  outputs, two-deep FIFOs. 2,101 packets of random traffic with random output
  back-pressure and `lock` pairs, each carrying a per-flow sequence number: every one
  delivered, none lost, repeated or reordered; an offered packet never changed or vanished
  before it was taken; 563 cycles in which two or more outputs moved at once (required to
  exceed 100); the lock excluded other sources in every locked sequence. A hold phase: while
  `hold` was up no other input passed the held output (0 of 6 queued), the other output carried
  all 6 packets sent to it, the holder still got through, and the six waiting packets passed
  once it dropped. A phase with an undeliverable destination: discarded and flagged, traffic carried on. Ten mutants are
  caught: no hold, a hold that blocks every output (survived at first, because the test
  counted the other output across the whole window and the same input's packets to it were
  stuck behind the blocked one; now a different input sends there and only the hold's window
  is counted), no lock, a lock never released, a grant not held, a bad destination not discarded, a
  FIFO that is never full, a FIFO that reads the wrong slot, ignoring the destination, and
  `last_out` not recorded.
- `formal/fv_noc_router.v` (two inputs, two outputs, depth 2; boolector, depth 12; 5 cover
  statements reached): a packet leaves by the port its `dst` names; every packet that leaves
  an input is that input's next one, by sequence number (no loss, repeat or reorder; the
  numbers are mod 16, enough that a two-deep FIFO cannot confuse them); an input is ready
  exactly while it has room; an offer, once made, stays unchanged; a locked sequence excludes
  others at its output; and a new offer at the output the holder last used is the holder's.
  Eight mutants are each refuted. (The first attempt used 32-bit counters and z3 and was
  stopped after thirty minutes; four-bit counters and boolector prove it in under four.)

**What this does not establish.** Nothing yet uses the router: `wb_noc_fabric.v` still has
the one-node network, and `soc_top` still shares one set of slave wires, so no two slaves
can be active at once. A fabric that gets parallelism out of the router has to give each
slave its own address and data wires and rebuild what the bus's shared signals carry (the
snoop and reservation-monitor events, which assume one write at a time); that is the next
piece, then the SoC, then the numbers.

**Update, Part 22: a fabric built on routers, compared with the bus.** The second Stage 2
piece puts the router (Part 21) where the one-node network was: `rtl/soc/wb_noc_xbar.v` has
the bus's masters and decode, a request router from the master interfaces to the slave
interfaces, and a response router back, so transactions to *different* slaves are in
flight at once. An address nothing decodes goes to one more router port, a small error
sink (`rtl/soc/noc_err_sink.v`), and comes back as the bus's ack with zero data. Two
things change at its edge, both because two slaves can now be busy together:

- **Per-slave wires.** The bus shares one set of address, data and control wires among
  all its slaves; here each slave has its own (`s_adr[i]`, `s_we[i]`, ...), and so do
  `s_data_master[i]` (whether the transaction at slave i is a data master's, taken from the
  slave interface, which now reports whom it is serving) and `snoop_*[i]` (the writes slave
  i has completed). The reservation monitor needs nothing from the bus: it works from
  each core's own store events. The caches' snoop port is the SoC-side question: block RAM
  (0x80) and SDRAM (0x90 and 0x91) are the two cacheable windows and can complete writes
  in the same cycle, which a cache with one snoop port cannot take; that is part of wiring
  this into `soc_top`, not done here.
- **Atomics, by a lock set when the read is issued.** The bus keeps others out of an AMO's gap
  from the read's ack to the write, using `d_amo_wrphase`. That is not enough here. A slave
  interface takes its next request the moment the read finishes, a few cycles before the
  read's response is back at the core and the core can raise `d_amo_wrphase`, so another
  master's access to the same slave can slip in first. The measurement: with the lock removed and the
  hold kept, the equivalence test below fails. So the data master sends the AMO's read with
  `lock` set, which needs a new input, `d_is_amo` (the core already has the signal,
  `dmem_is_amo`), `d_amo_wrphase` ends the lock on the write, and the request router's owner
  lock keeps everyone off that slave across the gap. The router's `hold` is not used.

**Evidence.** `make sim_noc_xbar` (`sim/tb_noc_xbar.v`, in `make verify`): the bus and the router
fabric, each with its own copy of the same slaves (on the bus's shared wires and on per-slave
wires respectively), run identical random traffic from every master role (the test of
Part 17: byte-lane writes, reads, line bursts, unmapped accesses and AMO increments). All eight
masters' logs of what they read are identical (about 2,500 values), every slave ends in
identical contents, all 72 AMO increments are present, the snooped-write and data-master
tallies match, and the router fabric had two slaves busy at once in 1,424 cycles (the bus
never has more than one), which the test requires. Eleven fabric mutants are caught: an AMO read not
locked, an AMO write also locked, an AMO never locked, burst for every slave or for none, an
unmapped address not sent to the error sink, a lost snoop source, a snoop without its ack, the
data-master flag off or counting walkers, and the like. One survives and is equivalent from
outside: an error sink that answers without the error bit, since the fabric turns every error
into an ack as the bus does.

**What this does not establish.** Still outside the SoC. The test's slaves are models, the
fabric's cost in cycles is unmeasured (a transaction now crosses two routers and two sets of
interface queues, which is more latency than the one node's, and the saving is only where two
slaves are used together), and the snoop-port question above is unanswered. The next piece is
`soc_top`: per-slave wiring for all thirteen slaves, two snoop ports on the data cache, and the
whole suite run over it, then the numbers.

**Update, Part 23: the SoC over routers, and what it costs.** The router fabric of Part 22
is now selectable in `soc_top`: `make INTERCONNECT=xbar` builds the SoC with `wb_noc_xbar` where
the bus stood, and `make verify_xbar` runs the whole `make verify` suite over it (as
`verify_noc` does for the one-node network). Every slave now reads its own copy of the
address, data and control wires (`sl_*`) in every build: on the bus and the one-node network
each copy is the shared wire, so nothing changes for them (the bus's cycle counts are
identical to before: Linux boots in 146,914,531 cycles and the SDRAM boot check takes
2,262,170, both unchanged), and on the router fabric they are separate wires, which is
what lets two slaves be busy at once.

**Three things had to change for the SoC to run, none of them visible in Part 22's models.**

- **The cache's snoop argument rested on the bus.** `cpu_wb.v`'s write-through data cache was
  argued correct because a write cannot complete while the hart's own access is in flight. With
  routers it can: a slave completes an access, and the ack (and a read's data) takes more cycles
  to come back, so another hart's write to the same word can be snooped in between and the late
  ack then fills or updates the line with a value already out of date. `sim/tb_cpu_wb_snoop_race.v`
  (`make sim_cpu_wb_snoop_race`, in `make verify`) reproduces both cases, a store and a fill, and
  failed on the unchanged cache before the fix. The fix, behind a new parameter `SNOOP_LATE_ACK`
  that only the router build turns on, cancels the cache update of an access whose index is
  snooped while it is in flight. It is a parameter because on the bus the same check would
  sometimes drop a fill needlessly, when another hart's write lands while a request merely waits
  for the bus, which would change the bus's cycle counts.
- **Two snoop ports.** Block RAM and SDRAM are both cacheable and can complete writes in the
  same cycle; the cache has a second snoop port (`snoop2_*`, tied low on the bus), and the router
  fabric reports each slave's writes separately, with the RAM slave's on port one and the SDRAM
  slave's on port two.
- **Only a read-modify-write AMO's read can be locked.** The first version of Part 22 locked
  the read of anything the core calls an AMO, and the SoC deadlocked at the load-reserved test:
  `dmem_is_amo` is also high for LR and SC, an LR has no write phase and an SC may not, so the
  lock was never released and blocked the hart's own instruction fetch. Both cores now export
  `dmem_is_rmw` (an AMO that is neither LR nor SC), which is what the fabric locks on.

**Evidence.** `make verify` and `make verify_ooo` (the bus) exit 0 with all of the above, the bus's
cycle counts unchanged. `make verify_xbar` and `make verify_xbar CORE=ooo` exit 0: the whole suite,
including Linux booting to userspace, over the router fabric on both cores. `make sim_linux_2hart
INTERCONNECT=xbar` reaches userspace on both harts with the in-order pair and the wide pair. Two
test knobs are set for the network builds, for the reasons given in Part 18 (the UART loader's
4-clocks-per-bit baud and the divide test's 97-cycle timer); `+checkreads` and `+busmon` read the
shared bus's wires and are off for this build, so `verilator_check` there compares the two
simulators cycle for cycle without the read checker.

**The cost, measured** (cycles to userspace; bus, one-node network of Parts 18 and 19, router fabric):

| Configuration | Bus | One-node network | Router fabric |
|---|---|---|---|
| 1 hart, in-order | 146,914,531 | 186,736,140 (+27.1%) | 183,452,079 (+24.9%) |
| 1 hart, wide | 149,304,491 | 191,667,924 (+28.4%) | 181,536,850 (+21.6%) |
| 2 harts, in-order | 212,175,721 | 246,170,878 (+16.0%) | 255,309,022 (+20.3%) |
| 2 harts, wide | 159,893,093 | 226,199,579 (+41.5%) | 266,594,156 (+66.7%) |
| SDRAM boot check, in-order | 2,262,170 | 2,887,812 (+27.7%) | 2,887,536 (+27.6%) |
| SDRAM boot check, wide | 1,931,096 | | 2,428,528 (+25.8%) |

With one hart the router fabric is slightly cheaper than the one-node network (it overlaps
a fetch and a data access to different slaves) and still 22 to 25% slower than the bus. With two
harts it is slower than the one-node network, and for the wide pair by a lot: 66.7% more
cycles than the bus. **Why is not measured.** Candidates, none tested: two harts mostly meet at
the one SDRAM slave, where the router fabric's parallelism has nothing to do and its longer path
(two routers and two sets of queues) is pure latency, exactly what Stage 0's finding that one memory
takes almost all the traffic predicts; and the late-ack guard, which cancels a cache update
whenever the other hart writes the same index while an access is in flight, may be costing fills
that two harts sharing data trigger often. Counting the cancelled fills would separate the two.

**What this means for Stage 2's Done-when**, which asks that the two-hart configuration run
correctly over the network in simulation, Linux SMP reach userspace, and the latency, bandwidth and
area be recorded against the bus: the first two are met, the latency is recorded above, and the
result is that **on this SoC the router fabric loses to the bus everywhere** (16 to 67% more
cycles). That is the outcome Stage 0 expected. Bandwidth was not measured separately (Linux's
cycles to userspace and the SDRAM boot check are the workloads), and area and timing were not
measured at all.

**What this does not establish.** No area or LUT figure, no Fmax, no board; no CI job builds the
network; the two-hart Linux boots are one run each; the late-ack guard's cost is a guess; and nothing
has run with the NPU's DMA racing a hart over the router fabric, the case where two slaves are
genuinely busy together.

**Update, Part 24: Stage 3 begun - traffic classes in the router.** Stage 3 asks for growth
past the minimal case, a real quality-of-service mechanism, a check that the reservation
monitor and coherence still hold with routing between the harts and memory, sensible routing
to more than one memory, and measurements under real multi-master workloads. This is the
quality-of-service piece, and only that.

**The mechanism.** The packet has carried a two-bit `qos` class since Part 15, set by each
master interface and echoed in the response, and nothing read it. `rtl/soc/noc_router.v`
now does. With the new parameter `QOS_EN` set, an output serves the input whose head packet
has the highest class (0 to 3), the lowest input number among equals. Strict class priority
starves a low class under a steady stream of a higher one, so `AGE_LIMIT` bounds it: a head
that has waited that many cycles is treated as the top class from then on, so its wait is
bounded by the limit plus the time to serve every other aged head ahead of it, whatever the
traffic (0 turns aging off). `wb_noc_xbar.v` takes the switches and one class per master role
(`QOS_DBG`, `QOS_D`, `QOS_W`, `QOS_F`, `QOS_N`) and applies them to both routers, so a
response travels in the class of its request. Everything defaults off and equal, which is the
behaviour of Parts 21 to 23.

**Evidence.**

- `make sim_noc_router_qos` (`sim/tb_noc_router_qos.v`, in `make verify`): three inputs of
  classes 2, 1 and 0 flood one output for 600 cycles. With strict priority the top class takes
  every slot (600, 0 and 0 packets): the starvation, shown and not assumed. With aging at 20
  cycles every input keeps being served (542, 29 and 29 packets) and the longest gap between one
  input's packets is 21 cycles, against a bound of 28. Two packets that arrive together leave
  in class order, not input order. Mutants are caught: classes ignored, aging never promoting,
  an aged head promoted to the lowest class, the lowest class winning, the wait counter never
  reset, and the aging limit doubled. Two of those survived the first version of the test: it
  checked only completed gaps and that each input got something, so a wait counter that never
  reset (which left one input with a single packet) passed; it now also checks the gap still
  open when the window ends and a minimum share.
- `formal/fv_noc_router_qos.v` (depth 12, boolector, both covers reached): whenever an output
  picks afresh, no input that could have been served has a higher effective class, and among
  equals none has a lower number, with locks and the hold in play; and each input's effective
  class is what it should be (the top class once aged, its own class otherwise). Four mutants
  are refuted. The class-definition assertions were added after a mutant that promoted an aged
  head to the *lowest* class passed the first version: the arbiter was proved consistent with
  its own idea of the class, which proves nothing about whether that idea is right.
- `make sim_noc_xbar` now runs a third copy of the system, the router fabric with the classes
  on (fetch class 3, data and walker 2, debug 1, the NPU's DMA 0, aging at 48 cycles), against
  the bus: every master's reads, every slave's final contents, the AMO counters and the snoop
  and data-master tallies agree. Priorities change when a master is served, never what it reads
  or writes. The per-role cost, in asking cycles per transfer:

  | | data | fetch | walker | debug | NPU |
  |---|---|---|---|---|---|
  | bus | 4.71 | 10.28 | 11.77 | 3.12 | 23.13 |
  | router fabric | 9.07 | 11.29 | 15.46 | 10.14 | 23.22 |
  | router fabric, classes on | 15.03 | 9.21 | 21.87 | 20.87 | 22.65 |

  The classes do what they say: the top class, fetch, is served sooner (11.29 to 9.21,
  better than the bus's 10.28; the test requires it) and the lower ones wait more, the price of
  putting it first. The NPU's bulk DMA barely moves, because it is already last in the fixed
  order the bus uses and the routers inherit: the class does not make it less urgent than it
  was. So "bulk DMA cannot starve CPU fetch" already held; what the classes add is a choice of
  who goes first among the processor-side masters, and with aging a guarantee in the other
  direction, that the NPU cannot be starved by them.
- The default path is unchanged to the cycle: Linux still boots to userspace over the router
  fabric in 183,452,079 cycles (in-order) and 181,536,850 (wide), as in Part 23.

**What this does not establish.** The classes are off in the SoC, and the assignment in the
test is illustrative, not a recommendation: it was chosen to show the mechanism, and it makes
data and debug accesses slower to speed fetch up, which may or may not be wanted. No real workload
has shown a benefit: the NPU DMA racing a hart, interrupt traffic and the concurrent multi-hart
Linux have not yet been run with the classes on. The aging bound is tested, not proved (the
formal property is the pick rule, not a latency bound, which needs fairness assumptions the
bounded check does not give). The rest of Stage 3 is not done: four or more harts, the reservation
monitor and coherence at that size, and the workload measurements.

**Stage 1 - a network interface and a real packet format** (done, in simulation: Parts 15 to 20 made
the interfaces, the packet, the one-node network and a drop-in fabric, compared the
fabric with the bus on random traffic, and ran the whole `make verify` suite and a
Linux boot over it with one and two harts and both cores, at 16 to 41% more cycles, with formal properties of the node and both interfaces; a
CI job for the network build is still open). The boundary
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

**Stage 2 - the smallest router that could replace the bus** (done, in simulation,
at the maintainer's request: Parts 21 to 23 built the router, a fabric on it, and ran the SoC and
Linux over it; the cycles are recorded in Part 23, and the bus is faster; area and timing
are not measured). A real router
(wormhole or virtual-cut-through, 2-5 ports) in the smallest topology that
says anything real - a 2x2 mesh, a small crossbar, or a ring, whichever
Stage 0's own measurements favor - carrying a real first configuration: two
harts, memory, and one accelerator. The classic `wb_interconnect.v` stays
selectable throughout, so every existing test keeps passing against it
while the new path is proven separately. **Done when:** that same
`NUM_HARTS=2` configuration runs correctly over the NoC in simulation,
Linux SMP still reaches userspace on it, and real latency/bandwidth/area
numbers are recorded against the classic bus, not estimated.

**Stage 3 - scaling past the minimal case** (begun at the maintainer's request:
Part 24 built the quality-of-service mechanism; four or more harts, the coherence check at that size and the
workload measurements are still open). Real growth to four or more
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

Stage 0 has begun: `sim/bus_monitor.v` measures the existing shared bus, and Parts 1 to 4 record it under one- and two-hart CoreMark, with and without the data cache, under an NPU DMA job racing a CPU loop, and under one- and two-hart Linux boots. The written Stage 0 decision is in Part 4 and the maintainer confirmed it on 2026-10-03: no network yet, work the levers instead. Stage 0 is closed. Stage 1 is built and its Done-when met in simulation (Parts 15 to 20). Stage 2 is done in simulation (Parts 21 to 23), with the bus winning on cycles. Stage 3 has begun (Part 24: traffic classes in the router). Stages 4 onward are a plan.
