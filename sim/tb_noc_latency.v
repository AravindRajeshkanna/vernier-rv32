`timescale 1ns/1ps
// Where a read's cycles go in the router fabric (Phase 8 Stage 3, Part 28).
//
// Part 27 measured the fabric 4.00 cycles behind the bus on every word a processor reads, in block
// RAM and in SDRAM alike. Reading rtl/soc/ gives four registered stages a read crosses that the bus
// has none of: the request router's input FIFO, the slave interface's request latch, its response
// queue, and the response router's input FIFO. This measures them instead of reading them off the
// code, one isolated transaction at a time, for the fabric as it is and with the slave interface's
// BYPASS on (rtl/soc/noc_ni_slave.v), which removes the second and third.
//
// Each transaction is timestamped four times, in cycles:
//   master  the first cycle the master's strobe is up, and the cycle it sees the ack
//   slave   the first cycle the slave interface's strobe is up, and the cycle the slave acks
// so that the time between them splits into the request path (master strobe to slave strobe), the
// slave's own service time (strobe to ack, fixed by the slave model here), and the response path
// (slave ack to master ack). On the bus the first and last are zero. Three slave models make the
// point that the cost does not depend on the slave: one that acks in the strobe's own cycle, one
// that takes a wait state, one that takes four and also streams a four-word burst, and one that acks
// every cycle and streams bursts at one word a cycle, so that a request and a burst's first beat
// can finish in the cycle they arrive. A locked read and write pair (an AMO) on the first checks that
// the slave still sees `cyc` held across the gap, which that same shortcut could lose.
module noc_lat_unit #(
    parameter NI_BYPASS = 0,
    parameter [8*8-1:0] NAME = "base"
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [31:0]  cyc,
    output reg          done,
    output wire [31:0]  failures_o,
    output wire [31:0]  req_path_o,     // the first single read's request path and response path,
    output wire [31:0]  rsp_path_o      // for the summary
);
    integer failures, req_path, rsp_path;
    assign failures_o = failures;
    assign req_path_o = req_path;
    assign rsp_path_o = rsp_path;

    // ---- the fabric, with one master used for single words and one for the burst ----
    reg         d_cyc = 0, d_stb = 0, d_we = 0, d_rmw = 0, d_wr = 0;
    reg  [31:0] d_adr = 0, d_dat_w = 0;
    reg  [3:0]  d_sel = 4'hf;
    wire [31:0] d_dat_r;
    wire        d_ack;
    reg         f_cyc = 0, f_stb = 0, f_burst = 0;
    reg  [31:0] f_adr = 0;
    wire [31:0] f_dat_r;
    wire        f_ack;

    localparam NS = 4;
    wire [NS-1:0]    s_cyc, s_stb, s_we, s_burst, s_ack;
    wire [NS*32-1:0] s_adr, s_dat_w, s_dat_r;
    wire [NS*4-1:0]  s_sel;

    wb_noc_xbar #(.NUM_SLAVES(NS), .NUM_HARTS(1), .BURST_SLAVES(4'b1100), .NI_BYPASS(NI_BYPASS)) X (
        .clk(clk), .rst(rst),
        .f_cyc(f_cyc), .f_stb(f_stb), .f_adr(f_adr), .f_burst(f_burst), .f_dat_r(f_dat_r), .f_ack(f_ack),
        .d_cyc(d_cyc), .d_stb(d_stb), .d_we(d_we), .d_adr(d_adr), .d_dat_w(d_dat_w), .d_sel(d_sel),
        .d_dat_r(d_dat_r), .d_ack(d_ack), .d_amo_wrphase(d_wr), .d_is_rmw(d_rmw),
        .w_cyc(1'b0), .w_stb(1'b0), .w_adr(32'b0), .w_dat_r(), .w_ack(),
        .dbg_cyc(1'b0), .dbg_stb(1'b0), .dbg_we(1'b0), .dbg_adr(32'b0), .dbg_dat_w(32'b0),
        .dbg_sel(4'b0), .dbg_dat_r(), .dbg_ack(),
        .n_cyc(1'b0), .n_stb(1'b0), .n_adr(32'b0), .n_dat_r(), .n_ack(),
        .s_base({8'h03, 8'h02, 8'h01, 8'h00}), .s_mask({4{8'hff}}),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
        .s_burst(s_burst), .s_dat_r(s_dat_r), .s_ack(s_ack),
        .s_data_master(), .snoop_wr(), .snoop_adr(), .snoop_src_d());

    // ---- three slaves ----
    // 0: acks in the strobe's own cycle. 1: one wait state. 2: four wait states for a word, and a
    // burst of four words two cycles apart (what the SDRAM controller does).
    reg ack1;
    reg [2:0] c2;
    reg [1:0] b2;
    reg ack2;
    always @(posedge clk) begin
        if (rst) ack1 <= 1'b0;
        else     ack1 <= s_stb[1] && !ack1;
        if (rst || !s_stb[2]) begin c2 <= 3'd0; b2 <= 2'd0; ack2 <= 1'b0; end
        else begin
            ack2 <= 1'b0;
            if (ack2)                                  begin c2 <= 3'd0; b2 <= b2 + 2'd1; end
            else if (c2 == (b2 == 2'd0 ? 3'd3 : 3'd0)) begin ack2 <= 1'b1; c2 <= 3'd0; end
            else                                            c2 <= c2 + 3'd1;
        end
    end
    // 3: acks every cycle, a burst at one word a cycle
    reg [1:0] b3;
    always @(posedge clk) begin
        if (rst || !s_stb[3]) b3 <= 2'd0;
        else                  b3 <= b3 + 2'd1;
    end
    assign s_ack = {s_stb[3], ack2 && s_stb[2], ack1 && s_stb[1], s_stb[0]};
    assign s_dat_r[31:0]  = {8'ha0, s_adr[23:0]};
    assign s_dat_r[63:32] = {8'ha1, s_adr[55:32]};
    assign s_dat_r[95:64] = s_burst[2] ? {8'hb2, s_adr[87:68], 2'b00, b2}
                                       : {8'ha2, s_adr[87:64]};
    assign s_dat_r[127:96] = s_burst[3] ? {8'hb3, s_adr[119:100], 2'b00, b3}
                                        : {8'ha3, s_adr[119:96]};

    // ---- timestamps, sampled at each clock edge (so a cycle's values are read as the cycle ends) ----
    integer kc;                              // which slave the transaction under test is for
    integer t_m0, t_ma, t_s0, t_sa;
    reg     use_f;                           // watch the fetch master instead of the data master
    reg         cap_we;                      // what the slave saw in the cycle it acked
    reg [31:0]  cap_dat, cap_adr;
    reg [3:0]   cap_sel;
    reg [31:0]  cap_rdat;                    // what the master was handed in the cycle it saw the ack
    wire    m_stb = use_f ? f_stb : d_stb;
    wire    m_ack = use_f ? f_ack : d_ack;
    reg     amo_watch;                       // between a locked read's ack and its write's ack at slave 0
    integer gap_len, gap_bad;
    always @(posedge clk) begin
        // the gap ends when the write has been done at the slave (what happens while its answer
        // travels back is no longer the gap)
        if (amo_watch && s_stb[0] && s_ack[0] && s_we[0]) amo_watch = 0;
        if (amo_watch && !s_stb[0]) begin
            gap_len = gap_len + 1;
            if (!s_cyc[0]) gap_bad = gap_bad + 1;     // cyc must stay up through the gap
        end
        if (m_stb && t_m0 < 0)                          t_m0 = cyc;
        if (m_stb && m_ack && t_ma < 0) begin
            t_ma    = cyc;
            cap_rdat = use_f ? f_dat_r : d_dat_r;
        end
        if (s_stb[kc] && t_s0 < 0)                      t_s0 = cyc;
        if (s_stb[kc] && s_ack[kc] && t_sa < 0) begin
            t_sa    = cyc;
            cap_we  = s_we[kc];
            cap_dat = s_dat_w[32*kc +: 32];
            cap_adr = s_adr[32*kc +: 32];
            cap_sel = s_sel[4*kc +: 4];
        end
    end

    function [31:0] expect_dat(input integer k, input [23:0] off);
        begin expect_dat = {8'ha0 + k[7:0], off}; end
    endfunction

    integer exp_req, exp_rsp;
    initial begin exp_req = 2 - NI_BYPASS; exp_rsp = 2 - NI_BYPASS; end
    integer svc_exp [0:3];
    initial begin svc_exp[0] = 0; svc_exp[1] = 1; svc_exp[2] = 4; svc_exp[3] = 0; end

    task fail(input [8*56-1:0] what);
        begin failures = failures + 1; $display("  FAIL [%0s] %0s", NAME, what); end
    endtask

    task start_watch(input integer k, input f);
        begin t_m0 = -1; t_ma = -1; t_s0 = -1; t_sa = -1; kc = k; use_f = f; end
    endtask

    task report(input integer k, input [8*5-1:0] what);
        integer rq, sv, rs;
        begin
            rq = t_s0 - t_m0; sv = t_sa - t_s0; rs = t_ma - t_sa;
            $display("  [%0s] %0s slave %0d: request path %0d, slave %0d, response path %0d = %0d cycles",
                     NAME, what, k, rq, sv, rs, t_ma - t_m0);
            if (rq != exp_req)    fail("request path is not what it should be");
            if (sv != svc_exp[k]) fail("slave service time changed");
            if (rs != exp_rsp)    fail("response path is not what it should be");
            if (k == 0 && what == "read ") begin req_path = rq; rsp_path = rs; end
        end
    endtask

    task one_read(input integer k, input [23:0] off);
        begin
            start_watch(k, 0);
            @(posedge clk); #1;
            d_cyc <= 1; d_stb <= 1; d_we <= 0; d_adr <= {k[7:0], off}; d_sel <= 4'hf;
            while (t_ma < 0) begin @(posedge clk); #1; end
            if (cap_rdat !== expect_dat(k, off)) fail("read data wrong");
            if (cap_we !== 1'b0 || cap_adr !== {k[7:0], off}) fail("the slave saw the wrong read");
            d_cyc <= 0; d_stb <= 0;
            report(k, "read ");
            repeat (12) @(posedge clk);
        end
    endtask

    task one_write(input integer k, input [23:0] off, input [31:0] data, input [3:0] sel);
        begin
            start_watch(k, 0);
            @(posedge clk); #1;
            d_cyc <= 1; d_stb <= 1; d_we <= 1; d_adr <= {k[7:0], off}; d_dat_w <= data; d_sel <= sel;
            while (t_ma < 0) begin @(posedge clk); #1; end
            // the slave must have seen the written word, the byte enables and the address when it acked
            if (cap_we !== 1'b1 || cap_dat !== data || cap_sel !== sel || cap_adr !== {k[7:0], off})
                fail("the slave saw the wrong write");
            d_cyc <= 0; d_stb <= 0; d_we <= 0;
            report(k, "write");
            repeat (12) @(posedge clk);
        end
    endtask

    // a four-word burst through the fetch master: the words come back in order, and every beat
    // takes the same response path
    integer beat, sbeat;
    integer ta [0:3];
    integer tsa [0:3];
    task one_burst(input integer k, input [23:0] off);
        reg [31:0] adr;
        begin
            adr = {k[7:0], off};
            kc = k; use_f = 1; beat = 0; sbeat = 0;
            @(posedge clk); #1;
            f_cyc <= 1; f_stb <= 1; f_burst <= 1; f_adr <= adr;
            while (beat < 4) begin
                @(posedge clk);                       // read the cycle that has just ended
                if (s_stb[k] && s_ack[k] && sbeat < 4) begin tsa[sbeat] = cyc; sbeat = sbeat + 1; end
                if (f_stb && f_ack) begin
                    ta[beat] = cyc;
                    if (f_dat_r !== {8'hb0 + k[7:0], adr[23:4], 2'b00, beat[1:0]}) fail("burst word wrong or out of order");
                    beat = beat + 1;
                end
                #1;
            end
            f_cyc <= 0; f_stb <= 0; f_burst <= 0;
            $display("  [%0s] burst slave %0d: slave acks at +0 +%0d +%0d +%0d, master sees them at +%0d +%0d +%0d +%0d",
                     NAME, k, tsa[1] - tsa[0], tsa[2] - tsa[0], tsa[3] - tsa[0],
                     ta[0] - tsa[0], ta[1] - tsa[0], ta[2] - tsa[0], ta[3] - tsa[0]);
            for (beat = 0; beat < 4; beat = beat + 1)
                if (ta[beat] - tsa[beat] != exp_rsp) fail("a burst beat's response path is not what it should be");
            repeat (12) @(posedge clk);
        end
    endtask

    // a locked read then a write to the same word, as an AMO makes: while the core works out the
    // new value the slave must still see cyc held, and the write must find its word
    task one_amo(input [23:0] off);
        reg [31:0] adr;
        begin
            adr = {8'h00, off};
            gap_len = 0; gap_bad = 0;
            start_watch(0, 0);
            @(posedge clk); #1;
            d_rmw <= 1; d_wr <= 0;
            d_cyc <= 1; d_stb <= 1; d_we <= 0; d_adr <= adr; d_sel <= 4'hf;
            while (t_ma < 0) begin @(posedge clk); #1; end
            amo_watch = 1;
            d_stb <= 0; d_wr <= 1;                     // the core now holds the word; cyc stays up
            repeat (4) @(posedge clk);
            #1;
            start_watch(0, 0);
            d_stb <= 1; d_we <= 1; d_adr <= adr; d_dat_w <= 32'h0a0b_0c0d; d_sel <= 4'hf;
            while (t_ma < 0) begin @(posedge clk); #1; end
            amo_watch = 0;
            d_cyc <= 0; d_stb <= 0; d_we <= 0; d_rmw <= 0; d_wr <= 0;
            $display("  [%0s] amo slave 0: slave saw cyc held with stb low for %0d cycles of the gap, %0d without cyc",
                     NAME, gap_len, gap_bad);
            if (gap_len == 0) fail("the amo test did not exercise a gap");
            if (gap_bad != 0) fail("cyc dropped between an amo's two phases");
            if (cap_we !== 1'b1 || cap_dat !== 32'h0a0b_0c0d) fail("the amo's write was not seen");
            repeat (12) @(posedge clk);
        end
    endtask

    integer j;
    initial begin
        done = 0; failures = 0; req_path = 0; rsp_path = 0; kc = 0; use_f = 0;
        amo_watch = 0; gap_len = 0; gap_bad = 0;
        t_m0 = -1; t_ma = -1; t_s0 = -1; t_sa = -1;
        wait (!rst);
        repeat (8) @(posedge clk);
        for (j = 0; j < 2; j = j + 1) begin
            one_read(0, 24'h000100 + j * 4);
            one_read(1, 24'h000200 + j * 4);
            one_read(2, 24'h000300 + j * 4);
        end
        one_write(0, 24'h000040, 32'hdead_beef, 4'hf);
        one_write(1, 24'h000044, 32'h1234_5678, 4'h3);
        one_burst(2, 24'h000050);
        // a request that finishes in its first cycle leaves the burst counter where it was; the next
        // request must not inherit it
        one_read(3, 24'h000400);
        one_burst(3, 24'h000060);
        one_read(0, 24'h000108);
        one_amo(24'h000080);
        done = 1;
    end
endmodule

module tb_noc_latency;
    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;
    reg [31:0] cyc = 0;
    always @(posedge clk) cyc <= cyc + 32'd1;
    initial begin repeat (4) @(posedge clk); rst = 0; end

    wire d0, d1;
    wire [31:0] f0, f1, rq0, rs0, rq1, rs1;
    noc_lat_unit #(.NI_BYPASS(0), .NAME("as built")) U0 (.clk(clk), .rst(rst), .cyc(cyc), .done(d0),
        .failures_o(f0), .req_path_o(rq0), .rsp_path_o(rs0));
    noc_lat_unit #(.NI_BYPASS(1), .NAME("bypass  ")) U1 (.clk(clk), .rst(rst), .cyc(cyc), .done(d1),
        .failures_o(f1), .req_path_o(rq1), .rsp_path_o(rs1));

    initial begin
        wait (d0 && d1);
        repeat (4) @(posedge clk);
        $display("\n  added to a read by the fabric: %0d cycles as built (%0d + %0d), %0d with the slave interface's bypass (%0d + %0d)",
                 rq0 + rs0, rq0, rs0, rq1 + rs1, rq1, rs1);
        if (f0 + f1 == 0) $display("NOC LATENCY TEST PASSED");
        else              $display("NOC LATENCY TEST FAILED (%0d)", f0 + f1);
        $finish;
    end
    initial begin
        #200000;
        $display("NOC LATENCY TEST FAILED (timeout)");
        $finish;
    end
endmodule
