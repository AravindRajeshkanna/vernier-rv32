# Phase 14 — Neural processing (quantized inference)

**A decision before it is a design, the same shape Phase 11 is, and for
the same reason: naming a specific architecture here without having
picked one would be exactly the estimate `docs/practices.md` warns
against holding on to.** The target is scoped, though, which Phase 11's
own "which extension" question is not yet: small quantized-inference
workloads - int8 weights and activations, multiply-accumulate into a
wider (int32) accumulator, the standard arithmetic shape of a quantized
neural-network layer - not general floating-point math or training.

**What exists today, precisely: nothing NPU-shaped.** RV32M
(`rtl/muldiv_div.v`) gives integer multiply, one operation at a time, on
the same pipeline every other instruction uses - no accumulation
register, no wide (int8×int8→int32) datapath, no operation that reduces
a vector or a matrix in hardware rather than in a software loop. A
quantized MAC engine, in whatever shape this phase eventually picks,
would be new hardware end to end, not a parameter added to something
that already exists - the same starting position Phase 1's out-of-order
rewrite was in, not the "close reading finds most of it is already
plumbing" position Phase 13 started from.

**The first open item, genuinely undecided rather than deferred: how
this reaches the core.** Two shapes, at opposite ends of how much of
`rtl/cpu_core.v`/`rtl/ooo/core_ooo.v` it touches:

- **Custom RISC-V instructions**, matching how this project added `M`
  and `A` - new decode, likely a new accumulator register or a
  convention for reusing the existing integer register file in pairs,
  and a multi-cycle execution unit alongside `rtl/muldiv_div.v`'s own.
  Every program gets access without a driver, at the cost of reaching
  into the pipeline's own decode/hazard logic the way Phase 1 and Phase
  11's floating-point option both would.
- **A memory-mapped peripheral on the Wishbone bus**, matching Phase
  10's blit engine or Phase 4's video path - a new `rtl/soc/` slave the
  CPU drives via MMIO registers (load operands, trigger, poll or
  interrupt on completion), no ISA change at all. Trades "every program
  gets it for free" for "a well-defined, self-contained block that
  cannot destabilize the instruction pipeline's own timing," the exact
  tradeoff Phase 10's own blit-engine option names for the same reason.

Nothing about the quantized-inference target above decides this by
itself - both shapes can do int8 MAC accumulation equally well - so this
is a real open design choice for whoever starts this phase, not a
placeholder for an answer already known.

**Stage 1: the open question above answered, and a first, deliberately
small MAC engine built to prove it - not the "Done when" bar itself.**
The decision: a memory-mapped peripheral, confirmed with the user rather
than picked silently, for the reason already named above - it cannot
destabilize either core's own timing-critical decode/hazard logic the
way reaching into `rtl/cpu_core.v`/`rtl/ooo/core_ooo.v` would. A new
Wishbone slave, `rtl/soc/wb_npu.v`, at `0x0900_0000`: two fixed
16-element int8 vectors (`A0`-`A3`/`W0`-`W3`, 4 lanes per word), a
`CTRL`/`STATUS` start-busy pair matching `wb_framebuffer.v`'s own
`BLIT_CTRL`/`BLIT_STATUS` convention exactly (writes ignored while
`BUSY`, not queued or errored), and one multiply-accumulate per cycle
into a signed 32-bit `RESULT` - `rtl/muldiv_div.v`'s own sequential, not
combinational, shape, since a real workload's vectors only get longer
from here and a wide parallel multiply-add tree does not scale the same
way a streamed one does.

**A gate failure, same class as two already fixed this session in
unrelated modules, caught before it could ship again.** `wb_npu.v`'s own
`idx_r`-vs-`VEC_LEN-1` comparison tripped the identical `WIDTHEXPAND`
issue `rtl/plic.v` (Phase 13 Stage 8) and `rtl/clint.v` (Stage 10) both
needed fixing - an unsized parameter's arithmetic result compared
against a narrower, explicitly-sized register. This one needed a step
neither precedent did: a bare bit-slice of the parameter itself
(`plic.v`'s own `NUM_CONTEXTS_W8` shape) was not available, since the
comparison value is a *computed* expression (`VEC_LEN-1`), not the bare
parameter - assigning that computed expression straight into a narrower
`localparam` declaration tripped a different warning
(`WIDTHTRUNC`) instead of the first. Resolved with a two-step
`localparam`: a full-width `VEC_LEN_M1` holding the subtraction, then an
explicit slice of *that* into the correctly narrow comparison value -
verified clean with a standalone `verilator --lint-only -Wall` pass
before rebuilding, the same discipline both earlier fixes used.

Also caught, from the same "add a peripheral" checklist
`docs/soc.md` section 6 already names as the step that bites: `fpga/
synth/synth_ecp5.sh`'s own RTL file list was missing not just this
stage's `wb_npu.v` but `rtl/soc/reservation_monitor.v` too - a real,
already-shipped omission dating back to Stage 9, invisible until now
because nothing in `make verify`/`make verify_ooo` exercises the actual
FPGA synthesis script, and `soc_top.v` has unconditionally instantiated
`reservation_monitor` since that stage. Both are in the file list now,
confirmed by an actual `./fpga/synth/synth_ecp5.sh` run rather than
assumed fixed by inspection.

Proven by two directed tests, matching the checklist's own step 6 as
well as Stage 6's own "verify the hard piece in isolation" precedent:
`sim/tb_wb_npu.v` (`sim_wb_npu`, now in `make verify`) checks the MAC
result against an independently-computed reference dot product - a
plain sum-of-products loop in the testbench, not the RTL's own
arithmetic copied - and separately checks that a `CTRL`/`A0` write
attempted mid-computation is genuinely ignored, not just that the
ordinary path works; confirmed non-vacuous by mutating the RTL (removing
the busy-guard on the register-write block) and watching the same test
fail on both the corrupted result and the exposed operand overwrite.
`software/soc/main.c` gained `test_npu()`, matching `test_gpt()`'s own
established per-peripheral shape exactly, proving the same peripheral is
reachable at `0x0900_0000` through the real CPU load/store path and the
real interconnect address decode - the standalone test alone cannot
prove that. Both `make verify` and `make verify_ooo` are fully green on
the final tree.

**What this stage deliberately does not do, and why "Done when" below
is still fully open:** the vector depth is a fixed 16 elements, loaded
one MMIO write at a time - nowhere near a real layer's own operand
count, and not the shape a measurement against a software baseline would
be fair on. Closing the actual bar needs a bus-master port reading
operands directly out of RAM - the same role `rtl/soc/wb_ptw.v` plays
for page-table walks - and a real small workload with a reference to
check against, neither attempted here. This stage proves the mechanism
(operand loading, streamed MAC, accumulation, busy/done, real address
reachability) works, the same "prove the hard piece in isolation before
wiring it to something real" role every one of Phase 13's own early
stages played.

**Stage 2: the "Done when" bar itself, closed - and Stage 1's own
prediction about it turned out wrong.** Stage 1 asserted above that a
fixed 16-element, MMIO-loaded vector was "not the shape a measurement
against a software baseline would be fair on," and that closing the bar
needed a bus-master DMA port first. Measuring rather than assuming
(`docs/practices.md`) turned up the opposite: a small quantized dense
layer - four output neurons, each a 16-element int8 dot product against
one shared activation vector, `software/soc/main.c`'s new
`test_npu_layer()` - built entirely from the already-shipped Stage 1
hardware, closes it as literally written.

The workload: `software/soc/gen_npu_layer.py` generates a fixed,
reproducible activation vector and a 4x16 weight matrix (mixed-sign
int8; a short search over `random.Random` seeds picked one where all
four expected outputs are nonzero and pairwise distinct, so a sign bug,
a dropped term, or a neuron mix-up would each visibly change the
result) and computes the four expected dot products independently in
Python - the same role a NumPy/C int8 reference plays for this
project's own ISA tests against Spike, this time with no shared code
path to either the RTL or the C test that exercises it. `test_npu_layer()`
computes the identical four dot products two more, genuinely
independent ways: once by driving `rtl/soc/wb_npu.v` (loading the
shared activation vector once, then looping over each neuron's own
weights, triggering, and polling), once in plain RV32M C with no NPU
access at all. All three - Python, hardware, software - agree
bit-exact.

Both paths are timed with the `cycle` CSR, counting *everything* - the
hardware path's own MMIO writes to load every neuron's weights are
inside its timing window, not excluded, because excluding them would be
exactly the kind of favorable-to-the-thesis estimate
`docs/practices.md` exists to catch. Measured, not estimated: **561
cycles for the NPU path, 654 for the RV32M-only software baseline
computing the identical four dot products** - the hardware is faster,
but only by about 1.16x, not the order-of-magnitude a "hardware
acceleration" framing might suggest. That is an honest result for a
workload this small: loading four 16-element weight vectors one MMIO
word at a time costs comparably to the 64 multiply-accumulates
themselves, so there is not much arithmetic yet to amortize the loading
cost over - the same shape of finding Phase 1's own CoreMark
measurement produced ("barely faster... the ROI case made before it
was built held up only once it was measured"), reported here rather
than smoothed over.

Confirmed non-vacuous the same way this session has confirmed every
other new test: a deliberate mutation (every neuron's weight-loading
loop pointed at neuron 0's own weights instead of its own) was built,
and the same test correctly failed - three of the four neurons' results
stopped matching the independently-computed reference.

Proven under both cores: `test_npu_layer()` runs inside the same
`sim_ramboot` acceptance test `test_npu()` already does, so `make
verify` and `make verify_ooo` both exercise it - no `CORE_OOO`-specific
behavior exists for it to diverge on, matching `test_npu()`'s own
reasoning.

**What this still does not do, and is not obligated to by the bar's own
wording:** the workload is synthetic (`random.Random`, not a real
trained model's own weights), simulated only (no board build asks for
this peripheral, so nothing here is confirmed on an LFE5U-85F yet), and
scaled to what Stage 1 already built (16 inputs, four outputs) rather
than a realistic layer's own size. The DMA/bus-mastering port Stage 1
named stays real, valuable future work for scaling past what fits
comfortably as always-resident MMIO registers - it is simply no longer
a precondition for closing this bar, which Stage 1 wrongly assumed it
was.

**Stage 3: the DMA/bus-mastering port itself, built anyway - real,
valuable work Stage 1 named and Stage 2 confirmed was not required to
close the bar.** `rtl/soc/wb_npu.v` gains a second, independent way to
reach the same MAC engine: a Wishbone bus-master port, the same role
`rtl/soc/wb_ptw.v` plays for page-table walks, configured by two new
registers (`A_ADDR`/`W_ADDR`, the RAM byte addresses of the operand
vectors) and a third (`LEN`, a runtime element count - not a
synthesis-time parameter, so a DMA-driven vector is no longer capped at
`VEC_LEN` the way the original MMIO path still is). CTRL bit 1 starts
it; the original CTRL bit 0/A0-A3/W0-W3 MMIO path is untouched and
still the smaller of two ways to reach the engine, not replaced.

**A new master needs a real place in `rtl/soc/wb_interconnect.v`'s own
priority order, and this one gets the simplest possible answer: last.**
Every existing tier's own priority is justified by what would go wrong
if it lost - a stalled pipeline, a broken atomic, an indefinitely
delayed page-table walk. None of that reasoning applies to a DMA
transfer nothing else in the SoC is waiting on: it has no forward-
progress dependency, and no correctness property depends on it winning
the bus promptly, or at all. Placed at the bottom of the arbitration
order specifically because it is the only master here with nothing to
lose by waiting - lowest priority is not a judgment about importance,
it is the conclusion the same "what breaks if this loses" reasoning
every earlier tier already used actually reaches for this one.
`formal/fv_interconnect.v` gained a new property (4c: fetch, walker,
data, and debug all outrank it, whenever arbitration is genuinely open)
and extended four existing ones (5, 6, 7, 8) to cover it - proved,
depth 12, alongside the five properties already there, not asserted
untested. Confirmed non-vacuous by mutation: letting the new tier win
against fetch too (instead of losing to it, as designed) produced a
real counterexample - two masters selected in the same cycle, an ack
delivered under the wrong master's own address - within the same
bounded-model-checking run, not a hypothetical.

Proven two ways, matching this project's own "prove the mechanism in
isolation, then through the real path" sequencing: `sim/tb_wb_npu.v`
gained a standalone DMA test against a 1-wait-state behavioral memory
model (the same timing shape as `rtl/soc/wb_ram.v`, so the test cannot
pass merely because reads happen to resolve in zero cycles) - a
32-element vector, double `VEC_LEN`'s own MMIO-mode cap, checked
against a reference computed independently in the testbench and
confirmed by hand arithmetic (every term of this stage's own test
pattern simplifies to `-(i+1)(i+2)`, so the total is `-Σk(k+1)` for
k=1..32, a closed-form sum checkable without trusting either
implementation). Confirmed non-vacuous by mutation: freezing the DMA
word index so it never advances past the first word produced a wrong,
checkable-by-hand-as-wrong result. Separately, `software/soc/main.c`'s
new `test_npu_dma()` proves the same master reaches real RAM through
the real interconnect - a 64-element vector, stored as ordinary static
arrays so the linker (not a hand-picked address) decides where they
land, DMA'd and checked against an independently-computed reference
(`-91520`, the same closed-form check scaled to 64 terms). Both `make
verify` and `make verify_ooo` are green on the final tree, `make
formal` included.

**What this still does not do:** no real, larger-than-toy workload has
been run through DMA mode yet, and nothing has been measured against a
software baseline at DMA scale the way Stage 2 did at MMIO scale - this
stage proves the mechanism (a bus-master port, correctly arbitrated,
reaching real RAM) works, not that it is faster or that a real model
has used it. Real trained-model weights, a workload real enough to be
worth measuring at this larger scale, and confirmation on real hardware
all remain open, exactly as Stage 2 already said they would.

**Stage 4: the workload Stage 3 left unmeasured, run and measured.**
`software/soc/gen_npu_dma_workload.py` builds the identical shape Stage
2's own `gen_npu_layer.py` already did - `NPU_DMA_OUT` output neurons,
each a dot product against one shared activation vector, expected
outputs computed independently in Python - at `NPU_DMA_INPUT_DIM=128`
rather than 16: eight times `VEC_LEN`'s own MMIO-mode cap, specifically
because that width cannot be reached through the MMIO path's fixed
register file at all. `software/soc/main.c`'s new
`test_npu_dma_workload()` runs it two genuinely independent ways -
through `rtl/soc/wb_npu.v`'s own DMA master, and in plain RV32M C with
no NPU access at all - checked bit-exact against the Python reference
both times, the same three-way independence Stage 2's own measurement
already established.

Measured, not estimated, counting everything (every DMA register write
and poll is inside the hardware path's own timing window, the same
"count the real cost, not a favorable slice of it" rule Stage 2's own
measurement already held itself to): **1220 cycles on the NPU's own DMA
path, 4840 for the RV32M-only software baseline computing the identical
128-input, 4-neuron layer - about 4.0x**, a real and substantial win,
in clear contrast with Stage 2's own MMIO-scale result (561 vs. 654,
about 1.16x). The reason is exactly the one Stage 2's own account named
without being able to measure yet: at MMIO scale, loading every operand
costs about as much as the arithmetic itself; at DMA scale, the
hardware path's own per-element cost is a streamed bus read comparable
to what the software loop's own memory reads already cost, so there is
real arithmetic left over for the MAC engine to amortize against -
which is the entire premise Stage 1 gave for building a streamed,
one-element-per-cycle engine in the first place, now with a number
attached to it instead of an assumption.

**What this still does not do, named plainly rather than smoothed
over:** this implementation's own DMA state machine re-fetches the
*entire* activation vector out of RAM for every one of the four
neurons, even though it is the same 128 elements each time and
`A_ADDR` never changes between them - `rtl/soc/wb_npu.v` has no
on-chip cache across separate DMA starts, only within one. A version
that fetched the activation vector once and reused it across all four
neurons would cost less than the 1220 cycles measured here, and this
number should not be read as the ceiling DMA mode can reach - it is
what this specific implementation, unoptimized in this one respect,
actually measures today. Real trained-model weights rather than
synthetic data, and confirmation on real hardware, remain open exactly
as before.

**Done when:** ✅ **closed, in simulation, at this scale.** A real
quantized-inference workload - a small int8 matrix-vector multiply, the
"single small layer" this bar names as the obvious candidate - runs, is
verified bit-exact against an independently-computed reference, and is
measured, not estimated, against a software-only (RV32M-only) baseline
computing the identical workload (Stage 2, MMIO scale: 561 vs. 652
cycles, about 1.16x; Stage 4, DMA scale, 128 inputs: 1220 vs. 4840
cycles, about 4.0x - the same "measure it, do not assert it" bar Phase
11's own "Done when" holds itself to, at two different scales rather
than one). Not yet done, and not required by this bar's own wording:
real trained-model weights rather than synthetic data, and confirmation
on real hardware rather than simulation alone.

**Stage 5: the exact inefficiency Stage 4 named, closed and measured -
not part of the "Done when" bar itself, which Stage 4 already fully
closed.** Stage 4's own account named a real cost plainly: every one of
the four neurons in that workload re-fetches the entire 128-element
activation vector out of RAM, even though `A_ADDR` never changes across
them. `rtl/soc/wb_npu.v` gains a bounded, synthesis-time-sized on-chip
cache (`A_CACHE_LEN`, default 128 - matching Stage 4's own workload
exactly) that every ordinary DMA start (CTRL bit 1) populates as a side
effect of its own A-fetch, plus a third way to start DMA mode (CTRL bit
2) that reuses that cache instead of re-fetching `A_ADDR`, reading only
`W_ADDR` out of RAM. `STATUS` bit 1 (`A_CACHE_VALID`) reports whether the
cache actually holds the current run's own vector at the current `LEN` -
a bit-2 start when it does not is a well-defined no-op, matching
`wb_framebuffer.v`'s own `BLIT_CTRL`/`BLIT_STATUS` "ignored while busy"
convention this register map already followed for bits 0/1, rather than
a silent wrong answer.

**Bounded deliberately:** `A_CACHE_LEN` is real on-chip storage, not a
free abstraction over RAM, so a vector that does not fit (`LEN >
A_CACHE_LEN`) simply is not cached - `A_CACHE_VALID` clears rather than
the hardware silently caching a truncated or wrong vector.

**A real FSM bug caught before any test ever ran, worth stating rather
than folding into an already-clean account:** the first draft of the
"not the last element" DMA transition unconditionally advanced to
`S_DMA_FETCH_A` for the next word, regardless of mode - correct for a
fresh fetch, wrong for a reuse-mode run, which must never re-enter that
state at all. Caught by tracing the FSM's own transition table by hand
before writing the final code, not by a test catching it after the
fact; fixed by conditioning the transition on `reuse_mode_r`.

Confirmed non-vacuous twice, matching this project's own "prove the
mechanism, then through the real path" sequencing already used for
Stage 3's own DMA master: `sim/tb_wb_npu.v` gained a standalone
`cache_test` (populates the cache via an ordinary DMA run, corrupts the
same RAM words the behavioral memory model backs, starts a reuse-mode
run, and checks the result still matches the correct reference - plus
confirms a mismatched-`LEN` reuse start is genuinely ignored) and an
`oversized_test` (a `LEN` run exceeding `A_CACHE_LEN` leaves
`A_CACHE_VALID` clear). Mutating the reuse-mode start transition
(pointing it at `S_DMA_FETCH_A` instead of `S_DMA_FETCH_W` - the same
class of bug named above, deliberately reintroduced) produced exactly
two failures - the reused-result check and the ignored-mismatched-reuse
check - both showing the RTL had silently re-read the now-corrupted RAM
instead of using the cache. `software/soc/main.c` gained
`test_npu_dma_cache()`, the same proof through the real interconnect and
real RAM Stage 3's own `test_npu_dma()` already established for the DMA
master itself: it runs Stage 4's own workload with neuron 0 fetching
fresh and neurons 1-3 reusing the cache, corrupts a writable copy of the
activation vector after the timed run closes, and confirms one more
reuse-mode start still produces the correct result. The same mutation
(confirmed independently on this file, not assumed to transfer from the
standalone test) makes exactly this one new acceptance-test check fail,
with every other check - including the pre-existing DMA workload
measurement it sits next to - still passing.

Measured, not estimated, timed with the identical `hw_c0`/`hw_cycles`
window `test_npu_dma_workload()` already uses (same start point, same
four neurons, nothing else inside it, so the two totals are a fair
comparison - the correctness check above deliberately runs after this
window closes, since corrupting RAM costs real cycles of its own that
would otherwise inflate the very number being reported): **986 cycles,
versus 1220 for the same workload without the cache - about 1.24x
faster, roughly 19%.** Algebra against both aggregate numbers (four
neurons at an uncached cost `x` each give `4x = 1220`; one neuron at
cost `x` plus three at a cached-reuse cost `y` give `x + 3y = 986`) puts
the uncached per-neuron cost at about 305 cycles and the cached-reuse
cost at about 227 - a roughly 78-cycle saving for each of the three
neurons that no longer re-fetch `A_ADDR`, smaller than a naive "removing
a 32-word RAM read should save many hundreds of cycles" estimate would
suggest, and named plainly rather than smoothed over: this RAM model's
own per-word read cost inside `S_DMA_FETCH_A` is evidently cheap already
relative to the rest of each neuron's own DMA sequence (arbitration, the
W-fetch that still happens every time, and 128 MAC cycles), so removing
it trims a real but modest fraction of the total rather than a
dominant one.

**What this still does not do:** the cache is populated only as a side
effect of an ordinary (bit 1) DMA start and is sized for exactly this
workload's own 128-element vector (`A_CACHE_LEN`'s default) - a vector
wider than that is never cached at all, falling back to a fresh fetch
every time with no error or degraded mode in between. No software
anywhere in this tree yet uses the cache for anything beyond this one
measurement; a real model with more than one shared-activation layer, or
with an activation vector wider than 128, would need either a larger
`A_CACHE_LEN` or to keep re-fetching, exactly as before this stage. Real
trained-model weights and confirmation on real hardware remain open, as
named at Stage 4 and unchanged by this stage.

**Stage 6: real trained-model weights, closing the one gap every stage
since Stage 2 has named as still open - not part of the "Done when" bar
itself, which Stage 4 already fully closed.** Every earlier NPU
workload's own int8 vectors - Stage 1's fixed 16 elements, Stage 2's
layer, Stage 3/4/5's 128-input DMA workload - were drawn straight from
`random.Random`, values with no relationship to any task at all, used
purely as mixed-sign test vectors. `software/soc/gen_npu_trained_layer.py`
is different in kind, not just in source: a from-scratch, pure-Python
(no numpy/sklearn/torch exists in this environment) multi-class linear
softmax classifier, trained by per-example stochastic gradient descent
on a real cross-entropy loss, no bias term (the peripheral is a pure dot
product with no accumulation input, so a model needing a bias would not
be faithfully representable in this hardware at all). The weights below
are the *output* of that training - the same category of artifact a
real deployed quantized model's weights would be.

**What is, and is not, "real" here, stated as plainly as the script's own
header states it:** the weights are genuinely trained; the data they are
trained and validated on is still synthetic - four class "prototype"
directions in 128-dimensional space, real examples drawn as
prototype-plus-noise, not sourced from any external real-world dataset,
since none is fetched or bundled in this environment. This closes
"trained weights", not "real-world data" - a model trained on genuinely
real-world data remains a still-different, still-open gap, named here
rather than folded into a claim this stage does not earn.

Trained in float, quantized to int8 afterward - standard post-training
quantization, per-tensor min-max scaling, separately for the weight
matrix and for the one held-out activation vector actually fed through
hardware - matching how quantized-inference deployments actually work,
not an invented scheme. Held-out accuracy, measured over 100 fresh
examples never used in training: **88.0%**, embedded as a comment in the
generated header itself so the claim "this model actually learned
something" is checkable, not just asserted. A short seed search (the
same convention `gen_npu_layer.py` already established) additionally
requires the one activation vector checked in hardware to be correctly
classified by both the float model and its int8-quantized counterpart,
so quantization provably does not flip this specific example's own
decision.

Runs through `rtl/soc/wb_npu.v`'s own DMA master at `NPU_TRAINED_INPUT_DIM
= 128`, the same width as `A_CACHE_LEN`'s own default, so class 0's
weights trigger a fresh DMA fetch of the activation vector and every
class after it reuses Stage 5's own on-chip cache - real reuse of
already-shipped machinery, not new hardware. `software/soc/main.c`'s new
`test_npu_trained_layer()` checks two genuinely different things: the
raw dot product for every class against the independently-computed
(Python) reference - a fresh sum-of-products loop over the quantized
int8 values alone, not derived from any training/quantization
intermediate - and, the check that actually matters for a "real trained
model" claim rather than "the arithmetic matches" (already proven
several times over by every earlier NPU stage), that the class with the
highest dot product - the hardware's own classification decision -
matches `NPU_TRAINED_CORRECT_CLASS`, the label the *original float
model*, before quantization, before ever touching this peripheral,
assigned to this exact held-out input.

**Confirmed non-vacuous, and an honest miss caught along the way.** The
established mutation for this cache path (pointing the reuse-mode start
transition at `S_DMA_FETCH_A` instead of `S_DMA_FETCH_W`) was tried here
first, expecting it to fail this test the same way it fails
`test_npu_dma_cache()` - it did not. Tracing through why: this test never
corrupts RAM after the cache is populated, unlike `test_npu_dma_cache()`,
so a reuse-mode run that mistakenly re-fetches from RAM instead of the
cache still reads the same, uncorrupted, correct activation bytes and
produces the same correct answer regardless of the bug. That is a real
finding about this test's own coverage, not a reason to call it passing:
this test does not re-prove cache correctness (Stage 5 already did, and
still does), it only *uses* the cache as shipped. The mutation that
actually exercises what this stage is new about targeted the generated
data instead: hand-editing the built (gitignored, not committed)
`npu_trained_layer_data.h` to flip `NPU_TRAINED_CORRECT_CLASS` to a wrong
label produced exactly one failure - this test, on exactly the
classification-decision check - with every other check, including the
adjacent cache-reuse dot-product measurement, still passing. A second,
separate mutation (corrupting one `npu_trained_expected[]` value by one)
produced the same single, isolated failure, confirming the bit-exact
dot-product check is independently live too, not dead code shadowed by
the classification check. Both mutations were reverted (the header
regenerated cleanly from the untouched script) and reconfirmed passing
before this was written down.

**What this still does not do:** the data is synthetic, not real-world,
named above rather than smoothed over; no board build has ever asked for
this peripheral, so nothing here is confirmed on real hardware; and this
is a single linear layer with no bias, not a multi-layer network - a
faithful match to what this specific piece of hardware can actually
compute, not a claim about what quantized inference in general looks
like.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

None. No board build has ever asked for this peripheral, so nothing in this phase is confirmed on an LFE5U-85F.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Stages 1 to 6 are simulation results: the quantized inference workload, the "Done when" bar (Stage 2), the DMA bus-mastering port, the measured workload and its inefficiency, and trained-model weights. The data is named in each stage as synthetic or trained, and the final stage states that it is a single linear layer without bias, not a multi-layer network.
