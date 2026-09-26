// Self-test for the write-burst rules added to sim/ddr3_dq_model.v in Phase 9
// Stage 1, Part 17 (docs/roadmap.md). Same discipline as
// sim/tb_ddr3_model_banks.v: a checker whose rules cannot be shown to fire is
// not a checker, and the real design, once aligned, never breaks them - so each
// rule gets its own directed stream on its own model instance, driven straight
// onto its pins, plus legal controls so a rule that is too strict fails here
// instead of silently rejecting a correct controller.
//
// Every instance sees the same command sequence - an ACTIVATE, then a WRITE
// three sclk later (W = the cycle the WRITE is driven in) - and differs only in
// what its DQS and DQ pins do around W. Relative to W the legal burst is:
//     W+2 DQS low   W+3 DQS active, DQ driven   W+4 DQS active, DQ driven
//     W+5 DQS low   everything else high-Z
//   0  legal
//   1  legal, and DQ driven during the preamble and postamble too - the DRAM
//      ignores DQ there, so a rule that rejects it is too strict
//   2  the whole burst one cycle early
//   3  the whole burst one cycle late
//   4  DQ not driven in the second active cycle
//   5  DQ not driven in the first active cycle
//   6  DQS absent in the first active cycle
//   7  no preamble (DQS high-Z the cycle before the burst)
//   8  no postamble (DQS high-Z the cycle after)
//   9  DQS driven again after the burst
//  10  a DQS burst with no WRITE behind it (a READ, then the burst)
`timescale 1ns/1ps
module tb_ddr3_dq_window_rules;
    localparam CLK_PERIOD = 40;
    localparam N          = 11;

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    // the edge clock, whose rising edges fall 10 ns after each clk edge - CK
    wire eclk, pll_sclk, pll_locked;
    ddr3_eclk_pll PLL (.clk(clk), .eclk(eclk), .sclk(pll_sclk), .locked(pll_locked));
    wire ck = eclk;

    reg [N-1:0]      cs_n  = {N{1'b1}};
    reg [N-1:0]      ras_n = {N{1'b1}};
    reg [N-1:0]      cas_n = {N{1'b1}};
    reg [N-1:0]      we_n  = {N{1'b1}};
    reg [3*N-1:0]    ba    = {3*N{1'b0}};
    reg [16*N-1:0]   a     = {16*N{1'b0}};
    reg [8*N-1:0]    dq    = {8*N{1'bz}};
    reg [N-1:0]      dqs   = {N{1'bz}};

    wire [N-1:0]     errs;
    wire [512*N-1:0] msgs;
    wire [8*N-1:0]   peeked;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : M
            wire        e;
            wire [511:0] m;
            wire [7:0]  mq_o;
            wire        mq_oe, mqs_o;
            ddr3_dq_model MODEL (
                .sclk(clk), .rst(rst), .ck(ck),
                .cs_n(cs_n[g]), .ras_n(ras_n[g]), .cas_n(cas_n[g]), .we_n(we_n[g]),
                .ba(ba[3*g +: 3]), .a(a[16*g +: 16]),
                .dq_pin(dq[8*g +: 8]), .dqs_pin(dqs[g]),
                .read_active(1'b0),
                .mem_dq_o(mq_o), .mem_dq_oe(mq_oe), .mem_dqs_o(mqs_o),
                .dq_error(e), .dq_error_msg(m)
            );
            assign errs[g] = e;
            assign msgs[512*g +: 512] = m;
            // peek() reads the model's internal store, so it has to be re-evaluated as that
            // changes - a continuous assign of a function of constants would not be.
            reg [7:0] pk;
            always @(posedge clk) pk = MODEL.peek(3'd1, 16'h0123, 16'h000A);
            assign peeked[8*g +: 8] = pk;
        end
    endgenerate

    localparam [15:0] ROW = 16'h0123;
    localparam [15:0] COL = 16'h000A;

    // the legal burst, as {dq_driven, byte, dqs} with dqs 0=low 1=high 2=z, at offset k from W
    function [10:0] legal(input integer k, input [7:0] byte_v);
        begin
            case (k)
                2:       legal = {1'b0, 8'h00,  2'd0};
                3, 4:    legal = {1'b1, byte_v, 2'd1};
                5:       legal = {1'b0, 8'h00,  2'd0};
                default: legal = {1'b0, 8'h00,  2'd2};
            endcase
        end
    endfunction

    function [10:0] pattern(input integer c, input integer k);
        reg [10:0] p;
        reg [7:0]  bv;
        begin
            bv = 8'hA0 + c;
            p  = legal(k, bv);
            case (c)
                1:  if (k == 2 || k == 5) p[10:2] = {1'b1, 8'h5C};
                2:  p = legal(k + 1, bv);
                3:  p = legal(k - 1, bv);
                4:  if (k == 4) p[10:2] = {1'b0, 8'h00};
                5:  if (k == 3) p[10:2] = {1'b0, 8'h00};
                6:  if (k == 3) p[1:0] = 2'd2;
                7:  if (k == 2) p[1:0] = 2'd2;
                8:  if (k == 5) p[1:0] = 2'd2;
                9:  if (k == 6) p[1:0] = 2'd0;
                default: ;
            endcase
            pattern = p;
        end
    endfunction

    integer errors = 0;
    task expect_legal(input integer i, input [1023:0] what);
        begin
            if (errs[i]) begin
                $display("  FAIL %0s: model rejected a legal burst: %0s", what, msgs[512*i +: 512]);
                errors = errors + 1;
            end else if (peeked[8*i +: 8] !== (8'hA0 + i)) begin
                $display("  FAIL %0s: accepted, but the byte did not land (got %02h)", what, peeked[8*i +: 8]);
                errors = errors + 1;
            end else
                $display("  ok   %0s", what);
        end
    endtask
    task expect_msg(input integer i, input [1023:0] what, input [511:0] msg);
        begin
            if (!errs[i]) begin
                $display("  FAIL %0s: model did NOT flag the violation", what);
                errors = errors + 1;
            end else if (msgs[512*i +: 512] !== msg) begin
                $display("  FAIL %0s: wrong rule fired: %0s", what, msgs[512*i +: 512]);
                errors = errors + 1;
            end else
                $display("  ok   %0s", what);
        end
    endtask

    integer t, i, w;
    reg [10:0] pv;
    initial begin
        $display("=== DDR3 write-burst rules, self-test (Phase 9 Stage 1, Part 17) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (12) @(posedge clk);

        // t = cycle offset from the ACTIVATE; the WRITE goes out at t = 3, so W = 3
        w = 3;
        for (t = 0; t <= 14; t = t + 1) begin
            @(posedge clk);
            // ---- command slot 0 of this cycle ----
            if (t == 0) begin
                cs_n <= {N{1'b0}}; ras_n <= {N{1'b0}}; cas_n <= {N{1'b1}}; we_n <= {N{1'b1}};
                for (i = 0; i < N; i = i + 1) begin ba[3*i +: 3] <= 3'd1; a[16*i +: 16] <= ROW; end
            end else if (t == w) begin
                cs_n <= {N{1'b0}}; ras_n <= {N{1'b1}}; cas_n <= {N{1'b0}};
                for (i = 0; i < N; i = i + 1) begin
                    ba[3*i +: 3] <= 3'd1; a[16*i +: 16] <= COL;
                    // instance 10: a READ instead of a WRITE - the burst that follows has no WRITE behind it
                    we_n[i] <= (i == 10) ? 1'b1 : 1'b0;
                end
            end
            // ---- the DQS and DQ pins for this cycle ----
            for (i = 0; i < N; i = i + 1) begin
                if (t >= w) begin
                    pv = pattern(i, t - w);
                    dqs[i]         <= (pv[1:0] == 2'd0) ? 1'b0 : (pv[1:0] == 2'd1) ? 1'b1 : 1'bz;
                    dq[8*i +: 8]   <= pv[10] ? pv[9:2] : 8'hzz;
                end
            end
            // ---- command slot 1: always a deselect, as the PHY drives it ----
            @(negedge clk);
            cs_n <= {N{1'b1}}; ras_n <= {N{1'b1}}; cas_n <= {N{1'b1}}; we_n <= {N{1'b1}};
        end
        repeat (10) @(posedge clk);

        expect_legal(0, "a legal burst at exactly WRITE + WL is accepted, and its byte lands in the addressed cell");
        expect_legal(1, "a legal burst that also drives DQ in the preamble and postamble is accepted");
        expect_msg(2, "a burst one cycle early is rejected",
                   "DQS driven outside the write burst a WRITE command asked for");
        expect_msg(3, "a burst one cycle late is rejected",
                   "write preamble: DQS not driven low the cycle before the burst");
        expect_msg(4, "DQ not driven in the second active cycle is rejected",
                   "write burst: DQ not driven while DQS is active");
        expect_msg(5, "DQ not driven in the first active cycle is rejected",
                   "write burst: DQ not driven while DQS is active");
        expect_msg(6, "DQS absent in the first active cycle is rejected",
                   "write burst: DQS not active in an expected burst cycle");
        expect_msg(7, "no preamble is rejected",
                   "write preamble: DQS not driven low the cycle before the burst");
        expect_msg(8, "no postamble is rejected",
                   "write postamble: DQS not driven low after the burst");
        expect_msg(9, "DQS driven again after the burst is rejected",
                   "DQS driven outside the write burst a WRITE command asked for");
        expect_msg(10, "a DQS burst with no WRITE behind it is rejected",
                   "DQS driven outside the write burst a WRITE command asked for");
        // a burst that never looked like a valid first half must leave nothing in the cell
        if (peeked[8*3 +: 8] !== 8'hxx) begin
            $display("  FAIL a burst that never opened validly stored data anyway (got %02h)", peeked[8*3 +: 8]);
            errors = errors + 1;
        end else $display("  ok   a burst that never opened validly leaves the cell unwritten (x)");
        if (peeked[8*10 +: 8] !== 8'hxx) begin
            $display("  FAIL a burst with no WRITE stored data anyway (got %02h)", peeked[8*10 +: 8]);
            errors = errors + 1;
        end else $display("  ok   a burst with no WRITE leaves the cell unwritten (x)");

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 WRITE BURST RULES TEST PASSED");
        else             $display("DDR3 WRITE BURST RULES TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #4_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
