# Vernier-RV32

[![CI](https://github.com/AravindRajeshkanna/vernier-rv32/actions/workflows/ci.yml/badge.svg)](https://github.com/AravindRajeshkanna/vernier-rv32/actions/workflows/ci.yml)
[![License: Apache-2.0 WITH SHL-2.1](https://img.shields.io/badge/license-Apache--2.0%20WITH%20SHL--2.1-blue.svg)](LICENSE)
[![riscv-tests](https://img.shields.io/badge/riscv--tests-81%20passed%2C%200%20failed%2C%203%20xfail-brightgreen.svg)](tests/README.md)
[![Spike co-simulation](https://img.shields.io/badge/vs%20Spike-84%2F84%20traces%20pass-brightgreen.svg)](tests/README.md)
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
TMDS serializer neither of which exists yet. **Linux boots to userspace on the
board** — 6.18.45 rv32ima, through OpenSBI, out of 32 MB of external SDRAM,
with the image sent over the serial line by the boot ROM's own loader. The
["Can this run Linux?"](#5-then-install-linux-and-test-cpu-performance--the-honest-picture)
section is the full accounting and `fpga/README.md` has the transcript.

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
    core_ooo.v   the wide, out-of-order core built for roadmap Phase 1, same
                 port list as cpu_core.v; `make verify_ooo` runs the whole
                 suite against it, and CORE=ooo builds every target with it
    regfile_phys.v  64-entry physical register file behind the RAT/ROB
  top.v          flat top level (cpu + imem + dmem + clint + plic + uart)
  soc/
    soc_top.v          the SoC: CPU on a Wishbone bus, unified address space
    wb_interconnect.v  2-master/7-slave shared bus, priority arbitration
    cpu_wb.v           core's native ports -> two Wishbone masters (+I/D caches)
    wb_ptw.v           the two Sv32 walkers -> a third Wishbone master, so a
                       page table can live in SDRAM
    wb_ram.v           RAM slave
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
  verilator_main.cpp  Verilator harness for the flat rtl/top.v
  verilator_soc.cpp   Verilator harness for the whole SoC - ~390x faster than
                      Icarus, with the SDRAM model ported to C++
  verilator_soc.vlt   what the harness is allowed to reach inside the design
  verilator_compare.py  requires both simulators to agree, cycle for cycle
  program.hex         hand-assembled RV32IMA test program
tests/
  fetch.sh            clone riscv-tests at a pinned commit (not vendored)
  build.sh            build the rv32ui/um/ua/mi/si suites into loadable images
  run.sh              run them all, with an XFAIL list that cannot go stale
  cosim.py            diff every retired instruction against Spike
  traptrace.py        what each trap was, and what two boots disagree about
  vernier/            this project's own tests, where riscv-tests has no reason
                      to go: pairing.S is the workload that dual-issues
  dual-issue-floor.txt  how much of the wide core a test must actually run
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
    mmutest.c    Sv32 with the page tables in SDRAM, walked from S-mode - the
                 first program here ever to enable translation, and it found
                 two core bugs on its first run
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
  comparison.md  how this sits next to SERV, PicoRV32, Ibex, VexRiscv,
                 NEORV32, SweRV, Rocket Chip and CVA6 - and where it's behind
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
riscv-tests:             82 passed, 0 failed, 2 xfail   (make isa)
co-simulation vs Spike:  84/84 traces pass              (make cosim)
  (make cosim CORE=ooo:  84/84 too, but one of the 84 is an accepted
                          divergence unique to the wide core - see
                          tests/README.md)
formal:                  6 proved, 0 refuted            (make formal)
CoreMark:                validates its own CRCs         (make coremark)
SDRAM controller:        against a model that says no    (make sim_sdram)
SoC out of SDRAM:        99 KB program, 64 KB block RAM  (make sim_sdramboot)
SDRAM on a board:        all 32 MB, every row, 4.0 s retention (BOARD=ulx3s85-sdramfull)
UART loader:             host -> ROM -> SDRAM -> running  (make sim_uartload)
  ...and its host script:  against a fake board on a pty    (make uartload-host)
Sv32, megapages and 4 KB: page tables in SDRAM, both levels (make sim_mmusdram)
OpenSBI:                 boots, detects the platform, hands off (make sim_opensbi)
Linux 6.18 rv32ima:      boots to userspace on this SoC, and under
                         QEMU; /init runs and prints            (make sim_linux)
  ...and on a board:     ULX3S 85F, 7.4 MB sent over UART       (BOARD=ulx3s85)
99 KB program from SDRAM: on a ULX3S 85F, over the serial line
ULX3S 85F bitstream:     23.18-25.92 MHz (a distribution, not a single
                         number - see fpga/README.md), 20% LUT, 38% BRAM
                                          (BOARD=ulx3s85 ...synth_ecp5.sh)
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

The default core (`cpu_core.v`, `CORE=inorder`) is still single-issue,
in-order. A second, parallel core — `rtl/ooo/core_ooo.v`, `CORE=ooo` — adds
register renaming, an 8-entry reorder buffer, and general out-of-order
issue, and `make verify_ooo` runs the same architectural/co-simulation/
formal suite against it that the default core carries; both are gated in
CI. It was built to answer whether renaming and a ROB were worth adding at
all, and the honest answer, from CoreMark, is not on their own: the wide
core measures 448,728 cycles against the in-order core's 453,844 — barely
faster — and *slower* than the narrower, cheaper dual-issue design it was
meant to replace (434,822 cycles, no renaming). `docs/roadmap.md`'s Phase 1
section has the full accounting, including why: register renaming and a
scoreboard remove hazards that in-order issue never has in the first
place, so most of what they cost goes to proving nothing broke, not to
real independent work. It stays in the tree, verified and measured rather
than deleted, because the number is the point — see the project's own
name, above.

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
`sim/wave_verilator.vcd`. `make verilator_sdramboot` runs the whole **SoC**
that way — the same test `make sim_sdramboot` runs, in about half a second
instead of three minutes — and `make verilator_check` runs it under both and
requires them to agree on the cycle count, the refresh count and every byte
the program printed.

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

This section opened, for most of this project's life, with "**this core (or a
beginner-scale core like it) cannot run Linux**". That was the honest reading
at the time and it is now wrong: `make sim_linux` boots Linux 6.18.45 rv32ima
to userspace on this SoC, through OpenSBI, out of external SDRAM, with `/init`
printing back the ISA string the kernel parsed from `dts/soc.dts`.

The rest of the sentence stands. It was a large undertaking, it took the
better part of this repository's history, and the list below is what it
actually required — kept in its original shape, with each item marked by what
now exists rather than rewritten to sound inevitable.

**And on hardware.** A ULX3S / LFE5U-85F, 7,744,876 bytes sent over the serial
line into external SDRAM, OpenSBI, the kernel, and `/init` at pid 1 printing
back the ISA string the kernel parsed out of `dts/soc.dts` — transcript in
`fpga/README.md`. What that boot did *not* prove is PLIC interrupt delivery:
the controller is probed and its contexts claimed, but nothing in the boot
requires an interrupt to be taken.

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
  logic. It now also delivers external interrupts to **S-mode**: the PLIC
  has the standard register layout and two contexts (hart 0 M-mode and
  hart 0 S-mode), and `mip.SEIP` is the spec's OR of a software-writable
  bit and the controller's pin. `make sim_plic` takes one.
- **A real memory controller** driving actual DRAM — Linux plus a minimal
  root filesystem needs tens of megabytes at least; FPGA block RAM alone
  (tens of KB–a few MB) isn't enough. **This one is now done, on silicon**:
  `rtl/soc/wb_sdram.v` drives the ULX3S's 32 MB SDR part, and a 99 KB
  program has been sent over the serial line into it and executed from
  there on an LFE5U-85F. No LiteX, no LiteDRAM. Sv32 page tables can live
  in it too, walked from S-mode for both fetch and data — the walkers are a
  bus master now, and the decode reaches all 32 MB.
- **A UART** (for a console) and **SPI/SD or similar storage** — the SoC
  now has both, and actually boots off the SD card. The UART is an
  **ns16550** as of the OpenSBI work, so the console is one a stock 8250
  driver can drive rather than one this project would have to write a
  driver for.
- **A boot chain**: typically first-stage bootloader → OpenSBI (SBI
  runtime) → U-Boot → Linux kernel → a root filesystem (often built with
  Buildroot). Three of those four links exist. `software/soc/bootrom.c` is
  a genuine first-stage loader; **OpenSBI boots**, detects this platform
  from `dts/soc.dts` and hands off to S-mode (`make sim_opensbi`); and
  there is now **an rv32ima Linux with an initramfs**, built from source by
  `software/linux/build-linux.sh`, which **boots to userspace on this SoC —
  on a board** — `Run /init as init process`, and `/init` printing `uname` and
  `/proc/cpuinfo` back. `make sim_linux` does the same under Verilator, which
  is where every defect in the way was found; `software/linux/README.md`
  records them and how each was caught. U-Boot is skipped: `mkimage.py` packs
  the kernel where `fw_jump` expects it, so there is nothing for it to do.
- Performance that isn't so slow it's unusable — this core is pipelined,
  has a branch predictor, and now an I-cache and D-cache too (shared by
  both cores, in the bus adapter). The core that actually boots Linux is
  still single-issue and in-order; a separate out-of-order core exists
  (`CORE=ooo`, Phase 1d) but measures *slower* on CoreMark than the
  narrower design it replaced and does not itself boot Linux to userspace
  yet. Real Linux-capable FPGA cores often add superscalar/out-of-order
  execution too — whether it pays for itself here is a measured, open
  question this project reports honestly rather than assumes the answer
  to.

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
| 1 | **Superscalar issue and out-of-order execution** | ✅ **built and measured, all the way through 1d** — `rtl/ooo/core_ooo.v` now has register renaming, an 8-entry reorder buffer and general out-of-order issue, `make verify_ooo` green. CoreMark says the honest thing: 448,728 cycles, barely faster than the in-order core (453,844) and slower than the narrower 1b+1c design it replaced (434,822) — the ROI case made *before* 1d was built held up once it was measured. Full accounting, including why, in `docs/roadmap.md` |
| 2 | Break the memory ceiling — external DRAM | ✅ **done, on silicon** — a 99 KB program sent over the serial line into external SDRAM on a ULX3S 85F and executed from there. 64 KB of block RAM is no longer the ceiling |
| 3 | Make it fast enough to be interesting — caches, interrupt-driven UART | I-cache **1.79×** and D-cache **1.11×** on CoreMark, both in the bus adapter and shared by both cores. Interrupt-driven UART and multi-word lines remain |
| 4 | Video out | the framebuffer works; nothing is routed to the HDMI pins |
| 5 | Run software this project did not write — OpenSBI, Zephyr | ✅ **OpenSBI boots** — banner, platform detected from the device tree, root domain built, prepared to enter S-mode. `make sim_opensbi`. A kernel to hand off to is the remaining half |
| 6 | Debug infrastructure — JTAG, a Debug Module | makes every other phase cheaper |
| 7 | Close the boot path — the SD card | the only untested link in the boot chain — and the only phase nothing else is waiting on |

Before any of Phase 5's RTL, the SoC now builds under **Verilator** as well as
Icarus (`sim/verilator_soc.cpp`). That is not a nicety: a Linux boot is order
10⁸ cycles, which is seven hours per attempt under Icarus and about a minute
under Verilator — roughly **390×**, measured on the same image and the same
core. On a bring-up whose characteristic failure is a silent hang, the length
of that loop is what decides whether the work takes weeks or months.
`make verilator_check` runs `sim_sdramboot` under both and requires the same
cycle count, the same refresh count and the same output, so the fast path
cannot quietly drift from the slow one.

Phase 1 is first because it replaces the machine every later phase builds on,
and is cheaper to do before they widen the surface it has to preserve — but it
is the largest thing on the list by a wide margin, and `docs/roadmap.md` is
specific about what it requires and what must not regress while it happens.
Phase 7 needs a card of 32 GB or less and about five minutes. It is last
because nothing else is blocked by it — every hardware run preloads the program
into the bitstream and that works — not because it is hard.

Several known defects are open and unscheduled, written down rather than
left to be rediscovered — among them the intermittent `ISA-TIMEOUT` under
`make verify` (still undiagnosed; it self-reports rather than hanging
silently now, which is not the same as being fixed), the wide core's Linux
boot still not reaching userspace, and `CORE=ooo` having no measurable Fmax
at all — place-and-route's static timing analysis fails outright on a
combinational loop in its completion-bus muxing, a different and more
significant gap than a missed frequency. `docs/roadmap.md`'s own "Known
defects" section has the full, current list.

---

## Contributing, licence, and how this was built

| | |
|---|---|
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to build, what a good pull request looks like, and what gets pushed back on |
| [docs/practices.md](docs/practices.md) | The working rules — forty-five of them, each attached to the incident on this repo that produced it |
| [docs/roadmap.md](docs/roadmap.md) | Where this goes next, in phases, in dependency order |
| [docs/comparison.md](docs/comparison.md) | How this compares to SERV, PicoRV32, Ibex, VexRiscv, NEORV32, SweRV, Rocket Chip and CVA6 |
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
