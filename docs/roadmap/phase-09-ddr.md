# Phase 9 — DDR

**Stage 0 and Stage 1 both have real, partial progress - board files, a
real diagnostic-scale bitstream, and a real simulated DDR3 PHY built up
over twenty-five gated slices (init and calibration, the DQ/DQS data path,
write, read and refresh command sequencers wired into one top level, with
refresh arbitrated against writes and reads in both directions, at most
one transaction ever in flight, every transaction closing its bank, a
memory model that decodes bank, row and column so the address path is
finally checked, CK at the edge-clock rate with two command slots per
`sclk`, a write burst that lands where the DRAM's write latency says, a memory
model that answers a read at the DRAM's own read latency, the same tests run under a
second simulator and in CI, a bounded formal proof of the controller's arbitration, bank
state and refresh gating, place-and-route on the real device with the board's DDR3 pins, a driven,
tested data mask for lane 0, a second byte lane's own hardware proven to calibrate
independently, wired into the real design, and now carrying data: the controller moves
16-bit words with a byte enable per lane) - but
neither is done. Stage 2's own "Done when" bar is met in simulation (Part 2:
a CPU reads and writes DDR3 as data through `rtl/soc/wb_ddr.v`, wired into
`rtl/soc/soc_top.v` behind `DDR3_ENABLE` so every existing build is untouched;
Part 9: it fetches and executes instructions from DDR3, which Part 2 had not
done); Stage 2's Parts 3 to 6, a paged (Sv32) access to DDR3, were an
investigation that Part 11 closed (the test never mapped the UART; the walker, the cache and the DDR3 path were not at fault)
and Part 12 extended to execution out of DDR3 and to page faults through DDR3 tables (which found an in-order-core bug in `mtval`),
and Part 13 to atomics, a read-only page, a PMP-denied frame, alignment, instruction faults and faults delegated to S-mode (which
found a wide-core bug: an AMO, `lr` or `sc` that faulted hung the core),
and Parts 7 and 8 (atomics, the device-tree node) shipped; Part 10 added a UART loader path into
DDR3 and, with it, fixed a bug in `rtl/soc/wb_ddr.v` that every earlier test
had missed (a request made before calibration was dropped and acknowledged
anyway). Stage 3 through Stage 5 remain
entirely a plan, not an account. Nothing past each stage's own "Update"
paragraph below should be read as a completed claim the way the "Stage N:"
entries in every phase above this one are. Stage 0's "Done when" bar (real hardware,
a real measured Fmax on silicon) is wholly unmet. Stage 1's is partly met:
standalone read, write and refresh tests now exist and pass, under Icarus
and (Part 19) under Verilator and in CI, with limits that part names, and
against a data-path model that has not yet been shown
hardware-faithful (see the survey near the end of this phase) - it still
names formal or property checks, done (Part 20) for the controller's control plane and not
for initialisation, calibration or the data path. No ECPIX-5 is attached to this session, and no real DDR3 chip
has seen anything this project has written.
What changed since this phase was first written down as "blocked on a
board, board not chosen" is that a real, evidence-based board candidate
now exists, described below. No hardware has been purchased this
session; every board-specific claim below is either a documented
spec or an external project's own published result, cited as such, not
something confirmed on silicon here.

**The board candidate: ECPIX-5 (LambdaConcept), not yet purchased or
tested.** Lattice ECP5-5G, `LFE5UM5G-45F` or `-85F` - the 85F variant
matches this project's own current ULX3S board's logic capacity exactly,
so existing RTL sizing assumptions carry over. 4 Gb (512 MB) DDR3L
on-board. Confirmed via the FPGA's own real hardware SerDes primitive
(`DCUA`, a 3-5 Gbps dual-channel SerDes unit) being supported by
`nextpnr-ecp5` today, not just the plain logic fabric - so this project's
existing open-source toolchain (`yosys` + `nextpnr-ecp5` + prjtrellis)
stays exactly what it is; no new synthesis toolchain is needed the way a
Xilinx board would require. €151, in stock, not a prototype-only or
crowdfunding-pending board.

**A DDR controller is a bigger design than `rtl/soc/wb_sdram.v`, not a
version of it.** SDR SDRAM's controller is what Phase 2 measured against
board revisions of a mode register and a refresh counter. DDR needs a
calibrated PHY - read/write leveling, delay-locked strobes - which has no
equivalent in this codebase today.

**Two real third-party references were evaluated for the PHY, and
neither was chosen - both are named here because the reasoning matters,
not because either is being adopted.** LiteDRAM (`enjoy-digital/litedram`)
has a real, dedicated ECP5 DDR3 PHY and - stronger than any other
candidate found - ECPIX-5 support has already been added to the
Linux-on-LiteX-VexRiscv ecosystem, meaning Linux has already been booted
against LiteDRAM-driven DDR3 on this exact board, under a different
RISC-V core. It is BSD-2-Clause licensed, compatible with this project's
own Apache 2.0/Solderpad license. UberDDR3 (`AngeloJacobo/UberDDR3`) has
real, silicon-proven ECP5 support too (OrangeCrab 85F, calibration and
BIST passing, through the same open toolchain this project already
uses) and a Wishbone interface matching this project's own convention -
but it is GPL-3.0, which would require the combined work to adopt
GPL-3.0-compatible terms, a real, project-wide licensing decision neither
this section nor a single peripheral addition should make unilaterally.
Both are real, working engineering - LiteDRAM's own generated-RTL
development model (Python/Migen, not hand-written Verilog) is the
reason it was set aside even before the licensing question for UberDDR3
came up: every other line of RTL in this project is hand-written and
understood line-by-line, and adopting a code-generator-produced core
would be a real, different kind of dependency than anything here today.
**The decision: a custom, hand-written DDR3 PHY and controller, in this
project's own established style** - matching every other peripheral in
this tree, at the real cost of starting without either reference
project's own silicon-proven precedent on this exact board. Whether that
PHY ends up built from soft IOSERDES logic (matching UberDDR3's own
demonstrated approach, without adopting its code) or some other shape is
Stage 1's own open question, not decided here.

**Bus integration follows the existing pattern**: a Wishbone slave beside
`wb_sdram.v`, the same way `wb_sdram.v` sits beside `wb_ram.v` - so the
caches and the MMU walkers that already treat "external memory" as an
address range gain the new one without changing. "Improve," once a first
controller exists, most likely means what Phase 3 already flagged and left
open for the caches - spatial locality, more than one word per transfer -
mattering more here than it does against the current SDRAM, because DDR's
burst mode is built for exactly that access pattern.

**Stage 0 - board bring-up, no memory controller yet.** A new
`fpga/ecpix5_top.v` board wrapper and `.lpf` constraints (clocks, LEDs,
UART, JTAG, reset - the same shape `fpga/ulx3s_top.v` and
`fpga/constraints/ulx3s.lpf` already are for the current board), and a
new `BOARD=ecpix5` target in `fpga/synth/synth_ecp5.sh` alongside the
existing `ulx3s85` case, not replacing it. The system clock and any DDR
reference clock get identified and documented from the board's own real
schematic, not guessed at. `docs/practices.md`'s "numbers quoted are
measured, not estimated" applies here exactly as it does to Fmax: no
DDR timing number gets written down before it is measured. **Done when:**
a minimal SoC (boot ROM, UART, on-chip RAM only - no DDR yet) builds,
loads, and prints a boot banner on real ECPIX-5 hardware, with a real
measured Fmax and resource count recorded in `fpga/README.md`'s own
style, and the existing `BOARD=ulx3s85` target still builds identically
to before - this stage adds a board, it does not touch one.

**Update: real progress, real gaps still open - not done, but no
longer just a plan.** `fpga/ecpix5_top.v`, `fpga/ecpix5_clk_pll.v` (a
100→25 MHz PLL, generated with `ecppll` the same way as
`fpga/video_pll.v`/`fpga/underclock_pll.v` - this design's own measured
Fmax is nowhere near the board's real 100 MHz oscillator, so the SoC
cannot run directly off it), `fpga/constraints/ecpix5.lpf`, a new
`BOARD=ecpix5` case in `fpga/synth/synth_ecp5.sh`, and `sim_ecpix5` (a
new board-wrapper testbench, `sim/tb_ecpix5.v`, mirroring
`sim_ulx3s`'s own reason for existing - a board wrapper is RTL no other
target would build - now part of `make verify`) all exist and are real.
`make verify`/`make verify_ooo` both pass (62/62 real test markers,
`sim_ecpix5` among them, non-vacuity confirmed by mutating the reset
polarity and watching 3 checks correctly fail before reverting).

Real synthesis was attempted, not just written. Two real bugs were
found and fixed by actually running it, not by review: `PACKAGE`
silently stayed at the ULX3S default (`CABGA381`) because this script's
own top-level `PACKAGE=${PACKAGE:-CABGA381}` runs before the board
`case` statement does, so the `ecpix5` block's own `${PACKAGE:-...}`
was a no-op - fixed with an unconditional `PACKAGE=CABGA554` there
instead, with the reasoning written down next to it; and the LPF's own
LED port name (`led0_g`) did not match the Verilog port it was meant to
constrain (`led2_g`) - nextpnr caught both immediately and by name, not
silently.

At the real 320x240 framebuffer scale, the actual `synth_ecp5.sh` run
was killed (`SIGKILL`) during ABC9 technology mapping after several
hours, on this exact 8 GB development machine - the same real memory
constraint this file's own "`wb_framebuffer.v` crashes yosys" entry
documents elsewhere, not a defect in this board's own files. Retried at
the diagnostic `FB_WIDTH=8 FB_HEIGHT=8` scale that entry's own Update 9
already established as a legitimate, permanent way to reach real
synthesis for unrelated work - and at that scale, synthesis, place and
route, and bitstream generation all completed cleanly, first attempt,
no seed retries:

```
Info: Max frequency for clock '$glbnet$soc_clk': 25.91 MHz (PASS at 25.00 MHz)
```

`fpga/build/ecpix5_top.bit` is real. **What this does not establish:**
whether synthesis closes at the real 320x240 scale on a machine with
more headroom than this one - genuinely unknown, not assumed either
way. (Update 2026-10-15: the cause is known and fixed. The framebuffer's pixel memory was written from an asynchronous-reset block, which yosys turns
into 614,400 registers; it is written from a clock-only port now. The ECPIX-5 build at the real 320x240 synthesises in 131 seconds and 741 MB, closes 25 MHz on its second placement seed (25.71 MHz; 82 `DP16KD`, 32,491 `TRELLIS_COMB`) and writes a bitstream. See
[docs/roadmap/index.md](index.md#common-known-defects).) Whether the board actually boots anything - no ECPIX-5 is attached
to this session; the bitstream has never been loaded onto real
hardware, and this stage's own "Done when" bar (a real boot banner, a
real measured Fmax on silicon) stays explicitly unmet on both counts.

**Stage 1 - the custom DDR3 PHY/controller, and a simulation model
trustworthy enough to develop against.** The real design work the
decision above commits to: a hand-written PHY (soft IOSERDES or
otherwise, decided here, not above) and controller, plus a DDR3
behavioral simulation model accurate enough to develop and gate against -
adopting an existing open behavioral model rather than writing one from
scratch is a real, separate option worth checking before assuming this
needs building too. Directed tests exercise init, read, write, and
refresh independently of the CPU, the same "a testbench that can fail"
discipline this project already holds every other peripheral to. The
external memory base address and 512 MB size get decided and written
down here, not assumed from the current SDRAM's own `0x9000_0000`.
**Done when:** the controller and its simulation model pass standalone
read/write/refresh tests under both Icarus and Verilator, with formal or
property checks where the design actually admits them - not asserted,
the same bar every other controller in this tree is held to.

**Update, Part 1: the real init/mode-register sequence and CK/CK#
generation exist and pass a real, fail-capable protocol checker - the
read/write/refresh data path does not exist yet, so this is a real
first slice of Stage 1, not the whole of it.** Two rounds of real
research this round answered Stage 1's own open "soft IOSERDES or
otherwise" question with real, cited technical grounding rather than a
guess: DDR3's own "DLL off" mode (fixing CL=CWL=6, capping the DRAM
clock at 125 MHz - far above what this design runs at) is confirmed,
against two independent real, working ECP5 implementations read for
architecture only, to let read/write leveling be skipped entirely for a
single-rank, point-to-point topology - exactly what ECPIX-5's own
on-board DDR3L chip is. A third real third-party option
(`ultraembedded/core_ddr3_controller`) was found, initially reported as
Apache-2.0 (which would have made it license-compatible, unlike
UberDDR3's GPL-3.0), and checked directly against GitHub's own API
before treating it as real: `license: null`, no code change since 2021,
and its own README already calling its ECP5 PHY "sub-optimal." Not
adopted - and this project's own "build custom" decision stands
confirmed by checking, not just left unchallenged.

Also confirmed, and worth stating plainly: DDR3's command/address bus
is single-data-rate - only `CK`/`CK#` and the DQ/DQS data lines are
truly double-pumped - so Part 1 needs only one DDR primitive
(`ODDRX1F`, for `CK`/`CK#`, mirroring `fpga/sdram_clk_out.v`'s own
real, hardware-confirmed 180-degree-phase reasoning almost exactly) -
`IDDRX1F`/`DELAYG`/DQS capture are real, but belong to the data-path
slice this update does not attempt. This toolchain's own behavioral
simulation model file (`cells_sim.v`) has zero DDR-I/O primitives at
all - confirmed by reading it directly, not assumed - so
`rtl/soc/ddr3_phy_ecp5.v` follows the exact `ifdef SYNTHESIS`/
behavioral-substitute pattern `fpga/sdram_clk_out.v` already
established, rather than inventing a new one.

`rtl/soc/ddr3_init_seq.v` drives the real JEDEC power-up sequence
(reset/CKE timing, MR2 -> MR3 -> MR1 -> MR0 -> ZQCL, the real required
order) against `sim/ddr3_model.v`, a new behavioral protocol checker
(not a memory array - no data path exists yet to model) that
independently verifies the real command order and the real
inter-command minimum waits, rather than trusting the sequence that
generates them. Mutation-tested twice before shipping - a wrong MR2
bank address, and a shortened tMRD wait - each caught by name
(`sim/tb_ddr3_init.v`'s own real assertions), reverted, reconfirmed
clean. `make verify`/`make verify_ooo` both pass (63/63 real test
markers, `sim_ddr3_init` among them).

**What this does not establish, named plainly rather than hidden.**
The exact per-field bit *values* inside MR0-3 (as opposed to the real
command order and timing above) were reasoned field-by-field against
general JEDEC knowledge and cross-checked where possible against
AngeloJacobo/UberDDR3's own real, working values (read for the
bit-field positions and encoding only - no code copied, GPL-3.0 either
way) - but this round could not successfully fetch the primary Micron
datasheet PDF directly (the fetch returned a redirect page, not the
document), so these individual values are not independently confirmed
against the primary source the way this project's own practices
normally require. A real, open verification gap for whoever continues
this - not silently presented as fully authoritative. No real DDR3
chip has ever seen this sequence - only `sim/ddr3_model.v`'s own
protocol checker has - and no ECPIX-5 is attached to this session.

**Update, Part 2: one byte lane's own DQ/DQS data path - real
`DQSBUFM`-based read calibration, and a real write-then-readback round
trip - now exists and passes a new directed test, independent of Part
1's own init sequence.** The user's own explicit choice this round:
`DQSBUFM`-based hardware DQS tracking (LiteDRAM's real, proven
architecture) over the simpler UberDDR3-style fixed-delay/bitslip
scheme Part 1's own update first recommended - checked directly
against LiteDRAM's own real source (`litedram/phy/ecp5ddrphy.py`,
BSD) rather than assumed from `DQSBUFM`'s own 23-port list. Two real
findings made the primitive tractable: `DDRDLLA` is a one-shot,
reset-time-only lock sequence, not a continuous loop; and `DQSBUFM`'s
own hardest feature - the internal `RDMOVE`/`WRMOVE` dynamic
margin-control engine - is real, present in silicon, and simply not
used, matching LiteDRAM's own real, shipping choice. Real calibration
instead happens through a bounded, one-shot sweep of
`READCLKSEL[2:0]`'s 8 discrete tap positions, Lattice's own documented
"READ Pulse Positioning" mechanism (`FPGA-TN-02035`, fetched via a
legitimate community mirror after Lattice's own `.ashx` URL failed the
same way an earlier datasheet fetch had).

A genuine new complexity surfaced mid-design and was put to the user
rather than decided unilaterally: `IDDRX2DQA`/`ODDRX2DQA`/`TSHX2DQA`
need a real 1:2 `SCLK`:`ECLK` clock-domain split, distinct from Part
1's own single-clock-domain command/address design - the user chose to
take this on now rather than narrow scope further.
`rtl/soc/ddr3_eclk_pll.v` generates both from this design's own 25 MHz
`clk` via `EHXPLLL` (25 -> 50 MHz `eclk`, 25 MHz `sclk`,
`ecppll`-generated, no warnings). Its own first simulation-model draft
(`eclk_r ^ clk`, toggled from separate posedge/negedge `always`
blocks) was not trusted on hand-trace alone - a real, standalone
`iverilog`/`vvp` test with `$dumpvars` caught it producing a
degenerate, near-zero-duration glitch rather than a real square wave;
replaced with a plain delay-based generator, independently reverified
the same way before use.

`rtl/soc/ddr3_dqs_ecp5.v` (`DDRDLLA` + `DQSBUFM`, tied off exactly as
LiteDRAM's own real code does) and `rtl/soc/ddr3_dq_serdes_ecp5.v`
(`IDDRX2DQA`/`ODDRX2DQA`/`TSHX2DQA` via `generate`, one byte lane,
`DQ_WIDTH=8`) both follow the same `ifdef SYNTHESIS`/
behavioral-substitute pattern Part 1 established - this toolchain has
zero simulation models for any of these primitives either, confirmed
the same way. `rtl/soc/ddr3_read_calib.v` sweeps all 8 `READCLKSEL`
positions once at boot, checking real captured data against a known
test pattern (not `DATAVALID` alone - a real status bit could
plausibly assert "valid" at a tap that still samples the wrong cycle)
and latching the first tap that actually matches; a real `calib_error`
if every tap fails. `sim/ddr3_dq_model.v` is a new, focused behavioral
DQ/DQS memory (kept separate from `sim/ddr3_model.v`'s own
protocol-only checker, a deliberate choice to keep concerns apart)
modeling DQS as genuinely source-synchronous - idle except while a
real read is active.

`sim/tb_ddr3_data.v` wires all of the above together with a real
tristate bus - both the FPGA's own drive and the memory model's own
drive sharing one `wire` - and a real bus-contention check: `dq_oe`
and the model's own drive enable asserted simultaneously is flagged as
a real error, not assumed impossible. The first real run passed
outright, with the sweep genuinely finding tap 2 (not tap 0, the
default starting position) - real proof the search itself is doing the
work, not a lucky first-try pass. Mutation-tested twice: a corrupted
stored byte correctly fails every one of the 8 taps and asserts
`calib_error`; a forced always-driving memory model correctly trips
the bus-contention check - the second mutation caught a real bug in
the testbench itself first (the contention check originally sampled
the live signal at one instant near the end, long after the one-cycle
write pulse that was the only real contention window, and so missed a
real violation silently; fixed to check a latched `contention_seen`
register instead, then reconfirmed both mutations catch and the clean
case still passes). `make verify`/`make verify_ooo` both pass
(`sim_ddr3_data` among them; formal 6/6 proved, riscv-tests 82
passed/0 failed/2 xfail, co-simulation vs Spike 84/84, Linux boot
reached userspace - no regression on any existing path).

**What this does not establish.** The full 16-bit DQ bus - one byte
lane only, matching this slice's own explicit scope. `DQSBUFM`'s own
`RDMOVE`/`WRMOVE` engine - deliberately unused, not a gap. Real
hardware bring-up - no ECPIX-5 is attached to this session, and the
simulation models for `DDRDLLA`/`DQSBUFM`/`IDDRX2DQA`/`ODDRX2DQA`/
`TSHX2DQA` are honest functional approximations, not phase-accurate -
real silicon could behave differently at the actual `READCLKSEL` tap
boundaries this sweep depends on. Part 2's own new `sclk`/`eclk`
clock-domain pair is not yet reconciled with Part 1's own single-`clk`
`ddr3_phy_ecp5.v` design - real, deliberate later work, not assumed
compatible here.

**Update, Part 3: Parts 1 and 2 now run together, on one real, shared,
PLL-derived clock tree, for the first time.** A new
`rtl/soc/ddr3_ecp5_top.v` instantiates `ddr3_eclk_pll.v` once and
drives every downstream module from its outputs - `ddr3_init_seq.v`
and `ddr3_phy_ecp5.v` (Part 1) now run on `sclk`, not an independent
`clk`, and `ddr3_dqs_ecp5.v`/`ddr3_dq_serdes_ecp5.v` (Part 2) keep
their own `eclk`/`sclk` pair from the same PLL - closing the gap named
above. Two real internal resets are gated correctly, not asserted:
`rst_all` stays high until `pll_locked`, so `ddr3_phy_ecp5.v` cannot
start toggling `CK`/`CK#` off a not-yet-locked clock; `ddr3_read_calib.v`'s
own reset stays high until `init_ready`, so this byte lane's read
calibration does not begin before the JEDEC power-up sequence itself
has reported ready.

A new `sim/tb_ddr3_top.v` wires `ddr3_ecp5_top.v` against BOTH
existing sim models at once, for the first time - `sim/ddr3_model.v`
(Part 1's own protocol checker) on the command/address pins and
`sim/ddr3_dq_model.v` (Part 2's own byte-lane memory) on the data
pins - rather than each part continuing to prove itself only in
isolation. The first real run found a real bug: the same
`model_seq_done`-lags-`ready`-by-a-few-cycles timing gap
`sim/tb_ddr3_init.v`'s own fix already found for Part 1 reproduced
here, sampled at the wrong instant; fixed the same way, with a real
settle delay before the check. Mutation-tested three ways, not two -
the third specific to what this integration adds over Parts 1 and 2
each proven alone: a wrong bank-address wire inside
`ddr3_ecp5_top.v` itself (`cmd_ba` tied to a constant instead of
`ddr3_init_seq.v`'s own output) is correctly caught by
`sim/ddr3_model.v`'s own real protocol check, proving this file's own
port-to-port wiring is load-bearing, not just individually-correct
submodules pasted together. The other two mutations (a corrupted
stored byte, a forced always-driving memory model) reproduce Part 2's
own two checks end-to-end through the new integration's real tristate
arbitration on `ddr3_dq`, not through a testbench-internal `wire` as
Part 2's own narrower test used. `make verify`/`make verify_ooo` both
pass, `sim_ddr3_top` among them, no regression on any existing path.

**What this does not establish, worth stating precisely.** Two
mutations this round could not have been meaningfully caught by
simulation at all, and are named here rather than skipped quietly: a
mutation removing the `pll_locked` reset gate, and one swapping
`ddr3_phy_ecp5.v`'s own clock from `sclk` back to raw `clk` (the exact
bug this Part exists to fix) - neither produces an observable failure
in this behavioral simulation, because `ddr3_eclk_pll.v`'s own
simulation model does not model real PLL lock delay or real
`sclk`-vs-`clk` phase difference at all (`assign sclk = clk;` in its
own simulation body - see that file's own header). The real benefit of
this Part - genuine phase alignment between `sclk` and `eclk` on real
silicon - is therefore asserted from datasheet/architecture reasoning,
the same way it was in Part 2's own account, not demonstrated by a
test that could fail. `ddr3_dqs` stays `input`-only, not `inout` -
`ddr3_dq_serdes_ecp5.v` still has no DQS write-drive primitive
(`ODDRX2DQSB`/`TSHX2DQSA`-for-DQS), so even though DQ's own
`ODDRX2DQA`/`TSHX2DQA` can drive out, no real write to real silicon
could work yet without a real strobe alongside it. `ddr3_read_calib.v`
still does not issue real ACT/WR/RD commands through
`ddr3_phy_ecp5.v` - gating its own reset on `init_ready` is real,
correct sequencing, but does not by itself turn its own
direct-signal-injection calibration scheme into a real command-level
read/write path; that, the second DQ byte lane, and real hardware
bring-up (no ECPIX-5 is attached to this session) remain later,
separate work.

**Update, Part 4: a real DQS write-drive primitive now exists,
standalone and proven - closing one specific half of the gap named
above.** A new `rtl/soc/ddr3_dqs_write_ecp5.v` wraps `ODDRX2DQSB` +
`TSHX2DQSA`, generating a real, fixed-shape burst-length-8 write
waveform on a single `write_start` pulse: one real `sclk` cycle of
low-with-OE-asserted preamble, two active toggle cycles (4 UI each,
matching `ODDRX2DQSB`'s own real 4-bit-wide `D3:D0` port and this
design's own already-established 4:1 `SCLK`:UI ratio), one real
low-with-OE-asserted postamble cycle - four `sclk` cycles of real
output-enable window in total, framed by real low guard bands on both
sides. The preamble/postamble length (a full `sclk` cycle each) is
reasoned as a conservative margin above JEDEC's own documented
minimums (tWPRE/tWPST, roughly 0.35-0.6 tCK depending on speed grade),
not independently checked against the primary Micron datasheet - the
same open verification gap `rtl/soc/ddr3_init_seq.v`'s own MR
field values already carry, named plainly again here rather than
implied resolved.

Proven standalone first, the same "narrow proof first" discipline
Part 2's own byte-lane read-calibration test used before Part 3
integrated it - `sim/tb_ddr3_dqs_write.v` is not yet wired into
`rtl/soc/ddr3_ecp5_top.v`. The first real run found a real bug, in
this file's own simulation substitute rather than the synthesis
logic: the sim-only DQS output was a registered, one-cycle-delayed
view of the active window, while the output-enable signal stayed
purely combinational - two different latencies for supposedly
synchronized signals, so DQS visibly stayed high for one extra cycle
after OE had already dropped. Not a hand-traced worry, either - caught
by the testbench's own real, recorded cycle-by-cycle history, the same
"verify by running it, not by reading it" practice
`rtl/soc/ddr3_eclk_pll.v`'s own first draft already needed. Fixed by
making the DQS output combinational too, matching `oe`'s own timing
exactly (`ODDRX2DQSB`/`TSHX2DQSA` both take their real inputs
combinationally at the same cadence in the real synthesis path, so
this fix also makes the simulation substitute more honestly
consistent with the real primitives, not just internally self-
consistent).

Mutation-tested three ways: a broken preamble (driven high instead of
low), a broken postamble (same), and a shortened output-enable window
(skipping the postamble state entirely, collapsing the real four-cycle
window to three) - all three caught by the test's own real recorded
history, reverted, clean case reconfirmed passing. `make verify`/
`make verify_ooo` both pass, `sim_ddr3_dqs_write` among them, no
regression on any existing path.

**What this does not establish.** `ddr3_ecp5_top.v` still exposes
`ddr3_dqs` as `input`-only - this module is not wired into it yet, so
the integration-level "real write to real silicon" claim stays exactly
as unmet as Part 3 left it. No memory model in this tree samples DQ on
real DQS edges yet - `sim/ddr3_dq_model.v` still trusts a direct
`wr_en` signal, not a real strobe, so this Part proves the DQS
waveform shape is correct, not that a real DRAM would actually latch
the right data from it. `ddr3_read_calib.v` still does not issue real
ACT/WR/RD commands through `ddr3_phy_ecp5.v`. The second DQ byte lane
and real hardware bring-up remain later, separate work, unchanged from
Part 3's own account.

**Update, Part 5: the DQS write-drive primitive is wired into
`ddr3_ecp5_top.v` - `ddr3_dqs` is genuinely `inout` now, not
`input`-only.** `write_start` is driven directly from
`ddr3_read_calib.v`'s own `wr_en` pulse - the same single-cycle signal
that already marks a write on the DQ side, reused rather than
duplicated. `sim/tb_ddr3_top.v` proves two things: the wiring is real
(`dqs_wr_oe` genuinely fires when a write happens, not dead code), and
the now-shared `ddr3_dqs` pin is never driven from both sides at once.

Getting the second check right took two real rounds of fixing the test
itself, not the design - worth recording plainly. A first version
tapped each side's own internal output-enable signal
(`DUT.dqs_wr_oe`/`mem_dq_oe`) and flagged both asserting together; a
mutation that broke the tristate assignment itself (driving the pin
unconditionally, bypassing the enable signal entirely) left that
internal signal's own value untouched, so the check kept passing while
a standalone probe showed the real `ddr3_dqs` net actually resolving
to `x` for 10 real cycles - genuine electrical contention the check
had no way to see, because it was watching the wrong thing. Fixed to
check the resolved pin value directly. That fix then surfaced a second
bug, in the fix itself: a first pass used a reduction-XOR
(`^ddr3_dq === 1'bx`) as a one-line "any bit contended" test, but
Verilog's own 4-state XOR table resolves to `x` whenever any operand
is `z` - so a cleanly floating, entirely undriven bus (confirmed
directly via a standalone probe showing `ddr3_dq === 8'bzzzzzzzz` at
the exact instant this reduction reported `x`) was misreported as
contended. Fixed to a real per-bit `x` check instead. Both fixes were
verified the same way the bugs were found - a standalone probe
observing the actual signal, not a hand-trace.

Mutation-tested four ways: `write_start` tied permanently low (the new
wiring goes dead - caught), the DQS tristate assignment removed
(genuine contention with the memory model's own read-side drive -
caught, and only caught after the fix above), the DQ tristate
assignment removed with the FPGA's own output left unmodified (not
caught - see below), and the DQ tristate assignment removed with the
FPGA's own output additionally inverted (genuine contention forced by
construction - caught, confirming the check mechanism itself is sound
for the cases it can see). `make verify`/`make verify_ooo` both pass,
no regression on any existing path (`sim_ddr3_top` itself has no new
Makefile target - Part 5 changes what it already gates).

**What this does not establish, including one real, unfixable-in-
simulation gap found this round.** The third mutation above - removing
the DQ tristate but leaving the FPGA's own output value unchanged -
was not caught, and cannot be, by any check built on 4-state `x`
detection: this design's own read-calibration test writes a fixed
pattern and reads it straight back, so both the FPGA's own (buggy,
always-driving) output and the memory model's own read-side output
happen to present the *same* value whenever they overlap, and Verilog
only resolves disagreeing drivers to `x` - two drivers that agree
resolve cleanly, indistinguishable in a digital simulator from a
single driver, even though real silicon could still suffer a genuine
electrical conflict from two active push-pull drivers fighting in
agreement. Proving that class of bug needs drive-strength-aware
modeling, out of scope here - named honestly rather than closed by a
check that only looks correct. Everything else Part 4's own account
named still applies unchanged: no memory model samples DQ on real DQS
edges, `ddr3_read_calib.v` still does not issue real ACT/WR/RD
commands, the second DQ byte lane and real hardware bring-up remain
later work.

**Update, Part 6: a real command-level write sequencer now exists,
standalone and proven - the first time any real ACT/WR command has
ever been issued through `rtl/soc/ddr3_phy_ecp5.v` in this stage.**
A new `rtl/soc/ddr3_write_seq.v` accepts one write request (bank, row,
column) and issues a real ACTIVATE, waits a real tRCD, issues a real
WRITE (forcing A10 low - no auto-precharge), waits the real CAS Write
Latency, then pulses `write_start` - the same single-cycle,
`wr_en`-shaped signal `rtl/soc/ddr3_read_calib.v`'s own direct-
injection scheme already produces, meant to eventually replace it.
CWL=6 is not re-derived - it is the exact real value
`rtl/soc/ddr3_init_seq.v`'s own MR2 already commits this design to
under DLL-off, reused directly.

Proven standalone first (`sim/tb_ddr3_write_seq.v`), the same "narrow
proof first" discipline Part 4's own DQS write-drive test used before
Part 5 integrated it - not yet wired into `rtl/soc/ddr3_ecp5_top.v`,
and no read-side equivalent (`ddr3_read_seq.v`, issuing ACT+RD with
tRCD/CL timing) exists yet either.

The real ACT-to-WR gap this FSM produces measured 3 cycles, not the 2
its own `TRCD_CYC` localparam name would suggest - `S_ACT` itself
occupies one real cycle before `S_TRCD_WAIT`'s own cycles even begin,
an off-by-one caught only by measuring the real testbench output, not
by trusting the header's own hand-derived arithmetic. Not a
correctness bug (3 cycles of real margin at this design's own 25 MHz
only exceeds any real DDR3 tRCD requirement further) - the header
comment was corrected to state the real measured value rather than
leave the imprecise name standing uncorrected.

Mutation-tested four ways, and one of the four exposed a real gap in
the test itself, not the design: a first mutation removing the CWL
wait entirely (`write_start` pulsing immediately after WR instead of
six real cycles later) passed clean, because the test's own checks up
to that point only verified *ordering* ("`write_start` happened after
WR"), never the *exact* real cycle gap. Fixed by adding dedicated
gap-value assertions matching the real, measured values above -
re-tested, and this mutation (along with the other three - a
mutation leaving A10 uncleared, one aliasing the WR encoding to ACT's
own, and the CWL-skip above) are now all correctly caught. `make
verify`/`make verify_ooo` both pass, `sim_ddr3_write_seq` among them,
no regression on any existing path.

**What this does not establish.** This module is not wired into
`rtl/soc/ddr3_ecp5_top.v` yet, and no symmetric read-side sequencer
exists - the "real command-level read/write sequencer" gap every
part since Part 3 has named stays open in the direction that matters
most for actually reading data back. This sequencer also does not
track which banks are already open (a real controller would skip a
redundant ACT) or issue PRECHARGE to close one down again - both
later, separate work, matching this design's own already-established
"one real, gateable slice at a time" discipline rather than an
oversight. The exact tRCD/CWL cycle counts remain reasoned margins,
not independently checked against the primary Micron datasheet - the
same open gap `rtl/soc/ddr3_init_seq.v`'s own MR field values and
`rtl/soc/ddr3_dqs_write_ecp5.v`'s own preamble/postamble margins
already carry.

**Update, Part 7: a symmetric read-side command sequencer now exists,
standalone and proven - the same real ACT+command+wait shape as
Part 6's own write sequencer, applied to READ.** A new
`rtl/soc/ddr3_read_seq.v` issues a real ACTIVATE, waits a real tRCD,
issues a real READ (forcing A10 low - no auto-precharge), waits the
real CAS Latency (CL), then pulses `read_start`. CL=6 is not
re-derived - it is the exact real value `rtl/soc/ddr3_init_seq.v`'s
own MR0 already commits this design to under DLL-off, reused
directly. Named as its own constant (`CL_CYC`), not shared with
`ddr3_write_seq.v`'s own `CWL_CYC` even though both currently equal 6
- a real DDR3 part can run CL and CWL at different values in general,
and this design's own current equality is a property of its own MR
encoding, not a fact worth baking into a shared name.

Proven standalone first, matching Part 6's own precedent - not yet
wired into `rtl/soc/ddr3_ecp5_top.v`, and its own `read_start` output
(a single-cycle pulse, matching `write_start`'s own shape) is
explicitly **not** the same signal as `rtl/soc/ddr3_dqs_ecp5.v`'s own
`read_active` input, which needs to stay high for the whole real
capture window, not pulse once - reconciling the two remains real,
later, separate work, named here rather than assumed already
compatible.

The real measured timing came out identical to the write sequencer's
own, cycle for cycle - ACT-to-RD measured 3 cycles (matching Part 6's
own real, measured ACT-to-WR gap exactly, for the same reason: `S_ACT`
occupies one real cycle before the wait state's own cycles begin), and
RD-to-`read_start` measured 6 cycles, exactly `CL_CYC`. Mutation-tested
three ways - A10 left uncleared, RD's own encoding aliased to ACT's,
and the CL wait skipped entirely - all three caught immediately by the
exact-gap assertions Part 6's own mutation round already established
as necessary (an ordering-only check would have missed the CL-skip
case the same way Part 6's own first attempt did; this file's own test
started with the exact-gap check already in place, so it did not need
to be re-discovered here). `make verify`/`make verify_ooo` both pass,
`sim_ddr3_read_seq` among them, no regression on any existing path.

**What this does not establish.** Neither sequencer is wired into
`rtl/soc/ddr3_ecp5_top.v` yet, and the real reconciliation between a
single-cycle `read_start`/`write_start` pulse and
`rtl/soc/ddr3_dqs_ecp5.v`'s own level-held `read_active` input has not
been attempted - that is real, necessary design work before either
sequencer can actually drive a real capture or drive window, not a
detail to paper over when integration happens. Bank-state tracking,
PRECHARGE, and real hardware bring-up remain later work, unchanged
from Part 6's own account.

**Update, Part 8: the `read_start`/`read_active` shape mismatch Part 7
named is closed, standalone, by a small, real extender module.** A new
`rtl/soc/ddr3_read_burst_ext.v` converts `ddr3_read_seq.v`'s own
single-cycle `read_start` pulse into a real, held-high `read_active`
signal spanning this design's own real burst-length-8 duration - 2
real `sclk` cycles, matching the 8 UI / 4:1 `SCLK`:UI ratio
`rtl/soc/ddr3_dq_serdes_ecp5.v`'s own header already establishes. The
write side needs no equivalent: `rtl/soc/ddr3_dqs_write_ecp5.v` already
takes `write_start` as a single-cycle pulse directly and handles its
own real multi-cycle preamble/active/postamble timing internally -
only the read side's own `read_active` input had this real shape
mismatch.

The first real run found a real bug - in this test's own stimulus, not
the design. A first draft drove `read_start` with a plain blocking
assignment right after `@(posedge clk)`, the well-known same-edge race
against the DUT's own NBA-clocked internal register - confirmed
directly via a standalone probe with a settle delay after the clock
edge, which showed `read_start` and the DUT's own internal delay
register reading as 1 on the *same* cycle, collapsing the intended
2-cycle window to 1. Not a real DUT defect: a real caller
(`ddr3_read_seq.v`'s own `read_start <= 1'b1;`) already drives this
signal with non-blocking assignment, so the race could not occur in
real integration - only in a testbench careless enough to drive a
synchronous stimulus signal with blocking assignment. Fixed by driving
`read_start` with non-blocking assignment too, and by recording the
real cycle history with a separate, continuously-running monitor
rather than an inline sample interleaved with the stimulus's own
sequencing (the same robust pattern `sim/tb_ddr3_dqs_write.v`'s own
history recorder already uses) - re-run, and the real, intended
2-cycle contiguous window appeared exactly as designed.

Mutation-tested two ways: removing the extension entirely (`read_active
= read_start`) and making the internal delay register never clear
(stuck high after the first pulse) - both caught, reverted, clean case
reconfirmed. `make verify`/`make verify_ooo` both pass,
`sim_ddr3_read_burst_ext` among them, no regression on any existing
path.

**What this does not establish.** This module is not wired into
`rtl/soc/ddr3_ecp5_top.v` yet - integrating both command sequencers
into that top-level module, alongside `rtl/soc/ddr3_read_calib.v`'s
own existing direct-injection calibration path (not replacing it -
calibration still needs its own simple mechanism to find a working
`READCLKSEL` tap before any command-driven read/write can be trusted),
remains later, separate work. Bank-state tracking, PRECHARGE, and real
hardware bring-up remain open too, unchanged from Part 7's own account.

**Update, Part 9: the first real, command-driven write-then-read round
trip through `rtl/soc/ddr3_ecp5_top.v` - a real ACT+WR followed by a
real ACT+RD, not `rtl/soc/ddr3_read_calib.v`'s own direct-signal-
injection scheme.** Both command sequencers (Parts 6/7) and the
read-burst extender (Part 8) are wired in now. Calibration is kept, not
replaced - it still runs first, gated on `init_ready` alone, and both
command sequencers are held in reset until `calib_done` too: a real,
deliberate safety property, since issuing a real read/write before a
working `READCLKSEL` tap is known would sample data at an unproven,
possibly-wrong point.

Four real muxes make this work, each mutually exclusive by
construction rather than an added arbitration state machine (the init
sequence only ever asserts a command before `ready`; the two command
sequencers only ever start after `calib_done`, which cannot happen
before `init_ready`; calibration's own write/read triggers only ever
fire before `calib_done`): the command/address bus into
`ddr3_phy_ecp5.v`, the DQS write-drive's own trigger, the DQ write
data, and `ddr3_dqs_ecp5.v`'s own `read_active` input. A new
`write_data_latch` register captures the top-level `write_data` input
at real request time, matching how `ddr3_write_seq.v`'s own
`bank`/`row`/`col` inputs are already captured - neither command
sequencer carries its own data path.

Two real bugs were found this round, both by tracing a real, observed
cycle-by-cycle probe rather than a hand-derived timing diagram - the
same discipline this whole investigation has needed repeatedly.
First: `sim/ddr3_model.v`, scoped to Part 1's own init-sequence-only
job, unconditionally failed on any command issued after the init
sequence completed - a real, now-stale check, since Part 9 makes real
post-init ACT/WR/RD traffic a legitimate scenario for the first time.
Fixed by decoding those three commands with the same
`{ras_n,cas_n,we_n}` convention the real RTL itself uses and accepting
them in that state, while still flagging anything else (a stray
MRS/ZQCL/PRECHARGE) as the real protocol violation it would be.

Second, and harder to find: `read_data_valid` was first gated directly
on `datavalid && real_read_active` (both combinational, zero-lag) -
but `rd_q0` is itself a registered capture of `dq_i`
(`rtl/soc/ddr3_dq_serdes_ecp5.v`'s own simulation body), one real cycle
behind `dq_i` becoming valid, which is itself one cycle behind
`mem_dq_oe`/`real_read_active` first asserting. A first attempted fix
(registering the gate by one cycle) produced a real, observed 2-cycle-
wide pulse whose *first* cycle still sampled stale `z` data - caught
only by re-running the same probe, not assumed fixed. The real, correct
fix: `read_data_valid` is a genuine single-cycle pulse on
`real_read_active`'s own falling edge (exactly the cycle `rd_q0` first
reflects settled data), gated on whether `datavalid` was ever asserted
at any point during the window that just closed.

Mutation-tested three ways, each specific to this round's own new
wiring, not a repeat of earlier parts' own mutations: the write-data
latch never capturing (real read-back returns 0, not the written
value), `real_read_active` removed from the `read_active` mux (the
real read never activates, `read_data_valid` never pulses), and
`wseq_write_start` removed from the write-trigger mux (the real
write never fires, and the read-back returns calibration's own stale
`0xA5` test pattern instead - a legible, specific failure, not just
"wrong"). All three caught, reverted, clean case reconfirmed. `make
verify`/`make verify_ooo` both pass, `sim_ddr3_cmd_seq` among them, no
regression on any existing path (including `sim_ddr3_top`, whose own
DUT gained new ports tied off to keep exercising Parts 3-5's own
calibration-only scenario unchanged).

**What this does not establish.** `sim/ddr3_dq_model.v` is still the
same single-stored-location model every part through Part 8 already
used - it does not address-decode `write_bank`/`write_row`/`write_col`
at all, so this proves the real command *timing and wiring*, not a
real multi-location memory array; a real memory model is later,
separate work. Bank-state tracking (no redundant-ACT avoidance),
PRECHARGE, the second DQ byte lane, and real hardware bring-up remain
open too.

**Update, Part 10: a real refresh scheduler now exists, standalone and
proven - the first real REFRESH command issued anywhere in this stage,
closing a gap this Stage's own "Done when" bar has named since Part 1
("standalone read/write/refresh tests").** A new
`rtl/soc/ddr3_refresh_ctrl.v` requests a refresh once every real tREFI
interval, holds the request pending (not dropped) until an external
caller grants it - a real controller must not interrupt an in-flight
ACT/WR/RD sequence to refresh mid-transaction - then issues a real
REFRESH command and holds `busy` for the real tRFC wait.

**The first primary-datasheet-verified DDR3 timing value in this whole
investigation, not another reasoned-margin caveat.** Every earlier
timing constant in this stage (MR field encodings, tRCD, CWL/CL, DQS
preamble/postamble) carried an honest "not checked against the primary
datasheet" caveat, because every previous attempt to fetch one had
failed (a redirect page, a corrupted PDF). This round's own fetch
succeeded: Micron's own real `MT41K256M16` datasheet (32 Meg x 16 x 8
banks = 4Gb - identified by a real, targeted web search as the chip
ECPIX-5's own "4Gb (512MB) DDR3L" spec likely uses, though that
specific board-to-chip identification came from search results, not a
directly-viewed schematic, and is named as such) gives two real
numbers directly from its own timing table, extracted via `pdftotext`
after `poppler-utils` was installed specifically to read it, not
estimated: tREFI = 7.8125us (`64ms/8192`, density-independent - holds
regardless of whether the exact chip identification above is right),
and tRFC(min) = 260ns for the 4Gb density this specific chip is - cross-
checked against a second, real manufacturer datasheet (Zentel's own
2Gb DDR3L part, tRFC(min) = 160ns) confirming the real pattern (larger
density, longer tRFC), not a one-off number. Even if ECPIX-5's own real
chip turns out smaller than 4Gb, using the larger part's own 260ns
figure only ever waits longer than a smaller chip's real minimum
requires, never less. `T_REFI` (195 cycles at 25 MHz) reuses
`rtl/soc/wb_sdram.v`'s own exact real formula (`CLK_HZ / 128000`) -
1/128000 = 7.8125us exactly, an algebraically exact conversion, not an
approximation, consistent with this project's own existing SDR SDRAM
controller. `T_RFC` (7 cycles = 280ns real margin, comfortably >= the
real 260ns minimum) reuses `rtl/soc/ddr3_init_seq.v`'s own `NS2CYC`
ceiling-rounding macro.

Proven standalone first, matching this stage's own established
discipline - not yet wired into `rtl/soc/ddr3_ecp5_top.v`. The real
measured tREFI (195 cycles) and tRFC (7 cycles) both matched the
primary-datasheet-verified values exactly on the first real run - the
two check failures that first run actually produced were both in this
test's own measurement methodology, not the design, and are worth
naming honestly rather than silently smoothing over: a grant-to-command
latency measured as 2 real cycles where the test's own first draft
assumed 1 (a real, standalone `iverilog` probe confirmed this is
because the stimulus's own non-blocking `refresh_grant <= 1'b1;`
assignment itself costs one real cycle before the DUT can even see it,
on top of the DUT's own one real cycle to register the command); and a
second real tREFI interval measured as 194 cycles, not 195, traced via
the same probe to a real, consistent one-cycle offset in exactly where
this test's own second measurement started counting from (`busy`'s own
drop is a registered, one-cycle-delayed reflection of the internal
counter's own reload, so measuring "from busy dropping" starts one
real cycle after the counter had already begun counting) - the raw
probe confirmed the internal counter itself reloads to the identical
value and counts down identically both times, not a design defect.
Mutation-tested three ways: a wrong REFRESH encoding (aliased to MRS),
`refresh_grant` ignored entirely, and the tRFC wait skipped outright -
all three caught, reverted, clean case reconfirmed. `make verify`/
`make verify_ooo` both pass, `sim_ddr3_refresh_ctrl` among them, no
regression on any existing path.

**What this does not establish.** This module is not wired into
`rtl/soc/ddr3_ecp5_top.v` yet - real arbitration (granting a refresh
only when neither `ddr3_write_seq.v` nor `ddr3_read_seq.v` has an
in-flight transaction) is real, necessary integration work, not
attempted here. Stage 1's own "Done when" bar also still names
Verilator (every test in this stage has only ever run under Icarus)
and "formal or property checks where the design admits them" (not
attempted anywhere in this stage) - both real, open gaps, named
plainly rather than implied closed by this update.

**Update, Part 11: Part 10's own refresh scheduler is now wired into
`rtl/soc/ddr3_ecp5_top.v`, with one real arbitration direction actually
built.** `refresh_grant = !write_busy && !read_busy` - refresh waits
for an in-flight write or read to finish before it is ever allowed to
issue its own command - and the top-level command mux (already
priority-ordered SEQ > WSEQ > RSEQ since Part 9) grew a fourth input,
REFRESH, lowest priority of the four. Named honestly, not implied
symmetric: the reverse direction - a new `write_req`/`read_req`
arriving while `refresh_busy` is itself asserted, mid-tRFC - is real,
deliberately unbuilt; nothing yet stops it, and this update does not
claim otherwise.

Getting a test that actually proves this arbitration, rather than
merely exercising it, took three real rounds of debugging, each
worth recording plainly rather than smoothing into "it passed."
First, `sim/ddr3_model.v`'s own post-init acceptance check - extended
in Part 9 for ACT/WR/RD - had never seen a real REFRESH command
before and flagged the first one as a protocol violation; fixed by
adding the same `is_ref` decode (JEDEC's own `3'b001` encoding) and
extending the check, the same class of gap Part 9's own extension
left for exactly this reason. Second, and the deepest finding of this
round: an early version of the test ran a long, free-running write
stream and simply hoped a refresh would become due while some write
was still in flight - it did, confirmed by a probe, and a mutation
deleting `refresh_grant`'s own gate entirely (forcing it to a constant
1) still passed clean, because two fully deterministic schedules (a
fixed write stream, a fixed 195-cycle tREFI interval) not colliding by
chance proves nothing about whether real protection exists. Reacting
to `refresh_req` instead (wait for it, then issue a write) was tried
next and was also wrong - a probe showed a *working* grant issues the
real command and moves on within the same cycle `refresh_req` first
appears, before a reactive write could possibly land, meaning that
design could never collide with a working grant in the first place.
The fix that held: anticipate the known, deterministic 195-cycle
deadline directly, timing a write to still be genuinely in flight when
it arrives. Third, the resulting contention check itself first watched
the muxed `phy_cmd_valid` output - the pins a real caller actually
sees - and still missed the same forced-`1` mutation, because the
mux's own fixed priority order lets an in-flight write's command
silently win that cycle even though `ddr3_refresh_ctrl.v` itself
believes its own command was issued and moves on to its own
`S_RFC_WAIT` state regardless; fixed by checking the raw, pre-mux
`refresh_cmd_valid` directly, the only place that real hazard is
actually visible.

Mutated two ways after the test itself was fixed, each specific to
this round's own new wiring: `refresh_grant` forced to a constant `1`
(now correctly caught, both via the raw-signal contention check and
via the muxed command losing the REFRESH encoding for that cycle) and
`refresh_cmd_valid` dropped from the top-level mux entirely (also
correctly caught). Both reverted, clean case reconfirmed byte-
identical against the pre-mutation file.

A fourth real bug, this one in the build, not the design or the test:
the full `make verify` run this update ships with caught it, which is
exactly what running the full gate (not just the new target) before
shipping is for. `rtl/soc/ddr3_ecp5_top.v` now instantiates
`ddr3_refresh_ctrl` unconditionally, but two pre-existing compile
rules that already built `ddr3_ecp5_top.v` - `sim_ddr3_top` (Parts
3-5) and `sim_ddr3_cmd_seq` (Part 9) - had never been told about the
new file, since only the new `sim_ddr3_refresh_wire` target's own rule
had been updated to list it. Both failed elaboration outright
("Unknown module type: ddr3_refresh_ctrl"), not a subtler mismatch;
fixed by adding `rtl/soc/ddr3_refresh_ctrl.v` to both rules' own file
lists, matching how the same file already appears in `sim_ddr3_refresh_wire`'s.
`make verify`/`make verify_ooo` both pass, `sim_ddr3_refresh_wire`
among them, no regression on any of the four existing DDR3 tests.

**What this does not establish.** The reverse arbitration direction -
a new write/read request starting while refresh is itself mid-tRFC -
remains real, deliberately unbuilt, named in both
`rtl/soc/ddr3_ecp5_top.v`'s own header and this new test's own header,
not exercised here because there is nothing yet to observe protecting
against it. Stage 1's own "Done when" bar still names Verilator (every
test in this stage, including this one, has only ever run under
Icarus) and "formal or property checks where the design admits them"
(not attempted anywhere in this stage) - both still open, named
plainly rather than implied closed.

**Update, Part 12: the reverse arbitration direction Part 11 left
unbuilt now exists - a new write or read request is held off while a
refresh is pending or running - and the "gate it or queue it" decision
Part 11 named turned out to have a third answer that needs neither.**
The requirement is now primary-source, not reasoned: Micron's own
`MT41K256M16` datasheet (Figure 40, note 5) says "Only NOP and DES
commands are allowed after a REFRESH command and until tRFC (MIN) is
satisfied." Part 11's account named this as unenforced; this closes it.

Part 11's header named the dilemma plainly: gating `write_req`/`read_req`
risks a caller's own one-cycle pulse being silently missed if it lands in
the window, and queuing needs storage and a replay path. What Part 12
does instead is make the caller-visible `write_busy`/`read_busy` rise one
cycle *before* the gate at the sequencers closes. `refresh_hold`
(`refresh_req | refresh_busy`, contiguous because `refresh_req` falls in
the exact cycle `refresh_busy` rises) feeds the caller-visible busy
directly and feeds the request gate through a register, `refresh_hold_d`.
A registered caller decides in one cycle and presents in the next, so it
can only be ignored if the hold was already high when it decided - in
which case it saw `busy` and never presented. Not dropped, not queued. A
caller that ignores `busy` entirely is simply ignored while the gate is
closed, the ordinary ready/valid contract. `refresh_grant` gained one
term, `refresh_hold_d`, so the gate is already closed in the cycle grant
is given; without it a request accepted in the very cycle `refresh_req`
first appears starts a transaction in the same cycle refresh commits, and
the same term keeps the sequencers' own `busy` (not the caller-visible
one, which refresh itself raises and would deadlock against) as grant's
input. `write_data_latch` had to move to the same gated accept condition
the sequencer uses - it read the caller-visible `write_busy`, which would
now leave it holding stale data for a request accepted in that first
boundary cycle. Real API change, named as one: `write_busy`/`read_busy`
at the top level now mean "a transaction is running *or* a refresh has
the bus", not just the sequencer's own state.

**How it was tested, and what was measured rather than assumed.** The
refresh interval is deterministic - the next refresh becomes due 194
cycles after `refresh_busy` falls, measured before the test was written,
not read off the RTL - so `sim/tb_ddr3_reverse_arb.v` anchors each round
on that fall and presents one request `k` cycles later, for every `k`
from 176 to 216, in four modes: a *polite* caller (registered, respects
`busy`) and a *blind* one (ignores it), each for writes and for reads.
This is a sweep rather than a chosen collision because of Part 11's own
finding: a single deterministic alignment, or a hoped-for one, cannot
tell working protection from none. Measured result: blind requests were
ignored at exactly `k` = 195 through 204 (a 10-cycle window, matching the
hold's measured length), four requests (a polite and a blind write, a
polite and a blind read) were accepted in the exact cycle a refresh first
became due (`k` = 194), 328 REFRESH commands were issued over the run with
the longest gap between two at 215 cycles (204 is the measured gap when
nothing is in flight; the rest is a pending refresh waiting for an
in-flight transaction to finish - refresh is not starved), and no polite
request was ever dropped. The independent check is a new tRFC rule in `sim/ddr3_model.v`
itself, watching the real command pins and indifferent to which module
issued a command; `tb_ddr3_refresh_wire.v` (Part 11) had to switch from
the top-level `write_busy` to the sequencer's own `wseq_busy` for its
contention check, since the former now includes the refresh hold and
would trip on every legitimate refresh.

It passed on the first run, which per this project's own discipline is
not evidence of anything, so it was mutation-tested seven ways, each
specific to this round's own logic, all caught by the mechanism expected:
the write gate removed (the model's new tRFC rule fires on blind requests
at `k` = 195 onward), the read gate removed (same, on reads), the gate fed
by `refresh_hold` instead of `refresh_hold_d` (a polite caller is dropped
at exactly `k` = 194 - the measured proof of the race the delayed gate
exists to prevent, not a hypothetical), `refresh_grant` without its
`refresh_hold_d` term (caught at the same boundary, by the model's tRFC rule
firing - confirmed by printing its message, not inferred), `write_data_latch` on the caller-visible busy (stale data
reaches memory at `k` = 194 only), `write_busy`/`read_busy` without the
hold (polite callers no longer see busy and are dropped), and `refresh_grant`
fed by the caller-visible busy (deadlock - caught as a timeout). Part 11's
own forced-grant mutation was re-run against the modified design too, since
this round edited that test's signals, and is still caught. `make
verify`/`make verify_ooo` both pass, `sim_ddr3_reverse_arb` among them, no
regression on the existing DDR3 tests. The gate was restarted once
mid-round, after the write-versus-read probe below showed the command
mux's "mutually exclusive by construction" comment overclaimed; the
result covers the final file.

**Two gaps this round found, both newly named.** *PRECHARGE before
REFRESH.* The same Micron figure shows PRECHARGE-all (note 3: `A10` must
be high "if more than one bank is active (must precharge all active
banks)") and tRP ahead of every REFRESH. This design never issues
PRECHARGE - its write and read sequencers force `A10` low and nothing
closes a bank - so a REFRESH after any write or read lands with a bank
still open. Established from the RTL and the datasheet, not measured:
`sim/ddr3_model.v` does not track bank state and so cannot see it. It
also means the new tRFC rule is the only refresh rule checked. *Write/read
mutual exclusion.* Found by probing what a caller could do that the tests
do not, and measured: a `write_req` and a `read_req` presented in the same
cycle run in lockstep, the pins carry only the write's ACT and WR (the
command mux's fixed priority silently wins), the read's ACT and RD never
reach the DRAM yet its `read_start` still pulses, `read_data` comes back
`z`, and the protocol checker stays silent because the pins look legal.
Part 9's "mutually exclusive by construction" comment was true for init
versus the rest and, since Part 11, for refresh versus write/read, but
never for write versus read - it now says so in `rtl/soc/ddr3_ecp5_top.v`
itself. Callers must present one request at a time; enforcing it is real,
separate work.

**What this does not establish.** Both gaps above. Stage 1's own "Done
when" bar also still names Verilator (every test in this stage has only
ever run under Icarus) and "formal or property checks where the design
admits them" (not attempted anywhere in this stage). `sim/ddr3_dq_model.v`
is still a single stored location, so the sweep checks that each accepted
request ran with the right data and each ignored one left no trace, not a
real multi-location array. The hold is conservative - a request presented
in the ten cycles after a refresh command is ignored even in the last few,
where tRFC has already elapsed - which costs throughput, not correctness.
Bank-state tracking, the second DQ byte lane, and real hardware bring-up
remain open, unchanged.

**Update, Part 13: a request is now either fully accepted or fully
ignored - at most one DDR3 transaction is ever in flight - closing the
write/read gap Part 12's probe measured, and the sweep that proved it
also found a stale-data bug that had been in the design since Part 9.**
A `write_req` and a `read_req` are accepted only if neither sequencer is
busy and no refresh holds the bus, and in the same cycle a write beats a
read:

- `wseq_write_req = write_req & ~refresh_hold_d & ~wseq_busy & ~rseq_busy`
- `rseq_read_req = read_req & ~refresh_hold_d & ~wseq_busy & ~rseq_busy & ~wseq_write_req`

`write_busy` and `read_busy` are now the same value (either sequencer
busy, or a refresh holding the bus), so a caller waiting on its own
direction's busy is safe against the other direction too - a second real
API change to those ports after Part 12's.

**Test first, and what running it against the unfixed design measured.**
`sim/tb_ddr3_wr_excl.v` was written and run against the unmodified RTL
before anything was changed, so the hazards are measured, not reasoned.
It failed in several distinct ways. *Same cycle* (d = 0): the read's ACT and
RD never reached the pins and it returned wrong data, matching Part 12's
probe. A *read overtaken by a write* (R->W, d = 1) also returned wrong data. *Coincident commands*: at d = 3, in both orders, a command from
each sequencer landed in the same cycle and one was lost. Worth saying
plainly that most other overlapping offsets did *not* fail on command
counts - the two sequences simply interleave on the command bus - so a
sparse test would have passed a design that was still wrong, and only the
sweep found the offsets where the commands coincide. *A polite caller*: one
that respected only its own direction's busy still collided at d = 2 in
both orders, which is why per-direction busy was not enough and the two
ports had to carry the same value. And *stale write data*: a second write
presented at d = 11 reached memory carrying the previous write's data.

**That last one was a latent bug, independent of the write/read gap.** A
sequencer is back in `S_IDLE` one cycle before its `busy` drops, and it
accepts a request in that cycle. `write_data_latch` (Part 9) only captured
when `!write_busy`, so a request presented in exactly that cycle was
accepted by the sequencer while the latch kept the old data. It needed a
caller that violates the busy contract to reach, which is why nothing
before this sweep hit it - but it is a real path to silently writing wrong
data, and gating on the sequencer's *own* busy as well closes it. The
mutation that removes just that term is not caught the obvious way: the
latch then updates on every presented request, including mid-flight ones,
overwriting an in-flight write's data - it is caught by the data check
across `W->W` offsets 1 and up, which is why the term is load-bearing and
not redundant with the latch change.

The sweep: a second request presented at every offset `d` from 0 to 30
after the first, for all four pairs (`W->W`, `W->R`, `R->W`, `R->R`), as a
blind caller (ignores `busy`) and as a polite one (waits on its own
direction's busy), 241 rounds, each anchored on `refresh_busy` falling and
run in the quiet stretch before the next refresh is due so it does not
interact with Part 12's hold. The property is stated as counts against
the real command pins, which no internal signal can fake: ACT on the pins
equals accepted writes plus accepted reads, WR equals accepted writes, RD
equals accepted reads, completions and `read_data_valid` pulses equal
acceptances, plus two global invariants (both sequencers never busy
together, never both driving a command in the same cycle) and the
documented tie-break itself. Measured result: 437 ACT, 219 WR and 218 RD
on the pins for 219 accepted writes and 218 accepted reads, and the outcome
symmetric across all four pairs - a blind second request ignored at 11
offsets and accepted at 19 in each - with no polite request ever dropped.

Mutation-tested six ways, all caught by the expected mechanism: the write
gate without the read-busy term, the read gate without the write-busy
term, no same-cycle tie-break, the write gate without its own busy, busy
kept per direction (polite callers are dropped), and the tie-break
reversed so a read beats a write (caught by the assertion added for
exactly that, since coherence alone would not notice which one wins).
All twelve DDR3 tests pass on the final design, and `make verify`/`make
verify_ooo` both pass with `sim_ddr3_wr_excl` among them.

**The PRECHARGE gap is broader than Part 12 framed it.** Part 12 named
"PRECHARGE before REFRESH". Reading the datasheet's ACTIVATE entry for
this update: "This row remains open (or active) for accesses until a
PRECHARGE command is issued to that bank. A PRECHARGE command must be
issued before opening a different row in the same bank." This design
never issues PRECHARGE, so every transaction after the first that opens a
different row of a bank it opened earlier is illegal on a real part, not
only a REFRESH that lands with a bank open. (An ACT to the *same* row
already open is not addressed by the text read, and is not claimed
either way.) Nothing in simulation can see it: `sim/ddr3_model.v` does
not track bank state and `sim/ddr3_dq_model.v` is a single stored
location. The datasheet also gives a candidate for the smallest fix -
READ and WRITE take auto precharge on `A10`, "the row being accessed will
be precharged at the end of the READ burst" - which would close both
halves of the gap at once; that is a candidate, not an evaluated design,
and this is the next item.

**What this does not establish.** The PRECHARGE gap above. *More than one
caller*: the contract is one caller presenting at most one request at a
time, and two independent masters presenting in the same cycle still get
one silently ignored (write wins) - a real ack or queue is needed for
that, and the Stage 2 Wishbone wrapper is single-master so it does not
need it yet. Throughput: the controller is strictly one transaction at a
time, with no pipelining or bank interleave. Stage 1's own "Done when" bar
also still names Verilator (every test in this stage has only ever run
under Icarus) and "formal or property checks where the design admits
them" (not attempted anywhere in this stage). `sim/ddr3_dq_model.v` is
still a single stored location. The second DQ byte lane and real hardware
bring-up remain open, unchanged.

**Update, Part 14: every transaction now closes its own bank with a
PRECHARGE, and the simulation model finally tracks bank state - which
showed that Part 9's headline write-then-read round trip was not a legal
DDR3 command sequence.** Parts 12 and 13 both named this as the next gap;
the datasheet reading for Part 13 made it clear it was broader than "a
REFRESH lands with a bank open".

**What the datasheet says, primary-source.** Micron's ACTIVATE entry:
"This row remains open (or active) for accesses until a PRECHARGE command
is issued to that bank. A PRECHARGE command must be issued before opening
a different row in the same bank." That states the different-row case.
Part 13's account hedged the same-row case, since the text it had read did
not address it; the datasheet's Simplified State Diagram (Figure 2) has
ACT leaving only the Idle state, and its general rule is "Any
functionality not specifically stated is considered undefined, illegal,
and not supported, and can result in unknown operation" - so ACT to an
already-open bank is out either way, and Part 13's hedge is settled. Also
from the datasheet: REFRESH needs every bank precharged (Figure 40 shows
PRECHARGE-all, then tRP, then REFRESH), tRTP is "the greater of 4CK or
7.5ns", and in DLL-disable mode - which this design runs in - tWR is "the
greater of 4CK or 15ns" (note 33), with write recovery starting four
clocks after WL for BL8 (note 34).

**Test first: giving the model bank state made the existing suite fail.**
`sim/ddr3_model.v` gained per-bank state, independent of which module
issued a command: ACTIVATE to an open bank, READ or WRITE to a closed one,
PRECHARGE before tRTP or before write recovery, and REFRESH with any bank
open (PRECHARGE with A10 low closes only its own bank, high closes all;
PRECHARGE to an idle bank is a NOP, as the datasheet says). Run against
the unchanged design, every test that issues more than one transaction
failed, and printing the model's message for Part 9's own
`sim_ddr3_cmd_seq` gave "ACTIVATE to a bank that is already open (no
PRECHARGE first)": that test's read activates the bank the write had just
opened and never closed. Part 9's result stands as what it claimed - the
command timing and the write-drive, capture and calibration wiring work
end to end - but its command sequence was never legal on a real part, and
nothing could say so until the checker knew what a bank was.

**The design.** `ddr3_write_seq.v` and `ddr3_read_seq.v` each end by
issuing PRECHARGE-all (`A10` high) after the data phase, and hold `busy`
through it. That gives one invariant the rest of the design leans on:
whenever both sequencers are idle, every bank is closed, so a REFRESH
granted while they are idle is legal by construction and the refresh path
needed no change. Placement is the datasheet minimum plus one cycle, the
margin `TRCD_CYC` already carries. After a write: WR + CWL(6) + BL/2(4) +
tWR(4) = 14 cycles minimum, issued at 15, measured. After a read the
datasheet minimum is only tRTP (4), but PRECHARGE is deliberately placed
after the burst has finished, at RD + CL + BL/2 + 1 = 11 measured, so the
design never closes a bank while its own capture window is open - a
design margin, not a datasheet requirement, and named as one. tRP has no
wait state of its own: at 15 ns or less it is under one 40 ns cycle, and a
request cannot be accepted before `busy` drops, so the fastest possible
caller measures 3 cycles (120 ns) from PRECHARGE to the next ACT.

**What the model does not check, and why.** tRCD, tRAS, tRP and tRC are
deliberately not modelled. At 25 MHz each is under one cycle (the two
cycles tRC needs are implied by tRAS plus tRP), so a rule for them can never fire,
and a rule that cannot fire cannot be tested. They become necessary if
`sclk` is ever raised. CK-count minimums are counted in `sclk` cycles, the way
the sequencers already count CL and CWL: a convention the whole design
uses, conservative if CK is in fact faster than `sclk`, and named here rather
than left implied.

**A checker whose rules cannot fire is not a checker.** Two of the new
rules cannot be triggered by the real design at all - a design that
follows them never breaks them - so `sim/tb_ddr3_model_banks.v` gives each
rule its own directed stream on its own model instance, behind one shared
real init sequence: ten instances, two legal controls (one at the exact
minimum spacings, so a too-strict rule fails there instead of silently
rejecting a correct controller; one with several banks open closed by both
PRECHARGE-all and per-bank PRECHARGE) and one stream per rule, each
identified by the model's own message. The spacings come from the
datasheet, not from the model's constants. Mutation-tested nine ways on
the model itself: each of the five checks removed (each fails exactly its
own streams), PRECHARGE ignoring `A10` (a REFRESH with a second bank open
is no longer flagged), the write-recovery and tRTP limits each one cycle
too strict (the legal control at the exact minimum fails), and PRECHARGE
never closing the bank.

**The design change, mutation-tested seven ways** against the standalone
and integrated tests: either sequencer skipping its PRECHARGE (caught by
its standalone test, by `sim_ddr3_wr_excl`, and for writes also by
`sim_ddr3_cmd_seq` and `sim_ddr3_reverse_arb`), write PRECHARGE too early
(the model's write-recovery rule), a wrong command encoding, and a
PRECHARGE aimed at the wrong bank with `A10` low. One did not go the way
it might look. Read PRECHARGE at RD + 8 instead of RD + 11 is still legal
against tRTP, so the model correctly does not flag it; only the standalone
test's exact-gap check catches it, which is the right layer for a design
margin. And `sim_ddr3_cmd_seq` does not catch the read-side mutations at
all, because it ends on a read and never follows it with another
transaction - the one-transaction sweep does. `sim_ddr3_wr_excl` now also
counts PRECHARGE on the real pins: 409 ACT, 409 PRE, 205 WR and 204 RD for
205 accepted writes and 204 accepted reads, so "fully accepted" now means
its ACT, its WR or RD, and its PRECHARGE all reached the pins. `make verify`
and `make verify_ooo` both pass with `sim_ddr3_model_banks` and the
updated sequencer tests among them. The gate was restarted once mid-round,
after a stale comment in the model (it called PRECHARGE a stray command the
design never issues) was corrected; the result covers the final file.

**Cost, stated.** A transaction is now about 22 cycles for a write and 18
for a read, up from about 11 and 13, because every one waits out its
PRECHARGE. The measured longest gap between refreshes grew from 215 to 224 cycles (204
nominal plus the wait for an in-flight write); that test's starvation bound
was restated with its derivation instead of left sitting a few cycles from
the measurement. This controller opens and closes a bank around every
access rather than exploiting open rows.

**What this does not establish.** Open-page operation, bank interleaving
and any throughput work - correctness first. The four nanosecond
parameters above that are not modelled, and the `CK = sclk` counting convention (retired by Part 16). Auto-precharge
(`A10` high on READ or WRITE, which the datasheet also allows) was not
evaluated or used. Stage 1's own "Done when" bar also still names
Verilator (every test in this stage has only ever run under Icarus) and
"formal or property checks where the design admits them" (not attempted
anywhere in this stage). `sim/ddr3_dq_model.v` is still a single stored
location, so no test can see a write landing in the wrong row. Two
independent callers presenting in the same cycle still get one silently
ignored. The second DQ byte lane and real hardware bring-up remain open.

**Update, Part 15: the memory model now decodes bank, row and column the
way the part does, so a write landing in the wrong cell is finally
visible - and the measured result is that the address path is correct,
and that until now nothing could have told us if it were not.** Every
account since Part 9 has carried the same caveat: `sim/ddr3_dq_model.v` is
a single stored byte, so "no test can see a write landing in the wrong
row". That was a coverage gap a green suite was silent about, and it is
closed here. No bug in the address path turned up; what changed is that
one would now be seen.

**What the part decodes, primary-source.** Micron's Table 2 for the 256 Meg
x 16 device (32 Meg x 16 x 8 banks - the chip Part 10 identified as
ECPIX-5's): row address 32K, `A[14:0]`; bank address 8, `BA[2:0]`; column
address 1K, `A[9:0]`; 2KB page. The controller's interface is wider than
that - `write_row`, `read_row`, `write_col` and `read_col` are 16 bits - so
the model decodes what the part would, not what the ports carry: row bit 15
and column bits 10 and up are not address bits (in a column command `A10`
is auto-precharge, `A12` is BC#, and `A11` and `A13`-`A15` carry no column
address on x16), and two requests differing only there hit the same cell,
exactly as on the real part. That is
now an asserted behavior of the test, not folklore. It also means
`ddr3_write_seq.v` and `ddr3_read_seq.v` pass `col[15:11]` through to the
pins where the part ignores them - harmless, and left alone.

**The model.** It watches the same real command pins the protocol checker
does: an ACTIVATE records the open row of its bank, and a WRITE or READ
records the bank, that bank's open row, and the column. The data phase - the
write data a CWL later, the read window a CL later - then lands in, or comes
from, that location. Pairing a data phase with the most recent WR or RD
command is sound only because the controller keeps at most one transaction
in flight (Part 13), and the file says it relies on that. Storage is a
small content-addressable table, since Icarus has no usable associative
arrays. A location never written reads back as `x`, on purpose: a read that
returned stale data from somewhere else would otherwise look like a hit.
Data written before any command has been seen goes to one separate cell,
which is what the calibration sweep's direct write and read injection needs,
since it issues no DRAM commands.

**The test, and why it has three layers.** `sim/tb_ddr3_addr.v` writes
distinct data to 47 locations, reads them all back, overwrites every fifth
and reads again, reads three never-written locations (each differing from a
written one in one field), and checks the aliasing case above. The set is
built to expose single-bit faults: every bank, every single-bit row (15) and
column (10) with the rest fixed, both all-ones extremes, and one location
per low/high combination of the three fields. It ran 157 transactions and
crossed 18 REFRESH commands, so data integrity across refreshes is checked
too. Three independent checks, because each misses what the others catch -
and this was measured, not assumed. *Read-back through the DUT* catches
aliasing and any write-versus-read disagreement. *Asking the model directly*
where each byte landed, by the address the test requested, catches a
permutation. *The real pins* - each ACT's bank and row and each WR or RD's
bank and column must equal the request, decoded as above - catches a dropped
or shifted bit directly. The case that separates them is a bank-bit swap
applied identically to the write and read paths: uncaught by read-back
(zero failures, since both paths agree), caught by the pins check (120) and
by the direct check (17).

**Mutation-tested eleven ways, all caught.** Seven address-path bugs in the
sequencers - row bit 14 dropped on writes, column bit 9 dropped on reads,
the write bank masked on the WR command only, row bit 0 dropped, the read
path's bank low bit inverted, bank bit 2 dropped on both paths (aliasing banks 0-3
with 4-7), and the consistent bank-bit swap - and four in the memory model:
the key ignoring the bank, the key using 14 row bits, the row taken from the
wrong bank, and unwritten locations reading zero instead of `x`.

**The gap, measured rather than argued.** The same address-path bugs were
applied to a copy of `main` with the old single-byte model and its old
tests. Three of the four tried (row bit 14 dropped on writes, column bit 9
dropped on reads, bank bit 2 dropped on both paths) passed all five DDR3
integration tests: green and wrong. The fourth, the write bank masked on the
WR command only, was caught by `sim_ddr3_cmd_seq` - and only because Part 14
gave the protocol checker bank state, which flags a WRITE to a bank that is
not open. That last one is the honest footnote: bank state closed one slice
of this class two parts ago; this closes the rest. `make verify` passes with
`sim_ddr3_addr` among the targets. `make verify_ooo` was not run: no file under
`rtl/` changed, the DDR3 targets do not take `CORE`, and CI runs the wide-core
variants regardless. The gate was restarted once mid-round, after a stale
comment in `sim/tb_ddr3_reverse_arb.v` (it still called the memory model a
single stored location) was corrected; the result covers the final file.

**What this does not establish.** The data path is still one byte lane on a
part that is x16, so nothing here says anything about the second lane, the
data-mask pins, or which byte of a 16-bit word a write lands in; that is the
next real piece of hardware-facing work. The memory returns `x` for a
location never written, which is a modelling choice - a real part returns
whatever its cells hold. Two independent callers presenting in the same
cycle still get one silently ignored. Stage 1's own "Done when" bar also
still names Verilator (every test in this stage has only ever run under
Icarus) and "formal or property checks where the design admits them" (not
attempted anywhere in this stage). Open-page operation, real hardware
bring-up and the four nanosecond parameters Part 14 chose not to model
remain open, unchanged. (A caveat on this update's memory model was found
after it merged: see the survey below.)

**Survey, no design change: the Stage 1 data path is a mechanism-level
model, not yet a hardware-faithful one - measured, and it sits underneath
the "second byte lane" item every account since Part 9 has named as
next.** Before widening the data path to x16 the current one was measured
rather than assumed, and it is not what "one byte lane" implies. Nothing
below is a regression - none of it was ever claimed to work on hardware - but
it is a distance the earlier accounts did not state, it changes what the
sensible next step is, and it is recorded here in the "Known defects"
ledger so it is not rediscovered.

**Measured: DQ is driven outside the DQS window.** A single write, watched
cycle by cycle on the integrated design: `write_start_final` is high for
**one** `sclk` cycle, and DQ's output-enable (`dq_oe`) is high for exactly
that one cycle. The write-drive enable for DQS (`dqs_wr_oe`) rises the *following*
cycle and stays high for four (preamble, two active toggle cycles,
postamble). So DQ is enabled for one cycle, one cycle before DQS is even
enabled and two cycles before its first active toggle; the two active DQS
cycles, which are the eight beats of a BL8 burst, see no DQ enable at all. A
real DRAM samples DQ on DQS edges, so it would capture undriven pins. The
simulation never noticed, because `sim/ddr3_dq_model.v` stores `wr_d0` on the
internal `wr_en` tap - it never compares DQ against DQS, so every write in
every test has been a mechanism check, not a timing check. The read side is
closer: `read_active` is two cycles (eight UI at the design's 4:1 ratio) and
the capture is aligned to it, but the model returns the same byte on all four
phases, so a wrong capture phase is invisible.

**Verified from the RTL: CK and the data rate disagree by 2x.**
`rtl/soc/ddr3_phy_ecp5.v` generates CK with an `ODDRX1F` on `sclk` - CK runs
at `sclk`'s 25 MHz - while `rtl/soc/ddr3_dq_serdes_ecp5.v` moves four UI per
`sclk` cycle per pin, a 100 MT/s data rate that implies a 50 MHz CK. Part 3
unified the clock *tree* (everything runs off one PLL) but never compared the
two rates; the PLL header's own "reconciling the two is later work" was
closed for the tree and left open for the ratio. The command timings the
design already counts (`CL_CYC`, `CWL_CYC`, the new PRECHARGE spacings) all
treat CK as `sclk`, so they are self-consistent and conservative in the sense
Part 14 described, but the data path is on a different rate than the CK the
DRAM would see. This one is an inference from two files, not a measurement on
hardware; simulation cannot show it, since the PLL model is `assign sclk =
clk`.

**Also, not yet a burst.** MR0 selects BL8, but every transaction moves one
byte: the four write phases all carry the same byte, the read takes only
`rd_q0`, and there are no data-mask pins, no second lane and no `UDQS` -
`ddr3_dm` and the upper byte's pins do not exist in the top-level ports,
while the ECPIX-5's part, as Part 10 identified it, is x16. That is the part of
the gap the "second byte lane" item already named; the two measurements above are what it did not.

**A caveat on Part 15, added after it merged.** The address-decoded memory
model stores one byte per (bank, row, column). A real part running BL8 writes
eight beats into eight columns of an aligned block on every unmasked write, so
two writes to different columns of the same block would clobber each other
there and do not in the model. Part 15's finding stands for what it measured -
the address that reaches the command pins - but the model is more forgiving
than the part about what a single-byte write leaves behind, and a
byte-granular write on real hardware needs the data mask (`DM` high on seven
of the eight beats, the byte on beat zero, with the burst started at the
wanted column).

**What a hardware-faithful path needs, in an order that follows from
the dependencies, not a commitment.** (1) Settle the clock and phase
architecture: CK at the edge-clock rate, commands placed on one of two
phases per `sclk`, every CK-counted timing recounted from that. This has to
come first because everything else's timing follows from it. (2) A DRAM model
that samples DQ on DQS edges at beat resolution, with data mask - the
checker that would have caught the first measurement above. (3) A write path
whose DQ enable and beats sit inside the DQS active window, and a read path
that picks the right capture phase. (4) x16: the second lane, `UDQS`, the
mask pins, per-lane calibration, the top-level ports and the ECPIX-5 pin
constraints. (5) Only then Stage 2's `wb_ddr.v`, because its request
interface depends on one open decision - whether the controller keeps a
byte-granular interface (each access a masked single-beat burst) or exposes
whole 16-byte bursts, which matches a 16-byte cache line and is far more
efficient, at the cost of buffering and a partial-write path. That decision
is the maintainer's, not this file's.

**What this does not establish.** Whether the design would in fact fail on
the board - the measurements are of a behavioural model, and the ECP5
primitives' own behaviour around the DQS window was not read from Lattice's
documentation for this survey (the copy on hand is the block-RAM guide, not
the high-speed I/O one). The first measurement is against this design's own
cycle-level model, and the real primitives' internal latencies could move the
relationship by a cycle. It says nothing about `DQSBUFM` read calibration,
which stands as measured. The exact effort of the path above is not
estimated here. (Step 1, the clock and phase architecture, is Part 16, and
the write half of steps 2 and 3 is Part 17, and the read half Part 18, below.)

**Update, Part 16: CK now runs at the edge-clock rate, twice `sclk`, with
two command slots per `sclk` - the structure Lattice's own reference DDR3
write side uses - closing the half of the survey's finding that was about
the clock, and putting the synthesis half of the PHY under a tool for the
first time.** The survey gave its second measurement as an inference from
two files; this part measured it first, then fixed it, then read the
document the survey admitted it had not read.

**Measured before the fix.** A new test, `sim/tb_ddr3_phy_phases.v`, was
written and run against the unchanged PHY: CK rose **5649 times against 5649
`sclk` edges, a ratio of exactly 1.00** - CK at 25 MHz against a data path
moving four UI per `sclk`. That turns the survey's "inferred from the RTL"
into a measurement. After the fix the same test reads 2.00.

**Primary source, read this time.** Lattice's FPGA-TN-02035 (the copy
hosted in a public GitHub mirror, version 1.2 - a newer 1.3 exists
and was not read), section 6.3.3 and Figure 6.10: CK is an `ODDRX2F` "with
inputs tied to constants", four values per `sclk` on the edge clock, so CK
runs at `eclk`; address, bank, RAS, CAS, WE, CKE and ODT go through
`ODDRX1F` taking two values per `sclk`, and CS_n through `OSHX2A`, so two
command slots per `sclk`, one per CK cycle; CK and CS_n then pass through a
`DELAYG` in `DQS_CMD_CLK` mode. Figure 6.9, the write side, has DQ and DM on
`ODDRX2DQA` clocked by `DQSW270` and DQS on `ODDRX2DQSB` clocked by `DQSW`,
all fed from the same `sclk`-domain words - which is what the next slice
needs. From Micron's datasheet, on why 50 MHz is legal: in DLL-off mode
only CL = 6 and CWL = 6 are supported, and `tCK[DLL_DIS]` has a minimum
(8 ns) and no stated maximum. The datasheet also says, for the read
slice, that read data starts "AL + CL - 1 cycles after the READ command"
in DLL-off mode (5 CK, not 6) with `tDQSCK` of 1-10 ns.

**What changed.** `rtl/soc/ddr3_phy_ecp5.v` takes `eclk`. In synthesis, CK and
CK# are `ODDRX2F` on constants through `DELAYG`, CS_n is `OSHX2A` (low only in
phase 0, high in phase 1) through `DELAYG`, and everything else is `ODDRX1F`
with both slots carrying the same value - the DRAM ignores them, since CS_n is
high in phase 1. In simulation CK is the `eclk` itself, whose rising edges
fall exactly 10 ns after each `sclk` edge, the centre of each command slot,
and phase 1 is a deselect. The design still issues at most one command per
`sclk` and always in phase 0, so nothing above the PHY changes shape - but a
CK-counted latency now converts exactly. **CL = CWL = 6 CK is 3 `sclk`, not
6:** before this part the design counted CK as `sclk` and waited twice as long
as MR2 tells the DRAM to expect the write data. `CL_CYC` and `CWL_CYC` are 3,
and the PRECHARGE spacings that follow from the datasheet minimums are
recounted: write 15 to 8 `sclk` (the 14-CK minimum is 7, plus one `sclk` of
margin), read 11 to 6. The init sequencer's mode-register and ZQ-calibration waits are
counted in `sclk` and now wait twice the CK minimum; left as they are,
conservative, with their comments corrected. The protocol model and the memory
model now sample commands on the rising edge of CK, where the DRAM does, and the
model converts nanoseconds at the CK rate - which retires Part 14's
"CK counted as `sclk`" convention: every CK-count constant in it is now
literally the datasheet's number. tRAS (two CK now) **can** fire, unlike the
four rules Part 14 dropped, so the model gained it, with its own self-test
case; the same self-test also gained the case Part 12's tRFC rule had never
had (a command one CK short of 260 ns, 13 CK, after a REFRESH) and every
legal control now sits at an exact CK boundary.

**The synthesis branch, under a tool for the first time.** Every DDR3 test runs
the simulation branch; the `ifdef SYNTHESIS` half of the PHY, DQ serializer and DQS
files, the half that instantiates the real ECP5 primitives, had never been
read by anything. `make synth_check_ddr3` elaborates it against yosys's own
ECP5 cell library with `hierarchy -check`, and it is in `make verify`. It
found nothing wrong with the existing branch - it elaborated on the first try
- and it can fail: renaming one `ODDRX2F` port to a nonexistent one gives
"Module `ODDRX2F` ... does not have a port named 'D9'". It catches wrong
wiring, not wrong behaviour.

**Mutation-tested eight ways, all caught.** CK back at `sclk` rate and phase 1
not deselected (both by the phase test; the second also makes the protocol
model see doubled commands), a command driven in phase 1 (caught **only** by
the phase test - the models sample on CK whichever phase), CWL and CL left at
6 (caught by the standalone sequencer tests), write recovery too short (the
standalone test, and the model's own write-recovery rule in the integrated
ones), the model converting nanoseconds at the wrong rate (the self-test's
tRFC case), and the memory model sampling commands on `sclk` again (143
failures in the address test). One of those is the finding worth having:
**with CWL or CL left at the wrong value, every integrated test still
passes.** The memory model drives read data when told and stores write data
off an internal tap, so it has no DRAM latency to be wrong about. That is
exactly the gap the survey named, now shown on a concrete change, and it is
the next slice.

**Measured after.** The phase test: 11274 CK edges against 5637 `sclk`, ratio
2.00, all six commands of a write-then-read in phase 0, none doubled, pins
stable across every CK edge. Transactions are shorter: a blind second request
is now ignored at 13 offsets after a write (20 before) and 11 after a read (16
before). The invariants hold - 433 ACT, 433 PRE, 217 WR and 216 RD on the pins
for 217 accepted writes and 216 accepted reads - and the refresh hold window
is unchanged (blind requests ignored at 195 through 204, the boundary hit at
194), with the longest gap between refreshes at 217 cycles. `make verify` passes
with the phase test, the synthesis check and every DDR3 target among them;
`make verify_ooo` was not run: no CPU, SoC or board build references any DDR3
file, so it cannot be affected, and CI runs the wide-core variants regardless.

**What this does not establish.** The DQ write window is still misaligned with
DQS - measured in the survey, untouched here, and the next thing to fix. The
DRAM's read timing (`CL - 1` in DLL-off mode, `tDQSCK`) is not modelled. The ECP5
primitives' behaviour is taken from Lattice's figure: whether phase 0 lands
where this file assumes after the fabric-to-pin latency of `ODDRX2F`,
`ODDRX1F` and `OSHX2A`, and what `DELAYG` in `DQS_CMD_CLK` mode actually
delays by, is unverified on silicon - the synthesis check proves the wiring
resolves, nothing more. The simulation's phase relationship is designed, not
derived: it depends on a testbench generating `clk` as `always #(period/2)`
from time zero. No data mask, no second lane, and the interface decision
(byte-granular versus 16-byte bursts) remains the maintainer's. Verilator,
formal checks and real hardware bring-up remain open.

**Update, Part 17: a write burst now lands where the DRAM's write latency
says - DQ is driven exactly while DQS toggles, WL after the WRITE - and the
memory model finally judges a write from the pins. Against the unaligned
design that model could not even complete calibration.** This is the DQ-window
half of the survey's finding, closed; the clock half was Part 16.

**Test first, and the result was stronger than expected.** `sim/ddr3_dq_model.v`
was changed to judge writes from what the DRAM would see - the command pins and
the resolved DQ and DQS pins - instead of storing an internal tap, and run
against the unchanged design. Calibration did not complete: `calib_done=0`,
`calib_error=1`, and the model's calibration cell held `00`. The sweep's own
test-pattern write never reached the memory, because DQ was not driven while
DQS was active. The survey had measured a misalignment; this showed the write
path had never worked at this level of fidelity, and nothing had been able to say
so. (The model did not flag an error for calibration itself - it issues no WRITE
command, so there is nothing to time the burst against - which is why the symptom
was calibration failing, not a message.)

**What the DRAM requires.** For a WRITE driven in `sclk` cycle W (Part 16: commands
sit in the first of two command slots), WL = CWL = 6 CK = 3 `sclk`, so the first
DQS rising edge falls 10 ns into cycle W+3: DQS low in W+2 (a full `sclk`, 2 CK,
over the 0.9 tCK preamble minimum), active with DQ driven in W+3 and W+4 (the
eight beats), low in W+5, and high-Z in every other cycle.

**What changed.** `ddr3_dqs_write_ecp5.v` exports `burst_active`, its two active
cycles. `ddr3_ecp5_top.v` enables DQ from it instead of from the one-cycle
trigger, and captures the byte when the burst is triggered - calibration's
`wr_d0` is only valid for the trigger cycle - holding it until the window opens.
`ddr3_write_seq.v` triggers the DQS FSM `CWL_CYC - 1` `sclk` after its own
`cmd_valid`. **That constant was wrong on the first attempt**, and it is worth
saying how: the derivation used `CWL_CYC - 2`, forgetting that the PHY registers
the command once more, so the command pins lag `cmd_valid` by one `sclk`. The
burst came out one cycle early, and the pin-level checker flagged it at once - a
small demonstration of why the checker exists. The PRECHARGE spacing is unchanged
at 8 `sclk` (`WREC_CYC` 4 to 5 to absorb the earlier trigger). The calibration
bench, which predates the DQS write FSM, now wires the real one as the top does;
the calibrated tap is unchanged.

**The model.** For each WRITE sampled in cycle W it expects the schedule above and
sets a sticky `dq_error` for anything else: DQS not low in the preamble, not active
or DQ not driven in a burst cycle, not low in the postamble, or DQS driven outside
the burst once commands have started. Data is stored from the first burst cycle
only if that cycle itself looked valid. That last point corrects a claim in this
part's first draft of the model header, that a misaligned burst's data is never
stored: the self-test showed a burst shifted by exactly one cycle can still store,
since one of its cycles lands where the first half was expected. For that case
`dq_error` is the verdict, so every integrated test now reads it.

**Three layers of test.** `sim/tb_ddr3_wr_window.v` watches the real pins with a
monitor that shares nothing with the model's checker: eight writes with different
banks, bytes and gaps, every one showing DQS low at W+2, active at W+3 and W+4,
low at W+5, high-Z otherwise, and DQ carrying the requested byte in both active
cycles. `sim/tb_ddr3_dq_window_rules.v` proves each model rule can fire - eleven
instances on their own pins, two legal controls (one driving DQ during the
preamble and postamble, which the DRAM ignores, so a rule rejecting it would be
too strict) and one stream per rule, identified by the model's own message. And
six integrated tests gained a `dq_error` check; the standalone DQS test gained one
for `burst_active` being exactly the two active cycles.

**Mutation-tested seventeen ways, all caught.** Nine on the model, each against
the self-test: the preamble, burst-DQS, DQ-driven, postamble and outside-the-burst
rules each removed (each fails exactly its own streams), the write latency off by
one (eight streams and the integrated command-driven test), a rule made too strict
(the control fails), data stored without the validity gate, and the calibration
capture dead (the calibration bench and the top test). Eight on the design: the
burst one cycle early and one cycle late, DQ enabled the old way, the burst one
cycle long, the data hold removed, the hold reading the wrong source, and write
recovery too short. Two findings. Shifting the burst one cycle early is **missed by
the standalone calibration bench**, because calibration has no WRITE to time
against - a real limit on what checks the calibration write. And putting the
preamble inside `burst_active` is caught **only by the standalone DQS test**: DQ
driven during the preamble is legal for the DRAM, so no timing check can object -
that is a design choice, and the standalone test is the right layer for it.

**What this does not establish.** The DRAM's **read** timing - `CL - 1` cycles after
the READ in DLL-off mode, with `tDQSCK` of 1-10 ns - is still not modelled; the
memory model still drives read data when told, so a wrong CL is still invisible to
every integrated test. (Part 18, below, closes this.) At `sclk` resolution the pins carry one DQ word per cycle, so
beat order is not visible, all eight beats carry the same byte, and only the first
half's byte is stored - a stand-in for real BL8 semantics, which write eight
columns per unmasked burst, until the data-mask slice. Calibration's write
bursts come with no WRITE command, so there is nothing to time them against. The alignment is to this design's
own simulation substitutes: the ECP5's real fabric-to-pin latency through
`ODDRX2DQA` and `ODDRX2DQSB`, and the sub-cycle `tDQSS` window (plus or minus a
quarter CK), are not resolved at this resolution and are unverified on silicon. No
data mask, no second lane, and the byte-granular versus 16-byte-burst interface
decision is still the maintainer's. Verilator, formal checks and real hardware
bring-up remain open.

**Update, Part 18: the memory model now answers a READ at the DRAM's own read
latency, so a wrong CL is finally visible to the integrated tests. The design
needed no change - its read window was already where the DRAM's data is.** This is
the read half of the survey's finding, closed on the model side; Part 17 was the
write half. Nothing under `rtl/` changed, apart from comments.

**Test first, and the result was a confirmation, not a fix.** `sim/ddr3_dq_model.v`
was changed to schedule the read burst itself from the READ command, and run
against the unchanged design: every integrated test passed. The existing read
window (`CL_CYC` 3) is aligned to the DRAM at `sclk` resolution, which nothing had
been able to say. The measurement that gives that meaning is the other direction.
Part 16 had shown a wrong `CL_CYC` passing every integrated test; with the new
model, `CL_CYC` of 2, 4 and 5 each fail the command-driven, address-path and
one-transaction tests. (The standalone-calibration bench, the top-level test and
the write-rules self-test still pass all three, as they should: none does a
command-driven read.)

**What the DRAM does.** In DLL-off mode Micron gives read data "AL + CL - 1 cycles
after the READ command", 5 CK, with `tDQSCK` of 1-10 ns after that. The READ is
sampled 10 ns into `sclk` cycle R and the first DQS edge falls 110-120 ns into it,
so at `sclk` resolution: preamble in R+2 (DQS driven low, DQ still high-Z), burst
half 1 in R+3 (DQS high, DQ carries beat 0), half 2 in R+4 (beat 4), postamble in
R+5, and high-Z otherwise. The `tDQSCK` spread is under a cycle and quantised away.

**The two halves differ on purpose.** Half 1 is the addressed column. Half 2 is the
byte at `{col[9:3], col[2:0] ^ 3'b100}` - BL8 in sequential order from column c
returns c, c+1 ... wrapping in the aligned 8, so beat 4 is four columns on. If both
halves carried the same byte, a capture one cycle late would return the right value
and nothing would notice. A neighbour never written reads `00`; the addressed
column, when unwritten, still reads `x`, so a stale read cannot pass as a hit.

**What changed.** The model gained a `mem_dqs_oe` output, since DQS is now driven
(low, in the preamble) while DQ is still high-Z, and every testbench that resolves
the DQS bus gained it. Calibration issues no READ command, so until the first
command has been seen the model still answers `read_active`, as before. The rules
self-test's stray-burst case moved eight cycles later, out of the model's own read
drive - it had overlapped it and looked like bus contention. Comments in
`rtl/soc/ddr3_ecp5_top.v` were corrected: they said the read half was still open.

**Two layers of test.** `sim/tb_ddr3_rd_window.v` watches the real pins with a
monitor that shares nothing with the model. Ten reads: eight with different rows,
bytes and gaps, each showing DQS low at R+2, high at R+3 and R+4, low at R+5,
high-Z otherwise, DQ carrying beat 0 at R+3 and beat 4 at R+4 (the written
neighbour, alternately the column above and the wrapped one below), the design's own
READ window overlapping a DQS-high cycle, `read_data_valid` exactly once at R+4 - a
value measured off the run and then pinned - and the byte returned being beat 0, not
beat 4; and two of cells not fully written, one whose neighbour was never written
(beat 4 is `00`) and one never written at all (unknown). The integrated tests
above are the second layer: they fail through the data.

**Mutation-tested eleven ways, all caught.** Eight on the model: half 2 made equal
to half 1, the burst one cycle early and one cycle late, an unwritten neighbour
reading `x` and a never-written cell reading `00` (each swapped for the other's
value), the neighbour taken as column + 4 without the wrap, and the read preamble
and postamble each removed. Three on the design: `CL_CYC` 2, 4 and 5. Every one
fails the read-window test. The schedule shifts and the wrong `CL_CYC` values also fail three
integrated tests; the unwritten-cell value swaps each fail one of them; half
2 equal to half 1, the missing wrap and the removed preamble or postamble are caught
by the read-window test alone, which is what it is for.

**Tried, and left out.** The first version also made the DQSBUFM stand-in's
`DATAVALID` and `BURSTDET` depend on the DQS pin, which they had ignored. It looked
like the right fidelity and was tested as a mutation: removing it changed no test
outcome, alone or combined with a wrong `CL_CYC` - the wrong-cycle window is caught
by the byte returned, and nothing consumes `BURSTDET`. Untested code claiming
fidelity is worse than a named gap, so it was removed, and the model header says the
stand-in still ignores DQS.

**What this does not establish.** The alignment is to this design's own simulation
substitutes at `sclk` resolution: the ECP5's real fabric latency through
`IDDRX2DQA` and `DQSBUFM`, and the sub-cycle `tDQSCK` window, are not resolved and
are unverified on silicon - a real board could still want a different `CL_CYC` or
`READCLKSEL`. The pins carry one DQ word per cycle, so a read returns two halves,
not eight beats, and a write still stores only its first half. Calibration's reads
still follow `read_active`, so the calibration sweep is not judged against the
DRAM's read timing. No data mask, no second lane, and the byte-granular versus
16-byte-burst interface decision is still the maintainer's. Verilator, formal
checks and real hardware bring-up remain open. (Part 19, below, does the Verilator half.)

**Update, Part 19: the DDR3 tests now run under a second simulator, Verilator,
and - for the first time - in CI. The second simulator found two things Icarus could
not: a protocol checker that judged whatever a simulator left on the command pins
before reset, and a memory model no Verilator build could connect to.** This is the
"Verilator" half of the gap every account since Part 1 has named, and it turned up
a larger one on the way: `.github/workflows/ci.yml` had no reference to DDR3 at all.
Eighteen slices had been gated only by whatever a contributor ran locally.

**Test first.** The DDR3 testbenches were built under Verilator 5.050 (`--binary
--timing`) with nothing changed. **Eleven of eighteen could not be built:**
`Unsupported: tristate in top-level IO: 'dqs_pin'`, from a tri-state net connected to
an `input` port of the memory model. A minimal repro showed the same net accepted on an
`inout` port, and read correctly (high-Z included) through it. Of the seven that
built, five passed and two failed. With the model's two pin ports changed to `inout`,
all eighteen built: twelve passed and six failed.

**A wrong first hypothesis, measured away.** The two failures that survived the port
change (`sim_ddr3_init`, three checks, and `sim_ddr3_model_banks`, twelve) were the same
symptom: the protocol checker reported "expected MRS to MR2 first" and the run ended at
620 ns. The first guess was a `timescale` dependence in the PLL model (the only `#`
delay in the DDR3 files is its edge-clock half period, and that file declares no
`timescale`). Adding one changed nothing. A probe printing the command pins on
every CK edge showed the real cause: at the very first CK edge, 10 ns in, `cs_n`,
`ras_n`, `cas_n` and `we_n` were all 0 - an MRS - with RESET# low and CKE low. The
registers in the PHY first take a value at the first `sclk` edge, 20 ns in, after the first CK edge.
Icarus leaves those registers `x`, which no rule of the checker matches, so the garbage
was invisible. Verilator has no `x`; it left 0.

**The fix follows the datasheet, not the simulator.** Micron's initialisation section: while
RESET# is low the outputs are High-Z and "all other inputs, including ODT, may be
undefined". A DRAM in reset does not decode commands, so the checker now ignores the
command pins while RESET# is low. Before, it passed only because Icarus's `x` happened to
look like nothing.

**The four other changes are portability, not behaviour.** The memory model's `dq_pin` and
`dqs_pin` are `inout` ports (the model never drives them; its own drive is the `mem_*`
outputs). The rules self-test drives its pins through output enables instead of assigning
`z` to a reg - a Verilator reg is two-state, and Icarus needs a net on the other side of
an `inout`. The two window testbenches read DQS and DQ through a new `sim/pin_probe.v`
whose ports are `inout`, so a floating strobe reads as high-Z. And the checks that need an
unknown value are compiled out under Verilator (`ifndef VERILATOR`).

**What a pass under Verilator does not show.** Verilator is two-state, so, and these stay
Icarus-only: the x-based bus-contention checks in the command-driven and top-level tests
cannot fire; "an unwritten location reads back as x" cannot be asked; a strobe nobody
drives reads as low on a net two modules drive, so the window tests accept low where they
expect high-Z and cannot tell floating from driven-low; and the rules self-test, whose job
is to show that each "DQ or DQS not driven" rule can fire and which is seven of eleven
cases exactly that distinction, is **not run under Verilator at all**. Seventeen of
eighteen are.

**Are the Verilator runs able to fail?** Nine mutations of the design and the model, each
run against all seventeen: `CL_CYC` 2 and 4 (six tests each fail), the model's read burst
one cycle late (five), the write burst trigger one cycle late (eight), write recovery cut
to 3 (seven), the delayed refresh gate removed (one - the reverse-arbitration test, as
under Icarus), the DQ data hold removed (nine), and each of this part's own two fixes
reverted. Every one is caught. Those last two are the point: with both model fixes
reverted, all seven affected Icarus tests still pass, so they are defects only a second
simulator sees. Reverting the port change is nine build failures.

**Lint.** `make lint-rtl-ddr3` runs Verilator's `-Wall` on the simulation branch of the DDR3
RTL - only that branch, since the synthesis branch instantiates ECP5 primitives Verilator
has no models of, which is what `synth_check_ddr3` is for. It reported two warnings that
were fixed - an initial value declared on a register the PLL model also assigns, and a delay code the
simulation branch never drove - and two that are deliberate and are waived in place with
the reason: `cs_n_pin`, written on both `sclk` edges because that is what two command
slots per `sclk` are, and the reset net, read synchronously once by the falling-edge
deselect in the PHY. It was shown able to fail by removing a waiver and by injecting a width mismatch.

**CI.** A new `ddr3` job runs `make ddr3_check_sim` - the eighteen Icarus tests, the seventeen
Verilator runs and the lint - and `synth_check_ddr3` is a step of the existing `formal`
job, which has yosys. `make verify` depends on the same two, through one list of tests in
the Makefile, so a test is either reached by both or by neither.

**The first CI run disagreed, and the disagreement was a finding.** The new job installs
Verilator from the distribution's package manager, release 5.020, and failed on it: three
tests that pass on 5.050 (`refresh_ctrl`, `reverse_arb`, `addr`) and the lint, which 5.020
refuses to run on a file with a delay or an event control unless told `--timing`. A local
build of 5.020 was not possible (the macOS flex fails to link it), so a throwaway branch
ran a two-question micro-test on the runner. Reading a DUT register at the edge that
updates it behaved as the standard says. A testbench's `a <= 1` made at an edge did not:
a flop sampling `a` at that same edge saw the new value, where the standard gives the old
one, so the DUT saw the testbench's request one cycle earlier than under Icarus or 5.050.
The three tests that hard-code an exact alignment (a grant against the command it
produces; a request against a pending refresh) measured the shifted timeline: "expected 2,
got 1", and a caller that follows the busy signal having its request dropped. Their
stimulus is now applied with `<= #1`, 1 ns after the edge. Under a conforming simulator
the DUT-visible timeline is unchanged (no expected value moved); under 5.020 the
assignment can no longer land at the same edge. The other fourteen pass under either
alignment. The lint gained `--timing` and a waiver for the PLL model's deliberate blocking
assignment, which `--timing` makes it report. A run on the runner's 5.020 then passed all
seventeen Verilator tests, the eighteen Icarus tests and the lint.

**What this does not establish.** Two versions of Verilator now disagree on one scheduling
point and the tests avoid it rather than relying on either; a third might disagree
elsewhere. The nine mutation runs above were made on 5.050 only. Verilator scheduling is
one more opinion, not a proof: it says nothing about real timing, and two simulators
agreeing does not make a model hardware-faithful. The x-based and floating-net checks are
exercised by Icarus alone.
The lint covers the simulation branch only. No formal or property checks, no data mask,
no second lane, and the byte-granular versus 16-byte-burst interface decision is still
the maintainer's. Real hardware bring-up remains open. (Part 20, below, does the formal half.)

**Update, Part 20: formal proofs of the DDR3 controller's control plane - arbitration,
bank state and refresh gating - for every request pattern, up to 250 cycles. The solver
refuted two of my own first-draft properties, and nine deliberate breakages of the RTL.**
This is the "formal or property checks" half of Stage 1's own "Done when" bar, which every
account has named as unattempted. It covers the controller between the request ports and
the command pins; it does not cover power-up or data.

**What is proved, and on what.** On the real `ddr3_ecp5_top.v`, not a copy: the properties
sit in an `ifdef FORMAL` block at its end (yosys cannot follow a hierarchical reference from
a wrapper), and `formal/ddr3_stubs.v` replaces what the controller does not need and yosys
cannot read - the PLL, PHY and DQ/DQS data path with constants, and initialisation and
calibration with what they hold for the rest of time (`ready` and `calib_done` high, nothing
driven). The last is not a convenience: a proof starting from reset would spend its whole
depth inside the 200 us reset wait and never see a request. So every claim below is "after
initialisation and calibration", which is the only time the request ports do anything.

- The three command sources - write sequencer, read sequencer, refresh - are never valid
  together, and no two requests are forwarded at once. The header has said since Part 9 that the
  command mux is exclusive by construction; this is that claim, proved.
- A request reaches a sequencer only when nothing is in flight and the gate is open, and never
  when the sequencer it would start is itself busy: the Part 13 hazard, stated directly.
- A REFRESH command goes out only with both sequencers idle.
- Two callers in the same cycle: the write is taken and the read is not, never both. This is the
  named gap (the loser is ignored, not queued), now pinned down rather than merely described.
- A caller that respects `busy` - sees it low in one cycle and presents in the next, and does not
  present two cycles running - is never dropped. This is Part 12's guarantee, which the
  reverse-arbitration test showed at 41 request offsets and which now holds at every offset.
- Bank state on the command pins, with a monitor that ACTIVATE sets and PRECHARGE clears: no
  ACTIVATE to an open bank, no column command to a closed one, no REFRESH with one open.
- Command spacing, with the datasheet numbers the memory model already checks: WRITE to
  PRECHARGE at least 7 `sclk` (14 CK), READ to PRECHARGE at least 2, ACTIVATE to PRECHARGE at
  least 1, and nothing within 7 `sclk` (tRFC, 13 CK) of a REFRESH.

**Measured, because the depth is the whole question.** The properties only mean something once a
refresh has come due, which at the design's real interval is about 195 cycles after reset, so the
bound has to reach past it. z3, the flow's solver, took 15 s at depth 20 and 199 s at depth 40,
and grows steeply (about ninety times as long as Boolector at depth 40). Boolector took 2.3 s at depth 40 (Yices 9 s), 15 s at depth 100 and 55 s at
depth 200; the proof at depth 250 takes about 85 s. `formal/run.sh` therefore checks this target
with Boolector to depth 250 and everything else as before, and fails loudly if Boolector is not on
`PATH`. It is in oss-cad-suite, which the `formal` CI job already installs, and not in Homebrew:
`make formal` on a machine that has only Homebrew's yosys and z3 will now say so rather than pass.

**Two of my properties were wrong, and the solver said so at the first refresh.** The first draft
said a request is never forwarded while a refresh is pending. Part 12 deliberately gates on the
*delayed* hold, so a request presented in the very cycle a refresh becomes pending is still taken and
the refresh waits for it - that is what lets a polite caller never be dropped. And the first draft
said the refresh scheduler is never busy while a sequencer is: its `busy` is high from the moment a
refresh is pending, not only while it runs. Neither was a design fault; both were my restatement of
the design, refuted at step 196 and 197 by a trace the design had produced legitimately. Each is
corrected in the file with its reason.

**A proof that cannot go red is not evidence, and one that cannot be reached is not either.** Two
checks. Nine mutations of the RTL, each refuted at its own property: the write gate ignoring its own
`busy` (step 2), a read not held off by a same-cycle write (step 1), a refresh granted with a write in
flight (step 198), the gate ignoring a pending refresh (step 197), the gate using the hold without its delay -
the Part 12 mutation - which is caught by the polite-caller property at the first refresh (step 196),
write recovery cut to 3 (step 12), no PRECHARGE after a write (step 16), tRFC cut short (step 205), and a
refresh granted without waiting for either sequencer (step 198). And twelve `cover` statements, one
beside each event the properties talk about - a refresh command, a request taken in the cycle a refresh
becomes pending, a refresh that had to wait for a transaction, a request ignored because one was in
flight - which `formal/run.sh` now requires to be reachable within the same bound: an unreached one
fails the target as vacuous. A tenth, initialisation that never finishes, holds the
controller in reset for ever and makes every assertion true; it is reported as vacuous rather than
proved.

**What this does not establish.** A bounded proof: every request pattern up to 250 cycles from reset, so
a bug that needs a second refresh (about cycle 400) or a longer history is out of reach, and unbounded
proof would need k-induction. Nothing about initialisation, calibration, the PHY or any data. The bound on
READ to PRECHARGE is loose (the design gives 6, the property says 2), so a shortened read recovery would
still pass it and is caught only by the sequencer tests and the memory model. "Respects `busy`" is a
definition of a caller, not something the design enforces. The stand-ins are stated assumptions: if
`ddr3_init_seq` or `ddr3_read_calib` drove a command after they report done, this would not see it. Data
mask, second lane and the byte-granular versus 16-byte-burst interface decision are unchanged.

**Update, Part 21: the PHY now goes through full synthesis and place-and-route on the
ECPIX-5's device with the board's real DDR3 pins. Getting it there found two defects no
simulation could see - and three places where the design assumes pins the board does not have.**
Every account since Part 1 has listed "ECP5 top-level ports and constraints" as unattempted.
The design had only ever been through `synth_check_ddr3`, which elaborates against yosys's
cell library and says nothing about whether a placer will accept the result.

**The pins.** litex-boards' platform file and amaranth-boards' description of the ECPIX-5 are
maintained separately, and were compared mechanically: they agree pin for pin on all eleven
signal groups this design uses (address, bank, RAS#, CAS#, WE#, CKE, ODT, DQ, DQS, CK, the
data masks). The Amaranth file additionally gives the negative halves of the differential
pairs. LambdaConcept's own documentation has no DDR3 page, so there is no vendor cross-check
and neither source is a schematic: `fpga/constraints/ecpix5_ddr3.lpf` says so in its header.
**Neither source lists CS# or RESET#.** (Update, 2026-10-18, Stage 2 Part 15: that was wrong about the schematic, which the documentation's
resources list and which this part did not look for. Its FPGA sheet agrees with all 44 pins, and says what the board does with CS# and RESET#;
see the open known defect.)

**Test first, and the failures came one at a time,** because each is a packing error that stops
the run. On `main`'s RTL, with the real pins:
1. `IOLOGIC functionality (DDR, DELAY, DQS, etc) can only be used with pin-constrained PIO
   (while processing 'PHY.CS_DLY')`. CS# is generated by `OSHX2A` plus `DELAYG`, which need a pad,
   and the board has none.
2. With the four ports the board has no pin for parked on throwaway pins - CS#, RESET#, CK#,
   A15 - `TSHX2DQA 'SERDES.DQ_LANE[7].OE' Q output must be connected only to a top level
   tristate`.
3. With that fixed, `Port RDPNTR2 of cell 'SERDES.DQ_LANE[7].CAP' must be driven by port RDPNTR2
   of a DQSBUFM`.

**Defect 2, the tri-state polarity, is a real bug and a subtle one.** `TSHX2DQA` is a tri-state
control: high means the pad is released. The design feeds it `!wr_en`, so its `Q` is high exactly
when DQ should not be driven - and the top then used that `Q` as an *enable*, in
`assign ddr3_dq[i] = dq_oe[i] ? dq_o[i] : 1'bz`. The drive was inverted, and nextpnr could not place
it. No simulation could see this, because the simulation branch defines `dq_oe` itself as an enable;
the two branches meant opposite things by the same name. The same was true of DQS. The pad is now a
`BB` (the ECP5's bidirectional buffer) with `T` taken directly from the primitive's `Q`, in the
synthesis branch only; the modules gained a `dq_t` and `dqs_t` output beside the unchanged `dq_oe` and
`dqs_oe`, so no testbench changed its meaning.

**Defect 3, the read FIFO pointers.** Every `IDDRX2DQA` must take its `RDPNTR` and `WRPNTR` from its
byte lane's `DQSBUFM`. The design tied them to constants and left the `DQSBUFM` outputs open. They are
wired now. Neither this nor defect 2 changes any simulation result (`make verify`).

**Then it places and routes** (`make pnr_probe_ddr3`, `fpga/synth/ddr3_pnr_probe.sh`): 423 flip-flops,
41 pads, 36 I/O logic cells, one `DQSBUFM` (nextpnr put it at `LDQS77`), one DLL, one PLL, `sclk`
at 231 MHz on the local tool bundle and 254 MHz on the one CI downloads (two nextpnr builds, so the figure moves; what is
stable is that it passes its 25 MHz constraint), edge clock promoted to banks 6 and 7, bank 6's VREF on
pin N2. The probe wraps the top in a shift register (`fpga/ecpix5_ddr3_probe.v`) so that only the DDR
pins are pads; it is not a bring-up test and proves nothing about behaviour.

**Two false starts, worth recording because they cost time and were mine.** The first attempt
put the throwaway pins on a right-hand connector, which made nextpnr try to route the edge clock to bank
3, and reported "Unable to route edge clock source" - a finding about my pin choice, not the design. The
second left most pins at the default 3.3 V I/O standard, in a bank the SSTL15 pins had set to 1.5 V. Both
are the same lesson the LPF header now states: every SSTL15 pin needs its `IO_TYPE` written down.

**Is the probe able to fail?** Nine mutations. Seven are caught: the pads made behavioural again (`main`'s
state), each pad given the enable polarity (caught - the primitive's `Q` then reaches a LUT, not a pad,
which is how the inversion shows), the pointers tied off, the `DQSBUFM` outputs left open, a pin at the
wrong I/O standard, and the DQS pad moved to a non-DQS site. **Two pass, and the header says so:** moving
a DQ pin to an address pin (wrong DQS group) is not caught - nextpnr does not check group membership - and
neither is tying a tri-state control to a constant. So the probe checks structure, not that the wiring means
the right thing, and the pin list is exactly as good as its two sources.

**Three things the board says about the controller, which this part records and does not fix.**
- **No CS#.** If it is tied low, the DRAM decodes every clock edge as a command, and the design's
  phase-1 deselect - CS# high, the second of the two command slots per `sclk` (Part 16), and every cycle
  with no command - has no pin to happen on. An idle slot would have to be a NOP (RAS#, CAS#, WE# all high)
  on the command pins instead. That is a change to the PHY and to what the protocol checker treats as idle.
- **No RESET#.** The initialisation sequence holds RESET# low for 200 us and releases it, and the FPGA
  cannot. How the board resets the DRAM is not in either source.
- **CK and DQS are single ports here, differential on the board.** The design has a `ddr3_ck_n` port and drives
  DQS as one wire; on the board the negative pads follow the positive ones automatically, so a real top has
  neither `ddr3_ck_n` nor `ddr3_dqs_n`. And the part is x16: lane 1, its strobe and the two data masks exist and
  the design drives none of them; lane 0's own data mask is now driven (Part 22) - an unmasked, undriven
  upper lane on a write is a separate hazard.
The probe parks CS#, RESET#, CK# and A15 on left-edge throwaway pins (`ecpix5_ddr3_probe.lpf`, headed as
not a pinout) so that it can look at everything else.

**What this does not establish.** Nothing about behaviour, or about timing at the DDR clock: `sclk` meeting
25 MHz says nothing about a 50 MHz edge clock reaching the pins. Whether the DLL works: `DDRDLLA`'s update
and freeze inputs are tied off, where a reference design steps them at reset, and place-and-route cannot see
that. The ECP5's real fabric latency through the DDR primitives is still unverified, and no board has been touched. CS#
and RESET# are open questions that a schematic would settle and these sources cannot. Only lane 0 is
constrained. The probe is not in `make verify` (it needs nextpnr, which is in YosysHQ's bundle and not in Homebrew);
CI runs it in the `formal` job. (Part 22, below, drives lane 0's own data mask.)

**Update, Part 22: the data mask (DM), lane 0. Through Part 21 nothing drove a DM pin at
all, and every write burst carried the same one byte across all eight real UI - a real
hazard, not just a missing pin, since the datasheet masks a beat only when DM is sampled
high on it, and an undriven or always-low DM masks nothing.** This closes the "no data
mask" half of the survey's own gap list; the second lane is the half that remains.

**Measured, before any design change existed to measure against.** `sim/ddr3_dq_model.v`'s
own write side had never modelled the write burst's second sclk-visible half touching a
column at all - it was "ignored, as if the data mask covered them" (Part 17's own words),
a claim nothing had tested. It now does: the second half lands on the same neighbour
column Part 18's read side already names (`{col[9:3], col[2:0]^3'b100}`), unless DM masks
it. With nothing yet driving DM, that neighbour column receives the burst's own byte -
the "caveat on Part 15" made concrete: a byte-granular write, run to completion, silently
overwrites a real column four columns away.

**What changed.** `rtl/soc/ddr3_dm_drv_ecp5.v` (new): `ODDRX2DQA` alone, no tri-state -
DM is FPGA-output-only on this part, so nothing ever drives it back and there is nothing
to arbitrate. `rtl/soc/ddr3_dqs_write_ecp5.v` exports `active0`, high only in the first of
its two active states. `rtl/soc/ddr3_ecp5_top.v` drives DM low exactly then, high
otherwise - low for the addressed column, high for the neighbour, high at every other
time (the safe idle default). A first version registered this in simulation, matching nothing
in particular, and a real run caught it at once: DM read the *previous* cycle's value,
one `sclk` behind the state register `active0` reads directly - masked exactly where it
should write, and not where it should. Fixed to combinational passthrough, the same stand-in
`ddr3_dq_serdes_ecp5.v` already uses for DQ and `ddr3_dqs_write_ecp5.v` already uses for DQS.

**The model.** `sim/ddr3_dq_model.v` gained a `dm_pin` input, and a compatibility rule
worth stating precisely: unconnected (`z`, what every testbench predating this part does)
changes nothing - the first half stores exactly as before, the second still touches
nothing. Only an explicit `1` at the first half (masking the write itself - a design
defect, the byte is lost) or an explicit `0` at the second (leaving the neighbour
unmasked - the corruption case) change anything. Nine testbenches that go through the
real top now wire `dm_pin` for real, giving every one of them a live DM check for free.

**Three layers of test.** `sim/tb_ddr3_dm_window.v` (new): the real DM waveform across eight
writes (low only at W+3, high everywhere else, matching the design's own timing), then two
real writes to neighbouring columns proving the second does not disturb the first.
`sim/tb_ddr3_dq_window_rules.v` gained two directed instances on their own column (chosen
so a naive `col+4` and the real wrap formula disagree): one with DM correctly masking the
second half (neighbour stays unwritten), one without (the neighbour receives the burst's
byte - the hazard, reproduced directly against the model). And the nine rewired
integration tests.

**Mutation-tested six ways.** Three on the design: DM tied low throughout (caught by
`dm_window`, `addr`, `rd_window`), DM tied high throughout - never writes anything (caught
by `dm_window`, `cmd_seq`, `addr`, `wr_excl`, `rd_window`), and DM masking the wrong half
(same four). Three on the model: the first-half gate removed (**caught by nothing** - with
DM always correctly unmasked there in the real design, the gate is never exercised; a
named, honest gap, not a silent one), the second-half gate removed (caught by `dm_window`,
`addr`, the new rules instances, `rd_window`), and the neighbour formula's own copy in
`store_neighbour` changed to a naive `+4` (caught only by the new rules instances - the
one place that drives DM low at the second half on purpose).

**What this does not establish.** Real per-UI fidelity: only two of the eight real UI have
any modelled effect (matching every other simplification in this file), so a design that
masked, say, only six of the seven beats it should would not be caught here. Whether the
first-half masking gate in the model can ever fire is untested (above); Calibration's own
direct-injection writes issue no command and are not checked against DM at all. Lane 1's
own data mask is unchanged - still not driven, named in Part 21's own list of what the
board says the controller still lacks. No formal proof of DM (Part 20's properties are the
control plane; this is data). No board. (Part 23, below, protects the untouched upper lane.)

**Update, Part 23: the untouched upper byte lane is held safely inert, not left
unconnected.** The part is x16; this design transfers through lane 0 only. Through Part 22,
lane 1's own DQ, UDQS and UDM had no real pin at all - not just unused, a real hazard,
since a x16 DRAM drives DQ[15:8] and UDQS from its own side on every real READ this
design's lane-0 traffic still provokes, and an unconstrained pin gets an unstated
direction rather than the one this design actually wants.

**What changed.** `ddr3_udm` (lane 1's own data mask) is driven high, always - the same
"FPGA-output-only, no tri-state needed" shape `ddr3_dm` already established (Part 22), so
a write issued through lane 0 can never be read by the DRAM as also touching the upper
byte. `ddr3_dqu` and `ddr3_udqs` are permanently tri-stated from the FPGA side - `BB` pads
with `T` tied high, the same real primitive Part 21 already established for lane 0, not a
plain `assign = z` left to inference - so a real READ's own drive from the DRAM is never
contended. Nothing in this design reads through this lane yet; that is unchanged and named
as such.

**Test.** New `sim/tb_ddr3_upper_lane.v`: across a run with real command-driven writes and
a real refresh - not just reset, when everything reads inert by construction regardless of
whether the design is right - `ddr3_udm` is sampled every `sclk` cycle and must never read
low or unknown; `ddr3_dqu` and `ddr3_udqs` must never read as driven. Three mutations, each
caught: `ddr3_udm` tied low, the upper DQ lane driven, UDQS driven. (Excluded from
`verilator_ddr3`: the whole point of this test is telling a floating pin from a driven one,
on pins nothing in the design ever drives from either side, and Verilator has nothing left
to distinguish once it resolves the net - the same reason `tb_ddr3_dq_window_rules.v` is
excluded.)

**Place-and-route.** `fpga/constraints/ecpix5_ddr3.lpf` gains lane 1's own real pins (the
same two independently-maintained sources Part 21 cross-checked); `fpga/ecpix5_ddr3_probe.v`
exposes them so the probe actually routes the full x16 footprint, not just lane 0's own
half of it. Caught by mutation: UDM left at the board's default 3.3 V standard fails
exactly the same way Part 21 measured for lane 0's own pins.

**What this does not establish.** Nothing about lane 1's own capability to transfer data -
no capture, no drive, no calibration for it; that is the "second lane" item every account
since the Part 14/15 survey has named, and remains open. No formal proof (Part 20's
properties are the control plane, unaffected by pins nothing in the design's own logic
reads or writes). No board. (Part 24, below, proves lane 1's own hardware calibrates.)

**Update, Part 24: lane 1's own `DQSBUFM`, DQ capture/drive and independent
`READCLKSEL` calibration, proven standalone - the same real proof Part 2 gave lane 0, run
a second time on lane 1's own pins, at the same time, sharing what real hardware actually
shares.** Not yet wired into the real command path: this mirrors Part 2's own original
scope exactly, before Part 3 integrated it, and deliberately does not touch the still-open
byte-granular-versus-16-byte-burst question - a standalone proof that lane 1's own hardware
calibrates commits to nothing about how a caller eventually reaches it.

**A real architectural mistake, caught before any wrong RTL was written.** `DDRDLLA` is a
FPGA-side, not a per-lane, primitive: one instance's `DDRDEL` output fans out to every
byte lane's own `DQSBUFM` - confirmed directly against LiteDRAM's own real, shipping ECP5
PHY. Through Part 23, `rtl/soc/ddr3_dqs_ecp5.v` instantiated its own `DDRDLLA` internally,
correct only because a single lane was ever this whole slice's own scope (Part 2) - a
second lane would have silently doubled a primitive real hardware has exactly one of, had
this not been checked against the cited architecture before writing anything. New
`rtl/soc/ddr3_ddrdlla_ecp5.v` now owns the one, shared instance; `ddr3_dqs_ecp5.v` takes
`ddrdel` as an input instead of generating it, and drops the `dll_locked` output it used to
produce alongside its own DLL. `rtl/soc/ddr3_ecp5_top.v`, `sim/tb_ddr3_data.v` and
`formal/ddr3_stubs.v` all updated to match; every existing DDR3 test still passes
unchanged, confirming the refactor moved nothing it should not have.

**New `sim/tb_ddr3_data_lane1.v`: both lanes calibrate at once, with different test
patterns, not two separate single-lane tests** - because the real question is not whether
lane 1's own mechanism works in isolation (already known, being identical to lane 0's), it
is whether the two interfere. Checked directly: each lane's own calibration must find its
own pattern, and neither lane's own bus may ever carry the other's.

**Measured, and a real limit of the existing simulation stand-in found in the process.**
Cross-wiring the two lanes' `dq_i` inputs is caught cleanly. Cross-wiring their `readclksel`
compare signals is not: both calibration sweeps are identical state machines, and staggering lane 1's
own reset by a few cycles (itself a real fix - synchronized calibration state machines are
not something real hardware would ever have either) still leaves an 8-value sweep with a
4-of-8 "good" window enough that a wrong compare signal often reports some plausible-looking
tap by chance rather than failing outright. And cross-wiring `dqs_pad_i` between the two
lanes is not observable at all: Part 2's own simulation stand-in for `DQSBUFM` never reads
that signal in simulation (`dqsr90`/`dqsw`/`dqsw270` come from `sclk`/`eclk` directly, and
`datavalid`/`burstdet` from `read_active`/`readclksel`) - a real limit of that stand-in,
present since Part 2, only now exercised by having a second lane's own `dqs_pad_i` to
cross-wire against.

**What this does not establish.** Nothing about the real command path: lane 1 is not wired
into `rtl/soc/ddr3_ecp5_top.v`'s own write/read sequencers, so no controller-facing request
can reach it yet, and how one eventually would is still entangled with the
byte-granular-versus-16-byte-burst decision this file has named as the maintainer's since
the Part 14/15 survey. A `readclksel` or `dqs_pad_i` cross-wiring between the two lanes'
own `DQSBUFM` instances is not reliably provable by simulation, for the reasons above; this
part did not yet extend the probe to instantiate a second real `DQSBUFM`/`IDDRX2DQA` set
either (`fpga/ecpix5_ddr3_probe.v` still wraps the single-lane `ddr3_ecp5_top.v`). No
formal proof. No board. (Part 25, below, wires it into the real design; a survey later in
this stage measures what place-and-route actually catches of the gap named here.)

**Update, Part 25: lane 1's own calibration, DQ/DQS write-drive and data mask are wired
into the real design, running automatically at boot the same way lane 0's always has -
not yet reachable from `write_req`/`read_req`, but no longer standalone or held
permanently inert either.** Part 23's own safe-default wiring (`ddr3_dqu`/`ddr3_udqs`
permanently tri-stated, `ddr3_udm` tied high always) is gone, replaced by a second, real
`CALIB1`/`DQS1`/`DQS_WR1`/`SERDES1`/`DM_DRV1` instance - sharing the one `ddr3_ddrdlla_ecp5`
instance Part 24 already established, exactly the way real hardware does.

**A real, measured failure on the first attempt - the test was incomplete, not the RTL.**
`sim/tb_ddr3_top_lane1.v` first showed lane 1's own calibration failing every tap through
the real top, where the identical mechanism had passed standalone in Part 24. The
difference: the standalone test gave lane 1 its own memory model to loop calibration's
test pattern back through; this one, at first, did not - `ddr3_dqu`/`ddr3_udqs` floated,
so no tap could ever read back what it wrote. Adding a second `ddr3_dq_model` instance,
the same role Part 3's own `MEM` plays for lane 0, fixed it: the RTL had been correct.

**A second, pre-existing bug found while strengthening the place-and-route probe for
this part - the probe's own primitive-count check has been vacuous since Part 21.**
`fpga/synth/ddr3_pnr_probe.sh` checked that each primitive's name appeared somewhere in
`write_json`'s output, but `write_json` always dumps every ECP5 cell's own blackbox
definition alongside the design - confirmed directly: `"OSCG"`, instantiated nowhere in
this design, matches the same check. The check would have passed even if every one of the
primitives it names had never been instantiated at all. Replaced with a real count of
instances inside the design's own module entry, which also gives Part 24's own DLL-sharing
claim its first real proof: exactly one `DDRDLLA` and exactly two `DQSBUFM` in the
synthesized netlist. (A mutation making lane 1 instantiate its own, second `DDRDLLA` is
caught even earlier than that count, by `nextpnr-ecp5` itself refusing to route a second
edge clock to a second DLL in one bank - a real, physical confirmation that the "one per
side" architecture this whole DLL-sharing effort follows is not a stylistic choice.)

**Mutation-tested.** Cross-wiring lane 1's own DQ pads to lane 0's `dq_o` is caught
(calibration fails outright). Lane 1's own DM tied permanently low was not caught by the
test's first version (it only checked DM goes low at least once, which a stuck-low signal
also satisfies) - strengthened to also require DM going back high afterward, which now
catches it. Cross-wiring lane 1's own UDQS pad to lane 0's own DQS output is not caught,
for the same reason Part 24 already named: the pins carry a plausible-looking burst
waveform regardless of which lane's logic produced it, and the simulation stand-in for
`DQSBUFM` does not check which. Feeding `CALIB1`'s own `DQS1` instance a fake, unshared
`ddrdel` is not caught by simulation either - nothing there reads a real delay code either
way - but is caught immediately by real place-and-route, as above.

**What this does not establish.** Still nothing about the real command path: no `wseq`/
`rseq`-equivalent drives lane 1, so a controller-facing request cannot reach it, and how
one eventually would remains entangled with the byte-granular-versus-16-byte-burst
decision. The `readclksel`/`dqs_pad_i` cross-wiring gap Part 24 named is unchanged by this
part - simulation still cannot show it. Place-and-route now proves the DLL sharing for
real, but whether it catches a `readclksel`/`dqs_pad_i` cross-wiring too was not actually
checked here - a guess this file should not have stated as settled. No formal proof (Part
20's properties are the control plane). No board. (The survey below measures it.)

**Survey, no design change: which cross-lane wiring mistakes real place-and-route
actually catches, measured directly rather than assumed.** Part 25 guessed
that real place-and-route "would actually catch a net swapped between two real pads" for
the `readclksel`/`dqs_pad_i` cross-wiring simulation cannot show. That guess was checked
by running the mutations through `make pnr_probe_ddr3` for real, and it was only half
right.

**`readclksel` cross-wiring between the two lanes is NOT caught by place-and-route
either.** Feeding lane 1's own `DQS1` instance lane 0's own `readclksel` places and routes
without complaint - `READCLKSEL[2:0]` is a plain 3-bit select bus with no physical locality
tie to a specific `DQSBUFM`, so nextpnr has no basis to object. This gap is real, and stays
open: neither simulation nor place-and-route can show a `readclksel` cross-wiring between
lanes.

**`dqs_pad_i` cross-wiring IS caught, for a precise, previously unconfirmed reason: DQS
group locality, not merely "two pads got swapped."** Two separate mutations were run.
Making both `DQS` and `DQS1` share one `dqs_pad_i` source (an illegal share, not a swap)
fails with `DQSBUFM 'DQS1.DQSBUF' DQSI input must be connected only to a top level input` -
a `DQSBUFM`'s own `DQSI` must connect to a genuinely unique, real pad-derived net, not one
another `DQSBUFM` already consumes. A true swap - each lane still gets a real, unique net,
just the other lane's - fails differently, with `DQS group mismatch, port DQSW270 of
'SERDES1...' in group LDQ89 is driven by DQSBUFM 'DQS.DQSBUF' in group LDQ77`: each byte
lane's own primitives belong to a real, physical `DQS group` tied to their location on the
device, and nextpnr enforces that a lane's own `IDDRX2DQA`/`ODDRX2DQA`/`TSHX2DQA` cells are
driven only by their own group's `DQSBUFM`.

**The same mechanism re-confirms Part 21's own `rdpntr`/`wrpntr` finding, this time with a
genuine second lane to cross-wire against.** Part 21 could only prove "every `IDDRX2DQA`
must take its pointers from its own byte lane's `DQSBUFM`" with one lane in existence,
which makes it true trivially - there was no other `DQSBUFM` to wrongly connect to. Feeding
lane 1's own `SERDES1` lane 0's own `rdpntr`/`wrpntr` now fails with the identical `DQS
group mismatch` error, on `RDPNTR2` this time - the same real constraint, now checked
against an actual alternative rather than an absence of one.

**Corrected: Part 25's own wording.** "Real hardware place-and-route ... would actually
catch a net swapped between two real pads" is true for `dqs_pad_i` and false for
`readclksel` - not a single fact, and this file should not have implied it was one before
measuring both. `fpga/synth/ddr3_pnr_probe.sh`'s own header is updated to state the real
boundary precisely.

**What this does not establish.** Nothing new about the real command path or the
byte-granular-versus-16-byte-burst decision, unaffected by this survey. No RTL changed; this
is a measurement, the same "survey, no design change" shape the Part 14/15 survey used.
`readclksel` cross-wiring between lanes remains an open gap neither layer of proof this
project has closes. No formal proof of any of this (Part 20's properties are the control
plane). No board.

**Update, Part 26: lane 1 carries data, and the controller is x16.** Through Part 25 lane 1 calibrated and drove its pins around its own
calibration burst, and nothing a caller could ask for reached it: `write_data` and `read_data` were eight bits wide and `read_active_1` was
calibration's own signal alone. The part is x16, so a column holds two bytes. A request is now one 16-bit word.

**What changed.** `rtl/soc/ddr3_ecp5_top.v`: `write_data` and `read_data` are 16 bits, `{lane 1, lane 0}`, and a new `write_be[1:0]` says which
lane a write stores. A lane whose bit is 0 has its data mask held high for the whole burst, so the DRAM keeps what the cell holds; 2'b00 runs the
transaction and stores nothing. Both lanes' strobes toggle for every write and both read windows open for every read, as on the part. Each lane does
what lane 0 always did: its byte is captured when the burst is triggered and held until the window opens (`dq_data_hold`, `dq_data_hold_1`), and its
data mask is low exactly in the burst's first half (Part 22) if the lane is stored (`lane0_store`, `lane1_store`). The request's data and enables are
captured at request time (`write_data_latch`, `write_be_latch`). The command sequencers wait for both lanes' calibration, and `read_data_valid` needs both
lanes' `datavalid`. The command path, the sequencers, the refresh and the PHY are untouched.

**Test: `sim/tb_ddr3_x16.v` (new, in `make verify` and CI).** Both lanes' memory models watch the same command pins, each holding its own byte plane. It writes
a different word to each of 18 cells (the first and last cell, a walking one through bank, row and column, a neighbour pair, alternating bits) and reads them
back; runs the byte-enable cases (both lanes, lane 0 only, lane 1 only, neither), each checked against the data-mask waveform of both lanes as well as the data;
runs the neighbour column on both lanes (a word written at column c survives a write to c ^ 4, and a lane-1-only write to c leaves lane 0 and the neighbour alone);
reads the whole sweep again, backwards; and looks into each lane's memory to see that its byte is in its own plane. The caller scrambles the request's data and
enables the cycle after handing it over, so a controller that did not latch them fails. Two scenarios per lane hold a net by hand with `force`: a lane's `calib_done`
low (no command may reach the pins, and the controller reports no busy for a request it did not take) and a lane's `datavalid` low (a read completes with no valid
pulse). The two lanes calibrate in lockstep in simulation, so without these the two gates were unobservable. Verilator's `release` does not hand a forced net back to
the module that drives it, so under Verilator the test stops before them; Icarus runs all of it.

**Mutation-tested, 16 ways, all caught.** Lane 1's byte taken from the wrong half; either store flag held high; the two enables swapped; the data, or the enables, read live
instead of latched; either lane's data mask stuck low; lane 1's data held at zero; lane 1's strobe not driven on a real write; lane 1's read window missing; the two
lanes swapped on a read; `read_data_valid` ignoring lane 1, or lane 0; the commands not waiting for lane 1's calibration, or lane 0's. The first version of the test caught
twelve of the first fourteen. The two that survived were the valid and the calibration gates, which cannot be seen while the lanes move in lockstep; the `force` scenarios,
and the two mirror-image mutants, came from that.

**The old tests.** The eleven testbenches that instantiate the top are adapted: the ports are wider, they write with `write_be = 2'b01` (so lane 0 does exactly what it
did and lane 1's mask stays high), and each gets lane 1's memory, through `ddr3_lane1_mem`, a wrapper at the end of `sim/ddr3_dq_model.v`. The controller no longer takes a
request until both lanes have calibrated, and a lane calibrates by looping a pattern back through a DRAM. `sim/tb_wb_ddr.v`, `sim/tb_ramboot.v` and `sim/tb_uartload.v`
likewise. `rtl/soc/wb_ddr.v` still uses lane 0 alone (`write_be = 2'b01`, the upper byte of every read dropped), so the window is still 256 MB; it waits for both
lanes' calibration, though, because the controller does and drops a request sent earlier. A slave that waited for lane 0 alone would send its first request into the void
(the bug the existing comment names: the first byte of a loaded image missing). `sim/tb_wb_ddr.v` holds lane 1's `calib1_done` low by hand, checks that nothing is
acknowledged, releases it, and checks that the access completes and stored what it was given; the mutant that waits for lane 0 alone fails it, with the word `c0de00xx`.

**Verified:** `make ddr3_check_sim` (every DDR3 test under both simulators, and the lint); the five SoC-level DDR3 tests (`sim_ddrcheck`, `sim_ddrexec`,
`sim_ddratomics`, `sim_ddrmmutest`, `sim_uartload_ddr3`); `make formal` (14 proved; the controller's proof to depth 250 with all twelve cover statements reached);
`make synth_check_ddr3`; `make pnr_probe_ddr3` (places and routes against the real pins, `sclk` at 251.57 MHz after routing, seed 1).

**What this does not establish.** Hardware-faithful bursts: the pins still carry one DQ word per `sclk`, so a burst still moves one column and masks its neighbour (Part 22).
Lane 1 on silicon: the lanes calibrate independently and `read_data_valid` assumes their capture windows open together, which nothing here can show for real silicon; the
`readclksel` and `dqs_pad_i` cross-wiring gaps of Parts 24 and 25 are unchanged. The Wishbone side: the window is still 256 MB, and `wb_ddr.v` still moves a block as sixteen
single-byte transactions (Stage 2, Part 14 closes this). No board.

**Update, Part 27: the controller fits the ECPIX-5's pins - an idle command slot is a NOP, the initialisation pulses nothing, and CS#, RESET#, CK# and A15 are no longer ports.** Stage 2, Part 15 read the board's schematic (R02) and found that the DRAM's CS# is tied to ground and its RESET# belongs to the board's reset circuit, and it left the controller as it was: a deselect in every idle command slot, a RESET# pulse in the initialisation, four ports with no pin, and a build that stopped before the bitstream. This part changes the controller to the board.

**What changed.**
- `rtl/soc/ddr3_phy_ecp5.v`. With CS# always low the DRAM samples RAS#, CAS# and WE# on every rising edge of CK, and a command left on the bus for the second slot of an `sclk` is presented twice (an ACTIVATE twice, a WRITE twice): the old controller would have presented every command twice on this board. The slot that holds no command now holds the NOP, all three high. In synthesis RAS#, CAS# and WE# go out through `ODDRX1F` with the command in the first slot and a constant 1 in the second, and a first slot with `cmd_valid` low is forced to the NOP too; in simulation the three pins return to 1 on the falling edge of `sclk`. The `OSHX2A` that carried CS# is gone, and so are the second `ODDRX2F` and `DELAYG` that carried CK#: `ddr3_ck` is a differential pad (`SSTL15D_I` in `ecpix5_ddr3.lpf`), so the pad pair makes CK# from it, as it does for DQS. The address is 15 bits. The command is still in the first slot, so no CK-counted timing moved.
- `rtl/soc/ddr3_init_seq.v`. No RESET# output. The 200 us of RESET# low is the board's. What is left is JEDEC's power-up step 2, 500 us from RESET# going high to CKE going high, counted from the controller's own reset and the PLL's lock, which should not be earlier than the DRAM's release, since both follow the board's reset (reasoned from the schematic, not measured). Through Part 26 that wait was 500 ns, not 500 us, and nothing checked it.
- `rtl/soc/ddr3_ecp5_top.v`, `wb_ddr.v`, `soc_top.v`, `fpga/soc_fpga.v`, `fpga/ecpix5_top.v`, the probe harness and `formal/ddr3_stubs.v` lose the four ports. The command bus `cmd_cs_ras_cas_we`, which never held a CS, is `cmd_ras_cas_we`. `fpga/constraints/ecpix5_ddr3_throwaway.lpf` is gone, and `BOARD=ecpix5-ddr3` writes a bitstream.

**Test first.** The checkers and testbenches were changed before the controller. `sim/ddr3_model.v` and `sim/ddr3_dq_model.v` lost their `cs_n` (every CK edge is a command slot, so an idle one has to be the NOP) and the model's `reset_n` became the testbench's to drive, as the board's reset circuit drives it: the testbenches play that circuit, with RESET# the complement of their reset. The model's check of the 200 us of RESET# low went, being the board's; in its place is the check that CKE does not rise until 500 us after RESET# went high, counted from the pins. Against the unchanged controller, **12 of the 18 integrated DDR3 simulations I ran fail (1,293 failed checks)**: the second slot of the PHY repeats every command, which `tb_ddr3_phy_phases.v` (no command on two consecutive CK edges, none in the second slot), the address test (a transaction that puts more than one ACTIVATE on the pins) and the protocol checker (an ACTIVATE to an open bank) all see, and the initialisation raises CKE after 200 us. The six that pass check the data window and the mask against the command's cycle, not how often a command reaches the pins.

**What the tests are now.** `sim/tb_ddr3_init.v` counts the init sequence's commands at the pins (five, each on exactly one CK edge) and measures RESET# to CKE (500.04 us). `sim/tb_ddr3_phy_phases.v` decodes a command as anything but 111, so its two existing rules (no command on consecutive CK edges, every command in the first slot) are now the NOP rule. `sim/tb_ecpix5.v` plays the board's reset circuit with `rst_n` and measures RESET# to CKE at the board's pins (500.33 us). `sim/tb_ramboot.v` and `sim/tb_uartload.v`, which run the five CPU-driven DDR3 tests, **instantiated the protocol checker and the DQ model and never read their verdicts**: a protocol or timing violation anywhere in those runs passed. They read them now (and all five still pass: nothing was hiding). Every time limit that counts from power-up moved 300 us. `fpga/synth/ddr3_phy_nop_check.sh`, run by `make synth_check_ddr3`, reads what the synthesis branch of the PHY elaborates to: RAS#, CAS# and WE# are `ODDRX1F` whose second input is the constant 1, the other 20 command pins carry one value in both slots, there is one `ODDRX2F` (CK) and no `OSHX2A`. Nothing simulates that branch, so nothing else would notice a command on that second input.

**Mutation-tested, 27 ways, 25 caught.** In the PHY and the initialisation: the falling-edge NOP removed; a slot with no command carrying the stale command; the second slot's WE# 0 (a ZQ calibration code); its CAS# 0 (a read/write code); RAS# and CAS# swapped; the wait before CKE 500 ns (the old figure), and 499 us (a microsecond short), and 500 ns again at the SoC level (`sim_ddrcheck`, which missed it until `tb_ramboot` read the checker); the address slice shifted by one bit. In the synthesis branch (eight, by `ddr3_phy_nop_check.sh`): each of RAS#, CAS# and WE# with the command in its second slot, WE#'s second slot 0, WE#'s first slot a constant, CKE and an address bit with different values in the two slots, CAS# through an `OSHX2A` again, a second `ODDRX2F` for CK#. And the 32-bit arithmetic back in the nanosecond macro, which both simulators' init tests catch. At the board top (nine, `make sim_ecpix5_ddr3`): the two data lanes swapped, RAS# with CAS#, CKE left open, CK left open, the two data masks swapped, address bits 0 and 1 swapped, bank bits 0 and 1 swapped (all seven caught); the two byte lanes' strobes swapped, and ODT left open (not caught: both strobes carry the same waveform on every write and read, so no simulation can tell them apart, and the controller never raises ODT).

**Found on the way.**
- The nanosecond-to-cycles macro wrapped at 32 bits under Verilator: the old 200 us reset wait was 706 cycles there (28 us), not 5,000, and the checker's own copy of the macro wrapped identically, so the two agreed. Under Icarus, which evaluated that constant wide, it was right. Both macros are 64-bit now, and a 32-bit parameter holds the result.
- `make pnr_probe_ddr3`, a step of CI's `formal` job, required at least one `OSHX2A` in the synthesized PHY, the primitive that carried CS#; it failed on the first run against this PHY. It now requires exactly one `ODDRX2F` (CK), no `OSHX2A` and 23 `ODDRX1F` (RAS#, CAS#, WE#, CKE, ODT, three bank bits, fifteen address bits), which is what the netlist has.
- The ECPIX-5's part was printed as `LFE5U-um5g-85F` in the synthesis script's messages and in the `.bit.target` file; it is `LFE5UM5G-85F`.

**Verified:** `make ddr3_check_sim` (23 Icarus tests, 22 Verilator builds, and the lint); `make synth_check_ddr3`; `make pnr_probe_ddr3`; `make formal` (the controller's proof, depth 250, all twelve cover statements reached); `make soc_fw_check_sim` (10 simulations, the five CPU-driven DDR3 tests and the board-level one among them, both cores); `make pnr_soc_ecpix5_ddr3`, which places, routes and writes the bitstream (below).

**What the build shows.** In-order core, first placement seed, `make pnr_soc_ecpix5_ddr3`: place-and-route finishes, **timing closes (`soc_clk` at 29.13 MHz against 25 asked, the controller's `sclk` at 155.57 MHz)**, and `ecppack` writes `fpga/build/ecpix5_ddr3/ecpix5_top.bit`, 2,117,804 bytes, part `LFE5UM5G-85F`, whose configuration has the clock pad as `OUTPUT_SSTL15D_I`, a differential output. Every port has a pin: the script drops `--lpf-allow-unconstrained` for a board target, so a port left out would be an error. 33,346 `TRELLIS_COMB` (39%), 11,041 flip-flops, the same 82 `DP16KD`, 44 I/O logic cells where Part 15 had 47 (the three outputs for CS#, CK# and A15 are gone), 11 minutes 4 seconds with the synthesis. Part 15 had 32,975 `TRELLIS_COMB`: the controller got smaller and the total did not, and I did not look for the cause; `ABC9`'s results move by a few percent with logic that has nothing to do with them (the index's record of the whole-SoC check). One seed is not a distribution, and no Fmax is claimed.

**What this does not establish.** Anything on a board: the bitstream has never been loaded, and no ECPIX-5 is attached. That the pins of an idle slot are right at the DRAM's setup and hold: RAS#, CAS# and WE# now go out without the `DELAYG` that CK and CS# had, as every other command pin always has. A reset of the controller that is not a reset of the board (a bitstream loaded with the board powered, or `ndmreset` from the debugger) starts the initialisation against a DRAM that was not reset; the header of `rtl/soc/ddr3_init_seq.v` says why that should work when the DRAM was idle and why it is not guaranteed otherwise, and nothing here tests it (the checker assumes the power-up order and would call a second one a violation). Hardware-faithful bursts, the wide core's figure with the controller, timing at the DDR clock: unchanged. (Update, Stage 2 Part 16: the wide core's synthesis figure exists now, and it never was the controller that stopped it.)

**Stage 2 - Wishbone integration, replacing nothing on the ULX3S path.**
A new `rtl/soc/wb_ddr.v`, styled like `wb_sdram.v`/`wb_ram.v`, wired into
`rtl/soc/soc_top.v`'s interconnect as a new address range, not a
replacement for the SDRAM slave - `wb_sdram.v` stays exactly what it is,
selectable by board the same way `CORE=` already selects between core
types. Address decode, `dts/soc.dts`, boot ROM/linker memory-map
constants, and the Sv32 page-table walker's own range all need to reach
the new 512 MB span - a real, checkable list, not a vague "update the
memory map." Caches, atomics, and LR/SC get re-verified against the new
controller's own latency profile, not assumed unaffected. **Done when:**
~~a CPU executes real code out of the new DDR path in simulation - the DDR
equivalent of what `sim_sdramboot` already proves for the current SDRAM
controller - and the full existing verification suite (`make verify`,
`make verify_ooo`) stays green with the new path present but unused by
default.~~ **Closed, in simulation, at this scale.** A CPU fetches and
executes code out of DDR3 (Part 9, `make sim_ddrexec`), the program gets
there through the boot ROM's UART loader (Part 10, `make sim_uartload_ddr3`),
and `make verify` and `make verify_ooo` are green with the path present but
off by default (`DDR3_ENABLE`). The Sv32 walker reading page tables out of DDR3, at both levels, is checked too (Part 11, `make sim_ddrmmutest`). This is Stage 2's bar only: the phase's own
bar (Linux to userspace from DDR on a real ECPIX-5) is not met, and "at this
scale" means 4 KB loads against a behavioural DRAM model, not the real chip. (Until
Part 14 it also meant a 256 MB lane-0 window; the window is the part's whole 512 MB now.)

**Decided: 16-byte burst, not byte-granular** - the maintainer's own
choice, made now, closing the question this file has named as open since
the Part 14/15 survey. Every DDR3-side transaction moves a full,
16-byte-aligned block, matching a real x16 BL8 burst's own transfer
granularity, rather than one Wishbone word at a time. Part 1 below is the
first real step.

**Update, Part 1: `rtl/soc/wb_ddr.v` exists and passes its own standalone
proof - not yet wired into `rtl/soc/soc_top.v`.** A Wishbone B4 classic
slave, one 16-byte block held open at a time (the same "one open row, not
four" simplification `wb_sdram.v`'s own header already reasons about, one
level down: one open *block* here). Reads that miss the open block issue
16 real, sequential single-byte `read_req` calls to the existing, entirely
unchanged `rtl/soc/ddr3_ecp5_top.v` to fill it; writes go straight through
immediately (a lone byte write, proven safe by Part 22's own DM masking
regardless of how many separate calls target nearby columns) and update
the cached copy if it is resident, so a later read of the same block never
needs a redundant re-fill. This needed no change to Stage 1's own files at
all: `sim/ddr3_dq_model.v`'s own `find(bank,row,col)` is a plain, linear
lookup, so 16 independent single-byte controller calls already address 16
independent real locations.

Standalone testbench (`sim/tb_wb_ddr.v`), against the same real protocol
checker and per-location DQ memory every Stage 1 integration test already
uses: a store-then-load round trip through a real miss/fill; a second
store to the same open block (a cache-hit-path store, not a re-fill) with
the first word confirmed unchanged; a store to a different block evicting
the first, and the first block's own two words both confirmed to survive
a later re-fill exactly as written; and a partial-`wb_sel` store changing
only the selected bytes. `make sim_wb_ddr` and `make verilator_wb_ddr`
both pass; `make lint-rtl-ddr3` lints `wb_ddr` as its own top-module
alongside `ddr3_ecp5_top`.

Two real bugs found and fixed before this passed clean, both a real
accept-pulse-then-busy race, not a design defect: a state that checked
`!write_busy`/`!read_busy` in the very cycle after issuing the request
pulse saw the *old*, still-low busy (busy itself only rises a cycle later)
and wrongly concluded the call was already done - fixed with an explicit
wait for busy to rise before waiting for it to fall, the same two-phase
wait `sim/tb_ddr3_cmd_seq.v`'s own hand-written stimulus already uses
driving this exact interface. Mutation-tested: removing the cache-coherency
update in the store path (`block_buf` left stale after a hit-path store)
was caught by two independent checks - the immediate re-read of the
just-updated word, and the partial-`wb_sel` check - while a check relying
on a later eviction-and-re-fill (which re-reads from the real DQ memory
model, bypassing the broken update path entirely) did not catch it,
confirming the direct-hit checks are the ones actually exercising that
code path, not the eviction ones.

**What this does not establish.** Not wired into `rtl/soc/soc_top.v` -
address decode, `dts/soc.dts`, boot ROM/linker constants and the
page-table walker's own range are all still ahead, and none of Stage 2's
own "Done when" bar (a CPU executing real code from DDR) is met yet (it was
met by Part 9, not by Part 2).
Real capacity today is 256MB, not the plan's own 512MB: lane 1 does not
carry real data (Part 24/25 wired its own calibration only), so this
module's own address space is lane 0 alone - 8 banks x 32768 rows x 1024
columns x 1 byte. Doubling that needs lane 1 wired for real data transfer,
separate, later work. The real, still-open "data path is not yet
hardware-faithful" Known Defect is unchanged: a real burst moves 16 real
bytes in one electrical transaction, and this design still moves them as
16 separate ACT+WR/RD command sequences - correct, and now genuinely
block-granular from the Wishbone side, but not a claim of hardware-faithful
burst timing, and not required by this stage's own bar. No caches, atomics
or LR/SC re-verification attempted (nothing reaches this module through
the interconnect yet to re-verify against). `make verify_ooo` was not run
for this part - grep-confirmed that no CPU/SoC/board build file references
`rtl/soc/wb_ddr.v`.

**Update, Part 2: wired into `rtl/soc/soc_top.v` for real, and a real CPU
program reaches it - through the actual interconnect, not a testbench
tap.** A new slave (`S_DDR3`, index 12, `NUM_SLAVES` 12 to 13), base
`0xA0` mask `0xF0` (`0xA0_00_0000`-`0xAF_FF_FFFF`, the real 256MB
Part 1 already established) - `rtl/soc/wb_ddr.v`'s own `wb_cyc`/
`wb_stb[S_DDR3]`/`wb_we`/`wb_adr`/`wb_dat_w`/`wb_sel`/`wb_dat_r`/`wb_ack`
into the shared bus, its real `ddr3_*` board pins passed straight through
as new `soc_top.v` ports (a real `inout`, unlike SDRAM's own o/oe/i split
- `ddr3_ecp5_top.v` already puts real `BB` tristate pads on these pins
itself, Part 21, so there is nothing left for a board wrapper to split).
Its own calibration/debug outputs are not exposed as `soc_top.v` ports -
nothing else there needs them, and a testbench can still reach them by
hierarchical reference, the same as SDRAM's own equivalent signals.

**A real regression caught before it ever reached a synthesis run, by
re-reading this project's own tooling rather than assuming an
unconnected `inout` is free.** Unlike every existing slave, `wb_ddr.v`
cannot simply be instantiated unconditionally: its own real `BB`
tristate pads (inside `ddr3_ecp5_top.v`, Part 21) need a real package pin
the moment real synthesis is attempted, and `fpga/synth/synth_ecp5.sh`'s
own header already documents that every board target except the bare,
pinout-free default drops `--lpf-allow-unconstrained` specifically so an
unplaced real pin is a build error, not a silently invented placement -
and no existing board's own `.lpf` has ever named a `ddr3_*` pin, since
ECPIX-5's own real pins (`fpga/constraints/ecpix5_ddr3.lpf`) exist only
for `fpga/ecpix5_ddr3_probe.v`, a dedicated, DDR3-only top, not for
`fpga/ulx3s_top.v` or `fpga/soc_fpga.v`. Wiring `wb_ddr.v` in
unconditionally, as first drafted, would have made every existing real
board build fail to place a primitive with nowhere to go - found by
re-checking `synth_ecp5.sh`'s own reasoning immediately after wiring the
slave in, not by running a real synthesis and watching it fail. Fixed
with a new `` `DDR3_ENABLE`` compile-time gate, matching `CORE_OOO`'s own
opt-in shape: undefined (every existing board, every existing test),
`rtl/soc/wb_ddr.v` is never instantiated at all - so `ddr3_ecp5_top.v`'s
own body, `BB` pads included, is never elaborated either, regardless of
whether its source file is on the compiler's own command line - and the
slave answers its own address range immediately with zero data rather
than leaving the bus hanging, the same "unmapped space acks with zeros"
behaviour `rtl/soc/wb_ram.v`'s own header already documents. Only
`make sim_ddrcheck` (below) defines it. `make lint-rtl-soc` now lints
both configurations - the disabled stub every existing board still
builds, and the enabled slave - not just the one this part happened to
write first.

**A real, previously-invisible bug found by this integration alone,
before any test even ran:** `rtl/soc/wb_sdram.v` defines its own
`` `NS2CYC`` macro and never `` `undef``s it; `rtl/soc/ddr3_init_seq.v`
and `rtl/soc/ddr3_refresh_ctrl.v` each separately define the identical
name. Nothing before this part ever compiled `wb_sdram.v` and any DDR3
file together in one Verilog compilation unit (Stage 1's own
`make lint-rtl-ddr3` never included `wb_sdram.v`; `make lint-rtl-soc`
never included any DDR3 file) - `rtl/soc/soc_top.v` now does, and
`make lint-rtl-soc` caught the collision immediately
(Verilator `REDEFMACRO`). Harmless today by pure file-order luck (each
file's own use of the name completes before the next file's redefinition
touches it), but exactly the reordering-fragile latent bug a `` `define``
with no matching `` `undef`` always risks - fixed by renaming the DDR3
family's own macro to `` `DDR3_NS2CYC`` and giving `ddr3_refresh_ctrl.v`
the `` `undef`` it was also missing.

**A minimal, directed CPU-issued proof, not a sweep - `software/soc/
ddrcheck.c`, run through `sim/tb_ramboot.v`, the same shared
preloaded-RAM harness `sdramcheck.c` already uses (`make sim_ddrcheck`,
mirroring `make sim_sdramcheck` exactly).** Deliberately not a memory
sweep: every miss here costs a real 16-byte block fill (16 sequential
single-byte controller calls, ~20 cycles each), so `sdramcheck.c`'s own
hundreds-of-KB coverage sweep would be prohibitively slow against this
stage's own current fidelity - a handful of directed word/byte accesses,
mirroring `sim/tb_wb_ddr.v`'s own cases exactly but issued as real
`sw`/`lw`/`sb`/`lb` instructions through `cpu_wb.v` and the real
interconnect this time: a store-then-load real miss/fill; a second word
in the same open block (a cache-hit-path store); a different block
evicting the first, both of the first block's own words confirmed to
survive a later re-fill; and a single-byte store/load proving the
interconnect's own `wb_sel` plumbing reaches this slave correctly.
Passed clean on the first real run, on both `CORE=inorder` and
`CORE=ooo`.

**Mutation-tested the wiring itself, not just re-running Part 1's own
proof.** Feeding `S_DDR3` a wrong `s_base` (`0xB0` instead of `0xA0`)
makes every check fail, reading back `0x00000000` for every access - the
interconnect's own unmapped-address behavior (`rtl/soc/wb_ram.v`'s own
header: unmapped space acks with zeros) - confirming this test genuinely
exercises real address decode, not an accidental pass through some other
slave. Reverted; clean re-run confirmed.

**What this does not establish.** `dts/soc.dts`, boot ROM/linker
memory-map constants and the Sv32 page-table walker's own range are all
still untouched - this proves a bare-metal, physical-address, MMU-off
program reaches DDR3 through the real bus, not that Linux or any
paged/OS-level caller can. No caches, atomics or LR/SC re-verification
attempted - `ddrcheck.c` is single-hart and touches no cached path
(`HART_DCACHE_ENABLE` is unaffected by this slave existing). Real
capacity is still 256MB, and the data path is still not hardware-faithful
per-beat, both unchanged from Part 1. `make verify`/`make verify_ooo`
**were** both run this time and stayed green - unlike Part 1, this part
changes `rtl/soc/soc_top.v` itself, a real CPU/SoC file every existing
consumer of `$(SOC_RTL)` now compiles against, so skipping either gate
would not have been honest.

**Update, Part 3 (an attempt, and a real, unresolved finding - not a
shipped feature): a paged access to DDR3 hangs, and the cause is not yet
found.** ~~Stage 2's own "Done when" bar was already met by Part 2 - a CPU
executing real code from the new DDR path in simulation, physically
addressed.~~ **Corrected in Part 9:** Part 2 ran from block RAM and used DDR3
only as data, so it had not met that bar; Part 9 did. This part went further, uninvited by that bar, to check
whether a *paged* (Sv32 MMU-on) caller can reach DDR3 too, mirroring
`software/soc/mmutest.c`'s own proof that the page-table walker reaches
SDRAM. `software/soc/ddrmmutest.c` puts the root table itself in DDR3 -
sparse, not a copy of `mmutest.c`'s own exhaustive sweep: only the two
megapages the test actually walks into (the code/stack/result-word
megapage, and one genuinely translated - not identity - megapage onto a
real DDR3 physical frame) are ever written; the other 1022 root-table
entries are never touched and never walked into either.

**What was found.** The physical-addressing checks before `satp` goes
live all pass: the DDR3 window is reachable, both PTEs read back exactly
as written. After `csrw satp`/`sfence.vma`/`mret` into S-mode, the run
hangs - no further output, no trap ("UNEXPECTED TRAP" is not printed;
M-mode fetch is always untranslated, so the trap handler itself does not
need paging to run, and it never runs), until `sim/tb_ramboot.v`'s own
`#400_000_000` (400,000,000 ns, 10,000,000 cycles at 40ns/cycle) timeout.
A temporary hierarchical trace
(`DUT.CPU.itlb_*`/`DUT.iptw_*`/`DUT.PTW.*`/`DUT.DDR3.DDR.*`, added and
removed for this investigation, not shipped) showed the instruction-side
walker's own read of the code/stack megapage's PTE from DDR3 completing
successfully (`iptw_gnt` arrives, `itlb_resolved` goes high) - and
`rtl/soc/wb_ptw.v`'s own `busy` flag then staying asserted, with its own
latched `adr_r` reading as an undefined (`x`) address, for effectively
the rest of the run (over 97% of a 1,052,423-line, ~42ms trace). Not a
fault, not a data-correctness error - a real hang, reproduced identically
on every attempt.

**Root cause not yet found, named plainly rather than guessed at.**
Direct inspection cleared two real candidates rather than assuming them
innocent: `rtl/soc/wb_ptw.v`'s own arbiter holds `busy`/`wb_cyc`/`wb_stb`
until `wb_ack`, with no counter and no assumption about how long that
takes (its own header: "it just waits longer for the grant"); the
walker's own default `s_we = 1'b0` for its read-only requests is set
unconditionally in `rtl/soc/wb_interconnect.v`, not left stale from a
previous master. Its own bus-lock mechanism (`lock`/`lock_w` in the same
file) clears only on `fin_ack`, with no timeout either. All three read as
correct for arbitrary latency, by inspection - and DDR3's own real,
much-longer-than-SDRAM latency is the only genuinely new variable this
exact combination (a page-table walker reading a PTE from it) had ever
been exercised against. Whether the actual defect is a narrower race
this reading did not reach, or something the DDR3-specific latency
merely makes practically reachable for the first time on hardware that
was always capable of it, is exactly what is not yet known.

**Filed as a Known Defect, not shipped as a passing test.**
`software/soc/ddrmmutest.c` and its own `make sim_ddrmmutest` build exist
in the tree as a real, working reproduction - deliberately **not** added
to `make verify` and **not** `.PHONY`, since it currently hangs rather
than fails quickly, and a hanging target inside the standard gate would
cost every future run real wall-clock time for a known, already-recorded
result. See the Known Defects section below for the standing entry.

**What this does not establish.** Nothing about Stage 2's own "Done
when" bar, which Part 2 already met and this part does not touch. Not a
claim that paged DDR3 access is impossible - only that this specific
attempt hangs, and why is not yet known. `dts/soc.dts` and the boot
ROM/linker's own real memory-map constants remain untouched either way -
this was a bare-metal, hand-built page table, not an OS-level path.

**Update, Part 4: Part 3's own central claim was wrong - re-measured with
a cleaner trace, corrected in place rather than left standing.** Part
3's own "the walker's `busy` flag stays asserted with an undefined
address for the rest of the run" came from a hierarchical trace captured
from a process killed mid-write (`kill -9` against a still-writing log,
to bound investigation time) - the trace file was real but truncated,
and reading a stale tail of it as the final state was the actual mistake,
not anything in the RTL. Redone with a print-on-*change* trace (one line
per real transition, not one per cycle) run to genuine completion this
time: `rtl/soc/wb_ptw.v` is not stuck at all. Multiple real PTE reads
from DDR3 complete correctly, on both the instruction and data walker -
`iptw_gnt`/`ptw_gnt` both arrive with real, valid data, `adr_r` holds a
real address throughout (`0xA0000800`, `root[512]`'s own byte), never an
undefined one. Execution genuinely enters `s_mode_main` (real, advancing
`pc` values through its own compiled code, a real stack growing at
`mem_addr_ex` near `BOOT_STACK_TOP`) - directly contradicting Part 3's
own claim that the walker itself never lets execution past the M-to-S
transition.

**The real hang is later, and does not touch the page-table walker or
DDR3 at all in its own stuck state.** `s_mode_main`'s own first message
("fetch translated via the RAM megapage...") never reaches the UART - the
literal text never appears in the decoded serial output, confirmed by
grep against the full capture, not inferred - even though `pc` clearly
progresses through addresses in that function's own range beforehand.
No walk into the UART's own megapage (`0x04000000`, index 16 - also
never mapped by this test's own sparse table) is ever attempted either,
ruling out "stuck retrying a fault into an unmapped UART page" as the
mechanism. Wherever execution is actually looping, it needs no new
translation and touches neither DDR3 nor the walker - which also means
Part 3's own Known Defect entry, filed against `wb_ptw.v`, named the
wrong suspect.

**Known Defect corrected below, not left naming a walker bug that direct
re-measurement did not confirm.** The entry now describes what is
actually established: paged access to DDR3 hangs, reproducibly, with the
walker and DDR3 both cleared as the immediate cause by a completed trace
- not "the walker gets stuck," which was itself an artifact of reading
an incomplete file. Root cause remains open.

**Update, Part 5: execution proceeds much further than Part 4 observed -
real UART register accesses, from S-mode, with translation bypassed for
them - and the trace stops there, deliberately, before claiming a final
resting state.** A third trace, watching `pc` and the stall/access
signals unconditionally rather than only the MMU/walker ones Part 4
already cleared, shows `s_mode_main` continuing well past where Part 4's
own trace went quiet: real, advancing `pc` values reach code that
repeatedly touches `0x0400_0014` (`UART_LSR`) and `0x0400_0000`
(`UART_THR`/`UART_RBR`) - exactly the registers `put_char`'s own
transmit-busy-wait polls. Part 4's own "no walk into the UART's own
megapage is attempted" is not wrong, but incomplete: it did not run far
enough to see the UART even get touched.

**A genuinely new, previously-unexercised interaction, found by reading
`rtl/cpu_core.v` directly rather than assumed: these UART accesses reach
the bus with `need_translate=0` - untranslated - despite genuinely
running S-mode code.** `need_translate = is_mem_op_now && !mem_misaligned
&& satp_mode && (effective_priv_for_data != PRIV_M)`, and
`effective_priv_for_data` is confirmed (by the same formula) to track the
real current privilege whenever `mstatus.MPRV` is clear, which it is
here. Untranslated access to `0x0400_0000` is not itself wrong - the
address is its own physical address either way, so no translation
ambiguity exists - but it means **`software/soc/mmutest.c`, the only
prior proof this project had that a page-table walk works at all, never
printed a single character from S-mode code with paging on**: its own
`report()` calls all run from `main()`, in M-mode, before `satp` is ever
written. This may be the first time any test in this project has asked
S-mode code to reach the UART with paging active - a real, previously
untested combination, and a plausible place for a real bug to have been
sitting invisible until now.

**This trace was also deliberately truncated (killed, to bound
investigation time) - stated here up front, not discovered as a mistake
afterward the way Part 3's was.** The last observed `pc` (`0x80001198`)
was still advancing, not obviously stuck at one instruction, when the
process was stopped - so this update does **not** claim to have found
the actual final resting state, only that execution reaches further,
real code than previously shown. Whether `put_char`'s own busy-wait ever
sees its own transmit-empty bit go true through this untranslated path,
and whether that path behaves any differently from an ordinary M-mode
MMIO access, is the next real lead - not yet checked.

**Update, Part 6: the busy-wait's own condition does eventually change -
not a value stuck forever - and a real attempt to distinguish "slow" from
"hung" did not settle the question either.** A trace watching the actual
value read back from `UART_LSR` (not just its address) shows `put_char`'s
own loop at one fixed `pc`, reading `0x00000000` (not ready) on every
iteration, for roughly 1.3 million cycles - then reading `0x00000060`
(bits 5 and 6 set, both real transmit-empty flags on a 16550) and
correctly exiting the loop to proceed toward a `UART_THR` write. That
flatly contradicts reading this as "the condition is wedged on one
value forever" - it genuinely changes, and the branch genuinely takes the
exit path when it does.

**A real candidate hypothesis was checked directly and ruled out, not
assumed innocent.** `rtl/soc/cpu_wb.v`'s own D-cache gates caching on
`dc_cacheable = DCACHE_ENABLE && ((dmem_addr[31:24] == 8'h80) ||
(dmem_addr[31:24] == 8'h00))` - UART's own address (`0x04...`) is
excluded regardless of whether the access was translated, so a stale
cached read is not the mechanism, whatever else this untranslated-MMIO
path turns out to involve.

**~1.3 million cycles for one busy-wait is nowhere near what this
testbench's own real UART timing should need** (`CLKS_PER_BIT` is 4 in
`sim/tb_ramboot.v`, so a full byte - start, 8 data, stop - is on the
order of 40 cycles, not over a million) - so "just legitimately slow"
does not explain this well either, without more evidence.

**A direct test of "does it just need more time" did not resolve the
question, and is reported as inconclusive rather than stretched into a
conclusion it does not support.** `sim/tb_ramboot.v`'s own timeout was
raised 10x (10,000,000 to 40,000,000 cycles) for one throwaway run, not
shipped. It did not complete within 113 minutes of real CPU time - far
longer than a mere 4x cycle-count increase should cost on this machine
(the traced runs above covered tens of thousands of real cycles in under
a minute of CPU time, even carrying heavy per-cycle `$display` overhead
the extended-timeout run did not have) - and was stopped there rather
than left running indefinitely against this investigation's own time
budget.
Two real explanations remain open and undistinguished: a single
~1.3M-cycle busy-wait repeating once per character of a ~68-character
message would alone exceed even the extended budget; or whatever state
this reaches costs the simulator disproportionately more per real cycle
to evaluate than ordinary execution does, which would itself be worth
finding the mechanism for. Root cause still not found. **Banked here** -
Parts 3 through 6 are a real, honest record of what has and has not been
established, and the next step (measuring `UART_THR` writes directly,
named in the memory note this investigation kept) remains available, but
Stage 2 has other, unblocked items of its own to close first.
(Update, Part 11: closed. The hang was the test's own; see below.)

**Update, Part 7: atomics against DDR3, real for the first time.**
Stage 2's own plan named this explicitly - "Caches, atomics, and LR/SC
get re-verified against the new controller's own latency profile, not
assumed unaffected" - and nothing before this part had ever issued an
AMO or an LR/SC pair against `rtl/soc/wb_ddr.v`; Part 2's own proof was a
plain load/store round trip. `software/soc/ddratomics.c` mirrors
`software/soc/main.c`'s own `test_amo_rmw`/`test_lr_sc_success`/
`test_lr_sc_failure` exactly - same instructions, same expected values -
against a real DDR3 physical address instead of RAM. The real question
isn't new atomics semantics, it's whether an AMO's own read-modify-write,
held together by `rtl/soc/wb_interconnect.v`'s own `amo_wrphase` lock
(not anything DDR3-specific), survives a slave whose own read and write
transactions each cost far more real bus cycles than RAM's ever did -
up to ~320 cycles for a block-fill miss, ~80 for a four-byte
write-through, against RAM's single-cycle response.

Passed clean on the first real attempt, on both `CORE=inorder` and
`CORE=ooo`: `AMOADD`/`AMOSWAP` read-modify-write correctly; `LR`/`SC`
succeeds when uninterrupted; `SC` correctly fails when an intervening
store breaks the reservation. Mutation-tested: corrupting one of the
test's own expected values (`123` to `124`) was caught immediately,
confirming the check itself is real, not vacuous.

**What this does not establish.** This is single-hart - the reservation
monitor's own cross-hart exclusion is untouched by this part, matching
where Phase 13's own cross-hart atomicity work already stands
independent of DDR3. Real capacity is still 256MB and the data path is
still not hardware-faithful per-beat, both unchanged since Part 1.
`make verify`/`make verify_ooo` were both run, since `sim_ddratomics` is
now gated inside `verify` itself (unlike the paging investigation, which
stays deliberately outside it; Update, Part 11: it is inside it now) - no RTL changed, but a new test entering
the shared gate graph gets the same confirmation any other addition to
it would.

**Update, Part 8: a `dts/soc.dts` node for DDR3, gated the same way the
RTL already is.** Stage 2's own plan named this too - "Address decode,
`dts/soc.dts`, boot ROM/linker memory-map constants... all need to reach
the new... span." Address decode (Part 2) and the C-side constants
(`DDR3_BASE`/`DDR3_SIZE`, Part 1's own `software/soc/soc.h` addition)
were already done; this closes the `dts/soc.dts` piece, the last one
Part 6's own investigation didn't already cover.

A new `memory@a0000000` node, guarded by `#ifdef DDR3_ENABLE` - not
unconditional, the same "over-declaring hands a kernel addresses that
decode to no slave" hazard the SDRAM node's own header already names,
now doubly true since no existing board or OpenSBI/Linux image builds
with `DDR3_ENABLE` at all. A new, separate build target,
`make dtb_ddr3`, rather than an env-var toggle on the existing `dtb`
target - the same "a different build product, not a runtime flag"
precedent `software/soc/sdramfull.elf` already set - builds
`dts/soc_$(CORE)_ddr3.dtb` with `-DDDR3_ENABLE` passed to the
preprocessor, round-trips it back to source (the existing sanity check
every `.dtb` build already has), and greps the round-tripped source for
the new node by name, so a regression that silently drops it fails loud.

**Confirmed the default path is genuinely untouched, not just
assumed.** Rebuilding `dts/soc_$(CORE).dtb` (no `DDR3_ENABLE`) produces a
byte-identical file to the one already in the tree - `git status` shows
no diff after the rebuild - and a direct check confirms the new node is
genuinely absent from that build, not merely unlisted.

**What this does not establish.** No existing `sbiimage`/`linuximage`
target builds with `DDR3_ENABLE` - nothing yet proves OpenSBI or Linux
actually parses this node and does anything useful with it, only that
the dts pipeline itself (preprocessor + `dtc`) accepts it. That is
separate, later work, and probably downstream of the banked paging
investigation in practice, since Linux's own use of a memory region
goes through Sv32. (Update, Part 11: that investigation is closed and a paged access to DDR3 works in simulation; Linux from DDR3 is still ahead.) No RTL changed.

**Update, Part 9: a CPU fetches and executes instructions from DDR3,
which is what Stage 2's "Done when" actually asks for.** Parts 2 and 7 ran
from block RAM and used DDR3 as data memory, so the claim made in Part 3
(and in this phase's opening) that Part 2 had met the bar was wrong, and is
corrected above. `software/soc/ddrexec.c` (`make sim_ddrexec`, in `verify`)
links four small functions to run at `0xA0000000` (a new `.ddrtext` section
in `software/soc/link_ram.ld`, empty and so dropped in every other program;
`ddratomics.bin` and `ddrcheck.bin` are byte-identical before and after),
copies them into DDR3 with ordinary stores, executes `fence.i`, and calls
them. It checks that the code runs at a DDR3 address (an `auipc`), and that
a loop with a nested call and a return, run cold and then warm in the
instruction cache and with a different trip count, gives the same result as
the same code running from RAM.

It passed on the first run. To check it can fail, the copy was changed to
write zeros: the run then traps with an illegal instruction at `0xA0000070`,
inside DDR3, and times out with no result word, so the test does depend on
what is in DDR3. (A first attempt at that mutation did not compile and
proved nothing; it was redone.) `make verify` passed (exit 0, 7 formal
proofs, riscv-tests 82/0/2 xfail, Linux boot to userspace). `make verify_ooo` also passed (exit 0, riscv-tests 82/0/2 xfail, co-simulation 84/84, 7 formal proofs, Linux boot to userspace), with `DDR3 EXEC TEST PASSED` on both cores.

**What this does not establish.** The program is a few hundred bytes, so the
fetch path is exercised for a handful of 16-byte blocks, not a large image
or a full-part sweep. Nothing loads DDR3 except the program itself: there is
no boot ROM or UART loader path to DDR3 (Part 10 adds the UART loader), so
a `sim_sdramboot` equivalent (reset straight into DDR3) is still not done. Paged execution out of DDR3
is still blocked on the banked investigation above (Update, Part 11: no longer blocked; Part 12: tried, and it works). No hardware: this is
the simulation DQ model only.

**Update, Part 10: the boot ROM's UART loader can put a program into
DDR3, and getting there found a real bug in `wb_ddr.v`: a request made
before calibration was silently dropped and acknowledged anyway.** DDR3 comes up empty on a board, like SDRAM, so the loader is the
only way a program gets there. `software/soc/bootrom.c`'s `uartload_addr_ok`
accepted block RAM and SDRAM only; built with `-DDDR3_ENABLE` it now accepts
`DDR3_BASE`..`DDR3_BASE + DDR3_SIZE` too. It is a compile-time choice, not
always on, because on a board without DDR3 that range is the tied-off slave
and accepting the header would write nowhere and then jump into zeros, the
failure the check exists to prevent. `make sim_uartload_ddr3` (in `verify`)
builds that ROM (`bootrom_$(CORE)_ddr3`), links `software/soc/uartprog.c`
with `-DUARTPROG_DDR3` at `0xA0000000` (`software/soc/link_ddr3.ld`, a twin of
`link_sdram.ld`, with its stack and data in DDR3 as well), and reuses
`sim/tb_uartload.v` with `DDR3_ENABLE` for the DDR3 model.

Result: the 4,192-byte image goes over the UART into DDR3, the CRC32 matches,
the program runs from DDR3 and reports that it is there, that its table
arrived intact and that block RAM still works, in 931,529 cycles.
Fail-first: the same testbench with the stock ROM is refused
(`0xA0000000 is not inside RAM or SDRAM`, a NAK) and fails, so the ROM change
is what makes the load possible. The first run also hit a model limit, not a
loader bug: `sim/ddr3_dq_model.v` stores one byte per location with a default
`DEPTH` of 1024 and printed "store full - raise DEPTH"; this test raises it to
8192 for itself, and since every access scans the list that is as small as it
can be.

**The bug.** The first version of this test passed on the in-order core and
hung on the wide one (`make verify_ooo`: no instruction ever retired in
DDR3, 77 minutes of simulation and the testbench watchdog still had not
fired). Measured, in order: all 4,192 image bytes reached `wb_ddr.v` with the
right address and data (checked against the image); yet the model held 4,191
locations, and the missing one was column 0 of row 0, the first byte ever
written (`0x13`), on both cores; the first `write_req` pulse went out at
cycle 2,797 while `init_ready` rose at 5,571 and `calib_done` at 5,601. The
controller holds its command sequencers in reset until `calib_done`, so the
pulse was lost, and `wb_ddr.v`, which never looked at `calib_done`, waited
for a `write_busy` that calibration's own activity then raised, and
acknowledged a store that never happened. The first instruction word of the
loaded program therefore had unknown bits. The in-order core got away with
it; the wide core's pipeline took the unknown into its control state
(`retire_fire` unknown) and stopped.

Every earlier DDR3 test touched DDR3 long after calibration, so none of them
could see it: any access in the first ~5,600 cycles after reset was
affected, reads included. Fix: `S_IDLE` accepts a request only when
`calib_done` is high, so an early access waits instead of being lost.
`sim/tb_wb_ddr.v` gained a store issued right after reset release, with a
monitor that latches any acknowledgement while `calib_done` is low. Fail
first: against the unfixed module that case reads back `0x0badf0xx`, the same
lost low byte; with the fix it reads `0x0badf00d` and the monitor stays
clear. With the fix `make sim_uartload_ddr3` passes on both cores
(813,330 cycles on the wide core, 931,325 in-order).

**What this does not establish.** Only the ROM variant built for simulation
exists; no board build uses `-DDDR3_ENABLE` or the ROM's embedded device tree
with a DDR3 node, so wiring the loader into a real `BOARD=ecpix5` build is
still ahead. (Update, Part 15: `BOARD=ecpix5-ddr3` builds with `-DDDR3_ENABLE` and this ROM, to place-and-route and, since Part 27, a bitstream; the
device tree in the ROM is still the ordinary one.) The image is 4 KB: this is the protocol and the write path, not a
large transfer, and the 8192-deep model would not hold one. Nothing here is
on hardware.

**Update, Part 11: the paged-access hang is closed, and it was never the walker, the D-cache or the UART: the test never mapped
the UART.** `make sim_ddrmmutest` passes on both cores and is in `make verify`. The change is to the test program
(`software/soc/ddrmmutest.c`) and the Makefile; no RTL changed.

**What was wrong.** The program wrote two root-table entries, the RAM megapage (index 512) and the DDR3 megapage (index 256), and
left the other 1,022 alone, on the reasoning that S-mode would never touch them. But `s_mode_main` prints through the UART, whose
register block is at `0x0400_0000`, and a load of `UART_LSR` at `0x0400_0014` walks root-table index 16: a DDR3 location nothing
had ever written. `sim/ddr3_dq_model.v` returns `x` for a location that was never written, on purpose, and `rtl/mmu.v` goes from
its first-level read to a second-level read unconditionally (`S_L1W` always goes to `S_L2`), forming the second-level address from
the first-level entry whatever that entry is. With `x` for the entry, the address was `x`, the interconnect's decode and the
walker's grant were `x`, and `if (ptw_gnt)` was never true.

**How it was measured**, in the order it was found. A passive monitor (scratch, not committed) that reads the CPU's CSRs, the two
walkers' handshakes and the data MMU's registers, run on the unmodified program:

- `mret` into S-mode at cycle 26,759. The instruction walker reads root[512] at `0xA0000800` and gets `0x200000CF` (a valid
  megapage leaf: V, R, W, X, A, D); the data walker reads the same entry. Both then make a second read, at `0x80000004` and
  `0x8000003C`, which is the leaf's frame plus `vpn0 * 4`, and get zeros: the redundant read described below.
- Cycle 27,279: the data walker reads root[16] at `0xA0000040` and gets `xxxxxxxx`.
- Sampled every 20,000 cycles from cycle 40,000 to at least 180,000, the data MMU is in state 3 (`S_L2`) with `pte1_r` and
  `ptw_addr` both `xxxxxxxx`, `ptw_req` high and `ptw_gnt` `x`, the CPU's program counter held at `0x80001198` by
  `mmu_wait_stall`. No trap, no further walker read, no UART write (the passive trace shows none) in all that time.
- The prediction that followed was tested: with the UART mapped, the same run reaches the end. The walks are now the ones the
  program says it makes: root[16] at `0xA0000040` is `0x28000801` (a pointer to the level-2 table at `0xA0002000`), the level-2
  entry there is `0x010000C7` (a 4 KB leaf for the UART's page: V, R, W, A, D, no X), and the DDR3 megapage at root[256]
  (`0xA0000400`) is `0x280000CF`.
- **Fail first, and back.** The final program with only the UART mapping taken out again reproduces the hang identically: the same
  walker reads, then `S_L2` with `x` at every 20,000-cycle sample up to the 1.46 million at which it was stopped.

**The fix** is in the program, which now maps what S-mode touches: root[16] is a pointer (`PTE_V` alone) to a level-2 table at
`DDR3_BASE + 0x2000`, whose entry 0 is a 4 KB leaf for the UART's page, identity (virtual equals physical, so `soc.h`'s registers
work unchanged). That also makes this the first test to walk a DDR3-resident table two levels deep; before, every walk of a
DDR3 table ended at a megapage leaf. Two read-back checks for the new entries joined the others.

**Result.** `DDR3 PAGED-ACCESS TEST PASSED` and the result word `PASS`, on the in-order core (the run ends at 2,179,500 ns of
simulated time, in `make verify`) and on the wide core (2,271,900 ns, in `make verify_ooo`). The store through a translated DDR3 page and the load that reads it back
both work. `sim_ddrmmutest` is in `verify` beside `sim_ddrexec`; it is not in CI, like the other DDR3 tests that run the whole SoC. (It is now, with them: `soc_fw_check_sim`, 2026-10-17.)

**What this changes in the account.** Parts 3 to 6 chased the walker (Part 3, wrongly), the D-cache and the UART's timing, and
ended on two explanations that were "open and undistinguished". Neither is supported. The simulator is not expensive per cycle in
the stuck state: Icarus runs this SoC at about 10,000 cycles a second, so the 40-million-cycle run of Part 6 needed more than an
hour of wall-clock to do nothing. And Part 6's observation of `UART_LSR` reading `0x00000000` for 1.3 million cycles and then
`0x00000060` does not match what the monitor sees at this tree: no `UART_LSR` load completes after the first console access,
because the walk for it never ends. What those traces were reading is not known.

**Found on the way, and not fixed: the walker's second-level read is unconditional.** After a first-level entry that is a leaf
(a megapage) or invalid, `rtl/mmu.v` still reads `{PPN, 12'b0} + vpn0 * 4` as if the entry were a pointer, then ignores the
answer (`l1_conclusive` selects the leaf's result). Seen above three times at megapage leaves (`0x80000004`, `0x8000003C`, and
`0xA0000004`, which returned `x` and was correctly ignored). Four consequences, none of them measured beyond the reads
themselves: it costs a bus read per megapage walk; for a megapage whose frame is a device it reads device registers (a read of a
UART receive register or a PLIC claim register has side effects); for an invalid entry the address comes from bits software
controls, and in simulation `x`; and in hardware that is a wild read, not a hang, because `rtl/soc/wb_interconnect.v`
acknowledges an address that decodes to no slave with zero data. Skipping the read when the first-level entry is conclusive is
the spec's walk and would be faster, but it changes the length of every megapage walk and so every cycle count in these
documents that includes one, which is why it is recorded under Known defects and not done here.

**What this does not establish.**

- Nothing is on hardware: this is the simulation DQ model, and a board's unwritten DDR3 holds arbitrary bits, not `x`.
- Paged *execution* out of DDR3 (instruction fetch through the instruction MMU from a DDR3 frame) is no longer blocked by this
  investigation, but has not been tried. Nor has a page *fault* through a DDR3-resident table with defined contents (an
  invalid entry written as zero). (Update, Part 12: both are tested now, and the fault test found a bug.) The program still
  reads an unwritten entry as `x` if it ever walks one, which is the right outcome for a test that touches memory it never
  initialised.
- The cost of the redundant read in cycles, for Linux or anything else, was not measured.
- One run per core.

**Update, Part 12: execution out of DDR3 and page faults through DDR3 tables are tested, and testing them found a real bug in the
in-order core: `mtval` after a page fault that needed a walk was not the faulting address.** Part 11 left two things untried;
`software/soc/ddrmmutest.c` now does both, on both cores, in `make verify`.

**What the test adds.**

- **Execution.** A routine of nine instructions (it stores its own `pc` from an `auipc`, adds 3 twenty times behind a taken
  backward branch, and returns 60) is copied into DDR3 physically, before paging, and called in S-mode at its *virtual* address
  through the same translated megapage as the data frame. The fetch therefore goes through the instruction MMU's walker, which
  reads the root entry out of DDR3 (seen in the monitor: a read at `0xA0000400`, the megapage's entry), and out of DDR3 through
  the instruction cache. The routine reports its own `pc`, which has to
  be the virtual address: a fetch that ignored translation, or ran a stale copy somewhere else, would report another.
- **Faults.** Entries whose contents are *defined* as invalid (written as zero; Part 11's lesson is that an unwritten DDR3
  location is `x` in simulation) must raise the right page fault at the right address: a load and a store at an invalid root
  entry (index 320), and a load and a store at an invalid level-2 entry under a valid root pointer (the UART megapage's second
  page). The traps are armed and resumed the way the acceptance test's are (`software/soc/trap.h`): the handler runs in M-mode,
  which does not translate, and returns to S-mode after the faulting instruction.

**Result: execution works, and the faults found a bug.** On the in-order core the routine ran from DDR3 at its virtual address and
returned 60, and all four faults raised the right cause (13, 15, 13, 15). The four address checks failed. A passive monitor
(scratch, not committed) printed the CSRs one cycle after each trap, beside the faulting access's own address as the core had it
and as the MMU had latched it:

| trap | cause | `mtval` the core wrote | `mem_addr_ex` at the trap cycle | `MMU.va_r` | the faulting address |
|---|---|---|---|---|---|
| load, invalid root entry | 13 | `0x00000001` | `0x00000001` | `0x50000000` | `0x50000000` |
| store, invalid root entry | 15 | `0x04000014` | `0x04000014` | `0x50000000` | `0x50000000` |
| load, invalid level-2 entry | 13 | `0x04000014` | `0x04000014` | `0x04001000` | `0x04001000` |
| store, invalid level-2 entry | 15 | `0x04000014` | `0x04000014` | `0x04001000` | `0x04001000` |

**Why.** `rtl/cpu_core.v` took the trap value of an MMU fault from `mem_addr_ex`, which it recomputes every cycle from live
forwarding. During a multi-cycle walk the pipeline keeps draining under the stalled access, and an operand that had come from the
instruction just before it decays to whatever the register file held earlier; the core's own comments say so for the address the
MMU walks (`va_r`) and for store data (`store_data_latched`), and the trap value had been missed. Every faulting access in the
test follows a `lui` that sets its base register (`lui a5,0x50000; lw a5,0(a5)`), which is exactly that shape, and the values
written (`0x1`, and `0x04000014`, the UART status register's address that the console code had just used) are earlier contents of
those registers, not addresses the program formed for these accesses. The wide core takes the address when the access issues and
keeps it in the reorder buffer (`rob_trap_val`), so it was never affected, and passes the same checks unchanged. (Update, Part 13:
the conclusion stands and the mechanism is misstated. `rob_trap_val` holds the address only of a load that traps when it issues.
A store, an AMO or a translated load runs at the head of the reorder buffer and forms its address there, from the operands held
in its own entry: `head_mem_addr_virt = headS_op1 + rob_imm[rob_head]`, which cannot decay.) A fault on a TLB
hit has no walk to decay over (reasoned, not provoked; Update, Part 13: provoked for a permission fault, and it reports the right
address). Why riscv-tests and the Spike co-simulation never saw the bug was not
checked; faults whose base register was settled before the access would not show it.

**The fix** is the instruction the MMU already provided for the purpose: its `pa_va` output, "which virtual address `pa` is the
translation of", which is the live address on a TLB hit and the walk's own snapshot after a walk. The in-order core left that port
unconnected, on the reasoning that the translation does not need it; it is now the trap value of a page fault, and of a PMP fault
on a translated access (which has the same decay). Nothing else changes: no stall, no cycle.

**Evidence.**

- Red, then green: before the fix the in-order core fails four checks (the ones above) and passes the execution checks; after it,
  `make sim_ddrmmutest` passes. The wide core passes before and after, with its RTL unchanged.
- The fix moves no published number: the in-order Linux boot reaches `VERNIER-RV32-LINUX-BOOT-OK` at cycle 146,466,531, as
  before. Identical to the cycle means the boot took no fault the bug changed.
- The new checks can fail. A mutant of the program that takes the execute permission off the DDR3 megapage stops with an
  unexpected `INSTRUCTION PAGE FAULT` (cause 12) at the call; a mutant that writes a valid leaf where the level-2 entry is meant
  to be invalid fails the two level-2 fault checks.
- `make verify` and `make verify_ooo` exit 0. The new test ends at 3,306,980 ns of simulated time in-order and 3,461,980 ns on the
  wide core.

**What this does not establish.**

- `stval`. The test takes the faults in M-mode (nothing is delegated), so it reads `mtval`; the same `val_for_csr` feeds `stval`
  when a fault is delegated, but a delegated fault was not run. (Update, Part 13: run now; `scause`, `stval` and `sepc` are right.)
- Any other path with a stale operand: the instruction fetch of a faulting `jalr` target, AMOs and `lr`/`sc` (they share the
  data MMU and so the fix, but were not provoked), and the misaligned case, which is detected before translation and is not
  affected. (Update, Part 13: all of these are run now, and the AMOs found a bug in the wide core.)
- Paged execution of anything larger than a nine-instruction routine, and execution of the *page tables'* own megapage.
- Fmax. The fix adds a mux input on the trap-value path; its timing was not measured (the record puts the netlist noise at about
  1.4 MHz).
- Nothing is on a board; the DDR3 model is the simulation one.

**Update, Part 13: the list Part 12 left is run, and the atomics found a second bug, this one in the wide core: an AMO, `lr.w` or
`sc.w` that faulted hung the core.** Part 12 ended with what it had not established. `software/soc/ddrmmutest.c` runs those things
now, on both cores, in `make verify`: 34 more checks.

**What the test adds.** The accesses walk: the TLB is emptied with `sfence.vma` first (an invalid entry is never cached, so those
walk anyway), and the register an access needs is made by the instruction just before it, the shape that made `mtval` wrong in
Part 12. Two checks are taken deliberately on a TLB hit: the store to the read-only page and the `sc.w` after its `lr.w`.

- **Atomics through a walk.** `amoadd.w` with its address made just before, then with its addend made just before, and `lr.w`
  followed by `sc.w`, on the translated DDR3 frame: the old value, the sum in memory, and the `sc.w` result and stored value.
- **A page S-mode may read and not write.** `root[272]` points at a second level-2 table in DDR3 whose entry 0 is a read-only
  leaf onto the test frame (a second name for the same word). A store (on a TLB hit), an `amoadd.w` (on a miss) and an `sc.w` after
  an `lr.w` must fault with cause 15 (an AMO is a store as far as permissions go), the `lr.w` must not fault, and the word must
  be unchanged.
- **A frame PMP denies to S-mode.** PMP entry 0 becomes a 4 KB region with no permissions; the all-memory entry that `crt0_ram.S` sets up moves
  to entry 1. `lw`, `sw`, `amoadd.w` and `lr.w` through a walk must raise access faults (5, 7, 7, 5) with the virtual address in
  `mtval`. M-mode still reaches the frame, because the entry is not locked. This is the half of Part 12's fix that covers PMP
  faults on translated accesses, which that part could only reason about.
- **Alignment under paging.** A misaligned `lw` and `amoadd.w` with the TLB empty must trap as misaligned (4 and 6), at the right
  address, not as a page fault.
- **Instruction page faults.** A `jalr` to an invalid root entry, to an invalid level-2 entry and to a page that is mapped but not
  executable (the UART's) must raise cause 12 with the target in both `mepc` and `mtval`.
- **Delegation.** With `medeleg` set for causes 12, 13 and 15, a load, a store, an AMO and two fetch faults are taken in S-mode,
  by a handler that records `scause`, `stval` and `sepc`, and no trap reaches M-mode.

Two small trap front ends in the test make the last two possible without touching the shared runtime (`crt0_ram.S`): `m_front` sits
in front of `trap_vector`, handles an `ecall` from S-mode (which sets `medeleg`, since S-mode cannot) and an armed instruction page
fault (which must resume at `ra`, where the armed path in `crt0_ram.S` would resume at `mepc+4`, an unmapped address), and hands everything
else to `trap_vector` untouched, so an unexpected trap is still loud; `s_front` is the S-mode handler.

**Result.** On the in-order core every check passed the first time: no bug there. On the wide core the run stopped after
`store, read-only page (TLB hit)` and the simulator spun until the testbench's cycle limit. A passive monitor (scratch, not
committed) showed the `amoadd.w` at the head of the reorder buffer walking root entry 272 and then the level-2 entry, the walk
resolving with a fault, no trap being taken, and the walk starting again: 5,166 resolutions in the 2.6 million cycles watched.
`head_dbus_stall` was already high when the AMO reached the head, and `head_ex_commit` was low throughout.

**Why.** In `rtl/ooo/core_ooo.v`, `amo_stall` was `headS_valid && rob_is_amo[rob_head] && headS_ready && !amo_done`, and
`amo_done` requires `amo_active`, which is low whenever the AMO is going to trap (`!head_mmu_fault_now`, `!head_mem_misaligned`,
`!head_pmp_fault_now` are terms of it). So an AMO that traps never produces the `amo_done` its stall waits for; `amo_stall` is a
term of `head_dbus_stall`, which gates `head_ex_commit`, which gates `head_take_trap`. The trap waits for the stall and the stall
waits for the AMO to finish. Loads and plain stores have no such term, which is why Part 12's four faults passed. The in-order core
does not have it: its `amo_stall` is `amo_active && !amo_done`, with `amo_active` meaning the AMO is in the memory stage, which an
AMO that traps in the execute stage does not reach. It has been there since stage 1d (#60), where `amo_stall` and the page-fault
and misaligned terms of `amo_active` first stood side by side (the PMP term followed in #105). Why nothing saw it before was not
checked. A faulting AMO would have hung the Linux boot, which reaches its marker, so the boot does not do one.

**The fix** is `head_amo_traps = head_mmu_fault_now || head_mem_misaligned || head_pmp_fault_now`, the three terms `amo_active`
already excludes, and `amo_stall` no longer holds while it is true. Nothing is released early: the walk itself still holds the head
(`head_mmu_wait_stall`), and a page fault only shows once the walk has resolved. An AMO that does not trap is unchanged.

**Evidence.**

- Red, then green: the unmodified wide core hangs at the first AMO that faults; with the fix, all 34 pass. The in-order core
  passes before and after (its RTL is unchanged by this part).
- The fix moves no published number: the Linux boot reaches `VERNIER-RV32-LINUX-BOOT-OK` at cycle 146,466,531 in-order and
  148,856,491 on the wide core, both as before. A change that acts only on an AMO that traps cannot move a boot that has none.
- Each term of the fix is needed. Taking out one at a time, the wide core hangs at the case that term covers: without the page-fault
  term at the `amoadd.w` to the read-only page, without the PMP term at the `amoadd.w` to the PMP-denied frame, without the
  misaligned term at the misaligned `amoadd.w`.
- The new checks can fail in other ways, each run on the final test. Reverting Part 12's `mtval` fix on the in-order core fails 12
  checks, 8 of them in Part 13 (AMO, `lr` and `sc` faults, and the delegated ones); reverting only its PMP half fails the `sw` and
  `amoadd.w` checks (the `lw` and `lr.w` checks do not catch that one: the address register had not decayed in that program, and
  why was not examined). Treating an AMO as a load for permissions fails 9 checks on each core. Zeroing `stval` fails the 5
  delegated checks. Zeroing the fetch-fault trap value fails 5 on each core. Making the read-only page writable fails 7.
  Switching off the in-order core's misaligned-AMO check fails the misaligned `amoadd.w` check.
- The test ends at 8,159,620 ns of simulated time in-order and 8,561,460 ns on the wide core.

**What this does not establish.**

- PMP on an instruction fetch, and on `sc.w` (the `amoadd.w` and `lr.w` cases are run); a PMP-denied page-table walk, which the
  checker does not cover by design.
- `lr`/`sc` reservation behaviour across a trap; an interrupt arriving on the very cycle a faulting AMO reaches the head (the
  interrupt would win, and the AMO would run again after the handler).
- Delegated misaligned accesses and delegated interrupts; only 12, 13 and 15 are delegated here.
- Fmax. `head_amo_traps` adds three signals to the cone of `amo_stall`, which feeds `head_dbus_stall`; each already fed
  `amo_active`, so no new dependency, but the timing was not measured.
- `CORE=hetero`. Nothing on a board.

**Update, Part 14: the Wishbone slave is x16, and the window is the part's whole 512 MB.** Through Part 13 `rtl/soc/wb_ddr.v` used lane 0 alone: a 16-byte
block was sixteen single-byte controller calls, the window was 256 MB (mask `0xF0`, `0xA0` to `0xAF`), and an address 256 MB up was not DDR3 at all. Stage 1's
Part 26 made the controller x16; this uses it.

**What changed.** `rtl/soc/wb_ddr.v` moves a 16-bit column per controller call. A block is 8 columns, so a fill is 8 reads (it was 16) and a 32-bit store is at most
2 writes (it was at most 4), each carrying the byte enables of its half of the word. The address maps the way the part addresses: `A[0]` is the lane, `A[10:1]` the
column, `A[13:11]` the bank and `A[28:14]` the row; a block is `A[28:4]`, 128 to a row, which is the part's 2 KB page. `rtl/soc/soc_top.v` passes `0xA0` to `0xBF` to
the slave (mask `0xE0`), and `dts/soc.dts` and `software/soc/soc.h` say 512 MB. Nothing else is mapped above `0xA0`, so nothing was displaced. The slave already
waited for lane 1's calibration (Part 26); the cache of the open block is updated lane by lane, so a store that stores one lane leaves the other's cached byte alone.

**Only in a build that has the slave.** The mask is `0xE0` under `DDR3_ENABLE`; a build without it keeps the tied-off stub on `0xA0` to `0xAF`, mask `0xF0`, exactly as before.
The first version widened the mask for every build, and the whole-SoC synthesis check (`make soc_synth_check`) failed the wide core's gate: the same SoC, with a window that
nothing in it uses, mapped to 57,538 LUT4 instead of 58,626 and took 1,685 s to synthesise instead of 368 s (the in-order SoC moved too, 23,615 LUT4 against 24,273). Run alone on an idle
machine it took the longer time again, so it is the netlist and not the load. Every figure of every build without the slave is unchanged now (58,626 and 24,273 LUT4, 368 s and 121 s),
which is what "present but unused by default" is for. It also showed that the check's time limit, then 1,500 s for the wide core, was not a margin that survives an unrelated change to the logic; that is fixed (the index's Common known defects).

**Tests.** `sim/tb_wb_ddr.v`, extended. Thirteen words across the address space, written out again from the part's addressing and not from the slave's: the first and the
last, a walking one through column, bank and row, the edge of the old window, the first word above it, and a pair 256 MB apart read one straight after the other so the
open block cannot answer for the wrong one; each of their bytes is found in the cell and the lane that addressing names, in the right plane of the memory, and reads back as
itself through the bus. A byte stored at each of the 16 offsets of a block, each in turn, changes exactly that byte. Selects that straddle the two columns of a word. And a
sweep of 56 random stores over the whole part against a byte-wise reference: 123 bytes, every one read back right. At the CPU, `software/soc/ddrcheck.c` stores to a word
256 MB up, to the last word of the part (`0xBFFFFFFC`), and to an even and an odd byte alone, through the real interconnect.

**Mutation-tested, 12 ways, all caught.** The two halves of a word swapped on a write; the byte enables of a half swapped; the column fields swapped; the bank taken from the
wrong bits; the row's top bit dropped; the column's top bit dropped; the fill's column counter stuck (a hang, which the testbench's timeout catches); the open block's copy
updated for both lanes after a one-lane store; the halves of a word swapped on a read; the hit test ignoring the top bit of the block tag; a store that always enables both
lanes; lane 1's byte dropped on a read. The first run left one alive, the hit test, because the two addresses 256 MB apart were not read one after the other; they are now.
At the CPU, narrowing the decode back to `0xF0` fails `ddrcheck` at the word 256 MB up and at the last word of the part, both of which read back zero (an unmapped address is
acknowledged with zeros).

**Verified:** `make ddr3_check_sim`; the five SoC-level DDR3 tests (`sim_ddrcheck`, `sim_ddrexec`, `sim_ddratomics`, `sim_ddrmmutest`, `sim_uartload_ddr3`); `make dtb_check`.

**What this does not establish.** Hardware-faithful bursts: a column is still one controller transaction, a block still eight of them, and a burst still moves one column and masks its
neighbour (Part 22). The cost of the change in time was not measured beyond the count (8 transactions for a fill, not 16; at most 2 for a store, not 4). Real silicon, a real
512 MB part, the retention and walking-pattern tests Stage 3 asks for, Linux from DDR3. The behavioural model's table holds a thousand bytes a lane by default, so the sweeps here
are sparse by design: "the whole part" means the address decode and the geometry reach every cell, not that every cell was written.

**Update, Part 15: the ECPIX-5 SoC build has the DDR3 controller in it, and places and routes with the board's real DDR3 pins; it writes no bitstream, and the board's schematic, which turned out to exist, says why the four pins the controller assumed are not there.** Through
Part 14 no board build contained the controller. The board's real DDR3 pins (`fpga/constraints/ecpix5_ddr3.lpf`) were used only by a diagnostic probe of the PHY alone (Part 21), and `rtl/soc/soc_top.v`'s own comment named "whichever real ECPIX-5 SoC board target
eventually needs it".

**What changed.** `fpga/soc_fpga.v` and `fpga/ecpix5_top.v` gain the DDR3 ports behind `DDR3_ENABLE`; a build without it has none of them, so the ULX3S builds and the Stage 0 ECPIX-5 build are as they were (`make soc_synth_check` gives the figures it gave, 24,273 and 58,626 LUT4).
`BOARD=ecpix5-ddr3` in `fpga/synth/synth_ecp5.sh` builds that top with `-DDDR3_ENABLE`, the DDR3 files, the DDR3 variant of the boot ROM (Part 10) and three constraint files in one: the base board's, the DDR3 pins, and `fpga/constraints/ecpix5_ddr3_throwaway.lpf`, which holds the four
lines the probe's file used to hold, now shared (the probe's effective constraints are the same 105 lines). It stops after place-and-route and writes no bitstream (`NO_BITSTREAM`), and removes the previous one so that none is left looking like this build's. `make pnr_soc_ecpix5_ddr3` runs it.

**Test first.** The nearest thing `main` allowed, `BOARD=ecpix5` with `-DDDR3_ENABLE` and the DDR3 files added by hand, synthesises and then fails in nextpnr's packing: `DQSBUFM can only be used with a pin-constrained PIO connected to its DQSI input (while processing
'SOC.SOC.DDR3.DDR.DQS1.DQSBUF')`, because the controller's pads have nowhere to go: the board top had no DDR3 ports. (The script then said "no placement seed closed timing in 1 attempts", its message for any nextpnr failure; it retries a packing error on every seed, six by default.)

**What it shows.** In-order core, first placement seed: place-and-route finishes and **timing closes, `soc_clk` at 27.51 MHz (25 MHz asked) and the controller's `sclk` at 188.96 MHz**, in 13 minutes 48 seconds with the synthesis. Against the same tree's Stage 0 build without the controller: `TRELLIS_COMB`
32,975 against 32,232 (+743), flip-flops 11,045 against 10,436 (+609), the same 82 `DP16KD`, and 48 more pads, 47 I/O logic cells, one more PLL (2 of 4, the controller's fed by the SoC's own, which nextpnr accepted), one DLL and two `DQSBUFM` (one per byte lane), so the whole controller and slave cost under
one percent of the device's logic and no block RAM. One seed each way is not a distribution: the baseline's first seed estimated 16.28 MHz after placement and was still routing after 54 minutes when I stopped it, where this one routed in about nine. No Fmax is claimed for what the controller costs; the area is the comparison.
The wide core with the controller has no figure: its synthesis was still in yosys's `ABC9` step after more than an hour when this was written, where the same core without the controller takes about six minutes there (the whole-SoC synthesis check; `ABC9`'s time is not stable under changes to unrelated logic, the index's record of the time limit). The build supports `CORE=ooo`, and the simulation below passes under both cores. (Update, Part 16: it has a figure now, and the stall was not the controller's; see below.)

**The board-level simulation.** `make sim_ecpix5_ddr3` (`sim/tb_ecpix5.v` under `DDR3_ENABLE`, in `soc_fw_check_sim` and so in `make verify` and CI, under both cores): the board top, a behavioural DDR3 behind each byte lane, both lanes calibrating through it (about 224 microseconds after reset is released, with the controller's PLL running off the SoC's), the pins carrying CK, CKE and RESET# as they should; and then words and byte-lane stores through the Wishbone slave, read back from the memory. Each load follows a load from another block, because the slave answers from the copy of the block it last
touched, and a load straight after a store says nothing about the DRAM: the calibration checks alone left three of the wiring errors below alive, the first version of the bus checks, which loaded straight after storing, caught one and left the mask swap alive, and that is how the cache was found. **Eight wiring errors put into the board top, one at a time:** the two data lanes swapped, RAS# with CAS#, CKE left open, RESET# left open, address bits 0 and 1 swapped, bank bits 0 and 1 swapped,
the two data masks swapped (all seven caught), and the two byte lanes' strobes swapped (not caught: both strobes carry the same waveform on every write and every read, so no simulation can tell them apart; that one is the pin list's job, and the schematic's, below).

**The schematic.** The roadmap said (Part 21) that LambdaConcept's documentation has no DDR3 page and that there was no schematic; the documentation's resources list one (`SCH_ECPIX-5_R02.PDF`, revision R02, 3 June 2020), and it was there to be read. Two things came out of it. **All 44 DDR3 signals in `ecpix5_ddr3.lpf` agree with its FPGA sheet, ball for ball**
(checked by pairing every DDR net label on the sheet with its ball, and comparing with the file; the three negative pads, J3, U5 and U2, agree with the file's comments), where before the list rested on two platform descriptions of the board. And it settles the open known defect: the DRAM's CS# is tied to ground through a 4.7 kΩ resistor, and its RESET# is driven by the board's reset circuit (a
74LVC07 open-drain buffer fed by the MAX6420 supervisor, pulled up to 1.5 V), neither from the FPGA. That is what Part 21 guessed ("presumably tied low and handled on the board"), now read. It does not change the controller, which still deselects with CS# and pulses RESET#; the open known defect says what it has to become (an idle slot is a NOP; the initialisation waits out its timings and pulses nothing) and the four throwaway pins
and the missing bitstream are what stand in the meantime. It is one revision of the board.

**What this does not establish.** Anything on hardware: no ECPIX-5 is attached to this session, and the bitstream this build would write is deliberately not written. That the board's DDR3 works with this controller, which cannot be said until CS# and RESET# are right. Fmax at the DDR clock (the controller's `sclk` is 25 MHz here and its edge clock 50). The wide core's timing with the controller. The device tree in the boot
ROM, which is still the ordinary one (no DDR3 node), so Linux from DDR3 is as far off as it was. And that two lanes' strobes are not swapped on the board: only the schematic says that, and it agrees.

(Update, Phase 9 Stage 1, Part 27: the controller no longer has the four ports, the throwaway pins are gone, and this build writes a bitstream; the text above is what Part 15 found and did.)

**Update, Part 16: the wide core with the controller synthesises, and what had stopped it was a check, not the controller.** Part 15 left the wide core with the controller without a figure: its synthesis was killed in `ABC9` after 2 h 35 min, and Part 27's after 2 h. Neither the controller nor the 512 MB decode constant (whose widening had once moved `ABC9` from 368 s to 1,685 s) is the cause. Yosys appends a `&verify` to ABC's script, an equivalence check of ABC's answer against its input with no bound on its time, and on the wide core's network (222,925 AND gates with the controller, 218,707 without) it took 134 s and 229 s where it finished, and had not finished after 50, 50 and 60 minutes in three runs. The yosys builds differ too: Homebrew's, which `make pnr_soc_ecpix5_ddr3` found first on `PATH` when the oss-cad-suite bundle was appended to it, is what the runs that stopped used, and the bundle's, which `soc_synth.sh` puts first, is why the same core "took six minutes" in the whole-SoC check; the check stopped both. The index (Common known defects) has the measurements, the stack samples that put ABC in `&verify`, the steps of the script that did not stall, and what else was tried.

**What changed.** `fpga/synth/synth_ecp5.sh` sets yosys's `abc9.verify` to 0 for `CORE=ooo` (`ABC9_VERIFY=1` puts the check back; the in-order core keeps it). The netlist does not change: the wide core without the controller comes out byte for byte the same with and without the check. The script prints which yosys and which ABC script it runs, and says when its yosys is not the one beside its `nextpnr-ecp5`. `soc_synth.sh` takes `BOARD=` for the boot ROM and the log directory, its list of memories that become registers can name a board (`both@ecpix5-ddr3`: the slave's 128-bit `block_buf`), and it fails if ABC's log shows a `&verify` that was not asked for. `make soc_synth_check_ddr3` runs it on `BOARD=ecpix5-ddr3`, in `make verify` and CI, under both cores.

**What the build shows.** `BOARD=ecpix5-ddr3 CORE=ooo`, synthesis only: 55,305 LUT4, 16,488 flip-flops and 80 `DP16KD` in 262 s with the bundle's yosys on a quiet laptop, and 55,178 LUT4 and the same flip-flops and block RAMs in 291 s with Homebrew's. The controller and its slave cost the wide core 1,754 LUT4 and 605 flip-flops (53,551 and 15,883 without them). Place-and-route does not give a bitstream: nextpnr's estimate for `soc_clk` after placement is 10.55 MHz against the 25 asked; a placement estimate runs about 6 MHz pessimistic (`fpga/README.md`), which leaves the wide core short of 25 all the same, and the routed figure was not waited for (routing, at 82% of the device's logic, had not finished when the run was stopped).

**What this does not establish.** A wide-core bitstream with the controller: the wide core does not meet 25 MHz on the ECPIX-5 any more than on the ULX3S (8.68 MHz, `fpga/README.md`), and an underclocked build, which is how the ULX3S got one, would also have to re-plan the controller's clocks, which hang off the SoC's. Anything on hardware. That the stock script cannot finish on the wide core: the runs that stopped were stopped. That no other step of ABC's script has an input it is slow on; the guard's time limit is what would catch one.

**Stage 3 - real silicon.** Bitstreams built and loaded on real ECPIX-5
hardware; DDR initialization/calibration, a full-memory (or large
representative subset) walking test, a retention/stress pattern, and
cache/MMU interaction all checked on real hardware, to the same standard
Phase 2 already set for the current SDRAM (every address, bank, and lane
- not "it linked and didn't hang"). OpenSBI, the kernel, and an
initramfs get ported to the new memory size and board. Achievable
frequency, resource usage, and a real bandwidth/latency comparison
against the existing SDRAM controller all get measured and written down,
not estimated. `fpga/README.md` gets updated to the same honesty
standard the current board's own table already holds itself to -
including naming what remains unproven, the way that table already does
for `CORE=ooo`. **Done when:** Linux reaches userspace on ECPIX-5 with
DDR as main memory, a real console transcript and real timing numbers
recorded - the same bar Phase 0 set for the pipeline itself and Phase 7
sets for the SD card: simulated first, then proven on silicon, not asserted
from simulation alone.

**Update, 2026-10-18: the first bitstream to put on the board exists, and nothing has run on it.** `BOARD=ecpix5-ddr3-check`
(`make pnr_soc_ecpix5_ddr3_check`) is `BOARD=ecpix5-ddr3` with `software/soc/ddrcheck.c` preloaded into block RAM, the DDR3 counterpart of
`ulx3s85-sdramcheck`: the boot ROM finds the program in RAM and jumps to it, with no SD card, and the program stores to and loads from
the DDR3 through the CPU and prints fourteen checks and `DDR3 CPU-PATH TEST PASSED` or `FAILED` on the board's UART. It is the smallest thing that
can say whether the controller starts, calibrates and moves data on a chip, and it is not a memory test: Stage 3's walking and retention tests and
the sweep are still ahead. `make sim_ecpix5_ddr3_check` runs this exact image through the board top with a behavioural DDR3 behind the pins and
decodes the UART pin. `fpga/README.md` ("Bringing up the DDR3 on the ECPIX-5") says how to load it and how to read each outcome, silence included.

**Update, 2026-10-22: the controller's status is on the board's LEDs.** The first run on a board is most likely to say nothing on the serial port, and the controller starts without the CPU, so a LED can say how far it got. The controller already had the signals (`pll_locked`, `dll_locked`, `init_ready`, each lane's `calib_done` and `calib_error`) and `soc_top` left them open; they are now a seven-bit `ddr3_status` out of `soc_top` and `soc_fpga`, and `fpga/ecpix5_ddr3_leds.v` turns them into colours on three of the board's four RGB LEDs: LED0 the controller's clocks and the DRAM's initialisation (dark, red, blue, green), LED1 and LED3 each byte lane's calibration (dark while waiting, blue sweeping, green calibrated, red failed). LED2's green stays the CPU's heartbeat. The decoder is combinational on purpose: the inputs come from the controller's own clock domains and stay put once reached, and a sampling register in a third domain would be a crossing for nothing.

*The pins and the circuit are from the schematic (R02), checked against LiteX's board file.* Sheet 5 labels each FPGA ball with its net (`LED_R0` to `LED_B3`), and all twelve agree with litex-boards' `rgb_led` resource ball for ball; LiteX numbers the four LEDs differently (its 0 is the schematic's LED2), and the names used are the schematic's. Sheet 17 is the circuit: common-anode LEDs through a resistor each to 3V3 (1,000 ohm on red, 100 ohm on blue and green), each channel sunk by a 74HC244, so **a pin driven low lights its channel**: every port is active low, the polarity is the board top's (`fpga/ecpix5_top.v`), and every channel is driven, the unused ones high, since a floating pin is an undriven buffer input. All twelve balls are in banks 2 and 3, which the power sheet (6) puts on 3V3 with every bank but 6, the DDR3's, so the LEDs are LVCMOS33 and share no bank with the SSTL15 pins. The schematic's own URL answered 503 on the day; the copy read is the Internet Archive's of that URL (17 pages, the same sheets).

*Tests, written before the code and seen to fail.* `make sim_ecpix5_leds` runs all 128 values of the status bus through the decoder against properties that do not restate it (no LED ever shows two colours, nothing is lit before the PLL locks, a lane is dark before initialisation is done, an error is red whatever else is set, a calibrated lane is green, each lane reads only its own bits) and thirteen named situations in the order a board goes through them. `make sim_ecpix5_ddr3` checks the LEDs at the board's pins: the early state (the DRAM still in its 500 us wait: LED0 blue, the lanes dark, which is the only moment the controller's LED and the lanes' differ, so the only one that shows they are wired to different signals), then all three green with the LED2's red and blue driven off. `make sim_ecpix5_ddr3_lane1` leaves nothing behind byte lane 1: its calibration fails and LED3 must go red while LED0 and LED1 stay green. Seventeen one-line breakages of the decoder, the board top and the three levels of wiring, **all caught**: the decoder's priorities, the DLL left out, a stage early, red and green swapped, a lane reading the other's bits; a LED not inverted, two LEDs swapped, LED0 showing a lane, two channels of LED3 swapped, LED2's red lit, its blue left floating; the status open at the board top and at `soc_fpga`; and in `soc_top` the two lanes' errors swapped, `init_ready` and the DLL swapped, and lane 1's done taken from lane 0. In simulation initialisation is done 522 us after the board's reset and each lane calibrates within 1 us of that, so the blue states are not seen going by on a good board: a LED that stays blue or dark is the finding.

*The build.* `make pnr_soc_ecpix5_ddr3`, in-order core, first placement seed: place-and-route finishes and **timing closes (`soc_clk` at 30.02 MHz against 25 asked, the controller's `sclk` at 145.45 MHz)**, in 10 minutes 40 seconds with the synthesis, and `ecppack` writes the bitstream (2,117,804 bytes, as before). There are 60 pads where there were 49: the eleven channels, and nextpnr's "placed 110 cells based on constraints" is the 99 it had and those eleven; every port has a pin, since the script drops `--lpf-allow-unconstrained` for a board target, so a port left out of the new file would have been an error. 11,043 flip-flops, 33,710 `TRELLIS_COMB` (40%) and 82 `DP16KD`; Part 27's build had 11,041 and 33,346, and the decoder is a handful of LUTs, so the difference in `TRELLIS_COMB` is `ABC9`'s habit of moving by a few per cent with logic that has nothing to do with it (the index's record of the whole-SoC check), which I did not look into. One seed is not a distribution, and no Fmax is claimed.

**What this does not establish.** Anything on a board: the LEDs have not been lit, and which of the four is which on the silkscreen was not checked. That green on a lane is more than it says (a read tap was found against a pattern the lane wrote, which is not a memory test). That the schematic is the board's: R02 is one revision.

**Update, 2026-10-22 (a correction to the two paragraphs above and to the README they changed): green on a lane does not say the DRAM answered.** The LED update, the decoder's header and `fpga/README.md` said that a lane's green meant "the pins, the strobe and the DRAM answered", and red "nothing came back through the DRAM and the board's traces". Both are wrong, and the phase document had already said why: `ddr3_read_calib.v` injects its pattern directly onto the lane's DQ and DQS pins and sends the DRAM no ACTIVATE, WRITE or READ (Part 2, above: "still does not issue real ACT/WR/RD commands"; measured again for this correction, a single sweep is 58 command slots and every one of them is a NOP). So the DRAM takes no part in a lane's colour. Green means the sweep found a tap that captures what the lane itself drove; red means it did not; on a board neither is evidence about the DRAM, and what the sweep ends in on silicon is not known (the simulation's DQSBUFM stand-in does not look at the DQS pin at all, and on the chip the capture needs a strobe at the pad). A green from this sweep is also not a tap proven for real reads, and a red stops every access, since the Wishbone slave waits for both lanes. LED0 is different and the README says so: its green means the power-up sequence ran to its end. The decoder is unchanged, its tests are unchanged (they test the decoder, not the DRAM), and the three places that carried the wrong sentence are corrected. The open defect is in the index's "Common known defects".

**Update, 2026-10-22: what the controller does after a reset that is not the board's.** Part 27 and the ECPIX-5 schematic work left one question open: the controller starts itself after *its* reset (`rst || !pll_locked`), and an `ndmreset` from the debugger or a bitstream loaded over a powered board resets the controller and not the DRAM (`ddr3_init_seq.v`'s header says so). Nothing had run it, and the memory model could not have judged it: `sim/ddr3_model.v` was single-shot, one power-up, and called every MRS after it unexpected. `sim/tb_ddr3_restart.v` (new; `make sim_ddr3_restart` runs it five times, once per row below, and it is in `DDR3_SIM_TESTS`, so in `ddr3_check_sim` and in `make verify`) writes four words and reads one back, then resets only the controller, at one of five points. The DQ models and the checker are on the board's reset, which is not pulsed, so the DRAM keeps what it holds.

*The checker learned what a warm restart must obey.* A fall of CKE while RESET# stays high, after the initialisation, is now a warm restart and is held to: CKE may not fall inside a write and its recovery (tWRPDEN = WL + 4 + tWR + 1) or a read burst (tRDPDEN = RL + 4 + 1); the first command after CKE rises waits tXP (3 CK); an MRS needs every bank precharged, so one issued with a bank open is a violation; and MR2, MR3, MR1, MR0, ZQCL are checked in that order again. These rules are reasoned from JESD79-3 as I know it and not from a Micron datasheet, which nothing here has read, so a rule may be too strict or too loose; the five runs below are what they find, not a certificate.

| Controller reset at | CKE | The checker says | The second initialisation | Both lanes' calibration |
|---|---|---|---|---|
| idle | falls at the reset, rises 501 us later | nothing: legal | runs in full: 500 us wait, MR2, MR3, MR1, MR0, ZQCL | error |
| a bank open (just after an ACTIVATE) | the same | **an MRS with a bank open** | the same | error |
| in the middle of a write burst | falls at the reset | **CKE fell in the middle of a write burst** | the same | error |
| in the middle of a read burst | falls at the reset | **CKE fell in the middle of a read burst** | the same | error |
| two `sclk` cycles after a REFRESH command | falls at the reset | nothing: legal | the same | error |

In all five the initialisation re-runs completely (eight MRS and two ZQCL in all by the end, 500 us or more between CKE falling and rising, `init_ready` falling and rising again at about 1,050 us), which is what the design says it does. Three things follow.

- **A warm restart is legal only from an idle DRAM.** The controller resets with no regard to what the DRAM is doing, and the initialisation it then runs has no PRECHARGE ALL, so a restart with a row open issues the first MRS into an open bank, and one in a burst drops CKE inside it. Each is a violation by the rules above, so what a real DRAM would do is outside what the standard promises. How often a reset finds a bank open or a burst running was not measured: it depends on what the CPU was doing, and the first two rows are the ones a program that is storing or loading when the debugger resets it will meet.
- **After every restart both lanes' calibration ends in an error, and the controller then accepts no request until the board's reset.** The simulation's cause is plain: the DQ model answers the sweep's injected pattern only before the first command it has seen (its "calibration cell"), and the DRAM has been commanded by now; each model also reports DQS "driven outside the write burst a WRITE command asked for". On silicon the cause may differ and is not known. The shared root is the open defect above: calibration is not a command-level step, so it has no place in a DRAM that has been used. `tb_ddr3_restart.v` asserts this defect as present (`KNOWN DEFECT`); the assertion is one to flip, with `-DEXPECT_RECAL`, once calibration is command-driven.
- **A refresh in progress is no obstacle.** The refresh controller resets with the rest, and the run restarted just after one is as clean as the idle one.

*Tested to fail.* Ten one-line breakages, each applied to a copy of the tree and run against `make sim_ddr3_restart`, all caught: in the checker, the write-burst rule removed, the read-burst rule removed, the bank-open rule removed, the order check not re-armed, tWRPDEN and tRDPDEN each cut to one CK, and the open banks forgotten at the CKE fall; in the controller, the 500 us wait cut to 500 ns and the ZQCL left out; in the test, the known-defect assertion flipped (which must fail while the defect stands). tXP has no mutation of its own, and the rule is the one the first MRS of a power-up already had.

**What this does not establish.** That a real DRAM would behave as the model does (retention, the mode registers surviving, a refresh debt after the controller's reset: all out of the model's reach); that the rules are JEDEC's rather than mine; that the board's reset circuit really resets the DRAM at the same time as the FPGA (the schematic says RESET# comes from it); anything about the controller on silicon. And what to do about it is not decided: the options are a PRECHARGE ALL ahead of the first MRS and a wait for the DRAM's burst to finish (cheap, covers the first two rows), and making calibration command-driven (large, covers the third).

**Stage 4 - making the larger memory actually useful.** Linux's own
memory configuration and device tree updated for the real 512 MB;
microSD boot on ECPIX-5 as a natural next step once the current SD-card
work (Phase 7) has a second board to run on; CoreMark and this project's
other existing benchmarks re-run and published before/after, the same
"measured, not estimated" standard as everywhere else in this file; any
multi-core or heterogeneous configuration (Phase 13/15) re-confirmed
against the new controller, not assumed to still work. Ethernet/HDMI off
the same board are real, named, explicitly *not* attempted here -
separate peripherals for a later phase, not folded into this one.
**Done when:** a documented, reproducible Linux boot from DDR on ECPIX-5
exists, with updated, real performance numbers next to the pre-DDR
baseline.

**Stage 5 - two boards, kept honest.** ULX3S with SDR SDRAM stays a
fully supported, lighter-weight target - never removed, never demoted to
an afterthought. Board selection stays as clean as `CORE=`/`BOARD=`
already are (`BOARD=ulx3s85` vs `BOARD=ecpix5`). A real migration note
for anyone moving between the two, and a look at whether any of the new
DDR constraints/wrapper code is worth upstreaming, close out the phase.

**Done when (the phase as a whole):** ECPIX-5 is a real, supported
`BOARD=` target; 512 MB of DDR3 is usable as main memory from both
simulation and real hardware; Linux boots to userspace on ECPIX-5 using
it; the ULX3S/SDR-SDRAM path remains fully functional and unregressed;
and every claim along the way follows this file's own existing
measurement and documentation standard - the same bar, not a relaxed one
for being a bigger phase.

## Known defects

**RESOLVED - a page-table walk into DDR3 hung the machine; the cause was the test program, which never mapped the UART, and
no hardware, walker or cache was at fault (Phase 9, Stage 2, Part 11).** Found by Parts 3 to 6, closed by Part 11. S-mode's
first console access walked into a root-table entry nothing had written; Icarus returns `x` for such a DDR3 location, and the
walker's unconditional second-level read made the `x` its bus address and waited for a grant that never came. The program now
maps the UART through a level-2 table in DDR3, and `make sim_ddrmmutest` passes on both cores and is in `verify`. Left here,
struck rather than deleted, as the record of what this entry used to say:

**OPEN - a page-table walk into DDR3 hangs the machine, cause not yet
found; the walker itself is cleared, execution reaches real UART MMIO,
and a real attempt to tell "slow" from "hung" did not settle it either
(Phase 9, Stage 2, Parts 3-6).** `software/soc/ddrmmutest.c`
(`make sim_ddrmmutest`, not gated in `verify`) puts a Sv32 root table in
DDR3 and maps one genuinely translated megapage onto a real DDR3 physical
frame. The physical setup and readback before `satp` goes live all pass;
after `mret` into S-mode the run hangs - no trap, no further output -
until the testbench's own timeout. Execution genuinely enters S-mode and
runs real code (Part 4): the walker completes multiple real PTE reads
from DDR3 correctly on both the instruction and data side, with real,
valid addresses throughout - not the undefined one Part 3 first (wrongly)
reported, an artifact of reading a killed process's own truncated trace.
Execution then reaches real UART register accesses (Part 5) -
`UART_LSR`/`UART_THR`, the registers `put_char`'s own transmit-busy-wait
polls - reached with translation genuinely bypassed (`need_translate=0`,
confirmed against `rtl/cpu_core.v`'s own real formula) even though the
CPU is genuinely in S-mode; a combination no prior test in this project
appears to have exercised, `software/soc/mmutest.c` included. The
busy-wait's own condition (`UART_LSR`'s real value) does eventually
change from not-ready to ready and the loop correctly exits (Part 6) -
not a value stuck forever - after roughly 1.3 million cycles, far more
than this testbench's own real UART timing (`CLKS_PER_BIT=4`, ~40 cycles
per byte) should need. The D-cache was checked directly and ruled out as
the mechanism (`rtl/soc/cpu_wb.v`'s own `dc_cacheable` correctly excludes
UART's address regardless of translation). A direct test of "does it just
need more time" (a throwaway 4x timeout extension) did not complete
within 113 minutes of real CPU time - far longer than a mere 4x
cycle-count increase should cost - and was stopped there rather than run
indefinitely; whether one ~1.3M-cycle wait repeats per character of a
~68-character message (exceeding even the extended budget) or the stuck
state costs the simulator disproportionately more per cycle to evaluate
are both still open, undistinguished. Root cause not found. Reproduces
identically on every attempt. See Phase 9 Stage 2's own "Update, Part 3"
through "Update, Part 6" for the full account.

**RESOLVED - the in-order core wrote a stale register value, not the faulting address, into `mtval` for a page fault that needed a walk
(`rtl/cpu_core.v`; Phase 9, Stage 2, Part 12).** `val_for_csr` took the address from `mem_addr_ex`, which is recomputed from live
forwarding and decays during a multi-cycle walk when the base register came from the instruction just before the access. Found by
`make sim_ddrmmutest`'s page-fault checks (four failures, causes right and addresses wrong), fixed by connecting the MMU's `pa_va`
output, which holds the faulting address, and using it for MMU faults and for PMP faults on translated accesses. The wide core was
never affected. The in-order Linux boot is unchanged to the cycle. `stval` for a delegated fault, AMOs and `lr`/`sc` were not
provoked. (Update, Part 13: all provoked now, with the PMP half of the fix; the AMOs found the next entry.)

**RESOLVED - the wide core hung on any AMO, `lr.w` or `sc.w` that faulted: a page fault, a misaligned address or a PMP denial
(`rtl/ooo/core_ooo.v`; Phase 9, Stage 2, Part 13).** `amo_stall` waited for an `amo_done` that an AMO which is going to trap can
never produce, and the trap it was waiting to take is gated by that same stall (`amo_stall` -> `head_dbus_stall` ->
`head_ex_commit` -> `head_take_trap`). Found by `make sim_ddrmmutest`: an `amoadd.w` to a read-only page resolved its walk with a
fault over and over and never trapped. Fixed by not stalling while the AMO is going to trap; each of the three causes is needed
and was checked by taking it out alone. The in-order core never had it. An AMO that does not trap is unchanged.

**OPEN - the page-table walker makes a second-level read after every first-level read, even when the first-level entry is a
leaf or invalid (`rtl/mmu.v`; Phase 9, Stage 2, Part 11).** `S_L1W` always goes to `S_L2`, which reads `{PPN, 12'b0} + vpn0 * 4`
from the first-level entry and ignores the answer when that entry was conclusive. Measured only as the reads themselves, four
times in `make sim_ddrmmutest` (`0x80000004`, `0x8000003C`, `0xA0000004`, and `0xA0000010` on the instruction walker in Part 12). The consequences are reasoned, not measured: an extra
bus read per megapage walk; for a megapage whose frame is a device, a read of device registers, some of which have side
effects (a UART receive register, a PLIC claim register); for an invalid entry, an address taken from bits software controls,
which in hardware is a wild read (an address that decodes to no slave is acknowledged with zero data, so not a hang) and in
simulation `x`, which is the hang above. The spec's walk stops at a leaf. Not fixed, because skipping the read changes the
length of every megapage walk and so every cycle count that includes one; the change would be to leave `S_L1W` for `S_L2W`
when the entry is conclusive, and whether to make it, behind an option or not, is the maintainer's decision.


**OPEN, narrowed - the data path of the DDR3 PHY is not yet hardware-faithful
(Phase 9, Stage 1).** As first written this entry had three parts, all now
RESOLVED: CK at 25 MHz against a data path moving four UI per `sclk` (Part 16
put CK at the edge-clock rate, measured 1.00 before and 2.00 after), DQ
output-enabled for one `sclk` cycle, one cycle before DQS was enabled and two
before its first active toggle (Part 17 aligned the burst to the DRAM's write
latency; against the unaligned design the pin-based checker could not even
complete calibration), and a memory model with no DRAM **read** latency, so a
wrong CL was invisible to every integrated test (Part 18: the model answers a
READ at the DRAM's own latency, the design's `CL_CYC` of 3 was confirmed, and 2,
4 and 5 now each fail three integrated tests). What remains: the pins carry one
DQ word per `sclk`, so all eight beats of a write burst carry one byte and a read
returns two halves rather than eight beats; and the ECP5's real capture latency and
the sub-cycle windows are unverified on silicon. (The data mask is Part 22, the second
lane's data Part 26: the controller is x16, though the Wishbone side still uses lane 0.) Not a regression and not a claim that ever failed;
a distance the earlier accounts did not state. Full measurement, what a faithful path
needs, and the one decision that is the maintainer's, in the Phase 9 survey
("Survey, no design change").


**RESOLVED - the DDR3 controller assumed pins the ECPIX-5 does not have, and now has the pins the board has (Phase 9, Stage 1, Part 27).**
The board's schematic (R02) ties the DRAM's CS# to ground and gives its RESET# to the board's reset circuit, CK# is the negative pad of the pair CK is half of and the part has
no A15. The controller's idle command slot is a NOP, its initialisation pulses nothing and waits 500 us from its own reset, and CS#, RESET#, CK# and A15 are not
ports; `BOARD=ecpix5-ddr3` places, routes and writes a bitstream, which has never been on a board. Part 27 above has the change, the tests and what they found.
What it does not settle is on the board: that the pins of an idle slot meet the DRAM's setup and hold, and that a reset of the controller alone (a bitstream loaded
with the board powered, or `ndmreset` from the debugger) recovers a DRAM that was not reset. Left here, struck rather than deleted, as the record of what this entry
used to say:

**OPEN - the DDR3 controller assumes pins the ECPIX-5 does not have (Phase 9, Stage 1,
Part 21; what the board does instead is settled, the controller is not yet changed).** Two independent descriptions of the
board list no CS# and no RESET# for its DDR3, so the FPGA cannot drive either: the CS# path in the PHY (a deselect in every
idle command slot) has no pin to happen on, and the initialisation sequence's RESET# pulse cannot be issued. CK# and DQS# are
the negative halves of differential pairs and are not separate ports. The part is x16 and lane 1, its strobe and its data
mask are driven like lane 0's (Parts 22, 25 and 26).
Found by place-and-route with the real pins, which refuses to place the CS# path. Part 21 recorded it as needing a schematic, and said there
was none. **There is one** (found 2026-10-18, Stage 2 Part 15): LambdaConcept's documentation links the board's schematic,
`docs.lambdaconcept.com/ecpix-5/_static/resources/SCH_ECPIX-5_R02.PDF`, revision R02, 3 June 2020. Its DDR3 sheet (7) ties the DRAM's
CS# (ball L2) to ground through R33, 4.7 kΩ: always selected, not the FPGA's. Its RESET# (ball T2) is driven by the board's reset
circuit (sheet 3): an open-drain buffer, U8 (74LVC07), fed by the MAX6420 supervisor, U9, and pulled up to 1.5 V by R22; it does not
reach the FPGA. The FPGA sheet (5) has a ball for every other DDR net and none for these two. So the controller has two things to
change, and neither has been done: with CS# always low, an idle command slot must be a NOP (RAS#, CAS# and WE# high) on the command
pins, where the design now deselects, which changes the PHY and what the protocol checker treats as idle; and the initialisation
sequence can only wait out its timings, not pulse RESET# (the board resets the DRAM with its own reset button and power-up
supervisor, the same event that resets the FPGA's logic through `rst_n`). Until then `BOARD=ecpix5-ddr3` places CS#, RESET#, CK#
and A15 on throwaway pins and writes no bitstream. Two defects place-and-route found in the same run - a tri-state control with
the wrong polarity, and read-FIFO pointers never wired - are RESOLVED (Part 21).

## Hardware

*Physical board testing: what has and has not run on a real board.*

Nothing has touched a real DDR3 chip: no ECPIX-5 is attached to the work recorded here, Stage 0's "Done when" (real hardware, a measured Fmax on silicon) is wholly unmet, and Stage 3, real silicon, is still a plan. What exists is a diagnostic-scale bitstream, place-and-route on the real device with the board's DDR3 pins - of the PHY alone (Part 21) and of the whole SoC with the controller in it (Stage 2, Part 15) - and, since Stage 1, Part 27 changed the controller to the board's pins (no CS#, RESET#, CK# or A15), a bitstream of the whole SoC with the controller in it (`BOARD=ecpix5-ddr3`), which has never been loaded onto a board.

## Software

*Simulation and formal checking: what has and has not been shown without a board.*

The DDR3 PHY and controller are proven here only against a behavioural DDR3 and DQ model: init and calibration, the DQ/DQS data path on both byte lanes (the controller moves 16-bit words with a byte enable per lane, Part 26), write, read and refresh sequencers, a bounded formal proof of the control plane (Part 20), and the same tests under Verilator and in CI (Part 19). Stage 2 adds `rtl/soc/wb_ddr.v`, a Wishbone slave at `0xA0000000` (the part's whole 512 MB, both byte lanes, Part 14) behind `DDR3_ENABLE`, with `sim_ddrcheck`, `sim_ddratomics`, `sim_ddrexec` (instruction fetch from DDR3, Part 9) and `sim_uartload_ddr3` (the boot ROM's UART loader into DDR3, Part 10) in `make verify`. `sim_ddrmmutest` (a paged Sv32 access with the root table and a level-2 table in DDR3, Part 11, which closed the paged-access hang; Part 12 added execution out of DDR3 and page faults through DDR3 tables; Part 13 added atomics, a read-only page, a PMP-denied
frame, alignment, instruction faults and faults delegated to S-mode, and found a wide-core bug) is in `make verify` as well. The behavioural model plays the board's DRAM since Part 27: no CS# (every CK edge is a command slot and an idle one is the NOP), a RESET# that the testbench drives as the board's reset circuit does, and a check of the 500 us from RESET# to CKE; the CPU-driven tests read its verdict and the DQ model's, which they did not before that part.
