#!/usr/bin/env python3
"""Check that a compiled device tree describes N harts, in the order the hardware numbers them.

dts/soc.dts says in several places that nothing checks its duplicated constants against each other, and
the hart lists are the clearest case. A cpu node's `reg` is the hart ID; the CLINT's and the PLIC's
`interrupts-extended` lists are indexed by position, so a pair swapped by hand compiles, boots, and fails
nothing: a PLIC context that names the wrong hart is only ever read by a driver that routes an interrupt to
that hart, and Linux routes every interrupt to hart 0. This is that check. For N harts it requires

  * cpu@0 .. cpu@N-1 under /cpus, each with reg = its number, status "okay", and an interrupt-controller
    child that has a phandle (and no other cpu node);
  * the CLINT's list to be, hart by hart, (machine software = 3, machine timer = 7) of that hart's
    controller (rtl/clint.v's msip_out[h] and mtip[h]);
  * the PLIC's list to be, hart by hart, (machine external = 11, supervisor external = 9) of that hart's
    controller, so context 2h is hart h's M-mode and 2h+1 its S-mode (rtl/soc/soc_top.v's plic_eip).

`--selftest` compiles the four-hart tree with one mistake at a time and requires each to fail, because a
check that was never seen to fail has not been shown to check anything (docs/practices.md, section 1).

Usage: check_dtb_harts.py HARTS FILE.dtb
       check_dtb_harts.py --selftest [DTS]      (DTS defaults to dts/soc.dts, built with -DDTS_FOUR_HARTS)
"""
import os
import re
import subprocess
import sys
import tempfile

MSIP, MTIP = 3, 7          # machine software / timer interrupt causes
MEI, SEI = 11, 9           # machine / supervisor external interrupt causes


def parse(dts_text):
    """{node path: {property: value text}} for the regular one-property-a-line text dtc prints."""
    props, stack = {}, []
    for raw in dts_text.splitlines():
        line = raw.strip()
        if not line or line.startswith('/dts-v1/'):
            continue
        if line.endswith('{'):
            name = line[:-1].strip()
            stack.append('' if name == '/' else name)
            props.setdefault('/' + '/'.join(n for n in stack if n), {})
        elif line == '};':
            stack.pop()
        else:
            m = re.match(r'([^=;]+?)\s*(?:=\s*(.*))?;$', line)
            if m:
                props['/' + '/'.join(n for n in stack if n)][m.group(1)] = m.group(2) or ''
    return props


def cells(value):
    m = re.match(r'<(.*)>$', value.strip())
    return [int(c, 0) for c in m.group(1).split()] if m else None


def find(props, compat):
    hits = [p for p, d in props.items() if '"%s"' % compat in d.get('compatible', '')]
    return hits[0] if len(hits) == 1 else None


def check(dtb, harts):
    """The list of what is wrong with the blob, empty if nothing is."""
    text = subprocess.run(['dtc', '-I', 'dtb', '-O', 'dts', dtb], capture_output=True, text=True, check=True).stdout
    props = parse(text)
    bad = []

    cpus = sorted(p for p in props if re.fullmatch(r'/cpus/cpu@\d+', p))
    if cpus != ['/cpus/cpu@%d' % h for h in range(harts)]:
        bad.append('cpu nodes are %s, expected cpu@0 to cpu@%d' % ([c.rsplit('/', 1)[1] for c in cpus], harts - 1))
    phandle = {}
    for h in range(harts):
        node = props.get('/cpus/cpu@%d' % h)
        if node is None:
            continue
        if cells(node.get('reg', '')) != [h]:
            bad.append('cpu@%d has reg = %s, expected <%d>' % (h, node.get('reg'), h))
        if node.get('status') != '"okay"':
            bad.append('cpu@%d status is %s' % (h, node.get('status')))
        ph = cells(props.get('/cpus/cpu@%d/interrupt-controller' % h, {}).get('phandle', ''))
        if not ph:
            bad.append('cpu@%d has no interrupt-controller with a phandle' % h)
        else:
            phandle[h] = ph[0]
    if len(set(phandle.values())) != len(phandle):
        bad.append('two harts share an interrupt-controller phandle')
    if bad:
        return bad

    who = {v: k for k, v in phandle.items()}

    def describe(lst):
        return ' '.join('(hart %s cause %d)' % (who.get(lst[i], '?%d' % lst[i]), lst[i + 1]) for i in range(0, len(lst) - 1, 2))

    for name, compat, causes in (('CLINT', 'riscv,clint0', (MSIP, MTIP)), ('PLIC', 'riscv,plic0', (MEI, SEI))):
        node = find(props, compat)
        if node is None:
            bad.append('no single %s node (compatible "%s")' % (name, compat))
            continue
        got = cells(props[node].get('interrupts-extended', ''))
        want = [x for h in range(harts) for x in (phandle[h], causes[0], phandle[h], causes[1])]
        if got != want:
            bad.append('%s interrupts-extended is\n    %s\n  expected\n    %s' % (name, describe(got or []), describe(want)))
    return bad


# One mistake at a time, as edits to the four-hart source after preprocessing. Each must change the text.
MUTANTS = (
    ('PLIC: harts 2 and 3 swapped (supervisor entries)', lambda s: swap(s, '&cpu2_intc 9', '&cpu3_intc 9')),
    ('PLIC: hart 3 listed before hart 2', lambda s: swap(s, '&cpu2_intc 11 &cpu2_intc 9', '&cpu3_intc 11 &cpu3_intc 9')),
    ('PLIC: hart 1\'s machine and supervisor entries swapped', lambda s: s.replace('&cpu1_intc 11 &cpu1_intc 9', '&cpu1_intc 9 &cpu1_intc 11', 1)),
    ('CLINT: hart 1\'s software and timer entries swapped', lambda s: s.replace('&cpu1_intc 3 &cpu1_intc 7', '&cpu1_intc 7 &cpu1_intc 3', 1)),
    ('CLINT: hart 3 names hart 2\'s controller', lambda s: s.replace('&cpu3_intc 3 &cpu3_intc 7', '&cpu2_intc 3 &cpu2_intc 7', 1)),
    ('cpu@3 has the wrong reg', lambda s: s.replace('reg = <3>;', 'reg = <5>;', 1)),
    ('cpu@2 is not "okay"', lambda s: re.sub(r'(cpu2: cpu@2 \{.*?)status = "okay";', r'\1status = "disabled";', s, count=1, flags=re.S)),
)


def swap(text, a, b):
    """Exchange the first occurrences of two strings."""
    assert a in text and b in text and a != b, 'mutation anchor missing: %r / %r' % (a, b)
    return text.replace(a, '\x00', 1).replace(b, a, 1).replace('\x00', b, 1)


def selftest(dts):
    src = subprocess.run(['cc', '-E', '-x', 'assembler-with-cpp', '-P', '-DDTS_FOUR_HARTS', dts],
                         capture_output=True, text=True, check=True).stdout
    failures = 0

    def compile_(text, out):
        subprocess.run(['dtc', '-q', '-I', 'dts', '-O', 'dtb', '-o', out], input=text, text=True, check=True)

    with tempfile.TemporaryDirectory() as tmp:
        good = os.path.join(tmp, 'good.dtb')
        compile_(src, good)
        bad = check(good, 4)
        if bad:
            print('selftest: the unmutated four-hart tree fails:\n  ' + '\n  '.join(bad))
            return 1
        print('selftest: the four-hart tree passes')
        for name, edit in MUTANTS:
            mutated = edit(src)
            if mutated == src:
                print('selftest: FAILED to apply the mutation "%s"' % name)
                failures += 1
                continue
            out = os.path.join(tmp, 'mutant.dtb')
            compile_(mutated, out)
            found = check(out, 4)
            print('selftest: %-62s %s' % (name, 'caught' if found else 'NOT CAUGHT'))
            failures += 0 if found else 1
    return 1 if failures else 0


def main(argv):
    if len(argv) >= 2 and argv[1] == '--selftest':
        return selftest(argv[2] if len(argv) > 2 else 'dts/soc.dts')
    if len(argv) != 3:
        print(__doc__)
        return 2
    harts, dtb = int(argv[1]), argv[2]
    bad = check(dtb, harts)
    if bad:
        print('%s: does not describe %d harts correctly:' % (dtb, harts))
        for b in bad:
            print('  ' + b)
        return 1
    print('%s: describes %d harts, in order (cpu nodes, CLINT, PLIC)' % (dtb, harts))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
