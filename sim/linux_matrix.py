#!/usr/bin/env python3
"""Linux to userspace on one, two and four harts, over the bus and over the router fabric (Phase 8 Stage 4,
Part 37): the cycles Part 23 and Part 28 recorded for one and two harts, repeated on the tree as it is now, and
the same boot on four.

A cell is "<core>.<harts>.<fabric>":

    core    inorder, ooo (the wide core), or hetero (hart 0 in-order, the others wide; four harts only)
    harts   1, 2 or 4 (the SoC's NUM_HARTS; the kernel, OpenSBI and the stub are the same files in every cell)
    fabric  bus, fabric (INTERCONNECT=xbar), or bypass (INTERCONNECT=xbar XBAR_NI_BYPASS=1)

Each cell builds its own Verilator simulation in a directory of its own (make does not know that a different
INTERCONNECT needs a different build), packs the image for its core (the four-hart cells use the four-hart device
tree, dts/soc_$(CORE)_4hart.dtb, and every other cell the one it always has), and boots to the kernel image's
marker. It records the cycle count the run ends on, which is what Parts 23 and 28 give (after the console has
drained), the cycle the marker was seen, and what the kernel said about its CPUs. A cell passes if the marker is
seen, the console dropped no byte, and /proc/cpuinfo lists as many processors as the SoC has harts.

  python3 sim/linux_matrix.py                  build and run every cell, then print the tables
  python3 sim/linux_matrix.py run CELL...      only these cells (e.g. inorder.4.fabric)
  python3 sim/linux_matrix.py report           print the tables from the results already in the log directory
                                               (LINUX_MATRIX_LOG, default /tmp/linux_matrix)

LINUX_MATRIX_JOBS (default 6) simulations run at once; a cell whose result is already in the log directory is
skipped unless LINUX_MATRIX_FORCE=1. Not part of `make verify` or CI: it needs the kernel image, and a cell takes
minutes to an hour. See `make sim_linux`, `sim_linux_2hart` and `sim_linux_4hart` for one cell at a time.
"""
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.environ.get("LINUX_MATRIX_LOG", "/tmp/linux_matrix")
JOBS = int(os.environ.get("LINUX_MATRIX_JOBS", "6"))
FORCE = os.environ.get("LINUX_MATRIX_FORCE") == "1"
MARKER = "VERNIER-RV32-LINUX-BOOT-OK"
MAXCYCLES = {1: 600000000, 2: 800000000, 4: 2000000000}

FABRICS = {"bus": [], "fabric": ["INTERCONNECT=xbar"], "bypass": ["INTERCONNECT=xbar", "XBAR_NI_BYPASS=1"]}
MDIRVAR = {1: "VERILATOR_MDIR", 2: "VERILATOR_2HART_MDIR", 4: "VERILATOR_4HART_MDIR"}

# Four harts first: they are the new cells, and the slowest to build and to run.
CELLS = ["%s.4.%s" % (core, f) for core in ("inorder", "ooo", "hetero") for f in FABRICS] + \
        ["%s.%d.%s" % (core, h, f) for h in (2, 1) for core in ("inorder", "ooo") for f in FABRICS]


def split(cell):
    core, harts, fabric = cell.split(".")
    assert core in ("inorder", "ooo", "hetero") and int(harts) in MDIRVAR and fabric in FABRICS, cell
    return core, int(harts), fabric


def mdir(cell):
    return "obj_dir_soc_lm_" + cell.replace(".", "_")


def image(core, harts):
    return "sim/linuximage_%s%s.hex" % (core, "_4hart" if harts == 4 else "")


def make(args):
    subprocess.run(["make", "-C", ROOT] + args, check=True)


def build_image(core, harts):
    make(["CORE=" + core, image(core, harts)])


def build_sim(cell):
    core, harts, fabric = split(cell)
    d = mdir(cell)
    make(["CORE=" + core, "%s=%s" % (MDIRVAR[harts], d)] + FABRICS[fabric] + ["%s/Vsoc_top" % d])


def result_path(cell):
    return os.path.join(LOGDIR, cell + ".json")


def parse(cell, log, wall):
    text = open(log, errors="replace").read()
    core, harts, fabric = split(cell)

    def last(pattern):
        m = re.findall(pattern, text, re.M)
        return int(m[-1]) if m else None

    up = re.findall(r"smp: Brought up (\d+) node, (\d+) CPU", text)
    cpus = sorted({int(n) for n in re.findall(r"^processor\t: (\d+)", text, re.M)})
    res = {"cell": cell, "core": core, "harts": harts, "fabric": fabric,
           "cycles": last(r"^cycles: (\d+)"), "stop_at": last(r'^stopon ".*": seen at cycle (\d+)'),
           "marker": ("=== %s ===" % MARKER) in text, "dropped": "dropped by the transmitter" in text,
           "brought_up": int(up[-1][1]) if up else None, "processors": cpus, "wall": wall, "log": log}
    res["ok"] = bool(res["marker"] and not res["dropped"] and cpus == list(range(harts)))
    return res


def start(cell):
    core, harts, fabric = split(cell)
    log = os.path.join(LOGDIR, cell + ".log")
    cmd = ["../%s/Vsoc_top" % mdir(cell), "+sdram=" + os.path.basename(image(core, harts)), "+uart_clks=224",
           "+sdram_words=16777216", "+maxcycles=%d" % MAXCYCLES[harts], "+checkuart", "+stopon=" + MARKER]
    print("started  %s" % cell, flush=True)
    return (subprocess.Popen(cmd, cwd=os.path.join(ROOT, "sim"), stdout=open(log, "w"), stderr=subprocess.STDOUT), log, time.time())


def reap(running, block):
    """Collect finished simulations; with block, wait until there is room for another."""
    while True:
        for cell in list(running):
            proc, log, t0 = running[cell]
            if proc.poll() is not None:
                del running[cell]
                res = parse(cell, log, time.time() - t0)
                json.dump(res, open(result_path(cell), "w"), indent=1)
                print("finished %s: %s, %s cycles, %d s" % (cell, "ok" if res["ok"] else "FAILED", res["cycles"], res["wall"]),
                      flush=True)
        if not running or not block or len(running) < JOBS:
            return
        time.sleep(5)


def run(cells):
    """Build a cell's simulation and start it at once, so that the builds overlap the runs."""
    os.makedirs(LOGDIR, exist_ok=True)
    todo = [c for c in cells if FORCE or not os.path.exists(result_path(c))]
    running, imaged = {}, set()
    for cell in todo:
        core, harts, _ = split(cell)
        if (core, harts == 4) not in imaged:
            build_image(core, harts)
            imaged.add((core, harts == 4))
        build_sim(cell)
        reap(running, True)
        running[cell] = start(cell)
    while running:
        reap(running, False)
        time.sleep(5)


def load():
    out = {}
    for c in CELLS:
        if os.path.exists(result_path(c)):
            out[c] = json.load(open(result_path(c)))
    return out


def report(res):
    for core in ("inorder", "ooo", "hetero"):
        rows = [h for h in (1, 2, 4) if any("%s.%d.%s" % (core, h, f) in res for f in FABRICS)]
        if not rows:
            continue
        print("\n### %s core: cycles to userspace (run ends), and against the bus\n" % core)
        print("| harts | bus | router fabric | with the bypass |")
        print("|---|---|---|---|")
        for h in rows:
            cols = []
            base = res.get("%s.%d.bus" % (core, h))
            for f in FABRICS:
                r = res.get("%s.%d.%s" % (core, h, f))
                if r is None:
                    cols.append("-")
                    continue
                s = "{:,}".format(r["cycles"]) if r["cycles"] else "no result"
                if not r["ok"]:
                    s += " **FAILED**"
                elif f != "bus" and base and base["cycles"]:
                    s += " ({:+.1f}%)".format(100.0 * (r["cycles"] / float(base["cycles"]) - 1))
                cols.append(s)
            print("| %d | %s |" % (h, " | ".join(cols)))
    print("\n### what the kernel said, and how long the run took\n")
    print("| cell | marker at | brought up | processors | wall |")
    print("|---|---|---|---|---|")
    for c in CELLS:
        r = res.get(c)
        if r:
            print("| %s | %s | %s | %s | %d s |" % (c, "{:,}".format(r["stop_at"]) if r["stop_at"] else "never", r["brought_up"],
                                                   ",".join(map(str, r["processors"])) or "none", r["wall"]))


def main(argv):
    if len(argv) > 1 and argv[1] == "report":
        report(load())
        return 0
    cells = argv[2:] if len(argv) > 1 and argv[1] == "run" else CELLS
    for c in cells:
        split(c)
    run(cells)
    report(load())
    return 0 if all(r["ok"] for r in load().values()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
