#!/usr/bin/env python3
# Generates this project's hardware bill of materials as CycloneDX 1.5 JSON:
# every third-party silicon IP primitive the RTL instantiates, plus the
# physical parts needed to reproduce this project on real hardware.
#
# The RTL-primitive half is found, not listed by hand: Lattice's naming
# convention for ECP5 hard primitives is ALL CAPS (EHXPLLL, ODDRX1F, ...),
# distinct from every module this project defines itself. Scanning for an
# instantiated type name that is all-caps and not one of this project's own
# module names finds every primitive automatically, including ones added
# after this script was written - a hand-maintained list would silently
# stop being complete the next time somebody adds a PLL or a serializer and
# forgets to update it here too.
#
# The board-component half cannot be found the same way - there is no
# machine-readable source for "which SDRAM part is on a ULX3S v3.1.4" the
# way there is for a pinned commit. It is transcribed instead from
# docs/toolchain.md §2 (the actual development board's own precise part
# numbers - IS42S16160G-7TL, not just IS42S16160G) for the primary board,
# and fpga/README.md (which documents the alternates this project has
# never had in hand: the 45F, the AS4C32M16) for the rest. bom/test_bom.py
# cross-checks every part number below against whichever of those two
# files actually documents it, so this list cannot drift out of sync with
# either doc without a test noticing.
import argparse
import json
import re
import sys
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

RTL_DIRS = ["rtl", "fpga"]

# Verilog keywords and this project's own port/signal-declaration keywords
# that a naive all-caps-at-line-start scan would otherwise never see
# (SystemVerilog keywords are lowercase, so this is really just guarding
# against a parameter/localparam whose *value* starts the next line) -
# empirically, none of these ever collided in this tree, but the guard
# costs nothing and documents the intent.
NOT_A_PRIMITIVE = {
    "module", "endmodule", "input", "output", "wire", "reg", "parameter",
    "localparam", "assign", "always", "begin", "end", "case", "if", "else",
    "function", "for", "genvar", "generate", "endgenerate", "integer",
}


def local_module_names():
    names = set()
    for d in RTL_DIRS + ["sim", "formal"]:
        for path in (REPO_ROOT / d).rglob("*.v"):
            text = path.read_text()
            for m in re.finditer(r'\bmodule\s+([A-Za-z_][A-Za-z0-9_]*)', text):
                names.add(m.group(1))
    return names


def find_rtl_primitives():
    local = local_module_names()
    hits = {}
    for d in RTL_DIRS:
        for path in (REPO_ROOT / d).rglob("*.v"):
            rel = path.relative_to(REPO_ROOT)
            for lineno, line in enumerate(path.read_text().splitlines(), 1):
                m = re.match(
                    r'^\s*([A-Z][A-Z0-9_]*)\s*(?:#\s*\(|[A-Za-z_][A-Za-z0-9_]*\s*\()',
                    line)
                if not m:
                    continue
                typename = m.group(1)
                if typename in local or typename in NOT_A_PRIMITIVE:
                    continue
                hits.setdefault(typename, []).append(f"{rel}:{lineno}")
    return hits


# name, description, datasheet-ish external reference
PRIMITIVE_INFO = {
    "EHXPLLL": ("Lattice ECP5 hard PLL primitive",
                "https://www.latticesemi.com/view_document?document_id=50464"),
    "ODDRX1F": ("Lattice ECP5 hard DDR output register primitive (1:2 SDR-in, "
                "DDR-out) - used both to drive a real DDR clock output and, "
                "separately, as the TMDS bit serializer's own output stage",
                "https://www.latticesemi.com/view_document?document_id=50464"),
}


def build_rtl_components():
    hits = find_rtl_primitives()
    components = []
    for typename, locations in sorted(hits.items()):
        description, ref = PRIMITIVE_INFO.get(
            typename,
            (f"Lattice ECP5 hard primitive (undocumented in {Path(__file__).name} - "
             "add an entry to PRIMITIVE_INFO)", None))
        component = {
            "type": "library",
            "name": typename,
            "description": description,
            "properties": [
                {"name": "internal:category", "value": "fpga-hard-primitive"},
                {"name": "internal:vendor", "value": "Lattice Semiconductor"},
            ] + [
                {"name": "internal:instantiated-at", "value": loc}
                for loc in locations
            ],
        }
        if ref:
            component["externalReferences"] = [{"type": "documentation", "url": ref}]
        components.append(component)
    return components


# Board components. Each is tagged with the doc section it was
# transcribed from, so bom/test_bom.py can cross-check it against the
# right file rather than assuming one source covers everything.
BOARD_COMPONENTS = [
    {
        "type": "device",
        "name": "ULX3S",
        "description": "Target board for this project - v3.1.8 "
                       "(Radiona/emard, made by Intergalaktik) is the "
                       "specific unit this project has actually run on; "
                       "v1.7, v2.0 and other v3.0.x/v3.1.x revisions also "
                       "appear in this project's own documentation. v1.7's "
                       "SD pins are wired differently and this project's "
                       "own constraints file targets v2.0/v3.0/v3.1.",
        "externalReferences": [{"type": "website",
                                 "url": "https://www.crowdsupply.com/1bitsquared/ulx3s"}],
        "properties": [{"name": "internal:doc-source",
                         "value": "docs/toolchain.md#2-hardware-under-test"}],
    },
    {
        "type": "device",
        "name": "LFE5U-85F",
        "description": "Lattice ECP5 FPGA, CABGA381 package - the part "
                       "on this project's own board, and its primary "
                       "synthesis/place-and-route target (BOARD=ulx3s85).",
        "properties": [{"name": "internal:package", "value": "CABGA381"},
                       {"name": "internal:doc-source",
                        "value": "docs/toolchain.md#2-hardware-under-test"}],
        "externalReferences": [{"type": "documentation",
                                 "url": "https://www.latticesemi.com/Products/FPGAandCPLD/ECP5"}],
    },
    {
        "type": "device",
        "name": "LFE5U-45F",
        "description": "Lattice ECP5 FPGA, CABGA381 package (same as the "
                       "85F) - this project's secondary synthesis/"
                       "place-and-route target (BOARD=ulx3s), measured "
                       "slower Fmax than the 85F but still closes timing. "
                       "Not a board this project has run on; a "
                       "synthesis/timing target only.",
        "properties": [{"name": "internal:package", "value": "CABGA381"},
                       {"name": "internal:doc-source", "value": "fpga/README.md"}],
        "externalReferences": [{"type": "documentation",
                                 "url": "https://www.latticesemi.com/Products/FPGAandCPLD/ECP5"}],
    },
    {
        "type": "device",
        "name": "IS42S16160G-7TL",
        "description": "SDRAM part on this project's own board (ULX3S "
                       "v3.1.8) and standard from v3.1.4 onward - 32 MB, "
                       "16-bit, 4 banks x 8192 rows x 512 columns, which "
                       "is exactly rtl/soc/wb_sdram.v's default "
                       "ROW_BITS=13/COL_BITS=9/BA_BITS=2 geometry.",
        "properties": [{"name": "internal:capacity", "value": "32MB"},
                       {"name": "internal:column-bits", "value": "9"},
                       {"name": "internal:doc-source",
                        "value": "docs/toolchain.md#2-hardware-under-test"}],
    },
    {
        "type": "device",
        "name": "AS4C32M16",
        "description": "SDRAM part on some ULX3S v3.0.x boards, not this "
                       "project's own - 64 MB, 10 column bits, needing a "
                       "non-default rtl/soc/wb_sdram.v configuration. The "
                       "controller stays correct with the wrong value set "
                       "(the mapping stays injective, it just addresses "
                       "half the part), so this is a silent capacity "
                       "loss rather than a failure if missed.",
        "properties": [{"name": "internal:capacity", "value": "64MB"},
                       {"name": "internal:column-bits", "value": "10"},
                       {"name": "internal:doc-source", "value": "fpga/README.md"}],
    },
    {
        "type": "device",
        "name": "ESP32",
        "description": "On-board microcontroller handling the ULX3S's "
                       "own JTAG/USB bridging and board control - "
                       "fpga/ulx3s_top.v must hold wifi_gpio0 high or "
                       "the ESP32 can reset the board underneath a "
                       "running design.",
        "properties": [{"name": "internal:doc-source", "value": "fpga/README.md"}],
    },
    {
        "type": "device",
        "name": "FT231X",
        "description": "On-board FTDI USB-to-serial bridge, 115200 8N1 - "
                       "this project's own console and UART bootloader "
                       "transcripts are captured through it, appearing as "
                       "/dev/cu.usbserial-* on macOS.",
        "properties": [{"name": "internal:doc-source",
                         "value": "docs/toolchain.md#2-hardware-under-test"}],
    },
]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--output", default="-",
                    help="output file, or - for stdout (default)")
    args = ap.parse_args()

    doc = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": f"urn:uuid:{uuid.uuid5(uuid.NAMESPACE_URL, 'vernier-rv32-hbom')}",
        "version": 1,
        "metadata": {
            "component": {
                "type": "firmware",
                "name": "vernier-rv32",
                "description": "An RV32IMA CPU and Wishbone SoC. This "
                                "document lists the third-party silicon "
                                "IP this design instantiates, plus the "
                                "physical parts needed to reproduce it on "
                                "real hardware - not the software this "
                                "project's own build depends on (see "
                                "bom/sbom.json for that).",
            },
        },
        "components": build_rtl_components() + BOARD_COMPONENTS,
    }

    out = json.dumps(doc, indent=2) + "\n"
    if args.output == "-":
        sys.stdout.write(out)
    else:
        Path(args.output).write_text(out)


if __name__ == "__main__":
    main()
