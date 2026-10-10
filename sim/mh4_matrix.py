#!/usr/bin/env python3
"""Four harts over every interconnect and both memories (Phase 8 Stage 3, Part 34).

Builds sim/sim_soc_4hart.out once per interconnect (the bus, the one-node network, the router fabric, and
the router fabric with the slave interfaces' bypass; the fabric with its traffic classes as well with MH4_QOS=1), then runs
software/bench/mh4.S on four harts with the shared data in block RAM and in SDRAM, and, in block RAM,
on one, two and three harts as well, so that a run that passes on four shows it is not the program that
only knows how to pass. Prints one line a run: whether the testbench's checks held, the cycles, and the
failed LR/SCs (a run in which none failed proved nothing about contention).

CORE=ooo or CORE=hetero runs the wide core, or hart 0 in-order and the rest wide. `make` does not know
that a different INTERCONNECT needs a different build, so the built simulations are cleared before each
build. See sim/tb_soc_4hart.v and software/bench/mh4.S.
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.environ.get("MH4_LOG", "/tmp/mh4_matrix")
VVP = os.environ.get("VVP", "vvp")

FABRICS = [("bus", []), ("noc", ["INTERCONNECT=noc"]), ("fabric", ["INTERCONNECT=xbar"]),
           ("bypass", ["INTERCONNECT=xbar", "XBAR_NI_BYPASS=1"])]
if os.environ.get("MH4_QOS"):
    FABRICS.append(("qos", ["INTERCONNECT=xbar", "MH4_DEFS=-DXBAR_QOS"]))
# (name, plusargs)
RUNS = [
    ("4 harts, block RAM", ["+nharts=4"]),
    ("4 harts, SDRAM", ["+nharts=4", "+base=90000000"]),
    ("3 harts, block RAM", ["+nharts=3"]),
    ("2 harts, block RAM", ["+nharts=2"]),
    ("1 hart, block RAM", ["+nharts=1"]),
]


def clear_builds():
    for f in glob.glob(os.path.join(ROOT, "sim", "*.out")):
        os.remove(f)


def build(extra):
    clear_builds()
    subprocess.run(["make", "-s", "sim/mh4.hex", "sim/sim_soc_4hart.out"] + extra,
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


def run(fabric, name, args):
    tag = "%s.%s" % (fabric, re.sub(r"[^a-z0-9]+", "_", name.lower()))
    p = subprocess.run([VVP, "sim_soc_4hart.out", "+maxcycles=1000000"] + args, cwd=os.path.join(ROOT, "sim"),
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    with open(os.path.join(LOGDIR, tag + ".log"), "w") as f:
        f.write(p.stdout)
    ok = p.returncode == 0 and "SOC-4HART: PASS" in p.stdout
    m = re.search(r"MH4 total cycles=(\d+)", p.stdout)
    cycles = int(m.group(1)) if m else 0
    m = re.search(r"MH4 observed c1=\d+ c2=\d+ c3=\d+ scfail=(\d+)", p.stdout)
    scfail = int(m.group(1)) if m else -1
    return ok, cycles, scfail, tag + ".log"


def main():
    os.makedirs(LOGDIR, exist_ok=True)
    core = os.environ.get("CORE", "inorder")
    print("Four harts, CORE=%s\n" % core)
    print("%-8s %-22s %-6s %9s %10s" % ("fabric", "run", "checks", "cycles", "failed SCs"))
    bad = 0
    for fabric, extra in FABRICS:
        build(extra)
        for name, args in RUNS:
            ok, cycles, scfail, log = run(fabric, name, args)
            if not ok:
                bad += 1
            print("%-8s %-22s %-6s %9d %10d%s" % (fabric, name, "ok" if ok else "FAILED", cycles, scfail,
                                                 "" if ok else "   (see %s/%s)" % (LOGDIR, log)))
            sys.stdout.flush()
    clear_builds()
    if bad:
        print("\n%d run(s) FAILED" % bad)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
