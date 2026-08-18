#!/usr/bin/env python3
"""Co-simulate the RTL against Spike, instruction by instruction.

The ISA tests answer "did the program reach its own pass condition". That is
a coarse check: a core can get the right answer through a wrong sequence, and
a test only catches what it thought to assert. Co-simulation asks a stricter
question - did this core execute *exactly* what the reference model executed,
in the same order, writing the same values.

Both sides are reduced to the same four fields per retired instruction:

    (pc, instruction word, destination register, written value)

Spike supplies them via `--log-commits`; the RTL supplies them via
sim/tracer.v. Neither side's disassembly is parsed or trusted.

Usage:
    tests/cosim.py <test-name> [...]     # names from tests/build/manifest.txt
    tests/cosim.py --all
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(HERE, "build")
SIM = os.path.join(ROOT, "sim", "sim_isa.out")
# Run the simulation through `vvp` rather than executing sim_isa.out directly.
# iverilog gives its output a `#!/path/to/vvp` shebang, which works only if vvp
# is a real binary. In the macOS oss-cad-suite builds it is a bash wrapper, and
# a shebang naming a script is a nested shebang - macOS answers ENOEXEC, so
# co-simulation could not be run locally at all. Every other simulation in the
# tree is already launched as `vvp <image>` (see the Makefile's VVP), so this
# just makes cosim.py agree with the rest.
VVP = os.environ.get("VVP", "vvp")
# zicntr covers cycle/time/instret, which this core implements; Spike makes
# them illegal unless the extension is named, and its default ISA string also
# includes zihpm (hpmcounter3-31), which this core does *not* implement.
ISA = "rv32ima_zicsr_zifencei_zicntr"
RAM_BASE = 0x80000000

# A commit line looks like:
#   core   0: 3 0x80000000 (0x0500006f)
#   core   0: 3 0x80000060 (0x00000293) x5  0x00000000
#   core   0: 3 0x8000010c (0x0182a283) x5  0x80000000 mem 0x00001018
# The leading privilege digit is what distinguishes a commit line from the
# disassembly line that precedes it, so it is required rather than optional.
COMMIT = re.compile(
    r"^core\s+\d+:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)(.*)$")
REGWRITE = re.compile(r"\bx(\d+)\s+0x([0-9a-f]+)")

# Counters legitimately differ between a 5-stage pipeline and a functional
# model: they count real cycles and real retirements, which are properties of
# the microarchitecture rather than of the ISA. Reads of these have their
# *value* exempted from comparison - the instruction itself, its position in
# the stream, and which register it targets are all still checked.
COUNTER_CSRS = {0xB00, 0xB02, 0xB80, 0xB82,
                0xC00, 0xC01, 0xC02, 0xC80, 0xC81, 0xC82}

# Machine identity registers name *which* implementation this is, so they are
# supposed to differ: Spike reports marchid 5, this core reports 0, and the
# spec says 0 means "not implemented". Exempting their values is not papering
# over a mismatch - a mismatch here is the correct answer.
IDENTITY_CSRS = {0xF11, 0xF12, 0xF13}

# Traces that are expected to part company, with the reason. Kept separate
# from tests/expected-failures.txt on purpose: the two lists are genuinely
# different. rv32ui-p-ma_data and rv32mi-p-pmpaddr *fail* their ISA test but
# *match* Spike instruction for instruction, because Spike is configured the
# same way this core is built (no --misaligned, --pmpregions=0) and so takes
# exactly the same traps. That agreement is worth more than the test result:
# it says the behavior is a deliberate configuration choice, not a defect.
EXPECTED_DIVERGENCE = {
    "rv32mi-p-breakpoint":
        "Spike implements debug-spec triggers (tselect/tdata); this core does "
        "not, so the write to tselect traps here and does not there.",
}


def value_exempt(insn):
    if (insn & 0x7F) != 0x73:          # SYSTEM
        return False
    if ((insn >> 12) & 0x7) == 0:      # ECALL/EBREAK/xRET, not a CSR access
        return False
    return (insn >> 20) & 0xFFF in COUNTER_CSRS | IDENTITY_CSRS


def spike_trace(elf, limit):
    """Retired instructions from Spike, starting at the test's entry point."""
    # --pmpregions=0: Spike defaults to 16 PMP regions and this core implements
    # none, so without it the two part company the moment riscv-tests' setup
    # writes pmpaddr0 - Spike executes the write, the RTL takes an
    # illegal-instruction trap, and every instruction after that is offset.
    # Configuring the reference model to the implementation's actual feature
    # set is the point; silently tolerating the divergence would not be.
    out = subprocess.run(
        ["spike", f"--isa={ISA}", "--pmpregions=0",
         "-l", "--log-commits", elf],
        capture_output=True, text=True, timeout=300).stderr

    trace, started = [], False
    for line in out.splitlines():
        m = COMMIT.match(line)
        if not m:
            continue
        pc = int(m.group(1), 16)
        # Spike boots through its own reset ROM at 0x1000 before jumping to
        # the ELF. That ROM is Spike's, not this SoC's, so the comparison
        # starts where both models agree the program starts.
        if not started:
            if pc < RAM_BASE:
                continue
            started = True
        rd, val = None, None
        w = REGWRITE.search(m.group(3))
        if w:
            rd, val = int(w.group(1)), int(w.group(2), 16)
        trace.append((pc, int(m.group(2), 16), rd, val))
        if len(trace) >= limit:
            break
    return trace


def rtl_trace(path):
    trace = []
    with open(path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) != 4:
                continue
            pc, insn, rd, val = parts
            if rd == "-":
                trace.append((int(pc, 16), int(insn, 16), None, None))
            else:
                trace.append((int(pc, 16), int(insn, 16),
                              int(rd[1:]), int(val, 16)))
    return trace


def fmt(entry):
    pc, insn, rd, val = entry
    tail = f"x{rd}=0x{val:08x}" if rd is not None else "(no reg write)"
    return f"pc=0x{pc:08x} insn=0x{insn:08x} {tail}"


def compare(name, rtl, spike):
    n = min(len(rtl), len(spike))
    for i in range(n):
        r, s = rtl[i], spike[i]
        if r[0] != s[0] or r[1] != s[1]:
            return i, "control flow diverged", r, s
        if r[2] != s[2]:
            return i, "different destination register", r, s
        if r[3] != s[3] and not value_exempt(r[1]):
            return i, "different written value", r, s
    if not n:
        return 0, "no instructions traced", None, None
    return None, None, None, None


def run_one(name, verbose=False):
    elf = os.path.join(BUILD, f"{name}.elf")
    hexf = os.path.join(BUILD, f"{name}.hex")
    trace_path = os.path.join(BUILD, f"{name}.trace")
    if not os.path.exists(elf):
        print(f"  {name:<28} SKIP (not built)")
        return True

    tohost = None
    with open(os.path.join(BUILD, "manifest.txt")) as f:
        for line in f:
            parts = line.split()
            if parts and parts[0] == name:
                tohost = parts[1]
    if tohost in (None, "BUILD_FAILED", "NO_TOHOST"):
        print(f"  {name:<28} SKIP (no tohost)")
        return True

    subprocess.run(
        [VVP, SIM, f"+hex={hexf}", f"+tohost={tohost}", f"+trace={trace_path}"],
        cwd=os.path.join(ROOT, "sim"),
        capture_output=True, text=True, timeout=600)

    rtl = rtl_trace(trace_path)
    # Spike is asked for only as many instructions as the RTL actually
    # retired: the RTL stops at the tohost write, while Spike goes on to spin
    # in the test's exit loop, and a length mismatch there is not a bug.
    spike = spike_trace(elf, len(rtl) + 16)

    idx, why, r, s = compare(name, rtl, spike)
    if idx is None:
        if name in EXPECTED_DIVERGENCE:
            print(f"  {name:<28} XMATCH (expected to diverge but did not - "
                  f"remove it from EXPECTED_DIVERGENCE)")
            return False
        print(f"  {name:<28} MATCH ({len(rtl)} instructions)")
        return True

    if name in EXPECTED_DIVERGENCE:
        print(f"  {name:<28} XDIVERGE at {idx} (expected): "
              f"{EXPECTED_DIVERGENCE[name]}")
        return True

    print(f"  {name:<28} DIVERGED at instruction {idx}: {why}")
    if r is not None:
        print(f"      rtl:   {fmt(r)}")
        print(f"      spike: {fmt(s)}")
    for j in range(max(0, idx - 3), idx):
        print(f"      ok  {j}: {fmt(rtl[j])}")
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(SIM):
        sys.exit("sim/sim_isa.out missing - run 'make isa' first")

    names = args.names
    if args.all or not names:
        names = []
        with open(os.path.join(BUILD, "manifest.txt")) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and parts[1] not in (
                        "BUILD_FAILED", "NO_TOHOST"):
                    names.append(parts[0])

    ok = sum(run_one(n) for n in names)
    print()
    print("===================================================")
    print(f"co-simulation vs Spike: {ok}/{len(names)} traces match")
    print("===================================================")
    sys.exit(0 if ok == len(names) else 1)


if __name__ == "__main__":
    main()
