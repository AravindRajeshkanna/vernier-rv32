# Contributing to Vernier-RV32

Thanks for looking. This is a single-author RISC-V core and SoC that grew into
something worth publishing, and contributions are welcome — bug reports most of
all, because the interesting failures here have all been things nobody thought
to test.

Two documents are worth reading before a substantial change:

- **[docs/practices.md](docs/practices.md)** — the working rules, each one
  attached to the incident that produced it. It is short, and it explains why
  reviews here ask the questions they ask.
- **[docs/architecture.md](docs/architecture.md)** — the full design writeup:
  pipeline, hazards, privilege, MMU, SoC, and every bug worth recording.

## Getting set up

macOS (Homebrew) or Linux. You need Icarus Verilog and a RISC-V toolchain for
everything; the rest is per-layer.

```bash
brew install icarus-verilog verilator surfer
brew install riscv-software-src/riscv/riscv-tools   # gcc + spike

make sim          # hand-assembled core regression — fastest thing that can fail
make verify       # everything that gates a change
```

`make isa-fetch` and `make coremark-fetch` pull the upstream suites (not
vendored, pinned to a commit). The ECP5 flow needs YosysHQ's `oss-cad-suite`
bundle on `PATH` — Homebrew has yosys but no `nextpnr-ecp5`. See
[docs/toolchain.md](docs/toolchain.md).

## Before you open a pull request

**Run `make verify` and say what it printed.** It runs, in rough order of how
fast they fail: the core regression, the software build, the SoC on the SD
boot path, the SoC on the board's preloaded path, a reset-and-rerun, the trap
handler calibration, video, the board wrapper, the SD probe, the architectural
tests, Spike co-simulation, and formal.

`make verify` builds the **in-order** core. `make verify_ooo` runs the same
suite against `rtl/ooo/core_ooo.v`, and CI runs both — so if your change
touches either core, or reaches into one (a debug probe, a formal wrapper),
run `verify_ooo` too. A change that compiled against one core and not the
other has already slipped through a green `verify` once.

**Neither `verify` covers the firmware targets**, because they need things off
the network: `make sim_opensbi` needs OpenSBI's cloned tree and `make
sim_linux` needs a 150 MB kernel tarball. Both build `CORE=inorder` by
default, and that gap is not theoretical — `mstatush` was added to
`rtl/cpu_core.v` and not to `rtl/ooo/core_ooo.v`, and OpenSBI could not boot
on the wide core *at all* for two releases without anything going red. If you
touch a CSR, a privilege check or the MMU, run:

```sh
make sim_opensbi CORE=ooo
```

A green `verify` is the baseline, not the bar. The bar is:

1. **A new test that fails without your change.** If you fixed something, show
   the test going red first. If you cannot make it go red, say so — that is
   useful information about the test, and sometimes the honest answer is that
   the bug is only reachable on hardware.
2. **Simulate the configuration that ships.** If your change touches anything
   the board runs, `make sim_ramboot` and `make sim_rerun` matter more than
   `make sim_soc` — see PRACTICES §4 and §5 for why the 256 KB / run-once
   simulation hid a real bug for months.
3. **Measured numbers, not estimated ones.** Timing, area, cycle counts: paste
   what the tool said.

If you have a board, say which one and paste the console output verbatim.
Hardware runs are recorded in this repo with the values that make them a report
about a specific build (`fpga/README.md` has the convention).

## Commit and PR style

Commits are imperative and say what changed and why it matters:

```
Test GPIO through a pad, not through a testbench
Report a trap in the loaded program instead of losing it
Rebuild .data at startup, and stop swallowing traps
```

The body carries the reasoning, the incident, and what you ruled out. This
project's history is where the *why* lives, so a long body on a subtle change
is welcome. Wrap at 72–76 columns.

Keep a pull request to one idea. If a change genuinely cannot be split — RTL
and its linker script and its testbench often move together — say so in the
description rather than splitting it into commits that do not build.

## What gets pushed back on

Not to be discouraging, but so you know what to expect:

- **A test that cannot fail.** The most common review comment. See PRACTICES
  §1 — the GPIO test passed for months while measuring the testbench.
- **A workaround described as a fix.** Workarounds are fine and sometimes
  right. Write down what you did not find out (§7).
- **A new duplicated constant with no named seam.** Some duplication is
  unavoidable across the Verilog/C/linker boundary; it gets a comment on both
  sides and a stated direction of safe error (§11).
- **A file nothing builds.** If `make verify` does not reach it, wire it in or
  leave it out (§14).
- **"Should be fine" as verification.** For RTL especially: if it is not
  simulated, it is not known.

## Reporting a bug

Please include the layer it showed up in (`make sim`, `make isa`, on a board),
the verbatim output, and — for hardware — the board, the FPGA variant, and the
`BOARD=` target you built. The issue forms ask for these.

If it is on hardware and the machine has stopped, note what the LEDs are
doing: `led[1:0]` carry the boot stage, `led[2]` is a heartbeat, `led[3]` is a
sticky "a trap happened", and an alternating `led[1:0]` pattern means the trap
handler halted and there is a report on the UART. `docs/soc.md` has the codes.

Security-relevant bugs — the privilege boundary, the MMU, trap delegation —
go through [SECURITY.md](SECURITY.md) instead.

## AI-assisted contributions

Allowed, and used heavily in this project's own history. They must be
disclosed, and you must be able to explain and defend every line you submit.
See [AI_USAGE.md](AI_USAGE.md) for the full policy and for this project's own
disclosure.

## Licensing of contributions

By contributing you agree that your contribution is licensed under the
Solderpad Hardware License 2.1 (`Apache-2.0 WITH SHL-2.1`), the same terms as
the rest of the project. See [LICENSE](LICENSE) and [NOTICE](NOTICE). There is
no CLA.

Do not paste code from another project into a pull request unless its license
permits it and you say where it came from. Third-party suites used here are
fetched at pinned commits rather than vendored, deliberately.

## Conduct

[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies to every space this project
uses.
