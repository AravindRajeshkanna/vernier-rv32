// Directed test for Phase 9 Stage 1, Part 1 (docs/roadmap.md):
// rtl/soc/ddr3_init_seq.v + rtl/soc/ddr3_phy_ecp5.v against
// sim/ddr3_model.v's own real protocol checker. Confirms the real
// command sequence (MR2 -> MR3 -> MR1 -> MR0 -> ZQCL), the real
// reset/CKE timing, and the real inter-command waits are honored - not
// that any data can be read or written yet, since no data path exists
// in this slice.
`timescale 1ns/1ps
module tb_ddr3_init;
    localparam CLK_HZ    = 25_000_000;
    localparam CLK_PERIOD = 40;   // 25 MHz
    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg rst = 1'b1;

    wire        cmd_valid;
    wire [2:0]  cmd_cs_ras_cas_we;
    wire [2:0]  cmd_ba;
    wire [15:0] cmd_addr;
    wire        cmd_cke, cmd_reset_n, cmd_odt;
    wire        ready;

    ddr3_init_seq #(.CLK_HZ(CLK_HZ)) SEQ (
        .clk(clk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_cs_ras_cas_we(cmd_cs_ras_cas_we),
        .cmd_ba(cmd_ba), .cmd_addr(cmd_addr),
        .cmd_cke(cmd_cke), .cmd_reset_n(cmd_reset_n), .cmd_odt(cmd_odt),
        .ready(ready)
    );

    wire ddr3_ck, ddr3_ck_n, ddr3_cs_n, ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [15:0] ddr3_a;
    wire        ddr3_cke, ddr3_reset_n, ddr3_odt;

    // The PHY's CK runs on the edge clock (Part 16), twice clk.
    wire eclk, pll_sclk, pll_locked;
    ddr3_eclk_pll PLL (.clk(clk), .eclk(eclk), .sclk(pll_sclk), .locked(pll_locked));

    ddr3_phy_ecp5 PHY (
        .clk(clk), .eclk(eclk), .rst(rst),
        .cmd_valid(cmd_valid), .cmd_cs_ras_cas_we(cmd_cs_ras_cas_we),
        .cmd_ba(cmd_ba), .cmd_addr(cmd_addr),
        .cmd_cke(cmd_cke), .cmd_reset_n(cmd_reset_n), .cmd_odt(cmd_odt),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt)
    );

    wire model_error;
    wire [511:0] model_error_msg;
    wire model_seq_done;

    ddr3_model #(.CLK_HZ(CLK_HZ)) MODEL (
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done(model_seq_done)
    );

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
        $display("=== DDR3 init sequence (Phase 9 Stage 1, Part 1) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Real CK/CK# toggling from the very first cycle - a stuck
        // clock output would be a real, silent PHY bug no protocol
        // check above would catch on its own.
        repeat (8) @(posedge clk);
        // eclk falls at every clk edge (and rises 10 ns after it), so
        // sampling at the edge itself races the two continuous assigns that
        // derive CK and CK# from it: one has updated, the other not yet. A
        // settle delay reads them after both have. Measured with a probe:
        // ck=0 ck_n=0 at the exact edge, complementary a moment later.
        #1;
        check("ddr3_ck and ddr3_ck_n are complementary", ddr3_ck, ~ddr3_ck_n);

        // Wait for the sequence to finish, or the model to flag a real
        // protocol violation, or a real timeout - whichever comes
        // first, so a hang says why rather than spinning silently.
        while (!ready && !model_error && $time < 500_000) @(posedge clk);

        check("init sequence reached ready", ready, 1'b1);

        // The model's own seq_done tracks its own, independently
        // clocked since_last_cmd counter - a real, legitimate cycle or
        // two of relative skew against ddr3_init_seq.v's own `ready`
        // is possible without either being wrong, so give it a little
        // room to settle rather than sampling the exact same edge.
        repeat (4) @(posedge clk);

        check("protocol checker saw no violation", model_error, 1'b0);
        if (model_error) $display("  model says: %0s", model_error_msg);
        check("protocol checker confirms the full sequence completed",
              model_seq_done, 1'b1);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 INIT SEQUENCE TEST PASSED");
        else             $display("DDR3 INIT SEQUENCE TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT - the init sequence never completed");
        $finish;
    end
endmodule
