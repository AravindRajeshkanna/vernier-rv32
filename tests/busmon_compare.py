#!/usr/bin/env python3
"""Compare the bus monitor's report from the Icarus run (sim/bus_monitor.v)
with the one from the Verilator harness (+busmon) on the same program.

The two cannot agree to the cycle: Icarus samples each signal just before the
clock edge and the harness just after it, and the runs end a different number
of cycles after the program finishes. So everything is compared as a share of
the run's cycles, within a tolerance, and what has to match exactly is which
masters and slaves appear at all.

Usage: busmon_compare.py ICARUS_LOG VERILATOR_LOG [TOLERANCE_PERCENTAGE_POINTS]
"""
import re
import sys

MASTER = re.compile(r'^\s+(fetch|data|walker|debug|npu dma)\s+(-?\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+[\d.]+%')
SLAVE = re.compile(r'slave (\d+) strobe up:\s+(\d+) cycles')
TOTAL = re.compile(r'bus monitor[^(]*\((\d+) cycles\)')
BUSY = re.compile(r'bus in use:\s+(\d+) cycles')
CONT = re.compile(r'in use with a master waiting:\s+(\d+) cycles')


def parse(path):
    # The last report in the file: the Verilator run may print windows first.
    text = open(path, errors='replace').read()
    start = max(text.rfind('---- bus monitor'), 0)
    text = text[start:]
    total = int(TOTAL.search(text).group(1))
    d = {'busy': int(BUSY.search(text).group(1)) / total * 100,
         'contended': int(CONT.search(text).group(1)) / total * 100}
    for line in text.splitlines():
        m = MASTER.match(line)
        if m:
            name, hart = m.group(1), m.group(2)
            for col, v in zip(('asked', 'granted', 'waited'), m.groups()[2:]):
                d[f'{name} {hart} {col}'] = int(v) / total * 100
        m = SLAVE.search(line)
        if m:
            d[f'slave {m.group(1)}'] = int(m.group(2)) / total * 100
    return total, d


def main():
    tol = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    ti, a = parse(sys.argv[1])
    tv, b = parse(sys.argv[2])
    bad = 0
    print(f'icarus {ti} cycles, verilator {tv} cycles; tolerance {tol} percentage points of the run')
    for k in sorted(set(a) | set(b)):
        if k not in a or k not in b:
            print(f'  MISMATCH {k}: only in {"icarus" if k in a else "verilator"}')
            bad += 1
            continue
        diff = abs(a[k] - b[k])
        flag = 'ok   ' if diff <= tol else 'FAIL '
        if diff > tol:
            bad += 1
        print(f'  {flag}{k:28s} icarus {a[k]:7.3f}%  verilator {b[k]:7.3f}%  diff {diff:.3f}')
    print('BUSMON CHECK PASSED' if not bad else f'BUSMON CHECK FAILED ({bad})')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
