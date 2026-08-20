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
| riscv-tests 79/82, Spike co-simulation 82/82, 5 formal proofs | ✅ in CI |

Timing: **27.41 MHz on an 85F** against the board's 25 MHz, as of the data
cache and the SDRAM controller. It was 30.77 before those two; the 45F's
28.78 predates them and has not been re-measured. See `docs/toolchain.md` §2.

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
- **79/82 architectural tests, 5 formal proofs, and a hardware run** are the
  standing bar. `docs/practices.md` §1 applies with force here: a superscalar
  core that passes because the tests never create the hazard is the most
  expensive kind of test that cannot fail.
- **Timing.** The design closes at **27.41 MHz** on an 85F — 10% margin over
  the board's 25, down from 23% before the data cache and the SDRAM
  controller. The critical path now runs from the CSR write-enable decode to
  the ID/EX register file's load enable, 11.32 ns of logic against 26.03 ns of
  routing. A wakeup/select loop is a classic critical path, and "it is faster
  in cycles" is not a result until Fmax is measured alongside it — with less
  headroom to spend than this section used to assume.
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
| 1c | Scoreboard: out-of-order completion, in-order retire | ✅ done — store buffer and load-completion buffer, +0.34% |
| 1d | Renaming, reorder buffer, reservation stations, LSQ | designed, **not scheduled** — a redesign with no independently useful piece, and the data cache took its measured ceiling from 2.9% to **0.56%** |

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
| Fetch buffer | a 4-deep FIFO replacing the single IF/ID register, so the PC advances on whether the *buffer* has room rather than on whether the back end is ready. `FB_DEPTH` is genuinely a parameter as of the D-cache change; it was not before, and depths of 8 and 16 have now been run |
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
`wb_ram.v`'s port structure. An instruction cache — currently Phase 3 — is the
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
measurement is: instruction cache first (Phase 3), then finish 1c against a
machine that can actually feed it.

**That was done, and it was right.** The I-cache is in Phase 3 below: 1.79× on
CoreMark, fetch starvation down 90%, and stage 1b's dual issue going from 47
pairs to 19,872 without a line of it changing. The load-use stall this stage
measured at 41 cycles is now 27,211, exactly as §18 predicted — it was always
there, hidden behind a bus stall. That, not the reorder buffer, is what the
rest of 1c should be aimed at when it resumes.

#### Stage 1c: the load-completion buffer, rejected and then reinstated

With the front end fixed, the load buffer was the piece left. It was measured
first, as everything in this phase now is:

| CoreMark, post-I-cache | Cycles |
|---|---|
| Data-bus stall caused by a load | 65,083 |
| ...of which an independent simple ALU op was in EX | **19,188** |

19,188 cycles is 4.0% of runtime — the first ceiling in this stage worth
building for. It was built, and then it was rejected on a bad reading, and then
that was corrected. All three steps are here because the middle one shipped.

**The rejection.** The first working build measured 2.5% slower *and* failed
CoreMark's CRC. The cycle count was recorded as unusable — an incorrect machine
is not a measurement — and then reasoned from anyway through a proxy:
dual-issue pairs had fallen from 19,872 to 18,386, so the deferral must be
stealing slot 1's pipeline from dual issue, so the loss must be structural. The
stage was closed without the feature.

**The correction.** The slowdown was the bug, not the contention. Deferring
releases `id_ex_stall`, which is exactly the condition that lets a dual-issue
pair be latched — and only the pair's *older* half was checked against the
outstanding load. The younger half arrived in EX while the load was still in
MEM and took the load's address off the EX/MEM forwarding path.

| | Baseline | Buggy build | Corrected |
|---|---|---|---|
| Total cycles | 484,306 | 496,228 | **482,674** |
| CoreMark CRC | valid | **failed** | valid |
| Dual-issue pairs | 19,872 | 18,386 | 18,276 |
| Deferrals taken | — | 4,616 | 4,205 of 19,118 |

**0.34%.** The contention was real — pairs still fall by 1,596 — it simply does
not dominate. `docs/practices.md` §20 records what went wrong in the reasoning.

**What the numbers say about stage 1d.** Only 4,205 of 19,118 opportunities are
taken, because a deferral needs slot 1's pipeline free and the successor pair
independent of the load. The remaining ~15,000 cycles are what a completion
slot of its own would reach, and that is a reorder buffer entry. The ceiling is
still 4.0% and about a tenth of it is collected; the rest is 1d's to argue for.

**The blind spot that let it through.** The missing hazard check needs a load
followed by a pair whose younger half depends on it. riscv-tests co-simulates
**82/82** against Spike with the bug present. CoreMark's list and state passes
hit it within a few thousand instructions. Co-simulation is the strongest layer
this project has and it is still only as good as the instruction mix it is
given.

#### Stage 1d: which of its four pieces actually carries the value

Phase 1's opening table lists what out-of-order execution requires: renaming, a
reorder buffer, reservation stations, multiple execution units, a load-store
queue, misprediction recovery, wider fetch. That list is a dependency order,
not a value order, and until now nothing here said which piece was worth
building first.

The load-completion buffer's misses answer it. Of 19,118 opportunities:

| | Cycles | |
|---|---|---|
| Taken | 4,205 | |
| Missed — **successor depends on the load** | **14,231** | 74% |
| Missed — slot 1's pipeline already in use | 682 | 3.6% |

**The reorder buffer is not where the value is.** The shared completion slot —
the thing stage 1c was rejected over, and the thing a ROB entry exists to fix —
costs 682 cycles. A dedicated slot would need a third writeback path, a third
register write port and `regfile_wide` going from 2W to 3W, to recover 0.14%.

The 14,231 cycles are blocked because the instruction that would take EX's
place reads the outstanding load. No completion slot helps that: the machine
needs to issue a *later*, independent instruction instead, which is
out-of-order issue, which is reservation stations and the renaming that makes
them safe.

So stage 1d's order is the reverse of the dependency list's convenience:
reservation stations carry ~2.9%, the ROB carries 0.14% and exists to make
traps precise once issue is out of order, and renaming exists to make both
correct. The ROB is still required — it is just required *by* the thing worth
building, not worth building on its own.

#### Stage 1d: why it cannot be staged, and what it needs

Stages 1b and 1c were built as small increments, each one green on the whole
suite before the next started. That was possible because each had a piece that
was independently useful: a fetch buffer works without dual issue, a store
buffer works without a reorder buffer. **Stage 1d has no such piece**, and it
is worth writing down why, because the instinct to slice it will not survive
contact with the pipeline.

| Piece | On its own | |
|---|---|---|
| Register renaming | nothing | WAR and WAW are already impossible with in-order issue and in-order writeback. Renaming exists to make out-of-order issue *safe*, and buys nothing before it |
| Scoreboard | nothing | tracks pending writes so a reader can stall. In-order issue already stalls readers |
| Reorder buffer | 0.14% | measured: 682 cycles of slot contention. It is a precondition for out-of-order issue, not a feature |
| Reservation stations | **~2.9%** | the 14,231 cycles where the successor depends on the load. But issuing out of order requires the ROB for retire order and renaming for correctness |
| Load-store queue | unknown | needed before a second memory access can be in flight; `cpu_wb.v` issues one transaction at a time, so it is blocked on the bus adapter too |

Everything valuable in the list depends on two things that are worth nothing
until it exists. That is the definition of a redesign, which is what this
file said Phase 1 was at the top, and 1d is the part where that becomes
unavoidable rather than convenient to defer.

**What it needs, in the order it has to be built:** a ROB with its own entries
(not slot 1's pipeline, which dual issue is using); a RAT and physical register
file; reservation stations feeding the existing ALU, the divider and the memory
port; and misprediction recovery by RAT checkpoint rather than the current
single-cycle flush. None of it can be verified in isolation, so it lands as one
change or not at all — and `make verify_ooo` plus the CoreMark CRC gate are the
bar it has to clear on the first commit that includes any of it.

#### The comparison happened, and stage 1d lost it

The section above said: measure a data cache before committing to 1d, because
the data-bus stall was 66,316 cycles against 1d's 14,231-cycle ceiling. That
measurement is now done — see Phase 3 — and it did not go the way the
dependency list implied.

**A data cache in the bus adapter cost about sixty lines, changed neither core,
and was worth 9.9% on the wide core and 12.3% on the in-order one.** It also
took the number stage 1d was scheduled on from 14,231 cycles to **1,138**.

| | Before the D-cache | After |
|---|---|---|
| Successor depends on an outstanding load | 14,231 | **1,138** |
| Load-use stall | 27,210 | 27,226 |

So the case for reservation stations moved. It is no longer "a load sits on the
bus and its successor cannot proceed" — that load now returns in the cycle it
is asked for, 96.3% of the time. It is the plain load-use bubble, which is
structural in a five-stage pipeline and is now the largest single stall at
27,226 cycles, 6.3% of the total.

Which raises exactly the question stage 1c's misses raised, one level up: when
the pipeline stalls on a load-use hazard, **is there anything else it could
have run?** `loaduse_oo_*` in `rtl/ooo/core_ooo.v` answers it directly. On each
such stall it walks the fetch buffer behind the stalled instruction and asks
whether any entry could have issued instead — none of its sources written by
the load in EX, by the stalled instruction, or by anything in between:

| Of 27,226 load-use stall cycles | | | What reaches it |
|---|---|---|---|
| An independent **ALU op** was in the window | **1,303** | 4.8% | reservation stations + renaming + ROB |
| Only a load, store or branch was | 14,796 | 54% | …**plus** a load-store queue and checkpointed recovery |
| **Nothing independent was there at all** | **11,128** | **41%** | nothing. Out-of-order issue cannot help |

The window was not the limiting factor, and that was checked rather than
assumed. `FB_DEPTH` is a parameter, so the same run at 8 and 16 entries asks
whether a bigger instruction window finds more:

| Fetch buffer | Candidates behind the stall | ALU op available | Nothing available | Cycles |
|---|---|---|---|---|
| 4 | 2.4 | 1,303 | 11,128 | 434,822 |
| 8 | 5.1 | 1,721 | 10,652 | 434,710 |
| 16 | 9.8 | **1,743** | 10,654 | 434,704 |

**Quadrupling the window is worth 440 cycles of extra opportunity — 0.1%** —
and the "nothing independent at all" bucket barely moves. The instruction-level
parallelism around a load-use hazard in this program is genuinely thin, not
window-limited, which is the objection that would otherwise have been left
hanging over the table above.

(That experiment could not be run before this change. `FB_DEPTH` read like a
parameter and was not one: `fb_head <= fb_head + fb_pop_n[FB_AW-1:0]` is an
out-of-range part-select for any `FB_AW` above 2, which Verilog resolves to x
rather than to an error. At `FB_DEPTH=8` the head pointer went x on the first
pop and the core executed nothing at all — every stall counter read zero, which
is what made it obvious. Fixed here, and depth 4 is bit-for-bit unchanged at
434,822 cycles.)

**That gives stage 1d a measured ceiling for the first time:**

| Scope | Cycles reachable | |
|---|---|---|
| Reservation stations + ROB + renaming, no LSQ | 1,303 + 1,138 = **2,441** | **0.56%** |
| Everything, including an LSQ and speculative control | + 14,796 = **17,237** | **4.0%** |

Both are ceilings in the strict sense: neither checks that the candidate's own
operands are ready, that a functional unit is free, or that issuing it moves
the stall rather than removing it. The real numbers are lower.

**Against that, the thing this stage costs.** 1d is a redesign of a
2,000-line core with no independently verifiable piece (the section above);
its wakeup/select loop is a classic critical path on a design that closes at
27.41 MHz today, with 10% margin over the board's clock; and a physical register file plus a ROB land on a 45F that is
already at 97% block RAM. Sixty lines in the bus adapter were worth 9.9%.

**Stage 1d is therefore not scheduled.** Not "designed and deferred" — the
design in the two sections above stands and is what it would be built from —
but the number that justified it was 2.9% and is now 0.56%, and there are
cheaper things above it in the same file. What would change this:

- **A different workload.** CoreMark is the only program measured here. A
  pointer-chasing or floating-point-heavy workload has a different independent-
  instruction density, and 41%-nothing-available is a property of this
  benchmark, not of the ISA. `make coremark` is one program; the honest read is
  that 1d is unjustified *on the evidence that exists*.
- **~~A deeper window~~** — measured above. 4 → 16 entries is worth 0.1%.
- **A second memory port or a wider fetch**, either of which changes what the
  back end is starved of. Neither is measured; both change what the back end
  is starved of, which is the only thing that has moved this number so far.

**Above it in the queue, on measured evidence:**

| | Cycles | |
|---|---|---|
| Load-use, with nothing independent available | 11,128 | unreachable by issue policy; needs a shorter load or a compiler that schedules |
| Fetch-empty | 7,435 | wider fetch, or spatial locality in the I-cache |
| Data-bus, post-cache | 5,803 | spatial locality in the D-cache |
| Divide | 2,772 | a faster divider — bounded, local, and nothing else depends on it |

**Still open in Phase 1, and cheaper than 1d:** dual issue pairs on 5.6% of the
windows that offer a pair. The counters that say which clause of the issue rule
is refusing them are in `rtl/ooo/core_ooo.v` as of this change, and that
breakdown is the next thing worth acting on in this phase.


---

## Phase 2 — Break the memory ceiling

**64 KB of block RAM is what stood between this and anything Linux-shaped.**
256 KB costs 244 ECP5 block RAMs, which no ECP5 has, and the ULX3S's 32 MB of
SDRAM was unreachable because there was no memory controller.

There is one now. `rtl/soc/wb_sdram.v` is a Wishbone slave in front of a
16-bit SDR SDRAM, and `make sim_sdramboot` runs the SoC out of it:

```
=== SDRAM acceptance test ===
Running from 0x90000000 .. 0x90080228
Loaded image is 99 KB, against 64 KB of block RAM

  code is above SDRAM_BASE      ok
  image exceeds block RAM       ok
  96 KB .rodata reads back      ok
  256 KB unique addresses       ok
  byte lanes                    ok
  halfword lanes                ok
  block RAM still reachable     ok

SDRAM-TEST: PASS
```

### Hand-written, not LiteDRAM

This file previously said "LiteDRAM via LiteX is the well-trodden path", and
for DDR it would be the only sane one. This is *SDR*: no read levelling, no
write levelling, no calibration, no PHY training — a command truth table and
six timing numbers. Against that, LiteX is a Python build dependency producing
a blob this repo could not simulate against its own model, could not put
through CI without installing a generator, and could not gate. The controller
and its model together are about 750 lines that every existing verification
layer reaches.

| | |
|---|---|
| `rtl/soc/wb_sdram.v` | the controller: power-up, one open row, burst-of-2, byte lanes via DQM, refresh every 7.8 µs |
| `sim/sdram_model.v` | a 32 MB part that **refuses illegal protocol** rather than tolerating it |
| `sim/tb_sdram.v` | `make sim_sdram` — the controller at the bus, no CPU, no toolchain |
| `sim/tb_sdramboot.v` | `make sim_sdramboot` — the SoC executing from SDRAM |
| `software/soc/sdramtest.c` + `sdramtable.S` | a program that **cannot** be a block RAM program |

### The model is the interesting half

A permissive memory model would let almost any controller pass, because every
interesting SDRAM bug is a *protocol* bug and none of them corrupt data in a
way a write-then-read test notices in simulation. They corrupt data on a
board, at temperature, weeks later. So the model checks tRCD, tRP, tRC, tRFC,
tMRD, the 100 µs power-up interval, the refresh interval, row ownership, burst
containment and the A[10] auto-precharge bit, and it takes CAS latency and
burst length **from the mode register the controller actually programmed**
rather than from what the model would prefer.

Four deliberate breaks, each red:

| Break | What it printed |
|---|---|
| Power-up wait cut from 100 µs to 10 µs | `command issued before the 100 us power-up interval` |
| Refresh never becomes due | `no AUTO REFRESH within 2x tREFI - rows are losing data` |
| Read captured one cycle early | `[00000000] = beefzzzz, expected deadbeef` |
| High beat masked by the low byte lanes | `[00000200] = 11xx3399, expected 11223399` |

The third is the one worth looking at twice: the low halfword arrives in the
high position and the second capture finds the bus already tristated. That is
what a CAS-latency error looks like, and no amount of staring at a controller
finds it as fast as one line of output does.

tRAS and tWR pass with margin and could not be made to fire by breaking the
controller, so they were checked the other way round — raised past what the
controller does, both fire. A check that cannot go red is not a check.

**And the model still did not find the one real bug.** The refresh interval
timer and the state machine both wrote `refresh_due`; the state machine's
clear won, so a tick landing on the exact cycle a refresh was issued dropped
the newly-owed refresh. One cycle in 195, found by reading the controller. A
model watches the wire, and on any given run a refresh did arrive in time —
it has no opinion about whether the controller meant to and lost track. See
`docs/practices.md` §22.

### Why a 96 KB table rather than a 256 KB memory test

Because a memory test would have passed on block RAM. `wb_interconnect.v`
decodes `addr[31:24]` alone, so the whole 16 MB window reaches whichever slave
answers, and a slave indexes with only the address bits its size needs — a
sweep over 256 KB of *block RAM* completes and reports success while quietly
writing the same 64 KB four times (`sim/tb_ramboot.v`'s header is about
exactly this). Only a program whose own image exceeds block RAM cannot be a
block RAM program, so `software/soc/sdramtable.S` is 96 KB of `.rodata` where
each word holds its own byte offset. It checks itself, it needs no generator
and no committed blob, and it makes the link fail rather than shrink.

### What it costs, and the one open row

| | |
|---|---|
| Row hit | ~6 cycles |
| Row miss | ~8 cycles, one precharge and one activate |
| Refresh | every 195 cycles at 25 MHz, ~4 cycles |

One open row, not four per bank. Per-bank open rows would remove the
precharge from an interleaved pattern — and `rtl/soc/cpu_wb.v` now holds an
instruction cache and a data cache that between them absorb 96.3% of loads and
the whole of every loop, so what reaches this controller is mostly sequential
cache misses. That is an argument for measuring before building it, which is
this phase's own lesson applied to itself, not an argument that it would not
help.

### Two things this deliberately did not do

**SDRAM sits at 0x9000_0000 alongside block RAM, not instead of it.**
`wb_ram.v` carries the two page-table walker ports on its second block RAM
port. An SDRAM has no second port, so putting the walkers there means
arbitrating three requesters into one controller and running every Sv32 test
through SDRAM latency. Keeping both memories made this an addition that cannot
regress anything — the whole existing suite is untouched and green — and
leaves **Sv32 page tables in SDRAM** as the next step, named rather than
attempted in the same change.

**The window is 16 MB, not 32.** One base byte is one 16 MB slave, because the
interconnect decodes `addr[31:24]`. That is 256× block RAM and 30× the 521 KB
`fw_jump.bin` that Phase 5 needs, so it is not the binding constraint on
anything — but the part is 32 MB and half of it is unreachable until that
decode grows a per-slave mask.

### Wired to a board, but not yet run on one

The pins are placed. `fpga/constraints/ulx3s.lpf` carries all 39 SDRAM
signals, copied verbatim from the board's own `ulx3s_v20.lpf` and cross-checked
line-for-line against litex-boards' `radiona_ulx3s.py` — the same two-source
rule the SD pins went through, and the two agree on every one, including
`sdram_a[10]` at N19, the one pin that breaks the otherwise sequential run and
therefore the one a transcription would get wrong without noticing.

**Measured, on an LFE5U-85F with `--lpf-allow-unconstrained` not set:**

| | Fmax | LUT | Block RAM |
|---|---|---|---|
| Full SoC (`BOARD=ulx3s85-sdramcheck`) | **27.41 MHz** — PASS at 25 | 20% | 51% |
| The probe (`BOARD=ulx3s-sdram`) | 95.79 MHz | <1% | 0% |

27.41 MHz is **down from 30.77**, and this is the first place-and-route since
both the data cache and this controller landed, so the drop belongs to the pair
of them. The critical path is in neither: it runs from the CSR write-enable
decode to the ID/EX register file's load enable, 11.32 ns of logic against
26.03 ns of routing. Margin at the board's 25 MHz is now 10% rather than 23%.

**None of that was evidence about a chip**, and the chip settled it in two
runs. The first bitstream mostly worked and returned one wrong word in a
thousand — a read capture point sitting 5.4 ns before the part swapped one
burst beat for the next, and a write path with no hold margin at all because
the clock and the data left the FPGA together. `fpga/sdram_clk_out.v` now
clocks the part half a period out through an `ODDRX1F` and
`rtl/soc/wb_sdram.v` captures a cycle earlier to match; the two are a matched
pair. The re-run reads and writes **256 KB of external SDRAM, every address
distinct, with byte and halfword lanes and refresh** — `SDRAM-CHECK: PASS`.
Both logs, the arithmetic and what it cost to read the evidence properly are
in `fpga/README.md` and `docs/practices.md` §23.

Bring-up is two bitstreams, in the order that narrows the problem —
`fpga/README.md` has the procedure and the LED table:

| | |
|---|---|
| `BOARD=ulx3s-sdram` | `fpga/ulx3s_sdram.v` — no CPU at all. Five cumulative LEDs: power-up, one word, walking ones over the data, one address per address bit, and survival across a ~100 ms idle, which is what proves refresh |
| `BOARD=ulx3s85-sdramcheck` | `software/soc/sdramcheck.c` — the CPU, caches and interconnect in the path, running from block RAM and hammering 256 KB of SDRAM |

Both have simulations (`make sim_sdramprobe`, `make sim_sdramcheck`) and both
are gated in CI, because a bring-up instrument that is itself wrong turns "the
memory does not work" into a hunt through the memory, the pinout and the clock.

**The thing most likely to need attention was `sdram_clk`**, and it was. That
paragraph used to say a straight assignment "usually works, and usually is not
a measurement". The measurement arrived and it did not work.

### Why nothing runs *from* SDRAM on a board yet

A bitstream initialises block RAM at FPGA configuration time. SDRAM is external
and comes up holding nothing, so `sdramtest.c` — linked at 0x9000_0000 and
preloaded into the model in simulation — has no way to get there. Running code
out of SDRAM on hardware needs a loader: the SD path (Phase 7, and CMD0
currently goes unanswered) or a UART one. Neither exists. That is a separate
piece of work, not a missing line in this one.

**Done when:** ~~the SoC runs a program larger than 64 KB from external
memory~~ — done in simulation, and **the memory itself is proven on silicon**:
256 KB read and written through the CPU, the caches and the interconnect on a
ULX3S v3.1.8 / LFE5U-85F.

**Still open**, and worth keeping separate because they are different sizes of
job:

| | |
|---|---|
| A loader, so code can run *from* SDRAM on a board | a bitstream initialises block RAM at configuration time and SDRAM comes up empty. Needs the SD path (Phase 7) or a UART loader |
| Sv32 page tables in SDRAM | `wb_ram.v` carries the walker ports on block RAM's second port, and an SDRAM has none |
| The 16 MB window | one base byte is one 16 MB slave under this decode; the part is 32 MB |


---

## Phase 3 — Make it fast enough to be interesting

Every fetch and every load goes to the bus, and the interconnect is a shared
bus rather than a crossbar, so a load costs the fetch behind it a cycle.

### The I-cache: done, and it was the whole game

`rtl/soc/cpu_wb.v` now holds a 256-entry direct-mapped instruction cache, one
word per line, replacing the single tagged word it used to buffer. It was
brought forward ahead of the rest of Phase 1 because stage 1c's experiment said
to — see below — and the result says that was right:

| CoreMark, one iteration, on the SoC | Cycles | |
|---|---|---|
| In-order core, no I-cache | 867,958 | the baseline everything so far was measured against |
| Wide core, no I-cache | 867,508 | dual issue + store buffer, worth **0.05%** |
| In-order core, with the I-cache | 517,588 | **1.68×** from the cache alone |
| **Wide core, with the I-cache** | **484,306** | **1.79×**, and now dual issue + store buffer are worth **6.9%** |

Read the last column downward. Stage 1b and stage 1c were worth 0.05% before
the cache and 6.9% after it — the same RTL, unmodified, measured against a
machine that can feed it. Two cheap experiments established that the front end
was the constraint, and the third confirmed it by removing it.

The knock-on effects are the interesting part:

| | Before | After |
|---|---|---|
| Fetch-empty stall | 111,520 | **11,903** |
| Data-bus stall | 78,839 | 66,316 |
| Load-use stall | 41 | **27,211** |
| Dual-issue pairs | 47 | **19,872** |
| Cycles offering a second instruction | 293 | **182,627** |

**Stage 1b's dual issue went from 47 pairs to 19,872 without a line of it
changing.** The fetch buffer could never accumulate while fetch was the
bottleneck; with cache hits served in the cycle they are asked for, fetch runs
ahead of decode and the issue rule finally has pairs to find. The work was not
wasted, it was stranded.

The load-use stall going from 41 to 27,211 is the same effect in reverse, and
was predicted: `docs/practices.md` §18 said some of the data-bus stall was
covering work the pipeline would have stalled on anyway. Now that fetch keeps
up, those hazards are exposed and are the next thing worth attacking.

**One word per line, deliberately.** No fill FSM, no burst: a miss fetches the
word that missed using the same single-transfer machinery the one-entry buffer
used. That buys nothing on straight-line code and buys the whole of a loop.
Whether spatial locality is worth a fill state machine on top is now a question
with a number attached rather than a guess.

**Not measured:** Fmax and ECP5 utilisation. The arrays are read
asynchronously — a synchronous block-RAM read would add a wait state to every
fetch including hits, and the core's fetch buffer cannot hide it because the PC
only advances when the fetch is not stalled — so they infer distributed LUT RAM.
256 entries is roughly 900 LUT4s against an 85F's 84k, but that is an estimate,
not a place-and-route result, and the 45F was already at 97% block RAM before
this. Nothing here has been through synthesis.

### The D-cache: 1.11x more, and it moved where the next work is

`rtl/soc/cpu_wb.v` now holds a second cache, on the data port, built to the
same shape as the first: 256 entries, direct-mapped, one word per line, read
asynchronously so a hit costs no wait state. It is in the *bus adapter*, not in
either core, so one copy serves both and neither core changed a line.

| CoreMark, one iteration, on the SoC | Cycles | |
|---|---|---|
| In-order core, I-cache only | 517,588 | |
| In-order core, **+ D-cache** | **453,844** | **1.14×** |
| Wide core, I-cache only | 482,674 | 1b + 1c, with the load-completion buffer |
| **Wide core, + D-cache** | **434,822** | **1.11×**; **1.19×** over the in-order core with only an I-cache |

**Write-through, allocate only on a full-word store miss.** Not the fast
policy — the one that is coherent with the rest of this system for free, which
matters more than the stores it doesn't accelerate:

- the MMU's page-table walkers read RAM through `wb_ram.v`'s **second port**,
  not through this bus. A write-back cache could hold a PTE no walker can see.
- `wb_framebuffer.v` is scanned out by video logic that never touches this
  adapter, so a pixel in a dirty line would never appear.
- UART, CLINT, PLIC, SPI and GPIO are excluded by address rather than by
  policy, but a write-back cache would have to get both right.

With every write reaching memory, this cache only ever mirrors the truth.
Nothing to flush, no dirty bit, no action on FENCE, SFENCE.VMA or a context
switch — the tags are physical, because `dmem_addr` is already translated when
it arrives. Allocating on a *full-word* store miss is the one piece of extra
reach that needs no justification beyond arithmetic: after the acknowledgement
memory holds exactly the store data, so caching it needs no bus read.

**256 entries is the knee, and it was measured rather than chosen:**

| Entries | Data | Load hit rate | Cycles |
|---|---|---|---|
| 128 | 512 B | 93.6% | 435,750 |
| **256** | **1 KB** | **96.3%** | **434,822** |
| 512 | 2 KB | 97.4% | 434,150 |
| 1024 | 4 KB | 98.7% | 433,454 |

Four times the LUT RAM buys 0.31%. The residual misses are compulsory, and the
answer to those is spatial locality — a fill state machine — not capacity.

**What it did to the stall profile is the part that matters**, because it is
what the rest of the roadmap is scheduled against:

| Wide core | Before D-cache | After | |
|---|---|---|---|
| Data-bus stall | 66,302 | **5,803** | −91% |
| Fetch-empty stall | 12,328 | **7,435** | hits stop contending for the bus |
| Load-use stall | 27,210 | 27,226 | unchanged, and now the largest |
| Deferral opportunity (1c) | 19,118 | **1,711** | |
| — successor depends on the load | 14,231 | **1,138** | the number stage 1d was scheduled on |

Both columns are from the same build, which is why a few of them differ by
tens of cycles from the I-cache section above — that one predates the
load-completion buffer, and 66,316 there is 66,302 here.

**That last row is why this measurement was made before stage 1d and not
after.** 14,231 cycles was the whole case for reservation stations. A cache in
the bus adapter removed 92% of it without touching the core.

**Not measured:** Fmax and ECP5 utilisation, same as the I-cache and for the
same reason — these arrays are asynchronously read, so they infer distributed
LUT RAM rather than block RAM, and 256 entries of data plus 22-bit tags is
roughly another 900 LUT4s on an estimate rather than a place-and-route result.
Two caches now rest on that estimate instead of one.

- **~~An I-cache alone would be a large win~~** — done, above.
- **~~A D-cache~~** — done, above.
- **Spatial locality: more than one word per line.** Both caches fetch exactly
  the word that missed. The D-cache's residual 3.7% miss rate is compulsory,
  which is the miss a fill state machine reaches and a bigger cache does not.
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

## Phase 4 — Video out

The framebuffer works and is verified by capturing a frame off the scan-out and
comparing it back (`make sim_video`), and the CPU's path to it is covered on
hardware by the acceptance test. **Nothing is routed to the HDMI pins.**

That needs a PLL and a TMDS serializer, neither of which exists. It is
independent of every other phase, which makes it a good one to pick up in
isolation.

**Done when:** a monitor shows the colour ramp the acceptance test leaves in
the framebuffer.

---

## Phase 5 — Run software this project did not write

OpenSBI **builds** for this core and does not **boot** on it.
[software/opensbi/README.md](../software/opensbi/README.md) is precise about
the split and lists what is missing: a platform port for console, timer and
IPI glue, and a way to get a 521 KB `fw_jump.bin` onto the board.

**The memory half of that is answered.** Phase 2's SDRAM is proven on silicon
and reaches 16 MB, which is thirty times what `fw_jump.bin` needs. What is not
answered is *loading* it there: a bitstream initialises block RAM at FPGA
configuration time and SDRAM comes up empty, so this now waits on a boot path
(Phase 7) or a UART loader rather than on memory that does not exist.

FreeRTOS or Zephyr is the realistic intermediate milestone, and is reachable
sooner: there is a bus, a timer, an interrupt controller and storage.

**Done when:** OpenSBI prints its banner and hands off to an S-mode payload.

---

## Phase 6 — Debug infrastructure

No JTAG TAP, no RISC-V Debug Module, so debugging is UART `printf` and the
loud trap handler. [docs/debug.md](debug.md) is honest about what that costs.

This is the phase that makes every other phase cheaper, which is an argument
for doing it earlier than its position here suggests. It is placed after the
others because none of them are blocked by it.

---

## Phase 7 — Close the boot path

Moved to last, and not because it got harder. This file orders phases by what
each one unblocks, and nothing above is blocked by the SD card: every hardware
run preloads the program into the bitstream, and that works. It is the only
phase whose absence costs convenience rather than capability.

**The SD card is the only part of the boot chain that has never worked on
hardware**, and it is by a wide margin the cheapest open question in the
project — which is the argument for doing it out of order, below.

A 64 GB SDXC card never answers CMD0. That is permitted — SPI mode is optional
above 32 GB — but it has not been distinguished from a wiring fault, because no
smaller card has been tried. `BOARD=ulx3s-cmd0` builds a 60-flip-flop probe,
proven against the card model by `make sim_cmd0`, that answers it in seconds.

Until this closes, every hardware run depends on preloading the program into
the bitstream, which is a bring-up crutch rather than a boot path. That is the
argument for doing it early despite its position: a crutch that works is still
a crutch, and the phases above are all easier to test on hardware without
one.

**Done when:** a card ≤32 GB answers CMD0, and `BOARD=ulx3s85` boots the
acceptance test off the card rather than out of block RAM.

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
