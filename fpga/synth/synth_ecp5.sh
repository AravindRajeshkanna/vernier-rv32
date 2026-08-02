#!/bin/sh
# Open-source synthesis + place-and-route for the SoC on a Lattice ECP5.
#
# Status: **this script has been run end to end.** yosys, nextpnr-ecp5 and
# ecppack all complete and produce a bitstream. Measured results (area,
# achieved Fmax, and the critical path) are in fpga/README.md.
#
# What has *not* happened: nothing has been loaded onto a board, because
# there is no board. The pinout in constraints/generic.lpf is still
# placeholders, so a real build needs a real LPF - see DEFAULT_LPF below.
#
# Prerequisites (macOS): there is no Homebrew cask or nextpnr formula, so the
# ECP5 flow comes from YosysHQ's prebuilt bundle:
#
#   curl -L -o oss-cad-suite.tgz \
#     https://github.com/YosysHQ/oss-cad-suite-build/releases/latest/download/oss-cad-suite-darwin-arm64-<date>.tgz
#   tar xzf oss-cad-suite.tgz -C ~/tools
#   export PATH=~/tools/oss-cad-suite/bin:$PATH
#
# (Homebrew's `prjtrellis` provides the ECP5 database and ecppack, but not
# nextpnr-ecp5, which is the piece that matters here.)
#
# Before running:
#   1. Fill in real pins in fpga/constraints/generic.lpf
#   2. Set DEVICE/PACKAGE below to your board
#   3. Set CLK_HZ in fpga/soc_fpga.v to your board's oscillator
#   4. `make soc` at the repo root, so sim/bootrom.hex exists - it is
#      $readmemh'd into the boot ROM at elaboration time and is therefore a
#      synthesis input, not just a simulation one
set -eu

cd "$(dirname "$0")/../.."
ROOT="$PWD"

# 45k, because 64 KB of on-chip RAM needs 67 block RAMs and a 25F has 56.
# A 25F build works at RAM_BYTES=32768 - see fpga/README.md's table.
DEVICE=${DEVICE:-45k}
PACKAGE=${PACKAGE:-CABGA381}
TOP=soc_fpga
BUILD=fpga/build

# Default to the timing-only constraints: they pin the clock and nothing else,
# which is what produces an honest Fmax without inventing a board. Point LPF
# at your board's real file for an actual build, and drop
# --lpf-allow-unconstrained so an unplaced pin is an error rather than a
# surprise.
LPF=${LPF:-fpga/constraints/timing_only.lpf}
PNR_EXTRA=${PNR_EXTRA:---lpf-allow-unconstrained}

# -DSYNTHESIS drops the memories' zero-fill initial loops, which exist for
# simulation only and which yosys unrolls into one assignment per word - the
# single thing that used to make this script appear to hang. See
# rtl/soc/wb_ram.v.
YOSYS_DEFINES="-DSYNTHESIS"

RTL="rtl/regfile.v rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v \
     rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v \
     rtl/soc/wb_interconnect.v rtl/soc/cpu_wb.v rtl/soc/wb_ram.v \
     rtl/soc/wb_rom.v rtl/soc/wb_periph_bridge.v rtl/soc/wb_gpio.v \
     rtl/soc/wb_spi.v rtl/soc/soc_top.v fpga/soc_fpga.v"

if [ ! -f sim/bootrom.hex ]; then
    echo "error: sim/bootrom.hex missing - run 'make soc' first" >&2
    exit 1
fi

mkdir -p "$BUILD"

# The boot ROM image is read by a *relative* path at elaboration time
# ($readmemh resolves against the working directory), so synthesis runs from
# $BUILD where a copy of it lives - and the RTL paths are made absolute
# rather than counted out in ../.., which is easy to get wrong and silently
# produces "file not found" from inside a yosys command line.
cp sim/bootrom.hex "$BUILD/bootrom.hex"

echo "=== yosys ==="
( cd "$BUILD" && yosys -p "read_verilog $YOSYS_DEFINES $(echo "$RTL" | sed "s|[^ ][^ ]*|$ROOT/&|g"); \
    synth_ecp5 -top $TOP -json $TOP.json" )

echo "=== nextpnr-ecp5 ==="
nextpnr-ecp5 --"$DEVICE" --package "$PACKAGE" \
    --json "$BUILD/$TOP.json" \
    --lpf "$LPF" $PNR_EXTRA \
    --textcfg "$BUILD/$TOP.config"

echo "=== ecppack ==="
ecppack "$BUILD/$TOP.config" "$BUILD/$TOP.bit"

echo
echo "bitstream: $BUILD/$TOP.bit"
echo "flash with: openFPGALoader -b <your-board> $BUILD/$TOP.bit"
echo
echo "Check nextpnr's reported Fmax against your target clock. If it comes"
echo "in under, the usual first suspects in this design are the combinational"
echo "paths through wb_interconnect.v's address decode and response mux, and"
echo "cpu_core.v's EX stage - see fpga/README.md."
