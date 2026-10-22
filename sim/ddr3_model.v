// Behavioral DDR3 protocol checker - Phase 9 Stage 1, Part 1
// (docs/roadmap/phase-09-ddr.md). Scoped to what Part 1's own init sequence
// exercises: reset/CKE timing, the real MR2->MR3->MR1->MR0->ZQCL
// command order, and the real inter-command minimum waits (tMRD,
// tZQinit). Not a memory array - no read/write data path exists yet to
// model, so this checks protocol *compliance*, not data correctness;
// that is the later, separate slice's own job, the same split
// rtl/soc/ddr3_init_seq.v's own header already draws.
//
// A real, fail-capable checker - matching docs/practices.md's own
// standard - not a passive logger: `error` latches and stays set the
// first time any real violation is seen, and the testbench reads it
// rather than eyeballing a transcript.
//
// ---- The pins are the ECPIX-5's (Phase 9 Stage 1, Part 27) ----
// The board ties the DRAM's CS# to ground (schematic R02, sheet 7, R33) and gives its
// RESET# to the board's own reset circuit (sheet 3), so this model has no CS# and its
// reset_n is not the controller's. With CS# always low there is no deselect: every rising
// edge of CK while RESET# is high is a command slot, and an idle one has to carry a NOP
// (RAS#, CAS# and WE# all high). A controller that leaves a command on the bus for the
// second slot of an sclk, as the old one did behind its CS# deselect, presents it twice,
// and the per-bank and inter-command rules below see the second copy. RESET# is the
// testbench's to drive, the way the board's reset circuit drives it: low while the
// system is in reset and released with it. That also means the 200 us the DRAM wants it
// held low is the board's to provide and is no longer checked here (it was a check of the
// controller's own RESET# pulse). What the controller still owns, and this file checks, is
// the other half of JEDEC's power-up step 2: CKE may not rise until 500 us after RESET#
// went high.
// ---- A reset of the controller that is not a reset of the DRAM (Phase 9 Stage 3) ----
// The debugger's `ndmreset` and a bitstream loaded over a powered board reset the controller and not the DRAM
// (rtl/soc/ddr3_init_seq.v's header says so): CKE falls while RESET# stays high, and the initialisation runs again
// against a DRAM that has kept its mode registers, its open rows and whatever burst it was in. Until now this file
// was single-shot: it judged one power-up and called every MRS after it "unexpected". It now treats a fall of CKE
// with RESET# high, after the initialisation, as the start of a warm restart, and holds it to what the DRAM requires
// of that, reasoned from the DDR3 standard (JESD79-3) and not from the primary datasheet, which nothing here has read:
//   - CKE may not fall while a write or its recovery is in progress (tWRPDEN = WL + 4 + tWR + 1) or while a read's
//     burst is (tRDPDEN = RL + 4 + 1): the DRAM would lose the clock enable in the middle of a burst;
//   - the first command after CKE rises waits tXP (3 CK) - the rule already here for the first MRS of a power-up;
//   - an MRS needs every bank precharged, so one issued with a bank open (an ACTIVATE not yet precharged) is a
//     violation, and the initialisation has no PRECHARGE of its own;
//   - the MR2, MR3, MR1, MR0, ZQCL order and the waits between them are checked again, as at power-up.
// A fall of CKE with RESET# low is the board's reset and nothing here: the DRAM is starting over too.
//
// And the restart that keeps CKE up (the controller's ndmreset, rtl/soc/ddr3_init_seq.v): the DRAM sees no reset at all, only a
// mode-register write at idle, which JESD79-3 allows at any time. An MRS after the initialisation is accepted if it is MR2
// (the start of the order again) and every bank is precharged (the bank rule below; a burst on the DRAM means a bank is open,
// so it is covered by that, and the PRECHARGE before it is held to tRAS, tRTP and write recovery by the per-bank rules);
// it re-arms the order check and the rest is held to the same rules as at power-up. tRP is not checked: at this design's
// clock no controller could miss it.
module ddr3_model #(
    parameter CLK_HZ = 25_000_000
)(
    input  wire        ck,        // ddr3_ck: every command is sampled on its rising edge, and every count below is in CK cycles
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [2:0]  ba,
    input  wire [14:0] a,         // A0-A14: the part is 4 Gb x16 and has no A15
    input  wire        cke,
    input  wire        reset_n,
    input  wire        odt,

    output reg          error,
    output reg  [511:0] error_msg,
    output reg           seq_done   // real MR2->MR3->MR1->MR0->ZQCL order completed, timing respected
);
    // CLK_HZ is sclk's rate, as every caller passes it; CK runs at twice that
    // (rtl/soc/ddr3_phy_ecp5.v, Part 16), and this file samples and counts on
    // CK, so a nanosecond figure becomes cycles at the CK rate.
    localparam CK_HZ = 2 * CLK_HZ;
    // 64-bit, as rtl/soc/ddr3_init_seq.v's macro is since Part 27: 500 us at the CK rate is 2.5e10 before the
    // division, which wraps in a 32-bit constant (see there for what that did before).
    `define NS2CYC(ns) 32'((((64'd1) * (ns) * (CK_HZ / 1000) + 999_999) / 1_000_000))
    // JEDEC power-up step 2: "After RESET# is de-asserted, wait for another 500 us until CKE
    // becomes active." (Step 1, 200 us of RESET# low, is the board's: see the header.)
    localparam [31:0] RESET_TO_CKE_MIN_CYC = `NS2CYC(500_000);
    localparam MRD_MIN_CYC   = 4;                  // tMRD minimum, cycle count not ns
    localparam ZQINIT_MIN_CYC = 512;               // tZQinit/tDLLK minimum, cycle count not ns
    // Part 12: Micron MT41K256M16 (4Gb) datasheet Figure 40, note 5 -
    // "Only NOP and DES commands are allowed after a REFRESH command and
    // until tRFC (MIN) is satisfied." tRFC(MIN) = 260ns for 4Gb.
    localparam [31:0] RFC_MIN_CYC = `NS2CYC(260);

    // Part 14: per-bank state. Values are from the same datasheet (4Gb
    // DDR3L, speed-bin tables and the timing-parameter table). Since Part 16
    // every count here is in real CK cycles, sampled on CK's own rising edge:
    // a CK-count minimum (tRTP, tWR in DLL-off mode, CWL, BL/2) is the
    // datasheet's number as written, and a nanosecond figure goes through
    // NS2CYC at the CK rate (20 ns per CK at sclk = 25 MHz).
    // tRAS (34-37.5 ns) is two CK and IS checked - it can fire, because the
    // self-test can place a PRECHARGE one CK after an ACTIVATE. tRCD
    // (13.5-15 ns) and tRP (13.125-15 ns) are one CK each, so the closest
    // two commands can be is already legal and a rule for them cannot fire;
    // tRC (47.9-52.5 ns, three CK) is tRAS plus tRP, implied by the two.
    // A rule that cannot fire cannot be tested, so those three are not here.
    localparam [31:0] RAS_MIN_CYC = `NS2CYC(38);   // tRAS, worst bin 37.5 ns
    localparam RTP_MIN_CYC = 4;             // tRTP = greater of 4CK or 7.5 ns
    localparam WR_REC_CYC  = 4;             // tWR = greater of 4CK or 15 ns in DLL-off mode (note 33)
    localparam CWL_CYC     = 6;             // MR2, DLL-off
    localparam BL_HALF_CYC = 4;             // BL8 = 4 CK
    // Note 34: write recovery starts four clocks after WL for BL8, so the
    // earliest legal PRECHARGE after a WRITE is WR + CWL + 4 + tWR.
    localparam WR_TO_PRE_MIN_CYC = CWL_CYC + BL_HALF_CYC + WR_REC_CYC;
    // A reset of the controller alone: CKE may fall once a write (and its recovery) or a read has finished, and the
    // first command after it rises waits tXP.
    localparam TXP_MIN_CYC     = 3;                                  // tXP = max(3 CK, 7.5 ns)
    localparam WR_PDEN_CYC     = CWL_CYC + BL_HALF_CYC + WR_REC_CYC + 1;   // tWRPDEN = WL + 4 + tWR + 1
    localparam RL_CYC          = 5;                                  // DLL-off read latency, AL + CL - 1 (see sim/ddr3_dq_model.v, Part 18)
    localparam RD_PDEN_CYC     = RL_CYC + BL_HALF_CYC + 1;           // tRDPDEN = RL + 4 + 1

    // Command decode - same {ras_n,cas_n,we_n} convention
    // rtl/soc/ddr3_phy_ecp5.v itself uses, checked independently here
    // rather than trusted, since this file's whole job is catching a
    // disagreement between the two.
    // While RESET# is low the DRAM is in reset and decodes nothing: the datasheet
    // says every other input, ODT included, "may be undefined" until the reset
    // has been released. The command pins do glitch then - the PHY's registers
    // only come up at its first sclk edge, after CK's first - and a checker that
    // read them would judge whatever a simulator happens to leave there. Icarus
    // leaves x, which no rule matches; a two-state simulator leaves 0, which is
    // an MRS. (With CS# tied low a slot is always selected, so out of reset every slot is
    // decoded, NOP included.)
    wire cmd_present = reset_n;
    wire is_mrs      = cmd_present && !ras_n && !cas_n && !we_n;
    wire is_zqcl      = cmd_present &&  ras_n &&  cas_n && !we_n && a[10];
    wire is_nop       = cmd_present &&  ras_n &&  cas_n &&  we_n;
    // Part 9 (docs/roadmap/phase-09-ddr.md): real post-init ACT/WR/RD traffic from
    // rtl/soc/ddr3_write_seq.v/rtl/soc/ddr3_read_seq.v - the same
    // {ras_n,cas_n,we_n} convention those files themselves use,
    // checked independently here rather than trusted, matching this
    // whole file's own reason for existing.
    wire is_act      = cmd_present && !ras_n &&  cas_n &&  we_n;
    wire is_wr       = cmd_present &&  ras_n && !cas_n && !we_n;
    wire is_rd       = cmd_present &&  ras_n && !cas_n &&  we_n;
    // Part 10: real post-init REFRESH traffic from
    // rtl/soc/ddr3_refresh_ctrl.v - same convention, same reasoning.
    wire is_ref      = cmd_present && !ras_n && !cas_n &&  we_n;
    // Part 14: PRECHARGE (RAS_n=0, CAS_n=1, WE_n=0); A10 high = all banks.
    wire is_pre      = cmd_present && !ras_n &&  cas_n && !we_n;

    localparam [2:0]
        SEQ_WAIT_RESET = 3'd0,
        SEQ_WAIT_CKE   = 3'd1,
        SEQ_WANT_MR2   = 3'd2,
        SEQ_WANT_MR3   = 3'd3,
        SEQ_WANT_MR1   = 3'd4,
        SEQ_WANT_MR0   = 3'd5,
        SEQ_WANT_ZQCL  = 3'd6,
        SEQ_DONE       = 3'd7;

    reg [2:0]  seq_state;
    reg [31:0] since_reset_high;  // CK cycles since RESET# last went high, saturating
    reg        cke_seen_high;     // CKE has been high since RESET# last went high
    reg [31:0] since_last_cmd;    // cycles since the last real (non-NOP) command
    reg [31:0] wait_min_needed;   // the minimum this project's own init sequence itself claims for the current gap
    reg [31:0] since_ref;         // cycles since the last REFRESH command (Part 12)
    reg        ref_seen;
    // A reset of the controller alone: see the header.
    reg        cke_q, reset_n_q;
    reg        warm_pending;      // CKE fell with RESET# high after the initialisation, and has not risen again
    reg [31:0] since_wr_cmd, since_rd_cmd;   // cycles since the last WRITE, READ command, saturating
    reg        wr_cmd_seen, rd_cmd_seen;
    integer    mi;
    reg        any_open;
    reg        bank_open    [0:7];   // per-bank state, tracked below (Part 14)

    task fail(input [511:0] msg);
        begin
            if (!error) begin
                error     <= 1'b1;
                error_msg <= msg;
            end
        end
    endtask

    // RESET# high to CKE high, counted here from the pins - independent of
    // ddr3_init_seq.v's own counter, so a bug in that counter cannot also hide itself from
    // this check. Re-arms every time RESET# goes low, as the DRAM itself starts over.
    always @(posedge ck) begin
        if (!reset_n) begin
            since_reset_high <= 0;
            cke_seen_high    <= 1'b0;
        end else begin
            if (since_reset_high != 32'hFFFF_FFFF) since_reset_high <= since_reset_high + 1;
            if (cke && !cke_seen_high) begin
                cke_seen_high <= 1'b1;
                if (since_reset_high < RESET_TO_CKE_MIN_CYC) begin
                    fail("CKE raised before 500us after RESET_n went high");
                end
            end
        end
    end

    // ---- a reset of the controller alone, from the pins ----
    always @(posedge ck) begin
        cke_q     <= cke;
        reset_n_q <= reset_n;
        if (since_wr_cmd != 32'hFFFF_FFFF) since_wr_cmd <= since_wr_cmd + 1;
        if (since_rd_cmd != 32'hFFFF_FFFF) since_rd_cmd <= since_rd_cmd + 1;
        if (reset_n && cmd_present && is_wr) begin since_wr_cmd <= 0; wr_cmd_seen <= 1'b1; end
        if (reset_n && cmd_present && is_rd) begin since_rd_cmd <= 0; rd_cmd_seen <= 1'b1; end
        if (reset_n && reset_n_q && seq_state == SEQ_DONE && cke_q && !cke) begin
            // CKE falls, the DRAM was not reset
            warm_pending <= 1'b1;
            if (wr_cmd_seen && since_wr_cmd + 1 < WR_PDEN_CYC)
                fail("CKE fell in the middle of a write burst (before tWRPDEN)");
            if (rd_cmd_seen && since_rd_cmd + 1 < RD_PDEN_CYC)
                fail("CKE fell in the middle of a read burst (before tRDPDEN)");
        end
        if (warm_pending && reset_n && !cke_q && cke) warm_pending <= 1'b0;   // the re-arm itself is in the block below
        if (!reset_n) warm_pending <= 1'b0;
    end

    always @(posedge ck) begin
        since_last_cmd <= since_last_cmd + 1;
        since_ref      <= since_ref + 1;

        // CKE rises after a fall with the DRAM not reset: the controller initialises it again, in the same order, and the
        // first command waits tXP from the rise
        if (warm_pending && reset_n && !cke_q && cke) begin
            seq_state       <= SEQ_WANT_MR2;
            seq_done        <= 1'b0;
            wait_min_needed <= TXP_MIN_CYC;
            since_last_cmd  <= 0;
        end

        if (cmd_present && !is_nop) begin
            // A real command is being issued right now - check the
            // minimum gap since the last one against whichever wait
            // this state's own transition requires, then decode it.
            if (since_last_cmd < wait_min_needed) begin
                fail("command issued before the required inter-command wait elapsed");
            end

            // Part 12: nothing but NOP/DES until tRFC has elapsed after a
            // REFRESH. `since_ref` is 0 in the cycle after the REFRESH was
            // sampled, so the gap in cycles is since_ref + 1. Checked here,
            // independent of which module issued the offending command.
            if (ref_seen && (since_ref + 1 < RFC_MIN_CYC)) begin
                fail("command issued during tRFC after REFRESH (only NOP/DES allowed)");
            end

            // An MRS needs every bank precharged (JESD79-3): after a reset of the controller alone, one can be open.
            if (is_mrs) begin
                any_open = 1'b0;
                for (mi = 0; mi < 8; mi = mi + 1) if (bank_open[mi]) any_open = 1'b1;
                if (any_open) fail("MRS with a bank open (all banks must be precharged first)");
            end

            case (seq_state)
                SEQ_WANT_MR2: begin
                    if (is_mrs && ba == 3'b010) begin
                        seq_state       <= SEQ_WANT_MR3;
                        wait_min_needed <= MRD_MIN_CYC;
                        since_last_cmd  <= 0;
                    end else begin
                        fail("expected MRS to MR2 first (JEDEC init order), got something else");
                    end
                end
                SEQ_WANT_MR3: begin
                    if (is_mrs && ba == 3'b011) begin
                        seq_state       <= SEQ_WANT_MR1;
                        wait_min_needed <= MRD_MIN_CYC;
                        since_last_cmd  <= 0;
                    end else begin
                        fail("expected MRS to MR3 second (JEDEC init order), got something else");
                    end
                end
                SEQ_WANT_MR1: begin
                    if (is_mrs && ba == 3'b001) begin
                        if (a[0] !== 1'b1) begin
                            fail("MR1 written but DLL-disable bit (A0) is not set");
                        end
                        seq_state       <= SEQ_WANT_MR0;
                        wait_min_needed <= MRD_MIN_CYC;
                        since_last_cmd  <= 0;
                    end else begin
                        fail("expected MRS to MR1 third (JEDEC init order), got something else");
                    end
                end
                SEQ_WANT_MR0: begin
                    if (is_mrs && ba == 3'b000) begin
                        seq_state       <= SEQ_WANT_ZQCL;
                        wait_min_needed <= MRD_MIN_CYC;
                        since_last_cmd  <= 0;
                    end else begin
                        fail("expected MRS to MR0 fourth (JEDEC init order), got something else");
                    end
                end
                SEQ_WANT_ZQCL: begin
                    if (is_zqcl) begin
                        for (mi = 0; mi < 8; mi = mi + 1) bank_open[mi] <= 1'b0;   // the DRAM took the MRS, so every bank was idle
                        seq_state       <= SEQ_DONE;
                        wait_min_needed <= ZQINIT_MIN_CYC;
                        since_last_cmd  <= 0;
                    end else begin
                        fail("expected ZQCL fifth (JEDEC init order), got something else");
                    end
                end
                SEQ_DONE: begin
                    // Part 9/10/14: real ACT/WR/RD/PRECHARGE/REFRESH
                    // traffic (rtl/soc/ddr3_write_seq.v/
                    // rtl/soc/ddr3_read_seq.v/rtl/soc/ddr3_refresh_ctrl.v)
                    // is a legitimate post-init scenario, accepted here
                    // rather than flagged - anything else (a stray MRS
                    // or ZQCL, neither of which this design ever
                    // re-issues after init) still is, since that really
                    // would be a protocol violation. Whether each
                    // accepted command is legal FOR THE STATE OF ITS
                    // BANK is the separate per-bank tracker below
                    // (Part 14). tRCD/CWL/CL timing themselves are not
                    // re-verified here -
                    // rtl/soc/ddr3_write_seq.v's/rtl/soc/ddr3_read_seq.v's/
                    // rtl/soc/ddr3_refresh_ctrl.v's own standalone tests
                    // (Parts 6/7/10/14) already measure and
                    // mutation-test that directly.
                    if (is_mrs) begin
                        // A mode-register write at idle with CKE up: the controller starting its initialisation again
                        // after a reset of its own (header). The bank rule above has already been applied.
                        if (ba == 3'b010) begin
                            seq_state       <= SEQ_WANT_MR3;
                            seq_done        <= 1'b0;
                            wait_min_needed <= MRD_MIN_CYC;
                            since_last_cmd  <= 0;
                        end else begin
                            fail("MRS after the initialisation that does not start the order again with MR2");
                        end
                    end else if (!(is_act || is_wr || is_rd || is_ref || is_pre)) begin
                        fail("unexpected command after init sequence completed");
                    end
                    if (is_ref) begin
                        ref_seen  <= 1'b1;
                        since_ref <= 0;
                    end
                end
                default: ;
            endcase
        end

        if (seq_state == SEQ_DONE && since_last_cmd >= ZQINIT_MIN_CYC) begin
            seq_done <= 1'b1;
        end
    end

    // ---- Part 14: per-bank state tracking, independent of which module
    // issued a command ----
    // Datasheet, ACTIVATE: "This row remains open (or active) for accesses
    // until a PRECHARGE command is issued to that bank. A PRECHARGE command
    // must be issued before opening a different row in the same bank."
    // REFRESH needs every bank precharged (Figure 40 shows PRECHARGE-all
    // then tRP ahead of it). A PRECHARGE to a bank with no open row is a NOP.
    integer    since_act    [0:7];
    integer    since_rd     [0:7];
    integer    since_wr     [0:7];
    reg        rd_after_act [0:7];
    reg        wr_after_act [0:7];
    integer    bi;

    always @(posedge ck) begin
        for (bi = 0; bi < 8; bi = bi + 1) begin
            since_act[bi] <= since_act[bi] + 1;
            since_rd[bi]  <= since_rd[bi]  + 1;
            since_wr[bi]  <= since_wr[bi]  + 1;
        end

        if (seq_state == SEQ_DONE && cmd_present && !is_nop) begin
            if (is_act) begin
                if (bank_open[ba])
                    fail("ACTIVATE to a bank that is already open (no PRECHARGE first)");
                bank_open[ba]    <= 1'b1;
                since_act[ba]    <= 0;
                rd_after_act[ba] <= 1'b0;
                wr_after_act[ba] <= 1'b0;
            end else if (is_rd || is_wr) begin
                if (!bank_open[ba])
                    fail("READ or WRITE to a bank that is not open");
                if (is_rd) begin
                    since_rd[ba]     <= 0;
                    rd_after_act[ba] <= 1'b1;
                end else begin
                    since_wr[ba]     <= 0;
                    wr_after_act[ba] <= 1'b1;
                end
            end else if (is_pre) begin
                for (bi = 0; bi < 8; bi = bi + 1) begin
                    if (a[10] || (bi == ba)) begin
                        if (bank_open[bi]) begin
                            if (since_act[bi] + 1 < RAS_MIN_CYC)
                                fail("PRECHARGE before tRAS elapsed after ACTIVATE");
                            if (rd_after_act[bi] && (since_rd[bi] + 1 < RTP_MIN_CYC))
                                fail("PRECHARGE before tRTP elapsed after READ");
                            if (wr_after_act[bi] && (since_wr[bi] + 1 < WR_TO_PRE_MIN_CYC))
                                fail("PRECHARGE before write recovery elapsed after WRITE");
                        end
                        bank_open[bi] <= 1'b0;
                    end
                end
            end else if (is_ref) begin
                for (bi = 0; bi < 8; bi = bi + 1) begin
                    if (bank_open[bi])
                        fail("REFRESH with a bank still open (all banks must be precharged)");
                end
            end
        end
    end

    initial begin
        for (bi = 0; bi < 8; bi = bi + 1) begin
            bank_open[bi] = 1'b0;
            rd_after_act[bi] = 1'b0; wr_after_act[bi] = 1'b0;
            since_act[bi] = 0; since_rd[bi] = 0; since_wr[bi] = 0;
        end
        error           = 1'b0;
        error_msg       = "";
        seq_done        = 1'b0;
        seq_state       = SEQ_WANT_MR2;
        since_reset_high = 0;
        cke_seen_high   = 1'b0;
        since_last_cmd  = 0;
        wait_min_needed = 0;
        since_ref       = 0;
        ref_seen        = 1'b0;
        cke_q = 1'b0; reset_n_q = 1'b0; warm_pending = 1'b0;
        since_wr_cmd = 32'hFFFF_FFFF; since_rd_cmd = 32'hFFFF_FFFF; wr_cmd_seen = 1'b0; rd_cmd_seen = 1'b0;
        any_open = 1'b0;
    end

    `undef NS2CYC
endmodule
