// Directed test for rtl/soc/tmds_encode.v against hand-derived vectors, not
// just "it runs" - see that module's header for how each vector below was
// worked out from the DVI 1.0 spec's own encode algorithm.
//
// Three things are checked, because a per-symbol lookup table would pass
// the first and fail the other two:
//   1. Stage 1 (transition minimization) on two disparity-independent
//      inputs, where the same code comes out regardless of history.
//   2. Stage 2 (disparity tracking) on the two most unbalanced inputs,
//      fed twice in a row - the second occurrence must flip encoding to
//      compensate for the first, which only a stateful encoder can do.
//   3. The four fixed control tokens, verbatim against the spec.
`timescale 1ns/1ps
module tb_tmds_encode;
    reg        clk = 0;
    reg        rst = 1;
    always #20 clk = ~clk;    // 25 MHz, this SoC's own pixel clock

    reg  [7:0] d = 8'b0;
    reg        c0 = 1'b0, c1 = 1'b0, de = 1'b0;
    wire [9:0] q_out;

    tmds_encode UUT (
        .clk(clk), .rst(rst),
        .d(d), .c0(c0), .c1(c1), .de(de),
        .q_out(q_out)
    );

    integer errors = 0;

    // Name fields are 400 bits (50 ASCII characters) - generous headroom
    // over the longest label below, since Verilog silently truncates a
    // string literal from the left if it overflows the vector width, which
    // would garble the log rather than fail the build.
    task check(input [399:0] name, input [9:0] got, input [9:0] expected);
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: got %010b expected %010b", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: %010b", name, got);
            end
        end
    endtask

    task check_cnt(input [399:0] name, input signed [5:0] got, input signed [5:0] expected);
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: cnt got %0d expected %0d", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: cnt %0d", name, got);
            end
        end
    endtask

    // `#1` after every `@(posedge clk)` that precedes a read of q_out/cnt:
    // this is an `initial` block, and the DUT's outputs are updated by a
    // non-blocking assignment in a *different* `always @(posedge clk)`
    // block reacting to the same edge. Reading them with no delay in
    // between is exactly the same-edge testbench race sim/tb_video.v's own
    // scan-out capture is a dedicated `always @(posedge clk)` block to
    // avoid - unlike that capture loop, these checks are one-shot and
    // sequential, so the simpler fix is a settling delay rather than a
    // second always block. Confirmed as the actual bug here, not a
    // precaution: without it every check below read the *previous* check's
    // result one edge late.
    initial begin
        @(posedge clk); @(posedge clk);
        rst = 0;
        @(posedge clk); #1;

        // ---- 1. disparity-independent vectors (stage 1 alone) ----
        // 0x10 = 00010000: one set bit -> XOR chain, already balanced
        // (4 ones, 4 zeros in q_m), so cnt==0 is not a precondition, just
        // the state this happens to start in after reset.
        d = 8'h10; de = 1'b1; c0 = 1'b0; c1 = 1'b0;
        @(posedge clk); #1;
        check("0x10 (XOR, balanced)", q_out, 10'b0111110000);
        check_cnt("cnt after 0x10", UUT.cnt, 6'sd0);

        // 0xEF = 11101111: seven set bits -> XNOR chain, also balanced.
        d = 8'hEF;
        @(posedge clk); #1;
        check("0xEF (XNOR, balanced)", q_out, 10'b1011110000);
        check_cnt("cnt after 0xEF", UUT.cnt, 6'sd0);

        // ---- 2. disparity tracking: the two extremes, twice each ----
        // 0x00 from a freshly zeroed counter: XOR chain of all zeros is
        // all zeros, maximally unbalanced (0 ones, 8 zeros) - cnt is 0
        // here (set by 0xEF above), so the "balanced_now" branch applies
        // and the un-inverted code goes out.
        d = 8'h00;
        @(posedge clk); #1;
        check("0x00 first (cnt was 0)", q_out, 10'b0100000000);
        check_cnt("cnt after first 0x00", UUT.cnt, -6'sd8);

        // Same byte again, with cnt now -8: stage 2 must flip to the
        // inverted code to pull the running disparity back the other way.
        // A stateless table would emit 0x100 again and be wrong.
        d = 8'h00;
        @(posedge clk); #1;
        check("0x00 second (cnt was -8, must flip)", q_out, 10'b1111111111);
        check_cnt("cnt after second 0x00", UUT.cnt, 6'sd2);

        // Blanking resets cnt to 0 regardless of what active video left it
        // at - the next line must not inherit the previous line's bias.
        de = 1'b0; c0 = 1'b0; c1 = 1'b0;
        @(posedge clk); #1;
        check_cnt("cnt reset by blanking", UUT.cnt, 6'sd0);

        // 0xFF from a freshly zeroed counter: mirror image of 0x00 above -
        // XNOR chain of all ones is all ones, maximally unbalanced the
        // other way.
        d = 8'hFF; de = 1'b1;
        @(posedge clk); #1;
        check("0xFF first (cnt was 0)", q_out, 10'b1000000000);
        check_cnt("cnt after first 0xFF", UUT.cnt, -6'sd8);

        d = 8'hFF;
        @(posedge clk); #1;
        check("0xFF second (cnt was -8, must flip)", q_out, 10'b0011111111);

        // ---- 3. control tokens: fixed values from the DVI spec ----
        de = 1'b0;
        c0 = 1'b0; c1 = 1'b0; @(posedge clk); #1;
        check("ctrl c1c0=00", q_out, 10'b1101010100);
        c0 = 1'b1; c1 = 1'b0; @(posedge clk); #1;
        check("ctrl c1c0=01", q_out, 10'b0010101011);
        c0 = 1'b0; c1 = 1'b1; @(posedge clk); #1;
        check("ctrl c1c0=10", q_out, 10'b0101010100);
        c0 = 1'b1; c1 = 1'b1; @(posedge clk); #1;
        check("ctrl c1c0=11", q_out, 10'b1010101011);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("TMDS-ENCODE-TEST: PASS");
        else             $display("TMDS-ENCODE-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the TMDS encoder test never completed");
        $finish;
    end
endmodule
