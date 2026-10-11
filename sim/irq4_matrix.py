#!/usr/bin/env python3
"""Interrupt service on one of four harts, beside the other three streaming through memory, over the bus and
over the router fabric (Phase 8 Stage 3, Part 36): Part 32's measurement (sim/irq2_matrix.py) with two more
harts, and with the interrupted hart chosen.

Builds sim/sim_soc_4hart_irq.out once per interconnect (the bus, the router fabric, and the router fabric with
the slave interfaces' bypass; the fabric without its aging as well with IRQ4_NOAGE=1), then runs the cases
below, each with the measured hart's timer interrupt off and on, and prints what the programs measure of
themselves. A case is which hart is measured and which of the others stream, and in which memory (R is block
RAM, the memory the measured hart's loop, stack and counters are in; S is SDRAM):

    m0 alone   hart 0 measured, the others parked
    m0 RRR     hart 0 measured, harts 1 to 3 stream block RAM
    m0 SSS     hart 0 measured, harts 1 to 3 stream SDRAM
    m3 alone   hart 3 measured (the lowest priority on the bus and in the fabric), the others parked
    m3 R, m3 S hart 3 measured, hart 0 streams block RAM, or SDRAM
    m3 RRR     hart 3 measured, harts 0 to 2 stream block RAM
    m3 SSS     hart 3 measured, harts 0 to 2 stream SDRAM

For every case it works out what the interrupts cost the measured hart (cycles an interrupt: the cycles the
interrupted passes took beyond what the same number takes uninterrupted, over the interrupts taken), how long
an interrupt took to reach the timer (lat) and to be served (done), and how much the interrupts slowed the
streamers. See sim/tb_soc_4hart_irq.v and software/bench/irq4.S. CORE=ooo runs the wide core.

  python3 sim/irq4_matrix.py                 run every interconnect, then print the tables
  python3 sim/irq4_matrix.py run bus fabric  run only these (several can run at once, each in its own copy of
                                             the tree, as they clear the built simulations)
  python3 sim/irq4_matrix.py report          print the tables from the results already in the log directory
                                             (IRQ4_LOG, default /tmp/irq4_matrix)

`make` does not know that a different INTERCONNECT needs a different build, so the built simulations are
cleared before each build. Sixteen Icarus simulations an interconnect, several minutes each.
"""
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.environ.get("IRQ4_LOG", "/tmp/irq4_matrix")
VVP = os.environ.get("VVP", "vvp")
WINDOW = int(os.environ.get("IRQ4_WINDOW", "400000"))       # the measured window when it is interrupted
WINDOW_OFF = int(os.environ.get("IRQ4_WINDOW_OFF", "150000"))   # and when it is not: only the cost of a pass is wanted
PERIOD = int(os.environ.get("IRQ4_PERIOD", "30000"))
START = int(os.environ.get("IRQ4_START", "150000"))
MAXCYCLES = int(os.environ.get("IRQ4_MAXCYCLES", "1500000"))
CORE = os.environ.get("CORE", "inorder")
WORDS_PER_BLOCK = 64
MAXH = 4

RAM = ["80020000", "80030000", "80040000", "80050000"]   # block RAM, one array a hart
SDR = ["90000000", "90010000", "90020000", "90030000"]   # SDRAM

# (case, measured hart, streaming harts, memory of the streamers, the timer's period)
CASES = [
    ("m0 alone", 0, [], "R", PERIOD), ("m0 RRR", 0, [1, 2, 3], "R", PERIOD), ("m0 SSS", 0, [1, 2, 3], "S", PERIOD),
    ("m3 alone", 3, [], "R", PERIOD), ("m3 R", 3, [0], "R", PERIOD), ("m3 S", 3, [0], "S", PERIOD),
    ("m3 RRR", 3, [0, 1, 2], "R", PERIOD), ("m3 SSS", 3, [0, 1, 2], "S", PERIOD),
    # Part 32's period, to tie these figures to Part 32's: the cost of an interrupt should not depend on it
    ("m0 alone 2k", 0, [], "R", 2000),
]
FABRICS = [("bus", []), ("fabric", ["INTERCONNECT=xbar"]),
           ("bypass", ["INTERCONNECT=xbar", "XBAR_NI_BYPASS=1"])]   # rtl/soc/noc_ni_slave.v's BYPASS
if os.environ.get("IRQ4_NOAGE"):
    FABRICS.append(("noage", ["INTERCONNECT=xbar", "XBAR_AGE_LIMIT=0"]))   # the four-hart fabric default is aging on


def clear_builds():
    for f in glob.glob(os.path.join(ROOT, "sim", "*.out")):
        os.remove(f)


def build(extra):
    clear_builds()
    subprocess.run(["make", "-s", "sim/irq4.hex", "sim/sim_soc_4hart_irq.out"] + extra,
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


def run(fabric, case, measured, streamers, memory, period, irq):
    tag = "%s.%s.irq%d" % (fabric, re.sub(r"[^a-z0-9]+", "_", case.lower()), irq)
    mode = sum(1 << h for h in streamers)
    bases = SDR if memory == "S" else RAM
    window = (WINDOW if period == PERIOD else 200000) if irq else WINDOW_OFF
    args = [VVP, "sim_soc_4hart_irq.out", "+measured=%d" % measured, "+mode=%d" % mode, "+irq=%d" % irq,
            "+period=%d" % period, "+window=%d" % window, "+start=%d" % START, "+maxcycles=%d" % MAXCYCLES]
    args += ["+base%d=%s" % (h, bases[h]) for h in range(MAXH)]
    p = subprocess.run(args, cwd=os.path.join(ROOT, "sim"), stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    with open(os.path.join(LOGDIR, tag + ".log"), "w") as f:
        f.write(p.stdout)
    r = {"ok": p.returncode == 0 and "SOC-4HART-IRQ: PASS" in p.stdout, "log": tag + ".log", "streamers": streamers}
    m = re.search(r"IRQ4 measured hart \d+ status=(\d+) passes=(\d+) elapsed=(\d+) start=(\d+) n=(\d+) bad=(\d+)", p.stdout)
    r["passes"], r["elapsed"], r["n"] = (int(m.group(2)), int(m.group(3)), int(m.group(5))) if m else (0, 0, 0)
    rate = 0.0
    r["rates"] = {}
    for h in streamers:
        m = re.search(r"IRQ4 stream hart %d status=(\d+) blocks=(\d+) cycles=(\d+)" % h, p.stdout)
        blocks, cycles = (int(m.group(2)), int(m.group(3))) if m else (0, 0)
        r["rates"][h] = blocks * WORDS_PER_BLOCK * 1000.0 / cycles if cycles else 0.0   # words per thousand cycles
        rate += r["rates"][h]
    r["stream"] = rate
    m = re.search(r"IRQ4 acc0 data=(\d+) fetch=(\d+)", p.stdout)
    r["dacc"], r["facc"] = (int(m.group(1)), int(m.group(2))) if m else (0, 0)   # the measured hart's accesses in its window
    samples = [(int(a), int(b)) for a, b in re.findall(r"IRQ4 s (\d+) (\d+)", p.stdout)]
    r["samples"] = samples[1:]            # the first interrupt of the window may have been pending
    m = re.search(r"IRQ4 delivered n=(\d+) of (\d+) periods", p.stdout)
    r["expected"] = int(m.group(2)) if m else 0
    return r


def run_fabrics(names):
    os.makedirs(LOGDIR, exist_ok=True)
    for fabric, extra in FABRICS:
        if names and fabric not in names:
            continue
        build(extra)
        res = {}
        for case, measured, streamers, memory, period in CASES:
            for irq in (0, 1):
                r = run(fabric, case, measured, streamers, memory, period, irq)
                res["%s|%d" % (case, irq)] = r
                print("  ran %-6s %-9s irq %d: %s" % (fabric, case, irq, "ok" if r["ok"] else
                                                      "FAILED (see %s/%s)" % (LOGDIR, r["log"])), file=sys.stderr)
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


def pct(sorted_vals, q):
    return sorted_vals[min(len(sorted_vals) - 1, (len(sorted_vals) * q) // 100)]


def stats(vals):
    if not vals:
        return (0.0, 0, 0)
    s = sorted(vals)
    return (sum(s) / float(len(s)), pct(s, 90), s[-1])


def report(res):
    fabrics = [f for f, _ in FABRICS if f in res]
    print("Four harts, CORE=%s. Without the interrupt: cycles a pass of the measured hart's loop takes, its accesses on "
          "the interconnect a pass (its 256 loads hit the data cache), and the streamers' words per thousand cycles "
          "(sum)\n" % CORE)
    print("%-7s %-9s %12s %12s %14s" % ("fabric", "case", "cycles/pass", "data/pass", "streamers"))
    for fabric in fabrics:
        for case, _m, _s, _mem, _p in CASES:
            r = res[fabric]["%s|0" % case]
            print("%-7s %-9s %12.1f %12.2f %14.1f%s" % (
                fabric, case, r["elapsed"] / float(r["passes"]) if r["passes"] else 0.0,
                r["dacc"] / float(r["passes"]) if r["passes"] else 0.0, r["stream"], "" if r["ok"] else "   FAILED"))

    print("\nWith the interrupt every %d cycles (%d-cycle window; cycles; the first interrupt left out of lat and done; "
          "'m0 alone 2k' has Part 32's period, 2000, and a 200000-cycle window)\n" % (PERIOD, WINDOW))
    hdr = "%-7s %-9s %9s %9s %9s %19s %19s %6s %10s %9s %9s"
    print(hdr % ("fabric", "case", "delivered", "cost/irq", "work kept", "lat mean(p90,max)", "done mean(p90,max)", "valid",
                 "streamers", "data/irq", "fetch/irq"))
    for fabric in fabrics:
        for case, _m, _s, _mem, _p in CASES:
            off, on = res[fabric]["%s|0" % case], res[fabric]["%s|1" % case]
            c_pass = off["elapsed"] / float(off["passes"]) if off["passes"] else 0.0
            cost = (on["elapsed"] - on["passes"] * c_pass) / float(on["n"]) if on["n"] else 0.0
            # a sample as long as the period is not a latency: the timer's counter wrapped
            per = dict((c[0], c[4]) for c in CASES)[case]
            good = [(a, b) for a, b in on["samples"] if a < per and b < per and b >= a]
            lat = stats([a for a, _ in good])
            dn = stats([b for _, b in good])
            kept = ("%.1f%%" % (100.0 * (on["passes"] / float(on["elapsed"])) / (off["passes"] / float(off["elapsed"])))
                    if off["passes"] and on["elapsed"] else "-")
            slow = "%+.1f%%" % (100.0 * (on["stream"] / off["stream"] - 1)) if off["stream"] else "-"
            # what the measured hart does on the interconnect without the interrupt: data accesses a pass (none on the
            # in-order core, two on the wide one), taken off by the passes, and a handful of instruction fetches once
            # (the loop's code), taken off as they are
            d_pass = off["dacc"] / float(off["passes"]) if off["passes"] else 0.0
            dacc = (on["dacc"] - d_pass * on["passes"]) / float(on["n"]) if on["n"] else 0.0
            facc = (on["facc"] - off["facc"]) / float(on["n"]) if on["n"] else 0.0
            print(hdr % (fabric, case, "%d/%d" % (on["n"], on["expected"]), "%.1f" % cost, kept, "%.1f (%d, %d)" % lat,
                         "%.1f (%d, %d)" % dn, "%d" % len(good), slow, "%.1f" % dacc, "%.1f" % facc)
                  + ("" if on["ok"] and off["ok"] else "   FAILED"))


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
