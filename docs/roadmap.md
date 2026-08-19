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

---

## Phase 0 — Proven on silicon

Done, and recorded rather than asserted. A ULX3S with an LFE5U-85F boots from a
preloaded bitstream and passes its acceptance test at 25 MHz; the console
output is in [fpga/README.md](../fpga/README.md), verbatim, with the values
that make it a report about that specific build.

| | |
|---|---|
| Pipeline, M extension, atomics (AMO + LR/SC incl. reservation breaking) | ✅ on hardware |
| Traps, misaligned-access faults, `FENCE.I`, CSR counters, `misa` | ✅ on hardware |
| Wishbone interconnect, on-chip RAM with byte/half lanes | ✅ on hardware |
| CLINT, GPIO through real pads, UART, boot ROM, framebuffer memory | ✅ on hardware |
| Reset and ESP32 hold-off | ✅ on hardware |
| newlib `printf` on hardware | ✅ — was a `.data` init bug, not libc |
| riscv-tests 79/82, Spike co-simulation 82/82, 4 formal proofs | ✅ in CI |

Timing: 30.77 MHz on an 85F, 28.78 MHz on a 45F, against the board's 25 MHz.

---

## Phase 1 — Superscalar issue and out-of-order execution

**This is a redesign, not an increment**, and it is worth being plain about
that before it is worth being enthusiastic about it. Every other phase adds to
the machine in `rtl/cpu_core.v`; this one replaces it. The current core is
1,342 lines of five-stage, single-issue, in-order pipeline, and roughly 140 of
those lines are load-bearing for privilege, the Sv32 MMU and the A extension —
none of which get simpler when instructions stop retiring in the order they
were fetched.

What it actually requires, each item a dependency of the ones after it:

| | Piece | Why it is not optional |
|---|---|---|
| 1 | Register renaming — a RAT and a physical register file | WAR and WAW hazards stop being stalls and start being wrong answers |
| 2 | A reorder buffer | precise traps. This core takes misaligned-access, page and illegal-instruction traps, and `mepc` must name the faulting instruction |
| 3 | Reservation stations or a scoreboard | the wakeup/select loop, which is where the Fmax goes |
| 4 | Multiple execution units | including the existing multi-cycle divider, which already stalls in-order today |
| 5 | A load-store queue with memory disambiguation | loads may not pass an aliasing store; `LR`/`SC` reservations and AMO atomicity must survive reordering |
| 6 | Misprediction recovery | RAT checkpointing or rollback, replacing today's single-cycle flush |
| 7 | Wider fetch and decode | otherwise the back end starves and none of the above shows up as throughput. Stage 1b measured this rather than assuming it, and the number says this row should be first, not last |

And the constraints that do not relax while it happens:

- **Co-simulation still compares every retired instruction against Spike.**
  This is the good news: an out-of-order machine still retires in order, so
  82/82 remains exactly the right check, and it is a brutal one.
- **79/82 architectural tests, 4 formal proofs, and a hardware run** are the
  standing bar. `docs/practices.md` §1 applies with force here: a superscalar
  core that passes because the tests never create the hazard is the most
  expensive kind of test that cannot fail.
- **Timing.** The design closes at 30.77 MHz on an 85F with the critical path
  running from a block RAM read port through the MMU walk result to the PC. A
  wakeup/select loop is a classic critical path, and "it is faster in cycles"
  is not a result until Fmax is measured alongside it.
- **Area.** The 45F is already at 97% block RAM. A physical register file and a
  ROB are not free, and this may become 85F-only.

**Done when:** `make verify_ooo` is green — including 82/82 co-simulation —
with more than one instruction retiring per cycle on CoreMark, and a measured
Fmax and utilisation reported next to the cycle count rather than instead of
it.

On CoreMark today that figure is 47 second-slot retirements out of ~400,000
instructions. Stage 1b's measurements below say why, and say which of the
remaining pieces is actually on the path to changing it.

### How it is being built

`rtl/ooo/core_ooo.v`, a second core with the identical port list, selected by
`make verify CORE=ooo` (or `make verify_ooo`). `rtl/cpu_core.v` is untouched
and stays the default, because it is the only design here that has run on
silicon and evolving it in place would leave no working baseline to diff a
regression against.

| Stage | | Status |
|---|---|---|
| 1a | Parallel core, behaviourally identical, whole suite green | ✅ done |
| 1b | Decoupled fetch buffer, dual issue for independent ALU ops | ✅ done — and see what it measured |
| 1c | Scoreboard: out-of-order completion, in-order retire | in progress — measured and designed, see below |
| 1d | Renaming, reorder buffer, reservation stations, LSQ | after 1c — the ROB 1c builds is most of its foundation |

Stage 1a is deliberately empty of microarchitecture: the file starts as a
byte-for-byte copy of `cpu_core.v` with the module renamed, and the commit
proves the second core passes everything the first does. That is not a
formality. It means every later stage has a harness already known to work, and
a diff that contains only the change being made rather than the change plus a
rewrite of the privilege, MMU and atomics logic that fifteen bugs went into
getting right (`tests/README.md`).

#### Stage 1b: what was built

Complete, and green on the whole suite under `make verify_ooo` — 82/82
co-simulation against Spike, 79/82 architectural tests, 5 formal proofs, and
every SoC, firmware and trap simulation.

| Piece | |
|---|---|
| `rtl/ooo/regfile_wide.v` | 4-read/2-write register file, formal properties in `formal/fv_regfile_wide.v`. Two writes to one architectural register in a cycle is a legal pair (`addi a0,..` ; `addi a0,..`), so port 1 is the younger and wins in both the array and the bypass |
| Fetch buffer | a 4-deep FIFO replacing the single IF/ID register, so the PC advances on whether the *buffer* has room rather than on whether the back end is ready |
| Second decoder and ALU | slot 1 accepts single-cycle integer ALU ops only — OP (minus M), OP-IMM, LUI, AUIPC |
| Issue rule | both halves must be in that class, slot 1 may not read slot 0's destination, and slot 1 gets its own load-use check against EX |
| Redirect and traps across the pair | slot 1 shares slot 0's `commit_ok`, so an interrupt at slot 0 withholds both writes |

The issue rule is narrow on purpose. Requiring *slot 0* to be in slot 1's class
is what keeps the change reviewable: a pair in EX then contains nothing that
can branch, trap on an address, touch memory or take a second cycle, so there
is no second redirect source, no second memory port, and no way for the two
halves to come apart mid-flight.

SFENCE.VMA now redirects to PC+4 on this core, which it does not on
`cpu_core.v`. The fence invalidates the ITLB and the buffer holds up to four
instructions already translated under the mappings being invalidated. The
one-entry IF/ID had the same exposure for a single instruction; a deeper buffer
makes it worth fixing rather than worth noting.

#### Stage 1b: what it measured, which is the point

CoreMark in simulation, one iteration, on the SoC:

| | Cycles | Pairs issued |
|---|---|---|
| In-order core | 867,958 | — |
| + fetch buffer | 867,672 | — |
| + dual issue | 867,590 | 47 |

**0.04% in total.** That number is worth more than the feature is.

The instrumentation says exactly why. `core_ooo.v` counts not just the pairs
formed but the cycles that *offered* a second instruction at all
(`pair_window_count`, reported by `sim/tb_bench.v`): **293 cycles out of
867,590**. The issue rule is not what is rejecting work — it is never asked.
The buffer is almost always empty of a second instruction.

And it has to be. Fetch supplies one instruction per cycle and decode consumes
one per cycle, so in steady state the buffer's occupancy is pinned at one entry
and the only way it ever holds two is in the shadow of a back-end stall. On
this SoC even that window mostly closes, because instruction fetch and data
share one Wishbone bus: the stalls that would let fetch run ahead are usually
data accesses, which are stalling the fetch too. The same measurement with a
zero-latency memory (`make sim CORE=ooo`, `rtl/top.v`) shows the same shape —
36 windows, 4 pairs — so this is structural, not a property of the bus.

**So the conclusion stage 1b actually produced is about stages 1c and 1d.** A
scoreboard, register renaming, a reorder buffer and a load-store queue all
make the back end better at consuming instructions. Nothing in the machine is
short of back-end capacity. Building them next would be optimising the half
that is already waiting.

**What is worth doing next in this phase is widening the front end**, and that
is not a change to `core_ooo.v`: `imem_addr`/`imem_rdata` are a single word,
`cpu_wb.v` holds a one-entry fetch buffer, and it reaches the interconnect and
`wb_ram.v`'s port structure. An instruction cache — currently Phase 4 — is the
other half of the same answer.

Stage 1c below revises this. Measuring the stalls rather than reasoning about
them showed the data bus costs 12.6% against the front end's 10.7%, and that a
reorder buffer aimed at the *bus* instead of at the divider is both cheaper and
worth far more. The front end is still the second thing to fix, not a thing to
skip.

That reordering is not being made here. It is written down because the
measurement is what should decide it, and the measurement now exists.

#### Stage 1c: where the cycles actually are

Stage 1b established that the back end is not what this machine is short of.
Stage 1c starts by answering the question that leaves open. `core_ooo.v` now
charges every stalled cycle to exactly one cause — the innermost one actually
blocking — and `sim/tb_bench.v` reports the breakdown. CoreMark, one
iteration, on the SoC:

| Cause | Cycles | Share | |
|---|---|---|---|
| Total | 867,590 | | |
| Data bus | 109,577 | 12.6% | in 80,738 waits — **1.36 cycles each** |
| Fetch empty | 92,740 | 10.7% | |
| Divide | 2,772 | 0.3% | |
| Load-use | 41 | 0.005% | |
| MMU walk | 0 | — | |

**This reshapes the stage.** A scoreboard's textbook target is the multi-cycle
divide, and the entire divide stall here is 0.3% of runtime — an out-of-order
divider would be worth less than the logic it takes to build, and covering one
33-cycle divide needs a ~33-entry reorder buffer, which is the expensive
dimension: every entry is a forwarding comparator on four read ports.

The cycles are in the data bus, where every load and store freezes the whole
pipeline — fetch included — until Wishbone acknowledges. At 1.36 cycles per
wait the buffer needed to cover one is **two to four entries**, not thirty-two.
So the same mechanism, aimed at the measured stall instead of the textbook one,
is both cheaper and worth roughly forty times more.

The load-use figure is worth reading twice: 41 cycles. It is not that this code
has no load-use hazards, it is that the data-bus stall is already absorbing
them. That is a preview of the ceiling — some of the 109,577 is covering work
the pipeline would otherwise stall on anyway, so the recoverable fraction is
below 12.6% and has to be measured rather than assumed.

#### Stage 1c: the design, and why it stops where it does

**Target:** a load or store waiting on the bus releases the EX stage, so
independent younger instructions execute underneath it, with results retiring
in program order.

**What that requires, in dependency order:**

| | Piece | Note |
|---|---|---|
| 1 | A store buffer | a store writes no register, so it needs no ROB entry at all — and a store that has passed EX cannot fault, since misaligned is caught in EX and page faults come from the MMU before the bus access. This is the cheap half and it is correct on its own |
| 2 | A 1-entry load buffer | the load's result has to land somewhere after EX has moved on |
| 3 | A 4-entry reorder buffer | so younger results retire *after* the load's, in program order |
| 4 | A scoreboard | one pending destination; readers of it stall at issue. WAR and WAW need nothing, because reads happen in order at issue and writes in order at retire |
| 5 | ROB forwarding | four entries against four read ports |

**The obstacle, which is specific and worth writing down.** `rtl/soc/cpu_wb.v`
drives Wishbone combinationally from `dmem_*` — `dwb_cyc`, `dwb_stb`,
`dwb_adr`, `dwb_dat_w` are continuous assignments off the core's `ex_mem_*`
registers, with no request register in the adapter. So the core cannot release
`ex_mem` early unless it holds the request itself, and the mux handing over
from `ex_mem` to the buffer has to keep every bus signal glitch-free across the
changeover cycle.

That is tractable — the buffer latches `ex_mem`'s values at the same edge
`ex_mem` changes, so the muxed output is continuous — but it lands in the same
logic as the LR/SC reservation tracking, which keys off `ex_mem_valid &&
ex_mem_is_sc` and `any_successful_write`. Moving a store into a buffer changes
*when* those fire. Atomics are the part of this core that fifteen bugs went
into getting right (`tests/README.md`), and they are not a thing to convert
without room to verify the conversion.

**Landed for 1c:** the measurement above and the instrumentation that produced
it, and the store buffer — the first piece, and the one that needs no reorder
buffer and no scoreboard.

#### Stage 1c: the store buffer, and what it proved

A store writes no register, and a store that has reached MEM can no longer
fault: misaligned is caught in EX, page faults come out of the MMU before the
access is issued, and the interconnect decodes on `addr[31:24]` alone so an
out-of-range store aliases rather than traps. There is nothing left to report
and nothing to keep it in the pipeline for — only a bus transaction that has to
finish. So it hands the transaction to a one-entry buffer and leaves, and the
buffer drives `dmem_*` until the acknowledgement arrives.

It works, by every measure except the one that matters:

| | Before | After |
|---|---|---|
| Data-bus stall | 109,577 | **78,839** |
| Fetch-empty stall | 92,740 | **111,520** |
| Total cycles | 867,590 | **867,508** |

18,979 stores took the buffered path and 30,738 cycles of data-bus stall
disappeared. The program got **82 cycles** faster.

**The two stalls were overlapping.** Part of the fetch-empty rise is
reclassification — the counters charge each cycle to the innermost blocking
cause, so a cycle that was both bus-stalled and fetch-starved used to be
charged to the bus and is now charged to fetch. That is exactly the finding:
those cycles were never recoverable by fixing the back end, because the front
end was not going to supply an instruction for them either way.

This is the strongest evidence in the project so far that **the machine is
fetch-bound**, and it is evidence by construction rather than by inference:
30,738 cycles of back-end stall were removed and 82 cycles came back.

**So the rest of 1c should wait.** The load buffer, the 4-entry reorder buffer
and its forwarding are several times the logic of the store buffer, and this
experiment predicts the same non-result for them — they remove back-end stalls
that the front end is already covering. The ordering that follows from the
measurement is: instruction cache first (Phase 4), then finish 1c against a
machine that can actually feed it.

**Still to do for 1c, once fetch is fixed:** the load buffer, the 4-entry ROB
and its forwarding, and AMO last, because its two bus phases and its
reservation interlock are the part with no cheap version.

**A note on whether to keep the store buffer.** It costs a handful of registers
and a six-way mux on the memory port for no measured gain today. It is kept
because it is a prerequisite for the rest of 1c and because the experiment it
supports is worth more than its area — but that is a judgement, and if ECP5
utilisation becomes the binding constraint it is the first thing to remove.

#### A defect stage 1b found in its own harness

`rtl/top.v` instantiated `cpu_core` unconditionally, with no `CORE_OOO`
selection. `make sim CORE=ooo` therefore compiled the wide core into the image,
instantiated the in-order one, and reported a pass — for stage 1a and for the
first half of 1b. Every other target in `verify_ooo` goes through
`soc_top.v`, which does select correctly, so the suite as a whole was always
testing the right core; this one testbench was not. It is fixed, and it is the
reason the `CORE` knob's earlier check — breaking `core_ooo.v` on purpose fails
`CORE=ooo` and leaves `CORE=inorder` green — passed while a hole remained: the
check proved the knob selects *somewhere*, not everywhere.

`docs/practices.md` §17 records the other one, which cost more: a register file
whose formal proofs passed against a netlist the simulator never built.

This phase is ordered first because it is the largest and because everything
it touches is easier to change before, not after, the phases below add
external memory, caches and a debug module to the surface it has to preserve.

---

## Phase 2 — Close the boot path

**The SD card is the only part of the boot chain that has never worked on
hardware**, and it is by a wide margin the cheapest open question in the
project.

A 64 GB SDXC card never answers CMD0. That is permitted — SPI mode is optional
above 32 GB — but it has not been distinguished from a wiring fault, because no
smaller card has been tried. `BOARD=ulx3s-cmd0` builds a 60-flip-flop probe,
proven against the card model by `make sim_cmd0`, that answers it in seconds.

Until this closes, every hardware run depends on preloading the program into
the bitstream, which is a bring-up crutch rather than a boot path.

**Done when:** a card ≤32 GB answers CMD0, and `BOARD=ulx3s85` boots the
acceptance test off the card rather than out of block RAM.

---

## Phase 3 — Break the memory ceiling

**64 KB of block RAM is what stands between this and anything Linux-shaped**,
and it is also what forces the firmware to stay as small as it is. 256 KB costs
244 ECP5 block RAMs, which no ECP5 has.

The ULX3S carries 32 MB of SDRAM that nothing here can reach, because there is
no memory controller. `rtl/soc/wb_ram.v` is the seam, and it is deliberately
shaped for this: everything above it speaks Wishbone and knows only a base
address and a size. LiteDRAM via LiteX is the well-trodden path.

This phase blocks Phase 5 entirely and constrains Phase 3.

**Done when:** the SoC runs a program larger than 64 KB from external memory,
and `sim_ramboot`'s 64 KB assumption is no longer the binding constraint.

---

## Phase 4 — Make it fast enough to be interesting

Every fetch and every load goes to the bus, and the interconnect is a shared
bus rather than a crossbar, so a load costs the fetch behind it a cycle.

- **An I-cache alone would be a large win** and is self-contained — it needs no
  other phase.
- **Interrupt-driven UART.** The interrupt is already wired to the PLIC; the
  driver simply polls. Small, independent.
- **Hardware PTE accessed/dirty update** in the MMU walker, so it does not
  fault when software has not pre-set those bits.

CoreMark already runs and validates its own CRCs, so there is a number to move
and a way to tell whether it moved.

**Done when:** a measured CoreMark improvement, reported with the same
disclosure `NOTICE` requires — these are unverified self-measurements, not
EEMBC-certified scores.

---

## Phase 5 — Video out

The framebuffer works and is verified by capturing a frame off the scan-out and
comparing it back (`make sim_video`), and the CPU's path to it is covered on
hardware by the acceptance test. **Nothing is routed to the HDMI pins.**

That needs a PLL and a TMDS serializer, neither of which exists. It is
independent of every other phase, which makes it a good one to pick up in
isolation.

**Done when:** a monitor shows the colour ramp the acceptance test leaves in
the framebuffer.

---

## Phase 6 — Run software this project did not write

OpenSBI **builds** for this core and does not **boot** on it.
[software/opensbi/README.md](../software/opensbi/README.md) is precise about
the split and lists what is missing: a platform port for console, timer and
IPI glue, and more RAM than there is — `fw_jump.bin` is 521 KB, which is
Phase 2's problem.

FreeRTOS or Zephyr is the realistic intermediate milestone, and is reachable
sooner: there is a bus, a timer, an interrupt controller and storage.

**Done when:** OpenSBI prints its banner and hands off to an S-mode payload.

---

## Phase 7 — Debug infrastructure

No JTAG TAP, no RISC-V Debug Module, so debugging is UART `printf` and the
loud trap handler. [docs/debug.md](debug.md) is honest about what that costs.

This is the phase that makes every other phase cheaper, which is an argument
for doing it earlier than its position here suggests. It is placed after the
others because none of them are blocked by it.

---

## Beyond the phases

**PMP**, which [SECURITY.md](../SECURITY.md) lists as a known gap rather than
an oversight.

---

## Known defects

Open, unscheduled, and written down so they are not rediscovered.

**The intermittent `ISA-TIMEOUT` under `make verify`.** Still undiagnosed. It
self-reports rather than hanging silently, which is not the same as being
fixed, and pretending otherwise is exactly the failure mode
[practices.md](practices.md) §7 is about.

**`sim/program.hex` is 440 instructions of recovered source.**
`sim/program.S` reassembles to it byte for byte and `make check-program`
holds that, but the labels are named for byte offsets because the original had
no symbol names to recover. Anyone extending the core regression will be
working with that.
