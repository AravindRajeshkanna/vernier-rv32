# FPGA integration — status and honest caveats

**The design builds to a ULX3S bitstream against that board's real pinout and
closes timing at 25 MHz — 30.77 MHz on an 85F, 28.78 MHz on a 45F. It has
never been loaded onto hardware.** Those are different claims:

| Artifact | Status |
|---|---|
| Full SoC synthesis (yosys) | ✅ **runs, ~19 s** |
| Place-and-route (`nextpnr-ecp5`) | ✅ **runs** — 4 min on an 85F, 11 min on a 45F |
| Bitstream (`ecppack`) | ✅ **`ulx3s_top.bit`** — 1.1 MB on a 45F, 2.1 MB on an 85F |
| Resource usage | ✅ **measured** — 27% LUT / 62% EBR on a 45F, 14% / 32% on an 85F |
| **Real pinout** | ✅ **`constraints/ulx3s.lpf`**, every pin placed, no `--lpf-allow-unconstrained` |
| **Fmax with I/O constrained** | ✅ **30.77 MHz** (85F) / **28.78 MHz** (45F), PASS at the board's 25 MHz |
| `constraints/generic.lpf` | ❌ still placeholders — superseded by `ulx3s.lpf` |
| `synth/vivado.tcl` | ❌ never executed |
| Running on a board | ❌ **no board** |

The pinout is no longer fictional, which is a smaller claim than "this works"
but a real one: the numbers above come from builds where every port is locked
to the pin it will actually use, rather than ones where nextpnr could place
I/O wherever suited it. When that constraint was first applied it cost about
1 MHz (30.38 → 29.37 on a 45F), less than expected.

**What is still unproven is everything that needs a board**: that the ESP32
hold-off is sufficient in practice, that a real SD card answers the boot ROM,
that the FTDI console is legible, that the design works at temperature. None
of that is knowable from here.

## Building for a ULX3S

**The 45F and the 85F both work; the 12F and 25F do not.** The ULX3S ships
with four FPGA options, and at the default 64 KB of on-chip RAM the two
smaller ones are over their block-RAM budget by 19% and fail to place. Both
supported parts have their own build target below, and both close timing.
Measured numbers for all four are in [Which ECP5 this
fits on](#which-ecp5-this-fits-on).

The board's **32 MB of SDRAM is external to the FPGA and present on every
variant**, so it neither helps nor hurts this choice — and nothing here can
reach it yet, because there is no memory controller.

```bash
make soc                                     # boot ROM image is a synthesis input
BOARD=ulx3s85 ./fpga/synth/synth_ecp5.sh     # LFE5U-85F
# or:  BOARD=ulx3s ./fpga/synth/synth_ecp5.sh   for the 45F
openFPGALoader -b ulx3s fpga/build/ulx3s_top.bit
```

**The FPGA variant is part of the board target, not a separate knob.** A
bitstream is device-specific and will not load on a different ECP5, the four
ULX3S variants are indistinguishable in a photo, and a stale `DEVICE=`
default would fail in a way that looks like a broken design rather than a
wrong command line. Both targets share the same pinout, wrapper and LPF and
differ only in the chip. The build prints its target up front and again on
the bitstream line.

| Target | Device | Fmax | LUT | EBR |
|---|---|---|---|---|
| `BOARD=ulx3s` | LFE5U-45F | 28.78 MHz | 29% | **105/108 — 97%** |
| `BOARD=ulx3s85` | LFE5U-85F | **30.77 MHz** | 15% | 105/208 — 50% |

Both close comfortably at the board's 25 MHz, but they are no longer
equivalent: **the 45F is now at 97% block RAM** and has room for essentially
nothing else, while the 85F is at half. That gap is the framebuffer, which
costs 38 EBR — see [Framebuffer cost](#framebuffer-cost).

**Check your board revision first.** The four SD pins used for SPI mode are
wired differently on **v1.7** than on v2.0/v3.0, and `constraints/ulx3s.lpf`
is for the latter:

| | v2.0 / v3.0 | v1.7 |
|---|---|---|
| sck | H2 | J1 |
| mosi | J1 | J3 |
| miso | J3 | K2 |
| cs_n | K2 | H1 |

On a v1.7 board the design builds, loads, and fails to find the card, because
all four signals land on the wrong pins.

Three board details that `fpga/ulx3s_top.v` handles and that are easy to get
wrong by hand: the buttons are **active high** (so reset is inverted, and
`btn[0]` is the power button rather than a general one), `wifi_gpio0` must be
**driven high** or the ESP32 can reset the board underneath a running design,
and `sd_d[2:1]` are unused in SPI mode but must not float. `make verify`
checks all three, plus GPIO bidirectionality — see `sim/tb_ulx3s.v`.

Running at some other frequency needs `CLK_HZ` in `fpga/soc_fpga.v`, `CPU_HZ`
in `software/soc/soc.h`, and `CLK_PERIOD` in `sim/tb_soc.v` changed together;
nothing checks that they agree. The ULX3S needs no PLL because its 25 MHz
oscillator is already below the design's Fmax. A faster board does:
`ecppll -i <osc_mhz> -o 25 -n pll --file pll.v` generates one.

### Getting the toolchain

There is no Homebrew cask for oss-cad-suite and no `nextpnr` formula.
(`prjtrellis` is a formula and provides the ECP5 database plus `ecppack`, but
not `nextpnr-ecp5`, which is the piece that matters.) Use YosysHQ's bundle:

```bash
curl -L -o oss-cad-suite.tgz \
  https://github.com/YosysHQ/oss-cad-suite-build/releases/latest/download/oss-cad-suite-darwin-arm64-<date>.tgz
tar xzf oss-cad-suite.tgz -C ~/tools
export PATH=~/tools/oss-cad-suite/bin:$PATH
```

## Measured: the SoC synthesizes, and fits an ECP5

Everything below is a real synthesis run rather than an estimate, and so is
the timing further down — place-and-route runs too, from the oss-cad-suite
bundle described above. **Area, Fmax and timing closure are all measured.**

The per-RAM-size table below predates the AMO retiming and so shows the
older, higher LUT counts; the 64 KB row's current numbers are in
[Utilization](#utilization-lfe5u-45f-cabga381-64-kb-ram-ulx3s-pinout). Only that one
configuration has been rebuilt since.

Full `soc_fpga` (CPU + Wishbone interconnect + boot ROM + RAM + CLINT + PLIC
+ UART + GPIO + SPI), `synth_ecp5`, by on-chip RAM size:

| RAM | LUT4 | FF | DP16KD (block RAM) | MULT18X18D |
|---|---|---|---|---|
| 32 KB | 12,289 | 6,684 | 38 | 4 |
| 64 KB | 12,363 | 6,687 | 67 | 4 |
| 128 KB | 12,591 | 6,691 | 126 | 4 |
| 256 KB | 12,512 | 6,695 | 244 | 4 |

### Framebuffer cost

`rtl/soc/wb_framebuffer.v` adds a 320x240 8bpp buffer (75 KB) and its
scan-out. Measured on the 85F, before and after:

| | Before | After | Δ |
|---|---|---|---|
| DP16KD | 67 | 105 | **+38** |
| LUT4 | 11,837 | 12,758 | +921 |
| TRELLIS_FF | 6,721 | 6,723 | +2 |

38 block RAMs for 75 KB is about 0.5 EBR/KB - near the theoretical minimum,
and notably *better* than `wb_ram.v`'s 0.95 EBR/KB for the same organization.
That was not predicted and is not fully explained; it is recorded as measured.

`FB_WIDTH`/`FB_HEIGHT` are parameters on `soc_top.v` precisely because this is
what decides which parts still fit. At the default the design fits both
supported ULX3S variants, but only just on the 45F.

Fmax also moved, 27.91 -> 30.77 MHz on the 85F. **That is not the framebuffer
making the design faster** - it is the placement sensitivity documented below,
re-rolled by adding ~900 LUTs. Do not read a speedup into it.

### Which ECP5 this fits on

Device capacities below are **as reported by nextpnr itself**, not transcribed
from a datasheet — an earlier version of this table claimed the 85F had
208,000 LUTs, which was its block-RAM count in the wrong column. Verdicts are
from actually attempting the build at `RAM_BYTES=65536`.

| Device | LUT4 | EBR | MULT18X18D | I/O | Verdict at 64 KB RAM |
|---|---|---|---|---|---|
| LFE5U-12F | 24,288 † | 56 | 28 | 197 | ❌ **needs 67 EBR — 119%** |
| LFE5U-25F | 24,288 | 56 | 28 | 197 | ❌ **needs 67 EBR — 119%** |
| LFE5U-45F | 43,848 | 108 | 72 | 245 | ✅ 29% LUT, **97% EBR**, 28.78 MHz |
| LFE5U-85F | 83,640 | 208 | 156 | 365 | ✅ 15% LUT, 50% EBR, **30.77 MHz** |

† **nextpnr targets the 25F resource database for `--12k`** — the two are the
same silicon, with the 12F sold as a reduced-capacity part. So a design that
"fits `--12k`" may still exceed what Lattice specifies for a 12F. Treat the
12F row as no better than the 25F row, and do not rely on the surplus.

Both smaller parts fail the same way and it is worth quoting, because it is
unambiguous about which resource is binding:

```
ERROR: Unable to place cell 'SOC.SOC.RAM.mem.1.7',
       no BELs remaining to implement cell type 'DP16KD'
```

Halving to `RAM_BYTES=32768` does fit the 25F die — 38/56 EBR, 12,380 LUTs,
27.70 MHz — but at ~51% LUT occupancy on a part marketed as having 12K LUTs,
with the SDRAM controller and caches that any larger goal needs still to come.

**Which part is faster has flipped, and that is the lesson.** Before the
framebuffer the 85F measured *slower* than the 45F (27.91 vs 29.37) and this
file said so, reasoning that a bigger die means longer routes. After the
framebuffer the order reverses: 30.77 on the 85F against 28.78 on the 45F.

Nothing about either die changed. What changed is that the 45F is now at 97%
block RAM, and a nearly-full device gives the placer far less freedom - which
also shows in the build time, 11 minutes against the 85F's 4. Treat "bigger is
slower" as the guess it was; the reason to pick the 85F is headroom, and on
this design headroom is now buying speed too.

Either supported part is a reasonable choice. The **45F** is the fastest of
the four and has ample room for a memory controller and caches. The **85F**
costs ~1.5 MHz and buys roughly four times the headroom, which matters if
external DRAM and a cache hierarchy are the plan. Both are measured above and
both have a build target.

The 256 KB simulation default fits **no ECP5** — 244 EBRs against the 85F's
208.

`fpga/soc_fpga.v`'s `RAM_BYTES` parameter defaults to 64 KB, and
`software/soc/soc.h` and `link_ram.ld` are built to match, so the firmware
that `make sim_soc` runs is the same firmware a 45F build would run. The
256 KB in `soc_top.v` is a simulation-only default.

Logic is essentially flat across RAM sizes, as it should be - only the memory
changes. The block RAM cost is about 0.95 EBR per KB, roughly 2x the
theoretical minimum, because a 32-bit dual-port memory with byte write
enables cannot use a DP16KD's full 18 Kbit in one instance.

### The core alone, iCE40 vs ECP5

| | iCE40 (`synth_ice40`) | ECP5 (`synth_ecp5`) |
|---|---|---|
| LUTs | 11,859 SB_LUT4 | 8,995 LUT4 |
| FFs | 5,729 | 6,035 |
| Multiplier | in LUTs | 4x MULT18X18D |

The largest iCE40 `nextpnr-ice40` targets is the HX8K at 7,680 LUTs, so **the
bare core still overshoots the biggest iCE40 by ~55%** and the iCE40 path
remains dead. The ~2,900-LUT difference on ECP5 is the multiplier: `cpu_core.v`
computes three full 32x32->64 products combinationally to cover
MUL/MULH/MULHSU/MULHU, and an ECP5 has DSP blocks to absorb them where an
iCE40 has none.

## What used to make synthesis hang, and why

Full-SoC synthesis previously ran for over ten minutes and was abandoned. It
now completes in **54 seconds**. There were two independent causes, and it is
worth recording both because only the first was ever suspected:

1. **`wb_ram.v` had asynchronous reads.** A block RAM's read port is
   registered, so yosys could not map it and fell back to building 256 KB out
   of flip-flops. Fixed by making the memory word-organized with synchronous
   reads and two ports instead of four - which costs one wait state, and
   forced a matching rework of the bus arbiter (a multi-cycle slave needs a
   locked grant) and of the MMU's page-table walker (which had assumed its
   PTE read landed combinationally).

2. **The memories' zero-fill `initial` loops.** This was the bigger one, and
   it was invisible until the first was fixed. Yosys unrolls
   `for (i = 0; i < WORDS; i = i + 1) mem[i] = 0;` into one assignment per
   word: **~43 seconds for a 1024-word array**, and effectively forever at
   65,536. The loops are simulation-only (Verilog leaves an unwritten array X,
   and the testbenches load images far smaller than the memory), so they are
   now behind `` `ifndef SYNTHESIS ``. With that one guard the same 256 KB
   array elaborates and maps to block RAM in 1.3 seconds.

   Anyone tempted to remove that guard for tidiness should re-measure first.

## Before you run any of this

On a ULX3S none of the first two apply — `constraints/ulx3s.lpf` has real
pins and `fpga/ulx3s_top.v` is already set for a 25 MHz oscillator. **For any
other board:**

1. **Replace every pin in the constraints file.** `constraints/generic.lpf`
   is still placeholders copied from no board in particular. Your vendor
   publishes a master constraints file; start from that, and write a board
   wrapper alongside `ulx3s_top.v` rather than editing it.
2. **Set `CLK_HZ` in `soc_fpga.v` to your board's actual oscillator**, along
   with `CPU_HZ` in `software/soc/soc.h` and `CLK_PERIOD` in
   `sim/tb_soc.v` — nothing checks that the three agree. The UART divisor and
   the SD initialization clock are both derived from them, and getting either
   wrong produces a console emitting garbage, or a card that never answers,
   even when timing closes perfectly. Both look like CPU bugs rather than
   configuration ones. If the oscillator is faster than the design's Fmax you
   also need a PLL — see the `ecppll` line above.

Regardless of board:

3. **Run `make soc` first.** `wb_rom.v` pulls `bootrom.hex` in with
   `$readmemh` at elaboration time, which makes it a *synthesis* input, not
   just a simulation one. Both scripts check for it and refuse to start
   without it, because the failure mode otherwise is a board that comes up
   and does nothing.

## Timing: measured, and the prediction was wrong

This section used to say 50-150 MHz was "plausible for a core this size".
Place-and-route says otherwise:

```
Max frequency for clock 'clk_25mhz': 30.77 MHz   (post-route, real pins, 85F)
```

`fpga/constraints/timing_only.lpf` therefore constrains the clock to 25 MHz,
which closes. The design is roughly **2-5x slower than the guess**, which is
worth stating plainly rather than quietly editing the range downward - an
untested estimate of a critical path is not evidence, and this is the whole
reason for running the tool.

Two numbers appear in nextpnr's log: 22.99 MHz after placement and 30.77 MHz
after routing. The second is the real one; the first is an estimate made
before the router has had a chance to fix anything.

### Utilization (LFE5U-45F, CABGA381, 64 KB RAM, ULX3S pinout)

```
LUT4          11837 / 43848    26%
DP16KD           67 /   108    62%    <- block RAM is the binding resource
MULT18X18D        4 /    72     5%
TRELLIS_IO       54 /   245    22%
DCCA              1 /    56     1%
```

### The critical path, and the AMO chain that used to be it

The first place-and-route run put the critical path here:

> **block RAM read data -> the AMO ALU -> bus write data**

It started at a DP16KD's 5.83 ns clock-to-out and ran through
`cpu_core.v`'s `amo_new_value` mux, which accounted for 12 of the path's
hops - the AMOMIN/AMOMAX signed and unsigned 32-bit comparators. The mux was
fed combinationally from `dmem_rdata`, which on an ack cycle is
combinationally the RAM's output, and drove `dwb_dat_w` straight back out to
the bus. An atomic's read-modify-write was, to static timing, one
combinational chain from memory back to memory: 35.40 ns, 28.25 MHz.

Note that the chain is *functionally* dead in the cycle it is live - the bus
write-enable is low during an AMO's read phase, so that value is never
written. Static timing has no way to know that, and there is no clean way to
declare it a false path, which is exactly why it had to be fixed structurally
rather than annotated away.

**Fixed.** `cpu_core.v` now captures the read value in `amo_rdata_q` and runs
the ALU off *that* in the following cycle, so both ends of the comparators
are bounded by flops and neither reaches memory combinationally. The phase
state moved into the core, which deleted the duplicate state machine
`cpu_wb.v` was running to sequence the same two bus phases. Measured:

| | Before | After |
|---|---|---|
| Fmax (post-route) | 28.25 MHz | **31.32 MHz** |
| Critical path | 35.40 ns | **31.93 ns** |
| LUT4 | 13,837 (31%) | **11,977 (27%)** |
| TRELLIS_FF | 6,687 | 6,719 |

(Those are the numbers from the run that measured this change. The current
build reports 30.38 MHz - two later, logically unrelated edits moved it. See
[Placement sensitivity](#placement-sensitivity-a-calibration) below, which is
the more useful lesson of the two.)

The **+32 flip-flops are exactly `amo_rdata_q`** - the core's new phase bit
replaces the one deleted from `cpu_wb.v`, netting zero. The 1,860-LUT drop
was not predicted and is the larger surprise: feeding the comparators from a
plain register instead of from the shifted, muxed `dmem_rdata` net evidently
lets yosys share a great deal more logic.

**It cost no cycles.** All 82 riscv-tests run identical cycle counts before
and after, because the SoC already spent a cycle between the read
acknowledgement and issuing the write - the register slots into a gap that
was there anyway. `rtl/top.v`'s zero-latency memory has no such gap, so an
AMO there now occupies MEM for two cycles instead of one. That path is
simulation-only.

### The critical path now

> **PC -> instruction-fetch path -> PC**

32.91 ns, of which **24.76 ns is routing and only 8.15 ns is logic**. It
starts at an ordinary flip-flop (0.52 ns clock-to-out, not a block RAM's
5.83) and runs through `cpu_core.v`'s IF stage from line 170.

There is very little logic left to remove here: **75% of this path is wire**.

### Placement sensitivity: a calibration

Three consecutive builds, each separated by a change that touched almost
nothing, put the critical path in three completely different places:

| Build | Fmax | Critical path | Routing | LUT4 | FF |
|---|---|---|---|---|---|
| After the AMO retiming | 31.32 MHz | RAM -> MMU walk -> PC | 61% | 11,977 | 6,719 |
| After rewiring 4 status LEDs | 30.64 MHz | forwarding mux -> address adder | 72% | 11,977 | 6,719 |
| After adding a 2-flop MISO synchronizer | 30.38 MHz | PC -> fetch -> PC | 75% | 12,124 | 6,721 |
| With the real ULX3S pinout (45F) | 29.37 MHz | RAM -> MMU walk -> PC | 67% | 11,837 | 6,721 |
| **Adding the framebuffer (85F)** | **30.77 MHz** | — | — | 12,758 | 6,723 |
| The same netlist on a 45F | 28.78 MHz | — | — | 12,758 | 6,723 |

The last two rows are the same netlist on two dies, 2 MHz apart - and the
*larger* one is faster, because the smaller is at 97% block RAM and the placer
has nowhere to put things.

The last row is the only one that constrains I/O, and is the number to
believe for hardware. It is also the only change in the table with a
*mechanism* behind its movement — real pins are a genuine constraint on
placement, not a perturbation — and it still only cost 1 MHz.

The middle row is the striking one: **byte-identical LUT and flip-flop
counts**, a completely different critical path, and 0.68 MHz. Nothing in the
CPU, the bus or any peripheral changed - only which four signals drive the
board LEDs.

This is **not** run-to-run noise. nextpnr is deterministic for a given
netlist - the pre-AMO design was placed twice and reported 28.25 MHz both
times. It is placement being a global optimization: perturb anything, and
every path is re-diced.

Two things follow, and they are the reason this is written down:

1. **Do not attribute a sub-MHz Fmax change to whatever you were editing.**
   The noise floor for "I changed something unrelated" is comfortably several
   tenths of a MHz on this design.
2. **A timing change is only demonstrated when the critical path moves off
   the structure it targeted.** That is what the AMO retiming did - the AMO
   ALU vanished from the report - and it is the evidence that actually
   mattered there, more than the +3.07 MHz headline.

The reverted MMU experiment in the next section is the same lesson learned
the expensive way: it was tried before the AMO path was found, and is a
warning rather than a starting point - that rewrite was independently
*incorrect*, and its correctness problem has nothing to do with whether it
would help timing now. With routing at 75% of the path, logic-depth changes
alone have limited headroom here.

### One optimization tried, and reverted

Before finding the AMO path, the obvious-looking target was the *other* long
chain the report shows: RAM output -> MMU walk result -> physical address ->
bus address decode. Making a completed page-table walk answer through the
TLB it had just filled (instead of combinationally from the walk result)
should have cut that chain at its source.

It was reverted, for two independent reasons:

1. **It measured no faster** - 28.25 MHz before, 26.61 MHz after. This file
   originally called that "placement noise either side of the same number".
   That wording is wrong and has been left visible rather than quietly
   edited: nextpnr is deterministic for a given netlist, so 26.61 MHz was a
   reproducible result, not a dice roll. The accurate reading is the one in
   [Placement sensitivity](#placement-sensitivity-a-calibration) above - the
   edit perturbed placement, everything was re-diced, and the number moved
   for reasons unrelated to the chain being targeted. Either way the
   conclusion stands: it did not help, and the AMO path was the real
   constraint.
2. **It was wrong.** The TLB is looked up with the *live* virtual address,
   and for a data access that address is `op1 + imm` recomputed from
   forwarding every cycle; across a multi-cycle walk the pipeline drains
   underneath it and the value decays. The walk result used the latched
   `va_r` and was immune. This is the same operand-drift hazard as the
   misaligned-address bug in docs/ARCHITECTURE.md section 12b, and the Spike
   co-simulation caught it within one run - `rv32si-p-dirty` taking a load
   page fault the reference model never takes.

Worth recording because the lesson generalizes: the critical path the tool
reports is the one to fix, not the one that looks worst by inspection.

### What would actually raise Fmax

In order of expected benefit:

1. ~~**Register the AMO result.**~~ Done - 28.25 -> 31.32 MHz, see above.
2. **Floorplan, or move to a smaller device.** This is now first on merit
   rather than last, and by a wide margin. The critical path is 75% wire and
   only 8 ns of logic; the design occupies 27% of an LFE5U-45F and is spread
   across all of it. Constraining related logic into neighbouring regions, or
   fitting a 25F at `RAM_BYTES=32768`, attacks the part that is actually
   large. The three-build table above is also the argument for this: the
   critical path keeps relocating because *placement*, not logic depth, is
   what decides it.
3. **Shorten whichever pipeline path the tool currently names.** Recent
   builds have landed on the EX-stage forwarding-mux-into-address-adder chain
   and on the IF-stage PC loop. Both are plausible targets - but check the
   calibration above before believing any single measurement of the result,
   and confirm the path actually left the report.
4. **Pipeline the bus response.** Address decode -> slave select -> response
   mux -> `ack` -> the CPU's stall logic is still a long chain, and it is
   what the second-longest paths run through.
5. **Pipeline the multiplier.** Three 32x32->64 products resolve in one EX
   stage. They map to DSPs on ECP5 so they are not currently critical, but
   they would be on a device without them.

The walk-result -> PC chain that was critical immediately after the AMO
retiming is no longer, and was never worth chasing on its own - it moved
because of an unrelated edit, not because anything was done to it.

## What is genuinely missing for "boots on hardware"

- **External DRAM.** `wb_ram.v` is 256 KB of on-chip memory. LiteDRAM is the
  usual answer, and it needs LiteX (a Python generator) plus a board with
  DDR — neither was available here. `wb_ram.v`'s header marks the seam.
- **JTAG debug.** No RISC-V Debug Module, no TAP. Debugging is UART `printf`
  and the LEDs.
- **Ethernet.** Not attempted.
- **Flash-based boot.** The boot ROM loads from SD; a real board usually
  also wants to boot from SPI flash.
