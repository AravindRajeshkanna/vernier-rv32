#!/bin/sh
# Does the whole SoC synthesise at its real size, and without a sizeable memory turning into registers?
# (docs/roadmap/index.md, "Common known defects"; fpga/synth/framebuffer_synth.sh holds the same line for one module.)
#
# fpga/synth/synth_ecp5.sh on BOARD=ulx3s85, synthesis only (SYNTH_ONLY, no place-and-route), with no FB_WIDTH or
# FB_HEIGHT override, so the framebuffer is its real 320x240, under a time limit:
#
#   sh fpga/synth/soc_synth.sh            print the figures
#   sh fpga/synth/soc_synth.sh --check    ...and fail if the build does not finish, if yosys turned a memory into
#                                         registers that fpga/synth/soc_register_memories.txt does not list, if a
#                                         listed one no longer is one, or if a figure is over (or under) its budget
#   CORE=ooo sh fpga/synth/soc_synth.sh --check       the wide core (default inorder; needs sim/bootrom_$CORE.hex)
#
# Why this exists. A memory written from an `always @(posedge clk or posedge rst)` block is replaced by yosys's front
# end with a list of registers ("Replacing memory \mem0 with list of registers"), and the passes after it then crawl:
# at the framebuffer's 320x240 that was 614,400 flip-flops and a build that did not finish in hours. Every simulation
# passed, because simulation does not care how a memory is built, and a build at the 8x8 size the boards were using
# finishes, so the framebuffer was shrunk to make place-and-route run and the cause stayed buried. framebuffer_synth.sh
# holds that one module. This holds the rest: any other memory, in any module, that someone writes from a block with
# an asynchronous reset.
#
# Two ways in, because yosys prints the same warning for a 16-word table and for a frame buffer. The list says which
# memories are known to become registers and are small (the TLB, the PLIC, the BTB...); a name that is not on it fails,
# and so does one that is on it and no longer happens, so the list only shrinks and cannot go stale. The budgets catch
# what the names cannot: a listed memory that has grown (the BTB at four times its size is over the flip-flop
# budget), or a memory that became registers some other way.
# The budgets are well over the figures the SoC has now and far under what a frame buffer of registers costs, so they
# hold across yosys versions (counts move by a few per cent between them) and still catch the mistake. The time limit
# is the real test of the original failure: the register version does not finish at all.
#
#                      TIME_LIMIT (s)    LIMIT_LUT (LUT4)     LIMIT_FF            MIN_BRAM (DP16KD)
#   CORE=inorder       600 (130 now)     40000 (24,273 now)   20000 (11,132 now)  60 (82 now)
#   CORE=ooo           1500 (330 now)    75000 (58,626 now)   26000 (16,579 now)  60 (80 now)
#
# The figures are from a laptop with two builds running side by side, 913 MB and 1.43 GB of memory at the peak. The
# wide core is most of the device (the 85F has 83,640 LUT4s), so its budget is not far above what it uses; the
# 320x240 pixel buffer alone is 80 DP16KD, which is why the block-RAM floor is 60.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$PWD
BUNDLE=${BUNDLE:-$HOME/tools/oss-cad-suite}
export PATH="$BUNDLE/bin:$PATH"
CORE=${CORE:-inorder}
BOARD=${BOARD:-ulx3s85}
LOG_DIR=${SOC_SYNTH_LOG:-/tmp/soc_synth_$CORE}
ALLOW=${SOC_ALLOW:-fpga/synth/soc_register_memories.txt}
check=0; [ "${1:-}" = "--check" ] && check=1
case "$CORE" in
    inorder) d_time=600;  d_lut=40000; d_ff=20000 ;;
    ooo)     d_time=1500; d_lut=75000; d_ff=26000 ;;
    *) echo "error: unknown CORE='$CORE' (known: inorder, ooo)" >&2; exit 1 ;;
esac
TIME_LIMIT=${TIME_LIMIT:-$d_time}
LIMIT_LUT=${LIMIT_LUT:-$d_lut}
LIMIT_FF=${LIMIT_FF:-$d_ff}
MIN_BRAM=${MIN_BRAM:-60}

if [ ! -f "sim/bootrom_$CORE.hex" ]; then
    echo "error: sim/bootrom_$CORE.hex missing - run 'make soc CORE=$CORE' first (it is a synthesis input)" >&2
    exit 1
fi
mkdir -p "$LOG_DIR/build"
log="$LOG_DIR/synth.log"
turned="$LOG_DIR/turned.txt"
rm -f "$log" "$turned"

# perl as the timer, because macOS has no timeout(1): run the build in its own process group, kill the whole group at
# the limit (synth_ecp5.sh is a shell, and the yosys under it would survive a kill of the shell alone), and exit 124
# (as timeout(1) does) if it had to; otherwise exit with the build's own status.
start=$(date +%s)
BUILD="$LOG_DIR/build" CORE="$CORE" BOARD="$BOARD" SYNTH_ONLY=1 \
    perl -e 'my $t = shift; my $p = fork; if (!$p) { setpgrp(0, 0); exec @ARGV; exit 127 }
             $SIG{ALRM} = sub { kill 9, -$p; waitpid $p, 0; exit 124 }; alarm $t; waitpid $p, 0; exit($? >> 8)' \
    "$TIME_LIMIT" sh fpga/synth/synth_ecp5.sh >"$log" 2>&1
status=$?
secs=$(( $(date +%s) - start ))

# The memories yosys turned into registers: "<file> <memory>", one line each, however many times a module was elaborated.
# The warning's own file name is absolute and the line number moves with every edit, so neither is kept.
grep -a "Replacing memory .* with list of registers" "$log" 2>/dev/null |
    sed -n "s|^Warning: Replacing memory \\\\\\([^ ]*\\) with list of registers. See $ROOT/\\([^:,]*\\):.*|\\2 \\1|p" |
    sort -u >"$turned"
nturned=$(wc -l <"$turned" | tr -d ' ')

# Each memory yosys turned into registers against this core's lines of the list: NEW if no line names it, GONE for
# a line that names nothing that was turned. A * in a line's memory stands for any run of characters.
verdict=$(awk -v core="$CORE" '
    function glob(g) { gsub(/\*/, ".*", g); return "^" g "$" }
    FILENAME == ARGV[1] {
        if ($0 ~ /^[[:space:]]*(#|$)/ || ($3 != "both" && $3 != core)) next
        na++; af[na] = $1; am[na] = glob($2); label[na] = $1 " " $2
        next
    }
    {
        hit = 0
        for (i = 1; i <= na; i++) if ($1 == af[i] && $2 ~ am[i]) { used[i] = 1; hit = 1 }
        if (!hit) print "NEW " $1 " " $2
    }
    END { for (i = 1; i <= na; i++) if (!used[i]) print "GONE " label[i] }
' "$ALLOW" "$turned")
new=$(echo "$verdict" | sed -n 's/^NEW //p')
gone=$(echo "$verdict" | sed -n 's/^GONE //p')

if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 124 ]; then
        echo "SOC SYNTHESIS FAILED: yosys had not finished after ${TIME_LIMIT}s ($log)"
        if [ -n "$new" ]; then
            echo "  it turned these memories into registers, and $ALLOW does not list them, which is what makes it crawl:"
            echo "$new" | head -n 5 | sed 's/^/    /'
        fi
    else
        echo "SOC SYNTHESIS FAILED: the build exited with status $status ($log)"
        { grep -a -m 3 -E "^error|ERROR" "$log" || tail -n 3 "$log"; } | cut -c1-200 | sed 's/^/    /'
    fi
    exit 1
fi

n() { grep -a -E "^ +[0-9]+ +$1\$" "$log" | tail -n 1 | awk '{print $1}'; }
lut=$(n LUT4); ff=$(n TRELLIS_FF); bram=$(n DP16KD); dpr=$(n TRELLIS_DPR16X4)
printf '%-30s %8s %8s %8s %9s %6s %10s\n' "SoC $BOARD $CORE 320x240" LUT4 FF DP16KD DPR16X4 secs "registers"
printf '%-30s %8s %8s %8s %9s %6s %10s\n' "" "${lut:-0}" "${ff:-0}" "${bram:-0}" "${dpr:-0}" "$secs" "${nturned:-0}"

fail=0
if [ "$check" = 1 ]; then
    if [ -n "$new" ]; then
        echo "  FAIL: yosys turned these memories into registers, and $ALLOW does not list them:"
        echo "$new" | sed 's/^/    /'
        echo "    (a memory written from a block with an asynchronous reset. Write it from a clock-only block, as"
        echo "     rtl/soc/wb_framebuffer.v does; if it is small on purpose, list it, with the reason.)"
        fail=1
    fi
    if [ -n "$gone" ]; then
        echo "  FAIL: $ALLOW lists these, and yosys no longer turns them into registers (delete the lines):"
        echo "$gone" | sed 's/^/    /'
        fail=1
    fi
    if [ -z "$lut" ] || [ "$lut" -gt "$LIMIT_LUT" ]; then
        echo "  FAIL: ${lut:-unknown} LUT4s, over its budget of $LIMIT_LUT"; fail=1
    fi
    if [ -z "$ff" ] || [ "$ff" -gt "$LIMIT_FF" ]; then
        echo "  FAIL: ${ff:-unknown} flip-flops, over its budget of $LIMIT_FF"; fail=1
    fi
    if [ -z "$bram" ] || [ "$bram" -lt "$MIN_BRAM" ]; then
        echo "  FAIL: ${bram:-0} block RAMs (DP16KD), under the $MIN_BRAM the pixel buffer needs"; fail=1
    fi
    [ "$fail" = 0 ] && echo "SOC SYNTHESIS OK" || echo "SOC SYNTHESIS FAILED"
fi
exit $fail
