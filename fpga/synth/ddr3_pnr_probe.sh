#!/bin/sh
# Synthesis and place-and-route of the DDR3 PHY on the ECPIX-5's device, with the board's
# real DDR3 pins - a probe of whether the PHY's structure is legal on an ECP5, not a
# bring-up build. Docs/roadmap.md, Parts 21 and 22.
#
# What passing shows: yosys maps every DDR primitive, and nextpnr packs, places and routes
# them against the real LFE5UM5G-85F/CABGA554 pin data - including checks no simulation
# can make: every IDDRX2DQA takes its pointers from its byte lane's DQSBUFM, a DQ/DQS
# tri-state control reaches its pad directly (which also catches it being inverted on
# the way), the DQS pad is a DQS site, DM lands on its own real pin at the right I/O
# standard, edge clocks reach the banks they serve, and no bank mixes 1.5 V and 3.3 V
# pads. Each was shown able to fail by mutation.
#
# What it does NOT show, and was shown not to (Part 21): that a DQ pin sits in its DQS
# group - moving one to an address pin passed - or that a tri-state control is used at all
# (tying it to a constant passed). It says nothing about behaviour, or about timing at the
# DDR clock, or about the four ports that have no pin on this board
# (fpga/constraints/ecpix5_ddr3_probe.lpf parks them on throwaway pins). The pin list is
# only as good as the two sources it was taken from.
#
# Needs yosys and nextpnr-ecp5, so YosysHQ's bundle first on PATH (see synth_ecp5.sh).
# Not in `make verify`, for the reason the rest of the FPGA flow is not: it needs the bundle.
# CI runs it (the `formal` job has the bundle).
set -eu

cd "$(dirname "$0")/../.."

BUILD=${BUILD:-fpga/build/ddr3_probe}
SEED=${SEED:-1}
missing=""
for tool in yosys nextpnr-ecp5; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    echo "ddr3_pnr_probe: not on PATH:$missing" >&2
    echo "  the ECP5 flow comes from YosysHQ's bundle: export PATH=\$HOME/tools/oss-cad-suite/bin:\$PATH" >&2
    exit 1
fi
mkdir -p "$BUILD"

RTL="fpga/ecpix5_ddr3_probe.v rtl/soc/ddr3_ecp5_top.v rtl/soc/ddr3_eclk_pll.v
     rtl/soc/ddr3_init_seq.v rtl/soc/ddr3_phy_ecp5.v rtl/soc/ddr3_dqs_ecp5.v
     rtl/soc/ddr3_dq_serdes_ecp5.v rtl/soc/ddr3_dqs_write_ecp5.v rtl/soc/ddr3_dm_drv_ecp5.v rtl/soc/ddr3_read_calib.v
     rtl/soc/ddr3_write_seq.v rtl/soc/ddr3_read_seq.v rtl/soc/ddr3_read_burst_ext.v
     rtl/soc/ddr3_refresh_ctrl.v"
RTL=$(echo $RTL)   # one line: it is spliced into a yosys command

echo "=== yosys synth_ecp5 ==="
# shellcheck disable=SC2086
yosys -q -l "$BUILD/yosys.log" -p "read_verilog -sv -DSYNTHESIS $RTL; synth_ecp5 -top ecpix5_ddr3_probe -json $BUILD/probe.json" \
    || { grep -E "ERROR|Error" "$BUILD/yosys.log" | head; echo "ddr3_pnr_probe: synthesis FAILED"; exit 1; }
echo "  ok - $BUILD/probe.json"

cat fpga/constraints/ecpix5_ddr3.lpf fpga/constraints/ecpix5_ddr3_probe.lpf > "$BUILD/probe.lpf"

echo "=== nextpnr-ecp5 (LFE5UM5G-85F, CABGA554, seed $SEED) ==="
if ! nextpnr-ecp5 --um5g-85k --package CABGA554 --speed 8 --json "$BUILD/probe.json" \
        --lpf "$BUILD/probe.lpf" --textcfg "$BUILD/probe.config" --seed "$SEED" \
        > "$BUILD/nextpnr.log" 2>&1; then
    grep -E "^ERROR" "$BUILD/nextpnr.log" | head -10
    echo "ddr3_pnr_probe: place-and-route FAILED - see $BUILD/nextpnr.log"
    exit 1
fi
grep -E "Max frequency|Using pin .* as VREF" "$BUILD/nextpnr.log" | sed 's/^Info: /  /'
if grep -E "Max frequency" "$BUILD/nextpnr.log" | grep -q "FAIL at"; then
    echo "ddr3_pnr_probe: a clock missed its constraint - see $BUILD/nextpnr.log"
    exit 1
fi
# The probe is worthless if the primitives it exists to check were optimised away.
for cell in DQSBUFM DDRDLLA IDDRX2DQA ODDRX2DQA TSHX2DQA ODDRX2DQSB TSHX2DQSA ODDRX2F OSHX2A EHXPLLL; do
    grep -q "\"$cell\"" "$BUILD/probe.json" || { echo "ddr3_pnr_probe: $cell is not in the synthesized netlist"; exit 1; }
done
echo "ddr3_pnr_probe: the DDR3 PHY places and routes on the ECPIX-5's device with its real DDR3 pins"
