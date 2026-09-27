// Integrated test for Phase 9 Stage 1, Part 25 (docs/roadmap.md): lane 1's own
// calibration, DQ/DQS write-drive and UDM masking, wired into the real
// rtl/soc/ddr3_ecp5_top.v and run through its real, shared clock/reset tree - the
// same proof sim/tb_ddr3_top.v (Parts 3-5) gave lane 0, mirrored for lane 1, plus
// confirmation that lane 0 - calibrating in the very same run - is undisturbed by
// it. sim/tb_ddr3_data_lane1.v (Part 24) proved the same mechanism standalone,
// against its own free-running clock; this proves it survives real integration,
// the same gap Part 3 once closed for lane 0 alone.
`timescale 1ns/1ps
module tb_ddr3_top_lane1;
    localparam CLK_PERIOD = 40;   // 25 MHz

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
    wire calib1_done, calib1_error;
    wire [2:0] calib1_readclksel;

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
        .write_req(1'b0), .write_bank(3'b0), .write_row(16'b0),
        .write_col(16'b0), .write_data(8'b0), .write_busy(write_busy),
        .read_req(1'b0), .read_bank(3'b0), .read_row(16'b0), .read_col(16'b0),
        .read_busy(read_busy), .read_data(read_data), .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked),
        .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error),
        .calib1_done(calib1_done), .calib1_readclksel(calib1_readclksel),
        .calib1_error(calib1_error)
    );

    // ---- lane 0's own memory model, watching lane 0's own real pins - proof that
    // wiring lane 1 in did not disturb what Part 3-5/17/18/22 already established ----
    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_oe, mem_dqs_o;
    wire       dq_error;
    wire [511:0] dq_error_msg;
    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
        .read_active(DUT.read_active),
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

    // ---- lane 1's own memory model - the same role MEM plays for lane 0, and for
    // the identical reason: calibration's own read-back self-check needs a real DRAM
    // to loop its test pattern back through, or every tap fails and calib1_error
    // asserts regardless of whether the RTL is correct. `read_active` is tapped from
    // DUT.read_active_1 (calibration's own signal, mirroring DUT.read_active for lane
    // 0 in sim/tb_ddr3_top.v) - lane 1 issues no real DRAM command either. ----
    wire [7:0] mem_dqu_o;
    wire       mem_dqu_oe, mem_udqs_oe, mem_udqs_o;
    wire       dqu_error;
    wire [511:0] dqu_error_msg;
    ddr3_dq_model MEM1 (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .ck(1'b0),
        .cs_n(1'b1), .ras_n(1'b1), .cas_n(1'b1), .we_n(1'b1), .ba(3'b0), .a(16'b0),
        .dq_pin(ddr3_dqu), .dqs_pin(ddr3_udqs), .dm_pin(ddr3_udm),
        .read_active(DUT.read_active_1),
        .mem_dq_o(mem_dqu_o), .mem_dq_oe(mem_dqu_oe), .mem_dqs_oe(mem_udqs_oe), .mem_dqs_o(mem_udqs_o),
        .dq_error(dqu_error), .dq_error_msg(dqu_error_msg)
    );
    genvar b1;
    generate
        for (b1 = 0; b1 < 8; b1 = b1 + 1) begin : DQU_BUS
            assign ddr3_dqu[b1] = mem_dqu_oe ? mem_dqu_o[b1] : 1'bz;
        end
    endgenerate
    assign ddr3_udqs = mem_udqs_oe ? mem_udqs_o : 1'bz;

    // Real contention on the SHARED lane-0 pins - the same per-bit, not
    // reduction-XOR, discipline sim/tb_ddr3_top.v's own header explains why.
    function automatic has_real_x;
        input [7:0] v;
        integer i;
        begin
            has_real_x = 1'b0;
            for (i = 0; i < 8; i = i + 1)
                if (v[i] === 1'bx) has_real_x = 1'b1;
        end
    endfunction
    reg dq_contention_seen = 1'b0;
    always @(posedge DUT.sclk) if (!rst && has_real_x(ddr3_dq)) dq_contention_seen <= 1'b1;
    reg dqs_contention_seen = 1'b0;
    always @(posedge DUT.sclk) if (!rst && (ddr3_dqs === 1'bx)) dqs_contention_seen <= 1'b1;

    // lane 1's own pins: nothing else in this testbench drives them, so any real x
    // there can only be the DUT's own internal drive disagreeing with itself.
    reg dqu_contention_seen = 1'b0;
    always @(posedge DUT.sclk) if (!rst && has_real_x(ddr3_dqu)) dqu_contention_seen <= 1'b1;
    reg udqs_contention_seen = 1'b0;
    always @(posedge DUT.sclk) if (!rst && (ddr3_udqs === 1'bx)) udqs_contention_seen <= 1'b1;

    // UDM's own real waveform: never floating (it is FPGA-output-only, Part 22/23's
    // own reasoning), and it must actually toggle low at some point - proof lane 1's
    // own write-drive really fired, not dead code, the same
    // `dqs_write_drive_seen`-style proof sim/tb_ddr3_top.v gives lane 0's DQS_WR.
    reg udm_floated = 1'b0;
    always @(posedge DUT.sclk) if (!rst && ddr3_udm !== 1'b0 && ddr3_udm !== 1'b1) udm_floated <= 1'b1;
    reg udm_went_low = 1'b0;
    always @(posedge DUT.sclk) if (ddr3_udm === 1'b0) udm_went_low <= 1'b1;
    // Masking, not just toggling: UDM tied permanently low would still pass the two
    // checks above, so this also requires it to go back HIGH after having been low -
    // real evidence of a burst window, not a stuck level.
    reg udm_seen_low_then_high = 1'b0;
    reg udm_was_low = 1'b0;
    always @(posedge DUT.sclk) begin
        if (ddr3_udm === 1'b0)                 udm_was_low <= 1'b1;
        if (udm_was_low && ddr3_udm === 1'b1)  udm_seen_low_then_high <= 1'b1;
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
        $display("=== DDR3 lane 1 wired in for real, alongside lane 0 (Phase 9 Stage 1, Part 25) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        repeat (8) @(posedge clk);
        check("PLL locked", pll_locked, 1'b1);
        check("the one, shared DLL locked", dll_locked, 1'b1);

        while (!((calib_done || calib_error) && (calib1_done || calib1_error))
               && $time < 600_000) @(posedge clk);

        check("lane 0 calibration completed (not errored)", calib_error, 1'b0);
        check("lane 0 calibration found a working tap", calib_done, 1'b1);
        check("lane 1 calibration completed (not errored)", calib1_error, 1'b0);
        check("lane 1 calibration found a working tap", calib1_done, 1'b1);
        if (calib_done)  $display("  lane 0 calibrated READCLKSEL = %0d", calib_readclksel);
        if (calib1_done) $display("  lane 1 calibrated READCLKSEL = %0d", calib1_readclksel);

        repeat (4) @(posedge clk);
        check("no DQ/DQS write-burst timing error on lane 0 (its memory model agrees)", dq_error, 1'b0);
        check("no bus contention on lane 0's own DQ pins", dq_contention_seen, 1'b0);
        check("no bus contention on lane 0's own DQS pin", dqs_contention_seen, 1'b0);
        check("no contention on lane 1's own DQ pins", dqu_contention_seen, 1'b0);
        check("no contention on lane 1's own UDQS pin", udqs_contention_seen, 1'b0);
        check("UDM never floats (a real level at every real cycle)", udm_floated, 1'b0);
        check("UDM really did go low at some point (lane 1's own write-drive fired)", udm_went_low, 1'b1);
        check("UDM masks - low, then high again - not stuck permanently low", udm_seen_low_then_high, 1'b1);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 LANE 1 INTEGRATION TEST PASSED");
        else             $display("DDR3 LANE 1 INTEGRATION TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
