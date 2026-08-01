#!/usr/bin/env bash
# Fetch the official RISC-V architectural test suite.
#
# The suite is not vendored into this repo - it is a separate upstream
# project with its own license, and the whole point of running it is that it
# is *not* something this project wrote. It is pinned to a commit so a
# regression can never be explained away by "upstream changed".
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/riscv-tests"
REPO="https://github.com/riscv-software-src/riscv-tests.git"
PIN="6de71edb142be36319e380ce782c3d1830c65d68"

if [ -d "$DEST/.git" ]; then
    echo "riscv-tests already present at $DEST"
else
    echo "cloning riscv-tests..."
    git clone "$REPO" "$DEST"
fi

cd "$DEST"
git fetch --depth 1 origin "$PIN" 2>/dev/null || git fetch origin
git checkout --quiet "$PIN"

# env/ holds the p (physical/machine-mode) and v (virtual) test environments:
# the linker script, the reset vector, and the pass/fail macros. It is a
# submodule, and nothing builds without it.
git submodule update --init --depth 1 env

echo "riscv-tests pinned at $PIN"
