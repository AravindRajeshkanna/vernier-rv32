#!/usr/bin/env python3
"""Four harts streaming through memory, over the bus and over the router fabric (Phase 8 Stage 3,
Part 35): Part 27's measurement (sim/stream2_matrix.py) with two more harts.

Builds sim/sim_soc_4hart_stream.out once per interconnect (the bus, with its monitor; the router fabric;
and the router fabric with the slave interfaces' bypass; the fabric without its aging as well with
STREAM4_NOAGE=1), then runs software/bench/stream4.S: a hart alone in each memory, the two-hart pair of
Part 27 as a control, and the placements below with all four harts streaming. A placement is where the
four harts' arrays live, hart 0 first: R is block RAM, S is SDRAM. The programs measure themselves, as
words read per thousand cycles inside a fixed window; the tables set a hart's rate beside the others
against its rate alone (the interference) and the fabric against the bus. See sim/tb_soc_4hart_stream.v.

  python3 sim/stream4_matrix.py                 run every interconnect, then print the tables
  python3 sim/stream4_matrix.py run bus fabric  run only these (several can run at once, each in its own
                                                copy of the tree, as they clear the built simulations)
  python3 sim/stream4_matrix.py report          print the tables from the results already in the log
                                                directory (STREAM4_LOG, default /tmp/stream4_matrix)

`make` does not know that a different INTERCONNECT needs a different build, so the built simulations
are cleared before each build. A few minutes of Icarus a run; nine runs an interconnect.
"""
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.environ.get("STREAM4_LOG", "/tmp/stream4_matrix")
VVP = os.environ.get("VVP", "vvp")
WINDOW = int(os.environ.get("STREAM4_WINDOW", "200000"))
CORE = os.environ.get("CORE", "inorder")
WORDS_PER_BLOCK = 64
MAXH = 4

RAM = ["80010000", "80020000", "80030000", "80040000"]   # block RAM, one array a hart
SDR = ["90000000", "90010000", "90020000", "90030000"]   # SDRAM

FABRICS = [("bus", ["STREAM4_DEFS=-DBUS_MONITOR"]), ("fabric", ["INTERCONNECT=xbar"]),
           ("bypass", ["INTERCONNECT=xbar", "XBAR_NI_BYPASS=1"])]   # the fabric with rtl/soc/noc_ni_slave.v's BYPASS
if os.environ.get("STREAM4_NOAGE"):
    FABRICS.append(("noage", ["INTERCONNECT=xbar", "XBAR_AGE_LIMIT=0"]))   # the four-hart fabric default is aging on
# Where the four harts' arrays are, hart 0 first.
PLACEMENTS = ["RRRR", "SSSS", "RRSS", "SSRR", "RRRS", "SRRR"]


def bases(placement):
    return [RAM[h] if c == "R" else SDR[h] for h, c in enumerate(placement)]


# (name, mode, placement): the runs of one interconnect. "alone" is hart 0 by itself; "pair" is the two harts
# of Part 27's split placement (hart 0 in block RAM, hart 1 in SDRAM), as a control on the four-hart SoC.
RUNS = [("alone R", 1, "RRRR"), ("alone S", 1, "SRRR"), ("pair RS", 3, "RSRR")] + [(p, 15, p) for p in PLACEMENTS]


def clear_builds():
    for f in glob.glob(os.path.join(ROOT, "sim", "*.out")):
        os.remove(f)


def build(extra):
    clear_builds()
    subprocess.run(["make", "-s", "sim/stream4.hex", "sim/sim_soc_4hart_stream.out"] + extra,
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


def run(fabric, name, mode, placement):
    tag = "%s.%s" % (fabric, re.sub(r"[^a-z0-9]+", "_", name.lower()))
    b = bases(placement)
    args = [VVP, "sim_soc_4hart_stream.out", "+mode=%d" % mode, "+window=%d" % WINDOW, "+maxcycles=3000000"]
    args += ["+base%d=%s" % (h, b[h]) for h in range(MAXH)]
    p = subprocess.run(args, cwd=os.path.join(ROOT, "sim"), stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    with open(os.path.join(LOGDIR, tag + ".log"), "w") as f:
        f.write(p.stdout)
    r = {"ok": p.returncode == 0 and "SOC-4HART-STREAM: PASS" in p.stdout, "log": tag + ".log", "mode": mode,
         "placement": placement}
    for h in range(MAXH):
        m = re.search(r"STREAM4 hart %d status=(\d+) blocks=(\d+) cycles=(\d+)" % h, p.stdout)
        blocks, cycles = (int(m.group(2)), int(m.group(3))) if m else (0, 0)
        r["h%d" % h] = blocks * WORDS_PER_BLOCK * 1000.0 / cycles if cycles else 0.0   # words per thousand cycles
    m = re.search(r"STREAM4 total cycles=(\d+)", p.stdout)
    r["total"] = int(m.group(1)) if m else 0
    m = re.search(r"bus in use:\s+\d+ cycles \((\d+)\.(\d+)%\)", p.stdout)
    if m:
        r["busy"] = float("%s.%s" % (m.group(1), m.group(2)))
    m = re.search(r"STREAM4 slaves over (\d+) cycles: RAM stb=(\d+) ack=(\d+) SDRAM stb=(\d+) ack=(\d+)", p.stdout)
    if m:
        win, rs, ra, ss, sa = (int(x) for x in m.groups())
        # per thousand cycles: accesses served, and the share of cycles the strobe was up
        r["ram_acc"], r["ram_up"] = ra * 1000.0 / win, rs * 100.0 / win
        r["sd_acc"], r["sd_up"] = sa * 1000.0 / win, ss * 100.0 / win
    return r


def run_fabrics(names):
    os.makedirs(LOGDIR, exist_ok=True)
    for fabric, extra in FABRICS:
        if names and fabric not in names:
            continue
        build(extra)
        res = {}
        for name, mode, placement in RUNS:
            res[name] = run(fabric, name, mode, placement)
            print("  ran %-6s %-8s: %s" % (fabric, name, "ok" if res[name]["ok"] else
                                          "FAILED (see %s/%s)" % (LOGDIR, res[name]["log"])), file=sys.stderr)
            sys.stderr.flush()
        with open(os.path.join(LOGDIR, fabric + ".json"), "w") as f:
            json.dump(res, f, indent=1)
    clear_builds()


def load():
    res = {}
    for fabric, _ in FABRICS:
        p = os.path.join(LOGDIR, fabric + ".json")
        if os.path.exists(p):
            res[fabric] = json.load(open(p))
    return res


def ratio(a, b):
    return a / b if b else 0.0


def report(res):
    fabrics = [f for f, _ in FABRICS if f in res]
    print("Four harts streaming, CORE=%s: words read per thousand cycles, in a %d-cycle window (arrays of 1024 words, "
          "4 KB)\n" % (CORE, WINDOW))
    print("%-7s %-9s %8s %8s %8s %8s %9s %9s %9s" % ("fabric", "run", "hart 0", "hart 1", "hart 2", "hart 3", "sum",
                                                      "slowest", "bus busy"))
    for fabric in fabrics:
        for name, mode, _p in RUNS:
            r = res[fabric].get(name)
            if not r:
                continue
            rates = [r["h%d" % h] for h in range(MAXH)]
            print("%-7s %-9s %8.1f %8.1f %8.1f %8.1f %9.1f %9s %9s%s" % (
                fabric, name, rates[0], rates[1], rates[2], rates[3], sum(rates),
                "%.1f" % min(rates[h] for h in range(MAXH) if mode >> h & 1) if mode == 15 else "",
                "%.1f%%" % r["busy"] if "busy" in r else "", "" if r["ok"] else "   FAILED"))
    print("\nThe memories' side, over the window: accesses served per thousand cycles, and the share of cycles the strobe was up\n")
    print("%-7s %-9s %12s %9s %12s %9s" % ("fabric", "run", "RAM access", "RAM up", "SDRAM access", "SDRAM up"))
    for fabric in fabrics:
        for name, _mode, _p in RUNS:
            r = res[fabric].get(name)
            if r and "ram_acc" in r:
                print("%-7s %-9s %12.1f %8.1f%% %12.1f %8.1f%%" % (fabric, name, r["ram_acc"], r["ram_up"],
                                                                   r["sd_acc"], r["sd_up"]))
    if "bus" not in res:
        return
    for fabric in [f for f in fabrics if f != "bus"]:
        print("\nAll four streaming: the %s against the bus (ratio above 1: it is faster)\n" % fabric)
        print("%-10s %-9s %s %9s" % ("arrays", "", " ".join("%10s" % ("hart %d" % h) for h in range(MAXH)), "sum"))
        for p in PLACEMENTS:
            b, f = res["bus"][p], res[fabric][p]
            cells = ["%10.2f" % ratio(f["h%d" % h], b["h%d" % h]) for h in range(MAXH)]
            bs = sum(b["h%d" % h] for h in range(MAXH))
            fs = sum(f["h%d" % h] for h in range(MAXH))
            print("%-10s %-9s %s %9.2f" % (p, "", " ".join(cells), ratio(fs, bs)))

    print("\nInterference: a hart's rate beside the other three, over its rate alone in the same memory (1.00: none)\n")
    print("%-7s %-8s %s" % ("fabric", "arrays", " ".join("%10s" % ("hart %d" % h) for h in range(MAXH))))
    for fabric in fabrics:
        alone = {"R": res[fabric]["alone R"]["h0"], "S": res[fabric]["alone S"]["h0"]}
        for p in PLACEMENTS:
            r = res[fabric][p]
            print("%-7s %-8s %s" % (fabric, p, " ".join("%10.2f" % ratio(r["h%d" % h], alone[p[h]])
                                                          for h in range(MAXH))))
    print("\nControl, the pair of Part 27 (hart 0 in block RAM, hart 1 in SDRAM) on this four-hart SoC:")
    for fabric in fabrics:
        r = res[fabric]["pair RS"]
        print("  %-7s hart 0 %6.1f   hart 1 %6.1f   (alone: RAM %6.1f, SDRAM %6.1f)" % (
            fabric, r["h0"], r["h1"], res[fabric]["alone R"]["h0"], res[fabric]["alone S"]["h0"]))


def main(argv):
    mode = argv[1] if len(argv) > 1 else "all"
    if mode in ("all", "run"):
        run_fabrics(argv[2:] if mode == "run" else [])
    if mode in ("all", "report"):
        res = load()
        report(res)
        failed = [(f, n) for f, d in res.items() for n, r in d.items() if not r["ok"]]
        if failed:
            print("\n%d run(s) FAILED: %s" % (len(failed), ", ".join("%s/%s" % k for k in failed)))
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
