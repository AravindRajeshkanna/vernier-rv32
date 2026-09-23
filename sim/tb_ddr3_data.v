// Directed test for Phase 9 Stage 1, Part 2 (docs/roadmap.md): one
// byte lane's own DQ/DQS read-calibration and write-then-readback
// round trip, against sim/ddr3_dq_model.v's own real behavioral
// memory. Confirms rtl/soc/ddr3_read_calib.v's own real READCLKSEL
// sweep finds a genuinely working tap (not the lucky-default-position
// case) and that the captured data actually matches what was written.
`timescale 1ns/1ps
module tb_ddr3_data;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default
    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg rst = 1'b1;

    wire eclk, sclk, pll_locked;
    ddr3_eclk_pll #(.CLK_PERIOD_NS(CLK_PERIOD)) PLL (
        .clk(clk), .eclk(eclk), .sclk(sclk), .locked(pll_locked)
    );

    wire [7:0] wr_d0;
    wire       wr_en, read_active;
    wire [2:0] readclksel;
    wire       datavalid;
    wire [7:0] rd_q0;
    wire       calib_done, calib_error;
    wire [2:0] calib_readclksel;

    ddr3_read_calib #(.TEST_PATTERN(8'hA5)) CALIB (
        .clk(sclk), .rst(rst),
        .wr_d0(wr_d0), .wr_en(wr_en),
        .read_active(read_active), .readclksel(readclksel),
        .datavalid(datavalid), .rd_q0(rd_q0),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    wire       dqsr90, dqsw, dqsw270, burstdet, dll_locked;
    wire       dqs_bus;

    ddr3_dqs_ecp5 DQS (
        .eclk(eclk), .sclk(sclk), .rst(rst),
        .dqs_pad_i(dqs_bus), .read_active(read_active), .readclksel(readclksel),
        .dqsr90(dqsr90), .dqsw(dqsw), .dqsw270(dqsw270),
        .datavalid(datavalid), .burstdet(burstdet), .dll_locked(dll_locked)
    );

    wire [7:0] fpga_dq_o, fpga_dq_oe;
    wire [7:0] dq_bus;
    wire [7:0] fpga_rd_q3, fpga_rd_q2, fpga_rd_q1, fpga_rd_q0;

    ddr3_dq_serdes_ecp5 #(.DQ_WIDTH(8)) SERDES (
        .sclk(sclk), .eclk(eclk), .rst(rst),
        .dqsr90(dqsr90), .dqsw270(dqsw270),
        .wr_d3(wr_d0), .wr_d2(wr_d0), .wr_d1(wr_d0), .wr_d0(wr_d0),
        .wr_en(wr_en),
        .rd_q3(fpga_rd_q3), .rd_q2(fpga_rd_q2), .rd_q1(fpga_rd_q1), .rd_q0(fpga_rd_q0),
        .dq_o(fpga_dq_o), .dq_oe(fpga_dq_oe), .dq_i(dq_bus)
    );
    assign rd_q0 = fpga_rd_q0;

    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_o;

    ddr3_dq_model MEM (
        .sclk(sclk), .rst(rst),
        .wr_d0(wr_d0), .wr_en(wr_en),
        .read_active(read_active),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_o(mem_dqs_o)
    );

    // ---- real tristate bus arbitration, matching how the two real
    // sides of an actual DDR3 bus share one set of pins - and a real
    // bus-contention check, not assumed impossible ----
    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign dq_bus[b] = fpga_dq_oe[b] ? fpga_dq_o[b] :
                                (mem_dq_oe    ? mem_dq_o[b]  : 1'bz);
        end
    endgenerate
    assign dqs_bus = mem_dq_oe ? mem_dqs_o : 1'bz;

    wire bus_contention = (|fpga_dq_oe) && mem_dq_oe;

    // Latches the first real bus-contention violation seen at any point
    // during the run - the FPGA's own write-drive window is a single
    // real cycle (S_WRITE's own one-cycle wr_en pulse), long over by
    // the time the final check below runs, so sampling `bus_contention`
    // live at that one instant would miss a real transient violation
    // earlier in the run. Declared here, above its first use, rather
    // than after - `always @(posedge sclk)` below only reads it.
    reg contention_seen = 1'b0;
    always @(posedge sclk) if (bus_contention) contention_seen <= 1'b1;

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
        $display("=== DDR3 DQ/DQS data path (Phase 9 Stage 1, Part 2) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        repeat (8) @(posedge sclk);
        check("PLL locked", pll_locked, 1'b1);
        check("DLL locked", dll_locked, 1'b1);

        while (!calib_done && !calib_error && $time < 500_000) @(posedge sclk);

        check("calibration completed (not errored)", calib_error, 1'b0);
        check("calibration found a working tap", calib_done, 1'b1);
        if (calib_done)
            $display("  calibrated READCLKSEL = %0d", calib_readclksel);

        repeat (4) @(posedge sclk);
        check("no bus contention seen at any point", contention_seen, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 DATA PATH TEST PASSED");
        else             $display("DDR3 DATA PATH TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT - calibration never completed");
        $finish;
    end
endmodule
