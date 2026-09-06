#!/usr/bin/env python3
# Directed test for bom/gen_sbom.py and bom/gen_hbom.py.
#
# What would make this a check that cannot fail: asserting only that the
# generators run and produce *some* JSON. Every assertion below instead
# checks a claim that a real regression would actually break - a pin that
# no longer parses, a board component transcribed from fpga/README.md that
# the doc no longer says, a primitive-detection scan that stops finding the
# two primitives this tree is known to instantiate today.
import json
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "bom"))

import gen_sbom  # noqa: E402
import gen_hbom  # noqa: E402

failures = []


def check(name, condition):
    print(f"  {'ok' if condition else 'FAILED'}   {name}")
    if not condition:
        failures.append(name)


def run_generator(module):
    out = subprocess.run([sys.executable, str(REPO_ROOT / "bom" / module)],
                         capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


# ---- Structural validity: both documents are well-formed CycloneDX ----
def check_cyclonedx_shape(doc, label):
    check(f"{label}: bomFormat is CycloneDX", doc.get("bomFormat") == "CycloneDX")
    check(f"{label}: specVersion is 1.5", doc.get("specVersion") == "1.5")
    check(f"{label}: has a metadata.component", "component" in doc.get("metadata", {}))
    check(f"{label}: components is a non-empty list",
          isinstance(doc.get("components"), list) and len(doc["components"]) > 0)
    valid_types = {"application", "framework", "library", "container",
                   "platform", "operating-system", "device", "device-driver",
                   "firmware", "file", "machine-learning-model", "data",
                   "cryptographic-asset"}
    for c in doc["components"]:
        check(f"{label}: {c.get('name')} has a valid component type",
              c.get("type") in valid_types)
        check(f"{label}: {c.get('name')} has a non-empty description",
              bool(c.get("description")))


print("=== SBOM ===")
sbom = run_generator("gen_sbom.py")
check_cyclonedx_shape(sbom, "sbom")

sbom_by_name = {c["name"]: c for c in sbom["components"]}

# Every pin this test checks is re-derived from the actual source file right
# here, not copied from gen_sbom.py's own extraction - a bug shared between
# the generator and this check would otherwise pass silently.
toolchain_yml = (REPO_ROOT / ".github/actions/riscv-toolchain/action.yml").read_text()
expect_gcc = re.search(r"default:\s*([0-9A-Za-z.\-]+)", toolchain_yml).group(1)
check("sbom: riscv-none-elf-gcc-xpack version matches action.yml's own default",
      sbom_by_name.get("riscv-none-elf-gcc-xpack", {}).get("version") == expect_gcc)

ci_yml = (REPO_ROOT / ".github/workflows/ci.yml").read_text()
expect_vale = re.search(r"VALE_VERSION:\s*([0-9.]+)", ci_yml).group(1)
check("sbom: vale version matches ci.yml's own VALE_VERSION",
      sbom_by_name.get("vale", {}).get("version") == expect_vale)

isa_pin = re.search(r'PIN="([0-9a-f]{40})"',
                    (REPO_ROOT / "tests/fetch.sh").read_text()).group(1)
check("sbom: riscv-tests version matches tests/fetch.sh's own PIN",
      sbom_by_name.get("riscv-tests", {}).get("version") == isa_pin)

kver = re.search(r'KVER=\$\{KVER:-([0-9.]+)\}',
                 (REPO_ROOT / "software/linux/build-linux.sh").read_text()).group(1)
check("sbom: linux version matches build-linux.sh's own KVER default",
      sbom_by_name.get("linux", {}).get("version") == kver)

# The two tools this project deliberately does not pin still get *some*
# version recorded, on any machine that has them installed - which this
# repo's own CI/dev environment always does, so their absence here would
# itself be worth noticing.
for name in ("icarus-verilog", "verilator"):
    check(f"sbom: {name} present with a non-empty version",
          bool(sbom_by_name.get(name, {}).get("version")))

print("\n=== HBOM ===")
hbom = run_generator("gen_hbom.py")
check_cyclonedx_shape(hbom, "hbom")

hbom_by_name = {c["name"]: c for c in hbom["components"]}

# RTL primitive detection: assert the two known today are found. Not an
# exhaustive list - a third primitive added later should make this test
# pass with one more component, not fail for being unlisted here.
for prim in ("EHXPLLL", "ODDRX1F"):
    check(f"hbom: {prim} detected as an instantiated hard primitive",
          prim in hbom_by_name)

# Board components: cross-checked against whichever doc each one is
# tagged as transcribed from (gen_hbom.py's own "internal:doc-source"
# property), not just against gen_hbom.py's own BOARD_COMPONENTS list -
# the whole point is to catch this file transcribing something the doc no
# longer says. "#section-anchor" is stripped before reading the file; this
# checks the fact is still in the file, not that the anchor still resolves.
doc_text_cache = {}


def doc_source_text(relpath_with_anchor):
    relpath = relpath_with_anchor.split("#", 1)[0]
    if relpath not in doc_text_cache:
        doc_text_cache[relpath] = (REPO_ROOT / relpath).read_text()
    return doc_text_cache[relpath]


for name in ("ULX3S", "LFE5U-85F", "LFE5U-45F", "IS42S16160G-7TL",
             "AS4C32M16", "ESP32", "FT231X"):
    component = hbom_by_name.get(name)
    check(f"hbom: {name} is in bom/gen_hbom.py's own component list",
          component is not None)
    if component is None:
        continue
    props = {p["name"]: p["value"] for p in component.get("properties", [])}
    source = props.get("internal:doc-source")
    check(f"hbom: {name} has a doc-source property to check against",
          bool(source))
    if source:
        check(f"hbom: {name} still appears in {source}",
              name in doc_source_text(source))

# The primitive-detection scan itself: prove it actually discriminates,
# not just that it happens to find the right two names. A module this
# project defines (all-caps or not) must never be reported as a hard
# primitive - if it were, "detection" would really just be "everything
# uppercase", which would silently start reporting every future SoC
# acronym-named module as fake silicon IP.
local = gen_hbom.local_module_names()
check("hbom: local module names were actually collected",
      len(local) > 50)
hits = gen_hbom.find_rtl_primitives()
check("hbom: no locally-defined module is misreported as a hard primitive",
      not (set(hits) & local))

print(f"\n{'PASS' if not failures else 'FAIL'}: "
      f"{len(failures)} check(s) failed" if failures else "PASS: all checks ok")
sys.exit(1 if failures else 0)
