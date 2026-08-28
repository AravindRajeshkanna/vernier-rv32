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
| 1d | Renaming, reorder buffer, reservation stations, LSQ | **built anyway** — see below. `make verify_ooo` fully green; CoreMark **448,346 cycles**, slower than the cheaper stage 1b+1c core it was meant to replace; Linux still does not boot to userspace |

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

#### Stage 1d was built anyway

The section above is what the numbers said before anyone wrote a line of it.
It was built anyway, on top of the identical-port-list `rtl/ooo/core_ooo.v`
stage 1b/1c had already been using, with the RAT, physical register file, ROB
and general out-of-order issue the earlier sections describe. What follows is
what actually happened, measured the same way the case against it was
measured.

**`make verify_ooo`.** riscv-tests 81/81 (up from 79/81 — see the dirty-bit
note below), cosim 83/84, formal 5/5 proved, 0 refuted, `sim_uartload`
passing. Fully green, with a fourth bug behind the last of those numbers that
is worth naming precisely rather than folding into a bare pass count:

- **`sim_uartload` used to fail, deterministically, every run.** Root cause:
  an out-of-order load can issue speculatively — before an older, unresolved
  branch is known to be correctly predicted — and speculation is free for
  ordinary RAM (a squashed load's result is just discarded) but not for a
  register with a real read side effect. The boot ROM's UART receive loop
  polls the UART's status register in a tight loop whose exit branch
  mispredicts on the very last byte it needs; the load that reads the data
  register on the mispredicted path had already dequeued the real byte from
  the UART's one-deep receive buffer by the time the misprediction was
  discovered and the load's own result discarded. The byte was gone —
  nothing puts it back — and the ROM waited forever for a byte that already
  arrived and was thrown away. Traced to the instruction level: the loop
  needs exactly 15 reads of the UART's RBR register to fill a 16-byte header
  buffer (1 from a leading skip-probe check, 15 from the main loop); the
  hardware showed the register genuinely read 15 times, but only 14 of those
  reads ever reached the loop's own store-and-increment bookkeeping.
  `sim_uart16550`, `sim_uartirq` and `sim_plic` all passed regardless,
  because none of them poll a side-effecting register through a branch that
  mispredicts on exit. This was a real, general hazard in the out-of-order
  load path, not specific to the UART — it would reach any MMIO register
  with a read side effect (the PLIC's claim register is the other one this
  SoC has) under the right branch pattern.
  **Fixed.** `core_ooo.v`'s out-of-order load-issue scan now excludes any
  address outside RAM (`0x80xxxxxx`) or the boot ROM (`0x00xxxxxx`) —
  mirroring `cpu_wb.v`'s own `dc_cacheable` test exactly, the same
  address-range check that already keeps the D-cache from caching a
  side-effecting register, applied here to keep the out-of-order load port
  from *speculating* on one. The exclusion sits at scan/discovery time, not
  at the port's own go-signal (`loadL_can_start`, which already excludes the
  one other case a load must not start out of order — an active Sv32 walk):
  gating discovery instead lets a side-effecting load simply be skipped in
  favor of a younger, safe one also waiting in the ROB, the same way an
  address-hazard-blocked candidate already is, rather than being "found" and
  then perpetually refused — which would have serialized the whole
  out-of-order load port behind it until it retired. `load_via_head`
  (previously only for a load needing Sv32 translation) picks up a
  side-effecting load the same way once it becomes the ROB head: only once
  it is provably the oldest instruction, with no older branch left that
  could still squash it, does it actually touch the register. CoreMark is
  unaffected (448,346 cycles against 448,728 before — noise, not a
  regression; CoreMark's own workload has nothing MMIO-heavy for this
  exclusion to touch).

Three other real bugs were found and fixed getting this far, all keyed off the
same root idea: out-of-order issue means an instruction can compute its
answer *before* the core has proven it is allowed to. **A store or load whose
address needed Sv32 translation was letting its real bus request —
`dmem_we`/`dmem_re`, the actual memory access — fire before
`head_mmu_wait_stall` cleared**, using whatever `mmu.v` happened to be
outputting mid-walk. On a TLB hit this raced harmlessly (the answer is ready
the same cycle). On a TLB miss it was not: the CPU asserted a write with a
garbage, mid-walk address, and because `wb_interconnect.v` gives the CPU's
own data master strict priority over the page-table walker (by design, so an
atomic's read-modify-write cannot be preempted mid-gap), that spurious write
held the bus and starved the walker of the very access that would have
resolved the address and cleared the stall — a self-sustaining deadlock,
reachable only on a genuine TLB miss under real concurrent bus traffic, which
is why the small synthetic Sv32 test in `tb_top.v` never found it but a real
Linux boot did (below). Fixed by also requiring `!head_mmu_wait_stall` before
a store, a head-issued load, or an AMO may own the bus. That fix alone left a
second, narrower race: `head_mmu_wait_stall` clears the instant the walk
resolves, *fault or not*, so a store whose translation resolved to a page
fault could still reach the bus on the very same cycle — this time with a
*real*, correctly-translated address, since the walk had by then actually
fetched the PTE. `sim_mmusdram`'s read-only-page checks caught it directly
("store to read-only faults" correctly `ok`, "read-only page unchanged"
`FAILED`). Fixed by also excluding `head_mmu_fault_now`.

A third instance of the exact same shape was missed in the same pass and
shipped: **a misaligned store, AMO, or head-routed load could take its trap
*and* still write to the bus in the same cycle**, because
`head_plain_store_now`/`amo_active`/`head_load_owns_port` excluded
`head_mmu_wait_stall` and `head_mmu_fault_now` but never
`head_mem_misaligned` — the out-of-order load path already got this right
(`loadL_can_start` excludes `issL_misaligned`), but the three head-based
signals above did not. This was not caught before `make verify_ooo` first
went green: `rv32mi-p-ma_addr` was already failing at that point, and it was
mischaracterized — without checking it against an actual pre-stage-1d
baseline — as the project's known, pre-existing, unrelated `ma_addr`
divergence, and shipped that way in this stage's first pull request. CI
caught it: `riscv-tests (ooo)` failed while `riscv-tests (inorder)` passed
on the same test, which a real pre-existing gap could not do, since nothing
in this change touches the in-order core. Root-caused with a targeted
cycle-by-cycle trace on the failing subtest (`sh zero,1(s0)` at address
`0x80002001`, riscv-tests' `ma_addr` case 22): the misalignment was detected
correctly and the trap fired on the very first possible cycle with no
delay, but the write reached the bus in that same cycle anyway, zeroing the
byte at the faulting address before the trap handler's own sanity check
(`lb t0,(t0); beqz t0, fail`) read it back and found zero where it expected
the original, nonzero data. Fixed by adding the same `!head_mem_misaligned`
exclusion to all three signals.

That second fix had an unplanned side effect: `rv32si-p-dirty`, one of the two
riscv-tests failures this project already carried before stage 1d existed (a
genuine gap, not a deliberate one — `tests/expected-failures.txt` was never
asked to cover it), now passes riscv-tests' own pass/fail check. Cosimulation
still finds a divergence in it, but at a *later* instruction than it ever
reached before: the corruption this fix removed was previously making the run
stop before it got there, not making it agree with Spike. What is now visible
is a real, narrower, still-unresolved Sv32 dirty-bit semantic difference from
Spike, one instruction wide, shared with the in-order core's own known
limitation in this area and not new to this stage.

**CoreMark, one iteration.** 448,346 cycles, correctness self-checked by
CoreMark's own CRC (`BENCHMARK PASSED`). For comparison, on the same D-cached
bus adapter:

| | Cycles | |
|---|---|---|
| In-order core | 453,844 | unchanged by this stage |
| Wide core, stage 1b+1c (dual issue, no ROB) | 434,822 | what 1d was meant to replace |
| **Wide core, stage 1d (renaming, ROB, general OOO issue)** | **448,346** | slower than 1b+1c, barely faster than in-order |

Dispatched 380,146, retired 359,619 — 0.80 instructions retired per cycle,
under one, let alone the "more than one instruction retiring per cycle" this
phase's own done-when criterion (above) named as the bar. The reordering is
real and substantial — 157,625 of 181,428 ALU issues and 64,986 of 71,975 load
issues actually left program order — and the net result is still a worse
cycle count than the design it was meant to supersede. This is the
CoreMark answer to the question the D-cache measurement above already asked:
the ROI case against 1d was not wrong.

**Linux.** `Makefile`'s own `linux_trapdiff` target already documented, before
this stage existed, that the wide core's Linux boot does not reach
`VERNIER-RV32-LINUX-BOOT-OK` and is not expected to — "the wide core's boot
*is* the failing one... a rule that required success here could only ever run
when there was nothing to diagnose." That is still true, but the *way* it
fails changed, and the change matters. Before the `head_mmu_wait_stall` fix
above, `sim_linux CORE=ooo` hung completely — not one line of the kernel's
own console output, only OpenSBI's banner, timing out at 400,000,000 cycles
with 38 traps, all attributable to OpenSBI's own init. That is the deadlock
described above, reached for the first time at the scale a real boot's
page-table traffic produces. After the fix, the same boot gets deep into
kernel initialisation (PLIC mapped, thousands of traps, misaligned-access
delegation confirmed working) but still never reaches user mode: a trap-trace
diff against the in-order core's own successful boot (`make linux_trapdiff`,
which drops interrupts and compares real exceptions only) shows zero `U->S`
transitions across the whole run, against 3.8x more `S->M` "ecall from S"
calls than in-order's *entire* successful boot needed for its whole run — the
kernel is ticking normally via the timer (a CLINT path, unrelated to the
PLIC) but never scheduling anything that reaches userspace. Timer interrupts
fine, nothing that depends on an external, PLIC-routed interrupt ever
completing: that pattern points at a second, distinct, not-yet-root-caused
interrupt-delivery gap specific to this core. Investigated to that point and
stopped there rather than chased further; `make verify_ooo` does not gate on
`sim_linux`, and this did not look like the class of bug a bounded amount
more tracing was likely to close quickly.

**Fmax and utilisation: attempted, and blocked on something worth naming.**
The toolchain was not installed in the session that built the rest of this
stage; it is in a later one, and `fpga/synth/synth_ecp5.sh` had never had a
`CORE=` knob at all — hardcoded to `rtl/cpu_core.v`, never run against
`core_ooo.v` once. Added one, mirroring the Makefile's own `CORE_RTL`/
`CORE_DEFINES` exactly, and confirmed it first against `CORE=inorder`: the
regression run reproduces the documented 85F numbers closely (80 DP16KD/38%,
17,814 TRELLIS_COMB/21%, 4 MULT18X18D, timing closed on seed 3 at 26.28 MHz —
next to the prior "seed 3, 25.96 MHz" entry above), so the knob itself is not
the story.

`CORE=ooo`, `BOARD=ulx3s85`, for the first time: **synthesis succeeds with
real numbers** — 78 DP16KD/37% (barely different from in-order's 80/38%, so
the physical register file and ROB did *not* turn out to be the block-RAM
pressure this file worried about before it was measured), 52,042/83,640
TRELLIS_COMB/**62%** (against in-order's 21% — roughly three times the logic,
which tracks with renaming, an 8-entry CAM-like ROB, and three completion
buses where the flat core has one), and 12 MULT18X18D against 4. **But
place-and-route's own static timing analysis fails outright, deterministically,
on all six placement seeds**: `ERROR: Timing analysis failed due to
combinational loops.` Not "too slow" — nextpnr cannot produce an Fmax number
for this design at all via the standard flow, which is a different and more
important finding than a missing digit.

This is almost certainly the same cycle `sim/verilator_soc.vlt`'s own
`UNOPTFLAT` waiver already names — one loop nextpnr reports (its internal
number 3941) touches exactly the CDB-bypass network that comment describes:
`regfile_phys`'s write-data muxes, the out-of-order ALU (Class B) operand
path, the divider, and the MMU's `va` all appear in the same reported cycle.
The `.vlt` file's own reasoning — "a specific tag match is a runtime
condition, always false for a producer reading its own not-yet-computed
result, by construction" — is sound for a value-level simulator, which is
exactly why Icarus and Verilator both execute this design correctly (`make
verify_ooo` is green; see above). It says nothing to a static timing
analyzer, which reasons about the wire graph, not runtime values, and a
structural cycle in silicon is a structural cycle regardless of which tag
matches ever really fire. Whether that is only a nextpnr-STA limitation
(the loop is genuinely inert, and a real board would work) or a real
metastability/settling risk on that path (the loop is not as inert in an
analog sense as it is in a simulated one) is now the open question, and it
is a different and harder one than "what is the Fmax" — worth its own
investigation with its own budget, not a fix folded into this stage.
Documented here rather than attempted under time pressure: breaking this
cycle structurally means restructuring the completion-bus muxing this stage
built, not a local patch.

**And it is now verified as well as counted.** Co-simulation against Spike had
been running on this core the whole time and passing 82 of 82 traces — while
retiring 63 instructions in slot 1 out of 28,262, with 70 of those traces
retiring none. Corrupting every slot-1 result leaves 73 of the 82 still
passing. `tests/vernier/pairing.S` is the workload built to close that: 6,143
slot-1 retirements, instruction-exact against Spike on both cores, with a
floor in `cosim.py` so a change to the issue rule cannot quietly turn it back
into a single-issue test. See [practices.md §40](practices.md).


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

**What 256 KB was not saying.** `wb_sdram.v` takes the row from
`wb_adr[24:12]`, so that sweep is all 512 columns, all 4 banks and **64 of
8192 rows** — row address bits A6..A12 never driven high through the CPU, on a
part a kernel needs 28 MB of. The gap is which bits toggle rather than how
many bytes are touched, so `sdramcheck.c` now writes and reads one word in
every one of the 8192 rows for 16,384 accesses, which runs in `make verify`;
forcing row bit A7 low makes it report 4,096 wrong rows while the 256 KB sweep
still passes. `make verilator_sdramfull` sweeps all 32 MB densely in about a
minute and measures a 4,031 ms retention interval against the short sweep's
31 ms.

**And it has run on the part.** `BOARD=ulx3s85-sdramfull` reports
`SDRAM-CHECK: PASS` on a ULX3S 85F over all 8192 rows, 8,388,608 unique words,
with the same 4,031 ms retention and 20 ms idle the model predicts — model and
silicon agreeing to the millisecond over 16 million accesses.
`docs/practices.md` §34.

Bring-up is two bitstreams, in the order that narrows the problem —
`fpga/README.md` has the procedure and the LED table:

| | |
|---|---|
| `BOARD=ulx3s-sdram` | `fpga/ulx3s_sdram.v` — no CPU at all. Five cumulative LEDs: power-up, one word, walking ones over the data, one address per address bit, and survival across a ~100 ms idle, which is what proves refresh |
| `BOARD=ulx3s85-sdramcheck` | `software/soc/sdramcheck.c` — the CPU, caches and interconnect in the path, running from block RAM and hammering 256 KB of SDRAM |
| `BOARD=ulx3s85-sdramfull` | the same program over the whole 32 MB. 256 KB was 64 of 8192 rows, so seven of the thirteen row address bits had never been driven high. **`SDRAM-CHECK: PASS` on the board** |

Both have simulations (`make sim_sdramprobe`, `make sim_sdramcheck`) and both
are gated in CI, because a bring-up instrument that is itself wrong turns "the
memory does not work" into a hunt through the memory, the pinout and the clock.

**The thing most likely to need attention was `sdram_clk`**, and it was. That
paragraph used to say a straight assignment "usually works, and usually is not
a measurement". The measurement arrived and it did not work.

### Getting a program into SDRAM on a board

A bitstream initialises block RAM at FPGA configuration time. SDRAM is external
and comes up holding nothing, so an image linked at 0x9000_0000 has no way to
get there — which is why the memory could be proven and still hold no code.

The boot ROM now takes one over the serial line:

```sh
./software/soc/uartload.py /dev/cu.usbserial-XXXX software/soc/sdramtest.bin
# then press reset on the board
```

It listens for a knock for 20 ms after reset, takes a 16-byte header (magic,
load address, length, CRC32), refuses an address outside RAM or SDRAM, and
checks the CRC before it jumps. `make sim_uartload` runs the whole path — host,
ROM, SDRAM, running program — and is gated in CI.

**It is stop-and-wait, a byte at a time**, and that is the interesting part.
`rtl/uart.v`'s receiver is one byte deep with no FIFO, so a transfer that
streams depends on the receiver keeping up with the line: true with 31× margin
at 115200 on a 25 MHz board, false in simulation at four clocks per bit, where
the ROM is 1.8× too slow. An earlier version acknowledged every 256 bytes and
believed that removed the dependence; it only divided it by 256.
`docs/practices.md` §24.

That loader is also the **first user of `rtl/uart.v`'s receive path** — nothing
in this project had ever transmitted *to* the SoC, so that half of the UART was
untested RTL until now.

**Done when:** ~~the SoC runs a program larger than 64 KB from external
memory~~ — **done, on silicon.** A 99 KB program sent over the serial line into
external SDRAM on a ULX3S v3.1.8 / LFE5U-85F, fetched and executed from there,
checking 96 KB of its own `.rodata` and sweeping 256 KB — `SDRAM-TEST: PASS`.
The log is in `fpga/README.md`.

That is the whole phase as it was written at the top of this section: 64 KB of
block RAM is no longer what stands between this and anything larger.

**Still open**, and worth keeping separate because they are different sizes of
job — the loader that used to head this list is done:

| | |
|---|---|
| ~~A loader, so code can run *from* SDRAM on a board~~ | **done** — the boot ROM takes an image over the serial line. See below |
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

### Spatial locality: measured six ways, and it doesn't pay for itself here

Both caches fetch exactly the word that missed - no line fill, no burst.
The D-cache's residual 3.7% miss rate is compulsory, which is the miss a
fill state machine reaches and a bigger cache does not, and that gap is
exactly what "more than one word per line" was supposed to close. Six
configurations were built, measured, and none beat the one-word baseline
on CoreMark - 454,010 cycles. In order:

| Configuration | Cycles | vs. baseline |
|---|---|---|
| Baseline (both caches, one word/line) | 454,010 | — |
| 4-word line, both caches, fixed-order fill | 510,710 | +12.5% |
| 4-word line, both caches, critical-word-first | 495,496 | +9.1% |
| 2-word line, both caches, critical-word-first | 469,466 | +3.4% |
| 2-word line, D-cache only (I-cache reverted) | 455,036 | +0.23% |
| 2-word line, D-cache only, preemptable background fetch | 454,982 | +0.21% |
| 2-word line, D-cache only, capacity doubled (256 sets, not 128) | hung | not measured |

**The fixed-order attempt** filled the whole line before reporting the
miss resolved, in address order. Simple, and measurably worse: losing the
one-word cache's same-cycle bypass and paying up to three extra round
trips before the *first* word ever reached the core cost more than the
improved hit rate gave back.

**Critical-word-first fixed that specific problem** - the missed word is
fetched first and delivered the moment its own transfer acks, exactly the
one-word cache's latency, with the rest of the line filling in behind it
while the core is already running. Still a regression, at both four words
and two: fetch happens every cycle, so even a modest "also fetch the
neighbor" tax multiplies fast, and it dominated the two-word, both-caches
measurement - 38,054 of 44,016 tallied tax cycles came from the
instruction side, against 5,962 from the data side, despite the two
having a similar miss count. Reverting the I-cache to its original
one-word form and keeping only the (much cheaper, near-break-even)
D-cache widening is what got the gap down to +0.23% - a result close
enough to call settled, not close enough to call a win.

**Closing the last +0.23% needed the background fetch to be preemptable**
- deferred, not just queued, so a store or an unrelated hit could use the
bus instead of waiting on a fetch nobody but this adapter cared about yet.
It closed 54 of the remaining 1,026 cycles. Diminishing returns at every
step: +12.5% → +9.1% → +3.4% → +0.23% → +0.21%, each increment of
sophistication buying less than the one before it.

**Why even the best variant didn't cross zero, checked against how real
cores do this:** every configuration above held total D-cache capacity
fixed at 256 words and widened the line by *shrinking the set count*
(256 sets → 128 for a two-word line). VexRiscv's cache plugins, Rocket
Chip and Ibex all widen lines by growing total capacity instead, precisely
to avoid this: fewer sets means more addresses alias to the same line, and
a small cache already has few sets to spare. CoreMark's list, matrix and
state-processing sub-benchmarks each hold their own working set resident
at once, which is exactly the access pattern most exposed to the resulting
conflict misses. The capacity-preserving variant - line width doubled,
set count held at 256, so total capacity doubles to 512 words - was
built to test that directly and hung before producing a number: a third
distinct bug, on top of the two below, not debugged before the investigation
was closed out. Area was never the obstacle - the existing 256-word cache
costs roughly 900 LUT4s against an 85F's 84k.

**Three real, previously-latent bugs surfaced along the way**, each found
by a genuine hang or a silent infinite loop, not by inspection - all fixed
in the code that produced the numbers above, none shipped because none of
the surrounding designs were:

1. `dbus_wait` missing a `want &&` guard - stalled the whole pipeline
   permanently the instant nothing was requesting the data bus, because
   `ex_busy_stall` (`rtl/cpu_core.v`) folds `dbus_stall` into `pc_freeze`.
   Unrelated to line width; would have broken any design that touched
   this signal.
2. A multi-word fill's tag only updates when the fill completes, but its
   data words land progressively as each one acks. An address that
   collides on the same line index while a fill for a *different* line is
   still in flight could read a line that is part old data, part new - a
   false hit on a torn line, under a tag that still matched the previous
   occupant. Fixed by invalidating the line the instant a new fill claims
   its index, not once the fill finishes.
3. In the preemptable design, a store could jump the queue ahead of a
   pending background fetch even when it targeted the *same* line that
   fetch was for. The store's write-through still reached memory
   correctly, but `dc_store` requires `dc_present`, which was false until
   the fetch finished - so the cache's already-resident critical word
   never picked up the store, and once the line went valid it served that
   stale word forever. Fixed by excluding same-line accesses from the
   "can jump the queue" condition.

Whoever picks this up next has three real, specific leads rather than a
blank page: the capacity-preserving variant's unfound bug, a genuinely
non-blocking (not just preemptable-before-starting) fill for the fetch
side specifically since that is where the tax concentrates, or a
different line width on top of a wider capacity-preserving cache. None of
that is on this branch - every configuration above regressed the metric
this phase is measured on, so none of it shipped.

- **~~An I-cache alone would be a large win~~** — done, above.
- **~~A D-cache~~** — done, above.
- **~~Spatial locality: more than one word per line~~** — measured six
  ways, above; none beat baseline, and the closest (+0.21%) is documented
  rather than shipped.
- **~~Interrupt-driven UART~~** — done. `software/soc/uartirq.c` (`make
  sim_uartirq`) is a driver that queues a message, arms ETBEI once, and lets
  the S-mode handler drain it one interrupt per byte, instead of every
  `put_char` in this repository polling LSR.THRE. Not a CoreMark number -
  CoreMark does no UART I/O in its measured loop, so this doesn't move that
  score - the thing it proves is that the CPU is free during the transfer: a
  5,000-iteration unrelated busy loop next to the send finds the transfer
  already done after 218 of them.
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
and reaches 16 MB, which is thirty times what `fw_jump.bin` needs — and the
loader question is answered too: `software/soc/uartload.py` sends an image
over the serial line into SDRAM and the boot ROM runs it from there, verified
on a board with a 99 KB program. Neither memory nor a way to fill it is a
blocker any more.

FreeRTOS or Zephyr is the realistic intermediate milestone, and is reachable
sooner: there is a bus, a timer, an interrupt controller and storage.

**Done when:** OpenSBI prints its banner and hands off to an S-mode payload —
**done**, and the payload now exists and boots in QEMU. The remaining gap is
this SoC, and it is one named failure rather than a category.

**The banner half is done.** `make sim_opensbi` boots OpenSBI v1.9 on this
SoC: it parses `dts/soc.dts`, finds the ns16550 console, the CLINT as
`aclint-mtimer`/`aclint-mswi` at the right frequency and the PLIC's window,
detects the hart as `rv32ima` with no PMP, builds its root domain, and stops
prepared to enter S-mode at `0x9040_0000`. What is missing is something to be
*at* that address.

### The debug loop had to be fixed first

Everything under `sim/tb_*.v` runs on Icarus, at about **11.3 thousand cycles
per second** on this SoC. Every test in the suite fits comfortably inside
that; the longest, `sim_sdramboot`, is 2.1 M cycles in three minutes.

A Linux boot does not fit. It is order 10⁸ cycles — **seven hours or more per
attempt** — on a bring-up whose characteristic failure is a silent hang with
no output at all, where the only way forward is to look at a waveform and try
again. One attempt per working day is not a debug loop.

So `soc_top` is now built under Verilator as well (`sim/verilator_soc.cpp`),
measured at **4.44 M cycles/s** on the same image and core: roughly **390×**,
turning that seven hours into about a minute. This is the cheapest thing on
the whole Phase 5 list and it multiplies everything after it, which is why it
was done before any of the RTL below.

Verilator cannot run `sim/sdram_model.v` — that model is written in
nanoseconds, with `#T_AC_NS` on the data path — so the harness carries a C++
port, and there are now two memory models that could disagree. A fast
simulator that quietly lies is worse than a slow one that does not, so
`make verilator_check` runs `sim_sdramboot` under both and requires the cycle
counts to match — to within the one cycle the two testbenches' verdict
watching differs by, which `sim/verilator_compare.py` justifies at length —
along with the refresh counts and every byte of program output, both exactly.
`sim/sdram_model.v` stays the authority; the port is checked against it.

### What is actually left, for Linux specifically

Two of the three hard blockers are now closed:

1. ~~**The page-table walkers cannot reach SDRAM.**~~ **Done.** They sat on
   `wb_ram.v`'s second block RAM port, and an SDRAM has no second port, so
   page tables could live in block RAM and nowhere else. `rtl/soc/wb_ptw.v`
   arbitrates both walkers into a third Wishbone master, so a PTE can come
   from any slave the interconnect decodes. `mmu.v` did not have to change:
   the module asserts the walker's grant in the bus's *ack* cycle and
   registers the returning word on the same edge, which reproduces the
   one-cycle-later contract the walkers were written against, whatever the
   slave's latency.
2. ~~**`mip.SEIP` is hardwired to zero and the PLIC has one M-mode context.**~~
   **Done.** `rtl/plic.v` has the standard register map and two contexts (0 =
   hart 0 M-mode, 1 = hart 0 S-mode), and `mip.SEIP` is the spec's OR of a
   software-writable bit and the controller's pin. `make sim_plic` raises a
   GPIO interrupt, has it delivered to **S-mode** through context 1, claims
   and completes it — the first program in this repository ever to take an
   external interrupt in either privilege mode.
3. ~~**The interconnect decodes `addr[31:24]`** — 16 MB per slave.~~ **Done.**
   The decode compares through a per-slave mask; the SDRAM's is `0xFE`, so it
   answers to `0x90` and `0x91` alike. `wb_sdram.v` needed no change — it
   always took its row from `wb_adr[24:12]`.

### The kernel: booting to userspace, here

`software/linux/build-linux.sh` fetches Linux 6.18.45 and builds an rv32ima
kernel with an initramfs in it. **In `qemu-system-riscv32 -M virt` it boots to
userspace, and on this SoC it does too**:

```
Run /init as init process

=== VERNIER-RV32: USERSPACE ===
kernel  : Linux 6.18.45
machine : riscv32
pid     : 1
isa     : rv32ima_zicntr_zicsr_zifencei_zaamo_zalrsc
mmu     : sv32
```

`make sim_linux` reaches the marker at cycle 132,938,924 — 33 seconds of
Verilator, 5.3 seconds of wall time at 25 MHz. It parses the device tree,
brings up `earlycon`, builds memblock and the whole linear map, turns Sv32 on,
reports `Memory: 24316K/28672K available`, switches to `riscv_clocksource`,
probes `rtl/plic.v` (`mapped 8 interrupts ... for 2 contexts`) and
`rtl/uart.v` (`ttyS0 at MMIO 0x4000000 (irq = 1) is a 16450`), hands the
console over from the SBI earlycon to `ttyS0`, frees its init memory and runs
`/init`.

Three defects stood between "the kernel starts" and that, and all three are
recorded below and in `software/linux/README.md`.

**And it boots on the board.** A ULX3S / LFE5U-85F, 7,744,876 bytes sent over
the serial line into external SDRAM in one attempt, OpenSBI, the kernel, and
`/init` at pid 1. `fpga/README.md` has the transcript and what each line of it
settles — the Sv32 MMU on silicon, the ns16550 console and its 3.1% baud
error, and the 22-minute all-or-nothing transfer. PLIC interrupt *delivery* is
the one thing that boot does not prove.

### The last one: a device tree that claimed a FIFO the hardware has not

The console garbled the instant Linux took it over from the SBI earlycon —
`clk: Disabling unused clocks` came out clean, and the next line arrived as
`Fet2KoecRt=:kL`. That was *not* a decoding-rate mismatch, which the standing
note here said and which was true: the harness reported divisor 14, 224 clocks
per bit, exactly what both OpenSBI and Linux compute from `clock-frequency`.
The rate was right. Not all of the bytes were being sent.

`dts/soc.dts` said `compatible = "ns16550a"`, and `rtl/uart.v` has no FIFOs.
The device tree even carried a comment saying so, ending "so a driver that
checks will stay in 16450 mode" — and nothing checks.
`drivers/tty/serial/8250/8250_of.c` sets `UPF_FIXED_TYPE`, so `autoconfig()`
never runs and the honest `IIR` is never read. The compatible string is not a
hint that a probe confirms; it *is* the configuration. `PORT_16550A` means
`tx_loadsz = 16`, and `serial8250_tx_chars()` writes sixteen bytes into a
one-byte holding register after a single `THRE` with no status check between
them. `rtl/uart.v` takes a write only when the transmitter is free, so fifteen
of every sixteen went nowhere, with nothing in the part that could report it.

`compatible = "ns16450", "ns16550";` now — the part this is, and the register
map it can be driven through. The order is load-bearing: Linux scores a match
by its index in *that* list and takes `ns16450`, while OpenSBI's `uart8250`
driver matches `ns16550` and keeps its own console.

`+checkuart` is what settles it, and it settles it in the output of the failing
run: it counts what software writes to `THR` against what the receiver decodes
off the wire, and needs no baseline, because a discarded write is a defect on
its own terms. Before, `6336 written, 470 dropped by the transmitter`, naming
the first twelve by value — `r`,`e`,`e`,`i`,`n`,`g`,` `,`u`,`n`,`u`,`s`,`e`,
the tail of "F*reeing unuse*d", 48 cycles apart where a character takes 2,240.
After, `6335 written, all 6335 sent, in order`. It runs in
`make verilator_check` and in `make sim_linux`. docs/practices.md section 32.

### The one before that: an instruction executed under the wrong PC

`unflatten_device_tree()` failed on a device tree that was demonstrably well
formed. The cause was **an instruction executed under the wrong program
counter**.

A `ret` was predicted taken to a stale BTB target left by a different call
site. The core detected the misprediction and redirected correctly — but an
**ITLB walk was in flight for the mispredicted address**, and `rtl/mmu.v`
answers a concluded walk from the `va_r` it latched when the walk began. That
is deliberate and right for the data side, where the live `va` is recomputed
from forwarding and decays under a stall. The fetch side has the opposite
property: `redirect_valid` overrides the PC freeze *on purpose*, so the PC
moves while the walk runs.

So the walk handed back the mispredicted path's physical address, the fetch
unit fetched a real instruction from a real address, and the IF/ID register
paired it with the corrected PC. `li a4,3` executed where `li a5,1` should
have. Two instructions later a `bne` took a branch it must not take, and
libfdt reported a malformed tree.

`rtl/mmu.v` now exposes `pa_va` — the virtual address its answer is the
translation of — and both cores reject an answer that is not for the current
`pc`. Rejecting costs a re-walk and cannot livelock: the walk still installs
its TLB entry.

**It needs an ITLB miss and a mispredict in flight simultaneously.** Every
bare-metal program in this repository is small enough that the ITLB stops
missing after its first pass, and riscv-tests never enables paging. Linux, with
4 KB pages throughout its linear map and 2.4 MB of text, lives in ITLB
eviction. `+checkdecode` now checks the pairing directly and runs in
`make verilator_check`; docs/practices.md section 31 is about why the three
probes that already passed could not have found it.

### Turning translation on had never included a second level

`make sim_mmusdram` mapped 4 MB megapages and nothing else, by explicit
design, so `l1_conclusive` in `mmu.v` was true on every walk this project had
ever run. riscv-tests does not cover it either — `rv32si-p-*` is the physical
variant and never enables paging. So the hardware had never read a *second*
PTE.

Linux has no such option: its linear map is megapages, which is why a kernel
runs here at all, but the fixmap, vmalloc, every `ioremap` and every page of
userspace are 4 KB pages behind a level-2 table.

`software/soc/mmutest.c` now covers it — VPN[0] at 0, 512 and 1023,
per-4-KB-page permissions, an invalid level-2 entry, three pages inside one
megapage to catch a TLB that tags at the wrong granularity, and a sweep over
four times the TLB's eight entries read back in reverse so every hit is on an
entry that was evicted and walked again. The aliasing check is the pointed
one: getting it wrong returns the *wrong page* rather than faulting, which is
the hardest shape of bug to see from software. The pressure check is there
because `best_map_size()` returns `PMD_SIZE` only under `CONFIG_64BIT`, so on
rv32 the entire linear map is 4 KB pages and Linux runs permanently in
eviction — a regime nothing else on this SoC enters. All pass —
the walker was already right, which is worth knowing rather than assuming.

What it will need, once OpenSBI hands off:

- ~~a kernel built `rv32ima` with **no C extension** (this core does not
  implement it) and `CONFIG_MMU=y` with Sv32~~ — **done**, and harder than it
  reads: `CONFIG_EFI` is `default y` on riscv and `select RISCV_ISA_C`, so
  turning C off is not enough on its own and kconfig reports nothing;
- ~~an initramfs, because there is no block device driver for the SPI card and
  the SD path is the boot ROM's, not the kernel's~~ — **done**, built into the
  Image, with a `/init` that makes raw `ecall`s because there is no rv32 Linux
  userspace toolchain on this host;
- ~~`fw_payload` rather than `fw_jump`, or a loader that places the kernel
  where `fw_jump` expects it~~ — **done**: `software/opensbi/mkimage.py`
  packs the Image at `FW_JUMP_ADDR` in the same blob as the firmware, and
  checks the RISC-V Image header's `text_offset` against where it put it;
- roughly 3×10⁸ cycles per boot attempt, which is about a minute under
  Verilator and seven hours under Icarus. That ratio is why the harness was
  built first.

Then: ~~an ns16550-compatible UART~~ (**done** — `rtl/uart.v` is one, with the
divisor latch, IIR and an interrupt into PLIC source 1; `make sim_uart16550`),
~~a device tree~~ (**done** — `dts/soc.dts` describes the two-context PLIC and
the ns16550, and OpenSBI's `generic` platform is entirely FDT-driven, so that
device tree *is* the platform port), an rv32ima kernel with no `C`, and an
initramfs. Hardware PTE A/D auto-update is absent and Linux does not strictly
need it to boot.

**OpenSBI boots.** Five defects stood between "builds" and "boots": a missing
`mstatush`, a load address violating OpenSBI's own alignment precondition, a
build script that built the wrong thing two different ways, a
`FW_JUMP_FDT_ADDR` default that landed outside this SoC's 32 MB — which
matters because `fdt_get_address()` returns the root domain's `next_arg1`, so
OpenSBI reads its *own* device tree through it — and a `timebase-frequency`
in `dts/soc.dts` that was twice the real one.

`software/opensbi/README.md` records the method as well as the findings,
because the method is the reusable part: OpenSBI owns the console and brings
it up late, so every failure before that is identical silence. The way through
was instrumenting the *hardware* - retired PC, trap CSRs, a branch-transfer
ring, a register watchpoint and a memory peek, all in
`sim/verilator_soc.cpp`.

### What turning translation on for the first time cost

`make sim_mmusdram` builds an Sv32 identity map of 4 MB megapages with the
root table at `0x9100_0000` — in SDRAM, above the old decode ceiling — enters
S-mode, and checks that fetch and data both translate, that a read-only
megapage still reads, and that storing to it takes a store page fault.

It is the first thing in this repository ever to write a non-zero `satp`.
riscv-tests' supervisor set is `rv32si-p-*`, the **physical** variant: it
exercises S-mode CSRs and traps and never enables paging. So 79 passing
architectural tests and 82 of 82 matching Spike traces had between them never
run a single page-table walk driven by hardware translation.

It found two core bugs on its first run, both present since the MMU landed:

- **The fetch address is `X` while the ITLB walks**, because `mmu.v` derives
  it from a PTE register that has not been read yet. `cpu_wb.v` indexes its
  I-cache with it, so `fetch_hit` goes `X`, so `iwb_cyc` goes `X` — and
  `wb_ram.v`'s `ack_r <= a_en && !ack_r` latches that `X` permanently, since
  `!x` is `x`. One unresolved fetch wedges main memory for the rest of the
  run. Both cores now hold the last resolved address instead, which is also
  free: that address is still in the I-cache, so no bus cycle is issued at
  all — and the walker is now competing for the same bus.
- **A translated store used the previous instruction's data on a TLB hit.**
  `store_data_latched` is a register; selecting it unconditionally hands a
  store that never stalled the operand as of the end of the *previous* cycle.
  Correct under a walk, which is the only path that had ever run.

docs/practices.md section 26 is about the shape of that: a suite that passes
is not a suite that ran the code.

---

## Phase 6 — Debug infrastructure

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
[practices.md §45](practices.md), which produces exactly "user mode crawls
in the interrupt-driven tty path" and arms on any reshuffle of the boot's
interleaving - which every one of the four fetch-path variants is, by
construction. Re-running the simplest of them - explicit gating instead of
an accidental cache hit, `rtl/cpu_core.v`'s `itlb_wait_stall` - on top of the
CSR fix settled it: both cores boot within 15,000 cycles of baseline, not
150x slower. [fpga/README.md has the numbers](../fpga/README.md); the other
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
byte-for-byte what #49 shipped. [practices.md §45](practices.md) is the
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

**What is left is hart control**: halt, resume, single-step, and reading the
CPU's registers. That needs debug mode, `dcsr`, `dpc`, `dret` and a debug ROM
the core vectors into, all of which land on the fetch redirect and the
register file write port. Two of six placement seeds already fail to close
25 MHz. **Fix the timing margin first** — this is the clearest case in the
project of one phase being gated on another, and it is gated on Phase 3's
unfinished business rather than on anything here.

Also missing, and cheaper: no debug adapter has been connected to a board.
The path is proven in simulation only.

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

## Phase 8 — PCIe

**Blocked on a board, not on anything in this project.** Every phase above is
ordered by what it unblocks on the ULX3S / LFE5U-85F this project has run on
since Phase 0. That board has no PCIe connector and the 85F has no SerDes -
no hardened PCIe, no soft endpoint has anywhere to plug in. This phase starts
when a board with both exists, and which board that is has not been decided.
Nothing below is a spec; it's the shape of the work once that choice is made.

**Board selection is the first open item**, and it constrains everything
after it: whether PCIe comes from a hardened hard IP or has to be a soft
endpoint depends on the part, and the endpoint core to use follows from that.
Guessing at a lane count or generation before the board is chosen would be
exactly the kind of estimate `docs/practices.md` exists to catch - "numbers
quoted are measured, not estimated" applies to specs as much as to Fmax.

**What plugs in once it exists**, in the shape every other peripheral here
already takes: `rtl/soc/wb_periph_bridge.v` is the template for a
register-mapped endpoint (BAR space as a Wishbone slave), the same as the
UART, CLINT and PLIC. A PCIe endpoint doing its own DMA is a different case -
a *bus master*, like `rtl/debug/dm.v` and the page-table walkers are today -
and `rtl/soc/wb_interconnect.v` would be gaining a fifth one rather than a
new slave. Which shape this needs depends on what the endpoint is for, which
is also not yet decided.

**Done when:** a real PCIe host's `lspci` sees the device, and a register
read or write round-trips on real hardware - the same bar Phase 0 set for
the pipeline and Phase 7 sets for the SD card: simulated first, then proven
on silicon, not asserted from the simulation alone.

---

## Phase 9 — DDR

**Also blocked on a board.** The SDRAM this project has (32 MB, confirmed on
silicon in Phase 2 - every address, bank and byte lane, 4,031 ms measured
retention, `fpga/README.md`) is single-data-rate. DDR is not that memory
running faster; it is different memory, on a part that supports it, and the
ULX3S/85F does not. This phase starts when that board is chosen, same as
Phase 8, and for the same reason it is last rather than absent.

**A DDR controller is a bigger design than `rtl/soc/wb_sdram.v`, not a
version of it.** SDR SDRAM's controller is what Phase 2 measured against
board revisions of a mode register and a refresh counter. DDR needs a
calibrated PHY - read/write leveling, delay-locked strobes - which has no
equivalent in this codebase today. Whether that PHY is a vendor hard block or
a soft one is, again, a question the board answers, not this file.

**Bus integration follows the existing pattern**: a Wishbone slave beside
`wb_sdram.v`, the same way `wb_sdram.v` sits beside `wb_ram.v` - so the
caches and the MMU walkers that already treat "external memory" as an
address range gain the new one without changing. "Improve," once a first
controller exists, most likely means what Phase 3 already flagged and left
open for the caches - spatial locality, more than one word per transfer -
mattering more here than it does against the current SDRAM, because DDR's
burst mode is built for exactly that access pattern.

**Done when:** DDR confirmed on silicon to the standard Phase 2 already set -
every address, bank and lane checked, a measured retention or timing margin,
not "it linked and didn't hang" - and something running from it, the way
`SDRAM-TEST: PASS` runs 99 KB of code out of the current memory today.

---

## Beyond the phases

**PMP**, which [SECURITY.md](../SECURITY.md) lists as a known gap rather than
an oversight.

---

## Known defects

Open, unscheduled, and written down so they are not rediscovered.

**The wide core's `execve` `-EFAULT`, now localized.** `make linux_trapdiff`
boots the same image on both cores and compares the traps. Exactly one
exception separates them: a supervisor store page fault at
`load_elf_binary+0xc30`, storing to user virtual address `0x00040000`. The
page really is unmapped — the root page table's entry 0 reads zero at the
faulting cycle — so the MMU is right and a *store* that should have written a
page-table entry did not — **and that reading turned out to be wrong**. The
write trace shows the in-order core installing that entry only after `/init`
is already running, so it never stores to the faulting address inside
`load_elf_binary` either. The wide core is issuing a store the working core
does not, rather than losing one. `software/linux/README.md` has the method
and the numbers; [practices.md §41](practices.md) has what `+checkmmu` was
checking while this went past it, and [§42](practices.md) has the correction.

**The intermittent `ISA-TIMEOUT` under `make verify`.** Still undiagnosed. It
self-reports rather than hanging silently, which is not the same as being
fixed, and pretending otherwise is exactly the failure mode
[practices.md](practices.md) §7 is about.

**`sim/program.hex` is 440 instructions of recovered source.**
`sim/program.S` reassembles to it byte for byte and `make check-program`
holds that, but the labels are named for byte offsets because the original had
no symbol names to recover. Anyone extending the core regression will be
working with that.

**`CORE=ooo` has no Fmax: nextpnr's static timing analysis fails outright on
a combinational loop.** Six placement seeds, `BOARD=ulx3s85`, six identical
`ERROR: Timing analysis failed due to combinational loops` — not a missed
frequency, no timing report produced at all. One reported loop (nextpnr's
internal number 3941) runs through `regfile_phys`'s write-data muxes, the
out-of-order ALU operand path, the divider, and the MMU's `va`, which is
exactly the CDB-bypass network `sim/verilator_soc.vlt`'s `UNOPTFLAT` waiver
already names and reasons is functionally inert (`make verify_ooo` is green;
Icarus and Verilator both execute it correctly). That reasoning is about
runtime values and does not help a static timing analyzer, which sees only
the wire graph. Whether the loop is genuinely electrically inert on real
silicon or a real metastability risk is open, and it is a different, harder
question than "what is the Fmax" — see the "Stage 1d was built anyway"
section above for the full measurement and reasoning. Fixing it means
restructuring the completion-bus muxing, not a local patch.
