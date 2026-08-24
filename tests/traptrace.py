#!/usr/bin/env python3
"""Read a +traptrace file, say what each trap was, and diff two runs.

sim/verilator_soc.cpp writes one line per trap:

    cycle pc priv to scause sepc stval mcause mepc mtval satp

`to` is S or M, read out of csr_file.v's own delegation logic. Both CSR sets
are recorded alongside it because only one of them is written by any given
trap, and which one is not visible from the values.

Two wrong ways to decide that, both tried here first. Reading `scause`
unconditionally reports a supervisor store page fault for every machine timer
interrupt that follows one, because the supervisor registers still hold the
last S-trap - that counted one fault as two. Reading "whichever set changed
since the last trap" is also wrong, and less obviously: software writes these
registers. OpenSBI sets `mepc` before every `mret`, so the machine set moves
with no trap involved, and the inference picks the wrong set or reports both.

The fix was to stop inferring. `trap_to_s` is a wire in the hardware that
already answers this, and recording it costs one character per line.

Usage:
    tests/traptrace.py TRACE [--map System.map]        summarize one run
    tests/traptrace.py A B  [--map System.map]         diff two runs
"""
import argparse
import bisect
import sys
from collections import Counter

EXCEPTIONS = {
    0: "instruction address misaligned",
    1: "instruction access fault",
    2: "illegal instruction",
    3: "breakpoint",
    4: "load address misaligned",
    5: "load access fault",
    6: "store/AMO address misaligned",
    7: "store/AMO access fault",
    8: "ecall from U",
    9: "ecall from S",
    11: "ecall from M",
    12: "instruction page fault",
    13: "load page fault",
    15: "store/AMO page fault",
}
INTERRUPTS = {
    1: "supervisor software", 3: "machine software",
    5: "supervisor timer",    7: "machine timer",
    9: "supervisor external", 11: "machine external",
}
PRIV = {0: "U", 1: "S", 3: "M"}


def cause_name(c):
    if c >> 31:
        return INTERRUPTS.get(c & 0x7FFFFFFF, f"interrupt {c & 0x7FFFFFFF}")
    return EXCEPTIONS.get(c, f"exception {c}")


class Symbols:
    """System.map lookup. Absent, every address prints as itself."""

    def __init__(self, path=None):
        self.addrs, self.names = [], []
        if not path:
            return
        rows = []
        for line in open(path):
            f = line.split()
            if len(f) >= 3:
                try:
                    rows.append((int(f[0], 16), f[2]))
                except ValueError:
                    pass
        rows.sort()
        self.addrs = [r[0] for r in rows]
        self.names = [r[1] for r in rows]

    def name(self, addr):
        if not self.addrs:
            return f"0x{addr:08x}"
        i = bisect.bisect_right(self.addrs, addr) - 1
        if i < 0:
            return f"0x{addr:08x}"
        off = addr - self.addrs[i]
        # A "symbol" a long way back is not the function you are in; it is the
        # last one before a hole. Saying so beats naming it confidently.
        if off > 0x10000:
            return f"0x{addr:08x}"
        return f"{self.names[i]}+0x{off:x}" if off else self.names[i]


def load(path):
    """Records, each carrying the set the hardware said the trap wrote."""
    out = []
    for line in open(path):
        if line.startswith("#"):
            continue
        f = line.split()
        if len(f) < 11 or f[4] == "-":     # trailing "csrs unread" record
            continue
        to = f[3]
        base = 4 if to == "S" else 7
        out.append(dict(cycle=int(f[0]), pc=int(f[1], 16), priv=int(f[2]),
                        to=to,
                        cause=int(f[base], 16),
                        epc=int(f[base + 1], 16),
                        tval=int(f[base + 2], 16),
                        satp=int(f[10], 16)))
    return out


def summarize(recs, syms, label):
    exc = [r for r in recs if not (r["cause"] >> 31)]
    print(f"{label}: {len(recs)} traps, "
          f"{len(recs) - len(exc)} interrupts, {len(exc)} exceptions")
    c = Counter((r["to"], r["priv"], r["cause"]) for r in exc)
    for (to, priv, cause), n in sorted(c.items(), key=lambda kv: -kv[1]):
        print(f"    {n:5d}  {PRIV.get(priv, priv)}->{to}  {cause_name(cause)}")
    return exc


def show(r, syms):
    return (f"cycle {r['cycle']:>12}  {PRIV.get(r['priv'], r['priv'])}->"
            f"{r['to']}  {cause_name(r['cause']):<26} "
            f"epc {syms.name(r['epc']):<28} tval 0x{r['tval']:08x}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("traces", nargs="+")
    ap.add_argument("--map", dest="mapfile")
    ap.add_argument("--all", action="store_true",
                    help="list every exception, not just the differing ones")
    args = ap.parse_args()
    syms = Symbols(args.mapfile)

    if len(args.traces) == 1:
        exc = summarize(load(args.traces[0]), syms, args.traces[0])
        if args.all:
            for r in exc:
                print("   ", show(r, syms))
        return 0

    a, b = (load(t) for t in args.traces[:2])
    ea = summarize(a, syms, args.traces[0])
    print()
    eb = summarize(b, syms, args.traces[1])
    print()

    # Interrupts are dropped from the comparison: the two runs take different
    # numbers of cycles for the same instructions, so a timer lands at a
    # different instruction in each and every trace diverges there. That is a
    # property of the clock, not of the core, and comparing on it buries the
    # exceptions - which is what the first attempt at this did.
    def key(r):
        return (r["priv"], r["to"], r["cause"], r["epc"], r["tval"])

    delta = Counter(map(key, ea))
    delta.subtract(Counter(map(key, eb)))

    for title, want_negative in (
            ("in the second run and not the first", True),
            ("in the first run and not the second", False)):
        print(f"=== exceptions {title} ===")
        found = False
        for k, n in sorted(delta.items(), key=lambda kv: kv[1]):
            if (n >= 0) if want_negative else (n <= 0):
                continue
            found = True
            priv, to, cause, epc, tval = k
            print(f"  x{abs(n)}  {PRIV.get(priv, priv)}->{to}  "
                  f"{cause_name(cause)}  at {syms.name(epc)}  "
                  f"tval 0x{tval:08x}")
        if not found:
            print("  (none)")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
