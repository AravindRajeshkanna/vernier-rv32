# Practices

The working rules this project runs on. Every one of them is here because
breaking it cost real time on this repository — the examples are not
illustrations invented for a style guide, they are incidents, and each links
to the code or document that records it.

Hardware amplifies bad verification habits in a way software does not. A
failing program prints a stack trace; a failing bitstream sits there with the
heartbeat blinking. The rules below are mostly about making the machine tell
you what happened instead of leaving you to guess.

---

## 1. A test must be able to fail

The first question about any new test is not "does it pass" but "what would
make it fail, and have I seen it do that".

**The incident.** The SoC's GPIO test drove the low 8 pins and checked them on
the high 8. It passed for months. It was measuring `sim/tb_soc.v`, which fed
`gpio_out` straight back into `gpio_in` — on a real board `gpio[15:8]` is a
row of header pins with `PULLMODE=NONE` and nothing plugged into them. The
test never touched a pad. It failed the first time it met hardware.

What replaced it drives every pin with two complementary patterns (`0x5A5A`
then `0xA5A5`) and requires each to read back. A pin that is not really being
driven settles at *some* level, and no single level matches both. The
testbench now models a pad instead of a wire: undriven pins read `X`, not `0`,
so anything depending on one fails in simulation rather than on a bench.

**The rule.** Prefer a test whose passing requires the hardware to have done
something specific over one that merely observes a value it expected. If a
test cannot fail without the testbench changing, it is testing the testbench.

## 2. Prove the instrument before you trust it

A diagnostic that silently does nothing is worse than no diagnostic, because
the next person to run it and see nothing concludes there is nothing to see.

**The incidents.** `fpga/ulx3s_cmd0.v` is an SD probe that goes on a board to
answer "does the card reply to CMD0". Before it was trusted, `make sim_cmd0`
proved it against the card model: `0xFF` with no card, `0x01` when one is
inserted mid-run, `0xFF` again when removed. Otherwise a bug in the probe
would have sent someone hunting for hardware faults that were not there.

Same discipline for the trap handler. It halts and prints on any trap nobody
armed — so `make trapcheck` provokes four faults whose reports are known in
advance and scores the text that comes out, including the double-fault path,
which is the code that runs when everything else has already failed and would
otherwise never have been executed at all.

**The rule.** Every diagnostic gets its own test, and that test asserts on the
output, not just on the exit status. Run it before you believe a quiet result
from it.

## 3. Diagnostics lie too

The instrument deserves the same scepticism as the thing it measures.

**The incident.** While diagnosing the `printf` failure (§7), the probe
reported two things confidently and wrongly. It decoded newlib's `_flags` by
testing the two buffering bits and falling through to "fully buffered" — so
`0x40`, whose only set bit is `__SERR`, was labelled as a buffering mode, and
the actual finding (no `__SWR`, the FILE was never set up for writing) was
hidden behind a plausible-sounding label. Then it sampled `__cleanup` *after*
stdio had been used; `__sinit` *sets* `__cleanup` on success, so a perfectly
healthy system also reads non-NULL there. On its own, that reading would have
"confirmed" the hypothesis regardless of whether it was true.

Both were caught by keeping a simulation baseline to compare against, and the
second was caught before it ever reached hardware.

**The rule.** Decode flags one bit at a time and name them; do not collapse a
bitfield into a mode. Sample a guard variable before the thing it guards
runs, not after. And keep a known-good baseline for every diagnostic, so
"this looks wrong" can be distinguished from "this always looks like that".

## 4. Simulate the configuration that actually ships

A simulation that models a machine nobody has proves things about a machine
nobody has.

**The incident.** `make sim_soc` gave the SoC 256 KB of RAM and booted it off
the SD card model. The bitstream that runs on the board does neither: 64 KB,
because 256 KB costs 244 ECP5 block RAMs and fits no ECP5 there is, and the
program preloaded into the bitstream because the card path was unproven. Two
load-bearing differences, and nothing simulated either — so `wb_interconnect`
decoding on `addr[31:24]` alone, which makes an access past the end of RAM
alias back to the start instead of faulting, had its wrap point four times
higher in simulation than on hardware.

`sim/tb_ramboot.v` now runs that path at that size and is in `make verify`.

**The rule.** For every configuration you ship, there is a simulation of *that*
configuration. Parameters that differ between simulation and hardware are a
list you maintain deliberately, not an accident of defaults.

## 5. Run it twice

Reset is not a fresh start, and one run proves only that the first run works.

**The incident.** Block RAM is initialised when the FPGA is *configured*, not
when the CPU is reset. `crt0_ram.S` zeroed `.bss` but never restored `.data`,
so pressing reset re-ran the program over memory the previous run had already
written. What that broke was newlib's stdio and nothing else: `__sinit`
returns early when its `__cleanup` guard is non-NULL and sets that guard
itself on success, so from run 2 onward `stdout` was never initialised and
every `printf` returned −1 and printed nothing.

Every simulation ran the program exactly once, so every simulation passed.
And because the usual bring-up gesture is *flash, open a terminal, tap reset
to catch the banner*, essentially every run anyone watched on hardware was
run two. `make sim_rerun` now runs the program, pulses reset without touching
RAM, and runs it again.

**The rule.** Anything with an initial value must be rebuilt at startup, not
assumed to survive. Test the second run, not just the first — and pick a test
program that would actually notice. `sim_rerun` uses the newlib probe rather
than the acceptance test precisely because the acceptance test keeps its
state in `.bss`, which `_start` has always zeroed, so it passes twice either
way.

## 6. Make the verdict machine-checkable

If a human has to read the output to know whether it passed, it will
eventually pass while broken.

**The practice.** Every SoC simulation ends with the firmware writing a magic
word (`"PASS"` / `"FAIL"`) to a fixed address the testbench reads back, so the
result is a value rather than an impression. The console output is still
printed — it is decoded off the CPU's actual serial TX pin by a receiver state
machine in the testbench, not a canned string — but it is evidence, not the
verdict. `tests/run.sh` and `sim/trapcheck.sh` return exit codes; `make
sim_rerun` greps its own log and fails the build.

Expected failures are held in `tests/expected-failures.txt` with reasons, and
`run.sh` fails the run if one of them starts *passing*, so the list cannot
quietly go stale.

## 7. Route around a defect and you have not fixed it

Workarounds are legitimate. Calling one a fix is not.

**The incident.** When `printf` appeared to hang on hardware, the acceptance
test was rewritten to print through a libc-free console. That was the right
call for the test — a test of the SoC should not be able to fail inside the C
library — and it was recorded as explicitly *not* an answer to the question.
That honesty is why the question was still open to be answered later, and the
answer turned out to be a `.data` initialisation bug in this project's own
startup code, not newlib at all (§5).

The same standard applies to the intermittent `ISA-TIMEOUT` under `make
verify`: it now self-reports instead of hanging silently, and the docs say
plainly that self-reporting was not a fix and the cause is still unknown.

**The rule.** When you work around something, write down what you did not
find out. A known unknown gets revisited; a silently patched one does not.

## 8. Read the failure, do not pattern-match it

**The incident.** "Reached `main` and stopped dead on its first `printf`" was
the accepted description of the bug in §5 for months. `printf` never hung. It
returned, reported failure, and its output was discarded — but `printf` was
the only output channel at the time, so "produced nothing" and "stopped" were
the same observation. The moment the program had an independent way to speak,
the symptom dissolved.

**The rule.** Before theorising about a cause, check that the symptom is
described correctly. Give the system a second, independent channel for
reporting — one that does not depend on the subsystem under suspicion.

## 9. Narrow by one dependency at a time

**The practice.** `software/soc/newlibprobe.c` is a ladder: RAM under the heap
→ `_sbrk` → the memory `_sbrk` returned → `malloc` → `snprintf` (formatter,
no heap or stdio) → `puts` (stdio setup and `_write`) → `printf`. Consecutive
rungs differ by a single dependency, and each prints one character *before* it
runs, so a run that stops tells you where even if the line never finished.

That structure is what turned "newlib is broken" into "`__sinit` was locked
out by a stale guard word" in three board runs, each of which eliminated a
specific layer rather than gathering general information.

## 10. Prefer arithmetic to inspection

**The incident.** The stale `.data` bug was confirmed not by looking at memory
and judging it wrong, but by a rotate-xor checksum over the whole 4,834-word
image. Expected ⊕ observed was `0x01448400`, and rotating the suspect value
`0x80002890` by its position in the image gives exactly `0x01448400` — proving
that word was the *only* one of 4,834 that differed. `nm` then showed the
value was `cleanup_stdio`, a function address only `__sinit` ever stores.

**The rule.** When you can turn "this looks wrong" into a number that can only
have one explanation, do it. It is faster than more inspection and it does not
depend on your judgement being sharp at the end of a long session.

## 11. Every duplicated constant is a defect waiting

Some constants cannot be shared across a language boundary: software cannot
read a synthesis parameter, and a linker script cannot include a C header.

**The practice.** Where duplication is unavoidable, it is named, commented on
both sides, and the direction of safe error is stated. `CPU_HZ` in
`software/soc/soc.h` must agree with `CLK_HZ` in `fpga/soc_fpga.v`, and the
comment says: if you get it wrong, get it wrong *high*, because
over-estimating makes SCK slower than intended (harmless) while
under-estimating pushes the SD init clock above the 400 kHz ceiling, which
real cards reject. `RAM_SIZE` vs `RAM_BYTES`, `soc.h` vs `soc_top.v`'s
`s_base` table vs `dts/soc.dts` vs the linker scripts are the same hazard.
`docs/soc.md` names all five places a new peripheral must be registered and
says outright that none of them check each other.

Where a check *is* possible, it exists: `fpga/synth/synth_ecp5.sh` refuses to
build if the preload image is older than the ELF it came from, and
`link_ram.ld` carries `ASSERT`s that name which neighbour the program has
grown into rather than leaving you with "region overflowed by 112 bytes".

## 12. A stale artifact is worse than a missing one

Missing stops the build. Stale sails through and produces a result about
something other than what you think you are testing.

**The incidents.** A bitstream was once built with a stale `ramimage.hex`,
baking in a program from before a fix and reproducing a bug that was already
solved — a full synthesize-and-flash cycle to notice. `make trapcheck` writes
the same image filename for each of its four cases, so it deletes the image
when it finishes rather than leaving whichever case ran last to be picked up
by a bitstream build. And every `$readmemh` image rule in the `Makefile` lists
`Makefile` itself as a prerequisite, because the word/byte layout of each
image is decided by the `bin2hex` flags there — without it, changing a
memory's organisation leaves an image that loads silently and wrong, which
cost real debugging time when `wb_ram.v` went from byte- to word-organised.

**The rule.** Build products carry their provenance. `synth_ecp5.sh` stamps
each bitstream with a copy of the image inside it, so "which program is in
this `.bit`?" is answerable from the filesystem rather than from memory.

## 13. Fail fast, and say what to do

**The incident.** A synthesis run got through 56 seconds of yosys before dying
on `nextpnr-ecp5: command not found`, because Homebrew ships yosys but has no
nextpnr formula. The script validated the boot ROM image and the preload image
before starting — but not the tools that consume them.

It now checks all three up front and prints the `export PATH=...` line.

**The rule.** Check preconditions in cost order, cheapest first. An error
message should name the fix, not just the problem.

## 14. Anything nothing builds will rot

**The incident.** `fpga/top_fpga.v` sat in the tree for months with unconnected
page-table-walker ports, because no target built it. `sim/tb_ulx3s.v` now
exists specifically so the board wrapper — pin direction, polarity, tie-offs —
cannot rot the same way, and it is part of `make verify`.

**The rule.** If a file is not built by something in `make verify`, either
wire it in or delete it. There is no third state that stays honest.

## 15. Layers, each answering what the one before cannot

Four verification layers, described in full in `tests/README.md`:

| Layer | The question only it answers |
|---|---|
| Directed tests | Does the feature I just wrote work? |
| Architectural tests (riscv-tests) | Does this implement *RISC-V*, as judged by someone else's suite? |
| Co-simulation vs Spike | Did it execute the *same instructions*, or reach the right answer a wrong way? |
| Formal (yosys + z3) | Does this hold for *every* input, not just the ones a test tried? |

The upstream suites are deliberately not vendored — the value of running them
is that this project did not write them — and are pinned to a commit so a
regression can never be explained away by "upstream changed".

Two of these exist specifically to catch what the others cannot.
Co-simulation found nothing the tests found; it asks a strictly harder
question. Formal covers roughly 2^30 PLIC priority/enable/pending/threshold
combinations that no test suite is going to enumerate.
`formal/fv_selftest.v` is a property that **must** fail, proving the flow can
still go red.

## 16. Write down what is not true yet

**The practice.** `fpga/README.md` opens with a table separating "builds",
"closes timing", "has been loaded onto a board" and "the SD card works",
because those are different claims and conflating them is how a project starts
lying about itself. `software/opensbi/README.md` says OpenSBI *builds* but
does not *boot*, and lists the four things standing in the way.
`tests/README.md` lists the three architectural tests that fail and why.

**The rule.** Status is per-claim, not per-project. "Works" is not a status.
When something has only been done in simulation, say so; when it has been done
on hardware, record the run verbatim, with the values that make it a report
about *that* build.

## 17. Two tools reading the same file can build different machines

**The incident.** `rtl/ooo/regfile_wide.v` computed each of its four read
ports by calling a function that read the write ports and the register array
out of the module around it — `assign rdata1_a = rd_port(rs1_a);`. Yosys
elaborates that into exactly the combinational logic it looks like, so all
four formal properties passed, including the write-priority one the module
exists for. Icarus builds the sensitivity list of a continuous assignment from
the *expression*, and a function's internal reads are not in it: in simulation
the register file's outputs moved only when a read address changed. A write
landing under a steady address was invisible.

The proof was not wrong. It was about a netlist the simulator never built.

The same mistake was then made a second time, in the forwarding mux of
`rtl/ooo/core_ooo.v`, and behaved differently again — that one updated
whenever a new instruction entered EX, which is most of the time, so it passed
the zero-latency-memory testbench with the BTB mispredict count unchanged and
failed only when the EX stage held its contents across a bus stall. It
surfaced on the SoC as the boot ROM reading a wrong magic number, and in
co-simulation as a `csrw mtvec` that the very next trap could not see.

**The rule.** A formal proof is evidence about the netlist your synthesis tool
builds. It is not evidence that your simulator builds the same one, and it is
not a substitute for executing the module. Anything proved but never simulated
is one tool's opinion.

The concrete habit that follows: in synthesisable RTL, do not call a function
from a continuous assignment unless every signal it reads is one of its
arguments. Write the logic out per port instead. `rtl/regfile.v` — the 2R/1W
file that has run on silicon — was always written that way, and the wide
version's first mistake was departing from it.

This is also the clearest case yet for §15's layering. No test caught this;
co-simulation did, because it is the only layer that asks whether the machine
executed the same instructions rather than whether it reached the right
answer.

## 18. Removing a bottleneck is how you find out it was not one

**The incident.** Stage 1c's stall counters said the data bus cost 12.6% of
CoreMark's runtime and instruction fetch cost 10.7%. The data bus was the
bigger number, so it got the work: a store buffer, so a store waiting on
Wishbone releases the pipeline instead of freezing it.

It did exactly what it was built to do. 18,979 stores took the buffered path
and 30,738 cycles of data-bus stall disappeared.

The program got 82 cycles faster.

The two stalls were concurrent, not additive. A cycle that was both bus-stalled
and fetch-starved had been charged to the bus, because the counters charge each
cycle to the innermost blocking cause. Removing the bus stall did not free the
cycle; it just relabelled it. The machine was fetch-bound the whole time, and
no amount of back-end work was going to show up as throughput.

**The rule.** A per-cause breakdown tells you where the cycles are *attributed*,
not where they are *available*. Overlapping causes look additive in a table and
are not. The only number that settles it is the total, measured before and
after, on the same workload.

The corollary is what to do with it: this is a reason to build the cheap version
of a change first. The store buffer is a few registers and a mux, and it bought
a fact that would otherwise have cost a reorder buffer, a load buffer and a
scoreboard to learn — the rest of stage 1c, which the same experiment now
predicts would also return nothing until the front end is fixed. An experiment
that changes the plan is worth more than a feature that confirms it.

## 19. Work that measures as worthless may only be stranded

**The incident.** Stage 1b built dual issue. On CoreMark it formed 47 pairs and
moved the total by 0.04%, and the instrumentation was clear about why: only 293
cycles in the whole run ever offered a second instruction to consider. Stage 1c
built a store buffer. It removed 30,738 cycles of data-bus stall and returned
82. Two features, both correct, both worth approximately nothing.

Then the instruction cache landed, and without a line of either changing:

| | Before | After |
|---|---|---|
| Dual-issue pairs | 47 | 19,872 |
| Cycles offering a second instruction | 293 | 182,627 |
| Value of stages 1b and 1c together | 0.05% | 6.9% |

The dual-issue logic was never the problem. The fetch buffer feeding it could
not accumulate while fetch was the bottleneck, so the issue rule was asked to
find a pair 293 times and found 47. With hits served in the cycle they are
asked for, fetch runs ahead of decode and it is asked 182,627 times.

**The rule.** A feature measured against a machine that cannot exercise it has
not been measured. "It gains nothing" and "nothing reaches it" produce the same
number and call for opposite responses — the first says remove it, the second
says fix what is upstream and measure again.

The instrumentation is what tells them apart, and it has to count the
*opportunities*, not just the successes. `dual_issue_count` alone would have
said the feature was useless. `pair_window_count` beside it said the feature was
starved, which is a different sentence with a different next step. When adding a
counter for how often something fires, add one for how often it could have.

This is not licence to keep everything. §18's rule still holds and the order
still matters: the cheap experiment that finds the real constraint comes first,
and the reorder buffer stage 1c did *not* build is still not built, because the
same reasoning now points at the load-use stall it exposed instead.

## 20. Do not reason from a measurement you have already called invalid

**The incident.** Stage 1c's load-completion buffer had the best ceiling in the
phase: 19,188 recoverable cycles, 4.0% of runtime. It was built. The build
measured 2.5% *slower* — and it also failed CoreMark's CRC.

Both facts were recorded. The cycle count was labelled, correctly, as coming
from an incorrect machine and therefore not a clean measurement. Then it was
reasoned from anyway, via a proxy: dual-issue pairs had fallen from 19,872 to
18,386, so the new feature must be stealing a shared resource from an existing
one, so the slowdown must be structural, so the feature was rejected and the
stage closed without it.

Every step of that was plausible and the conclusion was wrong. The bug was a
missed hazard check — the deferral released a stall that let a dual-issue pair
be latched, and only the pair's older half was checked against the outstanding
load. Fixed, the feature is a 0.34% *gain*. The pair count really does fall,
so the contention was real; it simply does not dominate, which the proxy could
never have shown either way.

**The rule.** A measurement you have disqualified is not evidence, and a
correlated signal is not a substitute for it. If a result is unusable because
the build is wrong, the next step is to fix the build, not to find a different
number that points the way the broken one did. The cost here was one wrong
conclusion shipped in a merged PR and a roadmap phase closed on it.

The corollary is about proxies specifically. `dual_issue_count` falling was a
real observation and it did identify a real mechanism. What it could not do was
weigh that mechanism against the one going the other way, because nothing was
counting the other one. A proxy tells you a force exists; only the total tells
you which force won.

### The blind spot underneath it

Worth recording separately, because it is what made the bug survive: the
missing hazard check needs a load followed by a dual-issue pair whose *younger*
half depends on it. **riscv-tests co-simulates 82/82 against Spike with the bug
present.** CoreMark's list and state passes hit it within a few thousand
instructions; its matrix pass, with fewer pointer chases, still produced a
correct CRC.

Co-simulation is the strongest layer here (§15) and it is still only as good as
the instruction mix it is given. A suite cannot create a hazard its programs do
not contain, and 82 hand-written architectural tests contain far less
pointer-chasing than one real benchmark. That is an argument for keeping a real
workload in the loop as a correctness check and not only as a stopwatch.

## 21. A stall counter is a bill, not an opportunity

Every stall counter in `rtl/ooo/core_ooo.v` says the same kind of thing: the
pipeline waited here, for this many cycles, for this reason. That is a
measurement of **cost**, and it is easy to read it as a measurement of
**opportunity**, because the two are printed in the same units and one of them
is an upper bound on the other. They are not the same number and the gap
between them can be a factor of twenty.

**The incident.** Stage 1d — renaming, a reorder buffer, reservation stations —
was scheduled on 14,231 cycles: the times a load sat on the bus and the
instruction behind it could not proceed. That is a real cost, correctly
counted, and reservation stations are the textbook answer to it. Two things
then happened to it.

A data cache, sixty lines in the bus adapter, took those 14,231 cycles to
**1,138** by making the load not sit on the bus in the first place. The
opportunity was never really "issue out of order"; it was "the load is slow",
and something much cheaper reached it.

What was left standing was the plain load-use bubble — 27,226 cycles, and now
the largest stall in the machine. So the same reasoning restarted one level up,
and this time the question was asked properly first: *when the pipeline stalls
on a load-use hazard, is there anything else it could have run?* A counter that
walks the fetch buffer on each such stall and checks it for an independent
instruction says: an ALU op in 4.8% of them, a load/store/branch in 54%, and
**nothing at all in 41%**.

Out-of-order issue does not recover 27,226 cycles. It recovers 1,303 of them
for the version that was designed, because in the other 25,923 there is either
nothing to run or nothing that can be run without a load-store queue. A 6.3%
stall was a 0.56% opportunity.

The obvious objection — that the window was only four instructions deep and a
real machine would look further — was measured rather than argued. At sixteen
entries the count goes from 1,303 to 1,743. Quadrupling the window is worth
0.1%.

**The rule.** Before building the mechanism that fills a stall, count the
cycles in which the filler exists. A stall counter needs a companion counter —
`defer_blk_dep`, `loaduse_oo_alu`, `pair_blk_class` — that asks what the
proposed fix would actually have found there. Both of the ones written for this
core answered "much less than you think", and both cost about thirty lines
against a redesign.

The corollary is scheduling. This project has re-derived the order of its own
work after every change for a reason: **removing a bottleneck does not only
reveal what was stranded behind it ([§18](#18-removing-a-bottleneck-is-how-you-find-out-it-was-not-one),
[§19](#19-work-that-measures-as-worthless-may-only-be-stranded)) — it can
delete the case for what was queued in front of it.** A ceiling computed
against the old machine is not evidence about the new one, and a plan that
survives without being re-measured is a plan nobody is checking.

---

## 22. When you write both sides, the model must encode the spec

`rtl/soc/wb_sdram.v` is checked against `sim/sdram_model.v`. Both were written
here, in the same afternoon, by the same author. That is a specific and
dangerous shape: **the natural failure mode is a model that agrees with the
controller, and a green test that means nothing.**

It is the same trap as [§1](#1-a-test-that-cannot-fail-is-testing-the-testbench)
and it is worse, because a model looks like an independent authority. A test
that cannot fail at least looks suspicious when you read it. A model that
happens to implement exactly what the controller does looks like a second
opinion.

**What kept it honest here** was writing the model as the *datasheet's* rules
rather than as the controller's behaviour:

- **Timing in nanoseconds, not cycles.** The controller derives cycle counts
  from `CLK_HZ`; the model checks tRCD, tRP, tRC, tRFC and the refresh
  interval against `$realtime`. Neither can quietly redefine the other, and
  running the controller at a different clock is a real test rather than a
  rescaling of both sides of one assumption.
- **The model reads the mode register.** CAS latency and burst length come
  from what the controller *programmed*, not from what the model would prefer.
  A controller that sets CL=3 and reads at CL=2 gets shifted data here,
  exactly as it would on silicon.
- **The model refuses rather than tolerates.** A read before tRCD, a refresh
  with a bank open, a burst that would cross a row, A[10] set on a column
  address: each stops the run with the rule named. None of those corrupt data
  in simulation. All of them corrupt data on a board, at temperature, weeks
  later — which is the entire reason to have a model instead of just a memory.

That last point is what a memory model is *for*. Storage that returns what was
written is the easy half and catches almost nothing; the value is in the half
that says no.

**And it was checked.** Four deliberate breaks in the controller, each red,
each naming itself:

| Break | What it printed |
|---|---|
| Power-up wait cut from 100 µs to 10 µs | `command issued before the 100 us power-up interval` |
| Refresh never becomes due | `no AUTO REFRESH within 2x tREFI - rows are losing data` |
| Read captured one cycle early | `[00000000] = beefzzzz, expected deadbeef` |
| High beat masked by the low byte lanes | `[00000200] = 11xx3399, expected 11223399` |

### And the model still did not find everything

The one real bug in the controller was found by reading it, not by running it.
The refresh interval timer and the state machine both wrote `refresh_due`, and
because the clear lived in the state machine it won — so an interval expiring
on the exact cycle a refresh was being issued dropped the newly-owed refresh.
One cycle in 195, and the model's tREFI check would only have caught a
systematic version of it, never the occasional one.

That is not a gap in the model, it is the shape of what a model can see. It
watches the wire. It has no opinion about whether the controller *meant* to
refresh and lost track — only about whether a refresh arrived in time, which
on any given run it did.

**The rule.** When the model and the thing it checks come from the same hand,
the model has to be written from the specification and in the specification's
own units, and then it has to be falsified — because "my controller passes my
model" is a statement about consistency, not about correctness, until
something makes it go red. And a model that says no to everything on the wire
still says nothing about the state behind it.

---

## 23. When the bench and your reasoning disagree, the bench is right

[§22](#22-when-you-write-both-sides-the-model-must-encode-the-spec) says that a
model written by the same hand as the thing it checks has to be written from
the specification and then falsified. This is what happened the first time that
model met a board, and it is a different failure with the same root.

**The incident.** `BOARD=ulx3s85-sdramcheck` came back with one wrong word in a
thousand. Chasing it, the read path looked off by one: CAS latency ought to
mean the part *launches* data that many edges after the command, and
`sim/sdram_model.v` was driving it a cycle earlier than that. The fix looked
obvious, and it was made.

It was wrong. With the model "corrected", the configuration the board had
actually run failed *catastrophically* in simulation — every read returning the
wrong beat. The board had not failed catastrophically. It had failed 0.1% of
the time, which means the timing was very nearly right, which means the model
had been very nearly right too. The change was reverted.

What the reasoning had missed is that the real controller and the real part
were meeting somewhere the datasheet's idealised diagram does not draw: the
capture edge sat 5.4 ns — one `tAC` — before the part swapped one burst beat
for the next. Correct almost always, wrong when a DQ line ran slow and the two
beats disagreed on that bit. The bench's failure *rate* carried that
information and the failure *itself* did not.

**The rule.** A measurement from hardware outranks a derivation, including a
derivation from the part's own datasheet, because the derivation is about an
idealised device and the measurement is about the one on the desk. When they
disagree, the thing to look for is what the derivation left out — not a way to
make the hardware's answer fit.

The corollary is about failure rates specifically. *That* it failed narrows the
cause a little; **how often it failed narrowed it enormously.** 100% would have
meant a wrong pin or an off-by-one. 0.1% cannot be either of those, and could
only be a margin. Any test that stops at the first mismatch throws that away,
which the one here did — so it now counts every failure, records which bits
were ever wrong, and reports how many of them were bits that differ between the
two halves of a word, because that last number is what confirms or refutes this
diagnosis on the next run rather than in another argument.

---

## 24. An acknowledgement that bounds an assumption has not removed it

The boot ROM's UART loader sends an image in pieces, and the receiver
acknowledges each one. The first version used 256-byte pieces, and the comment
above it said - in as many words - that the acknowledgement meant the loader no
longer depended on the receiver keeping up with the line.

**It did not.** It bounded that dependence to one piece and left it otherwise
exactly as it was. Inside a piece the host still transmits continuously, and
`rtl/uart.v`'s receiver is one byte deep: `rx_data_reg` and a valid bit, no
FIFO. A byte arriving before the previous one is read is simply gone.

The arithmetic that the comment should have contained:

| | cycles per byte |
|---|---|
| The ROM: poll, store to SDRAM, fold into a CRC | ~70 |
| The line at 115200 on a 25 MHz board | 2,170 |
| The line in simulation, at four clocks per bit | **40** |

So it worked on hardware with 31× of margin and lost bytes inside the first
piece in simulation — which is the wrong way round, because the simulation is
what is supposed to catch this before a board does.

Acknowledging every *byte* removes the assumption rather than bounding it: the
host cannot send byte N+1 until byte N has been read out of the register. It
costs a round trip per byte, which for a 500 KB image at 115200 is 87 seconds
instead of 43 — irrelevant for something run once per test cycle.

**The rule.** When a design rests on "A is faster than B", write down both
numbers. A handshake that fires every N units divides the exposure by N; only
a handshake every unit removes it. And the ratio that matters is not the one
on the bench - it is the worst one the design is ever run at, which for
anything with a simulation is usually the simulation.

The corollary is that this was the *third* protocol bug in the same loader, and
all three were the same shape: two things sharing a channel with an
unstated assumption about who speaks when. Console text collided with
acknowledgements because both used the wire; a probe still in flight became
the header's first byte because the host could not know when the ROM answered;
and the transfer outran the receiver. None of them are visible in a diagram of
the protocol, and all three were found by making a simulation actually run it.

---

## 25. A correction fitted to one measurement is a guess with a number on it

The SoC now runs under Verilator as well as Icarus, and the check that makes
the fast one trustworthy is that both must produce the **same cycle count** on
the same program — a far sharper instrument than both saying `PASS`, which two
quite different machines could do.

On the in-order core the two came out one cycle apart: 2,108,456 against
2,108,457. That is a real difference and it needed an explanation, so I wrote
one. Icarus watches the verdict word from a process that resumes in the active
region, before the non-blocking write has landed, while a cycle-based harness
sees it immediately; the harness should therefore read it one cycle stale. I
subtracted one, the counts matched exactly, and I wrote a paragraph of comment
explaining the scheduling semantics that made it so.

Then the same check ran against the wide core:

| | Icarus | Verilator, raw | offset |
|---|---|---|---|
| in-order | 2,108,456 | 2,108,457 | +1 |
| wide | 1,688,890 | 1,688,890 | **0** |

The offset is not a constant. The mechanism I had described so confidently
predicted +1 in both cases, and the correction I built on it took a clean run
on the wide core and reported it as a failure — a *false* one, in the check
whose entire job is to be believed.

The tell was there before the second measurement: **the correction was derived
from the only data point it was ever validated against.** One sample, one
free parameter, an exact fit — and an exact fit to one point is not evidence,
it is arithmetic. Section 23 says that when the bench and your reasoning
disagree the bench wins. This is the harder case, where the bench *agreed*,
because there was only enough of it to agree with.

**The rule.** If you cannot derive a discrepancy, do not model it — bound it,
and write down why the bound cannot hide the thing you are actually looking
for. `sim/verilator_compare.py` now allows the cycle counts to differ by one
and requires everything else to match exactly, with the justification stated:
a memory model that is early or late changes the stall on every one of ~10⁵
SDRAM accesses, so it moves the total by thousands of cycles — the one case
actually tried, loading the read pipeline at `cl` instead of `cl-1`, did not
shift the count at all, it hung the program. Meanwhile the refresh count must
match exactly, and at one refresh per ~196 cycles that pins the two runs
together far tighter than the cycle counter's one-cycle slack.

A tolerance you can justify beats an offset you fitted. It is also honest
about what you know, which is what the next person needs.

---

## 26. A suite that passes is not a suite that ran the code

This core has had an Sv32 MMU for a long time. It has two independent walkers,
an 8-entry TLB, superpage support, and a permission model with SUM and MXR.
Against it stand 79 riscv-tests passing, 82 of 82 Spike traces matching
instruction for instruction, and five formal proofs.

The first time anything ever turned instruction-fetch translation on, it
failed in the third instruction.

**Why the suite never noticed.** riscv-tests' supervisor set is `rv32si-p-*`,
and the `-p` is the whole story: it is the *physical* variant. Those tests run
in S-mode and exercise S-mode CSRs, traps and delegation — and never write a
non-zero `satp`. The suite that looks like the MMU's coverage is testing the
privilege model next to it. The `-v` variants, which do use virtual memory,
are not in the list this project fetches.

So `satp` had been enabled, in this SoC, exactly never. Two bugs were sitting
in the path, both reachable since the day the MMU landed:

| | |
|---|---|
| Fetch address is `X` during a walk | `mmu.v` derives `pa` from a PTE register that has not been read yet. `cpu_wb.v` indexes its I-cache with it, `fetch_hit` goes `X`, `iwb_cyc` goes `X`, and `wb_ram.v`'s `ack_r <= a_en && !ack_r` latches it **permanently** — `!x` is `x`. One unresolved fetch wedges main memory for the rest of the run. |
| Store data one cycle stale on a TLB hit | `store_data_latched` is a register, so it holds the operand as of the *end* of the cycle it was captured in. Correct when a walk follows and holds the instruction in EX; wrong on a hit, where the instruction leaves EX the same cycle and the register still holds the **previous instruction's** operand. |

The second one is the more embarrassing, because the comment above it already
described the hazard correctly and at length. What it got wrong was one term
in the select — `need_translate` where it needed `need_translate && mmu_busy`.
The prose was right and the code did not match it, and nothing was ever run
that could tell the difference.

**The rule.** Coverage is what a suite *executes*, not what it is named after.
When you adopt somebody else's tests, find out which configurations they
actually run before you count them as covering a feature — and when a feature
has no test that turns it *on*, say so in the place a reader would look for
reassurance, rather than letting a green suite imply it.

**The same rule applies to your own gate.** `make verify` builds `CORE=inorder`
only; `make verify_ooo` is a separate target and CI matrixes over both. A
change that added debug probes reaching into `cpu_core`'s internals passed a
green `verify` locally and failed CI's wide-core leg, because the probes named
a module the other core does not have. Nothing was subtly wrong — it did not
compile. It simply had never been compiled.

So: **anything touching a core, or anything reaching into one, needs
`verify_ooo` before it is pushed.** A green `verify` is evidence about one of
the two machines this repository builds, and the commit message should not
imply otherwise.

The corollary is about where these were found. Neither bug is subtle once the
path runs: one hangs the machine outright, the other writes the wrong word.
They survived because writing the twenty-line program that enables `satp` was
never anyone's task, and every layer above it reported success. The cheapest
test in this repository is still the one nobody has written yet.

---

## 27. When the firmware owns the console, instrument the machine

Bringing up OpenSBI produced the least informative failure this project has
had: eight million cycles, no output, no trap, no clue. Every technique that
had worked before was unavailable, because they all end in *printing
something*, and the thing that had failed was the code that brings up the
console. OpenSBI initialises its console late and deliberately — a firmware
that could print before it knows what its console is would have to guess.

The way out was to stop asking the firmware and start asking the hardware. The
Verilator harness gained four things, none of them clever:

| | what it answers |
|---|---|
| trap count + `mcause`/`mepc`/`mtval` | did it fault, and on what |
| PC range over the last N cycles | if it is looping, which loop |
| a ring of non-sequential PC changes | how it *got* to that loop |
| `+watchpc=ADDR` register dump | what it was carrying when it gave up |

Every address goes into `addr2line` against the firmware's ELF and comes back
a function name and a source line. Three bugs fell out in three iterations —
a missing CSR, a load address violating an alignment rule nobody had written
down, and a build script quietly building the wrong tree.

Two details that were not obvious and cost a round each:

- **Sample trap CSRs one cycle after the trap.** `trap` is a combinational
  pulse; `mcause`/`mepc`/`mtval` are written by the same edge. Reading them on
  the pulse returns the *previous* trap's values, which for the first trap is
  three zeros — and "cause 0, address 0" is a plausible-looking wrong answer
  rather than an obviously missing one.
- **Collapse repeated entries in a branch trace.** A two-instruction `wfi`
  spin overwrites a sixteen-entry ring in a microsecond, so the trace shows
  only the hang, which is the one thing already known.
- **Probe a *retired* signal, never a speculative one.** The first version of
  all of this watched `cpu_core.pc` — the fetch PC. It is speculative: the BTB
  predicts, the pipeline fetches, a mispredict squashes it. So the probe
  reported addresses the machine never executed, and dumped registers from a
  context that never ran. It produced a completely coherent, completely wrong
  diagnosis — "the scratch allocator is failing" — supported by a register
  dump, and the only reason it was caught is that the registers *disagreed
  with the code*: arriving at that branch would have left `a0` holding a lock
  address, and it held 64. Watching `id_ex_pc` qualified by `instret_retire`
  instead, the address in question turns out never to be reached at all.

  A probe on a speculative signal does not fail loudly. It invents a story.

**The rule.** The console is a peripheral, not a debugger. When the software
under test owns it, or has not reached it, the simulator is the instrument —
and a few registers exposed through a `.vlt` file will out-argue any amount of
reasoning about what the firmware "must" be doing. Build that before the third
round of guessing, not after.

The corollary is about speed. This only works because an iteration is under
two seconds: at 4.4 M cycles/s a full attempt is 1.35 s, so adding a probe and
re-running costs less than thinking about it. The same loop under Icarus would
be ten minutes an iteration, and nobody runs an experiment they have to wait
ten minutes for — they guess instead. Section 26's lesson was that untested
paths hide bugs; this one is that untestable *speeds* hide them just as well.

---

## 28. A build system that accepts a request has not granted it

Two of the five things that stood between "a kernel exists" and "a kernel
boots" were the build believing it had done what it was asked, and saying
nothing.

`software/linux/vernier_rv32.config` asks for `# CONFIG_RISCV_ISA_C is not
set`, because this core has no compressed instructions. Kconfig accepts that
and then turns it back on, because `CONFIG_EFI` is `default y` on riscv and
`select RISCV_ISA_C`. No warning, no error — a kernel full of instructions the
hardware cannot decode, which would have surfaced as an illegal-instruction
trap in S-mode before any console existed.

Worse, configuration would not have been sufficient even if it had been
honoured. `arch/riscv/Makefile` appends `_zacas` and `_zabha` to `-march`
whenever the *toolchain* supports them, keyed on `TOOLCHAIN_HAS_*` symbols
that have no prompt and cannot be turned off. There is no Kconfig option that
stops the compiler emitting an `amocas`.

So the request is checked and so is the artifact, and they are different
checks:

- `kconfig-merge.py check` re-reads `.config` *after* `olddefconfig` and fails
  when an option the fragment asked for did not survive. It caught EFI on its
  first run, along with `CONFIG_HZ_100` losing to a `choice` default that had
  not been cleared, and `CONFIG_BLOCK` needing `CONFIG_EXPERT` before it could
  be answered at all. Five of the thirty options in the fragment's first
  version were dropped without a word, and a sixth request —
  `CONFIG_RISCV_ALTERNATIVE` — turned out to be one kconfig will never
  grant, because `config RISCV` selects it unconditionally. The fragment
  says so now instead of asking again.
- `isacheck.py` disassembles the finished `vmlinux` — 641,785 instructions —
  and checks every mnemonic against what `rtl/` implements. That is the one
  that cannot be fooled by a Makefile, because it reads what was actually
  emitted.

The general form: when a tool lets you *ask* for a property, the ask is not
the property. If the property matters, read it back off the output. This is
section 11's "nothing checks that the four agree" pointed at a build system
instead of at a memory map.

There is a second-order benefit worth naming. `isacheck.py` finds four
Svinval instructions in every build, unreachable because `dts/soc.dts` does
not advertise the extension and `has_svinval()` is therefore false. They are
listed by name and counted rather than waved through, so the day that count
changes, somebody sees it.

---

## 29. Two microarchitectures failing identically is a measurement

Halfway through a bug hunt with no obvious cause, the cheapest question left
was: does the *other* core do this too?

It did — at byte-identical faulting addresses. That is not a small thing to
learn. The in-order five-stage core and the wide out-of-order one share no
pipeline logic at all; they share `mmu.v`, `csr_file.v`, `cpu_wb.v`,
`wb_ptw.v`, the interconnect and the software. Identical wrong values from two
unrelated pipelines rules out a timing race, an issue-order hazard, a
forwarding bug and a speculation bug in one run, and narrows the search to
shared modules or to the software itself.

It also, incidentally, found a different bug: the wide core could not run
OpenSBI at all, because `mstatush` had been added to one core and not the
other. Which is section 26 for the second time — and the first time,
`CONTRIBUTING.md` gained a line about running `verify_ooo`, which did not
help here because the firmware targets are not in either `verify`. It now
says to run `make sim_opensbi CORE=ooo` when a change touches a CSR, a
privilege check or the MMU. A rule that names the suite is weaker than one
that names the thing the suite does not cover.

The wider habit is to keep a list of the discriminators that are cheap in this
project and reach for them before theorising:

| Question | How | What it separates |
|---|---|---|
| Is it this core? | `CORE=ooo` | pipeline vs shared modules vs software |
| Is it the hardware at all? | `qemu-system-riscv32` | our SoC vs the software stack |
| Is the data in memory what we think? | `+savemem` and a real tool (`dtc`, `cmp`) | corruption vs interpretation |
| Is it where it is loaded? | move the address, re-run | layout vs logic |
| Is it deterministic? | run twice | race vs cause |

Every one of those is minutes. The failure they were pointed at had already
cost hours of reading RTL that turned out to be correct.

The corollary is that elimination is a deliverable. The strongest hypothesis
in this hunt was that the two-level Sv32 walk was broken — nothing in this
repository had ever made the hardware read a second PTE, since
`make sim_mmusdram` mapped megapages only and riscv-tests never enables
paging. Testing it meant extending that program to 4 KB pages, VPN[0] across
its range, per-page permissions and a TLB-aliasing check. The answer was that
the walker was already right. The test stays anyway: the gap it closed was
real whether or not it held the bug, and Linux depends on that path for every
page of userspace.

---

## 30. A probe that reports state needs calibrating; a probe that checks itself does not

Two kinds of instrument came out of one bug hunt, and they behaved completely
differently.

**The reporting kind.** `+watchpc` dumps the integer registers when a given PC
retires, and you read them. It has now produced a confident wrong answer three
times in this project. Once it watched the *fetch* PC and reported registers
from a speculative path (section 27). This time it read the register file in
the cycle the watched instruction retired - when the one or two instructions
*before* it are still in flight and have not written back. At a function entry
that is exactly the argument registers, so it reported the previous call's
arguments: `a0 = 0x9de0003c` two instructions after `mv a0,s3` with
`s3 = 0x9de00000`. That reads as a lost register write, which is a thrilling
and completely fictional bug. `+watchskew=N` fixes that one.

The pattern is that every reading needs a theory of what the probe means, the
theory is usually implicit, and when it is wrong the output is not obviously
wrong - it is plausible.

**What to do about it: calibrate against a case where you already know the
answer, at the same PC.** The reading that eventually mattered in that hunt
was that `a5` held `0x38` at a `bne a0,a5` two instructions after `li a5,1`.
On its own that is exactly the kind of too-good-to-be-true result that had
already been wrong twice. What made it usable was watching the *first*
execution of the same instruction, with the same probe and the same skew,
where the branch demonstrably falls through and `a5` therefore must be 1 - and
it reads 1. A probe that gets the known case right at the same PC is one you
can quote on the unknown case; nothing weaker is.

**The self-checking kind.** `+checkreads`, `+checkfetch` and `+checkmmu` do
not report anything for a human to interpret. Each one compares the hardware
against an independent model of what the answer should be, and is silent
unless they disagree:

| | Compares | Against |
|---|---|---|
| `+checkreads` | every word the interconnect acknowledges | the modelled SDRAM's contents |
| `+checkfetch` | every instruction the core consumes | the same, at the fetch address |
| `+checkmmu` | every address both TLBs resolve | an Sv32 walk written from the spec |
| `+checkuart` | every byte written to the UART's holding register | the byte the receiver decodes off the wire |

Over one Linux boot that is 19.9 million reads, 133.8 million fetches and
125.3 million translations, and the output is three lines. There is no reading
to misinterpret: either something disagreed or nothing did.

They are also *cheap to be sure of*, because a false positive announces itself
immediately. `+checkmmu`'s first version compared against the live `va`, and
mmu.v answers a concluded walk from the `va_r` it latched when the walk
started - so it reported 741 disagreements, every one of them its own. That
was ten minutes to find, because 741 out of 125 million with a common shape is
obviously a bug in the checker. The same error in a reporting probe would have
been one register dump that looked fine.

The rule that follows: **when you can state what the right answer is, check it
instead of printing it.** A probe that prints needs a person to be right about
what it means, every time it is read. A probe that checks needs someone to be
right once, when it is written - and it tells you when they were not.

The corollary is about what elimination is worth. None of the three checks
found the bug. What they bought is that the memory system and the MMU are no
longer suspects - not by argument, but by measurement over hundreds of
millions of events - and they stay in the tree, so the next person to suspect
them can re-run the question in a minute instead of a week.

---

## 31. "The right word from the right address" is two questions

Three self-checking probes said this SoC was behaving, over a whole Linux
boot: every word the interconnect acknowledged matched the modelled part
(19.9M), every instruction the core consumed matched memory (133.8M), every
address both TLBs resolved matched a walk of the page tables (125.3M).

All three were true, and the core was executing the wrong instruction.

`+checkfetch` asks whether the fetch unit returned the right word for the
address it was **given**. It cannot ask whether that was the right address to
have asked for, because it reads the address from the same wire the fetch unit
does. The question it was missing is one level up: *is the instruction the
decoder is holding the instruction at the PC it is attributed to?* That is
`+checkdecode`, it needs the page tables to answer, and it found 35 wrong
decodes in the first forty million cycles it ran.

The defect it found is worth the space, because its shape is the argument.
`rtl/mmu.v` answers a concluded walk from the `va_r` it latched when the walk
began — deliberately, because for a data access the live `va` is recomputed
from forwarding every cycle and decays under a stall. The instruction fetch
does not have that problem and has the opposite one: `redirect_valid`
overrides the PC freeze on purpose, so a mispredict *moves the PC* while a
fetch-side walk is in flight. The walk then hands back the mispredicted path's
physical address, and the IF/ID register pairs a real instruction from that
address with the corrected PC.

Every link in that chain is individually correct. The bus returned what memory
holds. The translation was a correct translation — of the address it was asked
about. The fetch returned the instruction at the address it was handed. Only
the *pairing* was wrong, and a pairing is exactly what a probe on either side
alone cannot see.

The practical rule: when a check reads one of its two operands from the thing
under test, it is not checking that operand. `+checkfetch` takes the address
from the fetch unit; `+checkdecode` takes it from the program counter and
derives the rest independently. That difference is the whole of why one found
the bug and the other could not.

And a second one, from the fix rather than the finding. The first version
compared `pa_va[31:12] != pc[31:12]` — page numbers — and cleared 32 of the 35.
The three it left were redirects *within a single page*, where the page number
matches and the offset does not, and a physical address is `{ppn, va[11:0]}`.
A fix that removes most of a symptom is the most dangerous kind, because the
remainder looks like noise. The check is what said three were left.

---

## 32. A device tree is a claim about hardware, and drivers do not check it

The last defect between this SoC and a Linux userspace was one letter in
`dts/soc.dts`:

```
compatible = "ns16550a";
```

`rtl/uart.v` has no FIFOs. It says so in its own header, and the device tree
said so too, in a comment directly above that line: *"No FIFOs: `fifo-size` is
deliberately absent and IIR reports bits 7:6 = 00, so a driver that checks
will stay in 16450 mode."*

Every clause of that is true. The conclusion does not follow, because
**nothing checks**. `drivers/tty/serial/8250/8250_of.c` sets `UPF_FIXED_TYPE`,
which makes `uart_configure_port()` skip `autoconfig()` entirely — the honest
`IIR` this hardware reports is never read by anything. The compatible string
is not a hint that a probe then confirms. It *is* the configuration.

`ns16550a` means `PORT_16550A`, which means `tx_loadsz = 16`, which means
`serial8250_tx_chars()` writes sixteen bytes into a one-byte holding register
after a single `THRE`, with no status check between them. `rtl/uart.v`'s
`TX_IDLE` arm takes a write only when the transmitter is free, so fifteen of
every sixteen were discarded — correctly, and with nothing anywhere that could
report it, because a part with no FIFO has no bit for "I threw that away".

Two things make this worth a section.

**The symptom impersonated the instrument.** Output came out thinned rather
than absent: `Freeing unused kernel image...` arrived as `Fet2KoecRt=:kL`.
Dropped characters and a mis-decoded baud rate look identical from the far end
of a serial line, and the console is the one component whose failure corrupts
the evidence for every other component. The standing note in
`software/linux/README.md` even said "it is not a decoding rate mismatch — the
harness reports divisor 14, 224 clocks per bit" — which was true, and ruled out
the wrong half. The rate was right. The bytes were not all being sent.

**The check that settles it watches both ends.** `+checkuart` counts what
software wrote to `THR` and compares it against what the receiver decodes off
the wire. It needs no baseline: a write discarded by the transmitter is a
defect on its own terms, and so is a byte on the line nobody wrote. It named
the first twelve losses by value and cycle — `r`, `e`, `e`, `i`, `n`, `g`, ` `,
`u`, `n`, `u`, `s`, `e`, forty-eight cycles apart where a character takes two
thousand two hundred and forty — and that is the whole diagnosis, in the
output of the run that failed. Section 30's rule, applied to the console
itself.

The general form: **`compatible` is not documentation, it is an instruction.**
A binding names a part, and the driver that binds to it implements that part's
contract without asking whether the silicon honours it. Under-claiming costs
performance; over-claiming corrupts data. `dts/soc.dts` now says
`"ns16450", "ns16550"` — the part this is, and the register map it can be
driven through — and the ordering is load-bearing, because Linux scores a
match by its index in *that* list while OpenSBI matches `ns16550` and keeps its
console.

The same file already carried the right instinct, one paragraph up, about the
UART's *previous* compatible string: "naming a compatible string you do not
implement loads a driver that talks to the wrong registers - a worse failure
than having no driver." The registers were right this time. The buffer depth
was not, and nothing in the format distinguishes those two kinds of lie.

---

---

## 33. A number without a spread is not a measurement

`fpga/README.md` carried "**25.37 MHz**, PASS at the board's 25 MHz — 1.5%
margin" for six pull requests, quoted to four significant figures, and it was
one place-and-route run.

nextpnr's placer is a simulated-annealing search seeded from a constant. Three
seeds of the same netlist:

| Seed | Routed Fmax |
|---|---|
| default | 27.63 MHz |
| 2 | 27.07 MHz |
| 3 | 25.47 MHz |

**The spread is 2.2 MHz and the margin being reported was 0.37 MHz.** The
number was not wrong; it was underspecified in a way that made a claim about
the design out of a property of one random seed. The claim worth making is the
worst seed, and it is 25.47 MHz — still a pass, and 1.9% rather than 1.5%,
which is the same order and now has a floor under it.

This is the same failure as `fpga/README.md`'s own opening confession, where
"50–150 MHz is plausible for a core this size" met 28.78 MHz from
place-and-route. That one was an estimate presented as a measurement. This one
is a measurement presented as a constant. Both overstate what one run of a
tool can tell you.

**And read the right number.** nextpnr prints "Max frequency" twice and they
disagree by about 6 MHz here, consistently, on every seed:

```
Info: Max frequency ... : 21.51 MHz (FAIL at 25.00 MHz)   <- after placement
Info: Max frequency ... : 27.63 MHz (PASS at 25.00 MHz)   <- after routing
```

The first is an estimate taken before the router has attacked the critical
nets. Taking it at face value here produced a confident report that the design
had stopped closing timing and needed the fetch path rebuilt — of a design
that passes with 10% to spare. A number that arrives mid-flow is not a result,
and a tool that prints two of them is not being ambiguous, it is being
truthful about a process with stages.

The practical rule: **when a number comes out of a stochastic or staged tool,
report the distribution and say which stage it came from.** Three runs is not
rigour, it is the minimum that distinguishes a number from a coincidence.

---

## 34. Volume is not coverage

`SDRAM-CHECK: PASS` over **256 KB** was this project's evidence that external
memory worked, on silicon, for months. It is true. It is also one
two-hundredth of the claim it sounds like.

`rtl/soc/wb_sdram.v` maps `wb_adr[24:12]` to the row, `wb_adr[11:10]` to the
bank, `wb_adr[9:1]` to the column. Decompose 256 KB against that and it is:

- all 512 columns
- all 4 banks
- **64 of 8192 rows** — row address bits A6 through A12 never driven high

Seven address lines that had never been asserted through the CPU, on a part a
kernel needs 28 MB of. "256 KB" is a volume, and volume reads like coverage
because both are big numbers that go up when things get better. They are not
the same quantity and only one of them is about the hardware.

**The fix is not more volume.** The gap is *which bits toggle*, and that
separates cleanly from how many bytes are touched: one word in each of the
8192 rows drives every row address bit for 16,384 accesses, which costs a
simulation nothing and therefore runs in `make verify` on every change. The
dense sweep stays what it always was — a volume and retention test — and its
full-part build is board-only because 8 million words is hours under Icarus.

The test now states its own coverage rather than leaving it to be worked out:

```
sweeping 256 KB of 32768 KB, against 64 KB of block RAM
  rows 0..63 of 8192, all 4 banks, all 512 columns
  the dense sweep leaves row address bits A6..A12 low; test 3 drives them
```

**It fails when it should**, which is section 1's question and is worth
answering with an experiment rather than an argument. Forcing row bit A7 low
in `wb_sdram.v`:

```
  4096 of 8192 rows wrong, first at 0x90000000 (row 0)
  all 8192 rows, one word each  FAILED
  256 KB unique addresses       ok        <- the old test, same broken part
```

The last line is the entire case. The test this project had been relying on
passes a memory with a dead address line.

**A second thing fell out of trying to run it**, and it is section 26 again.
The natural home for a full-part sweep was the Verilator harness, whose
`+ram=` plusarg has been documented at the top of `sim/verilator_soc.cpp` for
several revisions. It had never worked. `rtl/soc/wb_ram.v` opens with an
`initial` block that zero-fills the array, Verilator runs `initial` blocks on
the *first* `eval()`, and the harness loaded its image before that — so the
preload was erased before the first instruction was fetched. The machine
fetched zeros from its reset vector and trapped forever, printing nothing,
which reads as "the program hung". Nothing had noticed because every previous
run started from SDRAM, which is a C++ model the problem does not apply to.

A documented feature that nothing exercises is indistinguishable from one that
does not exist, and the two stay indistinguishable right up until somebody
needs it.

**Both tests have since run on the part**, which is the ending this section
needs to have: `BOARD=ulx3s85-sdramfull` reports `SDRAM-CHECK: PASS` on a
ULX3S 85F over all 8192 rows and 8,388,608 unique words, and the board's
measured retention interval — 4,031 ms — matches the model's to the
millisecond over sixteen million accesses. A coverage argument that ends in
simulation is a plan; this one ends on silicon.

---

---

## 35. A failed build must not leave a runnable artifact

Six board targets in `fpga/synth/synth_ecp5.sh` write the same
`fpga/build/ulx3s_top.bit`, carrying six different programs, and
`openFPGALoader` cannot tell them apart.

A `BOARD=ulx3s85-ram` build failed in place-and-route — it drew a placement
seed whose routed Fmax came in at 24.87 MHz against a 25.00 MHz constraint,
and nextpnr treats an unmet constraint as a hard error. The bitstream from an
earlier `BOARD=ulx3s85` run was still sitting there. The board got flashed with
it, came up with nothing in block RAM, fell through to the SD path it was
specifically meant to avoid, and printed:

```
=== RV32IMA SoC boot ROM ===
SPI/SD init...
  CMD0 failed after 10 tries: 0x000000FF
BOOT FAILED: no SD card
```

Every line of that is correct. It is an accurate report about a bitstream
nobody meant to flash. The debugging it invites — the card, the slot, the SPI
wiring, the boot ROM — is all downstream of a build that had already failed
and said so.

**The general shape: a build step that fails must not leave behind something
that still runs.** `set -e` stops the script; it does not undo the filesystem.
The previous artifact is byte-for-byte as loadable as a correct one, has no
marking that distinguishes it, and sits at exactly the path the next
documented command names. Deleting the outputs *before* the build starts is
the whole fix, and it works because a missing file cannot be misread while a
stale one is indistinguishable from a fresh one at the moment it matters.

**A stamp that outlives what it describes is worse than no stamp.** This had a
mitigation already: preloading targets copied their program next to the
bitstream as `$TOP.bit.ramimage.hex`, so you could see what was in it. It
failed for a reason worth stating, because it is not obvious — *only the
preloading targets wrote it*. A later non-preload build overwrote the
bitstream and left the stamp untouched, so the directory asserted that a
bitstream carried a program that was no longer in it. A stale absence is
ambiguous; a stale assertion is misleading, and it reads as evidence to
somebody deciding whether to trust the artifact. Every target writes the stamp
now, and it is deleted up front with everything else.

The third instance of the same class in three changes, which is why it is a
section rather than a comment: `make sim_linux`'s gate could not report a
garbled boot because a garbled boot made the log binary and `grep -q` silently
stops matching (§32's PR); `+ram=` was a documented harness feature that had
never worked because nothing exercised it (§34); and now a build failure that
leaves a loadable artifact. In all three the machinery was present, plausible,
and answering a question nobody had checked it could answer.

---

---

## 36. On a shared wire, a protocol byte must be one the console cannot print

The boot ROM's UART loader and the boot ROM's console are the same wire. The
host has nothing but the byte value to tell a protocol reply from ordinary
text, and the acknowledgement byte was `'K'`.

`'K'` is `0x4B`. **"KB" appears in the console output of every program in this
repository** — "64 KB of RAM the firmware assumes", "sweeping 256 KB of
32768 KB, against 64 KB of block RAM". So a host knocking at a board that was
*printing* rather than listening matched the `'K'` of "KB", announced

```
  ROM answered
```

sent its 16-byte header into a program that was not reading a single byte of
it, and then reported the next thing on the wire:

```
error: unexpected reply 0x42 ('B') after header - the ROM should send
       nothing but acknowledgements during a transfer
```

`0x42` is the `'B'` of "KB". Every word of that message is true and all of it
is about a protocol that was never running. The board was working correctly
and doing something else entirely — it had a bitstream with a program
preloaded into block RAM, so the ROM found it, jumped straight to it, and
never opened the knock window.

The fix is to choose bytes the other traffic on the wire cannot produce. This
ROM's console emits printable ASCII plus CR and LF, so `0x06` and `0x15` —
ASCII ACK and NAK — are unforgeable by anything printing. That is a property
of the value, not of timing, ordering or luck.

**The near-miss is the instructive part.** `software/soc/bootrom.c` already
carried a comment about exactly this hazard, in the other direction:

> *it cannot be filtered by value either, because 'E' is the NAK byte and
> "UART LOAD FAILED" contains one*

The collision had been noticed, reasoned about, and solved — for NAK, by
ordering the NAK before its message. The identical problem with ACK went
unexamined, because the analysis was framed as "can the host mistake a message
for a rejection" rather than "can text on this wire produce any protocol
byte". A rule stated as a special case protects the case; a rule stated as a
property protects the class.

**Two more defects came out of writing the test**, both in the same
never-exercised path. `tests/uartload_host.py` gained a board that prints and
never listens, and it was the first thing that had ever let the host's knock
run to its full timeout. That immediately produced a `BlockingIOError`
traceback — `os.write` on a non-blocking port raises `EAGAIN` once the buffer
fills, and nothing handled it. Handling it by retrying then produced the
opposite failure: the retry loop never returned, so the knock deadline was
never re-checked and the host knocked forever at a board that was never going
to answer. Probes and payload need *different* write semantics — the payload
must wait for room because the ROM is reading it, and a probe must be dropped
because nobody may be.

Three defects, all in the path that runs when the far end does not respond,
none reachable by any test that assumed it would.

---

---

## 37. Build the half that does not touch the critical path first

The RISC-V Debug Module has two ways to reach memory. Abstract commands and
the program buffer make the *hart* do it — which means halting it, which means
debug mode, `dcsr`, `dpc`, `dret` and a debug ROM the core vectors into.
System Bus Access does it with a bus master that has nothing to do with the
hart.

This project built the second and deliberately not the first, and the reason
is worth stating because it is a scheduling argument rather than a technical
one.

**Two of six placement seeds already fail to close 25 MHz.** Halt/resume lands
on the fetch redirect and the register file write port — the two paths the
critical path already runs through. Adding to them before the margin is fixed
would turn an intermittent build failure into a permanent one, and it would do
it in the same change that introduces a large new module, so the two causes
would arrive together and have to be separated afterwards.

Splitting on that line cost nothing, because the halves are not equally
valuable. Every failure that has actually cost time on this board — OpenSBI
hanging before its console came up, the boot ROM stopping silently, Linux
dying between `earlycon` and `ttyS0` — was *the memory is fine and I cannot
see it*. None of them needed the hart stopped. The half that touches nothing
is the half that answers the questions.

**The claim is measured, not asserted.** After the change the critical path
runs `CPU.pc` → `CPU.id_ex_pred_target`, 39.68 ns, CPU-internal at both ends
with no cell from `rtl/debug/` in it, and the new clock domain closes at
169.66 MHz against its 15 MHz constraint. "It does not touch the CPU" is the
kind of claim that is easy to believe about your own design and cheap to
check.

**And say what the deferred half means for a user, in the interface.**
`dmstatus` hardwires `allrunning` to 1 and accepts `haltreq` while ignoring
it, so a debugger that tries to halt gets a hart that never halts rather than
a plausible lie. `fpga/openocd/vernier.cfg` deliberately declares no target
for the same reason: `target create ... riscv` would produce timeouts that
read as a broken adapter instead of a Debug Module that says plainly it has no
hart control. A partial implementation should be *legible* as partial from the
outside, not merely documented as partial somewhere else.

---

---

## 38. A random seed is not a controlled variable

Section 33 established that a single place-and-route run is one draw from a
distribution and that the worst seed is the number to quote. This is the
corollary, and it is the one that bites when you try to *improve* something.

An attempt to shorten this design's critical path produced:

| Seed | Before | After |
|---|---|---|
| 1 | 24.80 MHz FAIL | 22.36 MHz FAIL |
| 2 | 24.44 MHz FAIL | 25.05 MHz PASS |

The tempting reading is "seed 2 improved by 0.6 MHz and seed 1 regressed by
2.4". Both halves of that sentence are wrong, because **a placement seed
indexes a random trajectory through a specific netlist**. Change the netlist
and seed 1 is no longer the same experiment with one variable moved — it is a
different draw. Holding the seed number fixed across a design change feels
like a control and is not one.

Against a spread already measured at ~3 MHz, two samples versus three cannot
resolve a change of this size in either direction. The honest statement is
**"no demonstrated effect"** — not "it helped", and equally not "it hurt".

Two things follow.

**A change with no demonstrated benefit does not ship**, however good the
argument for it. The reasoning here was sound and the transformation provably
exact — the predicate `pa_va != pc` really does reduce to
`(state != S_IDLE) && (va_r != pc)`, and that really does put both operands in
registers. Behaviour was identical, both simulators agreeing cycle for cycle.
None of that is evidence about timing, and the measurement declined to supply
any. It touches the fetch path, which is the highest-risk region in this
design and where section 31's defect lived, so the bar is a demonstrated win.
It was reverted.

**"It works and the check disagrees" is not a pass.** A second attempt at this
same path - virtually indexing the instruction cache - booted Linux to
userspace with `+checkdecode` clean over forty million instructions, and
`+checkfetch` reporting wrong words throughout. Both were true: the core is
stalled for the whole window in which the mismatch occurs, so the wrong word
is discarded and nothing architectural goes astray. It was still not
shippable, for two reasons worth separating. The correctness rested on a
*stall* rather than on the fetch being right, which is the same shape as every
defect in this file. And the `verilator_check` gate greps for the read
summary rather than the fetch one, so nothing would have caught it - a probe
firing into a gate that does not read it is a probe nobody has.

**A negative result is a result, and belongs in the tree.** `fpga/README.md`
carries the attempt, the numbers and the reason it was dropped, because the
alternative is that the next person derives the same algebra, spends the same
two place-and-route runs, and learns the same nothing. The measured critical
path is recorded alongside it for the same reason: the useful output of a
failed optimisation is usually the characterisation it produced on the way.

---

---

## Conventions

**Commits** are imperative and say what changed and why it matters — `Test
GPIO through a pad, not through a testbench`, `Report a trap in the loaded
program instead of losing it`. The body carries the reasoning and the
incident; commit messages here are where the history of *why* lives.

**Comments** explain the decision, not the syntax. A comment that says what
the next line does is noise; one that says why the obvious alternative was
rejected, or what broke last time, is why `rtl/soc/wb_ram.v` opens with three
paragraphs about why it is word-organised with synchronous reads.

**Numbers are measured, not estimated.** `fpga/README.md` once said 50–150 MHz
was "plausible for a core this size". Place-and-route said 28.78. That section
now carries the measured critical path and a note that the prediction was
wrong.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for how to get changes in.
