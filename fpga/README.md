# FPGA integration — status and honest caveats

**The design builds all the way to a bitstream on an ECP5, at a measured
31 MHz. It has never been loaded onto hardware.** Those are different claims:

| Artifact | Status |
|---|---|
| Full SoC synthesis (`synth_ecp5`) | ✅ **runs, 54 s** |
| Place-and-route (`nextpnr-ecp5`) | ✅ **runs, 2 min**, timing closes at 25 MHz |
| Bitstream (`ecppack`) | ✅ **1.1 MB `soc_fpga.bit`** |
| Resource usage | ✅ **measured** — 27% LUT, 62% block RAM of an LFE5U-45F |
| Achievable Fmax | ✅ **30.64 MHz measured post-route** — see the critical path below |
| `constraints/generic.lpf` | ❌ **Placeholder pins.** Timing was measured with I/O unconstrained |
| `synth/vivado.tcl` | ❌ never executed |
| Running on a board | ❌ no board |

`fpga/synth/synth_ecp5.sh` runs the whole flow and has been executed end to
end. What has no evidence is that it works against **real pins on a real
board** — the pinout is still fictional, and 31 MHz is a number from a build
where nextpnr could place I/O wherever it liked.

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
[Utilization](#utilization-lfe5u-45f-cabga381-64-kb-ram). Only that one
configuration has been rebuilt since.

Full `soc_fpga` (CPU + Wishbone interconnect + boot ROM + RAM + CLINT + PLIC
+ UART + GPIO + SPI), `synth_ecp5`, by on-chip RAM size:

| RAM | LUT4 | FF | DP16KD (block RAM) | MULT18X18D |
|---|---|---|---|---|
| 32 KB | 12,289 | 6,684 | 38 | 4 |
| 64 KB | 12,363 | 6,687 | 67 | 4 |
| 128 KB | 12,591 | 6,691 | 126 | 4 |
| 256 KB | 12,512 | 6,695 | 244 | 4 |

Against the parts:

| Device | LUTs | EBRs | Verdict |
|---|---|---|---|
| LFE5U-25F | 24,288 | 56 | fits **at 32 KB RAM** (51% LUT, 68% EBR) |
| LFE5U-45F | 44,000 | 108 | fits **at 64 KB RAM** (28% LUT, 62% EBR) |
| LFE5U-85F | 208,000 | 208 | fits **at 128 KB RAM** |
| any ECP5 | — | ≤208 | **256 KB does not fit** — 244 EBRs needed |

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

1. **Replace every pin in the constraints file.** They are placeholders
   copied from no board in particular. Your vendor publishes a master
   constraints file; start from that.
2. **Set `CLK_HZ` in `soc_fpga.v` to your board's actual oscillator.** The
   UART divisor is derived from it. Getting this wrong produces a console
   that emits garbage even when timing closes perfectly — and it looks like
   a CPU bug, not a configuration one.
3. **Run `make soc` first.** `wb_rom.v` pulls `bootrom.hex` in with
   `$readmemh` at elaboration time, which makes it a *synthesis* input, not
   just a simulation one. Both scripts check for it and refuse to start
   without it, because the failure mode otherwise is a board that comes up
   and does nothing.

## Timing: measured, and the prediction was wrong

This section used to say 50-150 MHz was "plausible for a core this size".
Place-and-route says otherwise:

```
Max frequency for clock 'clk': 30.64 MHz   (post-route)
```

`fpga/constraints/timing_only.lpf` therefore constrains the clock to 25 MHz,
which closes. The design is roughly **2-5x slower than the guess**, which is
worth stating plainly rather than quietly editing the range downward - an
untested estimate of a critical path is not evidence, and this is the whole
reason for running the tool.

Two numbers appear in nextpnr's log: 24.05 MHz after placement and 30.64 MHz
after routing. The second is the real one; the first is an estimate made
before the router has had a chance to fix anything.

### Utilization (LFE5U-45F, CABGA381, 64 KB RAM)

```
LUT4          11977 / 43848    27%
DP16KD           67 /   108    62%    <- block RAM is the binding resource
MULT18X18D        4 /    72     5%
TRELLIS_IO       28 /   245    11%
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
build reports 30.64 MHz - a later, logically unrelated edit moved it. See
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

> **forwarding mux -> EX-stage address adder**

32.64 ns, of which **23.64 ns is routing and only 9.00 ns is logic**. Unlike
every previous one this path starts at an ordinary flip-flop (0.52 ns
clock-to-out, not a block RAM's 5.83), runs through `cpu_core.v`'s operand
forwarding muxes at line 565 into the `op1 + id_ex_imm` effective-address
adder at line 645, and spends 14 hops in that adder's carry chain.

There is not much logic left to remove here: **72% of this path is wire**.

### Placement sensitivity: a calibration

Immediately after the AMO retiming the critical path was
`block RAM read data -> MMU walk result -> PC` at 31.93 ns / 31.32 MHz. Then
a four-bit change to which signals drive the status LEDs in
`fpga/soc_fpga.v` - no change to the CPU, the bus, or any peripheral -
produced:

| | Before the LED edit | After |
|---|---|---|
| Fmax | 31.32 MHz | 30.64 MHz |
| LUT4 | 11,977 | **11,977** |
| TRELLIS_FF | 6,719 | **6,719** |
| Critical path | RAM -> MMU walk -> PC | forwarding mux -> address adder |

Identical logic area, a completely different critical path, and 0.68 MHz.

This is **not** run-to-run noise: nextpnr is deterministic for a given
netlist, and the pre-AMO design was placed twice and reported 28.25 MHz both
times. It is placement being a global optimization - perturb anything and
every path is re-diced.

The practical consequence, and the reason this is written down: **do not read
much into sub-MHz Fmax differences on this design, and do not attribute one
to whatever you happened to be editing.** A change is only demonstrated to
have helped timing if it also moves the critical path off the structure it
targeted - which is what the AMO retiming did, and is the evidence that
mattered there rather than the +3.07 MHz.

The reverted MMU experiment in the next section is the same lesson learned
the expensive way: it was tried before the AMO path was found, and is a
warning rather than a starting point - that rewrite was independently
*incorrect*, and its correctness problem has nothing to do with whether it
would help timing now. With routing at 72% of the path, logic-depth changes
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
   rather than last. The critical path is 72% wire and only 9 ns of logic;
   the design occupies 27% of an LFE5U-45F and is spread across all of it.
   Constraining related logic into neighbouring regions, or fitting a 25F at
   `RAM_BYTES=32768`, attacks the part that is actually large.
3. **Shorten the EX-stage address path**, which is what the critical path is
   now: forwarding mux -> `op1 + id_ex_imm`. The forwarding muxes sit in
   front of the adder, so the operand is late before the addition even
   starts. Computing the address from a pre-forwarded operand, or splitting
   the adder, are both plausible - but see the calibration above before
   believing any single measurement of the result.
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
