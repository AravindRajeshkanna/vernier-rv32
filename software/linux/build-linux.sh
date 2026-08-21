#!/bin/sh
# Fetch, configure and build an rv32ima Linux with an initramfs for this SoC.
#
# What comes out: $HERE/build/Image, a flat kernel with the initramfs in
# software/linux/initramfs/ built into it, checked against the instruction
# set rtl/ actually implements. `make linuximage` packs it with OpenSBI into
# an SDRAM image and `make sim_linux` boots that.
#
# Not part of `make verify`, for the same reason OpenSBI is not: it needs a
# 150 MB tarball off the network, and a network is not a build dependency
# this project is willing to have.
#
# ---- The macOS problem, and why it is solved here rather than in a VM ----
#
# The only development host this project has is macOS (docs/toolchain.md), and
# the Linux kernel does not build there out of the box. Everything below is a
# specific, named incompatibility rather than a guess, because each one cost a
# round to find:
#
#   1. The kernel source has files whose names differ only in case
#      (include/uapi/linux/netfilter/xt_CONNMARK.h and xt_connmark.h, and four
#      more pairs). Extracting onto the default case-insensitive APFS loses
#      one of each - silently. So the tree goes on a case-sensitive disk
#      image, created here.
#   2. macOS has no <elf.h>, <byteswap.h> or <endian.h>. The first comes from
#      the cross toolchain's own sysroot; the other two are four lines each
#      over <libkern/OSByteOrder.h>.
#   3. scripts/mod/file2alias.c defines its own `uuid_t`, and the macOS SDK
#      has already typedef'd that name to `unsigned char[16]`. -D_UUID_T
#      suppresses the SDK's, which then breaks <unistd.h> because
#      gethostuuid()'s prototype needs it - so an empty <gethostuuid.h>
#      shadows the SDK header.
#   4. arch/riscv/kernel/vdso/gen_vdso_offsets.sh uses `sed -e 's/[0]\+...'`.
#      BSD sed has no \+, so it matches nothing, and the generated
#      vdso-offsets.h comes out *empty* rather than wrong - the build then
#      fails compiling signal.c with an undeclared __vdso_rt_sigreturn_offset,
#      several thousand lines from the cause. GNU sed goes on PATH.
#   5. riscv64-unknown-elf-ld cannot link `-shared`, which the vDSO needs.
#      Same shape as the -pie problem in software/opensbi/build-opensbi.sh and
#      the same cause: a bare-metal linker targeting ELF rather than Linux.
#      LLVM's ld.lld can, and the kernel supports LD=ld.lld with GCC.
#   6. usr/gen_init_cpio calls copy_file_range(2) and opens with O_LARGEFILE,
#      both Linux-only. usr/Makefile passes a .cpio file straight through
#      without building that tool at all, so software/linux/mkcpio.py writes
#      the archive instead and the host program never gets compiled.
#
# On a Linux host, 1 and 4 do not apply and the rest are harmless.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

KVER=${KVER:-6.18.45}
KSHA=30fa4a56579ca614ac125a12614f7f6466f87ab1278aef7b951dd74156deab33
KURL=https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz

CROSS=${CROSS_COMPILE:-riscv64-unknown-elf-}
JOBS=${JOBS:-8}

# GNU make. macOS ships 3.81, which the kernel refuses.
MAKE=make
command -v gmake >/dev/null 2>&1 && MAKE=gmake

say() { printf '\n=== %s ===\n' "$1"; }

# ---- 1. a workspace the kernel source can survive being extracted into ----
say "workspace"
WORK=${LINUX_WORKDIR:-}
if [ -z "$WORK" ]; then
    # Case-sensitivity is a property of the filesystem, so test it rather
    # than testing for macOS: a case-sensitive Mac needs no disk image and a
    # case-insensitive Linux mount would need one.
    probe=$(mktemp -d)
    : > "$probe/CaSe"
    if [ -e "$probe/case" ]; then
        rm -rf "$probe"
        WORK=/Volumes/vernier-linux
        IMG=${LINUX_SPARSEIMAGE:-/tmp/vernier-linux.sparseimage}
        if [ ! -d "$WORK" ]; then
            [ -f "$IMG" ] || hdiutil create -type SPARSE -fs 'Case-sensitive APFS' \
                -size 24g -volname vernier-linux "${IMG%.sparseimage}" >/dev/null
            hdiutil attach "$IMG" >/dev/null
        fi
        echo "  case-insensitive filesystem: building on $WORK ($IMG)"
    else
        rm -rf "$probe"
        WORK=$HERE/build/work
        mkdir -p "$WORK"
        echo "  case-sensitive filesystem: building in $WORK"
    fi
fi
SRC=$WORK/linux-$KVER
OUT=$WORK/obj
mkdir -p "$OUT" "$WORK/staging" "$WORK/hostinc" "$WORK/hostbin"

# ---- 2. the source ----
if [ ! -d "$SRC" ]; then
    say "fetching linux $KVER"
    TAR=$WORK/linux-$KVER.tar.xz
    [ -f "$TAR" ] || curl -sSL --fail -o "$TAR" "$KURL"
    echo "$KSHA  $TAR" | shasum -a 256 -c - || {
        echo "checksum mismatch - refusing to build an unverified kernel"; exit 1; }
    tar xf "$TAR" -C "$WORK"
fi

# ---- 3. host shims ----
say "host shims"
cp "$("$CROSS"gcc -print-sysroot)/include/elf.h" "$WORK/hostinc/elf.h"
cat > "$WORK/hostinc/byteswap.h" <<'EOF'
/* glibc's, over the macOS equivalents. */
#ifndef _VERNIER_BYTESWAP_H
#define _VERNIER_BYTESWAP_H
#include <libkern/OSByteOrder.h>
#define bswap_16(x) OSSwapInt16(x)
#define bswap_32(x) OSSwapInt32(x)
#define bswap_64(x) OSSwapInt64(x)
#endif
EOF
cat > "$WORK/hostinc/endian.h" <<'EOF'
/* glibc's, over the macOS equivalents. */
#ifndef _VERNIER_ENDIAN_H
#define _VERNIER_ENDIAN_H
#include <machine/endian.h>
#include <libkern/OSByteOrder.h>
#define htobe16(x) OSSwapHostToBigInt16(x)
#define htole16(x) OSSwapHostToLittleInt16(x)
#define be16toh(x) OSSwapBigToHostInt16(x)
#define le16toh(x) OSSwapLittleToHostInt16(x)
#define htobe32(x) OSSwapHostToBigInt32(x)
#define htole32(x) OSSwapHostToLittleInt32(x)
#define be32toh(x) OSSwapBigToHostInt32(x)
#define le32toh(x) OSSwapLittleToHostInt32(x)
#define htobe64(x) OSSwapHostToBigInt64(x)
#define htole64(x) OSSwapHostToLittleInt64(x)
#define be64toh(x) OSSwapBigToHostInt64(x)
#define le64toh(x) OSSwapLittleToHostInt64(x)
#endif
EOF
cat > "$WORK/hostinc/gethostuuid.h" <<'EOF'
/* Shadows the macOS SDK header. It exists only to declare gethostuuid(),
 * whose prototype needs the SDK's uuid_t - and suppressing that typedef with
 * -D_UUID_T is what lets scripts/mod/file2alias.c define its own. Nothing in
 * a kernel build calls gethostuuid(). */
EOF
if command -v gsed >/dev/null 2>&1; then
    ln -sf "$(command -v gsed)" "$WORK/hostbin/sed"
fi
PATH="$WORK/hostbin:$PATH"
export PATH

# Checked rather than assumed, because the failure it prevents is the worst
# kind: BSD sed treats \+ as a literal plus, so the vDSO offset generator
# matches nothing and writes an *empty* include/generated/vdso-offsets.h. The
# build then gets several thousand lines further and fails compiling signal.c
# against an undeclared __vdso_rt_sigreturn_offset.
if ! printf 'aaa\n' | sed -n -e 's/^a\+$/ok/p' | grep -q ok; then
    echo "error: sed does not support \\+ (BSD sed)." >&2
    echo "  The kernel's riscv vDSO build needs GNU sed. Install it -" >&2
    echo "  'brew install gnu-sed' - and this script will put it on PATH." >&2
    exit 1
fi

# A function rather than a variable: HOSTCFLAGS is several flags that have to
# reach make as *one* argument, and a variable expanded unquoted would split
# them into separate ones (silently - make would take -D_UUID_T as a target).
kmake() {
    "$MAKE" ARCH=riscv CROSS_COMPILE="$CROSS" LD=ld.lld O="$OUT" \
        HOSTCFLAGS="-I$WORK/hostinc -D_UUID_T -Wno-unused-command-line-argument" \
        "$@"
}

# ---- 4. /init and the initramfs ----
say "initramfs"
$CROSS"gcc" -march=rv32ima -mabi=ilp32 -mno-relax -Os -ffreestanding -fno-pic \
    -nostdlib -nostartfiles -Wall -Wextra -Werror \
    -Wl,-e,_start -Wl,--build-id=none \
    -o "$WORK/staging/init" "$HERE/initramfs/init.S" "$HERE/initramfs/init.c"
$CROSS"strip" "$WORK/staging/init"
sed "s|@INIT@|$WORK/staging/init|" "$HERE/initramfs/initramfs.spec.in" \
    > "$WORK/staging/initramfs.spec"
python3 "$HERE/mkcpio.py" "$WORK/staging/initramfs.spec" "$WORK/staging/initramfs.cpio"

# ---- 5. configure ----
say "configuring"
cd "$SRC"
$MAKE ARCH=riscv CROSS_COMPILE="$CROSS" O="$OUT" allnoconfig >/dev/null
python3 "$HERE/kconfig-merge.py" merge "$OUT/.config" \
        "$HERE/vernier_rv32.config" "$OUT/.config.new"
mv "$OUT/.config.new" "$OUT/.config"
# CONFIG_INITRAMFS_SOURCE has to be an absolute path into the workspace, so it
# cannot live in the tracked fragment.
printf 'CONFIG_INITRAMFS_SOURCE="%s"\n' "$WORK/staging/initramfs.cpio" >> "$OUT/.config"
$MAKE ARCH=riscv CROSS_COMPILE="$CROSS" O="$OUT" olddefconfig >/dev/null
# The check, not the merge, is the one that matters: kconfig drops an option
# whose dependencies are unmet without saying so, and CONFIG_EFI silently
# turns the C extension back on. See kconfig-merge.py.
python3 "$HERE/kconfig-merge.py" check "$HERE/vernier_rv32.config" "$OUT/.config"

# ---- 6. build ----
say "building"
kmake -j"$JOBS" Image

# ---- 7. check what came out, before anything tries to run it ----
say "checking the result against rtl/"
python3 "$HERE/isacheck.py" --objdump="$CROSS"objdump "$OUT/vmlinux"

mkdir -p "$HERE/build"
cp "$OUT/arch/riscv/boot/Image" "$HERE/build/Image"
cp "$OUT/vmlinux" "$HERE/build/vmlinux"
cp "$OUT/System.map" "$HERE/build/System.map"

say "built"
ls -la "$HERE/build/Image" | awk '{printf "  Image  %8.1f KB\n", $5/1024}'
echo
echo "next:  make linuximage    # pack it with OpenSBI into an SDRAM image"
echo "       make sim_linux     # boot it under Verilator"
