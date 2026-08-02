#!/bin/sh
# Open-source synthesis + place-and-route for the SoC on a Lattice ECP5.
#
# Status: the **yosys** half of this has been run and the design synthesizes
# cleanly (measured numbers in fpga/README.md). The **nextpnr/Trellis** half
# has still never been executed - Homebrew ships nextpnr-ice40 only, and ECP5
# place-and-route needs the oss-cad-suite bundle. So area is measured; timing
# and Fmax are not.
#
# Prerequisites (macOS):
#   brew install --cask oss-cad-suite      # yosys + nextpnr + Trellis + openFPGALoader
#   . /path/to/oss-cad-suite/environment
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

DEVICE=${DEVICE:-25k}
PACKAGE=${PACKAGE:-CABGA381}
TOP=soc_fpga
BUILD=fpga/build

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

# The boot ROM image is read by a relative path at elaboration time, so run
# synthesis from wherever that path resolves.
cp sim/bootrom.hex "$BUILD/bootrom.hex"

echo "=== yosys ==="
( cd "$BUILD" && yosys -p "read_verilog $YOSYS_DEFINES $(echo "$RTL" | sed 's|[^ ]*|../../&|g'); \
    synth_ecp5 -top $TOP -json $TOP.json" )

echo "=== nextpnr-ecp5 ==="
nextpnr-ecp5 --"$DEVICE" --package "$PACKAGE" \
    --json "$BUILD/$TOP.json" \
    --lpf fpga/constraints/generic.lpf \
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
