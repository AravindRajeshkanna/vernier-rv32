# Toolchain and development environment

Every version below was read off the machine this project was built on, not
copied from a requirements list. Where a tool is installed but unused, or
installed twice, this file says so — those are exactly the details that cost
time when a build behaves differently somewhere else.

## 1. Host

| | |
|---|---|
| OS | macOS |
| Kernel | Darwin |
| Architecture | `arm64` (Apple Silicon) |
| Shell | zsh |
| Package manager | Homebrew, prefix `/opt/homebrew` |

Nothing in the project is macOS-specific. Two things about this host do leak
into the setup, both called out below: Homebrew has no `nextpnr` formula, and
macOS ships GNU Make 3.81.

## 2. Hardware under test

The board every hardware claim in this project refers to. Recorded here
because "it works on a board" is not a portable statement: the ULX3S ships
with four different FPGAs, three SDRAM parts across its revisions, and a
pinout that changed between v1.7 and v2.0.

| | |
|---|---|
| Board | **ULX3S v3.1.8** (Radiona/emard, made by Intergalaktik) |
| FPGA | **Lattice LFE5U-85F**, CABGA381 |
| Oscillator | 25 MHz, no PLL — the design's Fmax has never needed one |
| SDRAM | **IS42S16160G-7TL** — 32 MB, 16-bit, 4 banks x 8192 rows x 512 columns |
| Console | on-board FTDI FT231X, 115200 8N1, appears as `/dev/cu.usbserial-*` |
| Flashing | `openFPGALoader -b ulx3s fpga/build/<top>.bit` |
| Card slot | tested with a 64 GB SDXC card, which never answers CMD0 |

**The SDRAM part is the detail worth knowing.** `rtl/soc/wb_sdram.v` defaults
to `ROW_BITS=13`, `COL_BITS=9`, `BA_BITS=2`, which is exactly the
IS42S16160G's geometry — v3.1.4 onward standardised on it. Earlier v3.0.x
boards shipped a mix, and some carried an **AS4C32M16**: 64 MB with *ten*
column bits, which needs `COL_BITS=10`. The controller would still be correct
with the wrong value — the mapping stays injective, it just addresses half the
part — so this is a silent capacity loss rather than a failure, which is
exactly why it is written down.

**Pins** come from the board's own [`ulx3s_v20.lpf`][lpf], cross-checked
line-for-line against [litex-boards' `radiona_ulx3s.py`][litex]. That file
covers v2.0, v3.0.x and v3.1.x alike: the v3.1 changes were ESP32 JTAG pins,
GPIO0 moving to a clock-capable pin, the OLED header going 7->8 and SERDES
pairs, none of which touched the memory. **It is not valid for v1.7**, which
wires the SD card's four SPI-mode pins to different sites entirely.

[lpf]: https://github.com/emard/ulx3s/blob/master/doc/constraints/ulx3s_v20.lpf
[litex]: https://github.com/litex-hub/litex-boards/blob/master/litex_boards/platforms/radiona_ulx3s.py

### What has actually been on this board, and what has not

`fpga/README.md` is the authority and carries the console output verbatim.
The short version, because the distinction matters more than the list:

| | |
|---|---|
| SoC boots, acceptance test passes | ✅ on silicon |
| newlib / `printf` | ✅ on silicon |
| Surviving a reset | ✅ on silicon |
| SD card | ❌ CMD0 unanswered |
| Video scan-out | ❌ not routed |
| **SDRAM, as data** | ✅ **on silicon** — 256 KB of unique addresses, byte/halfword lanes, refresh |
| Running code *from* SDRAM | ✅ **on silicon** — 99 KB sent over the serial line by `software/soc/uartload.py` |

The SDRAM rows earned their detail. The first bitstream ran, mostly worked,
and failed one word in a thousand — a clock-phase margin, and nothing
simulation could have caught. Moving the part's clock half a period and the
capture point one cycle fixed it, and the re-run reads and writes 256 KB
cleanly. `fpga/README.md` has both logs, the arithmetic and the two-step
procedure; `docs/practices.md` §23 has what it cost to read the evidence
properly.

Running *code* from SDRAM needed a loader, because a bitstream initialises
block RAM at configuration time and SDRAM comes up empty. The boot ROM has one
now — `software/soc/uartload.py`, standard library only — and a 99 KB program
has been through it onto a board.

### Place-and-route, as measured

Run on this host with the oss-cad-suite in §3, against the real pinout with
`--lpf-allow-unconstrained` **not** set — so an unplaced pin is an error
rather than an invented placement.

| Build | Fmax | LUT | FF | Block RAM | IO |
|---|---|---|---|---|---|
| `BOARD=ulx3s85-sdramcheck` (full SoC) | **27.41 MHz** — PASS at 25 | 16,831 (20%) | 7,418 (8%) | 107/208 (51%) | 93/365 (25%) |
| `BOARD=ulx3s-sdram` (probe, no CPU) | **95.79 MHz** | 684 (<1%) | 331 (<1%) | 0 | 56/365 (15%) |

(Both figures moved slightly when the SDRAM clock went through an `ODDRX1F`
instead of being a routed copy of the input clock — the SDRAM pin stopped
being its own clock domain, which is a cleaner thing for the timing analysis
to look at as well as the fix for a real hardware failure.)

**27.41 MHz is down from the 30.77 MHz** this file's predecessor recorded, and
that is the first place-and-route since both the data cache and the SDRAM
controller landed, so the drop belongs to the pair of them rather than to
either one. It still passes at the board's 25 MHz, but the margin is now 10%
rather than 23%, which is worth knowing before adding anything else.

The critical path is **not** in the memory controller or in either cache. It
runs from the CSR write-enable decode to the ID/EX register file's load
enable — 11.32 ns of logic against 26.03 ns of routing, which is the same
routing-dominated shape every measurement of this design has had.

---

## 3. Versions, as measured

| Tool | Version | Source |
|---|---|---|
| **Icarus Verilog** | 12.0 (stable) | Homebrew `icarus-verilog` |
| **Verilator** | 5.050, `2026-07-01` | Homebrew `verilator` |
| **Yosys** (formal) | 0.67+post, `b8e7da6f` | Homebrew `yosys` |
| **Yosys** (synthesis) | 0.68+118, `144c707b7-dirty` | oss-cad-suite |
| **nextpnr-ecp5** | `nextpnr-0.11.1-8-g7c0c1c40` | oss-cad-suite |
| **ecppack** (Project Trellis) | 1.4-82-g3afe7b5 | oss-cad-suite |
| **riscv64-unknown-elf-gcc** | 15.1.0 (`g1b306039a`) | Homebrew `riscv-gnu-toolchain` |
| **Spike** | 1.1.1-dev | Homebrew `riscv-isa-sim` |
| **z3** | 4.15.4 (64-bit) | Homebrew `z3` |
| **Surfer** | 0.7.0 | Homebrew `surfer` |
| **dtc** | installed | Homebrew `dtc` |
| **openFPGALoader** | installed | Homebrew `openfpgaloader` |
| **LLVM `ld.lld`** | 21.1.8 | Homebrew `lld`. Used *only* to build the Linux kernel: the vDSO needs `-shared` and `riscv64-unknown-elf-ld` cannot do it, the same shape of problem as OpenSBI's `-pie`. |
| **GNU sed (`gsed`)** | installed | Homebrew `gnu-sed`. Required for a kernel build, not optional: `arch/riscv/kernel/vdso/gen_vdso_offsets.sh` uses `\\+`, which BSD sed does not support, and the result is an *empty* generated header rather than an error. |
| **QEMU** | 10.2.0 | Homebrew `qemu`. `qemu-system-riscv32` is how a kernel is separated from this SoC: if it boots there and not here, the software is not the problem. |
| **Python** | 3.12.12 | system |
| **GNU Make** | 3.81 | macOS system |
| **git** | 2.54.0 | — |
| **oss-cad-suite** | `20260821` | YosysHQ prebuilt bundle |

### Two Yosys installations, and why it matters

There are two, they are different builds, and **the flows do not use the same
one**:

- `make formal` runs whatever `yosys` is first on `PATH` — normally
  Homebrew's 0.67+post.
- `fpga/synth/synth_ecp5.sh` needs `PATH` pointed at oss-cad-suite first,
  because that is the only place `nextpnr-ecp5` exists:

  ```bash
  export PATH=$HOME/tools/oss-cad-suite/bin:$PATH
  ```

  The script checks for `yosys`, `nextpnr-ecp5` and `ecppack` before it starts
  and prints that line if any are missing. That check exists because a run
  once got through 56 seconds of synthesis on a shell with only Homebrew on
  its `PATH` before dying at `nextpnr-ecp5: command not found`, with the
  netlist already built and nothing to do with it.

This is not a deliberate design, it is a consequence of packaging: Homebrew
has a `yosys` formula and a `prjtrellis` formula, but **no `nextpnr`
formula**, and `prjtrellis` ships the ECP5 database and `ecppack` without
`nextpnr-ecp5` — the one piece that actually matters for timing. So the ECP5
flow comes from YosysHQ's prebuilt bundle, which brings its own Yosys along
with it.

The published synthesis and place-and-route numbers in `fpga/README.md` were
produced with the **oss-cad-suite** Yosys. If you reproduce them with
Homebrew's, expect small differences.

### GNU Make 3.81

macOS still ships the 2006 release. The `Makefile` is written to work with
it. If you add rules, avoid `.ONESHELL`, `!=` shell assignment, and grouped
targets (`&:`) — none of which 3.81 has.

## 4. What each flow uses

| `make` target | Tools |
|---|---|
| `sim`, `sim_soc`, `sim_software` | iverilog + vvp |
| `isa` | iverilog + vvp, driven by `tests/run.sh` |
| `cosim` | iverilog + vvp + **Spike** + Python (`tests/cosim.py`) |
| `formal` | **Yosys** + `yosys-smtbmc` + **z3** |
| `coremark` | riscv64-unknown-elf-gcc + iverilog |
| `software`, `soc` | riscv64-unknown-elf-gcc/objcopy + Python |
| `verilator` | Verilator + a C++ toolchain (AppleClang) — the flat `rtl/top.v` |
| `verilator_soc`, `verilator_sdramboot` | the same, on the **SoC** (`sim/verilator_soc.cpp`) |
| `verilator_check` | both simulators at once: iverilog + vvp **and** Verilator |
| `wave`, `wave_soc` | **Surfer** (`VIEWER=` overrides) |
| `dtb` | `dtc` |
| *(script)* `fpga/synth/synth_ecp5.sh` | oss-cad-suite Yosys + nextpnr-ecp5 + ecppack |
| *(script)* `software/opensbi/build-opensbi.sh` | riscv64-unknown-elf-* + GNU Make |

`make verify` runs `sim`, `sim_software`, `sim_soc`, `isa`, `cosim`,
`verilator_check` and `formal` — so a full gate needs iverilog, **Verilator**,
the RISC-V GCC toolchain, Spike, Yosys and z3. It does **not** need the FPGA
toolchain.

Verilator became a hard dependency of `verify` when the SoC harness landed,
for the reason in practices §14: a file nothing in `verify` builds will rot,
and `sim/verilator_soc.cpp` is about to be the main instrument for the Linux
bring-up. `verilator_check` reuses the `sim_sdramboot` run rather than
repeating it, so it costs about a second on top of a suite that already runs
for many minutes.

### Two simulators on the same SoC, and why

Everything under `sim/tb_*.v` runs on Icarus, and Icarus runs this SoC at
about **11 thousand cycles per second** (measured: `sim_sdramboot`, 2,108,456
cycles in 187 s). That is fine for every test in the suite — the longest is
under four minutes.

It stops being fine at Phase 5. A Linux boot is order 10⁸ cycles, which is
**seven hours or more per attempt** on Icarus, on a bring-up whose
characteristic failure is a silent hang with no output at all. So `soc_top`
is also built under Verilator, by `sim/verilator_soc.cpp`:

| | cycles/s | `sim_sdramboot` | a ~3×10⁸-cycle Linux boot |
|---|---|---|---|
| Icarus + `vvp` | ~11.3 k | 187 s | ~7.4 hours |
| Verilator | ~4.44 M | **0.47 s** | **~1.1 minutes** |

Roughly **390×**, on the same machine, same image, same core.

The catch is that Verilator cannot run `sim/sdram_model.v`: that model is
written in nanoseconds, with `#T_AC_NS` on the data path, and Verilator has
no notion of either. So the harness carries a C++ port of it — which means
there are now two memory models that could disagree, and a fast simulator
that quietly lies is worse than a slow one that does not.

`make verilator_check` is the answer to that. It runs `sim_sdramboot` under
both and compares the **cycle count** — not merely that both say `PASS`,
which two quite different machines could do — along with the refresh count
and every byte the program printed. Measured, on both cores:

| | Icarus | Verilator | |
|---|---|---|---|
| in-order, cycles | 2,108,456 | 2,108,457 | +1 |
| in-order, refreshes | 10,754 | 10,754 | exact |
| wide, cycles | 1,688,890 | 1,688,890 | exact |
| wide, refreshes | 8,613 | 8,613 | exact |

The cycle count is allowed to differ by one and nothing else is allowed to
differ at all. That one cycle is a testbench artefact — Icarus watches the
verdict word from a process that resumes before the edge's non-blocking
assignments land, and a cycle-based harness has no such region — and it is
*slack*, not a correction, because the offset is +1 on one core and 0 on the
other. An earlier version fitted a constant to the in-order measurement and
turned the wide core's clean run into a false failure; practices §25.

`sim/sdram_model.v` remains the authority on what the part will accept; the
C++ port is checked against it, not the other way round.

### Formal is driven directly, not through SymbiYosys

`sby` is the usual front end for this and is not packaged for Homebrew, so
`formal/run.sh` does the two steps it would wrap by hand: Yosys writes the
design plus its properties out as an SMT2 transition system, and
`yosys-smtbmc` unrolls that and asks z3 whether any assertion can be violated
within `DEPTH` (default 12) cycles. `SOLVER=` and `DEPTH=` override.

### Python

Version 3.12.12, and the scripts (`tests/cosim.py`, `software/bin2hex.py`,
`software/soc/mkcard.py`) import **only the standard library** — `argparse`,
`os`, `re`, `struct`, `subprocess`, `sys`. There is no `requirements.txt`,
no virtualenv, and nothing to install. Any Python 3.8+ should do.

## 5. Compiler flags that are load-bearing

The target is RV32IMA, but the *compiler* is only ever asked for `rv32im`:

```
-march=rv32im_zicsr_zifencei  -mabi=ilp32
```

- `rv32im` rather than `rv32ima` because that is what has a **multilib** in
  the Homebrew toolchain. The A extension is used by hand-written assembly
  and by the tests, not by compiler-generated code.
- `zicsr` and `zifencei` are named explicitly because the firmware reads CSRs
  and issues `FENCE.I` directly; they tell the assembler those opcodes are
  legal and do not change multilib selection.
- `-specs=nano.specs` (newlib-nano) for anything wanting `printf`;
  `-ffreestanding -nostartfiles` everywhere, with `crt0` supplied by this
  project.

OpenSBI builds with `PLATFORM=generic`, `PLATFORM_RISCV_XLEN=32`,
`PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei`, `PLATFORM_RISCV_ABI=ilp32`,
`FW_PIC=n`.

## 6. Pinned upstream sources

Neither suite is vendored. Both are somebody else's project with their own
licence, and the whole value of running them is that this project did not
write them — so each is fetched at a **pinned commit**, and a regression can
never be explained away by "upstream changed".

| Project | Commit | Fetched by |
|---|---|---|
| riscv-tests | `6de71edb142be36319e380ce782c3d1830c65d68` | `make isa-fetch` |
| CoreMark | `1f483d5b8316753a742cbf5590caf5bd0a4e4777` | `make coremark-fetch` |
| OpenSBI | tracks upstream `master` | `software/opensbi/build-opensbi.sh` |

OpenSBI is the exception and is not pinned, because it is not part of any
pass/fail gate — it builds, it does not yet boot. See
`software/opensbi/README.md`.

## 7. Installing from scratch

```bash
# Simulation, verification and the RISC-V toolchain
brew install icarus-verilog verilator yosys z3 surfer dtc
brew install riscv-software-src/riscv/riscv-tools   # gcc + spike
brew install openfpgaloader                          # only to flash a board

# ECP5 synthesis + place-and-route. There is no Homebrew cask for
# oss-cad-suite and no nextpnr formula, so use YosysHQ's bundle.
curl -L -o oss-cad-suite.tgz \
  https://github.com/YosysHQ/oss-cad-suite-build/releases/latest/download/oss-cad-suite-darwin-arm64-<date>.tgz
tar xzf oss-cad-suite.tgz -C ~/tools
export PATH=~/tools/oss-cad-suite/bin:$PATH   # needed only for the FPGA flow
```

Then:

```bash
make verify     # full gate: no FPGA toolchain required
make soc && ./fpga/synth/synth_ecp5.sh   # bitstream; needs oss-cad-suite on PATH
```

`make soc` must run before synthesis: the boot ROM image is pulled in with
`$readmemh` at elaboration time, which makes it a **synthesis** input rather
than only a simulation one. Both synthesis scripts refuse to start without
it.

### The synthesis toolchain version is part of the result

`fpga/README.md`'s Fmax figures name the bundle they came from, and they have
to. Moving from `20260802` to `20260821` — nextpnr `0.10-109` → `0.11.1-8`,
yosys `0.67+137` → `0.68+118` — cost the 85F build **1.34 MHz** on unchanged
RTL, which is twice what the design change measured alongside it cost. A
place-and-route number compared against one from a different bundle is not a
comparison. Re-measure the baseline on the same tools, or say which bundle
each figure came from; docs/practices.md §20.

## 8. Installed but not used by this project

Worth listing so nobody assumes a dependency that isn't one.

- **GTKWave** — present on this machine, but `make wave` uses Surfer
  (`VIEWER = surfer` in the `Makefile`). GTKWave was discontinued upstream
  and Homebrew disabled its cask on 2025-10-29, which is why the project
  switched. `VIEWER=gtkwave` still works if you have it from elsewhere.
- **riscv-pk** — pulled in by the `riscv-tools` formula. Nothing here uses
  it; Spike is invoked directly.

## 9. Not used at all

- **SymbiYosys (`sby`)** — not installed; see §4.
- **Vivado** — `fpga/synth/vivado.tcl` exists and has **never been
  executed**. There is no Xilinx toolchain on this machine.
- **LiteX / LiteDRAM** — named throughout the docs as the path to external
  DRAM, not currently a dependency.

## 10. Reproducibility caveats

Two things are not deterministic across machines, and both matter when
comparing numbers against `fpga/README.md`:

1. **nextpnr placement is stochastic.** Fmax varies run to run. This project
   has already recorded a 26.61-vs-28.25 MHz swing that was placement noise
   either side of the same design. Treat a single run's Fmax as approximate,
   and read the critical-path report rather than the headline number.
2. **Yosys version affects area and timing.** See §3 - the published numbers
   come from the oss-cad-suite build specifically.

Simulation is deterministic: iverilog, Spike co-simulation and the formal
checks give identical results run to run, which is why they, and not the
synthesis numbers, are what the gate is built on. That determinism is
per-invocation of one fixed binary - **it does not mean the Homebrew
`icarus-verilog` formula itself is fixed.** This file's own §3 entry for it
drifted from `14.0 (devel)` to `12.0 (stable)` on this same machine between
when that line was written and 2026-08-31, with no project change
responsible for it - `brew upgrade`/`brew install` moves the formula
forward or (via a reinstall) back independently of anything in this repo.
That is a real, evidenced mechanism behind at least one investigation here:
`docs/roadmap.md`'s resolved sdramboot `verilator_check` discrepancy
bisected to "same commit, same RTL, different result," which a version
change in Icarus specifically - not in this project's code - explains
cleanly. Anyone chasing a simulation result that will not reproduce should
check `iverilog -V` against this table before assuming the RTL is at fault.
