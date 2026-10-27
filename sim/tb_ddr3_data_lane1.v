// Directed test for the second byte lane's read calibration, command-driven (Phase 9 Stage 3; Stage 1, Part 24 proved it
// first, standalone, with the injected scheme: docs/roadmap/phase-09-ddr.md). The two lanes are swept by one sequence of
// real reads and resolve independently, and what this is about is that they do not interfere: a shared DLL and one set of
// command pins with a lane-specific wiring bug could make one lane's result depend on the other's. Run three times, by the
// parameters DEAD0 and DEAD1:
//   DEAD1=0  both lanes have a memory behind them, with different patterns (lane 0 0xA5, lane 1 0x3C): each finds the
//            tap for its own pattern, neither lane's pins ever carry the other's pattern, and no pin is driven by two sides;
//   DEAD1=1  nothing behind lane 1 (a board whose lane 1 DQ pins or DRAM half is broken): its eight taps all fail and
//            `calib1_error` rises, lane 0 calibrates as before, the sweep is then one WRITE and eight READs (it goes on
//            to tap 7 for the lane that has not found one), and the controller takes no request, since it waits for
//            both lanes (a caller's write is not taken and `busy` does not claim it was);
//   DEAD0=1  the same with the lanes the other way round: nothing behind lane 0, `calib_error` rises and lane 1 calibrates.
// What it does not establish: what a lane with a real open pin does on silicon.
`timescale 1ns/1ps
module tb_ddr3_data_lane1;
    parameter DEAD0 = 0;
    parameter DEAD1 = 0;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default
    localparam CLK_HZ     = 25_000_000;
    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    wire        ddr3_ck, ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [14:0] ddr3_a;
    wire        ddr3_cke, ddr3_odt;
    wire        ddr3_reset_n = ~rst;
    wire [7:0]  ddr3_dq, ddr3_dqu;
    wire        ddr3_dqs, ddr3_dm, ddr3_udqs, ddr3_udm;

    wire pll_locked, dll_locked, init_ready;
    wire calib_done, calib_error, calib1_done, calib1_error;
    wire [2:0] calib_readclksel, calib1_readclksel;

    reg         write_req = 1'b0;
    wire        read_busy, write_busy, read_data_valid, refresh_busy;
    wire [15:0] read_data;

    ddr3_ecp5_top DUT (
        .rst_warm(1'b0),
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck), .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a), .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .write_wide(1'b0), .write_burst(128'b0), .write_burst_be(16'b0),
        .write_req(write_req), .write_bank(3'd1), .write_row(16'h0042),
        .write_col(16'h0007), .write_data(16'hBEEF), .write_be(2'b11), .write_busy(write_busy),
        .read_req(1'b0), .read_bank(3'b0), .read_row(16'b0), .read_col(16'b0),
        .read_busy(read_busy), .read_data(read_data), .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked), .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel), .calib_error(calib_error),
        .calib1_done(calib1_done), .calib1_readclksel(calib1_readclksel), .calib1_error(calib1_error)
    );

    wire         model_error;
    wire [511:0] model_error_msg;
    ddr3_model #(.CLK_HZ(CLK_HZ)) PROTO (
        .ck(ddr3_ck), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a), .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done()
    );

    // lane 0's memory, unless DEAD0
    wire [7:0] mem_dq_o;  wire mem_dq_oe, mem_dqs_oe, mem_dqs_o;  wire dq_error;  wire [511:0] dq_error_msg;
    generate if (!DEAD0) begin : LANE0_MEM
        ddr3_dq_model MEM (
            .sclk(DUT.sclk), .rst(DUT.rst_all), .ck(ddr3_ck),
            .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n), .ba(ddr3_ba), .a(ddr3_a),
            .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
            .read_active(DUT.read_active_final),
            .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_oe(mem_dqs_oe), .mem_dqs_o(mem_dqs_o),
            .dq_error(dq_error), .dq_error_msg(dq_error_msg)
        );
    end else begin : LANE0_NONE
        assign mem_dq_o = 8'b0; assign mem_dq_oe = 1'b0; assign mem_dqs_oe = 1'b0; assign mem_dqs_o = 1'b0;
        assign dq_error = 1'b0; assign dq_error_msg = 512'b0;
    end endgenerate
    genvar b;
    generate for (b = 0; b < 8; b = b + 1) begin : DQ_BUS assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz; end endgenerate
    assign ddr3_dqs = mem_dqs_oe ? mem_dqs_o : 1'bz;

    // lane 1's memory, unless DEAD1: then nothing drives lane 1's pins but the controller itself
    wire [7:0] mem_dqu_o;  wire mem_dqu_oe, mem_udqs_oe, mem_udqs_o;  wire dqu_error;  wire [511:0] dqu_error_msg;
    generate if (!DEAD1) begin : LANE1_MEM
        ddr3_dq_model MEM1 (
            .sclk(DUT.sclk), .rst(DUT.rst_all), .ck(ddr3_ck),
            .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n), .ba(ddr3_ba), .a(ddr3_a),
            .dq_pin(ddr3_dqu), .dqs_pin(ddr3_udqs), .dm_pin(ddr3_udm),
            .read_active(DUT.read_active_final_1),
            .mem_dq_o(mem_dqu_o), .mem_dq_oe(mem_dqu_oe), .mem_dqs_oe(mem_udqs_oe), .mem_dqs_o(mem_udqs_o),
            .dq_error(dqu_error), .dq_error_msg(dqu_error_msg)
        );
    end else begin : LANE1_NONE
        assign mem_dqu_o = 8'b0; assign mem_dqu_oe = 1'b0; assign mem_udqs_oe = 1'b0; assign mem_udqs_o = 1'b0;
        assign dqu_error = 1'b0; assign dqu_error_msg = 512'b0;
    end endgenerate
    genvar b1;
    generate for (b1 = 0; b1 < 8; b1 = b1 + 1) begin : DQU_BUS assign ddr3_dqu[b1] = mem_dqu_oe ? mem_dqu_o[b1] : 1'bz; end endgenerate
    assign ddr3_udqs = mem_udqs_oe ? mem_udqs_o : 1'bz;

    // ---- the commands as the DRAM sees them ----
    wire c_wr  =  ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n;
    wire c_rd  =  ddr3_ras_n && !ddr3_cas_n &&  ddr3_we_n;
    wire c_any = !(ddr3_ras_n && ddr3_cas_n && ddr3_we_n);
    integer n_wr = 0, n_rd = 0, n_any = 0;
    always @(posedge ddr3_ck) if (!rst && ddr3_reset_n && ddr3_cke && init_ready) begin
        if (c_wr)  n_wr  = n_wr  + 1;
        if (c_rd)  n_rd  = n_rd  + 1;
        if (c_any) n_any = n_any + 1;
    end

    // ---- contention, per bit; and cross-lane independence: neither lane's pins carry the OTHER lane's pattern ----
    function automatic has_real_x(input [7:0] v);
        integer i;
        begin has_real_x = 1'b0; for (i = 0; i < 8; i = i + 1) if (v[i] === 1'bx) has_real_x = 1'b1; end
    endfunction
    reg contention0 = 1'b0, contention1 = 1'b0;
    always @(posedge DUT.sclk) if (!rst) begin
        if (has_real_x(ddr3_dq)  || ddr3_dqs  === 1'bx) contention0 <= 1'b1;
        if (has_real_x(ddr3_dqu) || ddr3_udqs === 1'bx) contention1 <= 1'b1;
    end
    reg cross_0_carries_1 = 1'b0, cross_1_carries_0 = 1'b0;
    always @(posedge DUT.sclk) begin
        if (mem_dq_oe  && ddr3_dq  === 8'h3C) cross_0_carries_1 <= 1'b1;
        if (mem_dqu_oe && ddr3_dqu === 8'hA5) cross_1_carries_0 <= 1'b1;
    end

    integer errors = 0;
    task check(input [511:0] what, input got, input want);
        begin
            if (got !== want) begin $display("  FAIL %0s: got %b, expected %b", what, got, want); errors = errors + 1; end
            else $display("  ok   %0s", what);
        end
    endtask

    integer n_any0, n_wr0, g;
    initial begin
        $display("=== DDR3 second byte lane: independent calibration (Phase 9 Stage 3), DEAD0=%0d DEAD1=%0d ===", DEAD0, DEAD1);
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (8) @(posedge clk);
        check("PLL locked", pll_locked, 1'b1);
        check("the one, shared DLL locked", dll_locked, 1'b1);

        while (!((calib_done || calib_error) && (calib1_done || calib1_error)) && $time < 900_000) @(posedge clk);
        repeat (4) @(posedge clk);
        check("the protocol checker has no objection", model_error, 1'b0);
        check("lane 0's DQ model has no objection", dq_error, 1'b0);
        check("lane 1's DQ model has no objection", dqu_error, 1'b0);
        check("no pin of lane 0 driven by two sides at once", contention0, 1'b0);
        check("no pin of lane 1 driven by two sides at once", contention1, 1'b0);

        if (!DEAD0) begin
            check("lane 0 calibration completed (not errored)", calib_error, 1'b0);
            check("lane 0 calibration found a working tap", calib_done, 1'b1);
            if (calib_done) $display("  lane 0 calibrated READCLKSEL = %0d", calib_readclksel);
        end else begin
            check("lane 0 ended in an error: all eight taps failed", calib_error, 1'b1);
            check("lane 0 did not report a tap", calib_done, 1'b0);
        end
        if (!DEAD1) begin
            check("lane 1 calibration completed (not errored)", calib1_error, 1'b0);
            check("lane 1 calibration found a working tap", calib1_done, 1'b1);
            if (calib1_done) $display("  lane 1 calibrated READCLKSEL = %0d", calib1_readclksel);
        end else begin
            check("lane 1 ended in an error: all eight taps failed", calib1_error, 1'b1);
            check("lane 1 did not report a tap", calib1_done, 1'b0);
        end

        if (!DEAD0 && !DEAD1) begin
            check("lane 0's pins never carried lane 1's pattern", cross_0_carries_1, 1'b0);
            check("lane 1's pins never carried lane 0's pattern", cross_1_carries_0, 1'b0);
            check("one WRITE and three READs: both lanes pass at tap 2", n_wr == 1 && n_rd == 3, 1'b1);
        end else begin
            check("one WRITE and eight READs: the sweep went to tap 7", n_wr == 1 && n_rd == 8, 1'b1);
            // the controller waits for both lanes: a caller's write is not taken, and busy does not claim it was
            n_any0 = n_any;
            @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0;
            repeat (120) @(posedge clk);
            check("a caller's write reaches the pins as no command", n_any == n_any0, 1'b1);
            check("and the controller does not report busy for it", write_busy, 1'b0);
        end

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 SECOND LANE TEST PASSED");
        else             $display("DDR3 SECOND LANE TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #1_500_000;
        $display("TIMEOUT - calibration never completed on one or both lanes");
        $finish;
    end
endmodule
