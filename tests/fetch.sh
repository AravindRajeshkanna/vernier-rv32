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
PIN="3cf82492ee5e6c0acec786e0e2670969a4041a41"

if [ -d "$DEST/.git" ]; then
    echo "riscv-tests already present at $DEST"
else
    echo "cloning riscv-tests..."
    git clone "$REPO" "$DEST"
fi

cd "$DEST"

# Not `2>/dev/null || true`. The previous version swallowed a failed fetch and
# then a failed checkout, which is how this file spent its life pinning a
# commit that does not exist in the upstream repository: locally the clone
# already existed, so the block above short-circuited, the fetch failed
# silently, the checkout failed silently, and `make isa` ran against whatever
# happened to be checked out. The pinning that tests/README.md claims was not
# happening. CI, being the first fresh clone, is what exposed it.
if ! git fetch --depth 1 origin "$PIN" 2>/dev/null; then
    git fetch --quiet origin
fi
if ! git checkout --quiet "$PIN"; then
    echo "error: cannot check out the pinned riscv-tests commit $PIN" >&2
    echo "       It may have been removed upstream, or the pin is wrong." >&2
    echo "       Verify with:" >&2
    echo "         curl -fsS https://api.github.com/repos/riscv-software-src/riscv-tests/commits/$PIN" >&2
    exit 1
fi

# Prove we are actually on the pin, rather than trusting that the checkout
# above did what it said.
HEAD_SHA="$(git rev-parse HEAD)"
if [ "$HEAD_SHA" != "$PIN" ]; then
    echo "error: riscv-tests is at $HEAD_SHA, not the pinned $PIN" >&2
    exit 1
fi

# env/ holds the p (physical/machine-mode) and v (virtual) test environments:
# the linker script, the reset vector, and the pass/fail macros. It is a
# submodule, and nothing builds without it.
git submodule update --init --depth 1 env

echo "riscv-tests pinned at $PIN"
