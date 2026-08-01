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
SRC=${OPENSBI_SRC:-$(pwd)/build/opensbi}
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

make -j4 PLATFORM=generic CROSS_COMPILE="$CROSS" FW_PIC=n \
     PLATFORM_RISCV_XLEN=32 \
     PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
     PLATFORM_RISCV_ABI=ilp32

echo
echo "built:"
ls -la build/platform/generic/firmware/*.bin | awk '{printf "  %-22s %8.1f KB\n", $9, $5/1024}'
