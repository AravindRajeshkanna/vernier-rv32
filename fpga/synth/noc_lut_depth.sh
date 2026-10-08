#!/bin/sh
# A structural estimate of what the slave interfaces' bypass costs (Phase 8 Stage 3, Part 28,
# docs/roadmap/phase-08-noc.md): how many 4-input LUTs, and how many LUT levels deep the
# longest purely combinational path, for rtl/soc/noc_ni_slave.v alone and for the whole
# two-hart router fabric, with the bypass off and on.
#
# What this is: yosys maps the logic to 4-input LUTs with its own `abc` and `ltp` walks the
# longest path between registers, ports counting as its ends. What it is not: a timing figure.
# There is no place-and-route, no wire delay, no carry chains or block RAM, and the fabric is
# synthesised on its own, so its ports are path ends where in the SoC the paths continue into
# the cores and the slaves. It says how the logic changes, not whether a board's clock holds.
#
# (`ltp -noff` is only right on flip-flops yosys still knows as its own cells, which is why
# this stops short of `synth_ecp5`, whose TRELLIS_FF cells it would walk through.)
#
#   sh fpga/synth/noc_lut_depth.sh
set -u
cd "$(dirname "$0")/../.."
LOG=${NOC_LUT_LOG:-/tmp/noc_lut_depth}
mkdir -p "$LOG"

ALL="rtl/soc/wb_noc_xbar.v rtl/soc/noc_router.v rtl/soc/noc_err_sink.v rtl/soc/noc_ni_master.v rtl/soc/noc_ni_slave.v rtl/soc/noc_node1.v"

run() {  # label, top, parameter name, files, extra chparams
    label=$1; top=$2; param=$3; files=$4; extra=$5
    for b in 0 1; do
        log="$LOG/$label.$b.log"
        yosys -q -l "$log" -p "read_verilog -sv $files; chparam $extra -set $param $b $top;
            hierarchy -top $top; proc; flatten; opt; memory -nomap; memory_map; opt; techmap; opt;
            abc -lut 4; opt_clean; ltp -noff; stat" >/dev/null 2>&1 || { echo "yosys failed: see $log"; exit 1; }
        depth=$(grep -a 'Longest topological path' "$log" | tail -n 1 | sed 's/.*length=\([0-9]*\).*/\1/')
        luts=$(grep -a '\$lut$' "$log" | tail -n 1 | awk '{print $1}')
        printf '%-34s bypass %s  %7s LUT4s  %3s levels\n' "$label" "$b" "$luts" "$depth"
    done
}

run "noc_ni_slave (one interface)" noc_ni_slave BYPASS rtl/soc/noc_ni_slave.v ""
run "wb_noc_xbar (2 harts, 7 slaves)" wb_noc_xbar NI_BYPASS "$ALL" "-set NUM_HARTS 2 -set BURST_SLAVES 2"
