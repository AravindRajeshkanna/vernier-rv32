#!/usr/bin/env python3
# Generates this project's software bill of materials as CycloneDX 1.5 JSON.
#
# Every pinned version below is *extracted* from the file that actually pins
# it - tests/fetch.sh's own PIN=, .github/actions/riscv-toolchain/action.yml's
# own default version input, and so on - rather than duplicated by hand into
# this script. A hand-copied second location is exactly the kind of duplicated
# constant this project's own PR checklist asks for a comment on both sides
# of; parsing the original instead means there is only one place to update
# a pin, and this file cannot go stale by omission the way a copy could.
#
# Icarus Verilog and Verilator are deliberately *not* pinned anywhere in this
# repo (see .github/actions/verilator/action.yml's own reasoning: nothing
# about the result depends on Verilator's version, so pinning it would only
# be cargo-culting a number nothing checks). Their versions here are
# whatever is actually on PATH when this script runs, captured live rather
# than invented - if neither is installed, the component is simply omitted,
# not guessed at.
import argparse
import json
import re
import subprocess
import sys
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def read(relpath):
    return (REPO_ROOT / relpath).read_text()


def extract(pattern, text, relpath, group=1):
    m = re.search(pattern, text)
    if not m:
        raise RuntimeError(
            f"could not find {pattern!r} in {relpath} - "
            "has the file's own format changed?")
    return m.group(group)


def tool_version(argv):
    """Live version string from an installed tool, or None if it is not on
    PATH. Never raises - a missing tool is an omission, not a script error,
    since bom/test_bom.py is what asserts which tools CI's own environment
    is expected to actually have."""
    try:
        out = subprocess.run(argv, capture_output=True, text=True,
                              timeout=10, check=False)
    except FileNotFoundError:
        return None
    text = (out.stdout + out.stderr).strip()
    return text.splitlines()[0] if text else None


def git_pin_component(relpath, name, description):
    text = read(relpath)
    repo = extract(r'REPO=["\']?([^\s"\']+)', text, relpath)
    pin = extract(r'PIN=["\']([0-9a-f]{40})["\']', text, relpath)
    return {
        "type": "library",
        "name": name,
        "version": pin,
        "description": description,
        "externalReferences": [{"type": "vcs", "url": repo}],
        "properties": [
            {"name": "internal:pin-source", "value": relpath},
            {"name": "internal:vendoring", "value": "fetched-not-vendored"},
        ],
    }


def build_components():
    components = []

    # ---- The RISC-V toolchain: xPack's riscv-none-elf-gcc ----
    text = read(".github/actions/riscv-toolchain/action.yml")
    version = extract(r"version:\s*\n\s*description:[^\n]*\n\s*required:"
                       r"[^\n]*\n\s*default:\s*([0-9A-Za-z.\-]+)",
                       text, ".github/actions/riscv-toolchain/action.yml")
    components.append({
        "type": "application",
        "name": "riscv-none-elf-gcc-xpack",
        "version": version,
        "description": "Bare-metal RISC-V toolchain (rv32im/ilp32 newlib-nano "
                        "multilib) used to build every firmware program this "
                        "project's CI compiles.",
        "purl": f"pkg:github/xpack-dev-tools/riscv-none-elf-gcc-xpack@v{version}",
        "externalReferences": [{
            "type": "distribution",
            "url": f"https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/tag/v{version}",
        }],
        "properties": [{"name": "internal:pin-source",
                         "value": ".github/actions/riscv-toolchain/action.yml"}],
    })

    # ---- oss-cad-suite: yosys, yosys-smtbmc, z3, nextpnr-ecp5 ----
    text = read(".github/actions/oss-cad-suite/action.yml")
    version = extract(r"version:\s*\n\s*description:[^\n]*\n\s*required:"
                       r"[^\n]*\n\s*default:\s*'?([0-9\-]+)'?",
                       text, ".github/actions/oss-cad-suite/action.yml")
    components.append({
        "type": "application",
        "name": "oss-cad-suite",
        "version": version,
        "description": "YosysHQ's bundled build of yosys, yosys-smtbmc, z3 "
                        "and nextpnr-ecp5, used for this project's formal "
                        "verification flow and real FPGA synthesis.",
        "purl": f"pkg:github/YosysHQ/oss-cad-suite-build@{version}",
        "externalReferences": [{
            "type": "distribution",
            "url": f"https://github.com/YosysHQ/oss-cad-suite-build/releases/tag/{version}",
        }],
        "properties": [{"name": "internal:pin-source",
                         "value": ".github/actions/oss-cad-suite/action.yml"}],
    })

    # ---- Vale, installed directly from a release asset in ci.yml ----
    text = read(".github/workflows/ci.yml")
    version = extract(r"VALE_VERSION:\s*([0-9.]+)", text,
                       ".github/workflows/ci.yml")
    components.append({
        "type": "application",
        "name": "vale",
        "version": version,
        "description": "Prose linter for this project's documentation, "
                        "gated in CI's own lint job.",
        "purl": f"pkg:github/errata-ai/vale@v{version}",
        "externalReferences": [{
            "type": "distribution",
            "url": f"https://github.com/errata-ai/vale/releases/tag/v{version}",
        }],
        "properties": [{"name": "internal:pin-source",
                         "value": ".github/workflows/ci.yml"}],
    })

    # ---- markdownlint-cli2, pinned in the Makefile's own npx invocation ----
    text = read("Makefile")
    version = extract(r"npx --yes markdownlint-cli2@([0-9.]+)", text,
                       "Makefile")
    components.append({
        "type": "application",
        "name": "markdownlint-cli2",
        "version": version,
        "description": "Markdown structure linter, gated in CI's own lint "
                        "job.",
        "purl": f"pkg:npm/markdownlint-cli2@{version}",
        "properties": [{"name": "internal:pin-source", "value": "Makefile"}],
    })

    # ---- Fetched-not-vendored upstream test/benchmark suites ----
    components.append(git_pin_component(
        "tests/fetch.sh", "riscv-tests",
        "RISC-V architectural test suite, pinned so a regression can never "
        "be explained away by 'upstream changed'."))
    components.append(git_pin_component(
        "software/bench/fetch-coremark.sh", "coremark",
        "EEMBC's CoreMark benchmark, pinned so a cycle-count regression "
        "can never be explained away by 'upstream changed'."))

    # ---- OpenSBI: pinned commit, not fetched by CI (needs the network) ----
    text = read("software/opensbi/build-opensbi.sh")
    repo = extract(r'REPO=([^\s"\']+)', text,
                    "software/opensbi/build-opensbi.sh")
    commit = extract(r'COMMIT=\$\{OPENSBI_COMMIT:-([0-9a-f]+)\}', text,
                      "software/opensbi/build-opensbi.sh")
    components.append({
        "type": "application",
        "name": "opensbi",
        "version": commit,
        "description": "M-mode firmware this SoC hands off to; built from "
                        "source, not run by CI (needs the network - see "
                        "CONTRIBUTING.md).",
        "externalReferences": [{"type": "vcs", "url": repo}],
        "properties": [{"name": "internal:pin-source",
                         "value": "software/opensbi/build-opensbi.sh"}],
    })

    # ---- Linux kernel: pinned release tarball, not built by CI ----
    text = read("software/linux/build-linux.sh")
    kver = extract(r'KVER=\$\{KVER:-([0-9.]+)\}', text,
                    "software/linux/build-linux.sh")
    components.append({
        "type": "application",
        "name": "linux",
        "version": kver,
        "description": "The kernel this SoC boots to userspace; built from "
                        "source, not run by CI (needs the network).",
        "purl": f"pkg:generic/linux@{kver}",
        "externalReferences": [{
            "type": "distribution",
            "url": f"https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-{kver}.tar.xz",
        }],
        "properties": [{"name": "internal:pin-source",
                         "value": "software/linux/build-linux.sh"}],
    })

    # ---- Deliberately unpinned, captured live ----
    iv = tool_version(["iverilog", "-V"])
    if iv:
        m = re.search(r"version\s+([0-9][0-9A-Za-z.\-]*)", iv)
        components.append({
            "type": "application",
            "name": "icarus-verilog",
            "version": m.group(1) if m else iv,
            "description": "Primary Verilog simulator for this project's "
                            "own gates - installed via apt with no version "
                            "pin (docs/toolchain.md has the reasoning); "
                            "recorded here as whatever this run actually "
                            "used, not a promise about any other run.",
            "properties": [
                {"name": "internal:pinning", "value": "unpinned"},
                {"name": "internal:full-version-string", "value": iv},
            ],
        })
    vl = tool_version(["verilator", "--version"])
    if vl:
        m = re.search(r"Verilator\s+([0-9][0-9A-Za-z.\-]*)", vl)
        components.append({
            "type": "application",
            "name": "verilator",
            "version": m.group(1) if m else vl,
            "description": "Cross-checked against Icarus Verilog's own "
                            "result (make verilator_check); deliberately "
                            "unpinned since nothing about the result "
                            "depends on its version.",
            "properties": [
                {"name": "internal:pinning", "value": "unpinned"},
                {"name": "internal:full-version-string", "value": vl},
            ],
        })

    return components


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", default="-",
                    help="output file, or - for stdout (default)")
    args = ap.parse_args()

    doc = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, 'vernier-rv32-sbom')}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "firmware",
                "name": "vernier-rv32",
                "description": "An RV32IMA CPU and Wishbone SoC. This "
                                "document lists the software this "
                                "project's own build and CI pipeline "
                                "depends on - the toolchains, fetched test "
                                "suites, and firmware it builds against - "
                                "not the RTL/hardware this project itself "
                                "is (see bom/hbom.json for that).",
            },
        },
        "components": build_components(),
    }

    out = json.dumps(doc, indent=2) + "\n"
    if args.output == "-":
        sys.stdout.write(out)
    else:
        Path(args.output).write_text(out)


if __name__ == "__main__":
    main()
