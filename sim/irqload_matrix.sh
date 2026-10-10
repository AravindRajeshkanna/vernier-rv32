#!/usr/bin/env bash
# Interrupt traffic over every interconnect (Phase 8 Stage 3, Part 31).
#
# Runs software/soc/irqload.c in its forms - the NPU's buffer in block RAM or SDRAM, the CPU loop in
# the data cache or sweeping 8 KB, and a slower interrupt rate - over the shared bus, the router
# fabric, the router fabric with its traffic classes on, and the router fabric with the slave
# interfaces' bypass. For each it prints what the program measured about itself: what the periodic
# interrupts added to the CPU loop (per interrupt), how long the handler took to reach the timer
# (lat) and to finish (dn), alone and with the NPU's DMA job racing.
#
#   bash sim/irqload_matrix.sh                          every form over every interconnect, in turn
#   IRQLOAD_JOBS=4 bash sim/irqload_matrix.sh           the interconnects at the same time, each in
#                                                       a copy of the tree under $IRQLOAD_WORK
#   IRQLOAD_CONFIGS="bus xbar" IRQLOAD_VARIANTS="plain" bash sim/irqload_matrix.sh   a subset
#   IRQLOAD_CORE=ooo bash sim/irqload_matrix.sh         the wide core (default: the in-order one)
#
# Every run is built with -DREQ_COUNT (sim/tb_ramboot.v), which counts the accesses each master
# completes in each timed interval, so the table can say how many an interrupt makes (dacc/i for the
# data side, facc/i for instruction fetches) and how much the interrupts slow the NPU (npu_slow).
#
# `make` does not know that a different INTERCONNECT or define needs a different build, so the
# built simulations are cleared before each run. One Icarus simulation each, two to ten minutes.
set -u
cd "$(dirname "$0")/.."
LOG=${IRQLOAD_LOG:-/tmp/irqload_matrix}
mkdir -p "$LOG"

variants=(${IRQLOAD_VARIANTS:-plain split heavy heavysplit slow})
configs=(${IRQLOAD_CONFIGS:-bus xbar xbar_qos xbar_bypass})

target_of() { [ "$1" = plain ] && echo sim_irqload || echo "sim_irqload_$1"; }
log_of()    { [ "$1" = plain ] && echo sim/irqload.log || echo "sim/irqload_$1.log"; }

run() {  # variant config
    local v=$1 c=$2 t args=() defs="-DREQ_COUNT"
    t=$(target_of "$v")
    case $c in
        bus)         ;;
        xbar)        args=(INTERCONNECT=xbar) ;;
        xbar_qos)    args=(INTERCONNECT=xbar); defs="$defs -DXBAR_QOS" ;;
        xbar_bypass) args=(INTERCONNECT=xbar XBAR_NI_BYPASS=1) ;;
    esac
    [ -n "${IRQLOAD_CORE:-}" ] && args+=("CORE=$IRQLOAD_CORE")
    find sim -maxdepth 1 -name '*.out' -delete
    make "$t" "IRQLOAD_DEFS=$defs" ${args[@]+"${args[@]}"} > "$LOG/$v.$c.log" 2>&1
    local rc=$?
    local f; f=$(log_of "$v")
    if [ $rc -ne 0 ] || ! grep -aq "IRQ-LOAD: PASS" "$f"; then
        printf '%s %s FAILED (see %s)\n' "$v" "$c" "$LOG/$v.$c.log"
        grep -a "^IRQ phase=.*FAILED" "$f" | sed "s/^/$v $c /"
    else
        grep -a "^IRQ phase=\|^IRQ baselines\|^\[req\]" "$f" | sed "s/^/$v $c /"
    fi
}

if [ -n "${IRQLOAD_WORKER:-}" ]; then      # one interconnect, in this tree
    for v in "${variants[@]}"; do run "$v" "$IRQLOAD_WORKER"; done > "$LOG/raw.$IRQLOAD_WORKER.txt"
    find sim -maxdepth 1 -name '*.out' -delete
    exit 0
fi

rm -f "$LOG"/raw.*.txt
if [ "${IRQLOAD_JOBS:-1}" -le 1 ]; then
    for c in "${configs[@]}"; do IRQLOAD_WORKER=$c bash sim/irqload_matrix.sh; done
else
    WORK=${IRQLOAD_WORK:-/tmp/irqload_work}
    for c in "${configs[@]}"; do
        mkdir -p "$WORK/$c"
        rsync -a --delete --exclude=.git --exclude=fpga/build --exclude=sim/vl_ddr3 --exclude='obj_dir_*' \
            --exclude='sim/linuximage_*' ./ "$WORK/$c/"
        ( cd "$WORK/$c" && IRQLOAD_WORKER=$c bash sim/irqload_matrix.sh ) &
    done
    wait
fi

python3 - "$LOG" "${configs[@]}" <<'PYEOF'
import re, sys
log, configs = sys.argv[1], sys.argv[2:]
rows, fails, req = [], [], {}
for c in configs:
    try:
        lines = open('%s/raw.%s.txt' % (log, c)).read().splitlines()
    except IOError:
        fails.append('%s: no results' % c)
        continue
    for line in lines:
        p = line.split()
        if len(p) < 3:
            continue
        if 'FAILED' in p:
            fails.append(line)
            continue
        if p[2] == '[req]':          # [req] phase N: fetch F data D walker W npu P
            m = re.match(r'\S+ \S+ \[req\] phase (\d+): fetch (\d+) data (\d+) walker (\d+) npu (\d+)', line)
            req[(p[0], p[1], int(m.group(1)))] = [int(m.group(k)) for k in (2, 3, 4, 5)]
            continue
        kv = dict(x.split('=', 1) for x in p if '=' in x)
        if p[2] == 'IRQ' and 'phase' in kv:
            rows.append((p[0], p[1], kv))
hdr = '%-10s %-12s %-7s %8s %8s %4s %7s %6s %5s %5s %5s %6s %6s %6s %6s %7s %7s %8s'
print(hdr % ('variant', 'fabric', 'phase', 'base', 'with_irq', 'n', 'tax/irq', 'lat_mn', 'p50', 'p90', 'max',
             'dn_mn', 'dn_p50', 'dn_p90', 'dn_max', 'dacc/i', 'facc/i', 'npu_slow'))
for v, c, kv in rows:
    i = lambda k: int(kv[k])
    n, m = i('n'), i('samples')
    racing = kv['phase'] == 'racing'
    b, r = (3, 4) if racing else (1, 2)       # the testbench's phase numbers: baseline, interrupted
    dacc = facc = nslow = '-'
    if (v, c, b) in req and (v, c, r) in req:
        fb, db, _, nb = req[(v, c, b)]
        fr, dr, _, nr = req[(v, c, r)]
        dacc, facc = '%.1f' % ((dr - db) / float(n)), '%.1f' % ((fr - fb) / float(n))
        if racing and nb:
            nslow = '%.1f%%' % (100.0 * (1 - (nr / float(i('cycles'))) / (nb / float(i('base')))))
    print(hdr % (v, c, kv['phase'], i('base'), i('cycles'), n, '%.1f' % ((i('cycles') - i('base')) / float(n)),
                 '%.1f' % (i('lat_sum') / float(m)), i('lat_p50'), i('lat_p90'), i('lat_max'),
                 '%.1f' % (i('done_sum') / float(m)), i('done_p50'), i('done_p90'), i('done_max'),
                 dacc, facc, nslow))
for f in fails:
    print('FAILED:', f)
PYEOF
find sim -maxdepth 1 -name '*.out' -delete
