# Phase 4 — Video out

The framebuffer works and is verified by capturing a frame off the scan-out and
comparing it back (`make sim_video`), and the CPU's path to it is covered on
hardware by the acceptance test.

**Update: all four stages below are now done - the encoder, the PLL, the
serializer, and real GPDI pin wiring (`fpga/video_out.v`,
`fpga/constraints/ulx3s.lpf`), gated in `make verify` via `sim_ulx3s_video`
and synthesizing/routing for real via an opt-in `BOARD=ulx3s85-video`
target (opt-in because it costs this project's primary board target real
timing margin, measured below - not because anything is unfinished).**
The one thing left is the "done when" below, unchanged since this section
was first written: nothing has run against a real monitor yet. This
opening paragraph used to say nothing was routed to the HDMI pins at
all - kept accurate here rather than left to contradict the stage-by-stage
account immediately below, which was updated each time but never fed back
up to this summary.

**Done when:** a monitor shows the colour ramp the acceptance test leaves in
the framebuffer.

**Stage 1 (encoding) is done: `rtl/soc/tmds_encode.v`, the DVI 1.0 spec's
8b/10b transition-minimized, DC-balanced encoding, one channel per
instance.** Deliberately the first piece attempted, because it is the only
part of this phase that needs no board, no PLL and no serializer to prove
correct - `sim/tb_tmds_encode.v` (`make sim_tmds_encode`, in `verify`)
checks it against hand-derived vectors from the spec's own algorithm, cross-
checked against an independent reference implementation
([mithro/tmds_encoding](https://github.com/mithro/tmds_encoding)) rather
than trusted on inspection: two disparity-independent bytes (0x10, 0xEF,
where the transition-minimized result is already perfectly balanced, so the
same code comes out regardless of history) prove stage 1 alone; 0x00 and
0xFF fed twice each prove stage 2's running-disparity tracking actually
flips the encoding on the second occurrence, which a stateless per-byte
table could never do; the four fixed control tokens are checked verbatim.

**Stage 2 (the PLL) is also done: `fpga/video_pll.v`, one `EHXPLLL` with two
taps off the same VCO - 125 MHz (`clk_bit`, the eventual serializer's SCLK)
and 25 MHz (`clk_pixel`, re-emitted rather than reused from `clk_25mhz`
directly, so it shares the same fixed phase relationship to `clk_bit` a
free-running divide-by-5 counter could not guarantee across resets).
Parameters came from the project's own `ecppll` tool, not hand-picked - VCO
625 MHz, both taps exact integer divisions, zero rounding, which is the
same 25 MHz-not-25.175 MHz payoff the entry above already named.
`sim/tb_video_pll.v` (`make sim_video_pll`, in `verify`) checks the
simulation-mode fallback's divider gives an exact 5:1 period ratio and that
`locked` rises rather than starting high - `EHXPLLL` itself has no Icarus
model, matching `fpga/sdram_clk_out.v`'s `ODDRX1F` before it. **Also run,
by hand, once: `yosys` (oss-cad-suite `0.68+118`) + `nextpnr-ecp5 --85k
--package CABGA381` on a throwaway top-level wrapper - 0 errors, places and
routes, and nextpnr's own frequency derivation from the `EHXPLLL`
attributes reports exactly 125.0 MHz for `clk_bit`.** That is the one
thing simulation cannot check (a black-boxed hard primitive elaborates to
nothing in Icarus) and the one place a wrong parameter would only have
shown up on a real build.

**A real near-miss, worth naming so it does not recur:** the first attempt
at the serializer (stage 3 below) was going to use `OSER10`, a dedicated
10:1 serializer primitive - which turns out to belong to Gowin's cell
library, not Lattice's. `grep -rl OSER10` against the toolchain's own
bundled cell definitions found it only under `yosys/gowin/`; ECP5's actual
output serialization primitives (`yosys/ecp5/cells_bb.v`) top out at
`ODDR71B` (7:1). Caught before any RTL was written by checking the
toolchain's own primitive list rather than trusting a half-remembered name
- the kind of mistake that would otherwise have failed silently at
synthesis (an unrecognized module) rather than doing something worse.

**Stage 3 (the serializer) is also done: `fpga/tmds_serialize.v`, 5:1 DDR
through `ODDRX1F` clocked by `clk_bit` - 2 bits out per 125 MHz cycle, 5
cycles per pixel clock, 10 bits total, the same `ODDRX1F`
`fpga/sdram_clk_out.v` already uses for a different signal.** Rather than
assume the PLL's phase relationship (now concretely known from stage 2, but
still unverifiable in simulation, since `EHXPLLL` has no Icarus model), it
treats `clk_pixel` as a signal to detect the edge of in the `clk_bit`
domain with an ordinary two-flop synchronizer - correct regardless of what
that relationship turns out to be on real silicon, depending only on the
5:1 frequency ratio the PLL guarantees exactly.

**Two same-edge simulation races, both in the testbench, not the RTL -
recorded because both are easy to get wrong again the same way.** First,
the by-now-familiar one (`sim/tb_tmds_encode.v`'s own history repeated
itself): reading `UUT.px_rise`/`word_r`/`pos` from an `initial` block
immediately after `@(posedge clk_bit)`, with no settling delay, saw the
*previous* cycle's value instead of the one just committed by
non-blocking assignment in the DUT's own `always` block reacting to the
same edge. Second, a genuinely different one this project had not hit
before: `tmds_out`'s simulation-mode body is a **continuous assignment**
keyed directly on `clk_bit` (`clk_bit ? d0_r : d1_r`), and reading it
right after `@(negedge clk_bit)` raced that assignment's *own*
re-evaluation, triggered by the same negedge - every "low phase" sample
read the pre-transition value. Both need a `#1` settling delay; the second
is not covered by "nothing is sensitive to that edge," which was true for
every register in the design but not for a continuous assignment driven
directly off the clock signal itself.

**A structural bug in the first version of the test, independent of both
races above: a linear "detect the edge, then capture five bit pairs, then
look for the next edge" loop consumes six `clk_bit` cycles for a period
that is only five**, because the *next* word's edge is detected on the
same cycle the *current* word's last bit pair is still being sampled - so
the loop silently drifts out of phase after the first word, reading real
bits from the wrong point in the stream. Rather than get every interlocking
cycle count exactly right by hand, `sim/tb_tmds_serialize.v` now samples
continuously with no assumption about which cycle anything starts on, and
checks whether the known word sequence appears, intact and in order, at
some fixed 10-bit stride anywhere in a long captured stream - a weaker but
sufficient question that does not depend on predicting the DUT's internal
phase to ask.

**Also run by hand, once, chained behind the real PLL and encoder: `yosys`
+ `nextpnr-ecp5 --85k --package CABGA381` on a throwaway wrapper. Two real,
board-relevant constraints found and recorded, neither of which `fpga/tmds_serialize.v`
violates but both of which the next stage (wiring real GPDI pins) will need
to respect:** `ODDRX1F`'s `Q` output must connect only to a top-level
output port, no intermediate logic (nextpnr refuses otherwise); and
`ODDRX1F`/DDR IOLOGIC only works on a genuinely pin-constrained PIO, not an
auto-placed one (`--lpf-allow-unconstrained` alone is not enough once a
DDR primitive is in the design, unlike stage 2's PLL-only check). With
`tmds_out` constrained to the real `gpdi_dp[0]` site (A16, from the pin
table below) instead: 0 errors, places and routes, `clk_bit`-domain Fmax
**252.72 MHz routed** (the placement-estimate pass reports a lower,
non-final 241.43 MHz first, the same placed-vs-routed distinction
`fpga/README.md`'s Phase 3 investigation already documents) against the
125 MHz it actually needs.

**A clocking question resolved before any of the "still missing" items
below could safely be attempted: what clock does `tmds_encode.v`'s
`clk`/`tmds_serialize.v`'s `clk_pixel` actually connect to?** `rtl/soc/soc_top.v`
clocks `video_timing`/`wb_framebuffer` off the SoC's own `clk` - the same
net the CPU, cache and bus all use, confirmed by reading the instantiation
directly (`video_timing VTIMING (.clk(clk), ...)`), not assumed.
`video_pll.v` also has a `clk_pixel` output tap, generated alongside
`clk_bit` from the same VCO - using it for the encoder/serializer looked
like the obvious choice, and would have been wrong: `clk_pixel` and the
SoC's `clk` are both nominally 25 MHz but are two *different* nets (one
straight off the `clk_25mhz` pin, the other regenerated through the PLL),
related by a fixed but - like every other `EHXPLLL` phase question in this
file - unverifiable-in-simulation delay. Unlike the 5:1 `clk_bit`:`clk_pixel`
relationship `tmds_serialize.v`'s two-flop synchronizer already handles
safely (five bit-clock samples per pixel period is comfortable oversampling
margin regardless of phase), a 1:1 same-frequency crossing has none - a bad
enough phase alignment could tear or drop a pixel *deterministically*, every
single frame, not as an occasional metastability event, and no amount of
simulation against a fallback clock model built for this file's own
convenience could have caught it, because the real number is exactly the
one nothing here can check.

The resolution: `tmds_encode.v`'s `clk` and `tmds_serialize.v`'s
`clk_pixel` will be wired to the SoC's own `clk` directly - the same net
`wb_framebuffer.v` already uses, so there is no crossing between the
framebuffer's pixel stream and the encoder at all, not even a safe one.
`tmds_serialize.v`'s `clk_bit` still comes from `video_pll.v`, and the 5:1
relationship that makes its synchronizer safe holds regardless of which
25 MHz net is on the other side of it, because `clk_bit` and the SoC's
`clk` are both ultimately derived from the same `clk_25mhz` pin - `clk_bit`
through the PLL, `clk` directly, matching exactly how `video_pll.v` and
`soc_fpga` are wired to that same pin today (`fpga/ulx3s_top.v`'s `SOC`
instantiation: `.clk(clk_25mhz)`). `video_pll.v`'s `clk_pixel` output tap
is not removed - an unused output costs nothing once nothing is connected
to it, and touching an already-shipped, tested module for no functional
reason is not this round's job - but a future round wiring the real
top-level should not connect it to the video path. No RTL changed this
round; this is recorded so the wiring round does not rediscover a 1:1 CDC
hazard by building it first.

**Stage 4 (the real wiring) is done, but not on by default - `fpga/video_out.v`
ties the framebuffer's pixel stream to all four GPDI channels, and
`fpga/constraints/ulx3s.lpf` has the real `gpdi_*` pin constraints.**
Blue (channel 0) carries `hsync`/`vsync`; Green and Red tie `c0`/`c1` low,
per DVI convention. The clock channel gets no encoder - a fourth
`tmds_serialize` instance alone, fed the fixed `10'b0000011111` pattern DVI's
spec calls for on that pair, since there is nothing to encode there. The
real GPDI sites, cross-checked between the two sources this project's own
pinout methodology already uses (the official `ulx3s_v20.lpf` and
litex-boards' `radiona_ulx3s.py`, which agree exactly): blue
`gpdi_dp[0]`/`gpdi_dn[0]` = A16/B16, green `gpdi_dp[1]`/`gpdi_dn[1]` =
A14/C14, red `gpdi_dp[2]`/`gpdi_dn[2]` = A12/A13, clock
`gpdi_dp[3]`/`gpdi_dn[3]` = A17/B18, all `IO_TYPE=LVCMOS33D DRIVE=4`.

**Confirmed against a real, published reference before writing any pin-facing
RTL: only `gpdi_dp[i]` is ever a Verilog signal.** `LVCMOS33D` is
Lattice/Trellis's differential I/O mode - a "_p" port tagged with it, at a
site with a declared "_n" partner in the LPF, gets its complementary output
generated by the I/O buffer hardware from placement alone. A `gpdi_dn` port
in the Verilog would be a *second*, independently-driven signal, which is
wrong for TMDS and not what any real ULX3S GPDI design does - checked
against emard's own `ulx3s-misc/examples/serdes_dvi`, whose top module
declares `gpdi_dp` and nothing else. `fpga/tmds_serialize.v` needed no
change for this; a version that drove both sides explicitly would have
been extra, incorrect work.

**A real, measured cost, and this is the reason it is opt-in rather than
built into the primary board target.** First synthesis of the fully wired
board (`CORE=inorder BOARD=ulx3s85` with `video_out` instantiated
unconditionally): **0 of 6 seeds close 25 MHz**, every one routing lower
than the corresponding seed in the pre-video baseline (22.47-24.04 MHz
against 23.01-25.14 MHz) - not one unlucky seed, a shift across the whole
distribution. Raised `SEED_TRIES` to 16 to rule out an unlucky sample
before concluding anything: **still 0 of 16**, range 22.14-24.04 MHz, no
seed within a megahertz of closing. The critical path itself is unchanged
- still `BUSADAPT.dc_tag`-sourced, the same shape this section has
described since Phase 3's first six-seed sweep - and `video_out.v`'s own
logic does not appear on it; this is ordinary added-die-area routing
congestion pushing an already-thin margin further down, not a new logical
bottleneck. The distinction does not make the cost smaller: this project's
primary board target going from "closes on 1 of 6 seeds" to "does not
close in 16" is a real regression to the thing more people depend on
(the SoC actually running) traded for a thing nobody has tested on
hardware yet.

**Resolution: `WITH_VIDEO` is a build-time opt-in, not the default.**
`fpga/ulx3s_top.v` only declares the `gpdi_dp` port and instantiates
`video_out` under `` `ifdef WITH_VIDEO ``, the same style this project
already uses for `CORE_OOO`. Plain `BOARD=ulx3s85`/`ulx3s` build exactly as
before - re-measured after this change: **23.01/23.19/24.57/23.43/25.14
MHz, closes on seed 5, bit-for-bit identical to the pre-Phase-4 baseline** -
and `BOARD=ulx3s85-video` opts in, for whoever wants the feature and
accepts the cost. `make verify` now runs both: `sim_ulx3s` (unchanged,
no video) and a new `sim_ulx3s_video` (`-DWITH_VIDEO`, so `video_out.v`'s
integration is actually exercised in simulation and not merely compiled
in and left uninstantiated).

**Still missing:**

1. Hardware validation - "done when" above - the one remaining piece, and
   it needs `BOARD=ulx3s85-video` specifically (accepting its timing cost)
   plus an actual monitor. Nothing left to build first.

## Known defects

**`rtl/soc/wb_framebuffer.v` crashes yosys itself during real FPGA
synthesis - a real gap in the tree's own coverage, since nothing in
`make verify`/`make verify_ooo` attempts real place-and-route at all.**
`./fpga/synth/synth_ecp5.sh` (or a direct `synth_ecp5` invocation on the
file in isolation) reaches yosys's own `CHECK` pass and terminates with
`libc++abi: terminating due to uncaught exception of type
std::out_of_range: vector` - a raw C++ exception from inside yosys, not
a diagnostic yosys prints and continues from. First found while
measuring Fmax for PMP stage 4 (`beyond-the-phases.md`'s PMP entry); a
separate, already-fixed synthesis break in the same file (an
async-reset ambiguity on `a_q`, "Multiple edge sensitive events found
for this signal") was the *first* thing found there and does not
explain this one - the fix for that landed and this crash still
reproduces on top of it.

Three things ruled out, each with real evidence rather than assumed:

- **Not a toolchain mismatch.** `docs/toolchain.md` pins two different
  Yosys builds for two different purposes - Homebrew's (`0.67+post`)
  for `make formal`, oss-cad-suite's (`0.68+118`) for real synthesis -
  and the first investigation used the wrong one (Homebrew's, picked up
  via `autopilot_config`'s general-purpose "append, don't prepend" PATH
  rule, which is correct for the simulation gates but not for this
  script). Re-run explicitly against oss-cad-suite's own `yosys` binary,
  matching `docs/toolchain.md`'s documented pairing exactly: identical
  crash, same pass, same exception type.
- **Not the memory array's sheer size on its own.** A from-scratch
  minimal module - the same 19,200-word array, the same byte-lane-qualified
  write pattern this module actually uses, none of its fill/copy/line
  engine logic - synthesizes past the point this module crashes at
  (`CHECK`) and runs deep into ABC9 logic optimization before being
  killed by the OS (`EXIT=137`, consistent with memory exhaustion, not a
  yosys-internal exception) far later in the flow. A large block-RAM
  array alone is not sufficient to reproduce this specific crash.
- **Not the specific async-reset bug already fixed.** That fix (splitting
  `a_q` into its own `posedge clk`-only block) is confirmed necessary and
  landed - without it, synthesis fails *earlier*, with a clean, named
  error rather than a crash. This is a second, different problem
  encountered only after the first is already fixed.

What is not yet known: which part of the fill/copy/line engine's own
logic - beyond plain byte-lane-qualified writes to a large array, which
the minimal reproduction above shows is not enough on its own - produces
the netlist shape that trips this. The next step is the same bisection
technique that found the async-reset bug (stage 1 fill-only, then
stage 2 with copy, then stage 3 with line, each synthesized in
isolation), not yet completed for this specific crash because each
attempt against the real 19,200-word file costs 30-60+ minutes before
reaching the point of failure - a real cost, not a reason to guess
instead of measuring. Left here rather than chased further this round:
nothing in `make verify`/`make verify_ooo` is affected (this is real
synthesis only, which those targets never run), and no board is
attached to this session to make a working bitstream the actual
end goal being blocked. A `std::out_of_range` inside yosys's own `CHECK`
pass, on a design pattern yosys otherwise handles at both smaller scale
and at this same scale with different logic, is also a real candidate
for a yosys bug report upstream, not necessarily something this
project's own RTL is doing wrong - that possibility has not been
ruled out either, and would change what "fixing" this even means.

**Update 1: the bisection above turned out impractical on available
hardware, but a cheaper technique found the likely root mechanism -
`mem[]` never maps to a real block RAM at all, which points squarely
back at this project's own RTL.** The planned stage-by-stage bisection
(fill-only, then +copy, then +line, each synthesized at real 320x240
scale) does not complete on an 8 GB machine: even the simplest,
fill-only variant was killed by the OS during `FSM_EXTRACT`, before
reaching the `CHECK` pass this defect is actually about, so the
technique could not distinguish "this stage is fine" from "this stage
also crashes, just later." Comparing stages at full scale needs either
more memory than was available this round or a different technique
entirely.

A different, much cheaper technique found something the bisection
would not have: overriding `FB_WIDTH`/`FB_HEIGHT` via yosys's own
`chparam` shrinks the array without touching a single line of RTL, and
running the *actual, current* file (every stage's logic present) at
8x8 through 128x128 reaches `CHECK` cleanly every time - no crash, no
`std::out_of_range` - while still never once producing a "mapping
memory `wb_framebuffer.mem` via ..." line from `MEMORY_LIBMAP`. Compared
directly against `rtl/soc/wb_ram.v` in the same flow, which *does* map
its own byte-lane-written array to `DP16KD` (`mapping memory wb_ram.mem
via $__DP16KD_`), this means `wb_framebuffer.v`'s `mem[]` silently falls
through to `MEMORY_MAP` (flip-flops and logic) at *every* size tested,
scale-independent - it just so happens that the fallback is cheap enough
to survive at 128x128 and is not at 320x240. This reframes the defect:
the likely root cause is not an obscure `CHECK`-pass exception at all,
but this array never being mapped to real block RAM in the first place,
with `CHECK`'s crash being a downstream symptom of how large the
fallback gets at the real buffer's actual size. `wb_ram.v`'s own header
already documents this exact failure mode from this project's past ("the
previous version... asynchronous reads on three separate ports... falls
back to building the array out of flip-flops - two million of them - and
never finishes... One port, not four.") - strong precedent that this is
the same class of bug recurring, not a new yosys defect.

**What is different here, and what has been ruled out trying to close
that gap.** `wb_framebuffer.v`'s `mem[]` needs three effective ports (one
write, shared by the CPU and the engine, plus Port A's own read and Port
B's independent scan-out read) against `wb_ram.v`'s genuinely single
port (one read, one write, same address, same always block) - a
plausible reason `MEMORY_LIBMAP`'s default matching declines it. A
from-scratch minimal reproduction (a 256-word array, one write port, two
independent read ports, nothing else) rules out "three ports, full stop"
as the explanation: it maps cleanly, via `$__PDPW16KD_`, to two real
`DP16KD` primitives, in half a second. Three further synthetic
reproductions, together covering every other feature `wb_framebuffer.v`'s
real code actually has - byte-lane conditional writes (`wb_ram.v`'s own
pattern) against two independent reads; the write scattered across
separate case branches at different addresses (CPU write vs. the
engine's own) combined with a read address multiplexed on an internal
phase bit (`effective_read_addr`); and, in one module, all of the above
plus a captured read register whose value feeds a *later* write
(`copy_src_byte`) and two separate engine-write case branches to the
same address (line vs. fill/copy) - every one of them still mapped
cleanly to two `DP16KD`s at the same 256-word size the real file already
fails at. None of these, alone or together, is the trigger.

**What is not yet known, still.** The real file's specific wide,
multiply-based address computation (`(blit_cur_y * FB_WIDTH) +
{20'd0, blit_cur_x}`, sliced to `AW` bits out of a 32-bit intermediate)
and its much larger total signal count (the Bresenham line state and
everything else this module carries, well beyond any synthetic
reproduction tried) remain untested as the specific trigger, individually
or together. A fix attempt along the lines of `wb_ram.v`'s own historical
one - explicitly splitting `mem[]` into two arrays, one per read port, so
each individually looks like a single-port memory - was tried directly
against the real file and did not restore BRAM mapping either, so the
eventual fix is not yet known to be that simple. Left here rather than
guessed at further this round, for the same reasons as before: nothing in
`make verify`/`make verify_ooo` is affected, and no board is attached to
this session.

**Update 2: the crash is reproduced for the first time outside the real
file, in a minimal, purpose-built ~80-line module - both named
hypotheses from the paragraph above are needed together; neither alone
is enough.** Both remained untested because a full real-file bisection
is impractical on this exact machine (`sysctl hw.memsize`: 8 GB) - the
same reason "What is not yet known, still." gives above. The fix was not
a bigger machine, but smaller, purpose-built modules: the crash reproduces
on a bare `yosys -p "read_verilog ...; hierarchy -top ...; proc; check
-force-detailed-loop-check"` pass with no techmap and no ABC9 (already
established earlier in this file, alongside the separate `CORE=ooo` Fmax
entry's own Round 6), so isolating one variable at a time costs seconds
per run at small scale - dramatically cheaper than the 30-60+ minutes a
full real-file attempt needs. Every run below used oss-cad-suite's own
`yosys` (0.68+118, git sha1 `144c707b7-dirty`), the exact pairing
`docs/toolchain.md` documents for real synthesis - not Homebrew's, the
mismatch already ruled out earlier in this same entry.

Four small, cheap, single-variable-at-a-time modules, all at a safe
256-word (or 150-word, for the sizing test) scale matching the four
existing reproductions': a multiply-based write address alone (matching
`blit_pixel_index`'s real shape - a 12-bit y register times an
unsized-parameter width, summed with a zero-extended x, sliced for word
address and byte lane); the asymmetric read mux alone (matching
`effective_read_addr`'s real shape exactly - one read address
multiply-derived, the other a plain bus-address slice, muxed on a
phase-bit-equivalent condition); non-power-of-two sizing alone (150
words against an 8-bit, 256-slot address space, the same ~59%-used
ratio the real file's 19200-of-32768 has); and all three together. Every
one of the four synthesized cleanly, sub-second, under 125 MB - no
crash, matching the four *existing* reproductions' own clean results
exactly. Addressing complexity alone, at small scale, is not sufficient.

**One real methodological trap found and worked around, worth naming so
nobody repeats it:** the first attempt at a scalable version made
`WIDTH`/`HEIGHT` real module `parameter`s on the synthetic module itself
(mirroring `FB_WIDTH`/`FB_HEIGHT` textually) and tried `chparam -set
WIDTH 8 -set HEIGHT 8` before `hierarchy`, expecting the same safe
shrink `synth_ecp5.sh` already uses on `soc_top`. It silently did not
work - a nominally "8x8" run still cost 10.75s and 1.2 GB, because the
module's own `mem[]` array is declared directly from those parameters
with no instantiation step in between, and yosys's Verilog frontend
appears to bind the array's size from the parameter's *declared default*
during `read_verilog` itself, before `chparam` ever runs - unlike the
real project's own usage, where `FB_WIDTH`/`FB_HEIGHT` flow from
`soc_top` down into an actual `wb_framebuffer` *instance*, and `hierarchy`
is what specializes that instance to the overridden value. Confirmed by
comparing against a hardcoded-`localparam` version of the identical
module at the identical "8x8" size: 0.06s and 23 MB - two orders of
magnitude cheaper, and the number every subsequent test below actually
used. `chparam` on a self-contained top module does not do what it does
on a real instantiated hierarchy; every size below was generated as a
fresh file with `WIDTH`/`HEIGHT` as hardcoded `localparam`s instead.

**Scaling the combined (all-three) module toward real dimensions found
real, severe, super-linear cost growth before any crash appeared - and a
plain baseline with zero addressing complexity grows the same way.** At
128x128 (4,096 words, `AW=12`), the combined module synthesized cleanly
but expensively: 178.81 s, 908.88 MB peak (`proc_mux` alone: 124 s). A
*plain* baseline at the identical 4,096-word scale - one write port, two
independent reads, no multiply, no asymmetric mux, no non-power-of-two
sizing at all - was also expensive, just less so: 71.69 s, 654.75 MB
(`proc_mux`: 28 s). Scaling the combined module further, to 200x200
(10,000 words, 2.44x the word count), cost 1,064.59 s (~17.8 min) and
1,481.78 MB (`proc_mux`: 737 s, ~5.95x for 2.44x the words - consistent
with roughly quadratic growth). This growth is real and worth naming on
its own even though it is not, by itself, the answer: it means array
*size* alone, independent of either named hypothesis, already drives
severe non-linear cost in yosys's own `proc`/`mem2reg` machinery once
`mem[]` falls through to flip-flops (as "Update 1" above already
established it always does) - a plausible-looking but, it turns out,
incomplete explanation.

**The real answer: a plain baseline at the exact real 320x240 scale
(19,200 words, `AW=15`) does NOT crash - ruling out "array size alone."**
Given how expensive the combined module already was at smaller scales,
the single most informative next test was the cheapest one available:
the same zero-complexity baseline, scaled all the way to the real word
count, with nothing else added. It completed cleanly - 1,759.92 s
(~29.3 min), 1,474.89 MB peak, `Found and reported 0 problems.` This
rules out array size on its own as sufficient, at exactly the scale that
matters, and reframes the question precisely: whatever triggers the real
crash needs the addressing complexity *and* the real scale together.

**Reran the combined (multiply write address + asymmetric read mux +
non-power-of-two sizing) module at the exact real 320x240/19,200-word
scale. It crashes - identically to the real file:**

```
4. Executing CHECK pass (checking for obvious problems).
libc++abi: terminating due to uncaught exception of type std::out_of_range: vector
Checking module repro9_320x240...
```

`EXIT=134` (`SIGABRT`, matching the real file's own crash), the exact
same exception type, dying at the exact same point - inside the `CHECK`
pass, before it prints anything past its own banner line - that the real
`wb_framebuffer.v` crash already documented above dies at. This is the
first time this crash has ever been reproduced in anything other than
the real, ~600-line file: a purpose-built module of roughly 80 lines,
carrying none of the Bresenham line engine, none of the CPU/Wishbone bus
logic beyond a single byte-lane write, and none of the real file's other
signals - only `mem[]`, one multiply-derived write address, one
multiply/plain-slice read-address mux, and a non-power-of-two word
count, all three together, at real scale.

**What this establishes, precisely.** Neither named hypothesis alone is
sufficient (four separate small-scale tests above, all clean) and
neither is array size alone, even at the exact real word count (the
zero-complexity baseline above, also clean). The combination of
addressing complexity - some or all of multiply-based addressing, the
asymmetric read mux, and non-power-of-two sizing - together with real
scale, is what reproduces it. This is a real, minimal, working
reproduction case for the first time in this investigation's history.

**What this does not yet establish.** *Which* of the three combined
features, individually or in which pairing, is the actual necessary
trigger - not isolated this round. Each additional real-scale test costs
20-70+ minutes on this machine (the two real-scale runs above already
took roughly 29 and (before the crash cut it short) an unmeasured but
comparable span), so narrowing further was left as a named next step
rather than guessed at or chased through the night on the strength of
this one result - the same discipline this investigation has held to at
every prior round. That next step is now dramatically cheaper than it
looked before this round started: an ~80-line purpose-built module
iterates in tens of minutes per test, not the 30-60+ minutes (or,
per "Update 1," outright OOM) a full real-file attempt costs, and - now
that a small, clean, reliable reproduction exists independent of this
project's own RTL - is also a real, strong candidate to report upstream
to YosysHQ directly, the same possibility this entry named as plausible
before any reproduction existed. The reproduction files themselves are
throwaway and were not committed, matching every prior repro in this
entry; the exact shapes and commands above are written precisely enough
to reconstruct them.

**Update 3: narrowed further - the asymmetric read mux is not needed at
all. A single multiply-based WRITE address, alone, at real scale, is
sufficient.** The next question Update 2 left open was which of its
three combined features (or which pairing) is the true trigger. The
cheapest single test to run first: keep the one multiply-based address
(matching `blit_pixel_index` exactly) feeding only the engine's write
path, and replace the read side entirely with two independent, both-
plain reads - no mux, no asymmetry, no second multiply anywhere in the
design. Otherwise identical scale (19,200 words, `AW=15`) to Update 2's
own real-scale tests.

It crashes - identically:

```
4. Executing CHECK pass (checking for obvious problems).
libc++abi: terminating due to uncaught exception of type std::out_of_range: vector
Checking module repro10_multiply_only_320x240...
```

Same `EXIT=134`, same exception type, same point in `CHECK`. This rules
out the asymmetric read mux as a necessary ingredient - it was present
in Update 2's reproduction only because it is present in the real file,
not because it is load-bearing for the crash. The minimal trigger found
so far is dramatically smaller than Update 2's own three-feature
combination: **one multiply-derived address, feeding one write path,
at real 320x240 scale** - nothing else in the design needs to be
unusual at all.

**What this still does not establish.** Whether multiplication
specifically is the operator that matters, or whether any comparably
wide, non-trivial address computation (a long addition/shift chain of
similar bit width, say) at this same real scale would trigger the same
exception - not yet tested, and a real, cheap-to-state, precise next
question for whoever continues this. Also not yet tested: whether the
multiply needs to feed a *write* specifically, or would trigger the
same exception feeding only a *read* with an otherwise-trivial write.
Left here for the same reason as every stopping point in this
investigation: real, incremental progress recorded precisely, not
guessed past.

**Update 4: answered one of Update 3's two open questions decisively -
the multiply must feed a WRITE. Feeding only a read, it is
indistinguishable from the zero-complexity baseline.** The mirror image
of Update 3's own test: the same multiply-based address (matching
`blit_pixel_index` exactly) now feeds only a *read* port, with the write
path reduced to a single plain, trivial write (no case/byte-lane logic
at all). Same real 320x240/19,200-word scale.

It does not crash - and costs almost exactly what Update 2's own
zero-complexity baseline did:

```
Checking module repro11_multiply_read_only_320x240...
Found and reported 0 problems.
...
End of script. ... time: 1764.55s, ... MEM: 1487.34 MB peak
```

Compare Update 2's plain baseline at the identical scale: 1,759.92 s,
1,474.89 MB. Within noise of each other - a multiply-derived address
feeding a read behaves, for yosys's own cost and correctness purposes,
exactly like no addressing complexity at all. Paired with Update 3's
own crashing write-side test, this pins the trigger down precisely:
**a multiply-derived address must drive a memory WRITE, specifically,
at real scale - merely existing anywhere in the design, including
feeding a read, is not enough.**

**What remains open.** Whether multiplication specifically is the
operator that matters for the write-side trigger, or any comparably
wide, non-trivial write-address computation would do the same - the one
question from Update 3 not yet answered. Given how precisely this has
now narrowed (one multiply, one write, real scale - nothing else), this
is a strong point to hand off for an upstream YosysHQ report rather than
keep narrowing operator-by-operator on this machine.

**Update 5: answered the last open question - it is not multiplication
specifically. Any comparably wide, non-trivial write address triggers
it.** Replaced Update 3's multiply-based write address with a five-term
shift/add chain (`{20'd0, cur_y} + {19'd0, cur_x, 1'b0} + {18'd0,
cur_y, 2'b0} + {17'd0, cur_x, 3'b0} + {16'd0, cur_y, 4'b0}`) - no `*`
operator anywhere in the design, and deliberately not mathematically
equal to the original `cur_y*WIDTH+cur_x` (so yosys's own optimizer
cannot fold it back into an equivalent multiply). Otherwise identical to
Update 3's own crashing test: same write structure, same real
320x240/19,200-word scale, feeding only the write path.

It crashes - identically:

```
4. Executing CHECK pass (checking for obvious problems).
libc++abi: terminating due to uncaught exception of type std::out_of_range: vector
Checking module repro12_addchain_write_320x240...
```

Same `EXIT=134`, same exception, same point in `CHECK`. Multiplication
is not the operator that matters - a genuinely different arithmetic
shape (five-term shift/add, no multiply cell possible anywhere in this
design) reproduces the identical failure.

**The minimal trigger is now fully characterized, across five rounds of
narrowing (Updates 1-5): a wide, non-trivial, *computed* write address -
built from more than a simple slice of an existing signal, regardless of
which arithmetic operator computes it - driving a `mem2reg`'d array at
real ~19,200-word scale.** Every clean baseline in this investigation
used a direct slice (`bus_addr[AW-1:0]`) for its write address; every
crashing case computed the write address from an actual expression
(multiply, or now, shift/add) wide enough to plausibly produce any value
across the address's full bit range, not just a value known to fit
`WORDS`. This is now precise enough, and small enough (an ~85-line
module, no dependency on this project's own RTL beyond the address
shape it's modeled on), to be a strong, complete candidate for a direct
upstream report to YosysHQ - not attempted in this round, left for the
user's own explicit decision on whether and how to file it.

**Update 6: tested a real, concrete candidate fix - registering the
computed write address one cycle ahead of use - and it does not work.**
With the trigger now fully characterized as "a computed, not
directly-sliced, write address," a natural real-world fix suggests
itself: pipeline the address, so the actual `mem[addr] <= ...` write
reads a simple registered value rather than a same-cycle wide
computation. Took Update 5's own crashing shift/add-chain module and
added exactly that - `eng_word_addr`/`eng_byte_lane` registered one
cycle ahead, the write using the registered versions, nothing else
changed. Same real 320x240/19,200-word scale.

It still crashes - identically:

```
4. Executing CHECK pass (checking for obvious problems).
libc++abi: terminating due to uncaught exception of type std::out_of_range: vector
Checking module repro13_registered_addr_320x240...
```

Same `EXIT=134`, same exception, same point. This rules out a real,
plausible, commonly-reached-for fix: the crash is not about
combinational-versus-registered timing at the write port. Whatever
yosys's own `CHECK` pass is tripping over evidently looks at the write
address's *provenance* - traceable back to a wide, multi-term
computation versus a simple slice of an existing signal - regardless of
whether a register sits between that computation and the write itself.
A real fix, if this project chases one before an upstream yosys fix
lands, needs to change what the address is computed *from*, not merely
when it is computed relative to the clock edge.

**Update 7: tested a second real candidate fix - explicitly bounding
the computed address's range via `% WORDS` - and it also does not
work.** Every crashing case so far used an `AW`-bit slice of a wide
computation, technically capable of spanning the full `0..2^AW-1`
range, wider than `WORDS` itself (Update 1's own finding - 19,200 of
32,768 possible values). A real fix candidate: force the address
provably into range with an explicit `% WORDS`, so yosys's own range
analysis has a mathematical guarantee to work with, not just a wide
slice. Took Update 5's own crashing module and added exactly that -
`eng_word_addr = chain_index[AW+1:2] % WORDS` - nothing else changed.
Same real scale.

It still crashes - identically:

```
4. Executing CHECK pass (checking for obvious problems).
libc++abi: terminating due to uncaught exception of type std::out_of_range: vector
Checking module repro14_bounded_addr_320x240...
```

Same `EXIT=134`, same exception, same point. Two real, independent fix
ideas - pipelining the address, and provably bounding its range - have
now both failed to change the outcome at all. Neither *when* the
address is computed nor *whether its value is provably in range*
matters; what triggers this is evidently structural - the write
address being sourced from any non-trivial computed expression at all,
rather than a direct signal slice, regardless of that expression's own
timing or provable bounds. Two failed fix attempts, on top of the full
characterization Updates 1-5 already established, is a strong signal
that further guessing at RTL-side fixes has a low hit rate from here;
the upstream YosysHQ report remains the strongest next-step candidate,
left for the user's own decision on whether and how to file it.

**Update 8: a third candidate fix works - splitting the array into
smaller banks avoids the crash entirely.** Updates 2 and 6-7 already
established two things that, combined, suggest a real candidate: no
array at or below ~4,096-8,192 words crashed at any point in this
investigation, even with full addressing complexity (Update 2's own
128x128/4,096-word combined-feature test was clean), while the *same*
crashing computed-address logic against one 19,200-word array always
crashed. If the array itself, not merely the address expression, is
part of what triggers this, splitting the same logical 320x240 address
space into several individually-small arrays - each still reached via a
genuinely computed sub-address, not a direct slice - should avoid it.

Split the same 19,200-word logical space into 8 independent 2,400-word
banks (well under the already-safe ~4,096-word scale), decomposing
Update 5's own crashing write address into `(bank_select, sub_index)`
via `/`/`%` against the bank count, and routing the write through a
`case` on `bank_select` into the correct bank. (A first attempt at this
had a real bug - only byte 0 of each word was ever driven, leaving
460,800 bits structurally undriven and producing an unrelated flood of
"used but has no driver" warnings that would have confounded the
result; fixed by driving full 32-bit words throughout, the same
correction discipline `docs/practices.md` calls for before trusting a
result.) Same real logical 320x240 address space, same real oss-cad-suite
`yosys`.

**It does not crash:**

```
4. Executing CHECK pass (checking for obvious problems).
Checking module repro15b_banked_320x240...
Found and reported 0 problems.
...
End of script. ... time: 1113.04s, ... MEM: 1727.53 MB peak
```

The first successful candidate fix in this investigation, after two
failed attempts. Worth being precise about what this does and does not
establish: this is a *different* split strategy from the one Update 1
already reports as tried directly against the real file and
unsuccessful there - that earlier attempt split `mem[]` into two arrays
*by read port* (matching `wb_ram.v`'s own historical fix, each array
still covering the full word range), aimed at restoring `MEMORY_LIBMAP`
BRAM mapping specifically. This test splits by *address range* instead
(several arrays, each covering a disjoint slice of the total space),
and was only tested for whether it avoids the `CHECK` crash - not
whether it restores BRAM mapping, which is a related but separate
question this round did not test. Applying this same address-range
split to the real `wb_framebuffer.v` file, and confirming whether it
both avoids the crash *and* produces an efficient netlist there, is real
follow-up work, not yet attempted.

**Update 9: applied to the real file. The crash is gone.** Rewrote
`rtl/soc/wb_framebuffer.v` itself using Update 8's exact validated
shape: `mem[]` replaced by `NBANKS=8` separate bank arrays
(`BANK_WORDS = ceil(WORDS/NBANKS)`, 2,400 words each at the real
default), every address that used to index `mem[]` directly
(`a_addr`, `blit_word_addr`, `copy_src_word_addr`, `b_addr`) decomposed
into `(bank, sub_addr)` via `/`/`%`, and every write/read site routed
through an explicit `case` on its own bank-select signal into the
correct bank array - the same pattern, applied to all three real write
categories (CPU byte-lane writes, the line engine, the fill/copy
engine) and both real read ports (Port A, Port B), not just the
single write path the minimal reproduction covered. `INIT_FILE`'s
external contract is preserved via a simulation-only flat staging array
under `` `ifndef SYNTHESIS`` (so synthesis never sees a flat array at all -
one real, narrow behavior change on this already-unused path: INIT_FILE
now only takes effect in simulation, not during real synthesis, since
supporting it there for a banked array would need one file per bank).

One real bug caught before trusting the result: Verilator's own build
(part of `make verify`'s coverage stage) failed with 8
`WIDTHTRUNC` warnings treated as fatal - `/`/`%` against the unsized
`BANK_WORDS` localparam computes a wider result than the 3-bit/12-bit
`bank`/`sub_addr` target, and an implicit assignment-width truncation
there is exactly the kind of silent narrowing Verilator's own lint
exists to catch. Fixed by computing each division/modulo into an
explicit `AW`-bit intermediate wire, then an explicit bit-slice down to
the real width - a deliberate narrowing instead of an implicit one,
which warns about nothing.

**Real verification, in order:**

```
make sim_blit / make sim_video (the module's own two dedicated
testbenches, run directly): BLIT TEST PASSED / VIDEO TEST PASSED

make verify:   EXIT=0 (61/61 real test markers passed, Linux boot
               reached userspace, formal 6/6 proved)
make verify_ooo: EXIT=0 (61/61, same)

yosys -p "read_verilog rtl/soc/wb_framebuffer.v; hierarchy -top
    wb_framebuffer; proc; check -force-detailed-loop-check"
  Checking module wb_framebuffer...
  Found and reported 0 problems.
  End of script. ... time: 1940.17s, ... MEM: 2687.72 MB peak
```

**The real, full, 601-line production file - Bresenham line engine,
fill/copy engine, CTRL/STATUS registers, everything - now passes
yosys's `CHECK` pass cleanly at the real 320x240/19,200-word default
scale.** Not the minimal reproduction module; the actual file this
whole investigation (Updates 1-8) was about. `make verify`/
`make verify_ooo` passing confirms this is not merely "doesn't crash
yosys" - the module's own two dedicated testbenches (`sim_blit`,
`sim_video`, both already part of `verify`'s own target list) prove
fill, copy (including all four directional-overlap quadrants), all nine
Bresenham line variants, and a full 320x240 write-then-scan-out
readback all still behave identically to before the rewrite.

**What this does not establish.** Whether banking also restores real
block-RAM mapping (`MEMORY_LIBMAP` producing `DP16KD` primitives instead
of the flip-flop fallback "Update 1" documented) - attempted via a
fuller `synth_ecp5` techmap pass on the module in isolation, but that
run's own `yosys-abc` stage ran past 10 hours of CPU time (615+ minutes)
and 14+ hours of real wall-clock with no end in sight - dramatically
longer than Round 6's own full-*SoC* `synth_ecp5` precedent (~2 hours
for the equivalent stage), for one isolated peripheral module. Stopped
deliberately rather than let it run indefinitely, since it was an
explicitly optional bonus check, not required for this change's own
success criterion (avoiding the crash, which is already confirmed).
BRAM-mapping efficiency for the banked version remains a real, genuinely
open question - this update establishes the crash is gone, not that the
resulting netlist is an efficient one. A full `nextpnr-ecp5`
place-and-route of the real SoC with this change, at real scale, is
also not attempted here - a real, separate, much more expensive
follow-up, matching Round 6/the underclock work's own standard, worth
doing once (or alongside) confirming BRAM mapping.

## Hardware

*Physical board testing: what has and has not run on a real board.*

Not met: nothing has run against a real monitor yet, and the "Done when" (a monitor shows the colour ramp) is open. What exists is a build that synthesizes and routes, `BOARD=ulx3s85-video`, opt-in because it costs the primary target real timing margin. The CPU's path to the framebuffer itself is covered on hardware by the acceptance test, and nothing more than that.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

Done: the TMDS encoder (`make sim_tmds_encode`), the framebuffer capture (`make sim_video`) and the whole video integration (`make sim_ulx3s_video`, with video instantiated) are in `make verify`. The yosys crash on `wb_framebuffer.v` recorded above affects real synthesis only, not these simulations.
