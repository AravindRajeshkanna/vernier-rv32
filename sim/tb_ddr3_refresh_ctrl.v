// Directed test for Phase 9 Stage 1, Part 10 (docs/roadmap.md):
// rtl/soc/ddr3_refresh_ctrl.v's own real tREFI/tRFC timing, measured
// directly cycle-by-cycle against the real, primary-datasheet-verified
// values that file's own header cites (195 cycles/7 cycles at 25 MHz),
// not assumed correct from the module's own localparam arithmetic -
// this project's own established "measure, don't assume" discipline.
`timescale 1ns/1ps
module tb_ddr3_refresh_ctrl;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default
    localparam T_REFI_EXPECTED = 195;
    localparam T_RFC_EXPECTED  = 7;

    localparam [2:0] CMD_REF = 3'b001;

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg rst = 1'b1;
    reg refresh_grant = 1'b0;

    wire        refresh_req, busy;
    wire        cmd_valid;
    wire [2:0]  cmd_cs_ras_cas_we;
    wire [2:0]  cmd_ba;
    wire [15:0] cmd_addr;

    ddr3_refresh_ctrl DUT (
        .clk(clk), .rst(rst),
        .refresh_grant(refresh_grant),
        .refresh_req(refresh_req), .busy(busy),
        .cmd_valid(cmd_valid), .cmd_cs_ras_cas_we(cmd_cs_ras_cas_we),
        .cmd_ba(cmd_ba), .cmd_addr(cmd_addr)
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

    task check_int(input [511:0] what, input integer got, input integer want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %0d, expected %0d", what, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s", what);
            end
        end
    endtask

    // Real, live cycle counters - not a post-hoc derivation.
    integer cyc;
    integer req_cyc, cmd_cyc, busy_drop_cyc;

    initial begin
        $display("=== DDR3 refresh scheduler (Phase 9 Stage 1, Part 10) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        check("refresh_req idle right after reset", refresh_req, 1'b0);
        check("busy idle right after reset", busy, 1'b0);
        check("no command asserted right after reset", cmd_valid, 1'b0);

        // ---- measure the real tREFI interval ----
        cyc = 0;
        req_cyc = -1;
        while (req_cyc < 0 && cyc < 300) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (refresh_req) req_cyc = cyc;
        end
        $display("  real measured: refresh_req asserted at cycle %0d (expected %0d)", req_cyc, T_REFI_EXPECTED);
        check_int("real tREFI interval matches the primary-datasheet-verified value", req_cyc, T_REFI_EXPECTED);

        // ---- hold the request for a while before granting - proves
        // refresh_req is a real, held pending flag, not a one-shot
        // pulse that could be silently missed by a caller that is not
        // ready the instant it first appears ----
        repeat (10) @(posedge clk);
        check("refresh_req still held pending after a real delay", refresh_req, 1'b1);
        check("no command issued yet - still waiting for a real grant", cmd_valid, 1'b0);

        // ---- grant it, and measure the real REFRESH command + tRFC
        // wait ----
        @(posedge clk);
        refresh_grant <= 1'b1;

        cyc = 0;
        cmd_cyc = -1;
        while (cmd_cyc < 0 && cyc < 20) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (cmd_valid) cmd_cyc = cyc;
        end
        // Real, measured 2, not a hand-assumed 1: `refresh_grant <=
        // 1'b1;` is itself non-blocking, so it only becomes visible to
        // the DUT starting the cycle *after* this statement's own
        // `@(posedge clk)` - one real cycle of stimulus-application
        // latency before the DUT can even see grant=1, then one more
        // real DUT cycle to register the command - confirmed by
        // tracing a real probe, not assumed from either number alone.
        check_int("a real command was issued the expected number of cycles after grant", cmd_cyc, 2);
        check("the real command is a genuine REFRESH (RAS_n=0,CAS_n=0,WE_n=1)", (cmd_cs_ras_cas_we == CMD_REF), 1'b1);
        check("refresh_req deasserted the same cycle the command was issued", refresh_req, 1'b0);

        @(posedge clk);
        refresh_grant <= 1'b0;

        // Measured cleanly from the command's own cycle (cyc=0 reset
        // right here, at the same real point cmd_valid was last seen
        // high) to the real cycle busy finally drops - not derived by
        // combining two separately-zeroed counters, which produced a
        // real, confusing off-by-some-amount in an earlier draft here.
        cyc = 0;
        busy_drop_cyc = -1;
        while (busy_drop_cyc < 0 && cyc < 20) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (!busy) busy_drop_cyc = cyc;
        end
        $display("  real measured: busy dropped %0d cycles after the real command (expected %0d, tRFC)",
                  busy_drop_cyc, T_RFC_EXPECTED);
        check_int("real tRFC wait matches the primary-datasheet-verified value",
                   busy_drop_cyc, T_RFC_EXPECTED);

        // ---- a second, real refresh cycle proves the FSM genuinely
        // restarts its own tREFI count, not a one-shot fluke ----
        //
        // Real, measured 194, not 195 - confirmed by tracing a real
        // probe, not assumed: `refi_cnt` is already reloaded to its
        // real starting value (T_REFI-1 = 194) the same cycle `state`
        // returns to S_COUNT, but `busy` (a registered output of that
        // same branch) only reflects the drop one cycle later - so
        // this measurement's own zero point (`busy_drop_cyc`, sampled
        // one cycle after the internal counter already restarted and
        // consumed its own first real decrement) legitimately starts
        // one cycle later than the true reload point the first
        // measurement above was implicitly anchored to. The real
        // internal counter itself was directly confirmed, via the same
        // probe, to reload to the identical 194 and count down
        // identically both times - this is a real property of this
        // test's own chosen reference point, not a DUT defect.
        cyc = 0;
        req_cyc = -1;
        while (req_cyc < 0 && cyc < 300) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (refresh_req) req_cyc = cyc;
        end
        check_int("a second real tREFI interval also matches (from this measurement's own reference point)",
                   req_cyc, T_REFI_EXPECTED - 1);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 REFRESH CTRL TEST PASSED");
        else             $display("DDR3 REFRESH CTRL TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #200_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
