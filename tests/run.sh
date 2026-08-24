#!/usr/bin/env bash
# Run every built riscv-tests image on the RTL and print a per-suite summary.
#
# Usage:
#   tests/run.sh              run everything in tests/build
#   tests/run.sh rv32um       run only tests whose name matches a pattern
#
# Exits non-zero if anything fails or times out, so this is usable as a gate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"
SIM="$ROOT/sim/sim_isa.out"
FILTER="${1:-}"

[ -f "$SIM" ] || { echo "$SIM missing - run 'make isa' first" >&2; exit 1; }
[ -f "$OUT/manifest.txt" ] || { echo "no manifest - run tests/build.sh" >&2; exit 1; }

pass=0; fail=0; skip=0; xfail=0; xpass=0
failed_names=""
xpass_names=""
results="$OUT/results.txt"
: > "$results"

# Tests documented as expected to fail, and why. An entry here suppresses the
# failure - but an entry that starts *passing* is reported as XPASS and fails
# the run, so the list cannot silently outlive the limitation it describes.
is_expected_failure() {
    grep -v '^#' "$HERE/expected-failures.txt" 2>/dev/null \
        | awk -v n="$1" '$1==n{found=1} END{exit !found}'
}

# ---- the dual-issue floor -----------------------------------------------
#
# A verdict says the program reached its pass condition. It cannot say which
# half of the machine got it there, and on the wide core that turned out to
# matter: co-simulation reported 82 of 82 traces matching while the second
# issue slot retired 63 instructions out of 28,262. See
# tests/dual-issue-floor.txt and docs/practices.md section 40.
#
# This check is duplicated from tests/cosim.py deliberately, and the number
# is not: both read the same file. cosim.py is a *local* gate - it needs
# Spike, which .github/workflows/ci.yml explains is too expensive to build
# per run - while this script is what CI's `riscv-tests (ooo)` job actually
# executes. Leaving the floor only in cosim.py would mean a change that stops
# forming pairs passes every job in CI.
CORE="${CORE:-inorder}"
# sim/tracer.v's trailer: "# retired N instructions (slot1 M)". Missing file
# or missing trailer reads as 0, which fails the floor - the right direction
# for a check whose whole purpose is to notice that something stopped
# happening.
trace_slot1() {
    sed -n 's/^# retired [0-9]* instructions (slot1 \([0-9]*\))$/\1/p' \
        "$1" 2>/dev/null | tail -1 | grep -E '^[0-9]+$' || echo 0
}
slot1_floor() {
    grep -v '^#' "$HERE/dual-issue-floor.txt" 2>/dev/null \
        | awk -v n="$1" '$1==n{print $2; found=1} END{exit !found}'
}

while read -r name tohost; do
    if [ -n "$FILTER" ] && [[ "$name" != *"$FILTER"* ]]; then continue; fi

    case "$tohost" in
        BUILD_FAILED|NO_TOHOST)
            printf '  %-28s SKIP (%s)\n' "$name" "$tohost"
            echo "$name SKIP" >> "$results"
            skip=$((skip + 1))
            continue
            ;;
    esac

    # +trace= is only passed for the tests that have a floor: sim/tracer.v
    # writes one line per retired instruction, and asking every test for one
    # would write tens of thousands of lines nothing reads.
    floor="$(slot1_floor "$name" || true)"
    trace_arg=""
    if [ -n "$floor" ]; then
        trace_arg="+trace=$OUT/$name.trace"
    fi

    # $readmemh warns about the unfilled tail of the RAM array on every run;
    # that is expected (the image is far smaller than the memory) and would
    # otherwise bury the actual verdict. The full output is kept, though, so
    # that anything the filter does not recognize can still be shown - a
    # verdict this script cannot parse used to be indistinguishable from a
    # test that simply failed, which cost real time chasing an intermittent
    # ISA-TIMEOUT whose actual cause was never printed.
    full="$(cd "$ROOT/sim" && vvp "$SIM" \
              +hex="$OUT/$name.hex" +tohost="$tohost" $trace_arg 2>&1)"
    line="$(echo "$full" | grep -E '^ISA-(PASS|FAIL|TIMEOUT|LOADFAIL)' | head -1)"

    # No recognizable verdict at all: the simulator died, or said something
    # new. Either way, print what it actually said rather than silently
    # counting it as an ordinary failure.
    if [ -z "$line" ]; then
        printf '  %-28s ERROR (no verdict - simulator output follows)\n' "$name"
        echo "$full" | tail -8 | sed 's/^/      /'
        echo "$name ERROR" >> "$results"
        fail=$((fail + 1))
        failed_names="$failed_names $name"
        continue
    fi

    case "$line" in
        ISA-LOADFAIL*)
            # The image never made it into RAM, so whatever the core did
            # afterwards says nothing about the core. Never an expected
            # failure - this is a harness fault, not a CPU one.
            printf '  %-28s ERROR (%s)\n' "$name" "$line"
            echo "$name LOADFAIL" >> "$results"
            fail=$((fail + 1))
            failed_names="$failed_names $name"
            ;;
        ISA-PASS*)
            if is_expected_failure "$name"; then
                printf '  %-28s XPASS (listed as expected-fail but passed)\n' "$name"
                echo "$name XPASS" >> "$results"
                xpass=$((xpass + 1))
                xpass_names="$xpass_names $name"
            elif [ -n "$floor" ] && [ "$CORE" = ooo ] && \
                 [ "$(trace_slot1 "$OUT/$name.trace")" -lt "$floor" ]; then
                # Passing, and no longer testing what it was written to test.
                # Reported as a failure rather than a warning: a warning in a
                # 83-line list is a warning nobody reads.
                got="$(trace_slot1 "$OUT/$name.trace")"
                printf '  %-28s UNDER-ISSUED (passed, but retired %s in slot 1; needs %s)\n' \
                    "$name" "$got" "$floor"
                echo "$name UNDER-ISSUED $got/$floor" >> "$results"
                fail=$((fail + 1))
                failed_names="$failed_names $name"
            else
                extra=""
                if [ -n "$floor" ] && [ "$CORE" = ooo ]; then
                    extra=", slot1=$(trace_slot1 "$OUT/$name.trace")"
                fi
                printf '  %-28s PASS  (%s%s)\n' "$name" "${line#ISA-PASS }" "$extra"
                echo "$name PASS" >> "$results"
                pass=$((pass + 1))
            fi
            ;;
        ISA-FAIL*|ISA-TIMEOUT*)
            if is_expected_failure "$name"; then
                printf '  %-28s XFAIL (expected - see expected-failures.txt)\n' "$name"
                echo "$name XFAIL" >> "$results"
                xfail=$((xfail + 1))
            else
                printf '  %-28s FAIL  %s\n' "$name" "$line"
                echo "$name FAIL $line" >> "$results"
                fail=$((fail + 1))
                failed_names="$failed_names $name"
            fi
            ;;
        *)
            printf '  %-28s ERROR (no verdict from simulator)\n' "$name"
            echo "$name ERROR" >> "$results"
            fail=$((fail + 1))
            failed_names="$failed_names $name"
            ;;
    esac
done < "$OUT/manifest.txt"

echo
echo "==================================================="
echo "riscv-tests: $pass passed, $fail failed, $xfail xfail, $xpass xpass, $skip skipped"
[ -n "$failed_names" ] && echo "failing:$failed_names"
[ -n "$xpass_names" ] && echo "now passing (remove from expected-failures.txt):$xpass_names"
echo "==================================================="
[ "$fail" -eq 0 ] && [ "$xpass" -eq 0 ]
