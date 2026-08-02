# FPGA integration — status and honest caveats

**The design builds all the way to a bitstream on an ECP5, at a measured
28 MHz. It has never been loaded onto hardware.** Those are different claims:

| Artifact | Status |
|---|---|
| Full SoC synthesis (`synth_ecp5`) | ✅ **runs, 54 s** |
| Place-and-route (`nextpnr-ecp5`) | ✅ **runs, 2 min**, timing closes at 25 MHz |
| Bitstream (`ecppack`) | ✅ **1.1 MB `soc_fpga.bit`** |
| Resource usage | ✅ **measured** — 31% LUT, 62% block RAM of an LFE5U-45F |
| Achievable Fmax | ✅ **28.25 MHz measured post-route** — see the critical path below |
| `constraints/generic.lpf` | ❌ **Placeholder pins.** Timing was measured with I/O unconstrained |
| `synth/vivado.tcl` | ❌ never executed |
| Running on a board | ❌ no board |

`fpga/synth/synth_ecp5.sh` runs the whole flow and has been executed end to
end. What has no evidence is that it works against **real pins on a real
board** — the pinout is still fictional, and 28 MHz is a number from a build
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

Yosys 0.67 is installed, so everything below is a real synthesis run rather
than an estimate. Place-and-route is still not: `nextpnr-ecp5` needs the
oss-cad-suite bundle and Homebrew ships `nextpnr-ice40` only. **So area is
measured; Fmax and timing closure are not.**

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
Max frequency for clock 'clk': 28.25 MHz   (post-route)
```

`fpga/constraints/timing_only.lpf` therefore constrains the clock to 25 MHz,
which closes. The design is roughly **2-5x slower than the guess**, which is
worth stating plainly rather than quietly editing the range downward - an
untested estimate of a critical path is not evidence, and this is the whole
reason for running the tool.

Two numbers appear in nextpnr's log: 22.88 MHz after placement and 28.25 MHz
after routing. The second is the real one; the first is an estimate made
before the router has had a chance to fix anything.

### Utilization (LFE5U-45F, CABGA381, 64 KB RAM)

```
LUT4          13837 / 43848    31%
DP16KD           67 /   108    62%    <- block RAM is the binding resource
MULT18X18D        4 /    72     5%
TRELLIS_IO       28 /   245    11%
DCCA              1 /    56     1%
```

### The critical path

Not the interconnect, and not the multiplier - both of which this file
previously named as prime suspects. It is:

> **block RAM read data -> the AMO ALU -> bus write data**

starting at a DP16KD's 5.83 ns clock-to-out and running through
`cpu_core.v`'s `amo_new_value` mux, which accounts for 12 of the path's
hops. That mux contains the AMOMIN/AMOMAX signed and unsigned 32-bit
comparators, and it is fed combinationally from `dmem_rdata` - which on an
ack cycle is combinationally the RAM's output - and drives `dwb_dat_w`
straight back out to the bus.

So an atomic's read-modify-write is, as far as static timing is concerned,
one enormous combinational loop from memory back to memory. The fix is to
register the AMO result between the read and write phases: `cpu_wb.v`
already latches the read data in `rdata_q`, so the machinery is half there,
and an AMO taking one extra cycle costs nothing measurable.

### One optimization tried, and reverted

Before finding the AMO path, the obvious-looking target was the *other* long
chain the report shows: RAM output -> MMU walk result -> physical address ->
bus address decode. Making a completed page-table walk answer through the
TLB it had just filled (instead of combinationally from the walk result)
should have cut that chain at its source.

It was reverted, for two independent reasons:

1. **It measured no faster** - 28.25 MHz before, 26.61 MHz after, which is
   placement noise either side of the same number. The AMO path was the real
   constraint all along.
2. **It was wrong.** The TLB is looked up with the *live* virtual address,
   and for a data access that address is `op1 + imm` recomputed from
   forwarding every cycle; across a multi-cycle walk the pipeline drains
   underneath it and the value decays. The walk result used the latched
   `va_r` and was immune. This is the same operand-drift hazard as the
   misaligned-address bug in ARCHITECTURE.md section 12b, and the Spike
   co-simulation caught it within one run - `rv32si-p-dirty` taking a load
   page fault the reference model never takes.

Worth recording because the lesson generalizes: the critical path the tool
reports is the one to fix, not the one that looks worst by inspection.

### What would actually raise Fmax

In order of expected benefit:

1. **Register the AMO result** (above). Directly targets the measured path.
2. **Pipeline the bus response.** Address decode -> slave select -> response
   mux -> `ack` -> the CPU's stall logic is still a long chain, and it is
   what the second-longest paths run through.
3. **Pipeline the multiplier.** Three 32x32->64 products resolve in one EX
   stage. They map to DSPs on ECP5 so they are not currently critical, but
   they would be on a device without them.

## What is genuinely missing for "boots on hardware"

- **External DRAM.** `wb_ram.v` is 256 KB of on-chip memory. LiteDRAM is the
  usual answer, and it needs LiteX (a Python generator) plus a board with
  DDR — neither was available here. `wb_ram.v`'s header marks the seam.
- **JTAG debug.** No RISC-V Debug Module, no TAP. Debugging is UART `printf`
  and the LEDs.
- **Ethernet.** Not attempted.
- **Flash-based boot.** The boot ROM loads from SD; a real board usually
  also wants to boot from SPI flash.
