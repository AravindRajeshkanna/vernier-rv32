#!/usr/bin/env bash
# Fetch EEMBC's CoreMark.
#
# Not vendored, for the same reason riscv-tests is not: it is somebody else's
# project with its own license, and the point of running a standard benchmark
# is that this project did not write it. Pinned to a commit so a number can
# never move because upstream did.
#
# Only the port layer (core_portme.c/.h, the linker script and startup code)
# lives in this repo - the benchmark's own five source files are used
# unmodified.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/coremark"
REPO="https://github.com/eembc/coremark.git"
PIN="1f483d5b8316753a742cbf5590caf5bd0a4e4777"

if [ -d "$DEST/.git" ]; then
    echo "coremark already present at $DEST"
else
    echo "cloning coremark..."
    git clone "$REPO" "$DEST"
fi

cd "$DEST"
git fetch --depth 1 origin "$PIN" 2>/dev/null || git fetch origin
git checkout --quiet "$PIN"
echo "coremark pinned at $PIN"
