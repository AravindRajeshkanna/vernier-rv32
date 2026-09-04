#!/bin/sh
# Open-source synthesis + place-and-route for the SoC on a Lattice ECP5.
#
# Status: **this script has been run end to end.** yosys, nextpnr-ecp5 and
# ecppack all complete and produce a bitstream. Measured results (area,
# achieved Fmax, and the critical path) are in fpga/README.md.
#
# What has *not* happened: nothing has been loaded onto a board, because
# there is no board. The pinout in constraints/generic.lpf is still
# placeholders, so a real build needs a real LPF - see DEFAULT_LPF below.
#
# Prerequisites (macOS): there is no Homebrew cask or nextpnr formula, so the
# ECP5 flow comes from YosysHQ's prebuilt bundle:
#
#   curl -L -o oss-cad-suite.tgz \
#     https://github.com/YosysHQ/oss-cad-suite-build/releases/latest/download/oss-cad-suite-darwin-arm64-<date>.tgz
#   tar xzf oss-cad-suite.tgz -C ~/tools
#   export PATH=~/tools/oss-cad-suite/bin:$PATH
#
# (Homebrew's `prjtrellis` provides the ECP5 database and ecppack, but not
# nextpnr-ecp5, which is the piece that matters here.)
#
# Before running:
#   1. Fill in real pins in fpga/constraints/generic.lpf
#   2. Set DEVICE/PACKAGE below to your board
#   3. Set CLK_HZ in fpga/soc_fpga.v to your board's oscillator
#   4. `make soc` at the repo root, so sim/bootrom.hex exists - it is
#      $readmemh'd into the boot ROM at elaboration time and is therefore a
#      synthesis input, not just a simulation one
set -eu

cd "$(dirname "$0")/../.."
ROOT="$PWD"

# Which core, mirroring the Makefile's CORE ?= inorder / CORE_RTL /
# CORE_DEFINES exactly: regfile_phys.v is only pulled in for the wide core,
# never alongside plain regfile.v (rtl/cpu_core.v's 2R/1W file, still needed
# there), and -DCORE_OOO is what soc_top.v's own `ifdef switches on to pick
# core_ooo over cpu_core - the same define this script already threads
# through to yosys for -DSYNTHESIS/-DPRELOAD_RAM below.
CORE=${CORE:-inorder}
case "$CORE" in
    inorder) CORE_RTL="rtl/regfile.v rtl/cpu_core.v"; CORE_DEFINES="" ;;
    ooo)     CORE_RTL="rtl/ooo/regfile_phys.v rtl/ooo/core_ooo.v"; CORE_DEFINES="-DCORE_OOO" ;;
    *) echo "error: unknown CORE='$CORE' (known: inorder, ooo)" >&2; exit 1 ;;
esac

PACKAGE=${PACKAGE:-CABGA381}
BUILD=fpga/build

# Ways to build this:
#
#   ./fpga/synth/synth_ecp5.sh                   board-agnostic, timing only
#   BOARD=ulx3s   ./fpga/synth/synth_ecp5.sh     ULX3S with an LFE5U-45F
#   BOARD=ulx3s85 ./fpga/synth/synth_ecp5.sh     ULX3S with an LFE5U-85F
#
#   BOARD=ulx3s85-video ./fpga/synth/synth_ecp5.sh   ulx3s85, GPDI wired in.
#     Opt-in, not the default: measurably costs Fmax margin (0 of 16 seeds
#     close 25 MHz, against 1 of 6 for plain ulx3s85 - see docs/roadmap.md's
#     Phase 4 section), so the primary board target does not build it by
#     default.
#
# and three that bake a program into the bitstream instead of booting off SD,
# differing only in which program (see the cases below):
#
#   BOARD=ulx3s85-ram        the acceptance test
#   BOARD=ulx3s85-sdramcheck the SDRAM check, run from block RAM
#   BOARD=ulx3s85-sdramfull  the same check over the whole 32 MB part
#   BOARD=ulx3s85-mmutest    Sv32 with its page tables in real SDRAM
#   BOARD=ulx3s85-plictest   an interrupt delivered to S-mode
#   BOARD=ulx3s85-uarttest   the ns16550's divisor latch and register map
#
# and one that is not a SoC at all - a standalone SDRAM probe with no CPU,
# for proving the memory before anything else is in the path:
#
#   BOARD=ulx3s-sdram        fpga/ulx3s_sdram.v, five LEDs
#   BOARD=ulx3s85-probe      the newlib probe
#   BOARD=ulx3s85-trapcheck  the trap handler's own calibration
#
# The default constrains the clock and nothing else, which produces an Fmax
# without inventing a board - useful for tracking the design's own timing, but
# optimistic, because nextpnr may place I/O wherever suits it.
#
# The BOARD= targets build fpga/ulx3s_top.v against real pins and drop
# --lpf-allow-unconstrained, so an unplaced pin becomes an error instead of a
# silently invented placement. Those are the numbers to trust for hardware.
#
# **The FPGA variant is part of the board target, not a separate knob.** A
# bitstream is device-specific and will not load on a different one, and the
# ULX3S ships with four FPGA options that are indistinguishable in a photo.
# Pairing them here means the device cannot be left at a stale default -
# which it silently would be, since 45F and 85F share this board, this
# pinout and this wrapper, and differ only in the chip. DEVICE= still
# overrides for anything not listed.
BOARD=${BOARD:-}
DIAG_ONLY=0
PRELOAD_RAM=0
# Which program a preloading board bakes in, and the ELF it was built from.
# The ELF is not decoration: it is what the staleness check below compares
# against, so a board target that changes one must change the other.
RAM_IMAGE=sim/ramimage.hex
RAM_ELF=software/soc/socprog.elf

case "$BOARD" in
    ulx3s)
        DEVICE=${DEVICE:-45k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v"
        ;;
    ulx3s-diag)
        # SD-path hardware diagnostic: no CPU, no SoC. Builds only
        # fpga/ulx3s_diag.v against a cut-down LPF. 85F because that is the
        # board in hand; DEVICE=45k works too, the design is tiny either way.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_diag}
        LPF=${LPF:-fpga/constraints/ulx3s_diag.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_diag.v"
        DIAG_ONLY=1
        ;;
    ulx3s-cmd0)
        # Hardware CMD0 probe: sends the SD reset command and shows the
        # reply on the LEDs. Same port set as the diagnostic, so it shares
        # that LPF.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_cmd0}
        LPF=${LPF:-fpga/constraints/ulx3s_diag.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_cmd0.v"
        DIAG_ONLY=1
        ;;
    ulx3s-sdram)
        # Hardware SDRAM probe: exercises rtl/soc/wb_sdram.v against the
        # board's real memory chip with no CPU anywhere, and reports through
        # five cumulative LEDs. **Flash this before the SoC.** With the full
        # SoC, "it does not work" covers the pinout, the clock phase, the
        # controller, the interconnect, the caches and the firmware at once;
        # this narrows it to whether the controller talks to the chip.
        #
        # 85F because that is the board in hand. DEVICE=45k works too - the
        # design is a few hundred LUTs either way.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_sdram}
        LPF=${LPF:-fpga/constraints/ulx3s_sdram.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_sdram.v fpga/sdram_clk_out.v rtl/soc/wb_sdram.v"
        DIAG_ONLY=1
        ;;
    ulx3s85-sdramcheck)
        # 85F with software/soc/sdramcheck.c preloaded into *block* RAM,
        # hammering external SDRAM as data. The step after the probe above:
        # the CPU, the interconnect and the caches are now in the path, but
        # the program still runs from block RAM, because nothing can preload
        # SDRAM - a bitstream initialises block RAM at configuration time and
        # SDRAM comes up empty. Running *code* out of SDRAM needs a loader
        # that does not exist yet; see docs/roadmap.md Phase 2.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v"
        PRELOAD_RAM=1
        RAM_IMAGE=sim/sdramcheckimage.hex
        RAM_ELF=software/soc/sdramcheck.elf
        ;;
    ulx3s85-sdramfull)
        # The same program over the whole 32 MB instead of the first 256 KB.
        #
        # 256 KB is what silicon has ever been asked to hold, and it is a
        # smaller claim than it sounds: rtl/soc/wb_sdram.v maps wb_adr[24:12]
        # to the row, so 256 KB is 64 of 8192 rows and seven of the thirteen
        # row address bits are never driven high. Every bank, every column,
        # one two-hundredth of the rows. A kernel needs about 28 MB of it.
        #
        # It also buys the one thing a short sweep cannot: the write pass runs
        # bottom to top and so does the read-back, so the lowest address is
        # read seconds after it was written, with continuous traffic through
        # the same controller in between. The program measures that interval
        # off mtime and prints it rather than asserting it.
        #
        # Costs about six seconds on the board against a tenth of a second.
        # `make verilator_sdramfull` runs this exact image first, because a
        # bitstream nobody has executed is not a test - practices section 4.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v"
        PRELOAD_RAM=1
        RAM_IMAGE=sim/sdramfullimage.hex
        RAM_ELF=software/soc/sdramfull.elf
        ;;
    ulx3s85-mmutest|ulx3s85-plictest|ulx3s85-uarttest)
        # The three peripherals a Linux boot depends on, each in a bitstream
        # of its own.
        #
        # All three had a simulation target and no BOARD= target, which is a
        # specific kind of gap rather than an oversight: Sv32, PLIC interrupt
        # delivery and the ns16550's divisor-latch path are the parts of this
        # SoC that only *Linux* exercised on silicon, and Linux exercises them
        # all at once, three million instructions in, with no way to attribute
        # a failure to one of them. A bare-metal image that tests one thing
        # and prints a verdict is what turns "the kernel died somewhere in
        # early boot" into a question with an address on it.
        #
        # What each is for on a board, beyond what simulation already proves:
        #
        #   mmutest   Sv32 through real SDRAM. The page tables live in the
        #             external part, so this is the walkers, the TLBs and
        #             wb_ptw.v against a memory with actual latency.
        #   plictest  the one thing Linux has *not* settled on silicon: it
        #             maps 8 interrupts over 2 contexts and never needs one
        #             delivered, because the 8250 console path polls. This
        #             raises a GPIO interrupt and requires it to arrive in
        #             S-mode through context 1.
        #   uarttest  the divisor latch and the register map, including the
        #             reprogramming-mid-character case that garbles on real
        #             silicon and is meant to.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v"
        PRELOAD_RAM=1
        case "$BOARD" in
            *-mmutest)  RAM_IMAGE=sim/mmuimage.hex
                        RAM_ELF=software/soc/mmutest.elf ;;
            *-plictest) RAM_IMAGE=sim/plicimage.hex
                        RAM_ELF=software/soc/plictest.elf ;;
            *-uarttest) RAM_IMAGE=sim/uart16550image.hex
                        RAM_ELF=software/soc/uarttest.elf ;;
        esac
        ;;
    ulx3s85-ram)
        # 85F with the acceptance-test program preloaded into RAM, so the
        # boot ROM skips the SD card. For testing the SoC when the card path
        # is not yet working.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v"
        PRELOAD_RAM=1
        ;;
    ulx3s85-probe)
        # 85F with software/soc/newlibprobe.c preloaded instead of the
        # acceptance test: the ladder that answers why newlib dies on this
        # board, run under the loud trap handler.
        #
        # It is a *board* target rather than an env knob because a preloading
        # bitstream is defined by the program inside it. Two bitstreams that
        # differ only in that are indistinguishable once flashed, and the
        # program is the entire reason to build this one.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v"
        PRELOAD_RAM=1
        RAM_IMAGE=sim/probeimage.hex
        RAM_ELF=software/soc/newlibprobe.elf
        ;;
    ulx3s85-trapcheck)
        # 85F with software/soc/trapcheck.c preloaded: provokes one deliberate
        # fault and must print the trap report. The handler's calibration, on
        # silicon rather than in simulation - worth one flash before trusting a
        # *silent* run of the probe above to mean "nothing faulted".
        #
        # Which fault is compiled in, so the image has to be built
        # deliberately first - `make sim/trapimage.hex TRAPCHECK=2` for the
        # illegal-instruction case, and so on. `make trapcheck` deletes the
        # image when it finishes precisely so that this cannot pick up
        # whichever case that script happened to run last.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v"
        PRELOAD_RAM=1
        RAM_IMAGE=sim/trapimage.hex
        RAM_ELF=software/soc/trapcheck.elf
        ;;
    ulx3s85)
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v"
        ;;
    ulx3s85-video)
        # Same board and pins as plain ulx3s85, GPDI wired in - opt-in
        # rather than the default, because it measurably is not free: 0 of
        # 16 placement seeds close 25 MHz with this built in, against 1 of 6
        # without it, and the shift is consistent across every seed tried,
        # not one unlucky draw. docs/roadmap.md's Phase 4 section has the
        # full measurement. This project's primary board target
        # (`ulx3s85`) should not pay that cost by default; this variant
        # exists so the cost can still be measured and the feature still
        # built, deliberately, by whoever wants it.
        DEVICE=${DEVICE:-85k}
        TOP=${TOP:-ulx3s_top}
        LPF=${LPF:-fpga/constraints/ulx3s.lpf}
        PNR_EXTRA=${PNR_EXTRA:-}
        BOARD_RTL="fpga/ulx3s_top.v fpga/sdram_clk_out.v fpga/video_out.v \
                   fpga/video_pll.v fpga/tmds_serialize.v rtl/soc/tmds_encode.v"
        BOARD_DEFINES="-DWITH_VIDEO"
        ;;
    "")
        # 45k, because 64 KB of on-chip RAM needs 67 block RAMs and a 25F
        # has 56. See fpga/README.md's device table.
        DEVICE=${DEVICE:-45k}
        TOP=${TOP:-soc_fpga}
        LPF=${LPF:-fpga/constraints/timing_only.lpf}
        PNR_EXTRA=${PNR_EXTRA:---lpf-allow-unconstrained}
        BOARD_RTL=""
        ;;
    *)
        echo "error: unknown BOARD='$BOARD' (known: ulx3s, ulx3s85, ulx3s85-video," >&2
        echo "       ulx3s85-ram, ulx3s85-probe, ulx3s85-trapcheck, ulx3s85-sdramcheck," >&2
        echo "       ulx3s-diag, ulx3s-cmd0, ulx3s-sdram, or unset)" >&2
        exit 1
        ;;
esac

# -DSYNTHESIS drops the memories' zero-fill initial loops, which exist for
# simulation only and which yosys unrolls into one assignment per word - the
# single thing that used to make this script appear to hang. See
# rtl/soc/wb_ram.v.
YOSYS_DEFINES="-DSYNTHESIS $CORE_DEFINES ${BOARD_DEFINES:-}"

if [ "$PRELOAD_RAM" = "1" ]; then
    YOSYS_DEFINES="$YOSYS_DEFINES -DPRELOAD_RAM"
    if [ ! -f "$RAM_IMAGE" ]; then
        echo "error: $RAM_IMAGE missing - run 'make $RAM_IMAGE' first" >&2
        exit 1
    fi
    # A *stale* preload image is worse than a missing one. Missing stops the
    # build; stale sails through and bakes whatever program was current the
    # last time someone remembered into the bitstream, with nothing anywhere
    # in the log to say so. The board then runs yesterday's software and
    # reproduces a bug that was already fixed - which is exactly what happened
    # here, and cost a full synthesize-and-flash cycle to notice.
    if [ "$RAM_ELF" -nt "$RAM_IMAGE" ]; then
        echo "error: $RAM_IMAGE is older than $RAM_ELF" >&2
        echo "       the bitstream would carry a stale program - rebuild the image" >&2
        exit 1
    fi
    # Which program is going into this bitstream, stated in the log. Three
    # board targets now preload, they produce byte-identical-looking output,
    # and the only place the difference is visible after the fact is here.
    echo "=== preloading $RAM_IMAGE (from $RAM_ELF) ==="
fi

if [ "$DIAG_ONLY" = "1" ]; then
  RTL="$BOARD_RTL"
else
RTL="rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v \
     rtl/uart.v rtl/btb.v rtl/mmu.v rtl/pmp.v $CORE_RTL \
     rtl/soc/wb_interconnect.v rtl/soc/cpu_wb.v rtl/soc/wb_ptw.v \
     rtl/soc/wb_ram.v \
     rtl/soc/wb_rom.v rtl/soc/wb_periph_bridge.v rtl/soc/wb_gpio.v \
     rtl/soc/wb_spi.v rtl/soc/video_timing.v rtl/soc/wb_framebuffer.v \
     rtl/soc/wb_sdram.v \
     rtl/debug/jtag_tap.v rtl/debug/dmi_cdc.v rtl/debug/dm.v \
     rtl/soc/soc_top.v fpga/soc_fpga.v $BOARD_RTL"
fi

if [ "$DIAG_ONLY" != "1" ] && [ ! -f sim/bootrom.hex ]; then
    echo "error: sim/bootrom.hex missing - run 'make soc' first" >&2
    exit 1
fi

# All three tools, checked before the expensive step rather than between the
# steps that need them.
#
# Homebrew has yosys but *not* nextpnr-ecp5, so a shell with only Homebrew on
# its PATH gets through synthesis - a minute of work on an 85F - and then dies
# at "nextpnr-ecp5: command not found" with the netlist already built and
# nothing to do with it. That has now happened; this turns it into a one-second
# failure that says what to do.
missing=
for tool in yosys nextpnr-ecp5 ecppack; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
    echo "error: not on PATH:$missing" >&2
    echo "       the ECP5 flow comes from YosysHQ's bundle - Homebrew ships" >&2
    echo "       yosys and (via prjtrellis) ecppack, but no nextpnr-ecp5:" >&2
    echo "" >&2
    echo "         export PATH=\$HOME/tools/oss-cad-suite/bin:\$PATH" >&2
    echo "" >&2
    echo "       See 'Getting the toolchain' in fpga/README.md." >&2
    exit 1
fi

mkdir -p "$BUILD"

# The boot ROM image is read by a *relative* path at elaboration time
# ($readmemh resolves against the working directory), so synthesis runs from
# $BUILD where a copy of it lives - and the RTL paths are made absolute
# rather than counted out in ../.., which is easy to get wrong and silently
# produces "file not found" from inside a yosys command line.
[ "$DIAG_ONLY" = "1" ] || cp sim/bootrom.hex "$BUILD/bootrom.hex"
# Always copied to the one name fpga/soc_fpga.v's RAM_INIT knows about, so the
# RTL needs no per-program conditionals - the board target picks the source.
[ "$PRELOAD_RAM" = "1" ] && cp "$RAM_IMAGE" "$BUILD/ramimage.hex"

# ---- fail closed: no stale bitstream survives a failed build ----
#
# Every board target writes the same $BUILD/$TOP.bit. Six of them do
# (ulx3s85, -ram, -probe, -trapcheck, -sdramcheck, -sdramfull), carrying six
# different programs, and `openFPGALoader` cannot tell them apart. So a build
# that dies anywhere - nextpnr erroring, ecppack missing from PATH, a
# ^C - leaves the *previous* target's bitstream sitting there looking exactly
# like a fresh one, and the next command in the documented sequence flashes
# it.
#
# That has now cost a bench session. A `-ram` build failed in nextpnr, the
# bitstream from an earlier `ulx3s85` run stayed behind, and the board came up
# with no program in RAM and fell through to the SD path it was specifically
# supposed to be avoiding. The console output was correct and described a
# different bitstream than the one that had just been built.
#
# Removing them first makes the failure unmistakable: no bitstream at all
# rather than the wrong one. A missing file cannot be misread.
rm -f "$BUILD/$TOP.bit" "$BUILD/$TOP.bit.target" "$BUILD/$TOP.bit.ramimage.hex"

# Stated up front and again at the end: a bitstream is device-specific, and
# loading one built for the wrong ECP5 fails in ways that look like a broken
# design rather than a broken command line.
echo "=== target: ${BOARD:-generic}, LFE5U-${DEVICE%k}F, $PACKAGE ==="
echo "=== yosys ==="
( cd "$BUILD" && yosys -p "read_verilog $YOSYS_DEFINES $(echo "$RTL" | sed "s|[^ ][^ ]*|$ROOT/&|g"); \
    synth_ecp5 -top $TOP -json $TOP.json" )

# ---- place and route, retrying seeds until timing closes ----
#
# nextpnr treats an unmet clock constraint as a hard **error** and exits 1:
#
#   ERROR: Max frequency for clock ...: 24.87 MHz (FAIL at 25.00 MHz)
#   0 warnings, 1 error
#
# and this design does not reliably close 25 MHz. Its placer is a
# simulated-annealing search seeded from a constant, and the routed Fmax over
# six measured seeds is 24.69, 24.87, 25.47, 26.62, 27.07, 27.63 - **two of
# six below the constraint**. Whether a build succeeds is therefore a coin
# weighted about 2:1, decided by a seed, and the failure arrives after eight
# minutes of place-and-route with nothing to show for it.
#
# Retrying seeds is the standard answer to a marginal design and it is what
# this does. It is a mitigation, not a fix: the fix is a shorter critical path,
# and until that lands `fpga/README.md` says plainly that the margin is
# approximately zero. A bitstream produced on the fourth seed is exactly as
# correct as one produced on the first - the constraint is met or it is not -
# but a design that needs four is one bad change away from needing forty.
#
# Skipped entirely if the caller pinned a seed, because then the seed is the
# experiment.
echo "=== nextpnr-ecp5 ==="
pnr_seeds=${SEED_TRIES:-6}
case "$PNR_EXTRA" in
    *--seed*) pnr_seeds=1 ;;
esac

pnr_ok=0
pnr_seed=""
i=1
while [ "$i" -le "$pnr_seeds" ]; do
    if [ "$pnr_seeds" = "1" ]; then
        seed_arg=""
    else
        seed_arg="--seed $i"
        echo "--- placement seed $i of $pnr_seeds ---"
    fi
    if nextpnr-ecp5 --"$DEVICE" --package "$PACKAGE" \
        --json "$BUILD/$TOP.json" \
        --lpf "$LPF" $PNR_EXTRA $seed_arg \
        --textcfg "$BUILD/$TOP.config"; then
        pnr_ok=1
        pnr_seed="$i"
        break
    fi
    echo "--- seed $i did not close timing; trying another ---" >&2
    i=$((i + 1))
done

if [ "$pnr_ok" != "1" ]; then
    echo >&2
    echo "error: no placement seed closed timing in $pnr_seeds attempts." >&2
    echo "  This design's routed Fmax straddles the 25 MHz constraint - see" >&2
    echo "  'Fmax is a distribution' in fpga/README.md. Raise SEED_TRIES, or" >&2
    echo "  shorten the critical path nextpnr printed above." >&2
    exit 1
fi
# A plain `if`, not an `A && B && echo` chain: under `set -e` the failing case
# of such a chain is the last command in the list, and whether that aborts the
# script is exactly the kind of shell subtlety this file should not be
# betting on.
if [ "$pnr_seeds" != "1" ]; then
    echo "--- timing closed on seed $pnr_seed ---"
fi

echo "=== ecppack ==="
ecppack "$BUILD/$TOP.config" "$BUILD/$TOP.bit"

# ecppack can return 0 and write nothing useful, and `set -e` does not check
# what a tool produced - only what it returned. This is the last point at
# which "the build worked" is still a claim rather than an artifact.
if [ ! -s "$BUILD/$TOP.bit" ]; then
    echo "error: ecppack produced no bitstream at $BUILD/$TOP.bit" >&2
    exit 1
fi

echo
echo "bitstream: $BUILD/$TOP.bit  (LFE5U-${DEVICE%k}F - will not load on any other ECP5)"
# ---- what this bitstream is, written down next to it ----
#
# "Which program is in this bitstream?" is the one question you have to answer
# before flashing, and until now the filesystem could not answer it. The
# `.bit.ramimage.hex` stamp below was the attempt, and it was written *only by
# preloading targets* - so a later non-preload build overwrote the bitstream
# and left the stamp behind, describing a program that was no longer in it. A
# stamp that survives the thing it describes is worse than no stamp: it reads
# as evidence.
#
# Every target writes it now, including the ones that preload nothing, and it
# is removed before the build so a failure leaves neither.
{
    echo "board:     ${BOARD:-generic}"
    echo "top:       $TOP"
    echo "device:    LFE5U-${DEVICE%k}F $PACKAGE"
    echo "lpf:       $LPF"
    echo "built:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [ "$PRELOAD_RAM" = "1" ]; then
        echo "preloaded: $RAM_IMAGE (from $RAM_ELF)"
        echo "boots:     straight into the preloaded program; the SD card is not touched"
    else
        echo "preloaded: nothing"
        echo "boots:     the ROM - UART loader window first, then SD card"
    fi
} > "$BUILD/$TOP.bit.target"

if [ "$PRELOAD_RAM" = "1" ]; then
    cp "$RAM_IMAGE" "$BUILD/$TOP.bit.ramimage.hex"
    echo "  carries:  $RAM_IMAGE  (stamped as $TOP.bit.ramimage.hex)"
else
    echo "  carries:  nothing preloaded - this boots the ROM, which waits for a"
    echo "            UART knock and then tries the SD card"
fi
echo "  what it is: $BUILD/$TOP.bit.target"

# A second copy under the target's own name. $TOP.bit is the one every
# document and every muscle-memory command line names, so it stays; this is
# what lets a bring-up session keep several bitstreams without re-running
# place-and-route, and it cannot be confused with another target's.
if [ -n "${BOARD:-}" ]; then
    cp "$BUILD/$TOP.bit" "$BUILD/$BOARD.bit"
    echo "  also as:  $BUILD/$BOARD.bit"
fi

# Every ULX3S target, not a hand-maintained subset. ulx3s85-sdramfull was
# added and not listed here, so it printed "openFPGALoader -b <your-board>" at
# a user who was following the instructions - the same class of defect as the
# stamp above, and found the same way.
case "${BOARD:-}" in
    ulx3s*) echo "flash with: openFPGALoader -b ulx3s $BUILD/$TOP.bit" ;;
    *)      echo "flash with: openFPGALoader -b <your-board> $BUILD/$TOP.bit" ;;
esac
echo
echo "Check nextpnr's reported Fmax against your target clock. If it comes in"
echo "under, read the critical path out of the log above rather than guessing"
echo "- twice now the guess has been wrong. The last measured one runs from a"
echo "block RAM read port through the MMU walk result to the PC, and is mostly"
echo "routing. See fpga/README.md."
