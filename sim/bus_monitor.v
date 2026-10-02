`timescale 1ns/1ps
// A passive observer of rtl/soc/wb_interconnect.v, for Phase 8 Stage 0:
// measure the shared bus under load before deciding anything about replacing
// it. It reads signals, drives nothing, and is not part of any synthesised
// design.
//
// Per master it counts the cycles the master asked for the bus (cyc), the
// cycles it was granted it, and the cycles it asked but someone else held
// it (the contention cost). Masters are numbered fetch[0..H-1], data[0..H-1],
// walker[0..H-1], then debug, then NPU DMA, matching the interconnect's own
// tiers. Overall it counts cycles the bus was in use and cycles it was in use
// while another master was waiting, and per slave the cycles its strobe was up.
//
// Wire it to the interconnect's own request, grant and slave-strobe signals:
//   bus_monitor #(.NUM_HARTS(H), .NUM_SLAVES(N)) MON (
//       .clk(clk), .rst(rst),
//       .f_cyc(DUT.BUS.f_cyc), .d_cyc(DUT.BUS.d_cyc), .w_cyc(DUT.BUS.w_cyc),
//       .dbg_cyc(DUT.BUS.dbg_cyc), .n_cyc(DUT.BUS.n_cyc),
//       .sel_f(DUT.BUS.sel_f), .sel_d(DUT.BUS.sel_d), .sel_w(DUT.BUS.sel_w),
//       .sel_dbg(DUT.BUS.sel_dbg), .sel_n(DUT.BUS.sel_n),
//       .s_cyc(DUT.BUS.s_cyc), .s_stb(DUT.BUS.s_stb));
// and call MON.report from the testbench when the workload ends.
module bus_monitor #(
    parameter NUM_HARTS  = 1,
    parameter NUM_SLAVES = 7
)(
    input wire clk,
    input wire rst,
    input wire [NUM_HARTS-1:0] f_cyc, d_cyc, w_cyc,
    input wire dbg_cyc, n_cyc,
    input wire [NUM_HARTS-1:0] sel_f, sel_d, sel_w,
    input wire sel_dbg, sel_n,
    input wire s_cyc,
    input wire [NUM_SLAVES-1:0] s_stb
);
    localparam NM = 3 * NUM_HARTS + 2;

    wire [NM-1:0] req = {n_cyc,   dbg_cyc,   w_cyc, d_cyc, f_cyc};
    wire [NM-1:0] gnt = {sel_n,   sel_dbg,   sel_w, sel_d, sel_f};
    wire [NM-1:0] blk = req & ~gnt;

    reg [63:0] total, busy, busy_contended;
    reg [63:0] n_req   [0:NM-1];
    reg [63:0] n_gnt   [0:NM-1];
    reg [63:0] n_wait  [0:NM-1];
    reg [63:0] n_slave [0:NUM_SLAVES-1];
    integer i;

    initial begin
        total = 0; busy = 0; busy_contended = 0;
        for (i = 0; i < NM; i = i + 1) begin
            n_req[i] = 0; n_gnt[i] = 0; n_wait[i] = 0;
        end
        for (i = 0; i < NUM_SLAVES; i = i + 1) n_slave[i] = 0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            total = total + 1;
            if (s_cyc) busy = busy + 1;
            if (s_cyc && (|blk)) busy_contended = busy_contended + 1;
            for (i = 0; i < NM; i = i + 1) begin
                if (req[i]) n_req[i]  = n_req[i]  + 1;
                if (gnt[i]) n_gnt[i]  = n_gnt[i]  + 1;
                if (blk[i]) n_wait[i] = n_wait[i] + 1;
            end
            for (i = 0; i < NUM_SLAVES; i = i + 1)
                if (s_stb[i]) n_slave[i] = n_slave[i] + 1;
        end
    end

    // Zero every counter, so a testbench can report one phase of a program at
    // a time.
    task clear;
        integer k;
        begin
            total = 0; busy = 0; busy_contended = 0;
            for (k = 0; k < NM; k = k + 1) begin
                n_req[k] = 0; n_gnt[k] = 0; n_wait[k] = 0;
            end
            for (k = 0; k < NUM_SLAVES; k = k + 1) n_slave[k] = 0;
        end
    endtask

    function [8*10-1:0] role(input integer m);
        begin
            if      (m < NUM_HARTS)     role = "fetch";
            else if (m < 2 * NUM_HARTS) role = "data";
            else if (m < 3 * NUM_HARTS) role = "walker";
            else if (m == 3 * NUM_HARTS) role = "debug";
            else                        role = "npu dma";
        end
    endfunction

    function integer hart_of(input integer m);
        begin
            if (m < 3 * NUM_HARTS) hart_of = m % NUM_HARTS;
            else                   hart_of = -1;
        end
    endfunction

    task report;
        integer m;
        begin
            $display("");
            $display("---- bus monitor (%0d cycles) ----", total);
            $display("  bus in use:                   %0d cycles (%0d.%02d%%)", busy,
                     busy * 100 / total, (busy * 10000 / total) % 100);
            $display("  in use with a master waiting: %0d cycles (%0d.%02d%%)", busy_contended,
                     busy_contended * 100 / total, (busy_contended * 10000 / total) % 100);
            $display("  master            hart   asked    granted   waited   waited/asked");
            for (m = 0; m < NM; m = m + 1)
                if (n_req[m] != 0)
                    $display("  %-10s  %6d  %9d %9d %9d   %0d.%02d%%", role(m), hart_of(m),
                             n_req[m], n_gnt[m], n_wait[m],
                             n_wait[m] * 100 / n_req[m], (n_wait[m] * 10000 / n_req[m]) % 100);
            for (m = 0; m < NUM_SLAVES; m = m + 1)
                if (n_slave[m] != 0)
                    $display("  slave %0d strobe up:  %0d cycles", m, n_slave[m]);
            $display("---- end bus monitor ----");
        end
    endtask
endmodule
