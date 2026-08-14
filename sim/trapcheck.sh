#!/bin/sh
# Prove the loud trap handler, by making it report faults we already know the
# answers to.
#
# software/soc/trapcheck.c provokes one deliberate fault per run; this builds
# and runs each case and checks the report against what that fault must
# produce. Without this the handler is an instrument nobody has calibrated,
# and a later run that prints no trap report would be evidence of nothing.
#
# **The testbench verdict is inverted here on purpose.** trap_report writes
# FAIL to the result word - that is what makes an unexpected trap fail a normal
# simulation instead of hanging it - so every run below ends in "RAMBOOT TEST
# FAILED", and that is the pass condition. What is actually being scored is the
# text of the report.
set -eu

cd "$(dirname "$0")/.."

LOG=sim/trapcheck.log
fails=0

# $1 case number, $2.. the strings the report must contain
run_case() {
    n=$1
    shift

    echo "=== trapcheck case $n ==="

    # Force a rebuild: the image is the same filename every time, and only the
    # -DTRAPCHECK value differs, so make cannot tell the cases apart by date.
    rm -f software/soc/trapcheck.elf sim/trapimage.hex
    make -s sim/trapimage.hex TRAPCHECK="$n"

    ( cd sim && vvp sim_trap.out ) > "$LOG" 2>&1 || true
    sed 's/^/    /' "$LOG"

    for want in "$@"; do
        if grep -qF -- "$want" "$LOG"; then
            echo "  ok   report contains: $want"
        else
            echo "  FAIL report is missing: $want"
            fails=$((fails + 1))
        fi
    done

    # The one outcome that means the handler is still silently stepping over
    # faults - the exact behavior all of this exists to end.
    if grep -qF -- "the handler resumed from an unarmed trap" "$LOG"; then
        echo "  FAIL the handler resumed instead of halting"
        fails=$((fails + 1))
    fi
}

# Case 1: a misaligned load nobody armed. mtval is the faulting address.
run_case 1 \
    "an armed trap is recorded and resumed" \
    "*** UNEXPECTED TRAP - halted ***" \
    "mcause  0x00000004  load address misaligned" \
    "mtval   0x80008101" \
    "HALTED"

# Case 2: an illegal instruction. This is the one the old handler stepped over,
# leaving a program running with an instruction's effect simply missing.
# mtval is not checked - what it holds for an illegal instruction is the CPU's
# business, and the point here is that the machine stops.
run_case 2 \
    "*** UNEXPECTED TRAP - halted ***" \
    "mcause  0x00000002  ILLEGAL INSTRUCTION" \
    "HALTED"

# Case 3: the same fault with sp already wrecked. The report must still come
# out - that is what the reporter's private stack in link_ram.ld buys - and it
# must show the wild sp rather than the one it printed from.
run_case 3 \
    "*** UNEXPECTED TRAP - halted ***" \
    "mcause  0x00000004  load address misaligned" \
    "sp      0x80008001" \
    "NOTE: sp is not word-aligned" \
    "HALTED"

# Case 4: a trap while the reporter is already running. The last-resort path
# must emit its single '!' and stop - not a report, and not a loop. Checked
# separately below because what it must *not* contain is the point.
run_case 4 "!"

if grep -qF -- "*** UNEXPECTED TRAP" "$LOG"; then
    echo "  FAIL the double-fault path printed a full report"
    fails=$((fails + 1))
else
    echo "  ok   the double-fault path did not try to print a report"
fi
if [ "$(grep -c '!' "$LOG")" -gt 1 ]; then
    echo "  FAIL the double-fault path looped"
    fails=$((fails + 1))
else
    echo "  ok   the double-fault path emitted one byte and stopped"
fi

# Leave no image behind. Every case writes the same filename, so whatever
# survived would be "case 3" only by accident of running order - and
# BOARD=ulx3s85-trapcheck bakes that file into a bitstream. A missing image
# there is an error with a clear message; a stale one is a board that provokes
# a different fault than the person flashing it thinks.
rm -f sim/trapimage.hex software/soc/trapcheck.elf software/soc/trapcheck.bin

echo
echo "---------------------------------------------"
if [ "$fails" -eq 0 ]; then
    echo "TRAP HANDLER CHECK PASSED"
else
    echo "TRAP HANDLER CHECK FAILED ($fails check(s))"
fi
echo "---------------------------------------------"
[ "$fails" -eq 0 ]
