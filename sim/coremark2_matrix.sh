#!/usr/bin/env bash
# CoreMark on both harts at once, over every interconnect, with the harts' images in one memory or
# two (Phase 8 Stage 3). Prints one table of what the programs measure of themselves: each hart's
# CoreMark iteration in cycles, and the wall-clock total. See sim/tb_soc_2hart_coremark_mem.v.
#
# `make` does not know that a different INTERCONNECT or define needs a different build, so the
# built simulations are cleared before each run. Six Icarus simulations, each a few minutes to
# half an hour.
set -u
cd "$(dirname "$0")/.."
LOG=${COREMARK2_LOG:-/tmp/coremark2_matrix}
mkdir -p "$LOG"

layouts=(same split)
configs=(bus xbar xbar_qos xbar_noguard)

run() {  # layout config
    local l=$1 c=$2 args=()
    case $c in
        bus)      args=() ;;
        xbar)     args=(INTERCONNECT=xbar) ;;
        xbar_qos) args=(INTERCONNECT=xbar COREMARK2_DEFS=-DXBAR_QOS) ;;
        # a measurement only: the caches' late-ack guard off, which is WRONG under sharing
        xbar_noguard) args=(INTERCONNECT=xbar COREMARK2_DEFS=-DXBAR_NO_LATE_GUARD) ;;
    esac
    rm -f sim/*.out
    # (${args[@]+...} because an empty array is an unbound variable under `set -u` in the bash 3.2 macOS ships)
    make "sim_soc_2hart_coremark_$l" ${args[@]+"${args[@]}"} > "$LOG/$l.$c.log" 2>&1
    local rc=$?
    local f=sim/soc_2hart_coremark_$l.log
    local h0 h1 tot
    h0=$(grep -a "hart 0 (.*one CoreMark iteration" "$f" | grep -o '[0-9]* cycles' | grep -o '[0-9]*')
    h1=$(grep -a "hart 1 (.*one CoreMark iteration" "$f" | grep -o '[0-9]* cycles' | grep -o '[0-9]*')
    tot=$(grep -a "total cycles (pair wall-clock" "$f" | grep -o ': [0-9]*$' | grep -o '[0-9]*')
    if [ $rc -ne 0 ] || ! grep -aq "SOC-2HART-COREMARK: PASS" "$f"; then
        printf '%-6s %-12s %12s %12s %12s   FAILED (see %s)\n' "$l" "$c" "${h0:--}" "${h1:--}" "${tot:--}" "$LOG/$l.$c.log"
    else
        printf '%-6s %-12s %12s %12s %12s\n' "$l" "$c" "$h0" "$h1" "$tot"
    fi
}

printf '%-6s %-12s %12s %12s %12s\n' memory fabric hart0_iter hart1_iter total_cycles
for l in "${layouts[@]}"; do
    for c in "${configs[@]}"; do run "$l" "$c"; done
done
rm -f sim/*.out
