# Toolchain and development environment

Every version below was read off the machine this project was built on, not
copied from a requirements list. Where a tool is installed but unused, or
installed twice, this file says so — those are exactly the details that cost
time when a build behaves differently somewhere else.

## 1. Host

| | |
|---|---|
| OS | macOS 26.5.2 (build 25F84) |
| Kernel | Darwin 25.5.0 |
| Architecture | `arm64` (Apple Silicon) |
| Shell | zsh |
| Package manager | Homebrew, prefix `/opt/homebrew` |

Nothing in the project is macOS-specific. Two things about this host do leak
into the setup, both called out below: Homebrew has no `nextpnr` formula, and
macOS ships GNU Make 3.81.

## 2. Versions, as measured

| Tool | Version | Source |
|---|---|---|
| **Icarus Verilog** | 14.0 (devel), `s20260301-330-gb8b6e225f-dirty` | Homebrew `icarus-verilog` |
| **Verilator** | 5.051 devel, `v5.050-124-ga3e7f5103` (mod) | Homebrew `verilator` |
| **Yosys** (formal) | 0.67+post, `b8e7da6f` | Homebrew `yosys` |
| **Yosys** (synthesis) | 0.67+137, `41a4b5a03-dirty` | oss-cad-suite |
| **nextpnr-ecp5** | `nextpnr-0.10-109-g90b9be48` | oss-cad-suite |
| **ecppack** (Project Trellis) | 1.4-79-g56bb170 | oss-cad-suite |
| **riscv64-unknown-elf-gcc** | 15.1.0 (`g1b306039a`) | Homebrew `riscv-gnu-toolchain` |
| **Spike** | 1.1.1-dev | Homebrew `riscv-isa-sim` |
| **z3** | 4.15.4 (64-bit) | Homebrew `z3` |
| **Surfer** | 0.7.0 | Homebrew `surfer` |
| **dtc** | installed | Homebrew `dtc` |
| **openFPGALoader** | installed | Homebrew `openfpgaloader` |
| **Python** | 3.12.12 | system |
| **GNU Make** | 3.81 | macOS system |
| **git** | 2.54.0 | — |
| **oss-cad-suite** | `20260802` | YosysHQ prebuilt bundle |

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

## 3. What each flow uses

| `make` target | Tools |
|---|---|
| `sim`, `sim_soc`, `sim_software` | iverilog + vvp |
| `isa` | iverilog + vvp, driven by `tests/run.sh` |
| `cosim` | iverilog + vvp + **Spike** + Python (`tests/cosim.py`) |
| `formal` | **Yosys** + `yosys-smtbmc` + **z3** |
| `coremark` | riscv64-unknown-elf-gcc + iverilog |
| `software`, `soc` | riscv64-unknown-elf-gcc/objcopy + Python |
| `verilator` | Verilator + a C++ toolchain (AppleClang) |
| `wave`, `wave_soc` | **Surfer** (`VIEWER=` overrides) |
| `dtb` | `dtc` |
| *(script)* `fpga/synth/synth_ecp5.sh` | oss-cad-suite Yosys + nextpnr-ecp5 + ecppack |
| *(script)* `software/opensbi/build-opensbi.sh` | riscv64-unknown-elf-* + GNU Make |

`make verify` runs `sim`, `sim_software`, `sim_soc`, `isa`, `cosim` and
`formal` — so a full gate needs iverilog, the RISC-V GCC toolchain, Spike,
Yosys and z3. It does **not** need the FPGA toolchain.

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

## 4. Compiler flags that are load-bearing

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

## 5. Pinned upstream sources

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

## 6. Installing from scratch

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

## 7. Installed but not used by this project

Worth listing so nobody assumes a dependency that isn't one.

- **GTKWave** — present on this machine, but `make wave` uses Surfer
  (`VIEWER = surfer` in the `Makefile`). GTKWave was discontinued upstream
  and Homebrew disabled its cask on 2025-10-29, which is why the project
  switched. `VIEWER=gtkwave` still works if you have it from elsewhere.
- **riscv-pk** — pulled in by the `riscv-tools` formula. Nothing here uses
  it; Spike is invoked directly.
- **Verilator** — genuinely optional. `make verilator` exists as a
  second-opinion simulator on the flat `top.v` design; no gate depends on it,
  and the SoC is not wired up for it.

## 8. Not used at all

- **SymbiYosys (`sby`)** — not installed; see §3.
- **Vivado** — `fpga/synth/vivado.tcl` exists and has **never been
  executed**. There is no Xilinx toolchain on this machine.
- **LiteX / LiteDRAM** — named throughout the docs as the path to external
  DRAM, not currently a dependency.
- **CI** — there is none. No `.github/`, no pipeline config. `make verify` is
  run by hand.

## 9. Reproducibility caveats

Two things are not deterministic across machines, and both matter when
comparing numbers against `fpga/README.md`:

1. **nextpnr placement is stochastic.** Fmax varies run to run. This project
   has already recorded a 26.61-vs-28.25 MHz swing that was placement noise
   either side of the same design. Treat a single run's Fmax as approximate,
   and read the critical-path report rather than the headline number.
2. **Yosys version affects area and timing.** See §2 — the published numbers
   come from the oss-cad-suite build specifically.

Simulation is deterministic: iverilog, Spike co-simulation and the formal
checks give identical results run to run, which is why they, and not the
synthesis numbers, are what the gate is built on.
