#!/bin/sh
# Structural check of the DDR3 PHY's synthesis branch: what the command pins carry in the
# second slot of every sclk (Phase 9 Stage 1, Part 27, docs/roadmap/phase-09-ddr.md).
#
# The ECPIX-5 ties the DRAM's CS# to ground, so the DRAM samples RAS#, CAS# and WE# on every
# rising edge of CK and a command left on the bus for the second slot of an sclk would be
# presented twice. In the simulation branch of rtl/soc/ddr3_phy_ecp5.v that is checked by
# behaviour (sim/tb_ddr3_phy_phases.v, and every integrated test through the protocol
# checker). The synthesis branch is the one that runs on the board and nothing simulates it:
# `make synth_check_ddr3` only shows that its primitives elaborate. So this reads what it
# elaborates to and checks the one thing that makes it a NOP in phase 1: each of the output
# primitives for RAS#, CAS# and WE# is an ODDRX1F whose second-slot input D1 is the constant 1
# (the first, D0, is the registered command). It also checks that every other command pin goes
# out through an ODDRX1F carrying the same value in both slots (address, bank, CKE and ODT),
# that there are exactly the 23 such primitives the board's pins call for (3 qualifiers, CKE,
# ODT, 3 bank bits, 15 address bits), and that there is no OSHX2A left (it carried CS#) and
# exactly one ODDRX2F (CK; CK# is the differential pad pair's). It does not say the primitives
# put a value on the pin when the design assumes: that needs a board.
#
# Needs yosys. Run from the repository root; `make synth_check_ddr3` does.
set -eu

YSHARE=$(dirname "$(dirname "$(command -v yosys)")")/share/yosys/ecp5
CELLS_BB=$YSHARE/cells_bb.v
CELLS_IO=$YSHARE/cells_io.vh
for f in "$CELLS_BB" "$CELLS_IO"; do
    [ -f "$f" ] || { echo "ddr3_phy_nop_check: yosys ECP5 cell library not found at $f"; exit 1; }
done

# Scratch files in the temporary directory, removed on the way out, so nothing is left in the tree.
IL=$(mktemp "${TMPDIR:-/tmp}/ddr3_phy_synth.XXXXXX")
trap 'rm -f "$IL" "$IL.log"' EXIT
yosys -q -p "read_verilog -lib $CELLS_BB; read_verilog -lib $CELLS_IO; \
             read_verilog -DSYNTHESIS -sv rtl/soc/ddr3_phy_ecp5.v; \
             hierarchy -check -top ddr3_phy_ecp5; proc; write_rtlil $IL" \
    > "$IL.log" 2>&1 || { cat "$IL.log"; echo "ddr3_phy_nop_check: yosys FAILED"; exit 1; }

# One block of RTLIL per cell:  cell \ODDRX1F \RAS ... connect \D0 \ras_n_q ... connect \D1 1'1 ... end
awk '
    function bad(msg) { print "ddr3_phy_nop_check: " msg; failed = 1 }
    /^  cell / { type = $2; name = $3; d0 = ""; d1 = ""; next }
    /^    connect \\D0 / { d0 = $3 }
    /^    connect \\D1 / { d1 = $3 }
    /^  end$/ && type != "" {
        count[type]++
        if (type == "\\ODDRX1F") {
            if (name == "\\RAS" || name == "\\CAS" || name == "\\WE") {
                qual++
                if (d1 != "1'"'"'1") bad(name " second slot (D1) is " d1 ", not the constant 1 (the NOP level)")
                if (d0 == "" || d0 == "1'"'"'1") bad(name " first slot (D0) is " d0 ", not the registered command")
            } else {
                other++
                if (d0 == "" || d0 != d1) bad(name " carries " d0 " in the first slot and " d1 " in the second")
            }
        }
        type = ""
    }
    END {
        if (qual != 3)                     bad("expected 3 command-qualifier ODDRX1F (RAS, CAS, WE), found " qual+0)
        if (other != 20)                   bad("expected 20 other ODDRX1F (CKE, ODT, 3 bank, 15 address), found " other+0)
        if (count["\\OSHX2A"] != 0)        bad("an OSHX2A is left: it carried CS#, which the board ties low")
        if (count["\\ODDRX2F"] != 1)       bad("expected exactly one ODDRX2F (CK), found " count["\\ODDRX2F"]+0)
        if (failed) exit 1
        print "ddr3_phy_nop_check: RAS#, CAS# and WE# carry the NOP in phase 1; " other " other command pins carry one value in both slots; one ODDRX2F (CK), no OSHX2A"
    }
' "$IL"
