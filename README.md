# Vernier-RV32

[![CI](https://github.com/AravindRajeshkanna/vernier-rv32/actions/workflows/ci.yml/badge.svg)](https://github.com/AravindRajeshkanna/vernier-rv32/actions/workflows/ci.yml)
[![License: Apache-2.0 WITH SHL-2.1](https://img.shields.io/badge/license-Apache--2.0%20WITH%20SHL--2.1-blue.svg)](LICENSE)
[![riscv-tests](https://img.shields.io/badge/riscv--tests-79%20passed%2C%200%20failed%2C%203%20xfail-brightgreen.svg)](tests/README.md)
[![Spike co-simulation](https://img.shields.io/badge/vs%20Spike-82%2F82%20traces%20match-brightgreen.svg)](tests/README.md)
[![Hardware](https://img.shields.io/badge/ULX3S%20LFE5U--85F-SOC--TEST%3A%20PASS-brightgreen.svg)](fpga/README.md)

**An RV32IMA SoC that measures itself.**

A small, working RISC-V core — 5-stage pipeline, RV32IMA + Zicsr, full M/S/U
privilege with trap delegation, a Sv32 MMU covering both data and instruction
fetch, a BTB branch predictor — inside a complete Wishbone SoC: boot ROM,
RAM, CLINT, PLIC, UART, GPIO, SPI/SD storage, a device tree, and a
first-stage loader that pulls a program off an SD card into RAM and runs it.
Compiled C runs on it through a real `riscv64-unknown-elf-gcc` flow, not
hand-assembled hex. It synthesizes, places, routes and packs to an ECP5
bitstream.

A vernier is the auxiliary scale on a caliper — the part that gives you the
extra digit. The name is a claim about method rather than about the
microarchitecture: everything here is measured, and where something is
unmeasured or unproven this repo says so rather than rounding in its own
favour. See **Verification** below for the numbers, and `fpga/README.md` for
a worked example of the tool disagreeing with the prediction.

**It runs on hardware.** On a ULX3S with an LFE5U-85F the boot ROM comes up on
the FTDI console, jumps to the acceptance test in RAM, and the test reports
`SOC-TEST: PASS` — RAM, atomics, LR/SC, GPIO pins, framebuffer, the CLINT
timer, the counters, misaligned-access traps and `FENCE.I`, all executing
compiled C from block RAM on a real ECP5.

Two things still need a board and have not got one to work yet: **the SD
card** (a 64 GB SDXC card never answers CMD0 — cards above 32 GB are not
required to implement SPI mode, and the test bitstream sidesteps it by
preloading RAM from the bitstream) and **video scan-out**, which is generated
and simulated but not routed to the HDMI pins, since that needs a PLL and a
TMDS serializer neither of which exists yet. **Read the "Can this run Linux?"
section before you get too attached to that plan**: the honest answer is not with this core, and it
explains why and what the realistic path looks like.

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
  uart.v         TX+RX serial console, polled (txdata/rxdata/status)
  cpu_core.v     the CPU itself: 5-stage pipeline (IF/ID/EX/MEM/WB)
  ooo/
    core_ooo.v   the wide core being built for roadmap Phase 1, same port
                 list; `make verify_ooo` runs the whole suite against it
    regfile_wide.v  4-read/2-write register file for the dual-issue pair
  top.v          flat top level (cpu + imem + dmem + clint + plic + uart)
  soc/
    soc_top.v          the SoC: CPU on a Wishbone bus, unified address space
    wb_interconnect.v  2-master/7-slave shared bus, priority arbitration
    cpu_wb.v           core's native ports -> two Wishbone masters
    wb_ram.v           RAM slave (+ direct read ports for the MMU walkers)
    wb_rom.v           boot ROM slave
    wb_periph_bridge.v adapts clint/plic/uart onto the bus unchanged
    wb_gpio.v          GPIO with per-pin interrupts
    wb_spi.v           SPI master (the one slave with real wait states)
    video_timing.v     640x480@60 raster timing generator
    wb_framebuffer.v   320x240 8bpp framebuffer + scan-out (0x0700_0000)
    wb_sdram.v         SDR SDRAM controller (0x9000_0000, external memory)
sim/
  tb_top.v            self-checking testbench (hand-assembled program.hex)
  tb_software.v       runs the real compiled firmware, decodes UART to the console
  tb_soc.v            boots the SoC from a simulated SD card
  tb_isa.v            runs the official RISC-V architectural tests on the SoC
  tb_bench.v          runs CoreMark, ends on the benchmark's own verdict
  tb_sdram.v          the SDRAM controller at the bus, no CPU, no toolchain
  tb_sdramboot.v      the SoC executing a 99 KB program out of external SDRAM
  tb_uartload.v       a host sends a program over UART; the SoC runs it from SDRAM
  sdram_model.v       a 32 MB SDR part that refuses illegal protocol
  tb_ulx3s.v          board-wrapper wiring test (pin direction, polarity, tie-offs)
  tb_video.v          draws a pattern, captures a frame, compares it back
  tracer.v            retired-instruction tracer (drives the Spike co-simulation)
  sd_card_model.v     SD card in SPI mode (CMD0/8/55/58, ACMD41, CMD17)
  verilator_main.cpp  optional Verilator harness
  program.hex         hand-assembled RV32IMA test program
tests/
  fetch.sh            clone riscv-tests at a pinned commit (not vendored)
  build.sh            build the rv32ui/um/ua/mi/si suites into loadable images
  run.sh              run them all, with an XFAIL list that cannot go stale
  cosim.py            diff every retired instruction against Spike
  expected-failures.txt   the 3 known failures, each with a reason
  README.md           what each layer proves, and what it found
formal/
  run.sh              yosys -> SMT2 -> yosys-smtbmc -> z3, with a flow self-test
  fv_regfile.v        x0 semantics and the write-to-read bypass
  fv_interconnect.v   one-hot slave select, arbitration, ack routing
  fv_selftest.v       a property that MUST fail (proves the flow can go red)
  (plic.v and btb.v carry their own properties under `ifdef FORMAL)
software/
  crt0.S         startup code (stack/gp setup, zero .bss, call main)
  link.ld        two-region Harvard linker script (imem "ROM" + dmem "RAM")
  uart.c/.h      UART driver (uart_putc/uart_getc)
  syscalls.c     newlib syscall stubs (_write/_read route through the UART)
  main.c         demo program: printf a greeting and a small loop
  bin2hex.py     packs objcopy's raw binary output into $readmemh hex
  soc/
    soc.h        SoC memory map, shared by the boot ROM and the RAM program
    bootrom.c    first-stage loader: SPI/SD init, load image, jump
    main.c       acceptance test: RAM, atomics, GPIO, timer
    console.c/.h libc-free UART output, so a test can't fail inside libc
    trap.c/.h    the loud trap handler's C half: report an unarmed trap, halt
    newlibprobe.c  the ladder that found the .data bug: one dependency per
                   rung, heap RAM -> _sbrk -> malloc -> snprintf -> printf
    trapcheck.c  provokes known faults, so the handler is calibrated not assumed
    crt0_rom.S / crt0_ram.S, link_rom.ld / link_ram.ld
    mkcard.py    builds the SD card image (header block + program)
  bench/
    fetch-coremark.sh  clone CoreMark at a pinned commit (not vendored)
    core_portme.c/.h   the port layer: cycle-counter timer, printf over UART
    crt0_bench.S, link_bench.ld
docs/
  architecture.md  the full design writeup - pipeline, hazards, privilege,
                   MMU, SoC, and every bug worth recording
  soc.md         component and register reference: what each block is,
                 its registers, and what bites you when programming it
  practices.md   the working rules, each attached to the incident that
                 produced it - start here before changing anything
  roadmap.md     what is next, in phases, with the state of each stated
  debug.md       UART, tracer, and an honest account of the missing JTAG
  toolchain.md   every tool and version this was built with, and which
                 flow uses which
dts/
  soc.dts        device tree describing the SoC (`make dtb`)
fpga/
  top_fpga.v     board-agnostic FPGA top for the flat design
  soc_fpga.v     board-agnostic FPGA top for the SoC
  ulx3s_top.v    ULX3S board wrapper - real pins, builds to a bitstream
  constraints/   ulx3s.lpf (real pins); generic.lpf/.xdc still placeholders
  synth/         yosys/nextpnr batch script (run end to end) and a Vivado
                 one (never executed)
  README.md      what is and isn't known about the FPGA path
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
branch predictor** — see `docs/architecture.md` for the full pipeline/hazard/
privilege/interrupt/MMU design, including several real bugs found and
fixed along the way (a couple of pipeline hazards from an earlier update,
a page fault that could still commit its write, an MRET/SRET that could
complete despite being interrupt-preempted, and a PLIC priority-encoder
that picked the lowest matching source ID instead of comparing
priorities).

## Verification

```
riscv-tests:             79 passed, 0 failed, 3 xfail   (make isa)
co-simulation vs Spike:  82/82 traces match             (make cosim)
formal:                  5 proved, 0 refuted            (make formal)
CoreMark:                validates its own CRCs         (make coremark)
SDRAM controller:        against a model that says no    (make sim_sdram)
SoC out of SDRAM:        99 KB program, 64 KB block RAM  (make sim_sdramboot)
SDRAM on a board:        256 KB read/written, ULX3S 85F  (BOARD=ulx3s85-sdramcheck)
UART loader:             host -> ROM -> SDRAM -> running  (make sim_uartload)
  ...and its host script:  against a fake board on a pty    (make uartload-host)
99 KB program from SDRAM: on a ULX3S 85F, over the serial line
ULX3S 85F bitstream:     27.41 MHz, 20% LUT, 51% BRAM   (BOARD=ulx3s85 ...synth_ecp5.sh)
ULX3S 45F bitstream:     28.78 MHz, 29% LUT, 97% BRAM   (predates the D-cache and SDRAM)
```

`make verify` runs the lot. `tests/README.md` has the details, including the
**fifteen real bugs these layers found** — among them an MMU that never
checked the PTE's `U` bit (so U-mode could read and execute supervisor pages,
with the entire user/supervisor isolation boundary simply absent), `mcycle`
and `minstret` driven from two `always` blocks at once (undefined in
simulation, rejected by synthesis), an AMO permission-checked as a load (so
it could write a read-only page), and `misa` failing to advertise the S and U
modes this core actually has.

Two of those layers exist specifically to catch what the others cannot.
Co-simulation asks "did it execute the *same instructions* as Spike", not
just "did the test pass" — a core can reach the right answer through a wrong
sequence. Formal asks "does this hold for *every* input", which for the PLIC
means about 2^30 priority/enable/pending/threshold combinations that no test
suite is going to enumerate.

Debug infrastructure — UART console, instruction tracer, and why there is no
JTAG — is in `docs/debug.md`.

It does **not** implement superscalar issue or out-of-order execution —
still single-issue, in-order. That's the natural next step, but it's a
full microarchitecture redesign (register renaming, a reorder buffer,
reservation stations/scoreboard, multiple execution units) rather than an
additive change like everything above, so it's being treated as a
separate future effort instead of bolted onto this pipeline.

## 1. Simulate it on your Mac

```bash
brew install icarus-verilog surfer
# optional, for the faster/alternate simulator:
brew install verilator

cd vernier-rv32
make sim
```

Expected output ends with:
```
mem[0..3] (expect 15,0,0,0): 15 0 0 0
fail word (expect 0 = PASS): 0x00000000
BTB mispredict_count (expect 53): 53
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
(opens Surfer; GTKWave was discontinued upstream and pulled from Homebrew).

I hand-assembled the test program's encodings with a small Python script
(not part of the repo) and cross-checked several against the RV32I spec by
hand before handing this to you, so what you're running should behave as
described — but please still treat `make sim` as the real check, not my
word for it.

`make verilator` runs the same design through Verilator instead, producing
`sim/wave_verilator.vcd`.

## 2. Run real compiled C on it

```bash
brew install riscv-software-src/riscv/riscv-tools   # riscv64-unknown-elf-gcc

make sim_software
```

This compiles `software/main.c` with `riscv64-unknown-elf-gcc`
(`-march=rv32im -mabi=ilp32 -specs=nano.specs` — see below for why), links
it against `software/crt0.S`/`link.ld`/`syscalls.c`, converts the result
into the two hex files `imem`/`dmem` preload from, and runs it against a
new testbench (`sim/tb_software.v`) that decodes the CPU's simulated UART
output back into ASCII and prints it live. Expected output:

```
Hello from RV32IMA!
This is real C, compiled with riscv64-unknown-elf-gcc,
running on a from-scratch RISC-V core, printing over a
simulated UART.
i = 0
i = 1
i = 2
i = 3
i = 4
done.
```

That's real `printf`, through newlib, through this project's own
`_write` syscall stub, through `rtl/uart.v`'s bit-banged TX shift
register, decoded back into characters by a matching receiver state
machine in the testbench — not a canned string. `sim/tb_top.v` and
`sim/program.hex` (the hand-assembled self-checking regression test from
before) are completely untouched by any of this; `make sim` still runs
exactly as it always has, side by side with this new flow.

Two things that weren't obvious going in, in case you extend
`software/`: this toolchain build has no exact `rv32ima` multilib (use
`-march=rv32im` — the A extension just goes unused by compiled code), and
full newlib `printf` is ~69KB for even a trivial program against this
core's 4KB-by-default `imem` — `-specs=nano.specs` gets the same real
`printf` down to ~9KB, which is why `IMEM_WORDS` defaults to 8192 now.
See `docs/architecture.md` section 12 for the full story, including a second
linker-script gotcha (Harvard regions both based at address 0 confuse the
linker's *load*-address overlap check, which doesn't know they're
different physical memories).

## 3. Run the full SoC

```bash
make sim_soc
```

This is the CPU as an actual system-on-chip: a Wishbone B4 bus, boot ROM,
256 KB RAM, CLINT, PLIC, UART, GPIO and SPI, with a simulated SD card
attached. It runs the real boot sequence — nothing is preloaded into RAM.

```
=== RV32IMA SoC boot ROM ===
SPI/SD init...
  card ready
  image 0x00000F4C bytes -> 0x80001000
  loaded, starting program

MV

=== SoC acceptance test ===
Running from RAM at 0x80001248

  RAM walking ones             ok
  RAM address uniqueness       ok
  RAM byte/half access         ok
  AMO read-modify-write        ok
  LR/SC success                ok
  LR/SC broken by store        ok
  GPIO pin readback            ok
  framebuffer read/write       ok
  CLINT mtime advances         ok
  misa reports I+M+A           ok
  cycle/time/instret           ok
  misaligned access traps      ok
  FENCE.I invalidates          ok

0 failure(s)
SOC-TEST: PASS
```

The boot ROM brings up SPI, initializes the card, reads an image header,
pulls eight blocks in over a bit-banged SPI link, and jumps to RAM; the loaded
program then runs its own acceptance tests and reports over the UART. Every
character above is decoded off the CPU's actual serial TX pin by a receiver
state machine in `sim/tb_soc.v`. Pass/fail is also written as a magic word
to a fixed RAM address so the result is machine-checkable rather than
eyeballed.

`make dtb` compiles `dts/soc.dts` — a standard device tree describing the
hardware, which is the interface OpenSBI/U-Boot/Linux would come looking
for. Nothing in this project consumes it yet (the firmware has the memory
map compiled in via `software/soc/soc.h`), but it makes the address map
explicit and reviewable in one place.

**The SoC is a separate top level, not a replacement.** `rtl/top.v` and its
hand-assembled regression test are untouched, so `make sim` still proves
exactly what it always did — including reporting the same BTB mispredict
count, which is a usefully sensitive canary for accidental timing changes
in the core.

### The board's boot path, and a trap handler that says something

`make sim_soc` boots off the card with 256 KB of RAM. The bitstream that has
actually run on hardware does neither: the program is baked in
(`BOARD=ulx3s85-ram`), and the RAM is 64 KB, because 256 KB costs 244 ECP5
block RAMs and fits no ECP5 there is. Both differences matter — the bus
decodes on `addr[31:24]` alone, so running off the end of RAM *aliases* back
to the start instead of faulting, and at 256 KB that wrap point sits four
times higher than the board's. `make sim_ramboot` is that path at that size,
and it is part of `make verify`.

`make trapcheck` is the other half. The RAM program's trap handler used to
advance `mepc` by 4 and return from every trap — right for the one fault the
acceptance test provokes deliberately, and silently wrong for every other, so
an illegal instruction or a stray misaligned access was stepped over and the
program carried on with an instruction's effect missing. It is now loud: code
that wants a trap arms one first, and an unarmed trap prints
`mcause`/`mepc`/`mtval`/`ra`/`sp` and halts. Since the whole value of that is
in the report, `make trapcheck` provokes three faults whose reports are known
in advance and scores the text that comes out.

`make sim_rerun` is the third: it runs the program, pulses reset **without
touching RAM**, and runs it again. That is what a board does every time you
flash a bitstream, open a terminal and tap reset to catch the banner — and it
is not the same as a fresh start, because block RAM is initialised when the
FPGA is *configured*, not when the CPU is reset.

That test exists because it found a real bug. `crt0_ram.S` zeroed `.bss` but
never restored `.data`, so run 2 inherited run 1's writes. What it broke was
newlib's stdio and nothing else: `__sinit` returns early when its `__cleanup`
guard is non-NULL, and `__sinit` *sets* that guard on success, so the second
run skipped initialising `stdout` and every `printf` after it returned −1 and
printed nothing. That is what "printf hangs on hardware" actually was — it
never hung, it just had no other output channel to be heard on. `.data` is now
copied from a pristine load address at every startup. Full account, including
the evidence, in `fpga/README.md`.

`make sim_probe` runs `software/soc/newlibprobe.c`, the ladder that found it —
one dependency per rung, from RAM under the heap through `_sbrk`, `malloc` and
`snprintf` to `printf`.

Adding a bus meant teaching the pipeline to wait on it, which is a real
change to `cpu_core.v` (two new stall inputs, both tied low by the old top
level). It also surfaced a genuine latent bug: an `SC` both reads and clears
the reservation, and with zero-latency memory those happened in the same
cycle so the order never mattered — over a multi-cycle bus, clearing it
first pulled the success check out from under the write phase. See
`docs/architecture.md` section 12a.

## 4. Getting it onto an actual FPGA

**On a ULX3S there is nothing to fill in, and it has been done.**
`fpga/constraints/ulx3s.lpf` has real pins, `fpga/ulx3s_top.v` handles the
board's quirks, and the result boots on an LFE5U-85F and passes its
acceptance test. Both FPGA variants that fit have a build target:

```bash
make soc                                     # boot ROM is a synthesis input
BOARD=ulx3s85 ./fpga/synth/synth_ecp5.sh     # LFE5U-85F
BOARD=ulx3s   ./fpga/synth/synth_ecp5.sh     # LFE5U-45F
openFPGALoader -b ulx3s fpga/build/ulx3s_top.bit
```

Synthesis needs oss-cad-suite on `PATH` (`export
PATH=~/tools/oss-cad-suite/bin:$PATH`); `make verify` does not. See
`docs/toolchain.md`.

**Until the SD card works, boot from a preloaded RAM image instead:**

```bash
make ramimage
BOARD=ulx3s85-ram ./fpga/synth/synth_ecp5.sh
```

That bakes the program into the bitstream, and the boot ROM notices RAM is
already populated and jumps straight to it. It is how the acceptance test
was run on hardware, and it takes the card out of the path entirely.

The 12F and 25F variants of that board do **not** fit — they are over their
block-RAM budget and fail to place. See `fpga/README.md`.

What's there to start from on any *other* board: `fpga/soc_fpga.v` (the SoC
with a reset synchronizer and tristate GPIO, board-agnostic on purpose),
`generic.xdc`/`generic.lpf` which are still **placeholder pins**, and batch
scripts for both Vivado and the open-source yosys/nextpnr flow. Use
`ulx3s_top.v` as the worked example of what a board wrapper has to do.

The rest is genuinely board-dependent:

1. **Pick your toolchain based on your FPGA vendor:**
   - Lattice iCE40 (e.g. iCEBreaker, Alchitry Cu) → open-source flow:
     `brew install icestorm nextpnr yosys` (via the [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) tap is easiest on macOS)
   - Lattice ECP5 (e.g. ULX3S, OrangeCrab) → same open-source suite,
     targets `ecp5` instead of `ice40`
   - Xilinx (e.g. Arty A7, Basys 3) → Vivado (Linux/Windows only — on a Mac
     you'd typically use a Linux VM, or use the open-source `f4pga`/
     `symbiflow` flow instead)
   - Intel/Altera (e.g. DE10) → Quartus (also not native macOS)
2. **Fill in real pins** in `fpga/constraints/generic.xdc` (Xilinx) or
   `generic.lpf` (ECP5) — those two are still placeholders copied from no
   board in particular. Start from your vendor's master constraints file, and
   write a wrapper alongside `ulx3s_top.v` rather than editing it.
3. **Set `CLK_HZ` in `fpga/soc_fpga.v`** to your board's actual oscillator,
   along with `CPU_HZ` in `software/soc/soc.h` and `CLK_PERIOD` in
   `sim/tb_soc.v` — nothing checks the three agree. The UART divisor and the
   SD initialization clock are both derived from them, so getting either
   wrong produces a garbled console or a card that never answers, even when
   timing closes. Both look like CPU bugs rather than configuration ones. An
   oscillator faster than ~30 MHz also needs a PLL; the design has none.
4. **Run `make soc` first**, then synthesize. The boot ROM image is pulled
   in with `$readmemh` at elaboration time, which makes it a *synthesis*
   input, not just a simulation one. Both scripts refuse to start without
   it, because otherwise you get a board that comes up and does nothing.
5. **Synthesize, place & route, and flash:**
   ```bash
   make soc
   DEVICE=85k PACKAGE=CABGA381 ./fpga/synth/synth_ecp5.sh   # open-source flow
   # or:
   vivado -mode batch -source fpga/synth/vivado.tcl -tclargs xc7a35ticsg324-1L
   ```
   Pick a device that actually fits: at the default 64 KB of RAM plus the
   framebuffer the design needs **105 block RAMs**, which rules out the ECP5
   25F and 12F. `fpga/README.md` has the measured table.

## 5. "Then install Linux and test CPU performance" — the honest picture

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
  (tens of KB–a few MB) isn't enough. **This is now the single biggest
  gap.** The SoC has 64 KB of on-chip RAM behind a Wishbone slave (256 KB
  in simulation, which does not fit any ECP5 — see `fpga/README.md`); the
  seam where a LiteDRAM controller would go is marked in `wb_ram.v`, but
  wiring one up needs LiteX and a board with DDR.
- **A UART** (for a console) and **SPI/SD or similar storage** — the SoC
  now has both, and actually boots off the SD card.
- **A boot chain**: typically first-stage bootloader → OpenSBI (SBI
  runtime) → U-Boot → Linux kernel → a root filesystem (often built with
  Buildroot). The first link exists — `software/soc/bootrom.c` is a genuine
  first-stage loader — and **OpenSBI now builds for this core**
  (`software/opensbi/`), with the platform features it depends on
  implemented. It does not yet boot: it still needs a platform port and
  more RAM than 256 KB. See `software/opensbi/README.md`.
- Performance that isn't so slow it's unusable — this core is pipelined
  and now has a branch predictor, but it's still single-issue and
  in-order, with no cache; real Linux-capable FPGA cores typically add
  both a cache hierarchy and superscalar/out-of-order execution.

None of that is a natural extension of the file set above — it's a
different scale of project.

### Where this goes next

[docs/roadmap.md](docs/roadmap.md) has the full picture, in dependency order
rather than by how interesting each item is, with the current state of each
stated rather than implied.

The short version:

| Phase | | Status |
|---|---|---|
| 0 | Core, SoC and peripherals on silicon | ✅ done — `SOC-TEST: PASS` on an LFE5U-85F |
| 1 | **Superscalar issue and out-of-order execution** | 1a–1c done — `rtl/ooo/core_ooo.v` dual-issues ALU pairs, buffers stores, and completes independent work under a waiting load. Worth 0.05% until the Phase 3 I-cache landed and 7.2% after it, on largely unchanged RTL. **1d (renaming, reorder buffer, LSQ) is designed and not scheduled**: the Phase 3 D-cache took its measured ceiling from 2.9% to 0.56% |
| 2 | Break the memory ceiling — external DRAM | ✅ **done, on silicon** — a 99 KB program sent over the serial line into external SDRAM on a ULX3S 85F and executed from there. 64 KB of block RAM is no longer the ceiling |
| 3 | Make it fast enough to be interesting — caches, interrupt-driven UART | I-cache **1.79×** and D-cache **1.11×** on CoreMark, both in the bus adapter and shared by both cores. Interrupt-driven UART and multi-word lines remain |
| 4 | Video out | the framebuffer works; nothing is routed to the HDMI pins |
| 5 | Run software this project did not write — OpenSBI, Zephyr | OpenSBI builds, does not boot. Phase 2's SDRAM removes the "nowhere to put a 521 KB `fw_jump.bin`" half of that |
| 6 | Debug infrastructure — JTAG, a Debug Module | makes every other phase cheaper |
| 7 | Close the boot path — the SD card | the only untested link in the boot chain — and the only phase nothing else is waiting on |

Phase 1 is first because it replaces the machine every later phase builds on,
and is cheaper to do before they widen the surface it has to preserve — but it
is the largest thing on the list by a wide margin, and `docs/roadmap.md` is
specific about what it requires and what must not regress while it happens.
Phase 7 needs a card of 32 GB or less and about five minutes. It is last
because nothing else is blocked by it — every hardware run preloads the program
into the bitstream and that works — not because it is hard.

One known defect is open and unscheduled: the intermittent `ISA-TIMEOUT` under
`make verify`. It self-reports rather than hanging silently now, which is not
the same as being fixed.

---

## Contributing, licence, and how this was built

| | |
|---|---|
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to build, what a good pull request looks like, and what gets pushed back on |
| [docs/practices.md](docs/practices.md) | The working rules — twenty-three of them, each attached to the incident on this repo that produced it |
| [docs/roadmap.md](docs/roadmap.md) | Where this goes next, in phases, in dependency order |
| [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) | Contributor Covenant 2.1 |
| [SECURITY.md](SECURITY.md) | Reporting privilege-boundary and MMU bugs, and an honest scope statement |
| [AI_USAGE.md](AI_USAGE.md) | Disclosure of how this project was built, and the policy for contributions |
| [LICENSE](LICENSE) / [NOTICE](NOTICE) | Solderpad Hardware License 2.1 (`Apache-2.0 WITH SHL-2.1`) |

**Licence.** Solderpad 2.1 is the Apache License 2.0 with hardware-specific
wording — it extends the definitions to cover designs, netlists, layouts and
mask works, and grants rights to *make* and *instantiate* the work, not only
to copy it. You may treat anything here as plain Apache-2.0 if you prefer;
Section 2 of the licence says so explicitly. No third-party code is vendored:
riscv-tests and CoreMark are fetched at pinned commits and stay under their
own terms. See [NOTICE](NOTICE), and note that CoreMark scores from this
repository are unverified self-measurements, not EEMBC-certified ones.

**AI.** This project was built with substantial AI assistance, and
[AI_USAGE.md](AI_USAGE.md) says so in detail rather than leaving it to be
inferred — including the three failure modes it produced here (confident wrong
diagnostics, plausible tests that cannot fail, fluent explanations of the
wrong cause) and what the verification layers are there to catch. The first
three rules in `docs/practices.md` exist because of them.

**CI.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs the RTL
regression, the SoC on both boot paths, the reset-and-rerun test, the trap
handler calibration, the architectural suite and formal on every push. Spike
co-simulation and FPGA place-and-route are local gates — they are too slow for
CI, and `fpga/README.md` records the timing numbers from real runs by hand.
