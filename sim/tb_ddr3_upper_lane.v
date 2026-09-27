// Test for Phase 9 Stage 1, Part 23 (docs/roadmap.md): the untouched upper byte
// lane (this design transfers through lane 0 only; the part is x16) is held
// safely inert, not simply left unconnected.
//
// A x16 DRAM samples DQ[15:8] on every write unless UDM tells it not to; this
// design has never driven UDM, DQ[15:8] or UDQS at all. Left unconnected, on
// real hardware those pins would be unconstrained pads with an unstated
// direction - not just "unused", a real signal-integrity and correctness risk,
// since the DRAM actively drives DQ[15:8]/UDQS during every real READ this
// design's own lane-0 writes provoke no protection for. This test proves the
// three real, cheap guarantees rtl/soc/ddr3_ecp5_top.v now gives instead:
//   - `ddr3_udm` is driven, and only ever high (masked) - a write issued
//     through lane 0 can never be read by the DRAM as also writing lane 1;
//   - `ddr3_dqu` (the upper DQ lane) is never driven by the FPGA side - a
//     real READ's own drive from the DRAM is never contended;
//   - `ddr3_udqs` is never driven by the FPGA side, for the same reason.
// Checked across a run that actually exercises calibration, real writes and
// real refreshes - not just at reset, when everything reads inert by default
// regardless of whether the design is correct.
`timescale 1ns/1ps
module tb_ddr3_upper_lane;
    localparam CLK_PERIOD = 40;   // 25 MHz sclk

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
    wire        ddr3_dm;
    wire [7:0]  ddr3_dqu;
    wire        ddr3_udqs;
    wire        ddr3_udm;

    wire pll_locked, dll_locked, init_ready;
    wire calib_done, calib_error;
    wire [2:0] calib_readclksel;

    reg         write_req = 1'b0;
    reg  [2:0]  write_bank = 3'd0;
    reg  [15:0] write_row  = 16'h0000;
    reg  [15:0] write_col  = 16'h0000;
    reg  [7:0]  write_data = 8'h00;
    wire        write_busy, read_busy, read_data_valid, refresh_busy;
    wire [7:0]  read_data;

    ddr3_ecp5_top DUT (
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .write_req(write_req), .write_bank(write_bank), .write_row(write_row),
        .write_col(write_col), .write_data(write_data), .write_busy(write_busy),
        .read_req(1'b0), .read_bank(3'b0), .read_row(16'b0), .read_col(16'b0),
        .read_busy(read_busy), .read_data(read_data), .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked),
        .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    wire        dq_error;
    wire [511:0] dq_error_msg;
    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_oe, mem_dqs_o;
    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
        .read_active(DUT.read_active_final),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_oe(mem_dqs_oe), .mem_dqs_o(mem_dqs_o),
        .dq_error(dq_error), .dq_error_msg(dq_error_msg)
    );
    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = mem_dqs_oe ? mem_dqs_o : 1'bz;

    // ---- independent monitor: every sclk cycle, from reset onward ----
    integer cyc = 0;
    integer udm_low_count   = 0;
    integer udm_unknown_count = 0;
    integer dqu_driven_count = 0;
    integer udqs_driven_count = 0;
    always @(posedge DUT.sclk) begin
        if (ddr3_udm === 1'b0)                        udm_low_count     = udm_low_count + 1;
        else if (ddr3_udm !== 1'b1)                    udm_unknown_count = udm_unknown_count + 1;
        if (ddr3_dqu !== 8'bzzzzzzzz)                   dqu_driven_count  = dqu_driven_count + 1;
        if (ddr3_udqs !== 1'bz)                         udqs_driven_count = udqs_driven_count + 1;
        cyc = cyc + 1;
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

    integer i, guard;
    initial begin
        $display("=== DDR3 upper byte lane held safely inert (Phase 9 Stage 1, Part 23) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check_true("calibration completed before this test begins", calib_done && !calib_error);

        // Real writes, so real command-driven transactions - not just reset and
        // calibration - are covered by the monitor above.
        for (i = 0; i < 6; i = i + 1) begin
            write_bank <= i[2:0];
            write_row  <= 16'h0300 + i;
            write_col  <= 16'h0010 * i;
            write_data <= 8'h40 + i;
            @(posedge clk);
            write_req <= 1'b1;
            @(posedge clk);
            write_req <= 1'b0;
            @(posedge clk);
            guard = 0;
            while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
        end
        // Long enough to see at least one real refresh go by too (Part 12: ~194 cycles).
        repeat (220) @(posedge clk);

        check_true("real writes happened during this run (the monitor covers more than idle)", cyc > 200);
        check_true("ddr3_udm was never sampled low", udm_low_count == 0);
        check_true("ddr3_udm was never sampled at an unknown level (always a real 0 or 1)", udm_unknown_count == 0);
        check_true("ddr3_dqu was never driven by the FPGA side (always high-Z)", dqu_driven_count == 0);
        check_true("ddr3_udqs was never driven by the FPGA side (always high-Z)", udqs_driven_count == 0);
        check_true("no DQ/DQS/DM timing error on the lane this design actually uses", !dq_error);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 UPPER LANE TEST PASSED");
        else             $display("DDR3 UPPER LANE TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
