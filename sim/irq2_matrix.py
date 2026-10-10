#!/usr/bin/env python3
"""Interrupt service on hart 0 while hart 1 streams through memory, over the bus and over the router
fabric (Phase 8 Stage 3, Part 32).

Builds sim/sim_soc_2hart_irq.out once per interconnect (the bus, the router fabric, and the router
fabric with the slave interfaces' bypass), then runs three cases, each with hart 0's timer interrupt
off and on, and prints what the programs measure of themselves:

    alone   hart 1 parked
    split   hart 1 streams an array in SDRAM; hart 0's loop, stack and counters are in block RAM
    same    hart 1 streams an array in block RAM, the memory hart 0 uses

For every case it works out what the interrupts cost hart 0 (cycles an interrupt: the cycles the
interrupted passes took beyond what the same number takes uninterrupted, over the interrupts taken),
how long an interrupt took to reach the timer (lat) and to be served (done), and how much the
interrupts slowed hart 1. See sim/tb_soc_2hart_irq.v and software/bench/irq2.S. CORE=ooo runs the wide
core. `make` does not know that a different INTERCONNECT needs a different build, so the built
simulations are cleared before each build. Eighteen simulations a core, a minute or two each.
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.environ.get("IRQ2_LOG", "/tmp/irq2_matrix")
VVP = os.environ.get("VVP", "vvp")
WINDOW = int(os.environ.get("IRQ2_WINDOW", "200000"))
PERIOD = int(os.environ.get("IRQ2_PERIOD", "2000"))
WORDS_PER_BLOCK = 64

RAM_B, SD_A = "80020000", "90000000"

# (case, mode, base1)
CASES = [("alone", 0, RAM_B), ("split", 2, SD_A), ("same", 2, RAM_B)]
FABRICS = [("bus", []), ("fabric", ["INTERCONNECT=xbar"]),
           ("bypass", ["INTERCONNECT=xbar", "XBAR_NI_BYPASS=1"])]   # rtl/soc/noc_ni_slave.v's BYPASS
if os.environ.get("IRQ2_QOS"):
    FABRICS.append(("qos", ["INTERCONNECT=xbar", "IRQ2_DEFS=-DXBAR_QOS"]))


def clear_builds():
    for f in glob.glob(os.path.join(ROOT, "sim", "*.out")):
        os.remove(f)


def build(extra):
    clear_builds()
    subprocess.run(["make", "-s", "sim/irq2.hex", "sim/sim_soc_2hart_irq.out"] + extra,
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


def run(fabric, case, mode, base1, irq):
    name = "%s.%s.irq%d" % (fabric, case, irq)
    args = [VVP, "sim_soc_2hart_irq.out", "+mode=%d" % mode, "+irq=%d" % irq, "+period=%d" % PERIOD,
            "+base1=" + base1, "+window=%d" % WINDOW, "+maxcycles=4000000"]
    p = subprocess.run(args, cwd=os.path.join(ROOT, "sim"), stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True)
    with open(os.path.join(LOGDIR, name + ".log"), "w") as f:
        f.write(p.stdout)
    r = {"ok": p.returncode == 0 and "SOC-2HART-IRQ: PASS" in p.stdout, "log": name + ".log"}
    m = re.search(r"IRQ2 hart0 status=(\d+) passes=(\d+) elapsed=(\d+) start=(\d+) n=(\d+) bad=(\d+)", p.stdout)
    r["passes"], r["elapsed"], r["n"] = (int(m.group(2)), int(m.group(3)), int(m.group(5))) if m else (0, 0, 0)
    m = re.search(r"IRQ2 hart1 status=(\d+) blocks=(\d+) cycles=(\d+)", p.stdout)
    blocks, cycles = (int(m.group(2)), int(m.group(3))) if m else (0, 0)
    r["h1"] = blocks * WORDS_PER_BLOCK * 1000.0 / cycles if cycles else 0.0   # words per thousand cycles
    m = re.search(r"IRQ2 acc0 data=(\d+) fetch=(\d+)", p.stdout)
    r["dacc"], r["facc"] = (int(m.group(1)), int(m.group(2))) if m else (0, 0)   # hart 0's accesses in its window
    samples = [(int(a), int(b)) for a, b in re.findall(r"IRQ2 s (\d+) (\d+)", p.stdout)]
    r["samples"] = samples[1:]            # the first interrupt of the window may have been pending
    return r


def pct(sorted_vals, q):
    return sorted_vals[min(len(sorted_vals) - 1, (len(sorted_vals) * q) // 100)]


def stats(vals):
    if not vals:
        return (0.0, 0, 0)
    s = sorted(vals)
    return (sum(s) / float(len(s)), pct(s, 90), s[-1])


def main():
    os.makedirs(LOGDIR, exist_ok=True)
    res = {}
    for fabric, extra in FABRICS:
        build(extra)
        for case, mode, base1 in CASES:
            for irq in (0, 1):
                r = run(fabric, case, mode, base1, irq)
                res[(fabric, case, irq)] = r
                print("  ran %-6s %-5s irq %d: %s" % (fabric, case, irq,
                                                      "ok" if r["ok"] else "FAILED (see %s/%s)" % (LOGDIR, r["log"])),
                      file=sys.stderr)
    clear_builds()

    print("Without the interrupt: cycles a pass of hart 0's loop takes, its accesses on the interconnect a pass (its 256 loads hit the data cache), and hart 1's words per thousand cycles\n")
    print("%-7s %-7s %12s %12s %12s" % ("fabric", "case", "cycles/pass", "data/pass", "hart 1 rate"))
    for fabric, _ in FABRICS:
        for case, _m, _b in CASES:
            r = res[(fabric, case, 0)]
            print("%-7s %-7s %12.1f %12.2f %12.1f%s" % (fabric, case, r["elapsed"] / float(r["passes"]) if r["passes"] else 0.0,
                                                        r["dacc"] / float(r["passes"]) if r["passes"] else 0.0,
                                                        r["h1"], "" if r["ok"] else "   FAILED"))

    print("\nWith the interrupt every %d cycles (n interrupts in a %d-cycle window; cycles; the first interrupt left out of lat and done)\n"
          % (PERIOD, WINDOW))
    hdr = "%-7s %-7s %4s %9s %17s %17s %10s %9s %9s"
    print(hdr % ("fabric", "case", "n", "cost/irq", "lat mean(p90,max)", "done mean(p90,max)", "hart 1 rate",
                 "data/irq", "fetch/irq"))
    for fabric, _ in FABRICS:
        for case, _m, _b in CASES:
            off, on = res[(fabric, case, 0)], res[(fabric, case, 1)]
            c_pass = off["elapsed"] / float(off["passes"]) if off["passes"] else 0.0
            cost = (on["elapsed"] - on["passes"] * c_pass) / float(on["n"]) if on["n"] else 0.0
            lat = stats([a for a, _ in on["samples"]])
            dn = stats([b for _, b in on["samples"]])
            slow = "%+.1f%%" % (100.0 * (on["h1"] / off["h1"] - 1)) if off["h1"] else "-"
            # hart 0's accesses beyond what it makes uninterrupted (its loop's loads hit the data cache, so that is
            # nearly none), per interrupt
            d_rate = off["dacc"] / float(off["elapsed"]) if off["elapsed"] else 0.0
            f_rate = off["facc"] / float(off["elapsed"]) if off["elapsed"] else 0.0
            dacc = (on["dacc"] - d_rate * on["elapsed"]) / float(on["n"]) if on["n"] else 0.0
            facc = (on["facc"] - f_rate * on["elapsed"]) / float(on["n"]) if on["n"] else 0.0
            print(hdr % (fabric, case, on["n"], "%.1f" % cost,
                         "%.1f (%d, %d)" % lat, "%.1f (%d, %d)" % dn, slow, "%.1f" % dacc, "%.1f" % facc)
                  + ("" if on["ok"] and off["ok"] else "   FAILED"))

    failed = [k for k, v in res.items() if not v["ok"]]
    if failed:
        print("\n%d run(s) FAILED: %s" % (len(failed), ", ".join("%s/%s/irq%d" % k for k in failed)))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
