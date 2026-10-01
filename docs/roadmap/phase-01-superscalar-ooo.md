# Phase 1 — Superscalar issue and out-of-order execution

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

## How it is being built

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
| 1d | Renaming, reorder buffer, reservation stations, LSQ | **built anyway** — see below. `make verify_ooo` fully green; CoreMark **448,346 cycles**, slower than the cheaper stage 1b+1c core it was meant to replace; Linux boots to userspace (see Update 15) |

Stage 1a is deliberately empty of microarchitecture: the file starts as a
byte-for-byte copy of `cpu_core.v` with the module renamed, and the commit
proves the second core passes everything the first does. That is not a
formality. It means every later stage has a harness already known to work, and
a diff that contains only the change being made rather than the change plus a
rewrite of the privilege, MMU and atomics logic that fifteen bugs went into
getting right (`tests/README.md`).

### Stage 1b: what was built

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

### Stage 1b: what it measured, which is the point

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

### Stage 1c: where the cycles actually are

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

### Stage 1c: the design, and why it stops where it does

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

### Stage 1c: the store buffer, and what it proved

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

### Stage 1c: the load-completion buffer, rejected and then reinstated

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

### Stage 1d: which of its four pieces actually carries the value

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

### Stage 1d: why it cannot be staged, and what it needs

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

### The comparison happened, and stage 1d lost it

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

### Stage 1d was built anyway

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
Spike, one instruction wide. Believed at the time to be shared with the
in-order core's own known limitation in this area and not new to this
stage - **that belief does not hold up**: see "Update 8" below, where two
clean, dependency-graph-driven `cosim` runs, one per core, back to back,
found `CORE=ooo` diverging and `CORE=inorder` matching Spike exactly.
Whether it was ever really shared, or this was already the same class of
stale-artifact illusion Update 6/7 later caught red-handed, is not known.

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

**Update: a regression had started masking this point behind an earlier,
unrelated panic**, and got fixed on the way to reconfirming the above.
`head_misaligned_cause` - the trap cause the OOO core reports at the ROB head for a
misaligned access - was hardcoded to 32'd6 (store/AMO address misaligned)
regardless of whether the access was a load or a store, unlike
`cpu_core.v`'s own `misaligned_cause`, which has always correctly returned
32'd4 for a load. Bare-metal riscv-tests never caught it: an out-of-order-
issued load's own misalignment check (`issL_trap_now`) already used the
correct cause, and that is the *only* path a misaligned load can take with
paging off. Under Sv32, every load instead takes `load_via_head` (the OOO
load port has no MMU of its own) and hits the buggy head-level check instead
- invisible until something did a misaligned load with paging on. Linux's own
`check_unaligned_access_emulated` self-test does exactly that at boot,
deliberately, to probe whether misalignment is hardware-emulated; told it was
a store fault instead of a load fault, the kernel's store-misaligned handler
failed to decode what was actually a load and panicked outright, well into
kernel console output (memory init, the clocksource, "SBI misaligned access
exception delegation ok") but still PID 1 `swapper/0`, before any driver
probing - `sim_linux CORE=ooo` then timed out at 400,000,000 cycles with the
kernel long since wedged, nowhere near the `ecall`-storm point above. Fixed
by making the cause conditional on
`rob_is_store`/`rob_is_amo`, exactly mirroring `cpu_core.v`. After the fix,
`make linux_trapdiff` confirms the boot is back exactly at the point this
section already describes: zero `U->S` transitions, and 2,909 `S->M` "ecall
from S" traps against in-order's 773 for the same boot (3.76x, matching the
3.8x above), with the store-page-fault-at-`load_elf_binary+0xc30` signature
this doc used to lead with (see "Known defects" below) absent from the trace
entirely - not fixed, just not yet reachable again.

**Update 2: localized well past "an interrupt-delivery gap."** The `3.8x
more ecalls, zero U->S` framing above is real but was read at too coarse a
grain - it describes the whole rest of the boot, not where it starts going
wrong. Bisecting on `+maxcycles` (rerunning `sim_linux` at successively
narrower cycle counts and reading `pc over the last 2000 cycles` against
`software/linux/build/System.map` each time) narrows the actual point of no
return to a ~300,000-cycle window, cycle 94.5-94.8M of the run's eventual
400M-cycle timeout: `Serial: 8250/16550 driver, 4 ports` prints
(`serial8250_init`, `8250_platform.c`), and Linux's own `initcall_debug` boot
parameter (which prints every driver-model `probe()` as it starts and
returns) shows why nothing after it ever prints again - `probe of
serial8250:0`, `:0.0`, `:0.1`, and `:0.2` each return successfully in a few
thousand microseconds; `:0.3`, the fourth and structurally identical to the
other three, never returns. `CORE=inorder`, same kernel image, same
`initcall_debug` build: all five probes (`:0` through `:0.3`, plus a final
`serial8250` summary probe) return, and `serial8250_init` itself returns
after 192ms. This is not a platform or kernel-config gap - the same binary
works on the other core - it is a wide-core correctness bug, now genuinely
localized, not yet root-caused at the RTL level.

What the cycle-bisected trace actually shows, in order: `kernfs_create_dir_ns`
and `kernfs_add_one` (a new sysfs directory going in), then `kobject_uevent_env`
allocating and formatting a netlink environment buffer (`device_add()`'s final
step), then - in the *next* narrower window - `kernfs_free_rcu` and
`delete_node` (a kernfs node coming back *out*, via RCU, which is what a
failed or superseded registration's cleanup looks like, not what a plain
success does), an SBI `ecall` (most likely a timer rearm), and finally
`__schedule()` itself, after which every subsequent window is `do_idle()`
and nothing else, permanently. Something legitimately blocks - `schedule()`
is a deliberate call, not a stall - and whatever is supposed to wake it
never does, even though the periodic timer interrupt that would have to
carry that wakeup keeps firing on schedule for the remaining ~305,000,000
cycles of the run. That last point rules out a blunt "PLIC interrupts are
broken" reading: the timer *is* delivered, throughout; it is one specific
task's wakeup that never happens.

Not yet pinned down further: pure PC-trace bisection has a floor.
`riscv64-unknown-elf-addr2line -e software/linux/build/vmlinux` resolves
function names from `vmlinux`'s symbol table but not source lines (the debug
build here does not carry full line-number DWARF), and there is no call-stack
walker in the harness - `pc over the last 2000 cycles` shows control-flow
edges, not frames, so the actual *caller* of `schedule()` at this exact site,
and the wait primitive it used (a completion, a workqueue flush, a name
collision's error-recovery path - the `kernfs_free_rcu`/`delete_node` pairing
is circumstantial evidence for the last of these, not proof), is still open.
Closing that gap needs either a stack-aware trace (this SoC's own JTAG debug
module, `rtl/debug/dm.v`, could in principle drive a live GDB session against
the Verilator simulation, but wiring that up is its own project) or a
narrower, purpose-built RTL trace once there is a specific signal to watch
for. The reproduction itself is solid and cheap: `make sim_linux CORE=ooo`
with `+maxcycles=94800000` lands inside the steady-state idle loop every
time, and the same image passes on `CORE=inorder` in the same run for
comparison.

**Update 3: found the actual loop, not just where it starts.** "No call-stack
walker" turned out not to matter - `sim/verilator_soc.cpp`'s existing "last
control transfers" ring only kept 16 entries, and the `do_idle` loop alone
produces about nine per pass, so it was overwritten thousands of times over
before this point was ever reached. Raising `BRANCH_RING` (16 -> 4096, later
200,000 for this specific search - two `uint32_t` per entry, so even the
larger figure is 1.6 MB) and adding `+branch_hist=N` to control how much of
it prints - the default stays 16, so this changes nothing about any other
run's output - turns the same mechanism into an effective, if brute-force,
call-stack recovery: walk far enough back and the *caller's* edge is in
there too.

It was. `schedule()`'s own wrapper (not `__cond_resched()`, which keeps
appearing and returning normally throughout - that path is fine) calls
`__schedule()` fourteen times in the traced window; the first thirteen
return. The fourteenth doesn't, and what runs immediately after it - still
inside `__schedule`, which fully executes `sched_clock`/`rcu_qs`/
`update_rq_clock` on the way, all normally - is `dequeue_task_fair` ->
`dequeue_entities` -> `update_curr` -> `update_deadline` -> `avg_vruntime` ->
`div_s64_rem` -> **`__div64_32`**: the CFS/EEVDF scheduler's own vruntime
accounting for the task being switched away from, hitting the generic
(`lib/math/div64.c`) 64-bit-by-32-bit software division routine every 32-bit
RISC-V kernel needs, because RV32 has no 64-by-32 divide in hardware.
Execution never leaves it.

That routine's core loop is provably bounded:

```c
do {
    if (rem >= b) { rem -= b; res += d; }
    b >>= 1;
    d >>= 1;
} while (d);
```

`d` is a 64-bit value produced by repeated doubling, then repeatedly
right-shifted; the loop cannot run more than 64 times before `d` reaches
zero, regardless of `rem`, `b`, or the divisor. `riscv64-unknown-elf-objdump`
against `software/linux/build/vmlinux` (`__div64_32`, `0xc018d934`-`0xc018da8c`)
shows what `-O2` made of it: a hand-scheduled, software-pipelined ~40
instruction sequence spread across nine registers (`a0,a1,a3,a4,a5,a6,a7,t4,
t6` carry the two live 64-bit values' halves; `s0-s2,t0,t3,t5` are scratch
for the borrow/carry chain), computing the conditional-subtract branchily
rather than predicated and folding next iteration's shift into the current
one's tail. Faithful by construction, not by re-derivation - it is the
actual code Linux runs, disassembled, not a reconstruction of the C.

The infinite loop is inside that block, cycling among a fixed small set of
its instruction addresses. A CPU correctly executing sixteen ordinary
integer instructions - shifts, adds, subtracts, unsigned compares, all on
values already in registers - cannot fail to make `d` reach zero. Something
in this dependency chain is computing wrong, and it is only reachable this
way: `+watchpc`'s register dump (`sim/verilator_soc.cpp`, designed for and
so far only exercised against the in-order core) reads
`soc_top.CPU.RF.regs[0..31]` directly, which for `CORE=ooo` is the first 32
of `regfile_phys`'s 64 *physical* registers, not the architectural ones a
renaming core has long since scattered elsewhere - so the dump it produced
here (`sp=0`, implausible for a live kernel stack) is meaningless for this
core as the mechanism stands, and is not evidence of anything by itself.
Getting real operand values needs either fixing that (resolving each
architectural register through the current RAT before reading
`regfile_phys`) or a dedicated debug hook - not attempted here, kept as the
next concrete step rather than a vague one. **Done in Update 10 below**,
exactly that way - `+watchpc` now resolves through `soc_top.CPU.rat[]`
before indexing `RF.regs[]` on `CORE=ooo`, and produces plausible,
`addr2line`-coherent values.

**Update 4: attempted a standalone reproduction, and it did not reproduce -
which is real information, not a dead end.** `software/soc/div64test.c`
(`make sim_div64test`) is `__div64_32`, copied verbatim, called with 14
operand pairs chosen to cover both of its code paths and several edge
cases, each checked against a host-computed answer so a bug shared between
the reference and the target cannot cancel out. Phase 1 - no interrupts,
just the function - passes on both cores: `__div64_32`'s arithmetic itself
is not data-independently wrong, ruling out the simplest version of the
hypothesis.

Phase 2 re-runs the same 14 cases 400 times (5,600 calls) with the CLINT
machine timer interrupt live throughout, rearmed every 97 cycles - short
and not a multiple of the loop's own length, so successive calls catch the
interrupt at a different point in the instruction stream each time rather
than always the same one. `CORE=ooo`: 67,201 interrupts delivered across
the run, zero of 5,600 calls wrong. This rules out the next-simplest
version too: an M-mode timer interrupt landing mid-loop, on its own, is not
enough to reproduce whatever `sim_linux` hit.

What phase 2 does not cover, and the more specific hypothesis worth trying
next: Linux runs this in **S-mode**, reached via the OpenSBI-mediated
machine-to-supervisor timer delegation path (`SBI TIME extension`, `mip`/
`sip` bits, `stvec`), not a direct M-mode handler - the same general
category of mechanism as PR #52's `mip.SEIP` bug from earlier in this
project's history, where the defect was specifically in cross-privilege
interrupt bookkeeping and nothing about the interrupt *arriving* was wrong.
`div64test.c`'s phase 2 tests "an interrupt lands mid-loop"; it does not
test "an interrupt lands mid-loop, gets bounced through M-mode delegation,
and resumes in S-mode" - and that second shape is what the real boot
actually does every ~250,000 cycles.

**Update 5: built that too, and it still did not reproduce.** Phase 3 sets
`mideleg` bit 5 (supervisor timer; never-delegatable cause 7 still traps M
first, which is why an M-mode side exists at all), drops to S-mode, and
runs the same 14 cases with the real cross-privilege mechanism live: M
sets `mip.STIP` on the genuine `mtip`, S-mode traps via delegation, and -
unable to clear `STIP` itself, matching real hardware (`csr_file.v`'s `sip`
write path reaches only `SSIP`) - `ecall`s back to M to have it cleared,
the same shape OpenSBI's SBI TIME extension uses. `CORE=ooo`: 198 delegated
S-mode interrupts, 199 `mtip` traps, 198 `ecall`s, zero of anything else,
zero of 840 calls wrong. The mechanism itself - the same general class as
PR #52's `mip.SEIP` bug - is not where this lives either, at least not in
the shape this file can drive it.

(One dead end on the way there, left in a comment in `div64test.c` rather
than repeated here: the first version of phase 3 timed out on
`CORE=inorder` too, which said plainly this was the test's own arithmetic,
not a CPU defect, before any RTL was ever in question. `S_TIMER_INTERVAL`
too short for the delegation round trip's own overhead created a livelock
- the timer kept re-firing before the interrupted code could ever resume -
and separately, `STRESS_ROUNDS_P3`'s first value made phase 3 too slow for
`sim/tb_ramboot.v`'s fixed-wall-clock watchdog, which looks identical to a
hang in the output and is not one. Both were caught by the in-order control
failing the same way, which is exactly the check that is supposed to catch
"my test is wrong" before it gets read as "the CPU is wrong.")

Two independent, deliberately different reproduction attempts - an
interrupt landing mid-loop, and the full cross-privilege delegation
sequence Linux actually uses - both pass cleanly on `CORE=ooo`. That
narrows what is left rather than closing the question: whatever the real
boot's failure needs, it is not simply "an interrupt during this
function," in either shape this file can drive. Left open, and worth
naming plainly rather than guessing further: the register pressure and
live values `dequeue_task_fair`'s own call chain puts around this exact
call - which `div64test.c` cannot recreate calling the function fresh from
a shallow stack - or a specific micro-architectural timing window neither
of this file's two interrupt patterns happened to land on. `div64test.c`
is a real, permanent addition to the test suite regardless of any of that:
it passes on both cores today, in both phase 2's and phase 3's interrupt
shapes, and will keep proving this specific routine's arithmetic - and now
its behavior under both direct and delegated interrupts - if anything here
ever changes.

**Update 6: `rv32si-p-dirty` stopped diverging, on both cores, while gating
the above - unrelated to any of it, and not fully explained.** The
"83/84" figure a few paragraphs up, and `tests/cosim.py`'s
`EXPECTED_DIVERGENCE` registration of it (added in #64, after this same
divergence had been going unregistered and failing every clean `cosim`
run), both describe a real, previously-reproducible one-instruction
difference from Spike. A fresh `cosim --all` on both cores, run to gate
this update, shows **84/84 on both**: `rv32si-p-dirty` now `XMATCH`es
against the entry that expects it to diverge - it does not diverge at all
anymore, and neither `core_ooo.v` nor `cpu_core.v` (this stage's own
changes touched only the former) has anything in this diff that plausibly
explains an MMU dirty-bit semantic changing on the in-order core too.
Removed from `EXPECTED_DIVERGENCE` rather than left registered-but-wrong,
since a divergence that no longer happens is not "expected" by any
reading of the word - but removed with this note attached rather than
silently, because the mechanism is genuinely not understood: whether this
is an actual fix (of something upstream of both cores - Spike's own
version, the pinned riscv-tests commit, the toolchain building it - none
of which this session touched deliberately) or a marginal, build- or
address-layout-sensitive case that happened to land on the matching side
of it this time is an open question. If it reappears, that is not a
regression in anything gated here; put it back in `EXPECTED_DIVERGENCE`
when it does, with whatever is learned about why.

**Update 7: it reappeared, immediately, on the very next run - so Update 6
is wrong and is being left above rather than deleted, as the record of a
false lead.** The removal above was gated on one `cosim --all` pass on
each core, run by hand. The next thing this branch did was a full,
sequential `make verify_ooo` then (clean) `make verify` - the normal
Makefile dependency graph building `sim/sim_isa.out` fresh as a prerequisite
of `cosim`, not a hand-run sequence with room for a stale artifact to sneak
in. That run's `cosim --all --core=ooo` reproduced `rv32si-p-dirty`
`DIVERGED at instruction 112: different written value` - the identical
signature as the original discovery (`rtl: x5=0x800001d4` vs
`spike: x5=0x00000000`). Same RTL, same test binary, same Spike build as
the "fixed" run days earlier; deterministic Icarus simulation does not
explain two different answers from two runs of the same inputs, which
means the two runs were not actually run against the same inputs - most
likely the earlier "84/84" was contaminated by exactly the kind of stale
cross-`CORE` build artifact this doc has already documented biting
`verilator_check` (see the `verify_ooo`→`verify` sequencing note
elsewhere in this stage's history): `cosim`'s ELF/trace inputs are not
cleaned by the same `rm -f sim/*.out` that fixes `verilator_check`'s
version of this, so a leftover in-order build sitting under the paths
`cosim --core=ooo` reads from would produce exactly this false "now it
matches" result. Not confirmed - the stale artifacts from that run are
long gone - but it is the only explanation that doesn't require Icarus to
be nondeterministic. `rv32si-p-dirty` is back in `EXPECTED_DIVERGENCE`,
`README.md`'s badge is back to 83/84, and the lesson kept for next time
is: a single hand-run `cosim` after switching `CORE=` is not evidence:
trust the result from the ordinary `make verify_ooo`/`make verify`
dependency chain, which rebuilds its own inputs, over a hand-run
`cosim --core=X` in isolation right after a `CORE=` switch.

**Update 8: the badge moved again, on the same evidence this time, because
the trustworthy runs said something more specific than Update 7 gave them
credit for.** Update 7's fix put `rv32si-p-dirty` back in
`EXPECTED_DIVERGENCE` unconditionally, which makes `cosim` expect it to
diverge on *every* core - the same shape of claim as the original,
pre-session registration text ("shared with the in-order core"). But the
run that produced Update 7's evidence was a *pair*: `make verify_ooo`
immediately followed by a clean `make verify` (`CORE=inorder`), both
dependency-graph-driven, neither hand-run. Its `CORE=ooo` leg is what
Update 7 quotes - `DIVERGED at instruction 112`. Its `CORE=inorder` leg,
read in full rather than stopped at the first number, said something
different: `rv32si-p-dirty XMATCH (expected to diverge but did not)` -
`cosim`'s own name for "this is registered as expected to diverge and it
just didn't", which is a hard failure by design (`tests/cosim.py` lines
255-258). Unconditional registration cannot be right for a divergence that
one clean run confirms on one core and the very next clean run confirms
*absent* on the other: something has to give, and per this doc's own
[practices.md §23](../practices.md) - the bench is right - the two clean
measurements win over the inherited comment, not the other way round.

`EXPECTED_DIVERGENCE` in `tests/cosim.py` was never core-aware; nothing
needed it to be until now. It is, as of this update:
`EXPECTED_DIVERGENCE_CORES = {"rv32si-p-dirty": {"ooo"}}`, read by a small
`divergence_expected(name, core)` helper that both call sites (the XMATCH
check and the XDIVERGE check) now go through instead of a bare
`name in EXPECTED_DIVERGENCE`. Confirmed by direct measurement rather than
inference: with the fix in place, `tests/cosim.py --all --core=inorder`
against the just-built `sim/sim_isa.out` (the same binary the clean
`verify` run had just produced - no rebuild, no `CORE=` switch, nothing
for the Update-7-class staleness bug to act on) reports **84/84**, with
`rv32si-p-dirty` a plain `MATCH`; `divergence_expected` was also checked
directly for all four combinations of `{rv32si-p-dirty, rv32mi-p-breakpoint}
× {ooo, inorder}` and returns exactly `{True, False, True, True}` in that
order, matching the intended per-core semantics rather than assumption.

So, precisely, as measured: `rv32si-p-dirty` diverges from Spike on
`CORE=ooo` and matches exactly on `CORE=inorder`. That is not what either
the original registration or Update 6 claimed (both treated it as an
all-or-nothing property of the test), and it is not fully explained -
whether the in-order side was always clean and the original "shared with
the in-order core" text was itself wrong from the start (possibly the very
first instance of this session's stale-`CORE`-artifact class, just never
caught), or whether something between then and now genuinely fixed it on
one core and not the other, is not known. What is known, twice over now,
is which core currently diverges and which does not. `README.md`'s badge
is **84/84** again - `make cosim`'s actual default (`CORE=inorder`) output.
`make cosim CORE=ooo` is also 84/84 - a registered, accepted divergence
counts as a pass in `cosim.py`'s own tally, the same way
`rv32mi-p-breakpoint`'s always has - but for a different reason than
`CORE=inorder`'s 84/84: one of `CORE=ooo`'s 84 is `rv32si-p-dirty`'s
`XDIVERGE`, not a genuine match. Both counts being 84 is not evidence the
core-aware fix did nothing; the number that actually moved is which test
needed the exemption on which core, and that is what
`EXPECTED_DIVERGENCE_CORES` now records instead of leaving implicit.

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
into a single-issue test. See [practices.md §40](../practices.md).

### What stage 1d resolved, closed against the original list, and what a generic OoO-RV32 checklist gets right and wrong about this one

The seven-piece table at the top of this phase was a requirements list, not a
progress bar, and nothing since has gone back and closed it against what
stage 1d actually shipped:

| # | Piece | Landed as |
|---|---|---|
| 1 | Register renaming — RAT + PRF | **Done.** `rtl/ooo/regfile_phys.v`: `PREGS=64` (32 architectural + 32 free), 6-bit tags; `rat[0:31]` in `core_ooo.v`, one entry per architectural register |
| 2 | Reorder buffer, for precise traps | **Done** — this is what stage 1d added over 1b/1c |
| 3 | Reservation stations / scoreboard | **Done**: general out-of-order issue over the whole ROB, not 1b/1c's fixed slot-0/slot-1 pairing |
| 4 | Multiple execution units | **Done**, inherited from 1b/1c |
| 5 | LSQ with memory disambiguation | **Done, but deliberately conservative** — see below |
| 6 | Misprediction recovery | **Done, as rollback, not checkpointing** — see below |
| 7 | Wider fetch and decode | **Not done.** Fetch is still one instruction per cycle into `FB_DEPTH`; stage 1b's own measurement is the reason this row was meant to come first, and it still has not |

A generic list of OoO-RV32 concerns (variable-length fetch, renaming/x0,
memory disambiguation, control-flow speculation) is a reasonable checklist to
run this design against, but running it turns up one item that does not
apply, one that is finished and worth stating plainly as finished, and two
that are real and still open.

**Compressed instructions do not apply.** Neither core implements the C
extension — `dts/soc.dts`'s `riscv,isa` string is `rv32ima_zicsr_zifencei`,
no `c`, and `cpu_core.v`'s own comment on why misaligned-fetch detection
stops at 4-byte alignment says so directly: "Misaligned instruction fetch
(cause 0). Without the C extension...". Fetch and decode work on fixed
32-bit instructions only, on both cores. The aligner/multi-ported-mux cost a
variable-length ISA would add to the fetch buffer is real, but it is not a
cost this design pays today, and nothing in this roadmap plans to add it.

**x0 is guarded twice, and the second guard is not redundancy.** Dispatch
never allocates a physical register for a write to `x0` in the first place
(`dispatch_needs_preg` excludes `d_rd == 5'd0`), so `rat[0]` never leaves its
reset value. Physical register 0 is *also* hardwired to zero at the PRF's
own read ports and write-enable gating, independent of whatever the RAT
says. `regfile_phys.v`'s own comment calls this "belt-and-braces against a
renaming bug rather than something the steady state depends on" — a
reasoned decision to keep the second guard, not an oversight left in.

**Recovery is rollback, not checkpointing, and that was a choice, not a
gap.** The original table left piece 6 open as "RAT checkpointing or
rollback." Stage 1d picked rollback: on a mispredict or trap, the ROB is
walked tail-to-culprit, each entry restoring the RAT mapping it overwrote
and freeing the physical register it had allocated, rather than
snapshotting the whole RAT at every branch and restoring a snapshot in one
cycle. `core_ooo.v`'s own header states the reasoning plainly: "no separate
checkpoint storage, because the ROB's own entries are already an undo log."
The cost is recovery latency proportional to how deep the mispredicted
branch sat in the ROB, rather than a flat one cycle — nothing in this repo
has measured what that costs on this project's actual workload mix, which is
the honest gap in this paragraph, not a claim either way. One real bug
already came out of this exact path: on the recovery cycle, the culprit
instruction's completion-bus write bypassed the ordinary busy-bit clear,
stalling any waiter on that physical register forever — caught by cosim on
`rv32ui-p-jal`, not by any of riscv-tests' own directed tests.

**Two items are real and still open, and neither has been measured yet —
which is the reason neither is a "next stage" commitment, just a candidate
with a stated first step:**

- **No store-to-load forwarding.** The LSQ does real address-based
  disambiguation: an issued store with a known address blocks a younger load
  only at the same word, not every younger load. But `core_ooo.v`'s header is
  explicit that "an aliasing load simply waits for the store to retire
  rather than receiving a forwarded value - simpler, at some cost this core
  does not try to hide." That cost is unmeasured: CoreMark and riscv-tests
  were never built to stress store/load aliasing density, so the honest
  first step, in the same spirit as stage 1c's store-buffer measurement
  above, is a counter — aliasing loads that stalled to a store's retire, next
  to loads that did not need to — before any forwarding logic gets written.
- **No return-address stack.** `rtl/btb.v` is one generic, direct-mapped
  64-entry PC-indexed target cache that predicts every branch, `jal`, and
  `jalr` — `ret` included — the same way: whatever target it last saw at
  that PC. A RAS beats this specifically for call/return pairs, where a
  single `ret` site's correct target changes with call depth and one BTB
  slot cannot hold more than the most recent one. Nothing here currently
  counts how often that actually costs a misprediction, and recursive or
  deeply-nested call patterns are not obviously dense in the
  riscv-tests/CoreMark/Linux-boot mix this project measures against — so, as
  above, the first step is a `jalr`-mispredict counter split by whether the
  site looks `ret`-shaped, not a RAS built ahead of that evidence.

Both are independent of each other and of whatever gets called `1e`; either
could be built alone, and `docs/practices.md` §1 applies to both exactly as
it applied to stage 1c's counters — a change here needs a counter it can
move, not just an argument that it should help.

**Update 9: a real bug was found and fixed by a different route -
`sim_uartirq CORE=ooo`, not another attempt at `div64test.c` - and it is not
the Linux hang.** Said plainly, because the temptation not to say it
plainly is exactly what made this worth writing down: the two symptoms
looked alike. `sim_uartirq`'s "finished after never of 5000 unrelated-work
iterations" (Known Defects, above) and Linux's "a `schedule()` that never
returns" are both "something waiting on an interrupt-driven completion,
under `CORE=ooo`, that never arrives." That resemblance was the whole
reason to chase `sim_uartirq` first: it is 100% reproducible in seconds,
where the Linux hang needs 94.5M cycles and two rounds of purpose-built
reproduction (Updates 4 and 5) had already failed to trigger it any other
way.

Instruction-level tracing (temporary `$display` probes in `rtl/plic.v` and
`rtl/ooo/core_ooo.v`, removed before shipping - the technique, not the
probes, is what's reusable) found a real, previously-undiagnosed bug: the
handler's very first `tx_irq_count++` read back `1` when nothing had ever
written anything but `0` - one cycle after the PLIC's claim register
finished a *different* read with `rdata=1` (a genuinely correct claim ID
for `UART_SRC`). `loadL_can_start` (the out-of-order load-issue path) has
no check for `head_load_owns_port` (the ROB-head-only path every
peripheral/MMIO load must take, per `load_target_needs_head`) being active
on the same cycle; the address mux correctly gives `head_load_owns_port`
priority, so the out-of-order load's own request was never actually driven
that cycle, but `loadL_early_done <= dmem_rvalid` doesn't know that and
latches "done" off a `dmem_rvalid` that belongs to someone else's
transaction. The stolen claim's completion write, downstream, never
happened - it ran off since-corrupted state instead - which is what
permanently wedged the interrupt. Fixed with one added term,
`!head_load_owns_port`, restoring the symmetry `head_load_owns_port`
already keeps on its own side. `make sim_uartirq CORE=ooo` now passes: 60
of 60 interrupts, exactly one per byte, `UART-IRQ-TEST: PASS`.

Then `make sim_linux CORE=ooo` was run again, specifically to test whether
this was the Linux hang wearing a different address. **It is not.** Same
signature, same two addresses trading control forever
(`0xc0049b44`↔`0xc024e6e8`/`0xc024d770`), same `never seen in 400000000
cycles`. The `loadL`-vs-`head_load_owns_port` race is real, was worth
fixing on its own terms, and rules out one specific hypothesis about the
Linux hang rather than confirming it - which is a real result, not a null
one: two symptom-alike bugs with different root causes is itself
information, and the honest record of a hypothesis that didn't survive
contact with the bench is worth exactly as much shelf space as one that
did. `docs/practices.md` §25: a correction fitted to one measurement is a
guess with a number on it - the fix stands on `sim_uartirq`'s own evidence,
not on an assumption about Linux it was never actually shown to satisfy.

**Correction to the paragraph above, found immediately after shipping it:**
"same two addresses" was true as a string of hex digits and wrong as a
claim about what they are. `riscv64-unknown-elf-nm` on the same
`vmlinux`: `__div64_32` is at `c018d934`. `0xc0049b44`/`0xc024d770`/
`0xc024e6e8` are `do_idle`, `arch_cpu_idle`, and `default_idle_call`. The
"last 2000 cycles" trace, at a 400M-cycle timeout, shows whatever is
running *when the timeout fires* - which, if the system genuinely went
idle at cycle ~94.8M and nothing ever wakes it, is correctly the idle loop
for the remaining ~305M cycles, not the original fault. That is not
evidence against Update 3's `__div64_32` finding; it is a different claim
than the one that would be evidence either way, and the paragraph above
stated it as if it were the latter. Re-bisected properly this time,
`+maxcycles` narrowed the same way Update 3 did it: forward progress
(different symbols each step - `up_write`/`down_write`, `sched_domains`
code, ordinary init-time locking) continues cleanly through 94.78M cycles
and the trace is already the stable idle loop by 94.80M - the point of no
return is in that 20,000-cycle window, essentially unchanged from Update
3's original 94.5-94.8M and not moved by this fix, as expected given the
fix cannot even activate under `dmem_mmu_active` (see the `Update 9` fix
comment in `core_ooo.v`: `!dmem_mmu_active` already gates `loadL_can_start`
off whenever Sv32 is on, which is continuously true by this point in
boot). A wider trace at the transition (`+maxcycles=94790000
+branch_hist=300`) shows the *last* activity before idle is inside
OpenSBI (M-mode, `0x9008xxxx`/`0x9009xxxx` addresses, no Linux symbol
resolves there) - consistent with an SBI call the kernel made on its way
to sleeping, not with still being inside `__div64_32`'s own address range
at all at this point. Whether `__div64_32` is still involved earlier in
this same window, and what the specific SBI call is, is not established -
this correction fixes what was overclaimed, it does not extend the
finding. `docs/practices.md` §20 ("do not reason from a measurement you
have already called invalid") applies to the corrected claim now, not just
the original one: treat "goes through an SBI call, then idles, around
94.8M cycles" as the current state of the evidence, not as a new,
confirmed root cause.

**Update 10: a real, permanent tool fix - `+watchpc` now works on `CORE=ooo`
- and a second, deeper methodology error caught inside the same
investigation that fixed it.** `sim/verilator_soc.cpp`'s `+watchpc` dumped
`soc_top.CPU.RF.regs[0..31]` on a match - correct for `cpu_core.v`, where
`RF` is the architectural register file, but `core_ooo.v` also names its
physical register file `RF` (64 entries, `regfile_phys`), so the same code
read the *first 32 physical* registers, which correspond to no fixed
architectural meaning at all. Already known and documented as broken for
`CORE=ooo`. Fixed by resolving through the RAT first
(`soc_top.CPU.rat[0..31]`, one entry per architectural register, holding
its current physical index) before indexing into `RF.regs[]` - `#ifdef
CORE_OOO` only; `cpu_core.v`'s path is untouched. `x0` needs no special
case: the RAT never renames a write to it, and `regfile_phys` separately
hardwires physical register 0 to read zero regardless. Verified two ways:
`make verilator_check` passes cycle-for-cycle on both cores (the fix
touches only code gated behind an unused-by-default plusarg, so this
mainly confirms nothing else broke), and, positively, every `ra` value
read back through the fix during this update's own investigation resolved
via `addr2line` to a real function entry with a coherent, sensible calling
context (`smpboot_thread_fn`, `serial8250_register_ports`, ...) - a
broken resolution would have produced addresses `addr2line` could not
place inside any function, not a coherent call graph.

Used it to re-run this investigation's central check - `initcall_debug` on
`CORE=ooo` - and it reproduces exactly what Update 3 already established,
now on this stage's own current tree: `serial8250:0`, `:0.0`, `:0.1`,
`:0.2` all probe and return in a few thousand microseconds each;
`:0.3` never prints anything at all, success or failure. Not a new finding
- confirmation that nothing in Updates 6-9's fixes moved this.

Then three specific hypotheses, each chased with `+watchpc` on a real
function address rather than guessed at from source alone, and each ruled
out the same way - "never reached":

- `kernfs_drain`'s own `wait_event` call site (the `jal schedule` inside
  its hand-rolled wait loop, `rtl`-adjacent reasoning suggested this given
  Update 3's `kernfs_free_rcu`/`delete_node` mention) - never reached.
  `kernfs_drain` explicitly skips draining for nodes that were never
  activated, "allowing embedding `kernfs_remove()` in create error paths
  without worrying about draining" (its own comment) - the exact case a
  failed `kernfs_create_dir_ns` would be, so this was always a plausible
  dead end, just not a confirmed one until measured.
- `of_platform_serial_probe` (the device-tree-matched 8250 probe entry
  point) - never reached, at all, in the whole run. The naming
  (`serial8250:0.0`-`0.3`, not per-DT-node) is the legacy static-array
  registration path, not the OF one - a wrong assumption from reading
  `8250_of.c` without checking which driver this kernel's boot actually
  uses.
- `serial8250_register_8250_port` - also never reached, for the same
  reason: it is the newer registration API for hotpluggable 8250 devices,
  not what the legacy static-array path (which is what this kernel/DTS
  combination actually exercises) calls.

What *is* confirmed, from `uart_add_one_port`'s own return address:
`serial8250_register_ports()` (disassembled directly, `c026bc30`) is a
straight loop over `serial8250_ports[0..nr_uarts-1]`, calling
`uart_add_one_port` once per slot unless a per-slot skip condition is
already true. It was reached and called `uart_add_one_port` successfully
exactly 3 times (`+watchlast` on `uart_add_one_port`'s own entry) -
consistent with 3 of the 4 legacy slots (`:0.0`-`:0.2`), not yet accounting
for `:0.3`. Whether the loop's 4th iteration takes the skip path (and the
actual `:0.3` probe/hang happens somewhere else entirely, later) or reaches
`uart_add_one_port` a 4th time in a way this specific watch missed, is not
resolved.

**The methodology error, named plainly rather than left implicit:** this
update's own re-bisection (in the correction above) leaned on "does `pc
over the last 2000 cycles` look different" to distinguish real progress
from settled idling. It doesn't reliably: `tick_handle_periodic`'s own call
tree (`timekeeping_update_from_shadow`, `hrtimer_run_queues`,
`rcu_sched_clock_irq`, `sched_tick`, ...) spans dozens of addresses on its
own, so a 2000-cycle window sampled at two different points *inside one
normal, repeating tick* looks exactly as "different" as two windows
sampled during genuine forward progress. Confirmed directly: addresses
this update's own earlier bisection step logged as "still progressing"
(`0xc004dfc8`, `0xc0084ef8`) are ordinary addresses inside this same
tick-handler call tree, not evidence of unique work. `+maxcycles`
bisection on this window shape only ever answers "has the system reached
steady-state idle+tick yet", not "is this the actual point of no return" -
the two coincide by luck often enough to have looked reliable across
several updates, not because they are the same question.
`initcall_debug`/console-output timing (what Update 2's original finding
actually used) does not have this failure mode, because it is tied to a
semantic kernel event, not a raw PC sample - it is the correct tool for
this question and this update's most reliable finding (the exact `:0.3`
stall, confirmed twice now under different investigations) came from it,
not from PC bisection.

Net position, stated plainly: the stall is still `serial8250:0.3`'s probe,
still not reaching `uart_add_one_port` a visible 4th time, and the specific
statement (skip path vs. a call this trace missed) is not resolved. Two
real, permanent things came out of chasing it anyway - a working `+watchpc`
for `CORE=ooo`, and the retirement of PC-window bisection as a reliable
signal for "did this make progress," in favor of the semantic marker this
project already had.

**Update 11: a real gap found via upstream Linux/RISC-V precedent - plain
`FENCE` was a no-op on `CORE=ooo` - and fixing it moves the stall, but does
not close it.** Asked to check open-source OOO-core and Linux-kernel
precedent for this class of bug rather than continuing to probe this
project's own RTL in isolation. Two real upstream references turned up: an
LKML thread ("riscv pending interrupts freezes the kernel...") describing an
unrelated platform's IRQ-controller bug, and an RFC
("riscv: Switch back to CSR_STATUS masking when going idle") describing the
generic gotcha that a WFI executed with interrupts masked via `CSR_IE`
rather than `sstatus.SIE` can never wake. Checked this kernel's config for
the Pseudo-NMI/`CSR_IE`-masking mode that gotcha requires - `arch/riscv/Kconfig`
has no such option at all in this tree, and the periodic timer interrupt was
already independently confirmed (Update 10) to keep waking the CPU
throughout the run, so that exact bug class does not apply here. But getting
to that RFC meant reading `arch/riscv/include/asm/cpuidle.h`'s
`cpu_do_idle()`:

```c
static inline void cpu_do_idle(void)
{
	/*
	 * Add mb() here to ensure that all
	 * IO/MEM accesses are completed prior
	 * to entering WFI.
	 */
	mb();
	wait_for_interrupt();
}
```

`mb()` is `RISCV_FENCE(rw, rw)` - a plain `fence rw,rw`, funct3 `000`, not
`FENCE.I`. `cpu_core.v` treats plain `FENCE` as a no-op, with its own
comment explaining why that is safe there: no store buffer, so nothing can
be in flight for a later instruction to race against. `core_ooo.v` inherited
the same "no-op" decode unchanged - but it is not safe there. `sb_valid`
drains a store to the bus over cycles *after* the instruction that issued it
has already retired (`head_store_absorbed`), which is exactly the delayed
visibility a `fence rw,rw` exists to close: a store the kernel believes is
already visible (an SBI timer arm, an interrupt-controller write) can still
be sitting in the store buffer when `wait_for_interrupt()` executes right
after. `FENCE.I` and `SFENCE.VMA` already had this handled correctly, via
`head_fence_drain_stall` holding the ROB head until `sb_valid` clears; plain
`FENCE` was simply never routed through it. Fixed by adding a third
`rob_is_plain_fence` bit alongside the existing `rob_is_fence_i`/
`rob_is_sfence_vma` ones, set at dispatch from `is_miscmem && !is_fence_i`,
and OR'd into `head_fence_drain_stall`'s condition - the same mechanism,
extended to the case it was missing, not new logic.

**Tested directly against the actual goal, not assumed:** `make sim_linux
CORE=ooo` still fails, but not identically - unlike Update 9's fix, this one
does change the stall. With `+watchpc` bisection through `driver_init()`'s
call sequence (`devices_init`, `buses_init`, `classes_init`, `firmware_init`,
`faux_bus_init` all confirmed reached), `of_core_init` is now reached at
cycle 49,276,583 - it was never reached before this fix (the stall was
`serial8250:0.3`'s probe, at 94.5-94.8M, well inside `driver_init`'s later
`platform_bus_init`). Inside `of_core_init`, `kset_create_and_add` is called
(7 visits, last at cycle 49,276,862), then its `for_each_of_allnodes` loop
attaching each device-tree node to sysfs runs (`__of_attach_node_sysfs`, 19
visits, last at cycle 51,532,532), calling `kernfs_add_one` repeatedly (136
visits total; the last one, at cycle 51,613,530, entered from
`__kernfs_create_file` - a property file, not a directory). That count does
not move between a 60M-cycle run and a 90M-cycle run of the same image: no
further progress at all for 30M+ cycles. `of_core_init`'s own closing
`proc_symlink` call (gated on `if (of_root)`, the last thing the function
does before `driver_init` moves on to `platform_bus_init`) is never reached
- the only hit on that address (0xc014d5c0) anywhere in the run is a single,
earlier, unrelated caller at cycle 44,284,495. `platform_bus_init` itself is
never reached either. The run's tail then shows the hart cycling through
`default_idle_call`/`arch_cpu_idle` - the scheduler's idle path - repeating
forever: whichever thread runs `do_initcalls()` (`kernel_init`, PID 1, per
`rest_init()`'s split from the boot-context idle task) has gone to sleep and
is never woken back up. `kernfs_add_one` takes `down_write(&root->kernfs_rwsem)`
internally (`fs/kernfs/dir.c`); whether the sleep is on that rwsem, on
something `__kernfs_create_file`'s caller chain waits on next, or something
else entirely reachable only from inside that 136th call, is not resolved.

(These cycle numbers were corrected after this update first shipped - see
the note at the end of Update 12.)

Net position: a real, independently-motivated correctness fix - Linux's own
documented invariant for `cpu_do_idle()` did not hold on this core before
this change, regardless of what it does or does not do for this specific
hang - and a real, measured effect on the hang it was chasing: the stall
moves from `serial8250:0.3`'s probe (94.5-94.8M cycles) to somewhere in or
immediately after `of_core_init`'s kernfs node/property population (49-52M
cycles), a genuine behavioral change, not a wash. Whether that is the same
underlying bug surfacing earlier under different timing, or a different bug
this fix's changed timing now exposes, is exactly as unresolved as it
sounds - not claimed either way. `make verify` (`CORE=inorder`, unaffected)
and `make verify_ooo`'s every stage before `sim_linux` (`isa`, `cosim` 84/84,
`riscv-tests` 81/0/3, JTAG, SDRAM, interrupt-driven UART TX, ...) pass
cleanly with this change in place.

**Update 12: the stall is inside one specific `kernfs_add_one` call that
never returns - not somewhere in or after it.** Continuing directly from
Update 11's fix, on the reasoning that "somewhere in or immediately after"
was still too coarse to act on. Reused Update 10's return-address technique
(watch the instruction right after a call site, not just the callee's
entry) rather than guessing from source: `riscv64-unknown-elf-objdump -d`
against `vmlinux` finds every `jal`/`call` site targeting `kernfs_add_one`
- four of them, in `kernfs_create_dir_ns`, `kernfs_create_empty_dir`,
`__kernfs_create_file`, and `kernfs_create_link`. `+watchpc +watchlast` on
each call site's return address: `kernfs_create_dir_ns`'s returns 34 times,
last at cycle 51,551,316; `__kernfs_create_file`'s returns 101 times, last
at cycle 51,600,657; `kernfs_create_empty_dir`'s and `kernfs_create_link`'s
are never reached at all (0 visits - `of_core_init`'s path doesn't use
either). 34 + 101 = 135 returns, against `kernfs_add_one`'s own 136 entries
(Update 11) - exactly one call does not return. Cross-checked against
Update 11's own register capture at `kernfs_add_one`'s 136th (last) entry:
`ra=0xc015b934`, which is `__kernfs_create_file`'s call site - so the
non-returning call is a property-file creation, not a directory creation,
consistent with `__kernfs_create_file`'s return address having already
stopped advancing (its 101st and last return, at 51.6M) roughly 6M cycles
*before* `kernfs_add_one`'s final entry at 57.66M: the loop kept running
after that 101st return - moved to a later property or node, called
`__kernfs_create_file` once more - and this next call's own internal
`kernfs_add_one` is the one that never comes back.

`kernfs_add_one` itself (`fs/kernfs/dir.c:786`) is straight-line code with
no loops: `down_write(&root->kernfs_rwsem)`, a few checks, one link
operation, a second `down_write`/`up_write` pair on
`kernfs_iattr_rwsem` guarding a timestamp update, `up_write` on
`kernfs_rwsem`, an optional `kernfs_activate()`, return. The only two places
it can actually block are those two `down_write` calls. Update 11 already
established that the run's tail sits in the scheduler's idle path
(`default_idle_call`/`arch_cpu_idle`), repeating - a genuine voluntary
sleep, not a tight retry loop - which is the signature of a *contended*
`down_write` parking its caller on a wait queue, not of a corrupted atomic
compare-and-swap spinning forever. That points at a narrower, sharper
question than "why does this hang": something believes `kernfs_rwsem` (or
`kernfs_iattr_rwsem`) is already held, and whatever `up_write` should
eventually wake this waiter either never runs or its wakeup is lost.

A software bug in `kernfs_add_one` itself is unlikely on its face - this is
heavily-exercised, decades-mainlined upstream code, and a genuine
double-lock or missed-unlock surviving to 6.18 would be a well-known issue,
not something this project would be first to hit. That continues to point
at the RTL: an ordering or read-modify-write correctness gap in how the
rwsem's underlying atomic-long operations (RISC-V AMO or LR/SC, there being
no single-instruction CAS) interact with `core_ooo.v`'s store buffer and ROB
- the same general class Update 9's load-arbitration bug and this whole
investigation keep circling - not yet confirmed.

**Where this stopped, and why:** confirming or refuting that hypothesis
needs either the raw contents of the specific `kernfs_rwsem`/
`kernfs_iattr_rwsem` word contended at the hang point, or a trace of the
actual AMO/LR-SC instruction stream around it. `+watchpc` dumps
architectural registers at retirement; it has no way to read memory
contents at a triggered cycle. That gap is the same shape Update 10 hit and
closed by building `+watchpc` itself in the first place - the concrete next
step here is the same kind of tool, not more bisection with the tool that
already answered what it can.

**A correction to Update 11's cycle numbers, found while continuing this
investigation:** Update 11's bisection was run before its own fix's
diagnostic `dts/soc.dts` edit (temporary `initcall_debug ignore_loglevel`
bootargs, used earlier in that same investigation to get a live
`initcall_debug` trace) had been reverted and `sim/linuximage.hex` rebuilt
- so `of_core_init` at "cycle 55,327,794," `kset_create_and_add` at
"55,328,072," `__of_attach_node_sysfs` at "57,583,444," `kernfs_add_one`'s
136th call at "57,664,442," and the stray `proc_symlink` hit at "44,751,548"
were all measured against that verbose image, not the plain-bootargs one
`git diff` actually shows on `main` and that `make verify_ooo` gates. The
extra `initcall_debug`/`ignore_loglevel` console output shifts absolute
timing substantially (more UART traffic, more interrupts) without changing
which code runs - re-measured against the actual committed image, the same
136 total `kernfs_add_one` calls, the same 34/101 split across call sites,
and the same "never reached" results for `kernfs_create_empty_dir`,
`kernfs_create_link`, and `platform_bus_init` all reproduce exactly, just
5-8M cycles earlier: `of_core_init` at cycle 49,276,583,
`kset_create_and_add` at 49,276,862, `__of_attach_node_sysfs` at
51,532,532, `kernfs_add_one`'s 136th (and last) call at 51,613,530
(reproduced identically at both a 60M- and a 90M-cycle cutoff), and the
stray `proc_symlink` hit at 44,284,495. Update 11's prose above has been
corrected in place to these numbers; this update's own return-address
figures (34, 101, 51,551,316, 51,600,657) were already measured against
the correct, plain-bootargs image and needed no change - the mistake was
narrow: reusing one cycle number carried over between two investigations
without re-verifying it against the image each one actually shipped.
Caught by a plain reproducibility check (the same `+watchpc` command giving
a different answer on a supposedly-identical rerun), not by design - worth
naming so the next investigation checks `dts/soc.dts`'s actual committed
state before trusting a cycle number pulled from an earlier session.

**Update 13: found the lock word itself, and it is corrupted - not merely
contended.** Update 12 named the concrete next step: read the actual
contents of the rwsem word `kernfs_add_one`'s hung call blocks on, since
`+watchpc` only dumps registers, not memory. It turned out unnecessary to
build anything new - `sim/verilator_soc.cpp` already has `+writetrace=
ADDR:LEN:FILE`, logging every write the interconnect completes inside a
byte range, built for a different investigation entirely (the wide core's
`execve -EFAULT`, per that flag's own doc comment) but exactly the right
tool here too.

Getting the address needed no struct-offset arithmetic: `down_write`
(`kernel/locking/rwsem.c`) is not inlined, so `+watchpc=<down_write's
entry> +watchlast` reads `a0` - the semaphore pointer - directly out of the
argument register at the last call before the hang. Cross-referencing that
call's `ra` against a disassembly of `kernfs_add_one` (two `down_write`
call sites in the function: one on `root->kernfs_rwsem` at entry, one on
`root->kernfs_iattr_rwsem` later, guarding a parent-timestamp update) pins
it precisely: the hang is on `kernfs_iattr_rwsem`, not the main
`kernfs_rwsem` Update 12 assumed. `a0` at that call gives the virtual
address (`0xc0418144`); converting through this rv32 config's linear map
(`PAGE_OFFSET=0xc0000000`, kernel RAM based at physical `0x90400000`, per
`arch/riscv/include/asm/page.h` and this SoC's own boot log) gives the bus
address `+writetrace` needs: `0x90818144`.

The resulting trace, filtered to that one word across the whole run, is
unambiguous: hundreds of clean alternations - `00000001` (write-locked),
`00000000` (unlocked), repeating - one pair per successful
`down_write`/`up_write` on this lock, matching `kernfs_add_one`'s calls one
for one. The last clean pair is at cycle 51,615,576 (locked) / 51,615,790
(unlocked). Then, at cycle 51,620,040, the word is written `0xffffffff`.
Two further writes, `0xfffffffe` at 51,658,659 and again at 51,659,854, and
then nothing - the word never changes again, matching everything Update 12
already established about no forward progress past this point.

**Why `0xffffffff` cannot come from `down_write`'s own code, checked by
disassembly rather than assumed:** `down_write`'s fast path is the RISC-V
LR/SC idiom for `atomic_long_try_cmpxchg_acquire(&sem->count, &tmp=0,
RWSEM_WRITER_LOCKED=1)`:

```
li   a4, 1
.L0: lr.w  a3, (a0)
     bnez  a3, .L1        ; already nonzero - give up the fast path
     sc.w  a2, a4, (a0)   ; try to store the constant 1
     bnez  a2, .L0        ; SC failed - retry
```

The only value this loop's `sc.w` can ever store is the literal `1` loaded
into `a4` once, before the loop starts. There is no path through this code
that writes `0xffffffff` - ruling out the most obvious "software raced
itself" reading of the trace. `up_write`'s fast path is different: a single
native AMO, `amoadd.w a4, a4, (a0)` with `a4 = -1` -
`atomic_long_add_return(-RWSEM_WRITER_LOCKED, &sem->count)` - which,
applied to a correctly-read `0`, computes exactly `0 + (-1) = 0xffffffff`
in ordinary two's-complement arithmetic. Nothing about that bit pattern is
inherently alarming on its own; `rwsem.c`'s own flag layout
(`RWSEM_WRITER_LOCKED=1`, `RWSEM_FLAG_WAITERS=2`, `RWSEM_FLAG_HANDOFF=4`,
reader count from bit 8, `RWSEM_FLAG_READFAIL` at bit 31) makes `-1` look
like "locked, waiters, handoff, and 8,388,607 phantom readers" only if you
decode it as those fields - it is equally, and more simply, just what
`0 - 1` is in binary.

What is genuinely wrong is the *state*: for `up_write`'s AMO to legitimately
read `0` and subtract 1, some `down_write` must have already put the count
back to a state consistent with that read - but the trace shows the word
was already `0` (unlocked) at cycle 51,615,790, with no `1` written between
then and the `0xffffffff` write at 51,620,040. That is either an
`up_write` called with no matching prior `down_write` success (a spurious
or duplicate unlock), or a read that the CPU itself got wrong despite the
bus-level trace looking clean - `+writetrace`/`+readtrace` only see
Wishbone-level transactions, so a value an AMO's read-side got by internal
forwarding (from this core's store buffer, without ever reaching the bus)
would be invisible to both. Once the word is negative, the damage is
self-sustaining without any further hardware involvement: `down_write`'s
fast path requires reading exactly `0` to succeed (`bnez a3, .L1` sends it
to the slow path otherwise), so no future acquirer can ever take the fast
path again, and every subsequent `up_write` - there is no shortage of
legitimate ones later in boot, on this shared, per-root lock - just
subtracts 1 further from an already-negative count, which is exactly the
second and third recorded writes (`0xfffffffe`, twice, from two more
ordinary `up_write` calls piling onto the already-corrupted value).

**Where this stopped, and why:** this is the most concrete evidence this
investigation has produced - an exact corrupted value, at an exact cycle,
on an exact memory word, with the two competing explanations (extra/
duplicate AMO commit vs. a bad AMO read served from internal forwarding)
narrowed by direct disassembly rather than assumed. Deciding between them
needs reading `core_ooo.v`'s own AMO issue/completion logic - specifically
whether an AMO's read-and-write are guaranteed to observe exactly one
consistent memory state given the store buffer's delayed drain (Update
11's mechanism, for a different instruction class), and whether an AMO can
be issued, committed, or its result latched more than once. That is RTL
reading and signal-level tracing this update did not do - the same kind of
work that found and fixed PR #68's `loadL`/`head_load_owns_port` race, on
the out-of-order load path specifically. Whether AMOs share that path or a
different one (this session's own earlier port-arbitration audit found
`amo_active` tied to `rob_head`, unlike `loadL` - mutually exclusive by
construction, in principle not exposed to that exact race) is the open
question the next session should check first.

**Update 14: two of the obvious hardware explanations for Update 13's
corrupted word, ruled out by reading the actual RTL rather than assumed -
the real one is still open.** Continuing directly from Update 13's own
named next step, before reaching for signal-level tracing: read
`core_ooo.v`'s AMO issue/completion logic and `rtl/soc/cpu_wb.v`'s data
cache against the two most obvious ways an AMO could observe or produce a
wrong value.

**Ruled out: a stale cache read.** `cpu_wb.v`'s data cache (direct-mapped,
one word per line, write-through - its own header comment names exactly
why write-through, not write-back, matters here) documents that "AMOs
bypass the cache on the read phase," and reading the actual logic confirms
it does what it says: `dmem_re` is never asserted for an AMO (only
`dmem_is_amo` is, per `cpu_wb.v`'s own comment on why), so `load_hit =
dmem_re && dc_present` is always false for one, `req = want && !load_hit`
always reaches the real bus, and `dmem_rvalid = load_hit || read_ack`
therefore can only fire for an AMO on a genuine `dwb_ack`. There is no path
by which an AMO's read phase is served the cache's data instead of the
bus's.

**Ruled out: a new speculative load preempting an already-active AMO's
port.** This session's earlier port-arbitration audit (during the FENCE
investigation, before Update 11) found `amo_active` itself tied to
`rob_head`, and confirmed here more specifically: `amo_active`'s own guard
(`!port_taken_by_load && !port_taken_by_store`) is re-evaluated every
cycle, not latched at start, which looked like exactly the shape of race
`head_load_owns_port`'s fix (the giant comment above `port_taken_by_load`
in `core_ooo.v`) was written to prevent - a live transaction losing the bus
to something that starts after it. But `loadL_can_start` explicitly checks
`!port_owned_by_store`, and `port_owned_by_store` is defined as
`!port_taken_by_load && (sb_valid || head_plain_store_now || amo_active)` -
`amo_active` is one of its own OR'd terms. A new out-of-order load cannot
start while an AMO already holds the port; nothing exists to preempt.
Retirement was checked too: `rob_head`/`rob_valid[rob_head]` both advance
in the same non-blocking assignment that clears on `retire_fire`, so the
cycle after an AMO retires, `rob_is_amo[rob_head]` already names the next
instruction - no window for the same AMO's `amo_active` to spuriously
re-assert.

**What is still open, narrowed to three shapes rather than one:** the
corrupted write is `amo_new_value = amo_rdata_q + headS_op2` (the `amoadd`
case, matching `up_write`'s `amoadd.w a4,a4,(a0)` with `a4=-1`) reaching
memory as `-1` from a starting value that should have been `0` on the read
side. That's consistent with (a) `amo_rdata_q` capturing the wrong value
during the read phase despite `dmem_rvalid` looking correctly scoped, (b)
`headS_op2` - the operand register, `-1` here - being wrong at the exact
cycle `amo_new_value` is computed, a bypass/forwarding question this
update did not check, or (c) the AMO's write actually committing twice,
which static reading of the phase and retirement logic argues against but
cannot fully rule out without seeing the actual cycle in question. Every
one of the ideas ruled out in earlier updates and in this one was found by
reading code with a specific, falsifiable question in mind, not by
guessing - the same discipline says not to pick one of these three without
watching the actual instance corrupt. That needs the same tool PR #68 used
to root-cause its own race: temporary, instruction-scoped tracing (`$display`
probes or equivalent) around cycle 51,620,040 specifically, not more static
reading - this update's own two rule-outs are the return on the reading
that was still worth doing first.

**Update 15: found it, with the exact tool Update 14 named - and it is
fixed.** Built the temporary, cycle-gated `$display` tracing Update 14 said
was the actual next step (not part of this diff, stripped before shipping
the fix below): every retirement of the contended `kernfs_iattr_rwsem`
address, captured around cycle 51,620,040.

The read itself turned out to be completely innocent - the first hypothesis
this update ruled out. At cycle 51,620,031, the AMO's read phase completes
with `dmem_rdata=0`, matching memory's actual, correct state (the last
write really had been `0`, an ordinary unlock, at cycle 51,615,786). `0 +
(-1) = 0xffffffff` is exactly what `up_write`'s `amoadd.w a4,a4,(a0)`
(`a4=-1`) computes from that - Update 13/14's "bad AMO read" hypothesis is
wrong; the CPU read what was actually there and computed correctly on it.

Which reopened the "extra `up_write`" hypothesis, now checked by counting
rather than guessing: filtering the full-boot trace to that one address and
counting *completed instructions* (not cycles, which double-count
multi-cycle waits and had made an earlier, narrower attempt at this exact
count look inconclusive) gives 271 `lr.w` completions, 271 matching `sc.w`
completions - every `down_write` on this lock succeeded on its first try,
never once contended, the whole run - and 272 `amoadd.w` completions.
Exactly one `up_write` too many. Widening the trace to the full gap between
the last clean unlock and the corrupted write found no `lr.w`/`sc.w`
activity on this address anywhere in it - the extra `up_write` has no
missing partner nearby to blame; whatever produces it is local to that one
instruction's own handling, not a bookkeeping gap between two calls.

A second, `recovery_fire`-focused trace (`recovery_keep_culprit`, this
project's own marker distinguishing "a plain branch mispredict, retire the
culprit normally" from every other kind of ROB-head redirect - its own
definition is `head_mispredict && !head_take_trap && !interrupt_taken`)
found the answer sitting on the exact same cycle as the corrupted write's
own `amo_done`: a redirect with `keep_culprit=0`, meaning not a plain
mispredict - it coincides with `head_take_trap`, i.e. `interrupt_taken`.
Reading `interrupt_taken`'s own gate explains why: `!head_busy_now`, and
`head_busy_now` folds in `head_dbus_stall`, which folds in `amo_stall`,
which is defined as `!amo_done` - so on the exact cycle an AMO's `amo_done`
turns 1, `amo_stall` turns 0 in the same combinational step, and
`head_busy_now` goes false with it. If a timer interrupt happens to be
pending at that exact instant, `interrupt_taken` fires *instead of* the
retirement this AMO had just earned. `csr_file` is given `rob_pc[rob_head]`
unconditionally as `trap_pc` - right for a synchronous exception, which
needs the faulting instruction re-executed once handled, wrong for an
interrupt, which RISC-V defines as landing *between* instructions: `mepc`
ends up pointing at this AMO's own PC rather than the next one's, so
`mret`/`sret` returns straight back into it. For a plain ALU op that would
be wasted work - the register write had not retired yet, so redoing it is
harmless. For an AMO it is not: the read-modify-write had already reached
the bus during the very cycle it was preempted, a genuinely external and
irreversible effect, not a register waiting to be marked committed - and an
unconditional AMO has no reservation to invalidate the way a re-executed
`sc.w` would (which is exactly why `lr.w`/`sc.w` stayed perfectly balanced
under the identical race: a re-executed `lr.w` is a harmless re-read, and a
re-executed `sc.w` finds `reservation_valid` already cleared by
`head_take_trap` and correctly fails instead of double-writing - only a
plain, unconditional AMO like `amoadd` has no such guard).

**The fix**, one added term: `head_busy_now` now includes `rob_is_amo
[rob_head] && amo_done`, keeping the head "busy" (and therefore
interrupt-ineligible) for the one cycle its own AMO is completing, so
retirement wins that race instead of losing it. Not a new mechanism - the
same `head_busy_now` gate that already protects `head_div_stall` and
`head_mmu_wait_stall` from this exact class of preemption, extended to the
one case it was missing.

**Tested directly against the actual goal, not assumed - the whole reason
this investigation existed:** `make sim_linux CORE=ooo` now reaches `/init`
and prints `VERNIER-RV32-LINUX-BOOT-OK`; `+stopon` sees it at cycle
129,835,614 of a 400M-cycle budget, `+checkuart` confirms all 6,335 UART
bytes sent in order. `make isa CORE=ooo`: 81 passed, 0 failed, 3 xfail -
unchanged. `make cosim CORE=ooo`: 84/84 traces match Spike, including the
one already-accepted `rv32si-p-dirty` divergence - unchanged, and
specifically including every `rv32ua-p-amo*`/`rv32ua-p-lrsc` trace and the
30,804-instruction `vernier-p-pairing` stress test. `make formal`: 5
proved, 0 refuted. `sim_uartirq`, `sim_plic`, and `sim_div64test` - the
three existing tests that exercise interrupts most heavily, `sim_div64test`
specifically delivering 198 delegated S-mode timer interrupts mid-workload
- all still pass on `CORE=ooo`.

**One gate did not run clean, and it is not this fix:** `make verify`'s
`verilator_check` step failed on the `sdramboot` test - Icarus and
Verilator's SDRAM refresh-timing models disagreeing (`sim/sdram_model.v`
vs. `sim/verilator_soc.cpp`, neither of which is core-specific code) -
*before* reaching either core's own gates. Reproduced identically twice on
this branch, then reproduced identically a third time on a clean checkout
of `main` with none of this fix's changes present, ruling this fix out as
the cause with a real control, not an assumption. A new, separate,
currently-undiagnosed defect - written down here rather than left to be
rediscovered, and deliberately not chased further in the same change that
fixes the Linux hang.

Net position: the investigation this whole section documents - Update 2
through Update 14, `serial8250:0.3`, the store-buffer/FENCE gap, `kernfs_
add_one`, the corrupted rwsem word - ends here. `CORE=ooo` boots Linux to
userspace.

A second generic checklist arrived after the one above, structured as four
build phases: minimum-viable OoO, memory system + full privileged features,
SoC integration + Linux bring-up, stabilization + polish. Read literally it
implies starting from an empty repo. Curated against what is actually here,
most of it already exists — the value in the exercise is in the specific
items that turned out to be real gaps, and in correcting the "phase 1" frame
for the rest, so the next reader does not go looking for a CDB, a device
tree, or OpenSBI and conclude they need to be built.

**Minimum viable OoO, item by item.** Fetch+decode with compressed-instruction
support: not applicable, see "compressed instructions" above. Register
renaming (map table + free list): done, see "register renaming/x0" above.
ROB for in-order commit and precise exceptions: done — this is what stage 1d
added over 1b/1c, and it is exactly how this core takes a misaligned-access,
page, or illegal-instruction trap and still names the faulting instruction in
`mepc`. Reservation stations / issue queues: done, general out-of-order
issue over the whole ROB rather than a fixed 1-2-wide window. Functional
units (ALU, MUL/DIV, simple LSU): done, inherited from 1b/1c. **Common Data
Bus for wakeup: done, and under that exact name** — `core_ooo.v` calls them
"Completion buses (CDB): one per completion source," three of them
(`cdbS`/`cdbB`/`cdbL` for store/ALU-branch/load), broadcast to every waiting
reservation-station entry for wakeup. It is not incidental to the one open
item in "Known defects" below either: the CDB-bypass network is exactly what
`nextpnr-ecp5`'s static timing analysis finds a combinational loop through.
Basic branch handling: done (BTB, see above), with the RAS gap already
covered.

**Key correctness requirements for Linux.** Precise exceptions and
interrupts: the ROB is what makes this possible at all, and the Linux-boot
investigation that ran across "Stage 1d was built anyway," Updates 1-15,
turned out to end in exactly this area - Update 15's fix is a precise-
interrupt gap, an AMO's own completion racing `interrupt_taken` on the same
cycle. Memory ordering and atomics:
`core_ooo.v`'s own header states the strategy plainly - AMO/LR/SC "execute
only at the ROB head, because 'the reservation and the write happen in the
same indivisible step' is far easier to keep true when nothing is reordered
around it." That is atomicity by construction (nothing to reorder around),
not atomicity proven to survive reordering, and it is tested via riscv-tests'
`rv32ua` suite plus cosim on `CORE=ooo` (one real AMO bug was already found
this way, `core_ooo.v:766-770`) - not by a test built specifically to stress
address collisions between an in-flight AMO and surrounding loads/stores.
Speculative recovery restoring architectural state cleanly: done for
registers (the ROB-rollback mechanism described above); CSR writes follow
the same ROB-head-only discipline as AMO/LR/SC per `core_ooo.v`'s header
("the trap/CSR/MMU/AMO logic below is close to stage 1c's, retargeted"), so
there is no speculative CSR state to unwind in the first place - a stronger
guarantee than "restores cleanly," bought the same way atomicity was, by not
speculating there at all. TLB side effects specifically under speculation:
the I-side got a real, recent, named fix here (PR #55, `aae2576`) -
`itlb_wait_stall` now explicitly gates `fetch_hit`/`iwb_cyc` during a walk,
replacing what had been an accidental invariant rather than an enforced one.
**The D-side has no equivalent discussion anywhere in this document** - not
flagged as fine, not flagged as open, just silent. That silence is itself
worth recording as a gap. Misaligned accesses: trapped, and the OOO-specific
cause-selection bug in that exact path was this stage's own PR #64. Fences:
no dedicated discussion of `FENCE`/`FENCE.I` under reordering exists in this
document either, alongside the D-TLB gap above - two silences in the same
paragraph of the generic checklist, not one.

**Verification emphasis - two real, unmet asks, alongside the two open
items already logged above (LSQ forwarding, RAS).** Directed tests for
renaming/ROB/exception recovery specifically: `tests/vernier/` has
`loaduse_csr.S` and `pairing.S`, neither aimed at rename/ROB/recovery by
name. The one real recovery bug found in this design (a completion-bus
write bypassing the busy-bit clear on the ROB-rollback path) was "caught by
cosim on `rv32ui-p-jal`, not by any of riscv-tests' own directed tests" -
this project's own words for incidental coverage, not purpose-built
coverage. Random instruction streams against Spike: absent. `cosim.py` is
directed (a fixed corpus, compared exactly) and that is a real, brutal
check on its own terms, but it is not what a random-stream fuzzer would
catch - inputs nobody wrote a test for. Neither is a criticism of what is
here; both are honestly-scoped gaps the same way the LSQ-forwarding and RAS
items above are, and belong in the same queue, not ahead of it by default.

**Everything else in that generic plan already exists, at a phase number
that is not this one, done in enough detail that repeating it here would
just be a worse copy:**

| Generic-plan phase | Where it actually lives | Status, briefly |
|---|---|---|
| Data/instruction cache | Phase 3 — "Make it fast enough to be interesting" | Done: 1.79× CoreMark from the I-cache alone; D-cache +1.11% |
| Full Sv32 under speculation | Phase 5 — "Run software this project did not write" | I-side speculation gated (PR #55); D-side has no discussion, per the gap above |
| CLINT-style timer, interrupt controller | Phase 0 (CLINT) / already in every phase since | Done, on hardware, since Phase 0 |
| Debug module | Phase 6 — "Debug infrastructure" | Done: JTAG, `dm.v`, used throughout this session's own investigation |
| Complete SoC, interconnect, UART | Phase 0 | Done, on hardware |
| Device tree | `dts/soc.dts`, 302 lines | Real and load-bearing — OpenSBI and Linux both parse and act on it; three device-tree bugs already found and fixed (a UART FIFO claim, a timebase-frequency error, an FDT address placed outside mapped RAM) |
| OpenSBI / M-mode firmware | `software/opensbi/` | Real `PLATFORM=generic` FDT-driven port, boots on board and in `make sim_opensbi`; five real firmware defects already found and fixed there |
| U-Boot | — | Deliberately skipped: `fw_jump` already knows where `mkimage.py` packed the kernel, so there is nothing for U-Boot to do |
| Linux kernel, to a login shell | Phase 5 / Phase 7 | **Partial, and this is the one line in the table worth reading twice.** Both cores now reach `/init` and print a static userspace banner — `software/linux/initramfs/init.c` is 193 lines with no `fork`/`exec`/`wait` in it, because there is no rv32 Linux libc on the build machine to link a real shell against. `CORE=ooo` did not reach userspace at all for most of this investigation; "Stage 1d was built anyway"'s Update 15 has the fix |
| fork/memory-pressure/context-switch stress | — | Not attempted, and cannot be until the row above moves — nothing to stress-test without a second process |
| Multi-core / SMP | Phase 13 — "Multi-core: both cores, one SoC" | **Every "Done when" clause closed, for the in-order core, in simulation.** `rtl/soc/soc_top.v` genuinely builds and runs two harts (`NUM_HARTS=2`); cross-hart LR/SC is coherent (`rtl/soc/reservation_monitor.v` wired to both, a directed test proves a real hazard); `dts/soc.dts` declares both harts and OpenSBI detects them (`Platform HART Count : 2`); and `CONFIG_SMP=y` Linux boots both harts to userspace (`smp: Brought up 1 node, 2 CPUs`, `/proc/cpuinfo` shows harts 0 and 1). `software/soc/bootrom.c` also gained a real mailbox (`crt0_rom.S` parks every non-zero hart, hart 0 releases them with a correct `mhartid` in `a0`) and, separately, a real device tree in `a1` (Stage 13: `dts/soc.dtb` embedded in ROM, `a1` no longer a literal 0); `rtl/debug/dm.v`'s own `hartsel` now reaches every hart too, not just hart 0 (Stage 14, with a real cross-hart register-isolation proof) - all three proven through the real boot/debug paths rather than a shortcut. `CORE=ooo` now has real cross-hart LR/SC coherence too (Stage 15 gave it the same reservation ports `cpu_core.v` has; Stage 16 wired them to a real `reservation_monitor` instance and proved the same cross-hart hazard `sim/tb_soc_2hart_lrsc.v` already proved for the in-order core) and boots the same `CONFIG_SMP=y` Linux to userspace on both harts too (Stage 17, `sim_linux_2hart CORE=ooo`, first attempt, no new coherence bug found). `CORE=ooo` also gained the same halt/resume/single-step/register-access ports `cpu_core.v` has (Stage 18), now wired to a real `rtl/debug/dm.v` the same way `cpu_core.v`'s own are (Stage 19) - `sim/tb_jtag.v` proves the real DMI/Abstract Command path against `core_ooo.v` too, including single-step and cross-hart isolation. Still open: no board build has ever asked for `NUM_HARTS>1` - nothing outside simulation can reach a second hart yet — Phase 13 has the full account |
| Performance counters | `rtl/csr_file.v` | Only the RISC-V-mandated minimum: `mcycle`/`minstret`(+high halves)/`cycle`/`instret`/`time`. No `mhpmcounter3-31` — cosim's own Spike invocation excludes `zihpm` because this core does not implement it |

**One item from the generic plan's "Key Risks" section is worth quoting
back rather than curating, because this project already lives it rather
than needing to be told it:** "Continuous co-simulation against a golden
model (Spike/NEMU) saves enormous debug time." Every bug fix cited in this
document by a `core_ooo.v` line number was found this way, not by
inspection - `docs/practices.md` §23, "when the bench and your reasoning
disagree, the bench is right," is this project's own version of the same
advice, arrived at independently.

## Known defects

**RESOLVED - the wide core's Linux boot did not reach userspace; root-caused
and fixed.** See "Stage 1d was built anyway," Update 15, for the full
account. `make sim_linux CORE=ooo` now reaches `/init` and prints
`VERNIER-RV32-LINUX-BOOT-OK` - `stopon` sees it at cycle 129,835,614 of a
400M-cycle budget, all 6,335 UART bytes sent in order. Left here, struck
rather than deleted, as the record of what this entry used to say (the last
state before the fix, Update 13's "corrupted rwsem word" finding, and
everything the chase through Updates 1-14 built up to reach it):

`make linux_trapdiff`
boots the same image on both cores and compares the traps; the "Stage 1d was
built anyway" section above has the current, authoritative account. As of
"Update 13," the point of no return is `kernfs_add_one`'s
`down_write(&root->kernfs_iattr_rwsem)` (cycle 51,613,530 of 400M for the
call itself; the underlying corruption is at cycle 51,620,040) - and this is
no longer just "entered but never returns": `+writetrace` on the rwsem's
own memory word shows hundreds of clean, correctly-alternating
lock/unlock writes, then one write of `0xffffffff` where legitimate
software could only have written `0` or `1` at that point, then two more of
`0xfffffffe` as later, ordinary `up_write` calls pile onto the
now-permanently-negative count - after which the word never changes again.
`platform_bus_init`, the very next call in `driver_init` after
`of_core_init` returns, is never reached. Update 13 has the full trace,
the disassembly proof that `down_write`'s own fast path cannot be the
source (it can only ever write the literal `1`), and the two remaining
hypotheses - a spurious/duplicate `up_write` commit, or an AMO read served
by internal forwarding that never reached the bus `+writetrace` watches -
neither yet distinguished from the other. Either way this points at the
same class of RTL ordering/read-modify-write gap this investigation keeps
finding (Update 9, Update 11), now narrowed from "somewhere in the
memory-ordering machinery" to "this core's AMO issue/completion path
specifically." The run's tail shows the hart parked in the
scheduler's idle path (`default_idle_call`/`arch_cpu_idle`), repeating
forever: the thread running `do_initcalls()` has gone to sleep and is never
woken. This location is new as of Update 11's fix (plain `FENCE`
now actually drains the store buffer, matching Linux's own documented
`cpu_do_idle()` invariant, where before it was silently a no-op inherited
from `cpu_core.v`) - the stall used to be at cycle 94.5-94.8M, inside
`serial8250_init`'s legacy-port registration loop, the fourth of four
structurally identical `uart_add_one_port()` calls (confirmed via Linux's
own `initcall_debug`: probes `serial8250:0` through `:0.2` return in a few
thousand microseconds each, `:0.3` never does). That finding is not wrong,
but it is no longer reachable - Update 11 has the full account of both
locations and exactly what changed. `CORE=inorder`, identical kernel image,
still passes all probes and reaches userspace either way - ruling out a
platform/kernel-config explanation. The periodic timer interrupt that would
carry the eventual wakeup keeps firing for the rest of the run regardless,
so this is not a blanket "PLIC interrupts don't work" - one specific task's
wakeup does not happen. That "no call-stack walker" gap did get closed -
"Update 3" above found the exact loop (`__div64_32`, the kernel's software
64-bit division routine, reached from the CFS/EEVDF scheduler's own
vruntime accounting) by widening an existing testbench ring rather than
building a new tool - and "Update 4" and "Update 5" describe two different,
deliberately constructed reproductions of it (`software/soc/div64test.c`)
that both passed cleanly on `CORE=ooo`, narrowing but not yet closing what
it actually takes to trigger.

This entry used to say something different: a supervisor store page fault at
`load_elf_binary+0xc30`, storing to user virtual address `0x00040000`
(`software/linux/README.md` and [practices.md §41-42](../practices.md) have that
investigation in full). That finding is not wrong, but it is no longer
reachable - the boot now stops earlier than `execve`, at the point above, so
whether the stray store still exists cannot currently be reconfirmed either
way. Two fixes changed the failure point since: `head_mmu_wait_stall` (this
section) moved it from a complete hang to the `ecall`-storm point; a fixed
`head_misaligned_cause` (PR fixing the OOO core hardcoding cause 6 for every
misaligned access at the ROB head, including loads reaching it via
`load_via_head`, where cause 4 is correct) removed a newer regression that
had started masking that same point behind an earlier kernel panic -
Linux's own `check_unaligned_access_emulated` self-test deliberately issues a
misaligned load, got told it was a store fault, and the kernel's
store-misaligned handler failed to decode a load and panicked. Fixing it did
not move the boot past the `ecall`-storm point; it restored the boot *to*
it.


**`CORE=ooo` had no Fmax: nextpnr's static timing analysis failed outright on
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

**Investigated further: the loop is not the case the `.vlt` waiver's own
reasoning covers, and this entry was wrong to imply it was.** That
reasoning ("a specific tag match is a runtime condition, always false for a
producer reading its own not-yet-computed result") is airtight for the two
places `core_ooo.v` actually reads its own bus - Class B's operand read
(`issB_a_reg`/`issB_op2`, `core_ooo.v:932-944`) excludes `cdbB`; the ROB
head's operand read (`headS_op1`/`headS_op2`, `core_ooo.v:1019-1028`)
excludes `cdbS` - both by construction, both with the "must not consult
that same bus" comment at `core_ooo.v:634-643` naming exactly why. Tracing
the reported loop (nextpnr's #3941) through the actual netlist finds it
does **not** close through either self-exclusion. It closes through a
*different* pair of arms, each individually real and wanted:
`headS_op1`'s `cdbB` arm (`core_ooo.v:1021` - the ROB head legitimately
bypassing a completing Class-B ALU result into its own address/MUL
computation) and `issB_a_reg`'s `cdbS` arm (`core_ooo.v:934` - Class B
legitimately bypassing the head's completing result into its own operand),
feeding back into each other: `cdbB_val` (`core_ooo.v:950`) →
`headS_op1` → (through `head_mul_result`/`head_mmu_wait_stall`, both live
in `headS_op1` same-cycle) → `cdbS_val`/`cdbS_valid` (`core_ooo.v:1768-
1770`) → `issB_a_reg` → `classB_result` (`core_ooo.v:946`) → `cdbB_val`,
closing it. The MMU's `va` and the divider's operands sit in the same
combinational cone because `headS_op1` feeds both directly (`mmu.v`'s
`resolved`/`fault` are combinational in `va` on a TLB hit, `mmu.v:221`) -
which is why nextpnr reports one connected loop through all four
subsystems named above rather than something smaller.

Whether *this* pair can ever be live simultaneously - the ROB head needing
a result from whatever Class B is issuing, and that same Class-B entry
needing the head's result, in the same cycle - reduces to whether Class B
can ever be issuing the literal instruction the head's own tag points to
while that instruction's own operand tag points back at the head. Manual
tracing through the free-list (`core_ooo.v:1907-1998`: a physical register
is only pushed back to the free list, at `core_ooo.v:1981`/`1995`, as
`rob_old_preg[rob_head]` - the mapping the retiring head instruction
itself superseded - on the retiring instruction's own retirement) supports
that a *stale, reused-tag* version of this collision is impossible: freeing
a register requires its superseding writer to retire, and in-order
retirement means any legitimate reader of the freed register was
necessarily older than that writer and must already have retired itself -
the same "age truncates the graph" shape the `.vlt` file's argument
already uses, just applied to a pair of instructions instead of one. What
this reasoning does **not** settle is whether `issB_idx` (whichever entry
Class B is issuing) can ever *legitimately coincide* with an instruction
the ROB head depends on while *that* instruction's own operand,
simultaneously, depends on the head - which needs tracing `issB_idx`'s
selection logic and the AMO path (where a single ROB entry's arithmetic
may route through Class B while its address/completion routes through
`headS`) further than was done here to close out.

**No RTL was changed.** Restructuring either arm to break the loop is a
real wakeup-latency cost (the head loses same-cycle forwarding from Class
B, or Class B loses same-cycle forwarding from the head), not a free
exclusion like the two self-reads already are - and attempting that
restructuring without first being certain whether the value-level case is
truly unreachable risks trading a nextpnr limitation for a real,
much-worse-to-find data-hazard bug in the out-of-order core's renaming
logic. That trade is not worth making under uncertainty. The concrete next
step, if picked up again: either finish the `issB_idx`/AMO trace to a
decisive answer, or - since this project already has bounded model
checking for exactly this shape of question (`make formal`,
`formal/fv_regfile.v` et al.) - build a small, scoped formal harness around
just the free-list/tag-liveness invariant (not the whole core, which is
far too large a state space to be tractable) and let z3 answer the
liveness question this investigation could not.

**Investigated a second round: a formal proof would not actually fix
this, and a much narrower candidate fix was found - blocked on one
specific, testable, unresolved question.**

First, a correction to the previous round's own proposed next step. A
formal proof that the `headS_op1`/`cdbB` and `issB_a_reg`/`cdbS` arms can
never be simultaneously live would **not** make `nextpnr` produce an Fmax
number, even a perfect one: static timing analysis reasons about the wire
graph, not about which select conditions are reachable, so the structural
cycle stays exactly as reported regardless of what a formal tool proves
about it - same as `--ignore-loops` above being "a different kind of
wrong, not a smaller one" rather than a fix. A proof only has value here as
evidence that *removing* an arm is safe, not as a fix in its own right -
the loop can only actually be broken by removing something from the RTL.

That reframing points at a narrower, more promising target than either the
`headS_op1`/`cdbB` self-loop question or the `issB_idx` trace: **whether
`headS_op1`/`headS_op2`'s `cdbB`/`cdbL` arms (`core_ooo.v:1019-1028`) are
ever actually *consumed* by anything, rather than whether they are ever
*live*.** Traced every reader of `headS_op1`/`headS_op2` in the file
(`grep -n "headS_op1\|headS_op2" rtl/ooo/core_ooo.v`) against `headS_ready`
(`core_ooo.v:1012-1013`), which is gated by `rob_r1_ready[rob_head]` - a
*registered* flag (`reg`, `core_ooo.v:541`) that can only ever become true
one cycle *after* a matching CDB broadcast, via the clocked wakeup-snoop
block at `core_ooo.v:2023-2030`, never on the same cycle as the broadcast
itself. Every consumer checked ends up gated by `headS_ready` (directly, or
through `head_exec_done`/`head_redirect_valid`/`amo_active`, all of which
AND it in): `cdbS_valid` (`core_ooo.v:1768`, via `head_exec_done`),
`interrupt_taken` (`core_ooo.v:1232`, directly against
`rob_r1_ready[rob_head]`), `head_redirect_valid` (`core_ooo.v:1298` -
branch mispredict, traps, `mret`/`sret`, `fence.i`, `sfence.vma`, all of
it), `btb_train_en` (`core_ooo.v:1311`), and `amo_active`
(`core_ooo.v:1406`). Since `headS_ready` cannot be true on the exact cycle
`cdbB`/`cdbL` would first present a same-cycle bypass value, and by the
*next* cycle `rob_r1_val[rob_head]`/`rob_r2_val[rob_head]` (the mux's own
fallthrough arm) has already been registered to the identical value via
that same wakeup snoop - every one of these consumers would see the exact
same result whether the `cdbB`/`cdbL` arms exist or not. If that holds for
every consumer, removing them is a genuinely free fix: `headS_op1`/
`headS_op2` would no longer combinationally depend on `cdbB` at all,
breaking the loop's first link (`cdbB_val -> headS_op1`) with no latency
cost anywhere, since the arms never mattered to begin with.

**One consumer breaks that pattern, and it is the reason nothing was
changed.** `csr_file`'s `.we` port (`core_ooo.v:1269`) is gated by
`headS_valid && rob_is_csr[rob_head] && rob_csr_we[rob_head] &&
!interrupt_taken && head_ex_commit` - and `head_ex_commit`
(`core_ooo.v:1237`) is only `!head_dbus_stall && !head_fence_drain_stall`,
with no `headS_ready`/`rob_r1_ready[rob_head]` term anywhere in that
chain. `csr_op_operand` (`core_ooo.v:1140`) reads `headS_op1` for the
register form of `csrrw`/`csrrs`/`csrrc`, and `csr_file.v`'s own write path
(`csr_file.v:423`, `else if (we) case (addr) ... <= wdata`) has no
idempotency guard against being asserted on more than one cycle - if `we`
genuinely can go high before `rob_r1_ready[rob_head]` is set, on a cycle
where the CSR instruction's own operand tag does not happen to match a
live `cdbB`/`cdbL` broadcast, `csr_op_operand` reads whatever garbage or
stale value currently sits in `rob_r1_val[rob_head]`, and it would land in
the CSR file.

**This is not a confirmed bug - it is the specific, open, testable question
the fix above is blocked on**, and it was not chased further this round.
Two things are worth naming honestly: this would be a pre-existing
condition, unrelated to and unaffected by whether the `cdbB`/`cdbL` arms
are removed (removing them cannot make an already-live hazard worse in any
way that matters, since either a matching bypass covers the gap today and
would stop doing so, or nothing does and the gap was already there); and
this project's own extensive verification - 82/82 Spike co-simulation
traces, the full riscv-tests suite, CoreMark, and a Linux boot that
exercises CSR writes constantly (`satp`, `mstatus`, `mie`, PLIC context
registers) - has not caught it, which is itself evidence, though not proof,
that either it is not reachable or existing coverage has never happened to
put a slow-latency producer immediately before a register-form CSR write
with nothing between them. **The concrete next step: a small, directed
test - a multi-cycle producer (a divide is the obvious choice; `muldiv_div`
is not single-cycle) immediately followed by a register-form CSR
read-modify-write of its result, with nothing between them to absorb the
latency, checked against the expected value - would settle this
empirically** rather than by further reading. If `csr_file` ends up
holding the correct value regardless, `headS_op1`/`headS_op2`'s `cdbB`/
`cdbL` arms can be removed as a free fix for the reported loop. If it does
not, that is a real bug worth fixing on its own merits, independently of
Fmax, before anything here is touched.

**Round 3: the test was built, the CSR question is settled, the fix is
real and shipped - and it does not close this defect. The actual scope is
larger than any round here has understood it to be.**

`sim/tb_ooo_csr_hazard.v` is the directed test round 2 named: `li a1,
1000000` / `li a2, 7` / `div a5, a1, a2` / `csrrw x0, mscratch, a5` /
`csrrs a6, mscratch, x0`, watching `csr_file`'s `we` port and
`headS_ready` every cycle via hierarchical reference. Before trusting a
clean result, a debug build with cycle-by-cycle tracing confirmed the test
actually exercises the window rather than missing it: the divide (`rob_
head`=3) runs `div_busy` for ~33 cycles, and the moment it completes,
`rob_head` advances to the CSR instruction (entry 4) **on the same clock
edge** the registered wakeup-snoop sets `rob_r1_ready[4]` - `headS_ready`
reads as already true the very first cycle the CSR instruction is visible
as head. That is not a coincidence of this one test: retirement is
strictly in-order and exactly one entry per cycle, so an immediately-
adjacent producer/consumer pair is the *tightest possible* timing any
pair can ever have, and it is already safe - anything less tightly
coupled has even more slack. `we` was asserted before `headS_ready` zero
times across the run. The `cdbB`/`cdbL` arms were removed from
`headS_op1`/`headS_op2` (`core_ooo.v`) on the strength of that result,
verified clean against cosim (84/84 traces, including both documented
`XDIVERGE` cases, unaffected), the full riscv-tests suite (81/81), and
`make sim CORE=ooo`'s own regression (unchanged BTB mispredict count).
This is a genuine, tested simplification and it is shipped - dead code
removed, a new permanent regression (`sim_ooo_csr_hazard`, now in `make
verify`) covering a question nothing tested before.

**It does not fix Fmax.** `CORE=ooo BOARD=ulx3s85 ./fpga/synth/
synth_ecp5.sh` still fails identically on all six seeds with the fix
applied: `ERROR: Timing analysis failed due to combinational loops`,
now reporting **"Found 2780 combinational loops."** Sampling loops across
that list (1, 2, 5, 10, 50, 500, 1500, 2780) found the overwhelming
majority are not in the CDB network at all - they run through
`wb_interconnect.v`'s bus arbitration (`BUS.decoded`/`BUS.hit`/
`BUS.fin_ack`/`BUS.m1_adr`) and `cpu_wb.v`'s D-cache
(`BUSADAPT.dc_data`/`dc_line`), modules shared byte-for-byte with
`CORE=inorder`, which synthesizes to a real, closing Fmax on the same
toolchain. Those modules cannot be intrinsically cyclic on their own -
the far more likely explanation is that `core_ooo.v`'s own genuine
CDB-network cycle seeds a strongly-connected component that nextpnr's
SCC-based loop detection cannot cleanly separate from otherwise-acyclic
logic that merely shares fan-in/fan-out with it - once *anything* in the
netlist is provably cyclic, everything reachable from it in both
directions can end up reported as part of the same tangle, whether or
not it is cyclic on its own.

`regfile_phys.v` is the prime remaining suspect for that seed: its own
dispatch-time read ports (`rdata1_a`/`rdata2_a`, `regfile_phys.v:66-75`,
consumed one level up as `dispatch_r1_val`/`dispatch_r2_val` at
`core_ooo.v:681-692`) still mux across all three `cdbS`/`cdbB`/`cdbL`
write-data inputs, untouched by this round's fix and never traced the
way `headS_op1`/`issB_a_reg` were.

**This revises the scope stated in every round before this one.**
"Restructuring the completion-bus muxing, not a local patch" already said
this would not be small; it did not say the tangle would turn out to
include the bus interconnect and the data cache, or that fixing one real,
verified, individually-dead pair of mux arms would leave 2780 reported
loops essentially unchanged. Closing this for real needs at minimum:
finding and cutting whatever remaining genuine CDB-network cycle(s) still
exist (`regfile_phys.v`'s own write-data muxes are the most direct
remaining lead, per above), each requiring the same standard of proof
this round set - a full trace, an empirical test where reasoning alone
could not close the question, and a real synthesis run to confirm the
fix actually changes nextpnr's verdict rather than assuming it - and then
re-measuring whether the bus/cache loops disappear once the seed is gone
or turn out to be a second, genuinely separate defect. Given three rounds
have each found the next layer only by getting all the way to a real,
verified fix and then actually re-running synthesis, further work here
should keep doing exactly that rather than reasoning further from the RTL
alone.

**Round 4: `regfile_phys.v`'s own bypass was structurally dead code, not
just timing-gated - removed it, re-ran synthesis, still fails, and the
next candidate looks like a real feature rather than more dead code.**
This is where the "hunt for one more dead arm" approach this shape of
investigation has used for three rounds running stops being the right
tool.

`regfile_phys.v`'s `rdata1_a`/`rdata2_a` (round 3's named lead) turned out
to be dead by a cleaner argument than `headS_op1`'s arms were - no timing
analysis needed at all. `rdata1_a`/`rdata2_a` have exactly one reader in
the whole codebase: `dispatch_r1_val`/`dispatch_r2_val` at
`core_ooo.v:681-692` (confirmed by `grep -n "rf_rdata1\|rf_rdata2"
rtl/ooo/core_ooo.v` before touching anything - two hits, both the
fallthrough arm of those two wires). That caller already performs the
identical `cdbS`/`cdbB`/`cdbL` tag-match check itself, one level up,
before ever falling through to `rdata1_a`/`rdata2_a` - so by the time
`regfile_phys.v`'s own copy of the same three comparisons runs, the
caller has already established none of them match. The two checks share
every input; the inner one cannot ever produce an answer the outer one
did not already rule out. Removed the `w0`/`w1`/`w2` bypass ternary from
`rdata1_a`/`rdata2_a` (the write-side logic that actually updates `regs[]`
was untouched - only the redundant read-side copy), re-verified against
`sim_ooo_csr_hazard`, `make sim CORE=ooo` (unchanged BTB mispredict
count), cosim (84/84 traces), and both `make verify`/`make verify_ooo`.

**Still fails.** `CORE=ooo BOARD=ulx3s85 ./fpga/synth/synth_ecp5.sh`, all
six seeds, same `ERROR: Timing analysis failed due to combinational
loops` - now reporting **3083** loops, not fewer. That number moving in
the wrong direction is not evidence this made things worse; nextpnr's
loop count is however its SCC-decomposition happens to split (or not
split) whatever remains connected, not a distance-to-done metric, and
reading it as one is exactly the kind of number this project's own
practices warn against trusting without knowing what it measures. The
trace's tail now runs overwhelmingly through `issL_addr_calc` and a long
`MMU.va` carry chain, not through `RF.wdata1`/`RF.wdata2` (which no
longer exist - that specific edge is confirmed gone).

**The next candidate is not obviously more dead code, and that is the
important finding of this round, not just a name to chase.**
`issL_scan_addr` (`core_ooo.v:811-877`) is the out-of-order load-issue
scan: a combinational `for` loop over the whole ROB, computing a
candidate load's address - including a same-cycle `cdbL` bypass arm
(`core_ooo.v:833`) - for whichever entry the scan is currently
considering, and latching it into `issL_addr_calc` the moment it finds
the oldest ready, address-valid, hazard-clear load. Unlike `headS_op1`
and `regfile_phys.v`, there is no `headS_ready`-shaped registered gate
visible here, and no second identical check one level up to make it
redundant - `issL_addr_calc` feeds the actual memory address a load
issues with, and if `rtl/soc/cpu_wb.v`'s D-cache answers a hit
combinationally (which the "Phase 3" section above said it does - "one
word per line, so there is no fill state machine... arrays are read
asynchronously"), then a load whose base register is a completing
Class-L result **this same cycle** and whose data comes back **this same
cycle** is exactly the same-cycle back-to-back load chaining a real
out-of-order design is built to have - a feature, not dead code. Whether
it is *reachable* the way `headS_op1`'s arms were not is a genuinely
different, harder question than the last two rounds answered, and this
round did not attempt to answer it: this entry has already had to
self-correct once for reasoning about which arms a loop closed through
without fully tracing the netlist first (the "Investigated further"
section above opens by saying plainly that the original entry "was wrong
to imply" the loop matched the `.vlt` waiver's self-reference argument) -
guessing again here under the same pressure is not worth repeating.

**Kept and shipped anyway, same reasoning as round 3.** Removing genuinely
dead code that has now twice been proven dead by two different, both
rigorous arguments (a timing-registration argument for `headS_op1`, a
pure structural-redundancy argument for `regfile_phys.v`) is worth doing
on its own merits regardless of whether it closes this defect - and
twice now, on its own, it has not. **What this round changes about the
recommended next step**: stop looking for a third dead arm to remove
one at a time. `issL_scan_addr`'s `cdbL` bypass is plausibly load-to-load
forwarding this design actually wants, which means closing this defect
for real - if it is closeable without giving up that feature - needs the
"restructure the completion-bus muxing" scale of work the very first
version of this entry already named, not another round of this same
narrow search. The bus-interconnect/D-cache sweep-in question from round
3 is also still completely open and was not investigated further here.

**`nextpnr-ecp5 --ignore-loops` was tried, as the obvious cheap way around
the above, and it is not a usable shortcut.** The flag exists precisely to
let timing analysis proceed past a known-false combinational loop instead of
refusing outright - but "proceed" is not "produce a meaningful number."
Every seed tried (five of six placement seeds, `BOARD=ulx3s85`, before the
sixth was killed to free the machine for other work) reports the *same*
symptom: `clk_25mhz`'s max frequency comes back as 0.40-0.45 MHz against a
25 MHz requirement - not a close miss, four orders of magnitude off - paired
with dozens of hold-time violations on the clock input buffer itself, which
is not where a real timing problem in this design would show up. Ignoring
the loop does not make the analyzer treat it as zero-delay or otherwise
benign; it appears to make the analyzer treat *some* path through it as
absurdly slow instead, which is a different kind of wrong, not a smaller
one. This does not change the "not a local patch" conclusion above - if
anything it reinforces it, since the tool's own escape hatch for this class
of loop produces garbage rather than an answer.

**Round 5: three more genuinely dead arms removed by the same argument
that already killed `headS_op1`/`headS_op2`'s - including the exact one
Round 4 named a real feature, which it was not.** Round 4's own premise
for `issL_scan_addr`'s bypass ("if `rtl/soc/cpu_wb.v`'s D-cache answers a
hit combinationally... 'arrays are read asynchronously'") turned out to
have been accurate when written and stale by the time it was acted on:
that quote is genuinely about `cpu_wb.v` (Phase 3, not "Phase 4" as Round
4's own text mislabeled it, corrected here), but PR #97 - "Phase 3: D-cache
hit pipeline stage - correct, costs 16.6%, doesn't close margin alone" -
landed two days *after* Round 4, specifically adding the `dc_pending`/
`dc_hit_latched` registers that make a hit answer one full cycle later,
never combinationally, for an unrelated reason (`CORE=inorder`'s own Fmax
margin, not this defect). Nobody revisited Round 4's own conclusion once
that premise changed underneath it - the same kind of self-correction this
entry's own "Investigated further" section already had to make once
before, for the same reason: reasoning about which wires a loop closes
through, without re-checking the reasoning against the current tree.

Direct reading of `rtl/soc/cpu_wb.v:355-397` confirms `dmem_rvalid` (`=
hit_deliver || read_ack`) cannot assert the same cycle a request is first
presented, hit or miss - the same-cycle round-trip Round 4's hypothesis
needed cannot exist as described. That reopened the question of whether
`issL_scan_addr`'s bypass is actually reachable at all, checked this time
with the exact rigor `headS_op1`/`headS_op2`'s own removal already used
(that argument is preserved as a comment above `headS_op1`'s own
definition): entry into `issL_scan_addr`'s bypass requires
`rob_r1_ready[issL_scan_idx]`, and `rob_r1_ready[idx]`/`rob_r1_val[idx]`
are *always* co-written by the same clocked block (dispatch, or the
wakeup-snoop) - so `_ready` reading 1 this cycle structurally guarantees
`_val` already holds whichever CDB produced it, at least one cycle
earlier. A same-cycle bypass read here can only ever match a value
`rob_r1_val[issL_scan_idx]` already equals, by construction - unreachable,
not merely unlikely, the identical shape of argument that already proved
`headS_op1`/`headS_op2` dead, just not previously checked against this
specific arm.

The same check, applied for the first time to two more sites this
investigation had not individually named before, found the identical
pattern: `issB_a_reg`/`issB_op2` (Class B's own operand read, gated by
`issB_idx`'s own selection requiring both
`rob_r1_ready[issB_idx]`/`rob_r2_ready[issB_idx]`) - the very pair
this file's own "Investigated further" section named as the
*other* half of a closing loop, alongside `headS_op1`'s now-removed
`cdbB` arm; and the out-of-order store address/data computation
(`sq_addr`/`sq_wdata`, gated by `issST_idx`'s identical
`rob_r1_ready`/`rob_r2_ready` requirement) - the file's own header comment
had named this as a CDB-consuming site since the `src_value` inlining
work, but no round before this one checked it against the reachability
argument specifically. All three bypass ternaries removed, falling
through directly to `rob_r1_val`/`rob_r2_val` - Round 3's own shape of
fix (delete redundant logic), not Round 4's proposed one (add a new
register): nothing here needed compensating latency, because nothing here
was ever reachable.

**Non-vacuity, checked per site, not assumed from the argument alone.**
Mutating each of the three fallback reads in turn (XORing the value with
a small nonzero constant) and re-running `make cosim CORE=ooo` - the
suite that compares every retired instruction against Spike, not just a
final verdict - confirms the suite is genuinely sensitive to each: the
`issB_a_reg` mutation broke 82 of 84 traces (2/84 pass), the
`issL_scan_addr` mutation broke 28 of 84 (56/84 pass), and the
`sq_wdata` mutation sent `rv32ua-p-amomin_w` into a genuine non-terminating
loop in the test program's own logic (a corrupted store value feeding a
real control-flow dependency, not a simulator hang) - killed rather than
waited out, since two clean positive results already existed and a hang
is, if anything, stronger evidence of sensitivity than a clean mismatch.
Reverted each in turn and reconfirmed 84/84 clean before moving on. `make
verify` and `make verify_ooo` both green afterward: formal 6/6, riscv-tests
82 passed/2 xfail, cosim 84/84 (including `rv32si-p-dirty`'s own
already-documented, `CORE=ooo`-specific, unrelated divergence, correctly
still marked expected), Linux boot reached userspace, `sim_ramboot_2hart_
hetero`'s own `rob_count` identity check unaffected.

**Does not, on its own, close the defect - the same honest framing every
prior round already used.** This round removed dead code proven dead, the
same category Round 3's `regfile_phys.v` fix was, kept and shipped
regardless of whether it closes real synthesis on its own - it has not yet
been checked against a real `nextpnr-ecp5` run, which needs its own
separate pass (a real `wb_framebuffer.v` synthesis crash, documented
immediately below this entry, blocks a full-SoC synthesis attempt today
independent of anything here, and needs its own narrow workaround before
that check can even run). What Round 4 still leaves open - whether the
bus-interconnect/D-cache subgraph Round 3 first flagged is itself part of
any remaining loop - was not investigated further this round either.
Whether removing three more redundant arms reduces or closes the loop
count is Round 6's own first question to answer with real evidence, not
this round's to assume.

**Round 6: the combinational loop is gone. `CORE=ooo` has a real,
measurable Fmax for the first time ever - and it is 8.68 MHz, not 25.**
Cheap evidence first, matching the sequencing every prior round
established: a bare `yosys -p "read_verilog ...; hierarchy -top core_ooo;
proc; check -force-detailed-loop-check"`, scoped to `core_ooo.v` and its
direct dependencies only (`regfile_phys.v`, `mmu.v`, `pmp.v`, `csr_file.v`,
`muldiv_div.v`, `btb.v`), found no loop at all - completed in 4 seconds.
Widening the same bare check to the full SoC (`soc_top.v`, every peripheral,
`wb_interconnect.v`/`cpu_wb.v` with the D-cache enabled) still found none,
once `rtl/soc/wb_framebuffer.v`'s own unrelated, already-documented yosys
crash (below) was worked around the same way its own investigation already
validated - `chparam -set FB_WIDTH 8 -set FB_HEIGHT 8 soc_top`, a
diagnostic-only substitution that never touches the framebuffer's own
logic, applied because that crash reproduces even in this bare `check`
pass, not only inside `synth_ecp5`'s own later, techmapped one as first
assumed - completed in 22 seconds. Neither result is the authoritative
answer (`check`'s own loop detector runs on the pre-technology-mapped,
pre-ABC9 netlist, a genuinely different graph than what `nextpnr-ecp5`
statically times after real synthesis), but both pointed the same
direction strongly enough to justify the real, expensive check next.

**The real check: full `synth_ecp5` synthesis, then a real `nextpnr-ecp5`
place-and-route, on `BOARD=ulx3s85`, `CORE=ooo`, with the same diagnostic
framebuffer substitution (never shipped, `fpga/synth/synth_ecp5.sh` itself
untouched - this ran as a standalone invocation built for this check, since
the script has no `FB_WIDTH`/`FB_HEIGHT` override of its own).** Real
runtime, backgrounded and watched rather than guessed at:

| Stage | Wall-clock time |
|---|---|
| `yosys synth_ecp5` (full techmap + ABC9) | 7,268.6 s (2h 1m), `abc9_exe` alone: 7,193 s |
| `nextpnr-ecp5` (place + route, single seed) | 28h 17m 19s (101,365 s user + 474 s system CPU, 99% throughout) |
| **Total** | **~30h 18m** |

Pre-place utilisation: 74,679/83,640 LUT4s (89%), 16,964/83,640 DFFs (20%).
Placement itself finished quickly (cooled to `temp = 0.000000` within the
first ~40 iterations); essentially the entire 28-hour figure is routing on
an 89%-utilised 85F - real, watched cycle by cycle rather than assumed:
router iteration count and remaining-arc count were sampled repeatedly
across the run, arcs falling from 173,000-plus at the start to 0 at
completion, non-monotonically (real negotiated-congestion oscillation, not
a stall - confirmed by watching `ps`'s own CPU-time delta stay near 100%
throughout, including through several individual multi-hundred-second
batches late in the run).

**No `ERROR: Timing analysis failed due to combinational loops` anywhere.**
Instead, for the first time in this entire investigation, a real, complete
static timing report:

```
Info: Max frequency for clock '$glbnet$clk_25mhz$TRELLIS_IO_IN': 8.68 MHz (FAIL at 25.00 MHz)
```

`ERROR`, not silence - this still fails the board's own 25 MHz constraint,
by a wide margin - but it is a *timing* failure now, the same kind every
other configuration in this project already reports and works against, not
a structural one nothing could act on. Rounds 1-5's combined effect - two
proven-dead arms removed by Round 2/3, three more by this same argument in
Round 5 - closed every combinational cycle nextpnr's static analysis could
find.

**The real critical path, traced the same way every prior round's loop
samples were - real signal names from the real report, not inferred:**
115.17 ns total (23.78 ns logic, 91.39 ns routing - routing dominates,
which is itself informative), from `core_ooo.v`'s own `rob_r1_tag[7]`
register, through `rob_a_sel`'s Class-B operand-source mux, into
`rtl/mmu.v`'s `is_user` privilege check, back through `issL_idx`/
`rob_funct3` into the out-of-order load-issue PMP check
(`PMP_ISSL.size`), into `csr_file.v`'s `wdata`, into `rtl/debug/dm.v`'s
`dbg_reg_wdata`, and finally into `regfile_phys.v`'s own `RF.regs[53]` -
by way of the same debug-write priority mux (`rf0_we`/`rf0_wdata`)
`core_ooo.v`'s own header comment already documents. This path has no
reason to exist on the clock's own critical edge: JTAG debug register
writes are a rare, host-paced, already-slow operation (the whole halted
window this mux's own safety argument leans on), not something any real
workload depends on running at full clock speed. A `--sdc` multicycle or
false-path exception scoped to exactly this path is a real, cheap,
untried candidate for Round 7 - genuinely different in kind from every
fix this investigation has tried so far (all RTL-level), and worth trying
before reaching for another RTL change, precisely because it might not
need one at all.

**Update, before Round 7 could start: the SDC-exception idea above is not
viable in nextpnr-ecp5 today - not untried, dead on arrival.** Checked
directly against nextpnr's own upstream source
(`common/kernel/sdc.cc`, `YosysHQ/nextpnr`) before spending another
multi-hour synthesis+place-and-route cycle on it, the same discipline
this investigation has held to at every prior round rather than trusting
a plausible-sounding mechanism. The result: `set_multicycle_path` (and
`set_max_delay`/`set_min_delay`/`set_clock_groups`) is not implemented at
all - the SDC command dispatcher (`sdc.cc:216-236`) recognizes exactly
`get_ports`/`get_cells`/`get_nets`/`get_pins`, `create_clock`, and
`set_false_path`; anything else hits a hard `log_error` and aborts before
place-and-route even starts. `set_false_path` itself (`sdc.cc:373-430`)
parses `-from`/`-to` (a single exact net/pin/port name each - no
`-through`, no lists, no wildcards) but is documented parse-only
scaffolding: line 426 unconditionally logs `"set_false_path from: %s, to:
%s does not do anything(yet)."` and returns without touching the timing
graph at all, regardless of how correctly it is scoped. The PR that would
have made this real - #1372, "Add timing exception support" - sat as an
unmerged draft since September 2024 and was closed as stale, unmerged, on
2026-09-15, five days before this check. No RTL-level attribute
alternative exists either: nextpnr's own `docs/constraints.md` lists
exactly three constraint mechanisms total (IO constraints, absolute
placement via a `BEL` attribute, and clock constraints via `--freq`/
`ctx.addClock`) - nothing for timing exceptions. Worth naming the failure
mode this avoided: a syntax error fails loudly and cheaply, but a
well-formed, correctly-matching `set_false_path` would have printed one
easy-to-miss warning and then let the entire build run to completion
looking exactly like a real, unconstrained result - precisely the kind of
false positive this investigation has been careful to rule out at every
round. **The real 25 MHz gap is still open, with no current candidate
beyond another RTL change** - this correction closes out one specific
wrong idea about how to attempt Round 7, it does not replace it with a
new one.

**What this does not yet establish.** Whether 8.68 MHz is representative
of the *real* 320x240 framebuffer's own build (the diagnostic 8x8
substitution never appears anywhere in the traced critical path above, so
there is no reason to expect it does, but this was not independently
re-confirmed at real scale, which itself needs `wb_framebuffer.v`'s own
crash closed or worked around again first). Whether other, different
critical paths exist close behind this one - only the single worst path
was traced. Whether an RTL-level restructuring of this same path (the
option the SDC idea was meant to avoid) can close it instead - a real,
named, open question for Round 7, not assumed answered here.

**A real, timing-closed, flashable bitstream for `CORE=ooo` - the first
one this core has ever had - by underclocking rather than waiting on
Round 7 or a deeper fix.** 8.68 MHz is a real number, but still far short
of the board's 25 MHz requirement; flashing a design at a clock faster
than it settles produces routine setup-time violations, not a working
CPU. Rather than wait, a new opt-in board target derives a genuinely
slower clock from the board's own 25 MHz oscillator, using one of its
four otherwise-unused `EHXPLLL` hard blocks - the same mechanism
`fpga/video_pll.v` already uses for the video pipeline's own clock,
followed here rather than invented fresh.

`fpga/underclock_pll.v` (generated by the project's own `ecppll` tool,
the same discipline `video_pll.v`'s own header states: `ecppll -i 25 -n
underclock_pll --clkin_name clk_25mhz --clkout0_name clk_soc --clkout0 5
-f fpga/underclock_pll.v`) derives 5 MHz - a clean 1/5 division, and real
margin, about 1.7x, below the 8.68 MHz worst case, in case a fresh
place-and-route at a different target landed somewhat worse than that
figure did. `ecppll` itself printed a real warning generating this -
"Output frequency 5MHz not in range (10MHz, 400MHz)" - worth stating
plainly: the computed configuration (VCO 600 MHz, `CLKOP_DIV`=120) is
mechanically ordinary for the part, so the warning reads as `ecppll`'s
own generic guardrail for its typical use cases (video/memory clocking,
which rarely go this low), not a stated electrical limit - but this is
not independently confirmed on real silicon, which is exactly what
flashing the resulting bitstream would tell us that a timing report
cannot.

New opt-in board target, `BOARD=ulx3s85-underclock`, mirroring
`ulx3s85-video`'s own shape exactly (same device/pins, an added PLL,
`-DUNDERCLOCK` gating it). `fpga/sdram_clk_out.v`'s own header states
plainly why it exists - so the SDRAM's own clock output "cannot drift
apart" from the SoC's - so the new PLL's output feeds *both* the SoC and
that module, never one alone. `CLK_HZ` (already a real, unconditional
parameter on both `fpga/ulx3s_top.v` and `fpga/soc_fpga.v`) is overridden
to match via a new `UNDERCLOCK_HZ` environment variable, threaded through
as a `chparam` at synthesis time rather than an RTL-side conditional -
nothing checks that this and the PLL's own real output agree, the same
"docs/practices.md section 11" duplication risk this codebase already
names for `RAM_BYTES`/`FB_WIDTH` elsewhere. A new `FB_WIDTH`/`FB_HEIGHT`
override pair was added to `fpga/synth/synth_ecp5.sh` itself alongside
this - not a fix for `wb_framebuffer.v`'s own separately-tracked yosys
crash (below), but a real, permanent way to reach past it (the same
`chparam`-shrink diagnostic substitution this round's own bare-`check`
work already validated), needed here because a full-board synthesis
attempt hits that crash regardless of clock frequency.

**First attempt, no seed retries, closed cleanly:**

```
Info: Max frequency for clock '$glbnet$soc_clk': 10.17 MHz (PASS at 5.00 MHz)
```

Over 2x the 5 MHz target - not a borderline pass. `fpga/build/
ulx3s85-underclock.bit` is real (2,020,445 bytes) and ready to flash
(`openFPGALoader -b ulx3s fpga/build/ulx3s_top.bit`) - not yet loaded onto
a board this session. The critical path this time is a different one
from Round 6's own (`csr_file.v`'s `wdata` through `dbg_step_done`
through the D-cache's `load_hit`, still routing-dominated at roughly the
same 78% share) - consistent with a router given real room to find a
genuinely good solution instead of fighting for an unreachable target,
not evidence the earlier path was wrong.

**What this does not establish.** Whether the PLL primitive itself locks
reliably on real hardware at 5 MHz - a question outside what static
timing analysis (or this session, which has no board attached) can
answer. Whether `soc_clk`'s own 10.17 MHz margin holds at the real 320x240
framebuffer scale, not just the diagnostic 8x8 substitution used here (the
substitution never appears in the traced critical path, so there is no
reason to expect it does, but it was not independently re-checked at real
scale). This does not close the real 25 MHz gap Round 7 still names, and
does not attempt to - a genuinely different, complementary path to a real
board test now, not a replacement for closing that gap for good.


**RESOLVED - Interrupt-driven UART TX (#56) failed on `CORE=ooo`; root-caused
and fixed. See "Stage 1d was built anyway," Update 9, for the full account
and why it was chased in the first place** (a resemblance to the still-open
Linux hang below, which the fix turned out not to explain). Left here,
struck rather than deleted, as the record of what this entry used to say:
`make sim_uartirq CORE=ooo`: `all bytes handed to the UART FAILED`,
`exactly one interrupt per byte sent FAILED`, `transfer finished during the
unrelated work FAILED`, `finished after never of 5000 unrelated-work
iterations`, `UART-IRQ-TEST: FAIL (3)`, against a clean `CORE=inorder` pass.
Root cause: `rtl/ooo/core_ooo.v`'s out-of-order load-issue path
(`loadL_can_start`) could start on the same cycle a `head_load_owns_port`
transaction (every peripheral/MMIO load, per `load_target_needs_head`)
completed, and its early-completion latch had no way to tell that the
`dmem_rvalid`/`dmem_rdata` it just grabbed belonged to that other
transaction rather than its own - never-issued - request. Fixed by adding
`!head_load_owns_port` to `loadL_can_start`, restoring a symmetry
`head_load_owns_port` already kept on its own side. `make sim_uartirq
CORE=ooo` now passes cleanly on both cores.

**The reason CI couldn't see it is fixed.** `sim/tb_ramboot.v` decides
PASS/FAIL and reports it with `$display` - `RAMBOOT TEST PASSED`/`RAMBOOT
TEST FAILED` - then calls plain `$finish`, which exits Icarus 0 regardless
of which string it just printed. [practices.md §6](../practices.md) states the
intended design ("every SoC simulation ends with the firmware writing a
magic word... the result is a value rather than an impression") and names
`sim_rerun` as the example that actually does it - "greps its own log and
fails the build." The Makefile recipes for `sim_uartirq`, `sim_plic`,
`sim_uart16550`, `sim_mmusdram`, `sim_ramboot`, `sim_sdramcheck`,
`sim_div64test`, `sim_probe`, `sim_uartload`, `sim_sdram`, and
`sim_sdramboot` were all one line, `cd sim && $(VVP) foo.out $(VVP_DUMP)`,
with nothing after it to grep or check - confirmed directly for
`sim_uartirq`: `verify_ooo` used to keep going through every later target
and only stop at the pre-existing `sim_linux` failure, which *was* checked.
All eleven now `tee` their output to a per-target log and grep it for the
right verdict string before continuing - `RAMBOOT TEST PASSED` for the
eight built on `tb_ramboot.v`, `UARTLOAD TEST PASSED` / `SDRAM TEST PASSED`
/ `SDRAMBOOT TEST PASSED` for the three that use their own testbenches
instead, matching `sim_rerun`'s existing pattern exactly rather than
inventing a new one. Confirmed working both directions, not just asserted:
`make sim_uartirq CORE=ooo` now exits nonzero with `sim_uartirq FAILED`
printed, and `make verify_ooo` now stops there instead of running another
25 minutes to reach `sim_linux` - a real, measured side benefit, not just
correctness. `make sim_uartirq` (`CORE=inorder`) still exits 0. `sim_rerun`,
`tests/run.sh`, `sim/trapcheck.sh`, `cosim.py`, and `sim_linux`'s own
watchdog check were already the counter-examples in the tree before this;
now every other `tb_ramboot.v`/`tb_uartload.v`/`tb_sdram.v`/`tb_sdramboot.v`-
based target looks like them too. The testbenches themselves were not
touched - the fix is entirely in what the Makefile does with output they
already produced.

## Hardware

*Physical board testing: what has and has not run on a real board.*

Only the in-order core (`rtl/cpu_core.v`) has run on silicon. `rtl/ooo/core_ooo.v` has never run on a board: its first place-and-route attempts failed on a combinational loop, then on Fmax (8.68 MHz in the diagnostic build, against the board's 25 MHz). The Known defects entry "CORE=ooo had no Fmax" records a timing-closed, underclocked (5 MHz) bitstream, `BOARD=ulx3s85-underclock`, that had not been loaded onto a board when it was written, and leaves open whether its PLL locks on real hardware. The phase's own "Done when" names a hardware run as part of the standing bar; that part is unmet for the wide core.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

This is where the phase has been proven: `make verify_ooo` runs the whole suite on `CORE=ooo` (riscv-tests, Spike co-simulation, formal proofs, every SoC, firmware and trap simulation), and `make sim_linux CORE=ooo` boots Linux to userspace. The stage accounts above carry the counts as of each stage, and the measured CoreMark cycle counts (448,346 for stage 1d). The "Done when" bar of more than one instruction per cycle on CoreMark was measured and is argued in the stage 1d accounts above, not assumed.
