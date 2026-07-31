# FPGA integration — status and honest caveats

**Nothing in this directory has been synthesized, placed, routed, timed, or
run on hardware.** The environment this was developed in had no FPGA
toolchain at all — no yosys, no nextpnr, no Vivado, no Quartus — and no board
attached. Everything here was written from the standard flows and checked as
far as it could be, which is elaboration and lint only.

That distinction matters, so it is worth being precise about what *is* known:

| Artifact | Status |
|---|---|
| `soc_fpga.v` | Elaborates (Icarus) and lints clean (Verilator `-Wall`) |
| `top_fpga.v` | Same, unchanged from before the SoC existed |
| `constraints/*.xdc`, `*.lpf` | **Placeholder pins.** Never parsed by any tool |
| `synth/synth_ecp5.sh` | Never executed |
| `synth/vivado.tcl` | Never executed |
| Achievable Fmax | **Unknown.** No timing analysis was ever run |
| Resource usage | **Unknown.** No synthesis was ever run |

The RTL itself is thoroughly simulated — `make sim`, `make sim_software` and
`make sim_soc` all pass — so the *logic* has real evidence behind it. What
has no evidence is that it meets timing, fits, or works against real pins.

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
- **`wb_ram.v`'s asynchronous read.** It is written as combinational-read
  RAM, which infers distributed RAM (LUTRAM) rather than block RAM on some
  tools — expensive in area and slow. If utilization looks absurd, this is
  why. Converting it to a registered (synchronous) read makes it infer block
  RAM properly, but that changes it to a 1-wait-state slave, which means
  `wb_interconnect.v`'s "instruction master must only reach zero-wait-state
  slaves" note stops holding and the arbiter needs a sticky grant.

That last one is the most likely thing to bite, and it is a design decision
this project deliberately deferred rather than an oversight: asynchronous
read is what let the whole SoC stay zero-wait-state and keep the pipeline
timing identical to the pre-bus design, which is exactly what made the
simulation results comparable.

## What is genuinely missing for "boots on hardware"

- **External DRAM.** `wb_ram.v` is 256 KB of on-chip memory. LiteDRAM is the
  usual answer, and it needs LiteX (a Python generator) plus a board with
  DDR — neither was available here. `wb_ram.v`'s header marks the seam.
- **JTAG debug.** No RISC-V Debug Module, no TAP. Debugging is UART `printf`
  and the LEDs.
- **Ethernet.** Not attempted.
- **Flash-based boot.** The boot ROM loads from SD; a real board usually
  also wants to boot from SPI flash.
