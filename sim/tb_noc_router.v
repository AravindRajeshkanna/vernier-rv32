`timescale 1ns/1ps
// The packet router on its own (Phase 8 Stage 2): three inputs, three outputs,
// two-deep input FIFOs.
//
// A: random traffic from every input to every output with random pauses and
//    random back-pressure at the outputs. Each packet carries a sequence number
//    for its (input, output) flow, so a lost, duplicated or reordered packet is
//    caught by name. Checked on the way: an output that has offered a packet
//    keeps offering the same one until it is taken; packets bound for different
//    outputs really do move in the same cycle (counted, and required); and
//    sequences of `lock` packets exclude other sources at their output.
// B: the AMO hold. After input 0 has used output 0, `hold` for input 0 closes
//    that output to everyone else (output 1 stays open), input 0 itself still
//    gets through, and the others flow again when it drops.
// C: a destination that is not a port is taken, discarded and flagged, and the
//    router carries on.
module tb_noc_router;
    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;

    localparam NI = 3, NO = 3;
    reg  [NI-1:0]    in_valid = 0;
    reg  [NI*82-1:0] in_pkt = 0;
    wire [NI-1:0]    in_ready;
    wire [NO-1:0]    out_valid;
    wire [NO*82-1:0] out_pkt;
    reg  [NO-1:0]    out_ready = 0;
    reg              hold_v = 0;
    reg  [3:0]       hold_id = 0;
    wire             misroute;

    noc_router #(.NUM_IN(NI), .NUM_OUT(NO), .DEPTH(2)) DUT (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_pkt(in_pkt), .in_ready(in_ready),
        .out_valid(out_valid), .out_pkt(out_pkt), .out_ready(out_ready),
        .hold_v(hold_v), .hold_id(hold_id), .misroute(misroute));

    integer failures = 0;
    task fail(input [8*56-1:0] what);
        begin failures = failures + 1; $display("  FAIL %0s", what); end
    endtask

    // ---- the receivers' back-pressure: a random mask each cycle ----
    reg    ready_on = 1'b1;
    integer rseed = 5;
    always @(negedge clk)
        out_ready <= ready_on ? ($random(rseed) | $random(rseed)) : {NO{1'b1}};

    // ---- monitors ----
    integer expect_seq [0:NI*NO-1];
    integer got [0:NI*NO-1];
    integer moved_parallel = 0, moved_total = 0, ko, ki;
    reg       lk_v [0:NO-1];
    reg [3:0] lk_own [0:NO-1];
    reg       pend [0:NO-1];
    reg [81:0] pend_pkt [0:NO-1];
    integer   hold_viol = 0, open_during_hold = 0;
    reg       watch_hold = 0;
    integer   held_other_out0 = 0, held_other_out1 = 0, held_own_out0 = 0;
    integer   nmov;
    initial for (ko = 0; ko < NO; ko = ko + 1) begin lk_v[ko] = 0; lk_own[ko] = 0; pend[ko] = 0; end
    initial for (ko = 0; ko < NI*NO; ko = ko + 1) begin expect_seq[ko] = 0; got[ko] = 0; end

    always @(posedge clk) if (!rst) begin
        nmov = 0;
        for (ko = 0; ko < NO; ko = ko + 1) begin
            // an offer stays until taken, unchanged
            if (pend[ko] && !(out_valid[ko] && out_pkt[ko*82 +: 82] === pend_pkt[ko]))
                fail("an offered packet changed or vanished before it was taken");
            pend[ko] <= out_valid[ko] && !out_ready[ko];
            pend_pkt[ko] <= out_pkt[ko*82 +: 82];
            if (out_valid[ko] && out_ready[ko]) begin
                nmov = nmov + 1;
                ki = out_pkt[ko*82 + 8 +: 4];
                // dst field says this output
                if (out_pkt[ko*82 + 12 +: 4] != ko) fail("a packet came out of the wrong output");
                // per-flow order
                if (out_pkt[ko*82 + 48 +: 32] != expect_seq[ki*NO + ko] && !watch_hold) begin
                    fail("a packet was lost, repeated or reordered");
                    $display("    flow %0d->%0d wanted %0d got %0d", ki, ko, expect_seq[ki*NO + ko], out_pkt[ko*82 + 48 +: 32]);
                end
                expect_seq[ki*NO + ko] = out_pkt[ko*82 + 48 +: 32] + 1;
                got[ki*NO + ko] = got[ki*NO + ko] + 1;
                // lock exclusion
                if (lk_v[ko] && lk_own[ko] != ki) fail("a packet got in between a locked sequence");
                if (out_pkt[ko*82]) begin lk_v[ko] = 1; lk_own[ko] = ki; end
                else if (lk_v[ko] && lk_own[ko] == ki) lk_v[ko] = 0;
                // hold window bookkeeping (phase B)
                if (hold_v && ko == 0 && ki != hold_id) hold_viol = hold_viol + 1;
                if (hold_v && ko == 1 && ki == 2) open_during_hold = open_during_hold + 1;
                if (watch_hold) begin
                    if (ko == 0 && ki != 0) held_other_out0 = held_other_out0 + 1;
                    if (ko == 1 && ki != 0) held_other_out1 = held_other_out1 + 1;
                    if (ko == 0 && ki == 0) held_own_out0 = held_own_out0 + 1;
                end
            end
        end
        moved_total = moved_total + nmov;
        if (nmov >= 2) moved_parallel = moved_parallel + 1;
    end

    // ---- senders ----
    integer sent_seq [0:NI*NO-1];
    initial for (ko = 0; ko < NI*NO; ko = ko + 1) sent_seq[ko] = 0;

    task automatic send(input integer i, input integer dst, input lock);
        reg [81:0] p;
        begin
            p = 82'b0;
            p[0] = lock;  p[11:8] = i;  p[15:12] = dst;
            if (dst < NO) begin
                p[79:48] = sent_seq[i*NO + dst];
                sent_seq[i*NO + dst] = sent_seq[i*NO + dst] + 1;
            end
            in_pkt[i*82 +: 82] = p;
            in_valid[i] = 1'b1;
            @(posedge clk);
            while (!in_ready[i]) @(posedge clk);
            #1;
            in_valid[i] = 1'b0;
        end
    endtask

    task automatic sender(input integer i, input integer n);
        integer c, d, sd, g;
        begin
            sd = 40 + i;
            for (c = 0; c < n; c = c + 1) begin
                g = ($random(sd) & 32'h7fffffff) % 4;
                repeat (g) @(posedge clk);
                #1;
                d = ($random(sd) & 32'h7fffffff) % NO;
                if ((($random(sd) & 32'h7fffffff) % 8) == 0) begin
                    send(i, d, 1'b1);               // a locked pair: first, lock set...
                    send(i, d, 1'b0);               // ...then the closing packet, lock clear
                    c = c + 1;
                end else send(i, d, 1'b0);
            end
        end
    endtask

    integer w, q, total_sent, total_got;
    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // ---- A ----
        fork
            sender(0, 700);
            sender(1, 700);
            sender(2, 700);
        join
        repeat (60) @(posedge clk);
        total_sent = 0; total_got = 0;
        for (q = 0; q < NI*NO; q = q + 1) begin
            total_sent = total_sent + sent_seq[q];
            total_got  = total_got + got[q];
            if (sent_seq[q] != got[q]) fail("a flow delivered a different number than it sent");
        end
        $display("  A: %0d packets in, %0d out; %0d cycles moved two or more at once", total_sent, total_got, moved_parallel);
        if (moved_parallel < 100) fail("outputs did not run in parallel");

        // ---- B: the hold ----
        ready_on = 1'b0;                                   // outputs always ready, for a clean window
        repeat (4) @(posedge clk);
        send(0, 0, 1'b0);                                  // input 0 uses output 0
        repeat (6) @(posedge clk);
        watch_hold = 1;
        #1 hold_v = 1; hold_id = 0;
        fork
            begin repeat (6) send(1, 0, 1'b0); end           // input 1 floods the held output
            begin repeat (6) send(2, 1, 1'b0); end           // input 2 uses the other one
            begin repeat (20) @(posedge clk); send(0, 0, 1'b0); end
            begin repeat (60) @(posedge clk); #1 hold_v = 0; end
        join
        repeat (20) @(posedge clk);
        $display("  B: during the hold: %0d packets from others through the held output (must be 0), %0d through the other output (must be 6), the holder got %0d through; %0d reached the held output once it dropped",
                 hold_viol, open_during_hold, held_own_out0, held_other_out0);
        // input 1's six packets to output 0 may only pass once the hold drops
        if (hold_viol != 0)       fail("another input used the held output while the hold was up");
        if (open_during_hold != 6) fail("the hold closed an output it should not have");
        if (held_other_out0 != 6) fail("the held output did not serve the others after the hold dropped");
        if (held_own_out0 < 1)    fail("the holder was shut out of its own output");
        watch_hold = 0;
        for (q = 0; q < NI*NO; q = q + 1)
            if (sent_seq[q] != got[q]) fail("a flow lost packets across the hold");

        // ---- C: a misrouted packet ----
        if (misroute) fail("misroute flagged before any misroute");
        send(1, 9, 1'b0);
        send(1, 9, 1'b0);
        repeat (6) @(posedge clk);
        if (!misroute) fail("misroute not flagged");
        send(1, 2, 1'b0);
        send(2, 1, 1'b0);
        repeat (10) @(posedge clk);
        for (q = 0; q < NI*NO; q = q + 1)
            if (sent_seq[q] != got[q]) fail("traffic after a misroute was lost");
        $display("  C: misrouted packets discarded and flagged, traffic carried on");

        if (failures == 0) $display("\nNOC ROUTER TEST PASSED");
        else               $display("\nNOC ROUTER TEST FAILED (%0d)", failures);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("\nNOC ROUTER TEST FAILED (timeout)");
        $finish;
    end
endmodule
