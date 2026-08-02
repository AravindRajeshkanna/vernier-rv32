# Vernier-RV32

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

It has never run on hardware — there is no board, and the pinout is still
placeholders. **Read the "Can this run Linux?" section before you get too
attached to that plan**: the honest answer is not with this core, and it
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
sim/
  tb_top.v            self-checking testbench (hand-assembled program.hex)
  tb_software.v       runs the real compiled firmware, decodes UART to the console
  tb_soc.v            boots the SoC from a simulated SD card
  tb_isa.v            runs the official RISC-V architectural tests on the SoC
  tb_bench.v          runs CoreMark, ends on the benchmark's own verdict
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
    crt0_rom.S / crt0_ram.S, link_rom.ld / link_ram.ld
    mkcard.py    builds the SD card image (header block + program)
  bench/
    fetch-coremark.sh  clone CoreMark at a pinned commit (not vendored)
    core_portme.c/.h   the port layer: cycle-counter timer, printf over UART
    crt0_bench.S, link_bench.ld
docs/
  DEBUG.md       UART, tracer, and an honest account of the missing JTAG
  TOOLCHAIN.md   every tool and version this was built with, and which
                 flow uses which
dts/
  soc.dts        device tree describing the SoC (`make dtb`)
fpga/
  top_fpga.v     board-agnostic FPGA top for the flat design
  soc_fpga.v     board-agnostic FPGA top for the SoC (UNVERIFIED - see below)
  constraints/   pin templates (.xdc/.lpf) - PLACEHOLDER pins
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
branch predictor** — see `ARCHITECTURE.md` for the full pipeline/hazard/
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
formal:                  4 proved, 0 refuted            (make formal)
CoreMark:                validates its own CRCs         (make coremark)
synthesis (ECP5):        fits an LFE5U-45F, 54 s         (fpga/README.md)
place & route:           bitstream at 31.32 MHz          (fpga/synth/synth_ecp5.sh)
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
JTAG — is in `docs/DEBUG.md`.

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
See `ARCHITECTURE.md` section 12 for the full story, including a second
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
  image 0x00002A3C bytes -> 0x80001000
  loaded, starting program

=== SoC acceptance test ===
Running from RAM at 0x80001000, loaded from SD by the boot ROM.

  RAM walking ones             ok
  RAM address uniqueness       ok
  RAM byte/half access         ok
  AMO read-modify-write        ok
  LR/SC success                ok
  LR/SC broken by store        ok
  GPIO loopback                ok
  CLINT mtime advances         ok

0 failure(s)
SOC-TEST: PASS
```

The boot ROM brings up SPI, initializes the card, reads an image header,
pulls 21 blocks in over a bit-banged SPI link, and jumps to RAM; the loaded
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

Adding a bus meant teaching the pipeline to wait on it, which is a real
change to `cpu_core.v` (two new stall inputs, both tied low by the old top
level). It also surfaced a genuine latent bug: an `SC` both reads and clears
the reservation, and with zero-latency memory those happened in the same
cycle so the order never mattered — over a multi-cycle bus, clearing it
first pulled the success check out from under the write phase. See
`ARCHITECTURE.md` section 12a.

## 4. Getting it onto an actual FPGA

**Nothing in `fpga/` has been synthesized, placed, routed, or run on
hardware** — no FPGA toolchain and no board were available where this was
built, so those files are elaborated and lint-clean but otherwise unproven.
`fpga/README.md` is explicit about exactly what is and isn't known, and
about which paths are the likely suspects if timing doesn't close.

What's there to start from: `fpga/soc_fpga.v` (the SoC with a reset
synchronizer and tristate GPIO), constraints templates with **placeholder
pins** for Xilinx and ECP5, and batch scripts for both Vivado and the
open-source yosys/nextpnr flow.

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
   `generic.lpf` (ECP5). Every pin in those files today is a placeholder
   copied from no board in particular — start from your vendor's master
   constraints file.
3. **Set `CLK_HZ` in `fpga/soc_fpga.v`** to your board's actual oscillator.
   The UART divisor is derived from it, so getting this wrong produces a
   console emitting garbage even when timing closes — and it looks like a
   CPU bug rather than a configuration one.
4. **Run `make soc` first**, then synthesize. The boot ROM image is pulled
   in with `$readmemh` at elaboration time, which makes it a *synthesis*
   input, not just a simulation one. Both scripts refuse to start without
   it, because otherwise you get a board that comes up and does nothing.
5. **Synthesize, place & route, and flash:**
   ```bash
   make soc
   DEVICE=25k PACKAGE=CABGA381 ./fpga/synth/synth_ecp5.sh   # open-source flow
   # or:
   vivado -mode batch -source fpga/synth/vivado.tcl -tclargs xc7a35ticsg324-1L
   ```

Tell me your specific board (model number is fine) and I'll write you the
actual constraints file and exact toolchain commands.

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
- **Actually get a bitstream onto a board.** Everything in `fpga/` is
  written but unproven — no toolchain or hardware was available here. This
  is the highest-value next step by a distance, because it's the one thing
  simulation fundamentally can't substitute for, and it's what turns the
  timing/resource numbers from unknown into measured.
- **External DRAM**, which unblocks essentially everything else on this
  list (OpenSBI, FreeRTOS/Zephyr with any real workload, and eventually
  Linux). LiteDRAM via LiteX is the well-trodden path.
- **Caches.** Every fetch and load currently goes to the bus, and the
  shared-bus interconnect means a load costs the fetch behind it a cycle.
  An I-cache alone would help a lot.
- Make the UART interrupt-driven (a PLIC source) instead of polled, and
  write a real console/shell in C now that `printf`/`scanf` both work
- Bring up FreeRTOS or Zephyr — a realistic intermediate milestone now
  that there's a bus, a timer, an interrupt controller and storage
- **Superscalar issue and out-of-order execution** — register renaming, a
  reorder buffer, reservation stations or a scoreboard, multiple execution
  units. A genuine microarchitecture redesign, not an incremental add.
- Hardware PTE Accessed/Dirty auto-update in the MMU walker, so it
  doesn't have to fault when software forgot to pre-set those bits
- A JTAG TAP and a RISC-V Debug Module, so debugging isn't just `printf`
- SPI/SD storage, so `software/` programs could load data larger than
  fits in `dmem`
