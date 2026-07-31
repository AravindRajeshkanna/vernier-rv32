# RV32IMA Pipelined CPU (Verilog)

A small, working RISC-V (RV32IMA + Zicsr) 5-stage pipelined CPU core, with
full M/S/U privilege modes and trap delegation, timer/software/external
interrupts (a real prioritized/claimable PLIC), a Sv32 MMU covering both
data and instruction fetch, a BTB branch predictor, a self-checking
simulation testbench for macOS, and a minimal FPGA wrapper.

**Read the "Can this run Linux?" section before you get too attached to that
plan** — the honest answer is not with this core, and I explain why and what
the realistic path looks like.

## What's here

```
rtl/
  regfile.v      32x32-bit register file (with a same-cycle write bypass)
  imem.v         instruction memory (loaded from a hex file)
  dmem.v         byte-addressable data memory, 3 read ports (byte/half/word load-store)
  csr_file.v     M/S-mode CSRs (mstatus/sstatus/*tvec/*epc/*cause/mie/mip/satp/medeleg/mideleg/...)
  muldiv_div.v   multi-cycle DIV/DIVU/REM/REMU (restoring shift-subtract)
  mmu.v          Sv32 MMU: 8-entry TLB + 2-level walker (instantiated for data AND instruction fetch)
  btb.v          branch target buffer: 64-entry, 2-bit saturating counters
  clint.v        timer/software-interrupt peripheral (mtime/mtimecmp/msip)
  plic.v         prioritized/claimable external interrupt controller
  cpu_core.v     the CPU itself: 5-stage pipeline (IF/ID/EX/MEM/WB)
  top.v          simulation top level (cpu + imem + dmem + clint + plic)
sim/
  tb_top.v            self-checking testbench
  verilator_main.cpp  optional Verilator harness
  program.hex         hand-assembled RV32IMA test program
fpga/
  top_fpga.v     board-agnostic FPGA top level (drives LEDs from PC bits)
Makefile
```

This core implements the RV32I base integer ISA (LUI, AUIPC, JAL, JALR,
branches, loads/stores, all the immediate/register ALU ops), the **M**
extension (MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU), the **A** extension
(AMOSWAP/AMOADD/AMOXOR/AMOAND/AMOOR/AMOMIN(U)/AMOMAX(U)/LR/SC, word-only),
Zicsr, full **M/S/U privilege modes** with real trap delegation
(`medeleg`/`mideleg`, `SRET`, per-privilege CSR gating), timer/software/
external interrupts (the external source now a real **PLIC** — multiple
prioritized, claimable sources, not one wire), a **Sv32 MMU that covers
both data accesses and instruction fetch** (two independent TLBs/walkers
sharing one page-table structure), and a **BTB + 2-bit saturating-counter
branch predictor** — see `ARCHITECTURE.md` for the full pipeline/hazard/
privilege/interrupt/MMU design, including several real bugs found and
fixed along the way (a couple of pipeline hazards from an earlier update,
a page fault that could still commit its write, an MRET/SRET that could
complete despite being interrupt-preempted, and a PLIC priority-encoder
that picked the lowest matching source ID instead of comparing
priorities).

It does **not** implement superscalar issue or out-of-order execution —
still single-issue, in-order. That's the natural next step, but it's a
full microarchitecture redesign (register renaming, a reorder buffer,
reservation stations/scoreboard, multiple execution units) rather than an
additive change like everything above, so it's being treated as a
separate future effort instead of bolted onto this pipeline.

## 1. Simulate it on your Mac

```bash
brew install icarus-verilog gtkwave
# optional, for the faster/alternate simulator:
brew install verilator

cd riscv-fpga-cpu
make sim
```

Expected output ends with:
```
mem[0..3] (expect 15,0,0,0): 15 0 0 0
fail word (expect 0 = PASS): 0x00000000
BTB mispredict_count (expect 54): 54
TEST PASSED
```

The test program runs a series of checks back to back: the original
`5 + 10` arithmetic/store/load/branch/jump check; a load-use hazard;
ECALL/illegal-instruction traps; MUL/MULH/MULHSU/MULHU and DIV/DIVU/REM/
REMU (including divide-by-zero and the `INT_MIN/-1` overflow case); a
timer interrupt; a data-only-at-the-time Sv32 MMU round trip/page-fault/
`SFENCE.VMA` sequence (now run from S-mode, since translation only
applies below M); AMOADD/AMOSWAP round trips plus an LR/SC pair that
succeeds and one that's deliberately broken by an intervening store; a
full U→S→M→S→U privilege round trip through a delegated ECALL, an
undelegated ECALL, and `SRET`; a BTB-observability check on a bounded
loop (confirmed via an internal `mispredict_count`, not architecturally
visible to the program itself); a PLIC test with three sources at
different priorities/thresholds proving real claim/complete ordering;
and a deliberate instruction-fetch page fault. See the comment block in
`sim/tb_top.v` for the exact program. View the waveform with `make wave`
(opens GTKWave).

I hand-assembled the test program's encodings with a small Python script
(not part of the repo) and cross-checked several against the RV32I spec by
hand before handing this to you, so what you're running should behave as
described — but please still treat `make sim` as the real check, not my
word for it.

`make verilator` runs the same design through Verilator instead, producing
`sim/wave_verilator.vcd`.

## 2. Getting it onto an actual FPGA

This is genuinely board-dependent, and I don't know which board you have, so
I can't hand you a working bitstream flow — but here's the shape of it:

1. **Pick your toolchain based on your FPGA vendor:**
   - Lattice iCE40 (e.g. iCEBreaker, Alchitry Cu) → open-source flow:
     `brew install icestorm nextpnr yosys` (via the [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) tap is easiest on macOS)
   - Lattice ECP5 (e.g. ULX3S, OrangeCrab) → same open-source suite,
     targets `ecp5` instead of `ice40`
   - Xilinx (e.g. Arty A7, Basys 3) → Vivado (Linux/Windows only — on a Mac
     you'd typically use a Linux VM, or use the open-source `f4pga`/
     `symbiflow` flow instead)
   - Intel/Altera (e.g. DE10) → Quartus (also not native macOS)
2. **Write a constraints file** (`.pcf` for iCE40, `.lpf` for ECP5, `.xdc`
   for Xilinx) mapping `clk`, `rst_n`, and `led[3:0]` in `fpga/top_fpga.v`
   to real pins on your board. This is specific to your exact board model.
3. **Synthesize, place & route, and flash**, e.g. for an iCE40 board with
   the open-source flow:
   ```bash
   yosys -p "synth_ice40 -top top_fpga -json top_fpga.json" \
       rtl/*.v fpga/top_fpga.v
   nextpnr-ice40 --hx8k --json top_fpga.json --pcf your_board.pcf --asc top_fpga.asc
   icepack top_fpga.asc top_fpga.bin
   iceprog top_fpga.bin
   ```

Tell me your specific board (model number is fine) and I'll write you the
actual constraints file and exact toolchain commands.

## 3. "Then install Linux and test CPU performance" — the honest picture

This is the part I want to be direct about rather than let you find out the
hard way: **this core (or a beginner-scale core like it) cannot run Linux**,
and getting a homemade core to that point is a large undertaking — realistic
open-source projects that do this represent months of dedicated engineering
by experienced teams. Specifically, to boot Linux you need, at minimum:

- **RV32IMA or RV64IMA** — this core is now genuinely RV32IMA (the A
  extension landed alongside M/S/U privilege modes), so this box is
  actually checked, modulo being RV32 rather than RV64.
- **An MMU with page-table walking** (Sv32 for RV32, Sv39 for RV64) —
  Linux relies on virtual memory; without this it simply won't boot. This
  core now has a Sv32 walker + TLB covering **both** data accesses and
  instruction fetch, gated by real S/U privilege (not the earlier
  "unconditional whenever satp.MODE=1" stand-in) — this is now much
  closer to real, though it's still missing hardware PTE A/D auto-update
  and the hypervisor extension, neither of which Linux strictly needs to
  boot.
- **A trap/interrupt controller** (something like CLINT + PLIC) for
  timers and external interrupts. This core now has both: a CLINT-style
  timer/software interrupt, and a real PLIC (multiple prioritized,
  claimable sources) in place of the single wire it used to have — wired
  through real `mie`/`mip`/`mideleg` and privilege-aware interrupt-priority
  logic.
- **A real memory controller** driving actual DRAM — Linux plus a minimal
  root filesystem needs tens of megabytes at least; FPGA block RAM alone
  (tens of KB–a few MB) isn't enough.
- **A UART** (for a console) and usually **SPI/SD or similar storage**.
- **A boot chain**: typically first-stage bootloader → OpenSBI (SBI
  runtime) → U-Boot → Linux kernel → a root filesystem (often built with
  Buildroot). OpenSBI in particular expects real M/S-mode separation with
  trap delegation, which this core now has.
- Performance that isn't so slow it's unusable — this core is pipelined
  and now has a branch predictor, but it's still single-issue and
  in-order, with no cache; real Linux-capable FPGA cores typically add
  both a cache hierarchy and superscalar/out-of-order execution.

None of that is a natural extension of the file set above — it's a
different scale of project.

### What I'd actually recommend

If your real goal is "get Linux running on an FPGA and benchmark it," the
practical path is to use an existing, proven, open-source Linux-capable
core/SoC rather than build one from scratch:

- **[LiteX](https://github.com/enjoy-digital/litex) + [VexRiscv](https://github.com/SpinalHDL/VexRiscv)** — the most
  mature, well-documented option. The
  [linux-on-litex-vexriscv](https://github.com/litex-hub/linux-on-litex-vexriscv)
  project boots mainline Linux on affordable boards (Arty A7, ECPIX-5,
  OrangeCrab, and others), and has a working, maintained toolchain and
  build flow, plus benchmarking guidance (e.g. Dhrystone/CoreMark, and
  real Linux userspace benchmarks once booted).
- **SweRV / Rocket Chip / other larger RISC-V SoC generators** are also
  Linux-capable but generally have a steeper learning curve than
  LiteX-VexRiscv.

If you'd like, I can help you get `linux-on-litex-vexriscv` running on
whatever board you have — that's a realistic weekend-to-a-few-weeks project
depending on board and prior FPGA experience, versus the homemade-core-to-
Linux path which is a much longer undertaking.

### If you want to keep building on *this* core instead

That's also a great learning path, just with different, more achievable
milestones — happy to help with any of these next:
- **Superscalar issue and out-of-order execution** — the big one left on
  the list: register renaming, a reorder buffer, reservation stations or
  a scoreboard, multiple execution units. A genuine microarchitecture
  redesign, not an incremental add, so worth treating as its own project.
- Add a UART peripheral so you can print from running code
- Write actual assembly/C programs for it (via the `riscv64-unknown-elf`
  GNU toolchain — `brew install riscv-software-src/riscv/riscv-tools`) instead of hand-assembled hex
- Hardware PTE Accessed/Dirty auto-update in the MMU walker, so it
  doesn't have to fault when software forgot to pre-set those bits
- A second, PLIC-fed external-interrupt context for S-mode (real `SEIP`
  delivery), and a cache hierarchy
- Try booting a minimal OpenSBI + bare-metal payload now that M/S/U modes,
  trap delegation, and a real MMU exist — still well short of Linux, but a
  meaningfully closer milestone than before
