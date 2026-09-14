#!/usr/bin/env python3
"""Summarize Verilator line/toggle coverage from lcov .info files.

Why a first-party script instead of `verilator_coverage --report ...`: the
.info (lcov) format is a stable, documented, third-party interchange
format - the same reasoning bom/gen_sbom.py and bom/gen_hbom.py already
give for reading pinned-version files and RTL directly rather than
depending on a vendor tool's own report layout. This keeps what CI prints
and what it's allowed to grep entirely under this project's own control,
with no new pip dependency (docs/toolchain.md: Python, standard library
only).

Input: one or more paths to lcov .info files, each produced by
    verilator_coverage --write-info <path> <dat>
(see `make verilator_coverage_report`). Each is expected to contain zero
or more blocks of the form:

    SF:<path to source file>
    DA:<line number>,<hit count>[,<checksum>]
    ...
    end_of_record

Line coverage and toggle coverage are kept apart at the source: this
project builds two separate --coverage-line-only and
--coverage-toggle-only Verilator binaries rather than one combined
--coverage build, specifically because verilator_coverage's own
--filter-type flag (the newer, documented way to split a single combined
.dat by point type) does not exist on Verilator 5.020 - the version
CI's own apt package resolves to (see docs/toolchain.md) - only on newer
ones. Two type-pure .dat files avoids depending on a flag one of the two
toolchains this project runs under does not have.

Output: for each input file, one line per SF: block giving hit/total
lines and a percentage, then an OVERALL line for that file.

This never exits nonzero because a percentage is low - report-only, by
design (docs/toolchain.md): it exits nonzero only if a file is missing,
empty, or does not look like real verilator_coverage output, the same
"a test that cannot fail" concern CONTRIBUTING.md names, applied to a
summarizer instead of a test - one that always looks confident even when
it never actually parsed anything is its own kind of untrustworthy.

Usage: coverage_summary.py <coverage.info> [<coverage2.info> ...]
"""
import sys


def parse_info(path):
    """Return {source_file: (hit_lines, total_lines)} for one .info file."""
    files = {}
    current = None
    hit = total = 0
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if line.startswith("SF:"):
                current = line[3:]
                hit = total = 0
            elif line.startswith("DA:"):
                count = line[3:].split(",")[1]
                total += 1
                if int(count) > 0:
                    hit += 1
            elif line == "end_of_record" and current is not None:
                files[current] = (hit, total)
                current = None
    return files


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for path in sys.argv[1:]:
        files = parse_info(path)
        if not files:
            sys.exit(f"{path}: no SF:/DA: records found - is this a real "
                      f"verilator_coverage --write-info output?")
        print(f"=== {path} ===")
        total_hit = total_lines = 0
        for name in sorted(files):
            hit, total = files[name]
            pct = 100.0 * hit / total if total else 0.0
            print(f"  {name:<55} {hit:>6}/{total:<6} {pct:6.1f}%")
            total_hit += hit
            total_lines += total
        overall = 100.0 * total_hit / total_lines if total_lines else 0.0
        print(f"  {'OVERALL':<55} {total_hit:>6}/{total_lines:<6} {overall:6.1f}%\n")


if __name__ == "__main__":
    main()
