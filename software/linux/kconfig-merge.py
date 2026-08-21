#!/usr/bin/env python3
"""Merge a Kconfig fragment into a .config, and check that it stuck.

This replaces the kernel's own scripts/kconfig/merge_config.sh, which calls
`readlink -m` - a GNU extension that the macOS readlink does not have, and
this project's only development host is macOS. The logic is small enough that
reimplementing it is cheaper than adding coreutils to the toolchain.

Two subcommands, and the second is the one that earns its keep:

    merge <base.config> <fragment> <out.config>
    check <fragment> <final.config>

`merge` writes the union, with the fragment winning, and says so when it
overrides a value the base had set to something else.

`check` runs *after* `make olddefconfig` and re-reads the result. Kconfig
silently drops any symbol whose dependencies are not met - ask for
CONFIG_SERIAL_8250 without CONFIG_TTY and you get no error, you get a kernel
with no console and a boot that stops after OpenSBI. Every option in the
fragment is something this SoC needs, so a dropped one is a build failure
here rather than a silent one later.
"""
import re
import sys

SET   = re.compile(r"^(CONFIG_[A-Za-z0-9_]+)=(.*)$")
UNSET = re.compile(r"^# (CONFIG_[A-Za-z0-9_]+) is not set$")


def parse(path):
    """{symbol: value}, where a disabled symbol's value is None."""
    out = {}
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            m = SET.match(line)
            if m:
                out[m.group(1)] = m.group(2)
                continue
            m = UNSET.match(line)
            if m:
                out[m.group(1)] = None
    return out


def render(sym, val):
    return f"# {sym} is not set" if val is None else f"{sym}={val}"


def merge(base_path, frag_path, out_path):
    base = parse(base_path)
    frag = parse(frag_path)

    for sym, val in frag.items():
        if sym in base and base[sym] != val:
            print(f"  override {sym}: {render(sym, base[sym])} -> "
                  f"{render(sym, val)}", file=sys.stderr)

    # Rewrite the base in place, line for line, so comments and ordering
    # survive; anything the fragment adds is appended.
    written = set()
    lines = []
    with open(base_path) as f:
        for line in f:
            line = line.rstrip("\n")
            m = SET.match(line) or UNSET.match(line)
            sym = m.group(1) if m else None
            if sym in frag and sym not in written:
                lines.append(render(sym, frag[sym]))
                written.add(sym)
            else:
                lines.append(line)

    extra = [s for s in frag if s not in written]
    if extra:
        lines.append("")
        lines.append("# --- merged from the fragment ---")
        lines += [render(s, frag[s]) for s in extra]

    with open(out_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"  merged {len(frag)} options ({len(extra)} new)", file=sys.stderr)


def check(frag_path, final_path):
    frag  = parse(frag_path)
    final = parse(final_path)

    lost = []
    for sym, want in frag.items():
        got = final.get(sym, None)
        if got != want:
            lost.append((sym, want, got))

    if not lost:
        print(f"  all {len(frag)} requested options survived olddefconfig",
              file=sys.stderr)
        return 0

    print("\nKconfig dropped options this SoC needs:\n", file=sys.stderr)
    for sym, want, got in lost:
        print(f"  {sym}: asked for {render(sym, want)!r}, got "
              f"{render(sym, got)!r}", file=sys.stderr)
    print("\nThat almost always means an unmet dependency rather than a typo.",
          file=sys.stderr)
    return 1


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "merge" and len(sys.argv) == 5:
        merge(*sys.argv[2:])
        return 0
    if len(sys.argv) >= 2 and sys.argv[1] == "check" and len(sys.argv) == 4:
        return check(*sys.argv[2:])
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
