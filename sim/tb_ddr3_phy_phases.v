// Test for Phase 9 Stage 1, Part 16 (docs/roadmap.md): the clock and
// command-phase architecture of rtl/soc/ddr3_phy_ecp5.v.
//
// Lattice's own reference DDR3 write side (FPGA-TN-02035, Figure 6.10 and
// section 6.3.3) generates CK with an ODDRX2F on constant inputs 0,1,0,1 -
// so CK runs at the EDGE-CLOCK rate, twice SCLK - and generates address and
// command with ODDRX1F / OSHX2A taking TWO values per SCLK cycle, one per CK
// cycle. Until Part 16 this design generated CK with an ODDRX1F on sclk, so
// CK ran at sclk's own rate while the DQ serdes moved four UI per sclk: a
// 100 MT/s data path against a 25 MHz CK (found by the Part 14/15 survey).
//
// What is checked, all on the real pins and the real DDR3 CK, with the real
// init sequence and a real write-then-read transaction driving them:
//   1. CK rises exactly twice per sclk cycle.
//   2. CK's rising edges are evenly spaced (a square wave, not a glitchy one).
//   3. No two consecutive CK samples both carry a command: with two CK per
//      sclk and one command issued per sclk, each command must occupy exactly
//      ONE CK sample, or the DRAM would see it twice.
//   4. Every command is sampled in phase 0 - the first CK of its sclk cycle.
//   5. Every command pin is stable across the CK rising edge (a setup/hold
//      surrogate at this simulation's resolution), so the DRAM samples a
//      settled value, not one changing under it.
`timescale 1ns/1ps
module tb_ddr3_phy_phases;
    localparam CLK_PERIOD = 40;   // 25 MHz sclk
    localparam CK_PERIOD  = CLK_PERIOD / 2;

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    wire        ddr3_ck, ddr3_ck_n;
    wire        ddr3_cs_n, ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [15:0] ddr3_a;
    wire        ddr3_cke, ddr3_reset_n, ddr3_odt;
    wire [7:0]  ddr3_dq;
    wire        ddr3_dqs;

    wire pll_locked, dll_locked, init_ready;
    wire calib_done, calib_error;
    wire [2:0] calib_readclksel;

    reg         write_req = 1'b0;
    reg         read_req  = 1'b0;
    wire        write_busy, read_busy, read_data_valid, refresh_busy;
    wire [7:0]  read_data;

    ddr3_ecp5_top DUT (
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs),
        .write_req(write_req), .write_bank(3'd2), .write_row(16'h0123),
        .write_col(16'h0040), .write_data(8'hA7), .write_busy(write_busy),
        .read_req(read_req), .read_bank(3'd2), .read_row(16'h0123), .read_col(16'h0040),
        .read_busy(read_busy), .read_data(read_data), .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked),
        .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_o;
    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .wr_d0(DUT.wr_data_final), .wr_en(DUT.write_start_final),
        .read_active(DUT.read_active_final),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_o(mem_dqs_o)
    );
    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = mem_dq_oe ? mem_dqs_o : 1'bz;

    // ---- monitors ----
    // 1 and 2: CK rate and evenness, measured against sclk over the whole
    // run once CK is running.
    integer sclk_edges = 0, ck_edges = 0;
    time    last_ck_rise = 0;
    integer uneven_ck = 0;
    always @(posedge clk) if (!rst) sclk_edges = sclk_edges + 1;
    always @(posedge ddr3_ck) if (!rst) begin
        ck_edges = ck_edges + 1;
        if (last_ck_rise != 0 && ($time - last_ck_rise) != CK_PERIOD) uneven_ck = uneven_ck + 1;
        last_ck_rise = $time;
    end

    // 3, 4 and 5: every CK sample.
    integer commands = 0, consecutive_cmds = 0, phase1_cmds = 0, unstable_pins = 0;
    reg prev_cmd = 1'b0;
    wire [22:0] pins_now = {ddr3_cs_n, ddr3_ras_n, ddr3_cas_n, ddr3_we_n, ddr3_ba, ddr3_a};
    // the value the pins had a quarter-CK ago, for a coarse setup/hold check
    wire [22:0] pins_before;
    assign #(CK_PERIOD / 4) pins_before = pins_now;
    reg  [22:0] pins_at_edge;
    always @(posedge ddr3_ck) if (!rst && calib_done) begin
        pins_at_edge = pins_before;
        if (ddr3_cs_n === 1'b0) begin
            commands = commands + 1;
            if (prev_cmd) consecutive_cmds = consecutive_cmds + 1;
            if (clk !== 1'b1) phase1_cmds = phase1_cmds + 1;   // phase 0 = sclk high at this CK edge
            prev_cmd = 1'b1;
        end else begin
            prev_cmd = 1'b0;
        end
        // and a quarter-CK after the edge the pins must still be the same
        #(CK_PERIOD / 4);
        if (pins_now !== pins_at_edge) unstable_pins = unstable_pins + 1;
    end

    integer errors = 0;
    task check_true(input [1023:0] what, input cond);
        begin
            if (!cond) begin
                $display("  FAIL %0s", what);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s", what);
            end
        end
    endtask

    integer guard;
    initial begin
        $display("=== DDR3 PHY clock and command phases (Phase 9 Stage 1, Part 16) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check_true("calibration completed before this test begins", calib_done && !calib_error);

        // a real transaction, so ACT, WR, RD and PRECHARGE all cross the pins
        @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0;
        @(posedge clk); guard = 0; while (write_busy && guard < 300) begin @(posedge clk); guard = guard + 1; end
        @(posedge clk); read_req <= 1'b1; @(posedge clk); read_req <= 1'b0;
        @(posedge clk); guard = 0; while (read_busy && guard < 300) begin @(posedge clk); guard = guard + 1; end
        repeat (10) @(posedge clk);

        $display("");
        $display("  sclk edges: %0d, CK rising edges: %0d, ratio %0d.%02d",
                 sclk_edges, ck_edges, ck_edges / sclk_edges, ((ck_edges * 100) / sclk_edges) % 100);
        $display("  commands sampled: %0d; back-to-back: %0d; in phase 1: %0d; unstable around CK: %0d",
                 commands, consecutive_cmds, phase1_cmds, unstable_pins);

        check_true("CK rises exactly twice per sclk cycle",
                   (ck_edges * 10 >= sclk_edges * 19) && (ck_edges * 10 <= sclk_edges * 21));
        check_true("CK's rising edges are evenly spaced (a clean square wave)", uneven_ck == 0);
        // ACT + WR + PRECHARGE for the write, ACT + RD + PRECHARGE for the read
        check_true("real commands crossed the pins, so the next checks mean something", commands >= 6);
        check_true("no command is sampled on two consecutive CK edges", consecutive_cmds == 0);
        check_true("every command is sampled in phase 0, the first CK of its sclk cycle", phase1_cmds == 0);
        check_true("command pins are stable across every CK rising edge", unstable_pins == 0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 PHY PHASES TEST PASSED");
        else             $display("DDR3 PHY PHASES TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
