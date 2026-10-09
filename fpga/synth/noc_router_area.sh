#!/bin/sh
# What one router costs in an ECP5, in the two shapes the SoC's fabric uses (Phase 8 Stage 3,
# Part 29, docs/roadmap/phase-08-noc.md): the request router takes every master (five, with one
# hart) to every slave and the error sink (fourteen), the response router the other way.
#
# `synth_ecp5` on rtl/soc/noc_router.v alone, standing on its own, so the figures are the module's
# and not the SoC's: 4-input LUTs, the carry cells, the distributed-RAM cells, and the flip-flops.
#
#   sh fpga/synth/noc_router_area.sh
set -u
cd "$(dirname "$0")/../.."
BUNDLE=${BUNDLE:-$HOME/tools/oss-cad-suite}
export PATH="$BUNDLE/bin:$PATH"
LOG=${NOC_ROUTER_LOG:-/tmp/noc_router_area}
mkdir -p "$LOG"
SRC=${ROUTER_SRC:-rtl/soc/noc_router.v}

printf '%-30s %8s %7s %6s %7s %8s\n' "router (inputs x outputs)" LUT4 PFUMX CCU2C FF DPR16X4
for shape in "5 14" "14 5"; do
    set -- $shape
    log="$LOG/router_$1x$2.log"
    yosys -q -l "$log" -p "read_verilog -sv $SRC; chparam -set NUM_IN $1 -set NUM_OUT $2 -set DEPTH 2 noc_router;
        synth_ecp5 -top noc_router; stat" >/dev/null 2>&1 || { echo "yosys failed: see $log"; exit 1; }
    n() { grep -a -E "^ +[0-9]+ +$1\$" "$log" | tail -n 1 | awk '{print $1}'; }
    printf '%-30s %8s %7s %6s %7s %8s\n' "$1 x $2" "$(n LUT4)" "$(n PFUMX)" "$(n CCU2C)" "$(n TRELLIS_FF)" "$(n TRELLIS_DPR16X4)"
done
