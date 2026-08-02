#!/usr/bin/env bash
# Build the riscv-tests ISA suites into images this SoC can run.
#
# Each test is a standalone, self-checking assembly program. It links at
# 0x8000_0000 - which is exactly where rtl/soc/soc_top.v puts main RAM, so no
# relinking is needed - and reports its verdict by storing to a `tohost`
# word. That word's address is extracted per test and handed to the
# testbench, rather than hardcoding the 0x8000_1000 that today's linker
# script happens to produce.
#
# Only the suites this core can actually attempt are built: rv32ui (base
# integer), rv32um (M), rv32ua (A), rv32mi (machine-mode CSRs and traps) and
# rv32si (supervisor). Compressed, float, and bitmanip suites are skipped
# because the core does not implement those extensions - running them would
# only prove that a missing extension is missing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$HERE/riscv-tests"
OUT="$HERE/build"

CC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy
NM=riscv64-unknown-elf-nm

SUITES="${SUITES:-rv32ui rv32um rv32ua rv32mi rv32si}"

if [ ! -d "$SRC/env/p" ]; then
    echo "riscv-tests not fetched yet - run tests/fetch.sh" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# zicsr/zifencei are spelled out because the test environment writes CSRs and
# rv32ui/fence_i.S issues FENCE.I; since nothing here links against libc, the
# multilib mismatch that forces software/ to build as plain rv32im does not
# apply and the full rv32ima can be requested.
ARCH=rv32ima_zicsr_zifencei
CFLAGS="-march=$ARCH -mabi=ilp32 -static -mcmodel=medany -fvisibility=hidden \
        -nostdlib -nostartfiles -DXLEN=32 -I$SRC/env/p -I$SRC/isa/macros/scalar"

: > "$OUT/manifest.txt"
count=0

for suite in $SUITES; do
    for src in "$SRC/isa/$suite"/*.S; do
        [ -e "$src" ] || continue
        base="$(basename "$src" .S)"
        name="$suite-p-$base"

        if ! $CC $CFLAGS -T "$SRC/env/p/link.ld" "$src" -o "$OUT/$name.elf" \
                 2> "$OUT/$name.buildlog"; then
            echo "SKIP  $name (does not assemble for $ARCH)"
            echo "$name BUILD_FAILED" >> "$OUT/manifest.txt"
            continue
        fi
        rm -f "$OUT/$name.buildlog"

        # One flat image starting at the link base. The p environment's
        # sections are 4 KB aligned, so the binary carries the padding too and
        # every byte lands at (address - 0x80000000) in the RAM array.
        $OBJCOPY -O binary "$OUT/$name.elf" "$OUT/$name.bin"
        # word-size=4: rtl/soc/wb_ram.v is a 32-bit word array (it has to be,
        # to be a block RAM), so its $readmemh image is one little-endian
        # word per line rather than one byte.
        python3 "$ROOT/software/bin2hex.py" --word-size=4 "$OUT/$name.bin" \
            > "$OUT/$name.hex"
        rm -f "$OUT/$name.bin"

        tohost="$($NM "$OUT/$name.elf" | awk '$3=="tohost"{print $1}')"
        if [ -z "$tohost" ]; then
            echo "SKIP  $name (no tohost symbol)"
            echo "$name NO_TOHOST" >> "$OUT/manifest.txt"
            continue
        fi
        # The testbench indexes the RAM word array, so it wants a *word*
        # index from the RAM base, not the absolute byte address.
        offset="$(printf '%08x' $(( (0x$tohost - 0x80000000) / 4 )))"
        echo "$name $offset" >> "$OUT/manifest.txt"
        count=$((count + 1))
    done
done

echo "built $count test images into $OUT"
