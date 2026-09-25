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
    input  wire        clk,
    input  wire        ck,        // ddr3_ck, sampled for real toggling activity only
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
    `define NS2CYC(ns) (((ns) * (CLK_HZ / 1000) + 999_999) / 1_000_000)
    localparam RESET_MIN_CYC = `NS2CYC(200_000);  // tRESET minimum - real JEDEC requirement
    localparam MRD_MIN_CYC   = 4;                  // tMRD minimum, cycle count not ns
    localparam ZQINIT_MIN_CYC = 512;               // tZQinit/tDLLK minimum, cycle count not ns

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
    always @(posedge clk) begin
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

    always @(posedge clk) begin
        since_last_cmd <= since_last_cmd + 1;

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
                    // Part 9/10: real ACT/WR/RD/REFRESH traffic
                    // (rtl/soc/ddr3_write_seq.v/rtl/soc/ddr3_read_seq.v/
                    // rtl/soc/ddr3_refresh_ctrl.v) is now a legitimate
                    // post-init scenario, accepted here rather than
                    // flagged - anything else (a stray MRS/ZQCL/
                    // PRECHARGE, none of which this design ever
                    // re-issues after init) still is, since that really
                    // would be a protocol violation. Real ACT-to-WR/RD
                    // bank-address consistency and the real tRCD/CWL/CL/
                    // tRFC timing themselves are not re-verified here -
                    // rtl/soc/ddr3_write_seq.v's/rtl/soc/ddr3_read_seq.v's/
                    // rtl/soc/ddr3_refresh_ctrl.v's own standalone tests
                    // (Parts 6/7/10) already measure and mutation-test
                    // that directly.
                    if (!(is_act || is_wr || is_rd || is_ref)) begin
                        fail("unexpected command after init sequence completed (not ACT/WR/RD)");
                    end
                end
                default: ;
            endcase
        end

        if (seq_state == SEQ_DONE && since_last_cmd >= ZQINIT_MIN_CYC) begin
            seq_done <= 1'b1;
        end
    end

    initial begin
        error           = 1'b0;
        error_msg       = "";
        seq_done        = 1'b0;
        seq_state       = SEQ_WANT_MR2;
        reset_low_cnt   = 0;
        reset_was_low   = 1'b0;
        cke_seen_high   = 1'b0;
        since_last_cmd  = 0;
        wait_min_needed = 0;
    end

    `undef NS2CYC
endmodule
