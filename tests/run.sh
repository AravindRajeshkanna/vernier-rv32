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

    # $readmemh warns about the unfilled tail of the RAM array on every run;
    # that is expected (the image is far smaller than the memory) and would
    # otherwise bury the actual verdict.
    line="$(cd "$ROOT/sim" && vvp "$SIM" \
              +hex="$OUT/$name.hex" +tohost="$tohost" 2>&1 \
            | grep -E '^ISA-(PASS|FAIL|TIMEOUT)' | head -1)"

    case "$line" in
        ISA-PASS*)
            if is_expected_failure "$name"; then
                printf '  %-28s XPASS (listed as expected-fail but passed)\n' "$name"
                echo "$name XPASS" >> "$results"
                xpass=$((xpass + 1))
                xpass_names="$xpass_names $name"
            else
                printf '  %-28s PASS  (%s)\n' "$name" "${line#ISA-PASS }"
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
