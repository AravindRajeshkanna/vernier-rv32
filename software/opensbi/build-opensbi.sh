#!/bin/sh
# Fetch and build OpenSBI for this core.
#
# STATUS: this builds an OpenSBI that boots on this SoC and hands off to a
# Linux kernel in S-mode. `make sim_opensbi` checks the banner and the
# platform detection. There is no platform port: PLATFORM=generic is entirely
# FDT-driven, so dts/soc.dts *is* the port.
#
# The kernel it hands off to now reaches userspace: `make sim_linux` runs
# Linux 6.18.45 rv32ima through this firmware to a `/init` that prints back
# the ISA string the kernel parsed out of dts/soc.dts.
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

# Where fw_jump hands off, and where it puts the device tree for the next
# stage. Both default, in OpenSBI, to offsets from FW_TEXT_START -
# FW_JUMP_FDT_ADDR is FW_TEXT_START + 0x2200000, which here is 0x9228_0000
# and lands *outside* the 32 MB this SoC decodes. That matters more than it
# looks: `fdt_get_address()` returns the root domain's next_arg1, so OpenSBI
# reads its *own* device tree through that pointer. Pointed at unmapped
# space it reads zeros, fdt_path_offset() returns -FDT_ERR_BADMAGIC, and the
# firmware stops with no console - having been perfectly capable of parsing
# the same tree at its original address minutes earlier.
#
# FW_JUMP_ADDR is fixed by Linux rather than chosen: the rv32 Image header
# asks to run at RAM + 0x400000, because setup_vm() maps the kernel with Sv32
# 4 MB megapages. software/opensbi/mkimage.py reads that field out of the
# built Image and refuses a mismatch.
FW_JUMP_ADDR=${FW_JUMP_ADDR:-0x90400000}

# The device tree has to go *above* the kernel, and this is the second
# address it has been at for a reason that was invisible until a kernel ran.
#
# arch/riscv sets phys_ram_base to the kernel's own load address and drops
# every memory range below it - the boot log says so, "Ignoring memory range
# 0x90000000 - 0x90400000" - so the linear map starts at FW_JUMP_ADDR. A
# device tree below that is in memory the kernel has decided does not exist.
#
# It half works, which is what makes it expensive. The early parse reads the
# blob through the fixmap and succeeds: the machine model, the command line,
# the memory nodes and the reserved regions all come out right. It is
# unflatten_device_tree(), later and through the linear map, that reads
# nothing and fails with "Error -4 processing FDT" - by which point the
# console is up and the failure looks like memory corruption rather than a
# load address.
#
# 0x91E0_0000 is 30 MB into the part, out of the kernel's way, and mirrors
# where QEMU's virt machine puts it (top of RAM minus 2 MB). Anything above
# FW_JUMP_ADDR plus the kernel's runtime size would do.
FW_JUMP_FDT_ADDR=${FW_JUMP_FDT_ADDR:-0x91E00000}

# The generated linker script caches FW_TEXT_START, and `make clean` does not
# remove it - so changing the address without this silently rebuilds at the
# old one. That cost a debugging round: the symbols said 0x9001_0000 after a
# build that had asked for 0x9008_0000.
STAMP="build/.fw_addrs"
WANT="$FW_TEXT_START $FW_JUMP_FDT_ADDR $FW_JUMP_ADDR"
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$WANT" ]; then
    echo "addresses are [$WANT] (were [$(cat "$STAMP" 2>/dev/null || echo none)]) - rebuilding from scratch"
    rm -rf build
fi

make -j4 PLATFORM=generic CROSS_COMPILE="$CROSS" FW_PIC=n \
     PLATFORM_RISCV_XLEN=32 \
     PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei \
     PLATFORM_RISCV_ABI=ilp32 \
     FW_TEXT_START="$FW_TEXT_START" \
     FW_JUMP_FDT_ADDR="$FW_JUMP_FDT_ADDR" \
     FW_JUMP_ADDR="$FW_JUMP_ADDR"

mkdir -p build && printf '%s' "$WANT" > "$STAMP"

echo
echo "built:"
ls -la build/platform/generic/firmware/*.bin | awk '{printf "  %-22s %8.1f KB\n", $9, $5/1024}'
