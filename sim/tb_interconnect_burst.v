`timescale 1ns/1ps
// `INTERCONNECT picks the module under test: the bus (the default) or the Phase 8
// network fabric (wb_noc_fabric.v), which has to pass the same test.
`ifndef INTERCONNECT
`define INTERCONNECT wb_interconnect
`endif
// wb_interconnect.v carrying four-word bursts to the real SDRAM controller
// (Phase 8 Part 9, step 2a). Two harts' fetch masters burst-read SDRAM lines
// while hart 1's data master makes single reads of SDRAM and of a 1-wait RAM,
// all at once, so arbitration is open every time a transfer ends.
//
// What it proves: every burst returns its four words, in order, to the master
// that asked; and *no other master is acked while a burst is between its first
// and fourth ack* - the property the lock exists for, since acks follow the
// selection and the selection follows the lock. With the lock releasing on the
// first ack (what it did before bursts) words two to four go to whoever won the
// next arbitration, and this fails by name.
module tb_interconnect_burst;
    localparam CLK_HZ = 25_000_000;
    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;

    localparam NH = 2;
    localparam NS = 2;      // slave 0: SDRAM (burst capable); slave 1: a 1-wait RAM

    reg  [NH-1:0]    f_cyc = 0, f_stb = 0, f_burst = 0;
    reg  [NH*32-1:0] f_adr = 0;
    reg  [NH-1:0]    d_cyc = 0, d_stb = 0, d_we = 0;
    reg  [NH*32-1:0] d_adr = 0, d_dat_w = 0;
    reg  [NH*4-1:0]  d_sel = 0;
    wire [NH*32-1:0] f_dat_r, d_dat_r, w_dat_r;
    wire [NH-1:0]    f_ack, d_ack, w_ack;
    wire             s_cyc, s_we, s_data_master, s_burst;
    wire [NS-1:0]    s_stb;
    wire [31:0]      s_adr, s_dat_w;
    wire [3:0]       s_sel;
    wire [NS*32-1:0] s_dat_r;
    wire [NS-1:0]    s_ack;

    `INTERCONNECT #(.NUM_SLAVES(NS), .NUM_HARTS(NH), .BURST_SLAVES(1)) BUS (
        .clk(clk), .rst(rst),
        .f_cyc(f_cyc), .f_stb(f_stb), .f_adr(f_adr), .f_burst(f_burst),
        .f_dat_r(f_dat_r), .f_ack(f_ack),
        .d_cyc(d_cyc), .d_stb(d_stb), .d_we(d_we), .d_adr(d_adr),
        .d_dat_w(d_dat_w), .d_sel(d_sel),
        .d_dat_r(d_dat_r), .d_ack(d_ack),
        .d_amo_wrphase({NH{1'b0}}),
        .w_cyc({NH{1'b0}}), .w_stb({NH{1'b0}}), .w_adr({NH*32{1'b0}}),
        .w_dat_r(w_dat_r), .w_ack(w_ack),
        .dbg_cyc(1'b0), .dbg_stb(1'b0), .dbg_we(1'b0), .dbg_adr(32'b0),
        .dbg_dat_w(32'b0), .dbg_sel(4'b0), .dbg_dat_r(), .dbg_ack(),
        .n_cyc(1'b0), .n_stb(1'b0), .n_adr(32'b0), .n_dat_r(), .n_ack(),
        .s_base({8'h80, 8'h90}), .s_mask({8'hFF, 8'hFE}),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
        .s_dat_r(s_dat_r), .s_ack(s_ack),
        .s_data_master(s_data_master), .s_burst(s_burst),
        .snoop_wr(), .snoop_adr(), .snoop_src_d()
    );

    // ---- slave 0: the SDRAM controller and its model ----
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [12:0] sd_a;
    wire [1:0]  sd_ba, sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe, sd_ready;
    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    wb_sdram #(.CLK_HZ(CLK_HZ)) SDRAM (
        .clk(clk), .rst(rst),
        .wb_cyc(s_cyc), .wb_stb(s_stb[0]), .wb_we(s_we), .wb_adr(s_adr),
        .wb_dat_w(s_dat_w), .wb_sel(s_sel), .wb_burst(s_burst),
        .wb_dat_r(s_dat_r[31:0]), .wb_ack(s_ack[0]),
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n), .sdram_ras_n(sd_ras_n),
        .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
        .sdram_ready(sd_ready)
    );
    sdram_model #(.MEM_WORDS(1 << 20)) MEM (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );

    // ---- slave 1: a 1-wait RAM whose word is a function of its address ----
    reg ack1 = 0;
    always @(posedge clk) ack1 <= s_stb[1] && !ack1;
    assign s_ack[1]            = ack1;
    assign s_dat_r[63:32]      = {s_adr[15:0], ~s_adr[15:0]};

    integer errors = 0;
    task fail(input [1023:0] msg);
        begin $display("  FAIL: %0s", msg); errors = errors + 1; end
    endtask

    // ---- the monitor: nobody else is acked in the middle of a burst ----
    // A fetch master's burst is "mid" from its first ack to its fourth. While
    // either hart's is, no ack may go to any other master.
    integer cnt0 = 0, cnt1 = 0;
    wire mid0 = (cnt0 != 0) && f_burst[0];
    wire mid1 = (cnt1 != 0) && f_burst[1];
    always @(posedge clk) begin
        if (f_ack[0]) cnt0 <= (cnt0 == 3) ? 0 : cnt0 + 1;
        if (f_ack[1]) cnt1 <= (cnt1 == 3) ? 0 : cnt1 + 1;
        if (mid0 && (f_ack[1] || (|d_ack) || (|w_ack))) fail("an ack went to another master during hart 0's burst");
        if (mid1 && (f_ack[0] || (|d_ack) || (|w_ack))) fail("an ack went to another master during hart 1's burst");
    end

    // ---- masters ----
    reg [31:0] bw0 [0:3];
    reg [31:0] bw1 [0:3];
    integer n0, n1, c0, c1;

    // Masters change their outputs just after a rising edge (#1) and read acks
    // at the rising edge, which sees the values from before it: the way a
    // registered master behaves. (Dropping cyc at the falling edge, in the
    // middle of the cycle an ack is visible, is not a legal master here: the
    // interconnect samples cyc together with the ack at the next rising edge,
    // and a lock released only on that sample would never release.)
    task f0_burst(input [31:0] a);
        begin
            f_adr[31:0] = a; f_burst[0] = 1'b1; f_cyc[0] = 1'b1; f_stb[0] = 1'b1;
            n0 = 0; c0 = 0;
            while (n0 < 4 && c0 < 20000) begin
                @(posedge clk); c0 = c0 + 1;
                if (f_ack[0]) begin bw0[n0] = f_dat_r[31:0]; n0 = n0 + 1; end
                #1;
            end
            f_cyc[0] = 1'b0; f_stb[0] = 1'b0; f_burst[0] = 1'b0;
            if (n0 != 4) fail("hart 0 burst did not complete");
        end
    endtask
    task f1_burst(input [31:0] a);
        begin
            f_adr[63:32] = a; f_burst[1] = 1'b1; f_cyc[1] = 1'b1; f_stb[1] = 1'b1;
            n1 = 0; c1 = 0;
            while (n1 < 4 && c1 < 20000) begin
                @(posedge clk); c1 = c1 + 1;
                if (f_ack[1]) begin bw1[n1] = f_dat_r[63:32]; n1 = n1 + 1; end
                #1;
            end
            f_cyc[1] = 1'b0; f_stb[1] = 1'b0; f_burst[1] = 1'b0;
            if (n1 != 4) fail("hart 1 burst did not complete");
        end
    endtask

    // hart 0's data master writes the SDRAM (preload); hart 1's reads it and slave 1.
    task d0_write(input [31:0] a, input [31:0] d);
        begin
            d_adr[31:0] = a; d_dat_w[31:0] = d; d_sel[3:0] = 4'hF;
            d_we[0] = 1'b1; d_cyc[0] = 1'b1; d_stb[0] = 1'b1;
            @(posedge clk);
            while (!d_ack[0]) @(posedge clk);
            #1;
            d_cyc[0] = 1'b0; d_stb[0] = 1'b0; d_we[0] = 1'b0;
        end
    endtask
    reg [31:0] d1_got;
    task d1_read(input [31:0] a);
        begin
            d_adr[63:32] = a; d_sel[7:4] = 4'hF; d_we[1] = 1'b0;
            d_cyc[1] = 1'b1; d_stb[1] = 1'b1;
            @(posedge clk);
            while (!d_ack[1]) @(posedge clk);
            d1_got = d_dat_r[63:32];
            #1;
            d_cyc[1] = 1'b0; d_stb[1] = 1'b0;
        end
    endtask

    function [31:0] pat(input integer w); pat = 32'hC0DE_0000 + w; endfunction

    integer i, ia, ib, ic, la, lb;
    integer done_a = 0, done_b = 0, done_c = 0;
    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        wait (sd_ready);
        @(posedge clk); #1;
        for (i = 0; i < 64; i = i + 1) d0_write(32'h9000_0000 + i*4, pat(i));
        $display("");
        $display("=== interconnect burst test ===");
        fork
            begin : A   // hart 0 fetch: bursts over 8 lines, 24 times
                for (ia = 0; ia < 24; ia = ia + 1) begin
                    la = ia % 8;
                    f0_burst(32'h9000_0000 + la*16);
                    if (bw0[0] !== pat(la*4) || bw0[1] !== pat(la*4+1) ||
                        bw0[2] !== pat(la*4+2) || bw0[3] !== pat(la*4+3))
                        fail("hart 0 burst returned the wrong words");
                end
                done_a = 1;
            end
            begin : B   // hart 1 fetch: bursts too, other lines
                for (ib = 0; ib < 24; ib = ib + 1) begin
                    lb = 8 + (ib % 8);
                    f1_burst(32'h9000_0000 + lb*16);
                    if (bw1[0] !== pat(lb*4) || bw1[1] !== pat(lb*4+1) ||
                        bw1[2] !== pat(lb*4+2) || bw1[3] !== pat(lb*4+3))
                        fail("hart 1 burst returned the wrong words");
                end
                done_b = 1;
            end
            begin : C   // hart 1 data: single reads, RAM and SDRAM, interleaved
                for (ic = 0; ic < 60; ic = ic + 1) begin
                    // Gaps of 3 to 25 cycles, so the fetch bursts get the bus
                    // between reads and a data request - which outranks fetch -
                    // lands in the middle of one: the case the lock is for.
                    repeat (3 + (ic * 7) % 23) @(posedge clk);
                    #1;
                    d1_read(32'h8000_0000 + ic*4);
                    if (d1_got !== {ic[15:0]*16'd4, ~(ic[15:0]*16'd4)})
                        fail("hart 1 single read of the 1-wait RAM returned the wrong word");
                    repeat (2 + (ic * 5) % 17) @(posedge clk);
                    #1;
                    d1_read(32'h9000_0000 + (ic % 32)*4);
                    if (d1_got !== pat(ic % 32))
                        fail("hart 1 single read of SDRAM returned the wrong word");
                end
                done_c = 1;
            end
        join
        // A burst request to a slave that cannot burst is not passed on: s_burst
        // stays low and the transfer is one ordinary read with one ack. (A real
        // master never asks; this is the interconnect's own guard.)
        f_adr[31:0] = 32'h8000_0010; f_burst[0] = 1'b1; f_cyc[0] = 1'b1; f_stb[0] = 1'b1;
        n0 = 0; c0 = 0;
        while (n0 < 1 && c0 < 100) begin
            @(posedge clk); c0 = c0 + 1;
            if (s_burst) fail("s_burst was high for a slave that cannot burst");
            if (f_ack[0]) n0 = n0 + 1;
            #1;
        end
        f_cyc[0] = 1'b0; f_stb[0] = 1'b0; f_burst[0] = 1'b0;
        repeat (12) begin
            @(posedge clk);
            if (f_ack[0] || f_ack[1] || (|d_ack)) fail("a stray ack after a non-burst read");
        end
        if (n0 != 1) fail("a non-burst slave did not give exactly one ack");
        $display("  masters done: %0d %0d %0d", done_a, done_b, done_c);
        if (!(done_a && done_b && done_c)) fail("a master did not finish");
        $display("");
        if (errors == 0) $display("INTERCONNECT BURST TEST PASSED");
        else             $display("INTERCONNECT BURST TEST FAILED (%0d)", errors);
        $finish;
    end
    initial begin
        #200_000_000;
        $display("INTERCONNECT BURST TEST FAILED (timeout)");
        $finish;
    end
endmodule
