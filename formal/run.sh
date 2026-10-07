#!/usr/bin/env bash
# Bounded model checking with yosys + yosys-smtbmc + z3.
#
#   formal/run.sh            check every property module
#   formal/run.sh plic       check only the ones matching a pattern
#
# SymbiYosys (sby) is the usual driver for this and is not packaged for
# Homebrew, so the two steps it would wrap are done directly: yosys turns the
# design plus its properties into an SMT2 transition system, and
# yosys-smtbmc unrolls that system and asks z3 whether any assertion can be
# violated within the bound.
#
# What this does and does not establish: BMC proves the properties hold for
# every input sequence up to DEPTH cycles from reset. It is a proof over all
# *inputs*, which is what simulation cannot do - but it is not a proof over
# all *time*. A bug that needs more than DEPTH cycles to reach is out of
# scope, and unbounded proof would need k-induction. For combinational
# routing (the interconnect) the distinction does not arise; for the PLIC and
# BTB it genuinely does, and the honest claim is the bounded one.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUILD="$HERE/build"
DEPTH="${DEPTH:-12}"
SOLVER="${SOLVER:-z3}"
FILTER="${1:-}"

mkdir -p "$BUILD"

# Per-target solver and depth. Most targets are small and z3 is what this flow
# (and CI's tool bundle) is checked for. The DDR3 controller is not small enough for
# it: at depth 40 z3 took 199 s and boolector 2.3 s (measured), and the properties
# only mean something once a refresh has come due, which is about 195 cycles after
# reset at the design's real refresh interval - so it needs depth ~250, which z3
# cannot reach in any reasonable time and boolector does in about a minute and a half.
DDR3_SOLVER="${DDR3_SOLVER:-boolector}"
DDR3_DEPTH="${DDR3_DEPTH:-250}"
solver_for() { case "$1" in ddr3_ecp5_top) echo "$DDR3_SOLVER" ;; fv_pmp_equiv|fv_noc_router|fv_noc_router_qos) echo boolector ;; *) echo "$SOLVER" ;; esac; }
depth_for()  { case "$1" in ddr3_ecp5_top) echo "$DDR3_DEPTH"  ;; fv_pmp_equiv) echo 2 ;; *) echo "$DEPTH"  ;; esac; }

# What to check: "<top module> <verilog files>".
#
# Two shapes appear here, for a reason rather than by accident. Where the
# properties only need the module's ports, they live in a formal/fv_*.v
# wrapper that instantiates it, keeping the RTL clean. Where they need the
# module's internal *arrays* - the PLIC's per-source state, the BTB's table -
# they live inside the module under `ifdef FORMAL`, because yosys cannot
# follow a hierarchical reference into a submodule's array with a variable
# index, and a wrapper therefore cannot express them at all.
TARGETS=(
    "plic            $ROOT/rtl/plic.v"
    "btb             $ROOT/rtl/btb.v"
    "fv_regfile      $ROOT/rtl/regfile.v $HERE/fv_regfile.v"
    "fv_interconnect $ROOT/rtl/soc/wb_interconnect.v $HERE/fv_interconnect.v"
    "fv_noc_node     $ROOT/rtl/soc/noc_node1.v $HERE/fv_noc_node.v"
    "fv_noc_router   $ROOT/rtl/soc/noc_router.v $HERE/fv_noc_router.v"
    "fv_noc_router_qos $ROOT/rtl/soc/noc_router.v $HERE/fv_noc_router_qos.v"
    "fv_noc_ni_slave $ROOT/rtl/soc/noc_ni_slave.v $HERE/fv_noc_ni_slave.v"
    "fv_noc_ni_master $ROOT/rtl/soc/noc_ni_master.v $HERE/fv_noc_ni_master.v"
    "fv_regfile_wide $ROOT/rtl/ooo/regfile_wide.v $HERE/fv_regfile_wide.v"
    "fv_pmp          $ROOT/rtl/pmp.v $HERE/fv_pmp.v"
    "fv_pmp_equiv    $ROOT/rtl/pmp.v $HERE/pmp_ref.v $HERE/fv_pmp_equiv.v"
    "ddr3_ecp5_top   $ROOT/rtl/soc/ddr3_ecp5_top.v $ROOT/rtl/soc/ddr3_write_seq.v $ROOT/rtl/soc/ddr3_read_seq.v $ROOT/rtl/soc/ddr3_read_burst_ext.v $ROOT/rtl/soc/ddr3_refresh_ctrl.v $HERE/ddr3_stubs.v"
)

# Returns 0 if the solver proved the properties, 1 if it found a
# counterexample, 2 if the flow itself broke.
check() {
    local top="$1"; shift
    local files="$*"
    local smt log
    smt="$BUILD/$top.smt2"
    log="$BUILD/$top.log"

    # -sv is required: `assert` inside always is SystemVerilog, and without
    # it yosys parses the file, drops the assertions, and proves nothing.
    # async2sync + dffunmap + chformal -lower turn the resulting $check cells
    # into the plain $assert and $dff cells write_smt2 knows how to emit;
    # without them yosys either drops the assertions or refuses the
    # synchronous-reset flops.
    if ! yosys -q -p "
        read_verilog -sv -formal -DFORMAL $files;
        prep -top $top -flatten;
        async2sync;
        dffunmap;
        chformal -lower;
        write_smt2 -wires $smt" > "$log" 2>&1; then
        echo "    yosys failed - see $log"
        return 2
    fi

    if ! grep -q '\$assert' "$smt" && ! grep -q 'assert' "$smt"; then
        echo "    no assertions reached the solver - see $log"
        return 2
    fi

    local solver depth
    solver="$(solver_for "$top")"; depth="$(depth_for "$top")"
    if ! command -v "$solver" >/dev/null 2>&1; then
        echo "    solver '$solver' not found - $top needs it (see the comment on solver_for)"
        return 2
    fi

    yosys-smtbmc -s "$solver" -t "$depth" "$smt" >> "$log" 2>&1
    if grep -q "Status: FAILED" "$log"; then return 1; fi
    if ! grep -q "Status: PASSED" "$log"; then
        echo "    solver produced no verdict - see $log"
        return 2
    fi

    # A property that is true only because its premise can never happen looks
    # exactly like a proof. Any `cover` statement in the design must therefore be
    # reachable within the same bound; an unreached one fails the target.
    # (Designs with no cover statements print nothing and are unaffected.)
    yosys-smtbmc -c -s "$solver" -t "$depth" "$smt" > "$BUILD/$top.cover.log" 2>&1
    COVERED=$(grep -c "Reached cover statement" "$BUILD/$top.cover.log")
    if grep -q "Unreached cover statement" "$BUILD/$top.cover.log"; then
        echo "    proved, but $(grep -c 'Unreached cover statement' "$BUILD/$top.cover.log") cover statement(s) unreached: the proof may be vacuous"
        grep "Unreached cover statement" "$BUILD/$top.cover.log" | sed 's/^/      /'
        return 3
    fi
    return 0
}

# ---- flow self-test: a property that must fail ----
echo "flow self-test (a deliberately false property, expected to FAIL):"
if ! yosys -q -p "
    read_verilog -sv -formal $HERE/fv_selftest.v;
    prep -top fv_selftest -flatten;
    async2sync;
    chformal -lower;
    write_smt2 -wires $BUILD/fv_selftest.smt2" > "$BUILD/fv_selftest.log" 2>&1; then
    echo "  ABORT: yosys could not build the self-test"
    exit 2
fi
yosys-smtbmc -s "$SOLVER" -t 4 "$BUILD/fv_selftest.smt2" \
    >> "$BUILD/fv_selftest.log" 2>&1
if grep -q "Status: FAILED" "$BUILD/fv_selftest.log"; then
    echo "  ok - the flow can detect a violated property"
else
    echo "  ABORT: the self-test did NOT fail, so nothing below would mean"
    echo "  anything. The assertions are not reaching the solver."
    echo "  See $BUILD/fv_selftest.log"
    exit 2
fi
echo

echo "bounded model checking to depth $DEPTH with $SOLVER (per-target overrides shown on each line):"
pass=0; fail=0; err=0; failed=""
for entry in "${TARGETS[@]}"; do
    # shellcheck disable=SC2086
    set -- $entry
    top="$1"
    if [ -n "$FILTER" ] && [[ "$top" != *"$FILTER"* ]]; then continue; fi

    COVERED=0
    check "$@"
    case $? in
        0) if [ "$COVERED" -gt 0 ]; then
               printf '  %-20s PROVED (depth %s, %s, %s cover statements reached)\n' \
                      "$top" "$(depth_for "$top")" "$(solver_for "$top")" "$COVERED"
           else
               printf '  %-20s PROVED (depth %s)\n' "$top" "$(depth_for "$top")"
           fi
           pass=$((pass+1)) ;;
        1) printf '  %-20s COUNTEREXAMPLE FOUND - see %s/%s.log\n' \
                  "$top" "$BUILD" "$top"; fail=$((fail+1)); failed="$failed $top" ;;
        3) printf '  %-20s VACUOUS - see %s/%s.cover.log\n' \
                  "$top" "$BUILD" "$top"; err=$((err+1)) ;;
        *) printf '  %-20s ERROR\n' "$top"; err=$((err+1)) ;;
    esac
done

echo
echo "==================================================="
echo "formal: $pass proved, $fail refuted, $err errored (bound = $DEPTH cycles; ddr3_ecp5_top: $DDR3_DEPTH)"
[ -n "$failed" ] && echo "refuted:$failed"
echo "==================================================="
[ "$fail" -eq 0 ] && [ "$err" -eq 0 ]
