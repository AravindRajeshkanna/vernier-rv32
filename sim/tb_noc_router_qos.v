`timescale 1ns/1ps
// The router's quality of service (Phase 8 Stage 3): traffic classes, and the
// aging that keeps a low class from starving.
//
// Two copies of the router, three inputs each, all flooding output 0 with
// back-to-back packets of their own class (input 0 class 2, input 1 class 1,
// input 2 class 0), the output always ready:
//   strict   QOS_EN=1, AGE_LIMIT=0: class priority alone. The top class takes every
//            slot and the other two get none while it floods - the starvation aging exists
//            to bound, shown, not assumed.
//   aged     QOS_EN=1, AGE_LIMIT=20: every input keeps getting served, and the gap
//            between one input's packets never exceeds the limit plus the time to serve
//            the others that have also aged.
// And a directed case: two packets that arrive together, the lower-numbered input
// carrying the lower class, leave in class order, not input order.
module tb_noc_router_qos;
    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;

    localparam NI = 3;
    reg  [NI-1:0]    s_valid = 0, a_valid = 0;
    reg  [NI*82-1:0] s_pkt = 0, a_pkt = 0;
    wire [NI-1:0]    s_ready, a_ready;
    wire [1:0]       s_ov, a_ov;
    wire [2*82-1:0]  s_op, a_op;
    reg  [1:0]       o_ready = 2'b11;
    wire             s_mr, a_mr;

    noc_router #(.NUM_IN(NI), .NUM_OUT(2), .DEPTH(2), .QOS_EN(1), .AGE_LIMIT(0)) STRICT (
        .clk(clk), .rst(rst), .in_valid(s_valid), .in_pkt(s_pkt), .in_ready(s_ready),
        .out_valid(s_ov), .out_pkt(s_op), .out_ready(o_ready),
        .hold_v(1'b0), .hold_id(4'd0), .misroute(s_mr));
    noc_router #(.NUM_IN(NI), .NUM_OUT(2), .DEPTH(2), .QOS_EN(1), .AGE_LIMIT(20)) AGED (
        .clk(clk), .rst(rst), .in_valid(a_valid), .in_pkt(a_pkt), .in_ready(a_ready),
        .out_valid(a_ov), .out_pkt(a_op), .out_ready(o_ready),
        .hold_v(1'b0), .hold_id(4'd0), .misroute(a_mr));

    integer failures = 0;
    task fail(input [8*60-1:0] what);
        begin failures = failures + 1; $display("  FAIL %0s", what); end
    endtask

    function [81:0] mk(input integer src, input integer qos, input integer seq);
        reg [81:0] p;
        begin
            p = 82'b0;
            p[7:6] = qos; p[11:8] = src; p[15:12] = 4'd0; p[79:48] = seq;
            mk = p;
        end
    endfunction

    // ---- the floods: each input offers the next packet as soon as one is taken ----
    integer seq_s [0:NI-1];
    integer seq_a [0:NI-1];
    integer i;
    reg flood = 0;
    reg drive_floods = 0;                 // the flood driver owns the inputs only once the floods begin
    always @(posedge clk) if (!rst) begin
        for (i = 0; i < NI; i = i + 1) begin
            if (s_valid[i] && s_ready[i]) seq_s[i] = seq_s[i] + 1;
            if (a_valid[i] && a_ready[i]) seq_a[i] = seq_a[i] + 1;
        end
    end
    always @(posedge clk) if (drive_floods) begin
        #1;
        for (i = 0; i < NI; i = i + 1) begin
            s_valid[i] = flood;  s_pkt[i*82 +: 82] = mk(i, 2 - i, seq_s[i]);
            a_valid[i] = flood;  a_pkt[i*82 +: 82] = mk(i, 2 - i, seq_a[i]);
        end
    end
    initial for (i = 0; i < NI; i = i + 1) begin seq_s[i] = 0; seq_a[i] = 0; end

    // ---- what each router delivered, and the longest gap between one input's packets ----
    integer s_got [0:NI-1];
    integer a_got [0:NI-1];
    integer a_gap [0:NI-1];
    integer a_max [0:NI-1];
    integer s_src, a_src;
    reg     measuring = 0;
    initial for (i = 0; i < NI; i = i + 1) begin s_got[i] = 0; a_got[i] = 0; a_gap[i] = 0; a_max[i] = 0; end
    always @(posedge clk) if (!rst && measuring) begin
        for (i = 0; i < NI; i = i + 1) a_gap[i] = a_gap[i] + 1;
        if (s_ov[0] && o_ready[0]) begin
            s_src = s_op[8 +: 4];
            s_got[s_src] = s_got[s_src] + 1;
        end
        if (a_ov[0] && o_ready[0]) begin
            a_src = a_op[8 +: 4];
            a_got[a_src] = a_got[a_src] + 1;
            if (a_gap[a_src] > a_max[a_src]) a_max[a_src] = a_gap[a_src];
            a_gap[a_src] = 0;
        end
    end

    integer c;
    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // ---- directed: two packets arriving together leave in class order ----
        o_ready = 2'b00;                                  // hold the output while both are loaded
        @(posedge clk); #1;
        s_valid = 3'b101; s_pkt = 0;
        s_pkt[0*82 +: 82] = mk(0, 0, 100);                // input 0, the lower number, class 0
        s_pkt[2*82 +: 82] = mk(2, 3, 101);                // input 2, class 3
        a_valid = 3'b101; a_pkt = s_pkt;
        @(posedge clk); #1;
        s_valid = 0; a_valid = 0;
        @(posedge clk); #1;
        if (!s_ov[0] || s_op[8 +: 4] !== 4'd2) fail("the higher class did not go first (strict)");
        if (!a_ov[0] || a_op[8 +: 4] !== 4'd2) fail("the higher class did not go first (aged)");
        o_ready = 2'b11;
        repeat (6) @(posedge clk);
        $display("  directed: of two packets arriving together, class 3 from input 2 left before class 0 from input 0");

        // ---- the floods ----
        for (i = 0; i < NI; i = i + 1) begin seq_s[i] = 0; seq_a[i] = 0; end
        drive_floods = 1;
        flood = 1;
        repeat (20) @(posedge clk);
        measuring = 1;
        repeat (600) @(posedge clk);
        measuring = 0;
        flood = 0;

        $display("  strict classes, 600 cycles flooding: input 0 (class 2) %0d, input 1 (class 1) %0d, input 2 (class 0) %0d",
                 s_got[0], s_got[1], s_got[2]);
        if (s_got[0] < 500)               fail("the top class did not take the output while it flooded");
        if (s_got[1] != 0 || s_got[2] != 0) fail("a lower class got through a flood of a higher one (no starvation shown)");

        $display("  aged (limit 20): input 0 %0d, input 1 %0d, input 2 %0d; longest gap between an input's packets %0d, %0d, %0d",
                 a_got[0], a_got[1], a_got[2], a_max[0], a_max[1], a_max[2]);
        for (c = 0; c < NI; c = c + 1) begin
            if (a_got[c] == 0)        fail("an input starved despite aging");
            // aging gives a flooding input about one slot in (limit + inputs) cycles: 600/23 = 26
            if (a_got[c] < 15 && c != 0) fail("an aged input got far less than its share");
            if (a_max[c] > 20 + 8)    fail("an input waited longer than the aging bound allows");
            if (a_gap[c] > 20 + 8)    fail("an input was still waiting past the aging bound when the window ended");
        end

        if (failures == 0) $display("\nNOC ROUTER QOS TEST PASSED");
        else               $display("\nNOC ROUTER QOS TEST FAILED (%0d)", failures);
        $finish;
    end

    initial begin
        #10_000_000;
        $display("\nNOC ROUTER QOS TEST FAILED (timeout)");
        $finish;
    end
endmodule
