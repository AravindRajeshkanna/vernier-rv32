#!/usr/bin/env python3
"""Two harts streaming through memory, over the bus and over the router fabric (Phase 8 Stage 3,
Part 27).

Builds sim/sim_soc_2hart_stream.out once per interconnect, then runs the placements below with each
hart alone and with both together, and prints what the programs measure of themselves: how many
words each hart read per thousand cycles inside a fixed window, and the same figures set against the
hart running alone (the interference) and against the other interconnect. A placement is where the
two harts' arrays live: `same` both in block RAM, `split` hart 0 in RAM and hart 1 in SDRAM, `sdram`
both in SDRAM. See sim/tb_soc_2hart_stream.v and software/bench/stream2.S.

`make` does not know that a different INTERCONNECT needs a different build, so the built simulations
are cleared before each build. Sixteen Icarus simulations, a few seconds to a few minutes each.
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.environ.get("STREAM2_LOG", "/tmp/stream2_matrix")
VVP = os.environ.get("VVP", "vvp")
WINDOW = int(os.environ.get("STREAM2_WINDOW", "200000"))
WORDS_PER_BLOCK = 64

RAM_A, RAM_B = "80010000", "80020000"   # block RAM
SD_A, SD_B = "90000000", "90010000"     # SDRAM

# (placement, mode, base0, base1): mode 1 hart 0 alone, 2 hart 1 alone, 3 both
RUNS = [
    ("same", 1, RAM_A, RAM_B), ("same", 2, RAM_A, RAM_B), ("same", 3, RAM_A, RAM_B),
    ("split", 2, RAM_A, SD_A), ("split", 3, RAM_A, SD_A),
    ("sdram", 1, SD_A, SD_B), ("sdram", 2, SD_A, SD_B), ("sdram", 3, SD_A, SD_B),
]
FABRICS = [("bus", []), ("fabric", ["INTERCONNECT=xbar"])]
MEMORY = {"same": "RAM,RAM", "split": "RAM,SDRAM", "sdram": "SDRAM,SDRAM"}
# Which run is the hart on its own, in the memory it has in each placement.
ALONE = {
    (0, "same"): ("same", 1), (0, "split"): ("same", 1), (0, "sdram"): ("sdram", 1),
    (1, "same"): ("same", 2), (1, "split"): ("split", 2), (1, "sdram"): ("sdram", 2),
}


def clear_builds():
    for f in glob.glob(os.path.join(ROOT, "sim", "*.out")):
        os.remove(f)


def build(extra):
    clear_builds()
    subprocess.run(["make", "-s", "sim/stream2.hex", "sim/sim_soc_2hart_stream.out"] + extra,
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


def run(fabric, placement, mode, base0, base1):
    name = "%s.%s.%d" % (fabric, placement, mode)
    args = [VVP, "sim_soc_2hart_stream.out", "+mode=%d" % mode, "+base0=" + base0,
            "+base1=" + base1, "+window=%d" % WINDOW, "+maxcycles=3000000"]
    p = subprocess.run(args, cwd=os.path.join(ROOT, "sim"), stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    with open(os.path.join(LOGDIR, name + ".log"), "w") as f:
        f.write(p.stdout)
    r = {"ok": p.returncode == 0 and "SOC-2HART-STREAM: PASS" in p.stdout, "log": name + ".log"}
    for h in (0, 1):
        m = re.search(r"STREAM2 hart %d status=(\d+) blocks=(\d+) cycles=(\d+)" % h, p.stdout)
        blocks, cycles = (int(m.group(2)), int(m.group(3))) if m else (0, 0)
        # words per thousand cycles
        r["h%d" % h] = blocks * WORDS_PER_BLOCK * 1000.0 / cycles if cycles else 0.0
    m = re.search(r"STREAM2 total cycles=(\d+)", p.stdout)
    r["total"] = int(m.group(1)) if m else 0
    return r


def main():
    os.makedirs(LOGDIR, exist_ok=True)
    res = {}
    for fabric, extra in FABRICS:
        build(extra)
        for placement, mode, b0, b1 in RUNS:
            res[(fabric, placement, mode)] = run(fabric, placement, mode, b0, b1)
            r = res[(fabric, placement, mode)]
            print("  ran %-6s %-5s mode %d: %s" % (fabric, placement, mode,
                                                  "ok" if r["ok"] else "FAILED (see %s/%s)" % (LOGDIR, r["log"])),
                  file=sys.stderr)
    clear_builds()

    print("Words read per thousand cycles, in a %d-cycle window (arrays of 1024 words, 4 KB)\n" % WINDOW)
    print("%-7s %-12s %-10s %9s %9s %9s %12s" % ("fabric", "memory", "run", "hart 0", "hart 1", "sum", "wall-clock"))
    for fabric, _ in FABRICS:
        for placement, mode, _b0, _b1 in RUNS:
            r = res[(fabric, placement, mode)]
            what = {1: "hart 0 alone", 2: "hart 1 alone", 3: "both"}[mode]
            print("%-7s %-12s %-10s %9.1f %9.1f %9.1f %12d%s" % (
                fabric, MEMORY[placement], what, r["h0"], r["h1"], r["h0"] + r["h1"], r["total"],
                "" if r["ok"] else "   FAILED"))

    print("\nBoth harts streaming: the router fabric against the bus (ratio above 1: the fabric is faster)\n")
    print("%-12s %26s %26s %26s" % ("memory", "hart 0 (bus, fabric, x)", "hart 1 (bus, fabric, x)", "sum (bus, fabric, x)"))
    for placement in ("same", "split", "sdram"):
        b = res[("bus", placement, 3)]
        f = res[("fabric", placement, 3)]
        cells = []
        for k in ("h0", "h1"):
            cells.append("%8.1f %8.1f %6.2f" % (b[k], f[k], f[k] / b[k] if b[k] else 0.0))
        bs, fs = b["h0"] + b["h1"], f["h0"] + f["h1"]
        cells.append("%8.1f %8.1f %6.2f" % (bs, fs, fs / bs if bs else 0.0))
        print("%-12s %26s %26s %26s" % (MEMORY[placement], cells[0], cells[1], cells[2]))

    print("\nInterference: a hart's rate beside the other, over its rate alone (1.00: none)\n")
    print("%-12s %22s %22s" % ("memory", "bus (hart 0, hart 1)", "fabric (hart 0, hart 1)"))
    for placement in ("same", "split", "sdram"):
        cells = []
        for fabric, _ in FABRICS:
            both = res[(fabric, placement, 3)]
            vals = []
            for h in (0, 1):
                alone = res[(fabric,) + ALONE[(h, placement)]]["h%d" % h]
                vals.append(both["h%d" % h] / alone if alone else 0.0)
            cells.append("%9.2f %9.2f" % tuple(vals))
        print("%-12s %22s %22s" % (MEMORY[placement], cells[0], cells[1]))

    failed = [k for k, v in res.items() if not v["ok"]]
    if failed:
        print("\n%d run(s) FAILED: %s" % (len(failed), ", ".join("%s/%s/%d" % k for k in failed)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
