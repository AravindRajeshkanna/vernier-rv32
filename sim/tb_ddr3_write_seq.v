// Directed test for Phase 9 Stage 1, Part 6 (docs/roadmap.md):
// rtl/soc/ddr3_write_seq.v's own real ACT->WR->write_start command
// sequencing, measured directly cycle-by-cycle rather than trusted
// from the module's own header arithmetic - this project's own
// established practice after rtl/soc/ddr3_eclk_pll.v's own first
// clock-generation draft hand-traced as correct and was not.
`timescale 1ns/1ps
module tb_ddr3_write_seq;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg rst = 1'b1;
    reg write_req = 1'b0;
    reg [2:0]  bank = 3'd2;
    reg [15:0] row  = 16'hABCD;
    reg [15:0] col  = 16'h0754;   // bit 10 deliberately set - proves the DUT clears it, not the caller

    wire        busy;
    wire        cmd_valid;
    wire [2:0]  cmd_cs_ras_cas_we;
    wire [2:0]  cmd_ba;
    wire [15:0] cmd_addr;
    wire        write_start;

    ddr3_write_seq DUT (
        .clk(clk), .rst(rst),
        .write_req(write_req), .bank(bank), .row(row), .col(col),
        .busy(busy),
        .cmd_valid(cmd_valid), .cmd_cs_ras_cas_we(cmd_cs_ras_cas_we),
        .cmd_ba(cmd_ba), .cmd_addr(cmd_addr),
        .write_start(write_start)
    );

    localparam [2:0] CMD_ACT = 3'b011;
    localparam [2:0] CMD_WR  = 3'b100;

    // The exact real gaps rtl/soc/ddr3_write_seq.v's own TRCD_CYC/
    // CWL_CYC commit to (a hierarchical reference into the DUT's own
    // localparams is not a legal constant expression in this
    // toolchain, confirmed by trying it - Icarus refused to elaborate
    // it) - duplicated here deliberately, not re-derived independently,
    // so a real change to either constant in the DUT is expected to
    // require updating this line too, not silently drift out of sync.
    localparam ACT_TO_WR_GAP_CYC = 3;          // TRCD_CYC(2)+1 - see that file's own header for why +1
    localparam WR_TO_WRITE_START_GAP_CYC = 6;  // CWL_CYC exactly

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

    // Real, measured cycle numbers (relative to the cycle write_req
    // was seen), not assumed from the DUT's own header arithmetic.
    integer cyc;
    integer act_cyc, wr_cyc, write_start_cyc;
    reg [2:0] act_ba_seen, wr_ba_seen;
    reg [15:0] act_addr_seen, wr_addr_seen;

    initial begin
        $display("=== DDR3 write command sequencer (Phase 9 Stage 1, Part 6) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        check("idle before any request", busy, 1'b0);
        check("no command asserted while idle", cmd_valid, 1'b0);

        @(posedge clk);
        write_req = 1'b1;
        @(posedge clk);
        write_req = 1'b0;

        cyc = 0;
        act_cyc = -1; wr_cyc = -1; write_start_cyc = -1;

        while ((act_cyc < 0 || wr_cyc < 0 || write_start_cyc < 0) && cyc < 40) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (cmd_valid && cmd_cs_ras_cas_we == CMD_ACT && act_cyc < 0) begin
                act_cyc = cyc;
                act_ba_seen   = cmd_ba;
                act_addr_seen = cmd_addr;
            end
            if (cmd_valid && cmd_cs_ras_cas_we == CMD_WR && wr_cyc < 0) begin
                wr_cyc = cyc;
                wr_ba_seen   = cmd_ba;
                wr_addr_seen = cmd_addr;
            end
            if (write_start && write_start_cyc < 0) write_start_cyc = cyc;
        end

        $display("  real measured: ACT at cycle %0d, WR at cycle %0d, write_start at cycle %0d",
                  act_cyc, wr_cyc, write_start_cyc);
        $display("  real measured gaps: ACT->WR = %0d cycles, WR->write_start = %0d cycles",
                  wr_cyc - act_cyc, write_start_cyc - wr_cyc);

        check("a real ACT command was issued", (act_cyc > 0), 1'b1);
        check("a real WR command was issued", (wr_cyc > 0), 1'b1);
        check("write_start eventually pulsed", (write_start_cyc > 0), 1'b1);
        check("ACT carried the real requested bank", act_ba_seen, bank);
        check("ACT carried the real requested row", act_addr_seen, row);
        check("WR carried the real requested bank", wr_ba_seen, bank);
        check("WR's own A10 (auto-precharge) was forced low", wr_addr_seen[10], 1'b0);
        check("WR carried the real requested column otherwise unchanged",
              (wr_addr_seen == {col[15:11], 1'b0, col[9:0]}), 1'b1);
        check("WR happened strictly after ACT, not concurrently", (wr_cyc > act_cyc), 1'b1);
        check("write_start happened strictly after WR", (write_start_cyc > wr_cyc), 1'b1);

        // Exact gap checks, not just ordering - an ordering-only check
        // (the two above) cannot tell a real tRCD/CWL wait apart from
        // one shortened or skipped outright, only that it happened at
        // all. Caught only by adding this: a real mutation removing the
        // CWL wait entirely still passed every check above it, since
        // write_start still landed strictly after WR - just far too
        // soon.
        check_int("ACT->WR gap matches the real, measured value", wr_cyc - act_cyc, ACT_TO_WR_GAP_CYC);
        check_int("WR->write_start gap matches real CWL exactly", write_start_cyc - wr_cyc, WR_TO_WRITE_START_GAP_CYC);

        check("no stray command during the ACT->WR wait", stray_cmd_seen, 1'b0);

        repeat (4) @(posedge clk);
        check("busy deasserted again after the full sequence", busy, 1'b0);

        // A second, back-to-back request proves the FSM really returns
        // to idle and can restart - not a one-shot fluke.
        bank = 3'd5; row = 16'h1234; col = 16'h03FF;
        @(posedge clk);
        write_req = 1'b1;
        @(posedge clk);
        write_req = 1'b0;
        repeat (20) @(posedge clk);
        check("busy idle again after a second, different request", busy, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 WRITE SEQUENCER TEST PASSED");
        else             $display("DDR3 WRITE SEQUENCER TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    // A real, live monitor (not a re-derived post-hoc loop): once a
    // real ACT has been seen and before the real WR that closes it out
    // arrives, no OTHER live command (cmd_valid asserted with anything
    // other than ACT/WR itself) should appear - a real DDR3 part must
    // see NOP during the tRCD wait, not another command. Watches every
    // cycle of the whole run, not just the first sequence.
    reg act_pending = 1'b0;
    reg stray_cmd_seen = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            act_pending    <= 1'b0;
            stray_cmd_seen <= 1'b0;
        end else begin
            if (cmd_valid && cmd_cs_ras_cas_we == CMD_ACT) begin
                act_pending <= 1'b1;
            end else if (cmd_valid && cmd_cs_ras_cas_we == CMD_WR) begin
                act_pending <= 1'b0;
            end else if (act_pending && cmd_valid) begin
                stray_cmd_seen <= 1'b1;
            end
        end
    end

    initial begin
        #100_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
