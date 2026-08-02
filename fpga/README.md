# FPGA integration — status and honest caveats

**The design synthesizes and fits an ECP5. It has never been placed, routed,
timed, or run on hardware.** Those are different claims and the difference
matters, so:

| Artifact | Status |
|---|---|
| Full SoC synthesis (`synth_ecp5`) | ✅ **runs, 54 s** — numbers below |
| Resource usage | ✅ **measured** — fits an LFE5U-45F at 64 KB RAM |
| `soc_fpga.v`, `top_fpga.v` | Elaborate (Icarus), lint clean (Verilator `-Wall`) |
| Place-and-route | ❌ never run — `nextpnr-ecp5` needs oss-cad-suite, Homebrew ships ice40 only |
| Achievable Fmax | ❌ **unknown**, and it stays unknown until PnR runs |
| `constraints/*.xdc`, `*.lpf` | ❌ **Placeholder pins.** Never parsed by any tool |
| `synth/vivado.tcl` | ❌ never executed |
| Running on a board | ❌ no board |

So: the logic is thoroughly simulated (`make verify`), and the design is now
known to map to real primitives in a real device's budget. What still has no
evidence is that it *meets timing* or works against real pins.

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

## What to expect on timing

The target you mentioned, 50–150 MHz, is plausible for a core this size but
genuinely untested here. If it doesn't close, these are the paths to look at
first, in rough order of suspicion:

- **`wb_interconnect.v`'s combinational path.** Address decode → slave
  select → response mux → `ack` back to the master, all in one cycle, and
  then `ack` feeds the CPU's stall logic. This is the longest new path the
  SoC introduces. The standard fix is to register the response and go to a
  1-wait-state bus, which costs a cycle per access but breaks the path
  cleanly.
- **`cpu_core.v`'s EX stage.** The ALU, the branch comparator, the
  forwarding muxes, the CSR read/modify path and the trap-priority mux all
  resolve in one stage, and the multiplier (`mul_ss`/`mul_uu`/`mul_su`,
  three 64-bit products) sits in there too. On a small FPGA the multiplier
  is very often the critical path; pipelining it over two cycles behind the
  existing `ex_busy_stall` mechanism would be the natural fix, and that
  mechanism already exists for the divider.
- **`wb_ram.v`'s asynchronous read.** Already confirmed to be a blocker —
  see the measured section above. This has to be fixed before any full-SoC
  synthesis run will even terminate.

That last one was the most likely thing to bite, and it did. It is a design
decision this project deliberately deferred rather than an oversight:
asynchronous read is what let the whole SoC stay zero-wait-state and keep
the pipeline timing identical to the pre-bus design, which is exactly what
made the simulation results comparable.

## What is genuinely missing for "boots on hardware"

- **External DRAM.** `wb_ram.v` is 256 KB of on-chip memory. LiteDRAM is the
  usual answer, and it needs LiteX (a Python generator) plus a board with
  DDR — neither was available here. `wb_ram.v`'s header marks the seam.
- **JTAG debug.** No RISC-V Debug Module, no TAP. Debugging is UART `printf`
  and the LEDs.
- **Ethernet.** Not attempted.
- **Flash-based boot.** The boot ROM loads from SD; a real board usually
  also wants to boot from SPI flash.
