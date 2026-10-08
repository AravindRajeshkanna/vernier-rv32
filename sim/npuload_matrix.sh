#!/usr/bin/env bash
# The NPU DMA racing the CPU, over every interconnect (Phase 8 Stage 3).
#
# Runs software/soc/npuload.c in four forms - the original, with the NPU's buffer in SDRAM, with
# the CPU loop sweeping 8 KB so it misses its data cache, and both - over the shared bus, the
# router fabric, the router fabric with its traffic classes on, and the router fabric with the
# slave interfaces' bypass, and prints one table of
# what the program measures itself: the CPU loop alone, the NPU job alone, the CPU loop while
# the NPU runs, and the time until both have finished.
#
# `make` does not know that a different INTERCONNECT or define needs a different build, so the
# built simulations are cleared before each run. Takes a while: sixteen Icarus simulations.
set -u
cd "$(dirname "$0")/.."
LOG=${NPULOAD_LOG:-/tmp/npuload_matrix}
mkdir -p "$LOG"

variants=(plain split heavy heavysplit)
# (NPULOAD_CONFIGS picks a subset, e.g. "xbar xbar_bypass")
configs=(${NPULOAD_CONFIGS:-bus xbar xbar_qos xbar_bypass})

target_of() { [ "$1" = plain ] && echo sim_npuload || echo "sim_npuload_$1"; }
log_of()    { [ "$1" = plain ] && echo sim/npuload.log || echo "sim/npuload_$1.log"; }

run() {  # variant config
    local v=$1 c=$2 t args=()
    t=$(target_of "$v")
    case $c in
        bus)      args=(NPULOAD_MON=) ;;
        xbar)     args=(INTERCONNECT=xbar NPULOAD_MON=) ;;
        xbar_qos) args=(INTERCONNECT=xbar NPULOAD_MON= NPULOAD_DEFS=-DXBAR_QOS) ;;
        # the slave interfaces' bypass on (rtl/soc/noc_ni_slave.v): two cycles less on every access
        xbar_bypass) args=(INTERCONNECT=xbar XBAR_NI_BYPASS=1 NPULOAD_MON=) ;;
    esac
    rm -f sim/*.out
    make "$t" "${args[@]}" > "$LOG/$v.$c.log" 2>&1
    local rc=$?
    local f; f=$(log_of "$v")
    local a n b t2
    a=$(grep -a "CPU loop alone" "$f" | grep -o '[0-9]* cycles' | grep -o '[0-9]*')
    n=$(grep -a "NPU DMA job alone" "$f" | grep -o '[0-9]* cycles' | grep -o '[0-9]*')
    b=$(grep -a "CPU loop, NPU running" "$f" | grep -o '[0-9]* cycles' | grep -o '[0-9]*')
    t2=$(grep -a "both finished after" "$f" | grep -o '[0-9]* cycles' | grep -o '[0-9]*')
    if [ $rc -ne 0 ] || ! grep -aq "NPU-LOAD: PASS" "$f"; then
        printf '%-11s %-9s  FAILED (see %s)\n' "$v" "$c" "$LOG/$v.$c.log"
    else
        printf '%-11s %-9s %10s %10s %10s %10s   %6s\n' "$v" "$c" "$a" "$n" "$b" "$t2" \
            "$(python3 -c "print('%+.1f%%' % (100.0*($b-$a)/$a))")"
    fi
}

printf '%-11s %-9s %10s %10s %10s %10s   %6s\n' variant fabric cpu_alone npu_alone cpu_racing both_done cpu_slow
for v in "${variants[@]}"; do
    for c in "${configs[@]}"; do run "$v" "$c"; done
done
rm -f sim/*.out
