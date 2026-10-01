# Phase 11 — DSP

**Also a decision before it is a design, and unlike every phase above it,
not peripheral-shaped at all.** "Heavy mathematical calculations for
audio, video, and sensors" is what a floating-point or SIMD extension is
for, and adding one means new decode, a new register file, and a new
execution unit inside `rtl/cpu_core.v` itself - the same category of
change as Phase 1's out-of-order rewrite, not a Wishbone slave `rtl/soc/`
gains a new instance of. Naming a specific extension here without having
picked one would be exactly the estimate `docs/practices.md` warns
against holding on to.

**What exists today, precisely:** `misa` reports A/I/M/S/U (`rtl/
csr_file.v`'s `MISA` localparam, Spike co-simulation checked it bit for
bit - see that file's own header) - no `F`, no `D`, no `V`, no `P`. RV32M
already gives integer multiply/divide (`rtl/muldiv_div.v`, a multi-cycle
restoring shift-subtract divider), which is the only hardware math
acceleration this core has. Anything past integer arithmetic - a `float`
multiply, an FFT butterfly, an audio filter's coefficients - runs today
as compiler-emitted soft-float or fixed-point routines on the integer
pipeline, at whatever cost that costs; no measurement of that cost exists
in this repo yet, and one is the natural first step, the same way Phase
1 opened by measuring where cycles actually went before proposing
anything to fix it.

**The first open item:** which extension. Roughly, in order of how much
of the existing pipeline it reaches into:

- **Hardware floating point (`F`, possibly `D`)** - the standard answer
  for "audio and sensor math," and the most standardized path (real
  toolchain support, real `-march=` strings, no invented ISA). Needs its
  own 32-entry register file alongside `rtl/regfile.v`'s integer one,
  and FADD/FMUL/FDIV/FCVT datapaths with their own multi-cycle timing
  story, the same kind of question `rtl/muldiv_div.v` already answered
  once for integer divide.
- **Packed-SIMD / a DSP-style extension** - denser for audio/video
  kernels that are naturally short-vector, but a much less settled part
  of the RISC-V ecosystem to build against than `F` is.
- **A dedicated coprocessor** - closer to how Phase 4's video path is a
  separate block the CPU drives via MMIO rather than an ISA extension at
  all. Trades "every program gets faster math for free" for "the CPU
  hands off a specific, well-defined workload," the same tradeoff Phase
  10's blit-engine option makes for graphics.

**Stage 1: the open question above answered, and a first, real filter
engine built to prove it - not the "Done when" bar itself.** The
decision, confirmed with the user rather than picked silently: a
dedicated coprocessor, the same shape Phase 14's `wb_npu.v` and Phase
10's blit engine both are - a self-contained Wishbone slave, not a new
`rtl/cpu_core.v` execution unit, so neither core's own timing-critical
decode/hazard logic is touched. A new slave, `rtl/soc/wb_fir.v`, at
`0x0A00_0000`: an 8-tap streaming FIR (finite impulse response) filter.

**Genuinely new, not a re-skin of `wb_npu.v`.** `wb_npu.v` loads two
fixed vectors once and computes one dot product, then stops. A real
filter is not that - it is "one new sample arrives, one new output
comes out, forever," which needs state `wb_npu.v` never had to carry: a
sliding window of the last `N_TAPS` samples (the delay line every FIR
filter textbook draws), shifted on every new sample. Writing a new
signed int16 sample to `INPUT` shifts it in and starts a new
`N_TAPS`-cycle multiply-accumulate sweep over the updated window - the
same `rtl/muldiv_div.v` sequential-not-combinational precedent
`wb_npu.v` already used. It also needs a real answer to overflow a
bounded int8 dot product never had to give: two 16-bit samples multiply
to a 32-bit product, and summing `N_TAPS` of them can exceed 32 bits, so
the accumulator is 40 bits internally and the result is **saturated**
(clamped to `INT32_MIN`/`INT32_MAX`), not silently wrapped, into the
32-bit `OUTPUT` register - the same behavior every real fixed-point
audio path implements, since wrapping produces a far worse artifact
than a clipped-but-recognizable one.

**A real bug, caught in the test rather than the RTL, the same
discipline this session has applied to both.** `sim/tb_wb_fir.v`'s own
saturation cases initially reported values that did not match hand
computation - not the intended saturated bound, and not the plain
unsaturated sum either. Traced to a classic Verilog scoping mistake: the
testbench's own `push_and_check` task, called from inside a `for (k =
...)` loop in the saturation sections, used the *same shared,
module-level* `k` for its own internal shift-and-sum loops - so each
call left `k` at whatever value its own last internal loop had reached,
silently truncating the caller's intended seven-iteration loop to one.
The saturated-looking pass on the first attempt was the vacuous kind
this project's own practices exist to catch: the DUT was matching a
reference that was itself only summing one or two terms, not eight.
Fixed by giving the task its own local loop variable, not by patching
the specific loop that happened to trip over it - the structural fix
that makes the whole class of bug impossible rather than one instance
of it. Re-verified against exact hand arithmetic afterward: positive
saturation reaches `INT32_MAX` at exactly the third accumulated term
(`3 * 32767^2 = 3221028867`, the first partial sum past `2^31-1`), not
before or after, and negative saturation reaches `INT32_MIN` at exactly
the third term the same way - not merely "some clamp happened somewhere
in the sequence."

Confirmed non-vacuous a second way, matching every other new test this
session has built: a deliberate RTL mutation (removing the busy guard
on the coefficient-write path) was built, and the same test correctly
failed.

Proven under both cores: `software/soc/main.c`'s new `test_fir()` streams
the same coefficient and sample sequence `sim/tb_wb_fir.v` does through
the real CPU load/store path and the real interconnect address decode -
the standalone test alone cannot prove reachability, the same reasoning
`test_npu()`'s own pairing with `sim/tb_wb_npu.v` already established.
No `CORE_OOO`-specific behavior exists for it to diverge on. Both `make
verify` and `make verify_ooo` are green on the final tree.

**What this stage deliberately does not do, and why "Done when" below
is still fully open:** this is the mechanism, not the workload the bar
asks for. No real audio filter has been run through it, nothing has
been checked against an external reference implementation the way
Phase 14's own `gen_npu_layer.py` used Python, and - critically -
this file's own first line names measuring the
*current soft-math baseline* as "the natural first step," which this
stage has not done either. Both remain real, separate work for a later
stage - proving the register interface, the sliding window, and
saturation is what this stage does, the same "prove the hard piece in
isolation before wiring it to something real" role every one of Phase
13's and Phase 14's own early stages played.

**Stage 2: the "Done when" bar itself, closed.** A real 8-tap lowpass
filter - `software/soc/gen_fir_workload.py`: a windowed-sinc design
(Hamming window, cutoff at 0.15 of the Nyquist rate), unity DC gain,
scaled and rounded to int16 coefficients - applied to a 128-sample
synthetic signal (a low-frequency component plus a higher one past the
filter's own cutoff, so a correct lowpass filter measurably attenuates
it, not merely "some numbers came out"). The same script computes all
128 expected outputs independently, in Python, before either the RTL
or the C test that exercises it ever runs - the same role a plain
NumPy/C reference plays for this project's own RISC-V ISA tests against
Spike.

`software/soc/main.c`'s new `test_fir_workload()` runs the identical
128-sample workload two genuinely independent ways: once by streaming
every sample through `rtl/soc/wb_fir.v`'s real register interface, once
in plain RV32M C with no peripheral access at all, maintaining its own
sliding-window history by hand. Both are checked bit-exact against the
Python reference for all 128 outputs, and both are timed with the
`cycle` CSR, counting everything - the hardware path's own per-sample
`INPUT` write and `STATUS` poll are inside its timing window, not
excluded. Measured, not estimated - the soft-math baseline this phase's
own opening paragraph named as "the natural first step," finally taken:
**3553 cycles on the FIR peripheral, 17993 for the RV32M-only software
baseline computing the identical filter** - the hardware is
**genuinely, substantially faster this time**, about 5.1x, a real
contrast with Phase 14's own NPU result (about 1.16x) worth naming
rather than averaging away: unlike the NPU's one-shot dot product,
where loading every operand costs as much as the arithmetic itself,
this workload's hardware path pays a real per-element cost only once
(one `INPUT` write) and lets the peripheral's own sliding window and
sequential MAC absorb the rest, while the software path pays a real
shift-register cost (seven moves) on top of eight multiply-accumulates
for every one of the 128 samples. Different workload shapes give
genuinely different answers - exactly why this project's own practice
is to measure each one rather than assume a single verdict transfers.

Proven under both cores: `test_fir_workload()` runs inside the same
`sim_ramboot` acceptance test `test_fir()` already does, so `make
verify` and `make verify_ooo` both exercise it - no `CORE_OOO`-specific
behavior exists for it to diverge on.

**What this still does not do, and is not obligated to by the bar's own
wording:** the signal is synthetic, not a real recorded audio clip, and
the filter has not been confirmed on real hardware - simulation only,
same as Phase 14's own Stage 2. Neither is required by this bar's own
text, which asks for a real DSP-shaped workload, verified and measured,
not a specific data source or a hardware confirmation.

**Done when:** ✅ **closed, in simulation, at this scale.** A real
DSP-shaped workload - a small lowpass FIR filter, the "audio FIR
filter" this bar names as the obvious candidate - runs, is verified
bit-exact against an independently-computed reference, and is measured,
not estimated, against the current soft-math (RV32M-only) baseline this
phase's own first step named (Stage 2: 3553 vs. 17993 cycles, about
5.1x). Not yet done, and not required by this bar's own wording: a real
recorded signal rather than synthetic data, and confirmation on real
hardware rather than simulation alone.

## Known defects

None recorded against this phase. The common, cross-cutting entries are in the [index](index.md#common-known-defects).

## Hardware

*Physical board testing: what has and has not run on a real board.*

Not confirmed on hardware. The filter workload is simulation only, the same standing as Phase 14's Stage 2, and the "Done when" does not ask for a hardware confirmation.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Stage 2 closes the bar: a real 8-tap lowpass filter (windowed-sinc design, int16 coefficients) over a 128-sample synthetic signal, checked bit-exact against an independent Python reference for all 128 outputs, through both the `rtl/soc/wb_fir.v` register interface and plain C, and timed with the `cycle` CSR, in simulation. The signal is synthetic, not a recorded audio clip.
