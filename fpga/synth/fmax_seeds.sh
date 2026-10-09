#!/usr/bin/env bash
# Fmax and area of the SoC over several placement seeds, on the bus or on the router fabric
# (Phase 8 Stage 3, Part 29; docs/roadmap/phase-08-noc.md and "Fmax is a distribution" in
# fpga/README.md for why one run is not a number).
#
#   fpga/synth/fmax_seeds.sh [bus|xbar|bypass]       (default bus)
#
#   bus      the shared bus every build has always used
#   xbar     INTERCONNECT=xbar: the router fabric
#   bypass   the router fabric with the slave interfaces' bypass (XBAR_NI_BYPASS=1)
#
# Synthesises once (fpga/synth/synth_ecp5.sh with SYNTH_ONLY), then runs nextpnr-ecp5 for every
# seed at the same time and prints each seed's routed Fmax and the area. The protocol is the one
# fpga/README.md's earlier tables use, so that a number here can sit beside them: BOARD=ulx3s85
# (the 85F with its real pins), the framebuffer shrunk to 8x8 (at full scale yosys does not
# finish; the README shows it does not move Fmax), seeds 0 to 5 (0 is nextpnr's default, the
# others are `--seed N`), and the OSS CAD Suite bundle's tools ahead of anything else on PATH.
# Compare numbers from the same bundle only (docs/practices.md section 20).
#
# Takes about 20 minutes for the bus: three or four of synthesis, then six place-and-routes side
# by side. The router fabric is a different matter: it is more than twice the bus's size (see
# Part 29), and its place-and-route has not been seen to finish in hours.
#
#   SEEDS="0 1 2"  fewer seeds        BUNDLE=/path/to/oss-cad-suite   another bundle
#   KEEP=1         keep the configs   FB=8                            framebuffer side
set -u
cd "$(dirname "$0")/../.."
variant=${1:-bus}
BUNDLE=${BUNDLE:-$HOME/tools/oss-cad-suite}
SEEDS=${SEEDS:-0 1 2 3 4 5}
FB=${FB:-8}
export PATH="$BUNDLE/bin:$PATH"

NOC="rtl/soc/wb_noc_xbar.v rtl/soc/noc_router.v rtl/soc/noc_err_sink.v rtl/soc/noc_ni_master.v rtl/soc/noc_ni_slave.v rtl/soc/noc_node1.v"
defs=""; extra=""
case $variant in
    bus)    ;;
    xbar)   defs="-DINTERCONNECT_XBAR";                       extra="$NOC" ;;
    bypass) defs="-DINTERCONNECT_XBAR -DXBAR_NI_BYPASS=1";    extra="$NOC" ;;
    *) echo "usage: $0 [bus|xbar|bypass]" >&2; exit 1 ;;
esac
for tool in yosys nextpnr-ecp5; do
    command -v $tool >/dev/null || { echo "error: $tool not found (BUNDLE=$BUNDLE)" >&2; exit 1; }
done
[ -f sim/bootrom_inorder.hex ] || { echo "error: sim/bootrom_inorder.hex missing - run 'make soc' first" >&2; exit 1; }

B=fpga/build/fmax_$variant
LOG=${FMAX_LOG:-/tmp/fmax_seeds_$variant}
rm -rf "$B" "$LOG"; mkdir -p "$LOG"
echo "== $variant: synthesis ($(yosys -V | cut -d' ' -f1-2), nextpnr $(nextpnr-ecp5 --version 2>&1 | sed -n 's/.*Version nextpnr-\([^)]*\)).*/\1/p'))"
BUILD=$B BOARD=ulx3s85 FB_WIDTH=$FB FB_HEIGHT=$FB SYNTH_ONLY=1 BOARD_DEFINES="$defs" EXTRA_RTL="$extra" \
    ./fpga/synth/synth_ecp5.sh > "$LOG/synth.log" 2>&1 || { echo "synthesis failed: see $LOG/synth.log"; exit 1; }

echo "== $variant: place and route, seeds: $SEEDS"
for s in $SEEDS; do
    ( arg="--seed $s"; [ "$s" = 0 ] && arg=""
      nextpnr-ecp5 --85k --package CABGA381 --json "$B/ulx3s_top.json" --lpf fpga/constraints/ulx3s.lpf $arg \
          --textcfg "$B/s$s.config" > "$LOG/s$s.log" 2>&1 ) &
done
wait
[ -n "${KEEP:-}" ] || rm -f "$B"/s*.config

python3 - "$LOG" $SEEDS <<'PYEOF'
import re, sys
log, seeds = sys.argv[1], sys.argv[2:]
vals, area = [], None
for s in seeds:
    t = open('%s/s%s.log' % (log, s), errors='replace').read()
    m = re.findall(r"Max frequency for clock '\$glbnet\$clk_25mhz\$TRELLIS_IO_IN': ([0-9.]+) MHz", t)
    v = float(m[-1]) if m else None
    vals.append(v)
    c = re.findall(r'TRELLIS_COMB:\s+(\d+)/\s*(\d+)\s+(\d+)%', t)
    if c: area = c[-1]
    print("  seed %s: %s" % (s, '%.2f MHz' % v if v is not None else 'no result (did place-and-route finish?)'))
ok = [v for v in vals if v is not None]
if ok:
    print("  mean %.2f MHz over %d seeds (min %.2f, max %.2f)" % (sum(ok) / len(ok), len(ok), min(ok), max(ok)))
if area:
    print("  TRELLIS_COMB %s of %s (%s%%)" % area)
PYEOF
