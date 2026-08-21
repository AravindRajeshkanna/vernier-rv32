#!/bin/sh
# Fetch and build OpenSBI for this core.
#
# STATUS: this script is verified to *build* OpenSBI for rv32ima with the
# riscv64-unknown-elf toolchain. It does NOT yet produce something that boots
# on this SoC - a platform port (console/timer/ipi glue) is still needed. See
# software/opensbi/README.md for exactly what is and isn't done.
#
# The one non-obvious part is the PIE patch below. Modern OpenSBI hard-errors
# unless the linker can create position-independent executables, and the
# bare-metal riscv64-unknown-elf-ld simply cannot ("-pie not supported") - it
# targets ELF rather than Linux. The firmware does not actually need to be
# position-independent for our purposes, so the fix is to make the PIE flags
# conditional on the linker supporting them rather than unconditional, and
# build with FW_PIC=n.
set -eu

REPO=https://github.com/riscv-software-src/opensbi.git
# Pinned so a future upstream change can't silently break the patch below.
COMMIT=${OPENSBI_COMMIT:-c0f87f1}
# Relative to *this script*, not to the caller's working directory. It used to
# be $(pwd)/build/opensbi, which meant running it from the repository root
# cloned a second copy at <repo>/build/opensbi and built that - while every
# other path here, and the Makefile's OPENSBI_FW, still pointed at the copy
# under software/opensbi/. The two then disagreed about FW_TEXT_START and the
# symptom was a rebuild that appeared to do nothing.
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${OPENSBI_SRC:-$HERE/build/opensbi}
CROSS=${CROSS_COMPILE:-riscv64-unknown-elf-}

mkdir -p "$(dirname "$SRC")"
if [ ! -d "$SRC" ]; then
    git clone "$REPO" "$SRC"
    (cd "$SRC" && git checkout "$COMMIT")
fi

cd "$SRC"

# --- PIE patch (idempotent) ---
if ! grep -q "PIE requirement relaxed" Makefile; then
    python3 - <<'PY'
import pathlib, re
p = pathlib.Path("Makefile"); s = p.read_text()
s = re.sub(r"ifneq \(\$\(OPENSBI_LD_PIE\),y\)\n\$\(error [^\n]*\)\nendif",
           "# PIE requirement relaxed: bare-metal riscv64-unknown-elf-ld has no -pie.\n"
           "# The PIE flags are made conditional below instead, giving static firmware.",
           s)
for old, new in [
    ("CFLAGS\t\t+=\t-fPIE -pie",
     "ifeq ($(OPENSBI_LD_PIE),y)\nCFLAGS\t\t+=\t-fPIE -pie\nendif"),
    ("ASFLAGS\t\t+=\t-fPIE",
     "ifeq ($(OPENSBI_LD_PIE),y)\nASFLAGS\t\t+=\t-fPIE\nendif"),
    ("ELFFLAGS\t+=\t-Wl,--no-dynamic-linker -Wl,-pie",
     "ifeq ($(OPENSBI_LD_PIE),y)\nELFFLAGS\t+=\t-Wl,--no-dynamic-linker -Wl,-pie\nendif"),
]:
    s = s.replace(old, new)
p.write_text(s)
PY
    echo "applied PIE patch"
fi

# Where the firmware is linked to run. It must be aligned to the power-of-2
# size of OpenSBI's read-only sections, because its linker script puts the
# read-write ones at the next such boundary and sbi_domain_init() then insists
# (_fw_rw_start - _fw_start) is a power of two with _fw_start aligned to it.
# 0x9001_0000 looks reasonable and produces 0x70000, which is not, and OpenSBI
# then hangs in a `wfi` loop before the console exists. software/opensbi/
# mkimage.py re-checks this against the built ELF so the failure is a build
# error rather than eight million silent cycles.
FW_TEXT_START=${FW_TEXT_START:-0x90080000}

# The generated linker script caches FW_TEXT_START, and `make clean` does not
# remove it - so changing the address without this silently rebuilds at the
# old one. That cost a debugging round: the symbols said 0x9001_0000 after a
# build that had asked for 0x9008_0000.
STAMP="build/.fw_text_start"
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$FW_TEXT_START" ]; then
    echo "FW_TEXT_START is $FW_TEXT_START (was $(cat "$STAMP" 2>/dev/null || echo none)) - rebuilding from scratch"
    rm -rf build
fi

make -j4 PLATFORM=generic CROSS_COMPILE="$CROSS" FW_PIC=n \
     PLATFORM_RISCV_XLEN=32 \
     PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
     PLATFORM_RISCV_ABI=ilp32 \
     FW_TEXT_START="$FW_TEXT_START"

mkdir -p build && printf '%s' "$FW_TEXT_START" > "$STAMP"

echo
echo "built:"
ls -la build/platform/generic/firmware/*.bin | awk '{printf "  %-22s %8.1f KB\n", $9, $5/1024}'
