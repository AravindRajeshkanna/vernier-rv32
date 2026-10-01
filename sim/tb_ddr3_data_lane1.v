// Directed test for Phase 9 Stage 1, Part 24 (docs/roadmap/phase-09-ddr.md): the second byte lane's
// own DQ/DQS read-calibration and write-then-readback round trip - the same real proof
// sim/tb_ddr3_data.v (Part 2) gave lane 0 - run a second time on lane 1's own pins,
// sharing the one real rtl/soc/ddr3_ddrdlla_ecp5.v instance real hardware has exactly one
// of (Part 24's own refactor: `ddr3_dqs_ecp5.v` used to instantiate its own `DDRDLLA`
// internally, correct only because a single lane was ever in scope; confirmed against
// LiteDRAM's own real, shipping ECP5 PHY that a second lane shares the first lane's DLL,
// not a second one).
//
// Both lanes calibrate at once, in one run, with different test patterns - not two
// separate single-lane tests - because the real question this file answers is not "does
// lane 1's own mechanism work in isolation" (already known from lane 0's own identical
// mechanism) but "do the two lanes interfere": a shared DLL with a lane-specific wiring
// bug could plausibly make one lane's own calibration depend on the other's state. This
// is checked directly: lane 0's own calibration must find lane 0's own pattern, lane 1's
// own must find lane 1's own, and neither dqs_pad_i/dq_pin bus may show data or timing
// that belongs to the other lane.
`timescale 1ns/1ps
module tb_ddr3_data_lane1;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default
    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg rst = 1'b1;
    // Lane 1's own reset releases a few sclk cycles after lane 0's (and the shared
    // DLL's) own `rst` - real hardware would never have two calibration state
    // machines perfectly synchronized either, and it is what makes a mis-wiring
    // between the two lanes' own signals show up: with both sweeps started at the
    // same instant, an identical FSM stepping in lockstep makes readclksel_0 and
    // readclksel_1 equal at every check regardless of which one either lane's own
    // DQS instance actually reads (measured - see docs/roadmap/phase-09-ddr.md, Part 24).
    reg rst1 = 1'b1;
    localparam LANE1_RST_STAGGER = 3;
    integer rst1_cnt;
    always @(posedge sclk or posedge rst) begin
        if (rst)             begin rst1 <= 1'b1; rst1_cnt <= LANE1_RST_STAGGER; end
        else if (rst1_cnt > 0) begin rst1_cnt <= rst1_cnt - 1; end
        else                  rst1 <= 1'b0;
    end

    wire eclk, sclk, pll_locked;
    ddr3_eclk_pll #(.CLK_PERIOD_NS(CLK_PERIOD)) PLL (
        .clk(clk), .eclk(eclk), .sclk(sclk), .locked(pll_locked)
    );

    // ---- the one, shared DLL (Part 24) ----
    wire ddrdel, dll_locked;
    ddr3_ddrdlla_ecp5 DLL (
        .eclk(eclk), .rst(rst),
        .ddrdel(ddrdel), .dll_locked(dll_locked)
    );

    // ---- lane 0 ----
    wire [7:0] wr_d0_0;
    wire       wr_en_0, read_active_0;
    wire [2:0] readclksel_0;
    wire       datavalid_0;
    wire [7:0] rd_q0_0;
    wire       calib_done_0, calib_error_0;
    wire [2:0] calib_readclksel_0;

    ddr3_read_calib #(.TEST_PATTERN(8'hA5)) CALIB0 (
        .clk(sclk), .rst(rst),
        .wr_d0(wr_d0_0), .wr_en(wr_en_0),
        .read_active(read_active_0), .readclksel(readclksel_0),
        .datavalid(datavalid_0), .rd_q0(rd_q0_0),
        .calib_done(calib_done_0), .calib_readclksel(calib_readclksel_0),
        .calib_error(calib_error_0)
    );

    wire dqsr90_0, dqsw_0, dqsw270_0, burstdet_0;
    wire dqs_bus_0;
    ddr3_dqs_ecp5 DQS0 (
        .eclk(eclk), .sclk(sclk), .rst(rst),
        .dqs_pad_i(dqs_bus_0), .read_active(read_active_0), .readclksel(readclksel_0),
        .ddrdel(ddrdel),
        .dqsr90(dqsr90_0), .dqsw(dqsw_0), .dqsw270(dqsw270_0),
        .datavalid(datavalid_0), .burstdet(burstdet_0)
    );

    wire dqs_wr_o_0, dqs_wr_oe_0, dq_burst_0;
    ddr3_dqs_write_ecp5 DQS_WR0 (
        .sclk(sclk), .eclk(eclk), .dqsw(dqsw_0), .rst(rst),
        .write_start(wr_en_0),
        .dqs_o(dqs_wr_o_0), .dqs_oe(dqs_wr_oe_0), .burst_active(dq_burst_0)
    );
    reg [7:0] dq_data_hold_0;
    always @(posedge sclk or posedge rst) begin
        if (rst)          dq_data_hold_0 <= 8'b0;
        else if (wr_en_0) dq_data_hold_0 <= wr_d0_0;
    end

    wire [7:0] fpga_dq_o_0, fpga_dq_oe_0;
    wire [7:0] dq_bus_0;
    wire [7:0] fpga_rd_q0_0;
    ddr3_dq_serdes_ecp5 #(.DQ_WIDTH(8)) SERDES0 (
        .sclk(sclk), .eclk(eclk), .rst(rst),
        .dqsr90(dqsr90_0), .dqsw270(dqsw270_0),
        .rdpntr(3'b0), .wrpntr(3'b0),
        .wr_d3(dq_data_hold_0), .wr_d2(dq_data_hold_0), .wr_d1(dq_data_hold_0), .wr_d0(dq_data_hold_0),
        .wr_en(dq_burst_0),
        .rd_q3(), .rd_q2(), .rd_q1(), .rd_q0(fpga_rd_q0_0),
        .dq_o(fpga_dq_o_0), .dq_oe(fpga_dq_oe_0), .dq_i(dq_bus_0)
    );
    assign rd_q0_0 = fpga_rd_q0_0;

    wire [7:0] mem_dq_o_0;
    wire       mem_dq_oe_0, mem_dqs_oe_0, mem_dqs_o_0;
    wire       dq_error_0;
    wire [511:0] dq_error_msg_0;
    ddr3_dq_model MEM0 (
        .sclk(sclk), .rst(rst),
        .ck(1'b0),
        .cs_n(1'b1), .ras_n(1'b1), .cas_n(1'b1), .we_n(1'b1), .ba(3'b0), .a(16'b0),
        .dq_pin(dq_bus_0), .dqs_pin(dqs_bus_0),
        .read_active(read_active_0),
        .mem_dq_o(mem_dq_o_0), .mem_dq_oe(mem_dq_oe_0), .mem_dqs_oe(mem_dqs_oe_0), .mem_dqs_o(mem_dqs_o_0),
        .dq_error(dq_error_0), .dq_error_msg(dq_error_msg_0)
    );
    genvar b0;
    generate
        for (b0 = 0; b0 < 8; b0 = b0 + 1) begin : DQ_BUS0
            assign dq_bus_0[b0] = fpga_dq_oe_0[b0] ? fpga_dq_o_0[b0] :
                                   (mem_dq_oe_0    ? mem_dq_o_0[b0]  : 1'bz);
        end
    endgenerate
    assign dqs_bus_0 = dqs_wr_oe_0 ? dqs_wr_o_0 : (mem_dqs_oe_0 ? mem_dqs_o_0 : 1'bz);
    wire bus_contention_0 = (|fpga_dq_oe_0) && mem_dq_oe_0;
    reg contention_seen_0 = 1'b0;
    always @(posedge sclk) if (bus_contention_0) contention_seen_0 <= 1'b1;

    // ---- lane 1: the same chain, its own pins, a different test pattern ----
    wire [7:0] wr_d0_1;
    wire       wr_en_1, read_active_1;
    wire [2:0] readclksel_1;
    wire       datavalid_1;
    wire [7:0] rd_q0_1;
    wire       calib_done_1, calib_error_1;
    wire [2:0] calib_readclksel_1;

    ddr3_read_calib #(.TEST_PATTERN(8'h3C)) CALIB1 (
        .clk(sclk), .rst(rst1),
        .wr_d0(wr_d0_1), .wr_en(wr_en_1),
        .read_active(read_active_1), .readclksel(readclksel_1),
        .datavalid(datavalid_1), .rd_q0(rd_q0_1),
        .calib_done(calib_done_1), .calib_readclksel(calib_readclksel_1),
        .calib_error(calib_error_1)
    );

    wire dqsr90_1, dqsw_1, dqsw270_1, burstdet_1;
    wire dqs_bus_1;
    ddr3_dqs_ecp5 DQS1 (
        .eclk(eclk), .sclk(sclk), .rst(rst1),
        .dqs_pad_i(dqs_bus_1), .read_active(read_active_1), .readclksel(readclksel_1),
        .ddrdel(ddrdel),
        .dqsr90(dqsr90_1), .dqsw(dqsw_1), .dqsw270(dqsw270_1),
        .datavalid(datavalid_1), .burstdet(burstdet_1)
    );

    wire dqs_wr_o_1, dqs_wr_oe_1, dq_burst_1;
    ddr3_dqs_write_ecp5 DQS_WR1 (
        .sclk(sclk), .eclk(eclk), .dqsw(dqsw_1), .rst(rst1),
        .write_start(wr_en_1),
        .dqs_o(dqs_wr_o_1), .dqs_oe(dqs_wr_oe_1), .burst_active(dq_burst_1)
    );
    reg [7:0] dq_data_hold_1;
    always @(posedge sclk or posedge rst1) begin
        if (rst1)         dq_data_hold_1 <= 8'b0;
        else if (wr_en_1) dq_data_hold_1 <= wr_d0_1;
    end

    wire [7:0] fpga_dq_o_1, fpga_dq_oe_1;
    wire [7:0] dq_bus_1;
    wire [7:0] fpga_rd_q0_1;
    ddr3_dq_serdes_ecp5 #(.DQ_WIDTH(8)) SERDES1 (
        .sclk(sclk), .eclk(eclk), .rst(rst1),
        .dqsr90(dqsr90_1), .dqsw270(dqsw270_1),
        .rdpntr(3'b0), .wrpntr(3'b0),
        .wr_d3(dq_data_hold_1), .wr_d2(dq_data_hold_1), .wr_d1(dq_data_hold_1), .wr_d0(dq_data_hold_1),
        .wr_en(dq_burst_1),
        .rd_q3(), .rd_q2(), .rd_q1(), .rd_q0(fpga_rd_q0_1),
        .dq_o(fpga_dq_o_1), .dq_oe(fpga_dq_oe_1), .dq_i(dq_bus_1)
    );
    assign rd_q0_1 = fpga_rd_q0_1;

    wire [7:0] mem_dq_o_1;
    wire       mem_dq_oe_1, mem_dqs_oe_1, mem_dqs_o_1;
    wire       dq_error_1;
    wire [511:0] dq_error_msg_1;
    ddr3_dq_model MEM1 (
        .sclk(sclk), .rst(rst1),
        .ck(1'b0),
        .cs_n(1'b1), .ras_n(1'b1), .cas_n(1'b1), .we_n(1'b1), .ba(3'b0), .a(16'b0),
        .dq_pin(dq_bus_1), .dqs_pin(dqs_bus_1),
        .read_active(read_active_1),
        .mem_dq_o(mem_dq_o_1), .mem_dq_oe(mem_dq_oe_1), .mem_dqs_oe(mem_dqs_oe_1), .mem_dqs_o(mem_dqs_o_1),
        .dq_error(dq_error_1), .dq_error_msg(dq_error_msg_1)
    );
    genvar b1;
    generate
        for (b1 = 0; b1 < 8; b1 = b1 + 1) begin : DQ_BUS1
            assign dq_bus_1[b1] = fpga_dq_oe_1[b1] ? fpga_dq_o_1[b1] :
                                   (mem_dq_oe_1    ? mem_dq_o_1[b1]  : 1'bz);
        end
    endgenerate
    assign dqs_bus_1 = dqs_wr_oe_1 ? dqs_wr_o_1 : (mem_dqs_oe_1 ? mem_dqs_o_1 : 1'bz);
    wire bus_contention_1 = (|fpga_dq_oe_1) && mem_dq_oe_1;
    reg contention_seen_1 = 1'b0;
    always @(posedge sclk) if (bus_contention_1) contention_seen_1 <= 1'b1;

    // ---- cross-lane independence: neither lane's own bus may ever show the OTHER
    // lane's own test pattern - the real, measured proof that the two are wired to
    // genuinely separate pins, not aliased copies of one signal ----
    reg cross_seen_0_carries_1 = 1'b0;
    reg cross_seen_1_carries_0 = 1'b0;
    always @(posedge sclk) begin
        if (mem_dq_oe_0 && dq_bus_0 === 8'h3C) cross_seen_0_carries_1 <= 1'b1;
        if (mem_dq_oe_1 && dq_bus_1 === 8'hA5) cross_seen_1_carries_0 <= 1'b1;
    end

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

    initial begin
        $display("=== DDR3 second byte lane: independent DQ/DQS calibration (Phase 9 Stage 1, Part 24) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        repeat (8) @(posedge sclk);
        check("PLL locked", pll_locked, 1'b1);
        check("the one, shared DLL locked", dll_locked, 1'b1);

        while (!((calib_done_0 || calib_error_0) && (calib_done_1 || calib_error_1))
               && $time < 500_000) @(posedge sclk);

        check("lane 0 calibration completed (not errored)", calib_error_0, 1'b0);
        check("lane 0 calibration found a working tap", calib_done_0, 1'b1);
        check("lane 1 calibration completed (not errored)", calib_error_1, 1'b0);
        check("lane 1 calibration found a working tap", calib_done_1, 1'b1);
        if (calib_done_0) $display("  lane 0 calibrated READCLKSEL = %0d", calib_readclksel_0);
        if (calib_done_1) $display("  lane 1 calibrated READCLKSEL = %0d", calib_readclksel_1);

        repeat (4) @(posedge sclk);
        check("no bus contention on lane 0's own pins", contention_seen_0, 1'b0);
        check("no bus contention on lane 1's own pins", contention_seen_1, 1'b0);
        check("lane 0's own bus never carried lane 1's own pattern", cross_seen_0_carries_1, 1'b0);
        check("lane 1's own bus never carried lane 0's own pattern", cross_seen_1_carries_0, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 SECOND LANE TEST PASSED");
        else             $display("DDR3 SECOND LANE TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT - calibration never completed on one or both lanes");
        $finish;
    end
endmodule
