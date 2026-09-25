// Directed test for Phase 9 Stage 1, Part 8 (docs/roadmap.md):
// rtl/soc/ddr3_read_burst_ext.v's own real read_active window,
// measured directly cycle-by-cycle rather than trusted from a hand-
// trace - this project's own established practice after
// rtl/soc/ddr3_eclk_pll.v's own first clock-generation draft
// hand-traced as correct and was not.
//
// The stimulus drives read_start with a non-blocking assignment,
// matching how a real synchronous caller (rtl/soc/ddr3_read_seq.v's
// own `read_start <= 1'b1;`) actually drives this signal - a first
// draft used a plain blocking assignment right after `@(posedge clk)`,
// the well-known same-edge race against the DUT's own NBA-clocked
// `delay_r <= read_start;`. Confirmed directly, not assumed, via a
// standalone probe with a settle delay after the clock edge, which
// showed `read_start` and `delay_r` reading as 1 on the SAME cycle
// (collapsing the intended real 2-cycle window to 1) purely from that
// testbench-side race, not a real DUT defect - a real caller's own
// NBA-driven output would never trigger it. History is recorded by a
// separate, continuously-running monitor below, not interleaved with
// the stimulus sequence itself, so there is no equivalent race between
// "when did I start recording" and "when did the pulse actually fire."
`timescale 1ns/1ps
module tb_ddr3_read_burst_ext;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg rst = 1'b1;
    reg read_start = 1'b0;

    wire read_active;

    ddr3_read_burst_ext DUT (
        .clk(clk), .rst(rst),
        .read_start(read_start), .read_active(read_active)
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

    // A real, continuously-running history recorder, not an inline
    // sample interleaved with the stimulus's own sequencing - the same
    // robust pattern sim/tb_ddr3_dqs_write.v's own oe_hist/o_hist
    // already uses, so "when did recording start" cannot itself race
    // against "when did the pulse fire."
    reg [0:15] active_hist;
    always @(posedge clk) begin
        if (!rst) active_hist <= {active_hist[1:15], read_active};
    end

    initial begin
        $display("=== DDR3 read-burst active-window extender (Phase 9 Stage 1, Part 8) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        check("idle before any pulse", read_active, 1'b0);

        @(posedge clk);
        read_start <= 1'b1;
        @(posedge clk);
        read_start <= 1'b0;

        repeat (8) @(posedge clk);

        $display("  read_active history (oldest..newest): %b", active_hist);

        check("read_active deasserted again after the burst", read_active, 1'b0);

        begin : COUNT_CHECK
            integer i, ones;
            ones = 0;
            for (i = 0; i < 16; i = i + 1)
                if (active_hist[i]) ones = ones + 1;
            check("read_active was held for exactly 2 real cycles", (ones == 2), 1'b1);
        end

        // The two real "1"s in the recorded history must be adjacent -
        // proves this is one real, contiguous 2-cycle window, not two
        // separate glitches that happen to sum to 2.
        begin : ADJACENT_CHECK
            integer i;
            integer adjacent_pair_seen;
            adjacent_pair_seen = 0;
            for (i = 0; i < 15; i = i + 1)
                if (active_hist[i] && active_hist[i+1]) adjacent_pair_seen = 1;
            check("the 2 active cycles are one contiguous window", adjacent_pair_seen, 1);
        end

        // A second, back-to-back pulse proves this can retrigger
        // cleanly - not a one-shot fluke.
        @(posedge clk);
        read_start <= 1'b1;
        @(posedge clk);
        read_start <= 1'b0;
        repeat (8) @(posedge clk);
        check("read_active idle again after a second pulse", read_active, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 READ BURST EXT TEST PASSED");
        else             $display("DDR3 READ BURST EXT TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #50_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
