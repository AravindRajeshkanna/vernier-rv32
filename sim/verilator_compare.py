#!/usr/bin/env python3
"""Require the Icarus and Verilator SoC runs to agree.

A second simulator is only worth having if it agrees with the first, and
"both printed PASS" is a weak form of agreement: two quite different machines
can both finish a self-checking program successfully. What is checked here is
the *cycle count*, which is the strongest statement the two runs can make
about being the same design.

Matching cycle counts mean the C++ SDRAM model in sim/verilator_soc.cpp
returns read data on the same edges sim/sdram_model.v returns it on, that
reset is released on the same edge, and that nothing in between is being
simulated approximately. A port of a memory model that is one cycle early
still passes a write-then-read test; it does not pass this. (Measured: making
exactly that change - loading the read pipeline at `cl` instead of `cl-1` -
does not shift the total by a few cycles. It hangs the program outright.)

---- Why the cycle count gets one unit of slack, and nothing else does ----

sim/tb_sdramboot.v watches the verdict word from an `initial` block sitting
on `@(posedge clk)`, which resumes in the active region - before that edge's
non-blocking assignments have landed - and counts cycles in a *second*
process on the same edge. Verilog does not define the order of those two
processes, and a cycle-based harness has no active region at all. So the two
totals can differ by one, for reasons that live entirely in the testbenches.

Measured, and this is why it is slack rather than a constant offset:

    in-order   Icarus 2,108,456   Verilator 2,108,457   (+1)
    wide       Icarus 1,688,890   Verilator 1,688,890   ( 0)

An earlier version of the harness "corrected" the in-order case with a
constant, derived from a mechanism that predicted +1 for both. It turned the
wide core's clean run into a false failure. docs/practices.md section 25.

One cycle cannot hide a real divergence. A memory model that is early or late
changes the stall on every one of the ~10^5 SDRAM accesses this program
makes, so the effect is thousands of cycles at least. The refresh count is an
independent witness to the same thing and must match *exactly*: at roughly
one refresh per 196 cycles it pins the two runs together far tighter than the
cycle counter's slack does. And the program's own UART output is compared
byte for byte, because a cycle count is a single number and two runs can
arrive at the same one having printed different things.

Usage: verilator_compare.py <icarus.log> <verilator.log>
"""
import difflib
import re
import sys


# name -> (pattern, how many units of slack it is allowed). Only the cycle
# count gets any, and only one; see the module docstring.
FIELDS = (
    ("cycles",    re.compile(r"^cycles:\s*(\d+)", re.M),                  1),
    ("refreshes", re.compile(r"^SDRAM refreshes issued:\s*(\d+)", re.M),  0),
    ("result",    re.compile(r"^result word.*:\s*(0x[0-9a-fA-F]+)", re.M), 0),
)


# The program's own output, bounded by two lines it prints itself. Everything
# outside this is the harness talking - banners, image sizes, wall clock - and
# legitimately differs between the two.
BODY_START = "=== SDRAM acceptance test ==="
BODY_END   = "SDRAM-TEST:"


def body(path):
    """The UART stream the firmware produced, with the harness chatter cut off."""
    lines = open(path).read().splitlines()
    try:
        first = next(i for i, l in enumerate(lines) if BODY_START in l)
        last = next(i for i, l in enumerate(lines) if BODY_END in l)
    except StopIteration:
        sys.exit(f"{path}: no program output between "
                 f"'{BODY_START}' and '{BODY_END}'")
    return lines[first:last + 1]


def scrape(path):
    text = open(path).read()
    out = {}
    for name, pattern, _ in FIELDS:
        match = pattern.search(text)
        if not match:
            sys.exit(f"{path}: no '{name}' line - did the run get that far?\n"
                     f"--- tail ---\n{text[-800:]}")
        out[name] = match.group(1)
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    icarus, verilator = (scrape(p) for p in sys.argv[1:3])

    print(f"{'':<12}{'icarus':>14}{'verilator':>14}{'':>10}")
    for name, _, slack in FIELDS:
        note = ""
        if slack and icarus[name] != verilator[name]:
            note = f"  (differ by {int(verilator[name]) - int(icarus[name]):+d}, "\
                   f"allowed +/-{slack})"
        print(f"{name:<12}{icarus[name]:>14}{verilator[name]:>14}{note}")

    if icarus["result"].lower() != "0x50415353":
        sys.exit("\nthe Icarus run did not pass; nothing to compare against")

    bad = []
    for name, _, slack in FIELDS:
        if icarus[name] == verilator[name]:
            continue
        if slack and abs(int(verilator[name]) - int(icarus[name])) <= slack:
            continue
        bad.append(name)

    icarus_body, verilator_body = (body(p) for p in sys.argv[1:3])
    if icarus_body != verilator_body:
        for line in difflib.unified_diff(icarus_body, verilator_body,
                                         "icarus", "verilator", lineterm=""):
            print(line)
        bad.append("the program's UART output")

    if bad:
        sys.exit("\nthe two simulators disagree on: " + ", ".join(bad) +
                 "\nsim/sdram_model.v is the authority - the C++ port in "
                 "sim/verilator_soc.cpp has the bug.")

    print(f"\n{len(icarus_body)} lines of program output, identical")
    if all(icarus[n] == verilator[n] for n, _, _ in FIELDS):
        print("VERILATOR CHECK PASSED - both simulators, cycle for cycle")
    else:
        print("VERILATOR CHECK PASSED - both simulators, within the stated slack")


if __name__ == "__main__":
    main()
