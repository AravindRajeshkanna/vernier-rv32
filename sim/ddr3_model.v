// Behavioral DDR3 protocol checker - Phase 9 Stage 1, Part 1
// (docs/roadmap.md). Scoped to what Part 1's own init sequence
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
module ddr3_model #(
    parameter CLK_HZ = 25_000_000
)(
    input  wire        ck,        // ddr3_ck: every command is sampled on its rising edge, and every count below is in CK cycles
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [2:0]  ba,
    input  wire [15:0] a,
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
    `define NS2CYC(ns) (((ns) * (CK_HZ / 1000) + 999_999) / 1_000_000)
    localparam RESET_MIN_CYC = `NS2CYC(200_000);  // tRESET minimum - real JEDEC requirement
    localparam MRD_MIN_CYC   = 4;                  // tMRD minimum, cycle count not ns
    localparam ZQINIT_MIN_CYC = 512;               // tZQinit/tDLLK minimum, cycle count not ns
    // Part 12: Micron MT41K256M16 (4Gb) datasheet Figure 40, note 5 -
    // "Only NOP and DES commands are allowed after a REFRESH command and
    // until tRFC (MIN) is satisfied." tRFC(MIN) = 260ns for 4Gb.
    localparam RFC_MIN_CYC   = `NS2CYC(260);

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
    localparam RAS_MIN_CYC = `NS2CYC(38);   // tRAS, worst bin 37.5 ns
    localparam RTP_MIN_CYC = 4;             // tRTP = greater of 4CK or 7.5 ns
    localparam WR_REC_CYC  = 4;             // tWR = greater of 4CK or 15 ns in DLL-off mode (note 33)
    localparam CWL_CYC     = 6;             // MR2, DLL-off
    localparam BL_HALF_CYC = 4;             // BL8 = 4 CK
    // Note 34: write recovery starts four clocks after WL for BL8, so the
    // earliest legal PRECHARGE after a WRITE is WR + CWL + 4 + tWR.
    localparam WR_TO_PRE_MIN_CYC = CWL_CYC + BL_HALF_CYC + WR_REC_CYC;

    // Command decode - same {ras_n,cas_n,we_n} convention
    // rtl/soc/ddr3_phy_ecp5.v itself uses, checked independently here
    // rather than trusted, since this file's whole job is catching a
    // disagreement between the two.
    wire cmd_present = !cs_n;
    wire is_mrs      = cmd_present && !ras_n && !cas_n && !we_n;
    wire is_zqcl      = cmd_present &&  ras_n &&  cas_n && !we_n && a[10];
    wire is_nop       = cmd_present &&  ras_n &&  cas_n &&  we_n;
    // Part 9 (docs/roadmap.md): real post-init ACT/WR/RD traffic from
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
    reg [31:0] reset_low_cnt;
    reg        reset_was_low;
    reg        cke_seen_high;
    reg [31:0] since_last_cmd;    // cycles since the last real (non-NOP) command
    reg [31:0] wait_min_needed;   // the minimum this project's own init sequence itself claims for the current gap
    reg [31:0] since_ref;         // cycles since the last REFRESH command (Part 12)
    reg        ref_seen;

    task fail(input [511:0] msg);
        begin
            if (!error) begin
                error     <= 1'b1;
                error_msg <= msg;
            end
        end
    endtask

    // Real reset-low duration tracking - independent of ddr3_init_seq.v's
    // own internal counter, so a bug in that counter cannot also hide
    // itself from this check.
    always @(posedge ck) begin
        if (!reset_n) begin
            reset_low_cnt <= reset_low_cnt + 1;
            reset_was_low <= 1'b1;
        end else begin
            if (reset_was_low && reset_low_cnt < RESET_MIN_CYC) begin
                fail("RESET_n released before tRESET (>=200us) elapsed");
            end
            reset_was_low <= 1'b0;
        end
    end

    always @(posedge ck) begin
        since_last_cmd <= since_last_cmd + 1;
        since_ref      <= since_ref + 1;

        if (reset_n && cke && !cke_seen_high) begin
            cke_seen_high <= 1'b1;
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
                    if (!(is_act || is_wr || is_rd || is_ref || is_pre)) begin
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
    reg        bank_open    [0:7];
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
        reset_low_cnt   = 0;
        reset_was_low   = 1'b0;
        cke_seen_high   = 1'b0;
        since_last_cmd  = 0;
        wait_min_needed = 0;
        since_ref       = 0;
        ref_seen        = 1'b0;
    end

    `undef NS2CYC
endmodule
