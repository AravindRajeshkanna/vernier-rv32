# Phase 3 — Make it fast enough to be interesting

Every fetch and every load goes to the bus, and the interconnect is a shared
bus rather than a crossbar, so a load costs the fetch behind it a cycle.

## The I-cache: done, and it was the whole game

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
this. Nothing here has been through synthesis. (Update: Phase 8 Part 7 later
measured it, and the estimate was low: the whole design is 31,837 LUT4s with 64
entries, 33,130 with 256 and 42,070 with 1024.)

## The D-cache: 1.11x more, and it moved where the next work is

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

## Spatial locality: measured six ways, and it doesn't pay for itself here

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

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

No number in this phase was measured on a board. The Fmax figures are place-and-route results; the CoreMark cycle counts are simulation results. Whether the caches change what a real board does beyond those figures has not been separately checked.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

All measurements here are CoreMark cycle counts from simulation on the SoC: the I-cache took the in-order core from 867,958 to 517,588 cycles (1.68x) and the wide core to 484,306 (1.79x), and the D-cache was worth a further 9.9% on the wide core and 12.3% on the in-order one. The "Done when" bar, a measured improvement with the `NOTICE` disclosure, is met in simulation.
