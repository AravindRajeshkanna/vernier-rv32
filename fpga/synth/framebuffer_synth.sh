#!/bin/sh
# Does the framebuffer synthesise at its real size, and into block RAM?  (docs/roadmap/index.md, "Common known
# defects": real-scale synthesis stopped finishing; docs/roadmap/phase-10-gpu.md.)
#
# `synth_ecp5` on rtl/soc/wb_framebuffer.v alone, at its default 320x240, under a time limit:
#
#   sh fpga/synth/framebuffer_synth.sh            print the figures
#   sh fpga/synth/framebuffer_synth.sh --check    ...and fail if it does not finish, if yosys turned a pixel memory
#                                                 into registers, or if a figure is over (or under) its budget
#
# Why this exists. A memory written from an `always @(posedge clk or posedge rst)` block is replaced by yosys's front
# end with a list of registers ("Replacing memory \mem0 with list of registers"), and the passes after it then crawl:
# at 320x240 that is 614,400 flip-flops and a PROC_ARST pass that was 16% done after 25 minutes when it was killed.
# Nothing else noticed. Every simulation passes, because simulation does not care how a memory is built, and a build at
# the 8x8 size the boards were using finishes, so the framebuffer was shrunk to make place-and-route run and the cause
# stayed buried. Written from a clock-only block, the same memory maps to block RAM and the whole module synthesises in
# seconds. Keeping the write port out of the FSM's reset block is what this check holds in place.
#
# The limits are several times the figures the module has now and several times under what the register version costs,
# so they hold across yosys versions (counts move by a few per cent between them) and still catch the mistake. The time
# limit is the real test: the register version does not finish at all, and this one takes seconds.
#   TIME_LIMIT (default 180)   seconds yosys may take
#   LIMIT_LUT  (default 12000) 4-input LUTs (3,819 now)
#   LIMIT_FF   (default 5000)  flip-flops (401 now; the register version has one per stored bit, 614,400)
#   MIN_BRAM   (default 60)    DP16KD block RAMs (80 now)
set -u
cd "$(dirname "$0")/../.."
BUNDLE=${BUNDLE:-$HOME/tools/oss-cad-suite}
export PATH="$BUNDLE/bin:$PATH"
LOG_DIR=${FB_SYNTH_LOG:-/tmp/framebuffer_synth}
mkdir -p "$LOG_DIR"
SRC=${FB_SRC:-rtl/soc/wb_framebuffer.v}
check=0; [ "${1:-}" = "--check" ] && check=1
TIME_LIMIT=${TIME_LIMIT:-180}
LIMIT_LUT=${LIMIT_LUT:-12000}
LIMIT_FF=${LIMIT_FF:-5000}
MIN_BRAM=${MIN_BRAM:-60}

log="$LOG_DIR/framebuffer.log"
start=$(date +%s)
# perl as the timer, because macOS has no timeout(1): run the command, kill it at the limit, and exit 124 (as
# timeout(1) does) if it had to; otherwise exit with the command's own status.
perl -e 'my $t = shift; my $p = fork; exec @ARGV unless $p;
         $SIG{ALRM} = sub { kill 9, $p; waitpid $p, 0; exit 124 }; alarm $t; waitpid $p, 0; exit($? >> 8)' "$TIME_LIMIT" \
    yosys -q -l "$log" -p "read_verilog -sv $SRC; synth_ecp5 -top wb_framebuffer; stat" >/dev/null 2>&1
status=$?
secs=$(( $(date +%s) - start ))

if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 124 ]; then
        echo "FRAMEBUFFER SYNTHESIS FAILED: yosys had not finished after ${TIME_LIMIT}s ($log)"
        regs=$(grep -a -c "Replacing memory .* with list of registers" "$log" 2>/dev/null)
        [ "${regs:-0}" -gt 0 ] && echo "  yosys turned ${regs} memories into registers, which is what makes it crawl:" &&
            grep -a "Replacing memory .* with list of registers" "$log" | head -n 3 | sed 's/^/    /'
    else
        echo "FRAMEBUFFER SYNTHESIS FAILED: yosys exited with status $status ($log)"
    fi
    exit 1
fi

n() { grep -a -E "^ +[0-9]+ +$1\$" "$log" | tail -n 1 | awk '{print $1}'; }
lut=$(n LUT4); ff=$(n TRELLIS_FF); bram=$(n DP16KD); dpr=$(n TRELLIS_DPR16X4)
regs=$(grep -a -c "Replacing memory .* with list of registers" "$log")
printf '%-28s %8s %8s %8s %10s %6s\n' "wb_framebuffer 320x240" LUT4 FF DP16KD DPR16X4 secs
printf '%-28s %8s %8s %8s %10s %6s\n' "" "${lut:-0}" "${ff:-0}" "${bram:-0}" "${dpr:-0}" "$secs"

fail=0
if [ "$check" = 1 ]; then
    if [ "${regs:-0}" -gt 0 ]; then
        echo "  FAIL: yosys turned ${regs} memories into registers (a memory written from a block with an asynchronous reset)"
        grep -a "Replacing memory .* with list of registers" "$log" | head -n 3 | sed 's/^/    /'
        fail=1
    fi
    if [ -z "$lut" ] || [ "$lut" -gt "$LIMIT_LUT" ]; then
        echo "  FAIL: ${lut:-unknown} LUT4s, over its budget of $LIMIT_LUT"; fail=1
    fi
    if [ -n "$ff" ] && [ "$ff" -gt "$LIMIT_FF" ]; then
        echo "  FAIL: $ff flip-flops, over its budget of $LIMIT_FF"; fail=1
    fi
    if [ -z "$bram" ] || [ "$bram" -lt "$MIN_BRAM" ]; then
        echo "  FAIL: ${bram:-0} block RAMs (DP16KD), under the $MIN_BRAM the pixel buffer needs"; fail=1
    fi
    [ "$fail" = 0 ] && echo "FRAMEBUFFER SYNTHESIS OK" || echo "FRAMEBUFFER SYNTHESIS FAILED"
fi
exit $fail
