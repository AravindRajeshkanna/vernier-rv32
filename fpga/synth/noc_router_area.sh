#!/bin/sh
# What one router costs in an ECP5, in the two shapes the SoC's fabric uses (Phase 8 Stage 3,
# Parts 29 and 30, docs/roadmap/phase-08-noc.md): the request router takes every master (five, with
# one hart) to every slave and the error sink (fourteen), the response router the other way.
#
# `synth_ecp5` on rtl/soc/noc_router.v alone, standing on its own, so the figures are the module's
# and not the SoC's: 4-input LUTs, the carry cells, the distributed-RAM cells, and the flip-flops.
#
#   sh fpga/synth/noc_router_area.sh            print the table
#   sh fpga/synth/noc_router_area.sh --check    ...and fail if a router is over its budget
#
# The budget exists because the area of a router is easy to lose without noticing and hard to get
# back: Part 29 found the response router at 65,805 LUT4s, because its FIFOs were one array every
# input could reach, in a design whose every test passed. The limits are several times the figures
# the router has now, and several times under what that mistake costs, so they hold across yosys
# versions (LUT counts move by a few per cent between them) and still catch the mistake.
#   LIMIT_REQ (default 10000)   the request router, 5 inputs by 14 outputs
#   LIMIT_RSP (default 12000)   the response router, 14 inputs by 5 outputs
set -u
cd "$(dirname "$0")/../.."
BUNDLE=${BUNDLE:-$HOME/tools/oss-cad-suite}
export PATH="$BUNDLE/bin:$PATH"
LOG=${NOC_ROUTER_LOG:-/tmp/noc_router_area}
mkdir -p "$LOG"
SRC=${ROUTER_SRC:-rtl/soc/noc_router.v}
check=0; [ "${1:-}" = "--check" ] && check=1
LIMIT_REQ=${LIMIT_REQ:-10000}
LIMIT_RSP=${LIMIT_RSP:-12000}

printf '%-30s %8s %7s %6s %7s %8s\n' "router (inputs x outputs)" LUT4 PFUMX CCU2C FF DPR16X4
fail=0
for shape in "5 14" "14 5"; do
    set -- $shape
    log="$LOG/router_$1x$2.log"
    yosys -q -l "$log" -p "read_verilog -sv $SRC; chparam -set NUM_IN $1 -set NUM_OUT $2 -set DEPTH 2 noc_router;
        synth_ecp5 -top noc_router; stat" >/dev/null 2>&1 || { echo "yosys failed: see $log"; exit 1; }
    n() { grep -a -E "^ +[0-9]+ +$1\$" "$log" | tail -n 1 | awk '{print $1}'; }
    lut=$(n LUT4)
    printf '%-30s %8s %7s %6s %7s %8s\n' "$1 x $2" "$lut" "$(n PFUMX)" "$(n CCU2C)" "$(n TRELLIS_FF)" "$(n TRELLIS_DPR16X4)"
    if [ "$check" = 1 ]; then
        limit=$LIMIT_REQ; [ "$1" = 14 ] && limit=$LIMIT_RSP
        if [ -z "$lut" ] || [ "$lut" -gt "$limit" ]; then
            echo "  FAIL: the $1 x $2 router is ${lut:-unknown} LUT4s, over its budget of $limit"
            fail=1
        fi
    fi
done
[ "$check" = 1 ] && { [ "$fail" = 0 ] && echo "NOC ROUTER AREA OK" || echo "NOC ROUTER AREA FAILED"; }
exit $fail
