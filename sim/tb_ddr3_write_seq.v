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

    // Part 14: PRECHARGE-all after every transaction. The exact gap is what
    // the DUT commits to (one cycle of margin over the datasheet minimum,
    // see rtl/soc/ddr3_write_seq.v's own header); the minimum is the
    // datasheet's own number, WR + CWL(6) + BL/2(4) + tWR(4), so this test
    // fails both if the DUT drifts and if the DUT is ever set below the
    // real requirement.
    localparam [2:0] CMD_PRE = 3'b010;
    localparam WR_TO_PRE_GAP_CYC = 15;
    localparam WR_TO_PRE_MIN_CYC = 14;

    // Every command on the pins, timestamped on one global cycle counter,
    // so a gap can be measured across two transactions.
    integer gcyc = 0;
    integer pre_abs [0:3];
    integer act_abs [0:3];
    integer pre_n = 0, act_n = 0;
    reg     pre_busy_seen = 1'b0;    // busy was still high in the cycle PRECHARGE appeared
    reg     pre_a10_all = 1'b1;      // every PRECHARGE seen had A10 high
    always @(posedge clk) begin
        gcyc <= gcyc + 1;
        if (!rst && cmd_valid && cmd_cs_ras_cas_we == CMD_PRE) begin
            pre_abs[pre_n] = gcyc;
            pre_n = pre_n + 1;
            if (busy) pre_busy_seen = 1'b1;
            if (!cmd_addr[10]) pre_a10_all = 1'b0;
        end
        if (!rst && cmd_valid && cmd_cs_ras_cas_we == CMD_ACT) begin
            act_abs[act_n] = gcyc;
            act_n = act_n + 1;
        end
    end
    integer wr_abs0;
    integer pre_gap_meas, pre_to_act_meas;

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

        // PRECHARGE comes after write_start; wait for it, then for busy to drop.
        cyc = 0;
        while (pre_n < 1 && cyc < 60) begin @(posedge clk); cyc = cyc + 1; end
        check("a real PRECHARGE command was issued", (pre_n >= 1), 1'b1);
        check("PRECHARGE is PRECHARGE-all (A10 high)", pre_a10_all, 1'b1);
        check("busy was still high when PRECHARGE appeared (idle means banks closed)", pre_busy_seen, 1'b1);
        pre_gap_meas = pre_abs[0] - act_abs[0] - ((wr_cyc) - (act_cyc));
        $display("  real measured: WR -> PRECHARGE = %0d cycles", pre_gap_meas);
        check_int("WR->PRECHARGE gap matches the DUT's committed value exactly", pre_gap_meas, WR_TO_PRE_GAP_CYC);
        check("WR->PRECHARGE is no earlier than the datasheet minimum", (pre_gap_meas >= WR_TO_PRE_MIN_CYC), 1'b1);

        cyc = 0;
        while (busy && cyc < 40) begin @(posedge clk); cyc = cyc + 1; end
        check("busy deasserted again after the full sequence, PRECHARGE included", busy, 1'b0);
        check_int("exactly one PRECHARGE for the one transaction", pre_n, 1);

        // A second, back-to-back request proves the FSM really returns
        // to idle and can restart - not a one-shot fluke.
        bank = 3'd5; row = 16'h1234; col = 16'h03FF;
        @(posedge clk);
        write_req = 1'b1;
        @(posedge clk);
        write_req = 1'b0;
        cyc = 0;
        while (pre_n < 2 && cyc < 80) begin @(posedge clk); cyc = cyc + 1; end
        cyc = 0;
        while (busy && cyc < 40) begin @(posedge clk); cyc = cyc + 1; end
        check("busy idle again after a second, different request", busy, 1'b0);
        check_int("a second transaction issues its own PRECHARGE", pre_n, 2);

        // tRP (13.1-15 ns) is under one 40 ns cycle, and the FSM covers it
        // structurally rather than with a wait state: a caller cannot
        // present a request before busy drops, and the ACT follows after
        // that. Measured here as the smallest gap a caller can produce -
        // request presented in the cycle busy is first seen low.
        bank = 3'd6; row = 16'h0A0A;
        while (busy) @(posedge clk);
        write_req = 1'b1;
        @(posedge clk);
        write_req = 1'b0;
        cyc = 0;
        while (act_n < 3 && cyc < 20) begin @(posedge clk); cyc = cyc + 1; end
        pre_to_act_meas = act_abs[2] - pre_abs[1];
        $display("  real measured: PRECHARGE -> next ACTIVATE (fastest possible caller) = %0d cycles", pre_to_act_meas);
        check("PRECHARGE -> next ACTIVATE is at least one cycle (tRP is 15 ns or less)", (pre_to_act_meas >= 1), 1'b1);
        repeat (40) @(posedge clk);

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
