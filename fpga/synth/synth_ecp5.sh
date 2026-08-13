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

PACKAGE=${PACKAGE:-CABGA381}
BUILD=fpga/build

# Three ways to build this:
#
#   ./fpga/synth/synth_ecp5.sh                   board-agnostic, timing only
#   BOARD=ulx3s   ./fpga/synth/synth_ecp5.sh     ULX3S with an LFE5U-45F
#   BOARD=ulx3s85 ./fpga/synth/synth_ecp5.sh     ULX3S with an LFE5U-85F
#
# The default constrains the clock and nothing else, which produces an Fmax
# without inventing a board - useful for tracking the design's own timing, but
# optimistic, because nextpnr may place I/O wherever suits it.
#
# The BOARD= targets build fpga/ulx3s_top.v against real pins and drop
# --lpf-allow-unconstrained, so an unplaced pin becomes an error instead of a
# silently invented placement. Those are the numbers to trust for hardware.
#
# **The FPGA variant is part of the board target, not a separate knob.** A
# bitstream is device-specific and will not load on a different one, and the
# ULX3S ships with four FPGA options that are indistinguishable in a photo.
# Pairing them here means the device cannot be left at a stale default -
# which it silently would be, since 45F and 85F share this board, this
# pinout and this wrapper, and differ only in the chip. DEVICE= still
# overrides for anything not listed.
BOARD=${BOARD:-}
DIAG_ONLY=0

case "$BOARD" in
    ulx3s)
        DEVICE=${DEVICE:-45k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v"
        ;;
    ulx3s-diag)
        # SD-path hardware diagnostic: no CPU, no SoC. Builds only
        # fpga/ulx3s_diag.v against a cut-down LPF. 85F because that is the
        # board in hand; DEVICE=45k works too, the design is tiny either way.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_diag}
        LPF=${LPF:-fpga/constraints/ulx3s_diag.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_diag.v"
        DIAG_ONLY=1
        ;;
    ulx3s-cmd0)
        # Hardware CMD0 probe: sends the SD reset command and shows the
        # reply on the LEDs. Same port set as the diagnostic, so it shares
        # that LPF.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_cmd0}
        LPF=${LPF:-fpga/constraints/ulx3s_diag.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_cmd0.v"
        DIAG_ONLY=1
        ;;
    ulx3s85)
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v"
        ;;
    "")
        # 45k, because 64 KB of on-chip RAM needs 67 block RAMs and a 25F
        # has 56. See fpga/README.md's device table.
        DEVICE=${DEVICE:-45k}
        TOP=${TOP:-soc_fpga}
        LPF=${LPF:-fpga/constraints/timing_only.lpf}
        PNR_EXTRA=${PNR_EXTRA:---lpf-allow-unconstrained}
        BOARD_RTL=""
        ;;
    *)
        echo "error: unknown BOARD='$BOARD' (known: ulx3s, ulx3s85, ulx3s-diag, ulx3s-cmd0, or unset)" >&2
        exit 1
        ;;
esac

# -DSYNTHESIS drops the memories' zero-fill initial loops, which exist for
# simulation only and which yosys unrolls into one assignment per word - the
# single thing that used to make this script appear to hang. See
# rtl/soc/wb_ram.v.
YOSYS_DEFINES="-DSYNTHESIS"

if [ "$DIAG_ONLY" = "1" ]; then
  RTL="$BOARD_RTL"
else
RTL="rtl/regfile.v rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v \
     rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v \
     rtl/soc/wb_interconnect.v rtl/soc/cpu_wb.v rtl/soc/wb_ram.v \
     rtl/soc/wb_rom.v rtl/soc/wb_periph_bridge.v rtl/soc/wb_gpio.v \
     rtl/soc/wb_spi.v rtl/soc/video_timing.v rtl/soc/wb_framebuffer.v \
     rtl/soc/soc_top.v fpga/soc_fpga.v $BOARD_RTL"
fi

if [ "$DIAG_ONLY" != "1" ] && [ ! -f sim/bootrom.hex ]; then
    echo "error: sim/bootrom.hex missing - run 'make soc' first" >&2
    exit 1
fi

mkdir -p "$BUILD"

# The boot ROM image is read by a *relative* path at elaboration time
# ($readmemh resolves against the working directory), so synthesis runs from
# $BUILD where a copy of it lives - and the RTL paths are made absolute
# rather than counted out in ../.., which is easy to get wrong and silently
# produces "file not found" from inside a yosys command line.
[ "$DIAG_ONLY" = "1" ] || cp sim/bootrom.hex "$BUILD/bootrom.hex"

# Stated up front and again at the end: a bitstream is device-specific, and
# loading one built for the wrong ECP5 fails in ways that look like a broken
# design rather than a broken command line.
echo "=== target: ${BOARD:-generic}, LFE5U-${DEVICE%k}F, $PACKAGE ==="
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
echo "bitstream: $BUILD/$TOP.bit  (LFE5U-${DEVICE%k}F - will not load on any other ECP5)"
case "$BOARD" in
    ulx3s|ulx3s85|ulx3s-diag|ulx3s-cmd0) echo "flash with: openFPGALoader -b ulx3s $BUILD/$TOP.bit" ;;
    *)             echo "flash with: openFPGALoader -b <your-board> $BUILD/$TOP.bit" ;;
esac
echo
echo "Check nextpnr's reported Fmax against your target clock. If it comes in"
echo "under, read the critical path out of the log above rather than guessing"
echo "- twice now the guess has been wrong. The last measured one runs from a"
echo "block RAM read port through the MMU walk result to the PC, and is mostly"
echo "routing. See fpga/README.md."
