#!/bin/sh
# Synthesis and place-and-route of the DDR3 PHY on the ECPIX-5's device, with the board's
# real DDR3 pins - a probe of whether the PHY's structure is legal on an ECP5, not a
# bring-up build. Docs/roadmap/phase-09-ddr.md, Parts 21-25 (25 gives lane 1 its own real DQSBUFM,
# sharing the one DDRDLLA lane 0 already had - Part 23's own tie-off is gone), plus a later
# survey, no RTL change, that probes this same flow with deliberate cross-lane mutations
# to find out precisely what it does and does not catch.
#
# What passing shows: yosys maps every DDR primitive, and nextpnr packs, places and routes
# them against the real LFE5UM5G-85F/CABGA554 pin data - including checks no simulation
# can make: every IDDRX2DQA takes its pointers from its own byte lane's DQSBUFM (enforced
# by real DQS-group locality - confirmed genuinely cross-lane-testable with a real second
# lane, not just assumed from a single lane as Part 21 first found it), a DQSBUFM's own
# DQSI input is a genuinely unique top-level net (a net two DQSBUFM instances share is
# refused), a
# DQ/DQS tri-state control reaches its pad directly (which also catches it being inverted on
# the way), the DQS pad is a DQS site, DM lands on its own real pin at the right I/O
# standard, edge clocks reach the banks they serve, and no bank mixes 1.5 V and 3.3 V
# pads. Each was shown able to fail by mutation.
#
# What it does NOT show, and was shown not to: that a DQ pin sits in its DQS group - moving
# one to an address pin passed (Part 21) - or that a tri-state control is used at all (tying
# it to a constant passed, Part 21). READCLKSEL[2:0] carries no physical locality
# constraint either: cross-wiring lane 1's own DQSBUFM to lane 0's own calibrated
# READCLKSEL places and routes without complaint - simulation cannot show this either
# (docs/roadmap/phase-09-ddr.md, Part 24), so a READCLKSEL cross-wire between lanes is a real,
# currently open gap neither layer of proof this project has closes. It also says nothing
# about behaviour, or about timing at the DDR clock, or about the four ports that have no
# pin on this board (fpga/constraints/ecpix5_ddr3_probe.lpf parks them on throwaway pins).
# The pin list is only as good as the two sources it was taken from.
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
     rtl/soc/ddr3_init_seq.v rtl/soc/ddr3_phy_ecp5.v rtl/soc/ddr3_dqs_ecp5.v rtl/soc/ddr3_ddrdlla_ecp5.v
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
# The probe is worthless if the primitives it exists to check were optimised away - and a
# plain `grep -q "\"$cell\""` on the JSON does NOT show that: `write_json` always dumps
# every ECP5 cell's own blackbox definition alongside the design, so the string for a
# primitive nothing instantiates (checked directly: "OSCG", used nowhere in this design,
# matches once) is present regardless. Found while adding the count below for Part 25 -
# this check had been vacuous since Part 21. Counting real instances in the design's own
# module entry is what actually proves it: exact counts for DQSBUFM/DDRDLLA double as the
# one real check that lane 1 shares lane 0's own DLL rather than getting a second one
# (Part 24's own refactor) - simulation cannot show this, since nothing there reads a real
# delay code either way.
python3 - "$BUILD/probe.json" <<'PYEOF'
import json, sys, collections
d = json.load(open(sys.argv[1]))
mod = d["modules"]["ecpix5_ddr3_probe"]
counts = collections.Counter(c["type"] for c in mod["cells"].values())
checks = [
    ("DQSBUFM",    2, "=="),   # one per byte lane
    ("DDRDLLA",    1, "=="),   # shared, not one per lane (Part 24)
    ("IDDRX2DQA",  1, ">="),
    ("ODDRX2DQA",  1, ">="),
    ("TSHX2DQA",   1, ">="),
    ("ODDRX2DQSB", 1, ">="),
    ("TSHX2DQSA",  1, ">="),
    ("ODDRX2F",    1, ">="),
    ("OSHX2A",     1, ">="),
    ("EHXPLLL",    1, ">="),
]
failed = False
for cell, want, op in checks:
    got = counts.get(cell, 0)
    ok = (got == want) if op == "==" else (got >= want)
    if not ok:
        print(f"ddr3_pnr_probe: {cell}: {got} instances in the synthesized netlist, expected {op} {want}")
        failed = True
if failed:
    sys.exit(1)
PYEOF
echo "ddr3_pnr_probe: the DDR3 PHY places and routes on the ECPIX-5's device with its real DDR3 pins"
