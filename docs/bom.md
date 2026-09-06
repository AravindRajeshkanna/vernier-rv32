# Bill of materials

`bom/gen_sbom.py` and `bom/gen_hbom.py` generate this project's software and
hardware bills of materials as CycloneDX 1.5 JSON, gated in CI's own
`Bill of materials (SBOM + HBOM)` job. `make bom` runs both locally and
checks them the same way CI does.

## Why generated, not hand-maintained

A hand-written BOM is a second place every pin has to be kept in sync by
hand, and this project already has a rule about that: any constant
duplicated across files needs a comment on both sides saying so (see the PR
template). A generated one is the alternative to duplicating at all - the
scripts read the same files that already pin each version
(`tests/fetch.sh`'s own `PIN=`, `.github/actions/riscv-toolchain/action.yml`'s
own `default:`, and so on) rather than a second, hand-copied list that can
drift the moment one side changes and the other does not.

The one place this could not be done - there is no machine-readable source
for "which SDRAM part is on a ULX3S v3.1.4" - is transcribed instead from
`docs/toolchain.md` §2 and `fpga/README.md`, and `bom/test_bom.py`
cross-checks every transcribed fact against whichever of those two files it
came from, so a board-component list going stale is still something a test
catches rather than something nobody notices until it's wrong.

## SBOM: `bom/sbom.json`

Every pinned software dependency this project's own build and CI pipeline
actually touches:

- The RISC-V toolchain (xPack's `riscv-none-elf-gcc`), oss-cad-suite
  (yosys/yosys-smtbmc/z3/nextpnr-ecp5), Vale and `markdownlint-cli2` -
  all version-pinned already, for reasons `docs/toolchain.md` and the CI
  workflow's own comments give; the SBOM just surfaces those pins in one
  place rather than requiring five files be read to reconstruct the list.
- `riscv-tests` and CoreMark, fetched-not-vendored at a pinned commit each,
  for the same "a regression should never be explained away by 'upstream
  changed'" reason `tests/fetch.sh`'s own comment states.
- OpenSBI and the Linux kernel, whose build scripts pin a commit/version
  even though neither one runs in CI (both need the network - see
  CONTRIBUTING.md).
- Icarus Verilog and Verilator, deliberately **not** pinned anywhere in
  this repo (`.github/actions/verilator/action.yml`'s own reasoning:
  nothing about the result depends on Verilator's version). Their SBOM
  entries record whatever version actually ran this specific generation,
  not a promise about any other run - `internal:pinning: unpinned` marks
  them so a reader does not mistake "recorded" for "pinned."

## HBOM: `bom/hbom.json`

Two different kinds of "hardware," combined into one document since this
project does not design its own PCB and a hardware/software split does not
mean the same thing here it would for a company shipping silicon:

- **RTL-instantiated silicon IP.** Found by scanning, not listed by hand:
  Lattice's ECP5 hard-primitive naming convention is ALL CAPS (`EHXPLLL`,
  `ODDRX1F`, ...), distinct from every module this project defines itself,
  so `bom/gen_hbom.py` finds every instantiated primitive automatically
  rather than needing to be told about the next one someone adds. Today
  that is exactly two: the PLL (`fpga/video_pll.v`) and the DDR output
  register used both for the SDRAM clock and the TMDS serializer's own
  output stage.
- **The target board's physical components.** ULX3S, the Lattice
  LFE5U-85F this project has actually run on (and the 45F it has only
  synthesized for), the SDRAM part split `docs/toolchain.md` §2 already
  documents precisely (`IS42S16160G-7TL` on this project's own board;
  `AS4C32M16` on some older revisions, needing a different
  `rtl/soc/wb_sdram.v` configuration), the on-board ESP32, and the FT231X
  USB-serial bridge the console runs through.

## Regenerating locally

```sh
make bom            # writes bom/sbom.json and bom/hbom.json, then checks both
make sbom            # just the SBOM
make hbom            # just the HBOM
python3 bom/test_bom.py   # just the check, against whatever is already on disk
```

Both JSON files are generated, not committed (`.gitignore`) - CI uploads
them as build artifacts on every run instead, the same way a synthesis
report or a coverage file would be.

## What would make `bom/test_bom.py` fail

Any of: a pinned-version file changing its own format so the extraction
regex no longer matches (the generator raises rather than silently
emitting an empty or wrong version); a board-component fact transcribed
here no longer appearing in the doc it was transcribed from; a new
locally-defined, all-caps module name being misdetected as a hard
primitive; or `iverilog`/`verilator` being absent from an environment the
test expects to have them (CI's own `bom` job, or any contributor's
machine that has run `make verify`).
