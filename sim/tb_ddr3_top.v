// Integrated test for Phase 9 Stage 1, Part 3 (docs/roadmap.md):
// rtl/soc/ddr3_ecp5_top.v wired against BOTH sim models at once for
// the first time - sim/ddr3_model.v (the real JEDEC command/timing
// protocol checker, Part 1) on the command/address pins, and
// sim/ddr3_dq_model.v (the byte-lane DQ/DQS memory, Part 2) on the
// data pins - proving the real init sequence and the real read
// calibration sweep both run correctly off one shared, PLL-derived
// clock tree, not two independently-clocked islands as in each part's
// own standalone testbench.
`timescale 1ns/1ps
module tb_ddr3_top;
    localparam CLK_HZ    = 25_000_000;
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

    wire pll_locked, dll_locked, init_ready;
    wire calib_done, calib_error;
    wire [2:0] calib_readclksel;

    ddr3_ecp5_top DUT (
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs),
        .pll_locked(pll_locked), .dll_locked(dll_locked),
        .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    // ---- Part 1's own real protocol checker, watching the same real
    // command/address pins this integration now drives off sclk ----
    wire        model_error;
    wire [511:0] model_error_msg;
    wire        model_seq_done;

    ddr3_model #(.CLK_HZ(CLK_HZ)) PROTO (
        .clk(clk), .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done(model_seq_done)
    );

    // ---- Part 2's own real byte-lane DQ/DQS memory, watching the
    // same real DQ pins this integration now drives via ODDRX2DQA/
    // TSHX2DQA off the PLL's own sclk/eclk pair ----
    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_o;

    // The calibration sweep's own wr_d0/wr_en/read_active are internal
    // to DUT - sim/ddr3_dq_model.v needs them too, so they are re-
    // derived here from the same real pins DUT itself exposes rather
    // than reaching into DUT's own hierarchy: wr_en/read_active have
    // no external pin, so this testbench taps DUT's own internal nets
    // directly (permitted for a testbench, not for synthesizable RTL).
    wire [7:0] tap_wr_d0      = DUT.wr_d0;
    wire       tap_wr_en      = DUT.wr_en;
    wire       tap_read_active = DUT.read_active;

    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .wr_d0(tap_wr_d0), .wr_en(tap_wr_en),
        .read_active(tap_read_active),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_o(mem_dqs_o)
    );

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = mem_dq_oe ? mem_dqs_o : 1'bz;

    // A real bus-contention check on the shared DQ pins - both DUT's
    // own dq_oe (tapped internally, since ddr3_dq itself only shows the
    // resolved 'z/'0/'1 value, not which side actually asserted) and
    // the memory model's own mem_dq_oe driving at once would be a real
    // hardware conflict, not assumed impossible.
    wire [7:0] tap_dq_oe = DUT.dq_oe;
    wire bus_contention = (|tap_dq_oe) && mem_dq_oe;
    reg  contention_seen = 1'b0;
    always @(posedge DUT.sclk) if (bus_contention) contention_seen <= 1'b1;

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
        $display("=== DDR3 PHY integration (Phase 9 Stage 1, Part 3) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        repeat (8) @(posedge clk);
        check("PLL locked", pll_locked, 1'b1);
        check("DLL locked", dll_locked, 1'b1);

        while (!init_ready && !model_error && $time < 400_000) @(posedge clk);
        check("real protocol checker saw no error", model_error, 1'b0);
        check("init sequence reports ready", init_ready, 1'b1);

        // sim/ddr3_model.v's own seq_done comes from an independently-
        // clocked counter that legitimately lags ready by a few real
        // cycles without either side being wrong - the same real
        // timing gap sim/tb_ddr3_init.v's own fix already found for
        // Part 1; sampled here in the same instant it would reproduce
        // it.
        repeat (4) @(posedge clk);
        check("protocol checker's own seq_done agrees", model_seq_done, init_ready);

        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check("calibration completed (not errored)", calib_error, 1'b0);
        check("calibration found a working tap", calib_done, 1'b1);
        if (calib_done)
            $display("  calibrated READCLKSEL = %0d", calib_readclksel);

        repeat (4) @(posedge clk);
        check("no bus contention seen at any point", contention_seen, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 PHY INTEGRATION TEST PASSED");
        else             $display("DDR3 PHY INTEGRATION TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
