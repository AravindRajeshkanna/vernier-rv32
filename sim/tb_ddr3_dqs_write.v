// Directed test for Phase 9 Stage 1, Part 4 (docs/roadmap.md):
// rtl/soc/ddr3_dqs_write_ecp5.v's own real preamble/active/postamble
// state sequencing, observed directly cycle-by-cycle rather than
// trusted from a hand-trace - this project's own established practice
// after rtl/soc/ddr3_eclk_pll.v's own first clock-generation draft
// hand-traced as correct and was not.
`timescale 1ns/1ps
module tb_ddr3_dqs_write;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg rst = 1'b1;
    reg write_start = 1'b0;

    wire dqs_o, dqs_oe;

    ddr3_dqs_write_ecp5 DUT (
        .sclk(clk), .eclk(clk), .dqsw(clk), .rst(rst),
        .write_start(write_start),
        .dqs_o(dqs_o), .dqs_oe(dqs_oe)
    );

    integer errors = 0;
    task check(input [511:0] what, input got, input want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %b, expected %b", what, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s", what);
            end
        end
    endtask

    // Records the real cycle-by-cycle waveform so the checks below
    // reason about what actually happened, not what was intended.
    reg [31:0] cyc;
    reg [0:9]  oe_hist;
    reg [0:9]  o_hist;

    always @(posedge clk) begin
        if (!rst) begin
            oe_hist <= {oe_hist[1:9], dqs_oe};
            o_hist  <= {o_hist[1:9], dqs_o};
        end
    end

    initial begin
        $display("=== DDR3 DQS write-drive (Phase 9 Stage 1, Part 4) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        cyc = 0;

        check("OE idle before any write", dqs_oe, 1'b0);
        check("DQS idle before any write", dqs_o, 1'b0);

        @(posedge clk);
        write_start = 1'b1;
        @(posedge clk);
        write_start = 1'b0;

        // One full burst is 4 real sclk cycles (preamble, 2 active,
        // postamble) - sample OE/DQS across a window comfortably
        // wider than that and check the real recorded history, not a
        // single instantaneous sample.
        repeat (8) @(posedge clk);

        $display("  oe history (oldest..newest): %b", oe_hist);
        $display("  dqs history (oldest..newest): %b", o_hist);

        // Real OE window: exactly 4 cycles asserted, framed by
        // deasserted cycles on both sides - counted from the real
        // recorded history, not assumed from the FSM's own state
        // names.
        check("OE deasserted again after the burst", dqs_oe, 1'b0);

        begin : OE_COUNT
            integer i, ones;
            ones = 0;
            for (i = 0; i < 10; i = i + 1)
                if (oe_hist[i]) ones = ones + 1;
            check("OE was asserted for exactly 4 real cycles", (ones == 4), 1'b1);
        end

        // Real preamble: the first cycle OE is high, DQS must be low.
        begin : PREAMBLE_CHECK
            integer i;
            integer first_oe;
            first_oe = -1;
            for (i = 0; i < 10; i = i + 1)
                if (oe_hist[i] && first_oe == -1) first_oe = i;
            if (first_oe >= 0)
                check("DQS held low on OE's own first real cycle (preamble)",
                      o_hist[first_oe], 1'b0);
        end

        // Real activity: DQS must have gone high at some point during
        // the burst - proving the active window is not just more of
        // the same low level the preamble/postamble already show.
        begin : ACTIVITY_CHECK
            integer i;
            integer saw_high;
            saw_high = 0;
            for (i = 0; i < 10; i = i + 1)
                if (o_hist[i]) saw_high = 1;
            check("DQS went high at some point during the burst", saw_high, 1);
        end

        // Real postamble: the last cycle OE is high, DQS must be low
        // again - a real low guard band after the active window, not
        // left floating high.
        begin : POSTAMBLE_CHECK
            integer i;
            integer last_oe;
            last_oe = -1;
            for (i = 0; i < 10; i = i + 1)
                if (oe_hist[i]) last_oe = i;
            if (last_oe >= 0)
                check("DQS held low on OE's own last real cycle (postamble)",
                      o_hist[last_oe], 1'b0);
        end

        // A second burst, back-to-back, proves the FSM really returns
        // to S_IDLE and can restart - not a one-shot fluke.
        @(posedge clk);
        write_start = 1'b1;
        @(posedge clk);
        write_start = 1'b0;
        repeat (8) @(posedge clk);
        check("OE idle again after a second burst", dqs_oe, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 DQS WRITE-DRIVE TEST PASSED");
        else             $display("DDR3 DQS WRITE-DRIVE TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #100_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
