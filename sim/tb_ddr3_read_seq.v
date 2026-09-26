// Directed test for Phase 9 Stage 1, Part 7 (docs/roadmap.md):
// rtl/soc/ddr3_read_seq.v's own real ACT->RD->read_start command
// sequencing, measured directly cycle-by-cycle rather than assumed
// identical to rtl/soc/ddr3_write_seq.v's own already-measured
// behavior just because the FSM shape matches - this project's own
// "measure, don't assume" discipline applies just as much to a
// same-shaped sibling module as to a first draft.
`timescale 1ns/1ps
module tb_ddr3_read_seq;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg rst = 1'b1;
    reg read_req = 1'b0;
    reg [2:0]  bank = 3'd3;
    reg [15:0] row  = 16'h5A5A;
    reg [15:0] col  = 16'h0640;   // bit 10 deliberately set - proves the DUT clears it, not the caller

    wire        busy;
    wire        cmd_valid;
    wire [2:0]  cmd_cs_ras_cas_we;
    wire [2:0]  cmd_ba;
    wire [15:0] cmd_addr;
    wire        read_start;

    ddr3_read_seq DUT (
        .clk(clk), .rst(rst),
        .read_req(read_req), .bank(bank), .row(row), .col(col),
        .busy(busy),
        .cmd_valid(cmd_valid), .cmd_cs_ras_cas_we(cmd_cs_ras_cas_we),
        .cmd_ba(cmd_ba), .cmd_addr(cmd_addr),
        .read_start(read_start)
    );

    localparam [2:0] CMD_ACT = 3'b011;
    localparam [2:0] CMD_RD  = 3'b101;

    // The exact real gaps rtl/soc/ddr3_read_seq.v's own TRCD_CYC/CL_CYC
    // commit to - duplicated here deliberately (a hierarchical
    // reference into the DUT's own localparams is not a legal constant
    // expression in this toolchain, confirmed the same way
    // sim/tb_ddr3_write_seq.v's own header already found), so a real
    // change to either constant in the DUT is expected to require
    // updating this line too, not silently drift out of sync.
    localparam ACT_TO_RD_GAP_CYC = 3;         // TRCD_CYC(2)+1 - see rtl/soc/ddr3_read_seq.v's own header for why +1
    localparam RD_TO_READ_START_GAP_CYC = 3;  // CL_CYC exactly: CL = 6 CK = 3 sclk (Part 16: CK is twice sclk)

    // Part 14: PRECHARGE-all after every transaction. The exact gap is what
    // the DUT commits to (the burst end plus one sclk of margin, see
    // rtl/soc/ddr3_read_seq.v's own header); the minimum is the datasheet's
    // own number, tRTP = 4 CK, which is 2 sclk (Part 16). The DUT is
    // deliberately well above it, so a design margin and not a datasheet
    // requirement is what the exact-gap check pins.
    localparam [2:0] CMD_PRE = 3'b010;
    localparam RD_TO_PRE_GAP_CYC = 6;
    localparam RD_TO_PRE_MIN_CYC = 2;

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
    integer rd_abs0;
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

    integer cyc;
    integer act_cyc, rd_cyc, read_start_cyc;
    reg [2:0] act_ba_seen, rd_ba_seen;
    reg [15:0] act_addr_seen, rd_addr_seen;

    initial begin
        $display("=== DDR3 read command sequencer (Phase 9 Stage 1, Part 7) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        check("idle before any request", busy, 1'b0);
        check("no command asserted while idle", cmd_valid, 1'b0);

        @(posedge clk);
        read_req = 1'b1;
        @(posedge clk);
        read_req = 1'b0;

        cyc = 0;
        act_cyc = -1; rd_cyc = -1; read_start_cyc = -1;

        while ((act_cyc < 0 || rd_cyc < 0 || read_start_cyc < 0) && cyc < 40) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (cmd_valid && cmd_cs_ras_cas_we == CMD_ACT && act_cyc < 0) begin
                act_cyc = cyc;
                act_ba_seen   = cmd_ba;
                act_addr_seen = cmd_addr;
            end
            if (cmd_valid && cmd_cs_ras_cas_we == CMD_RD && rd_cyc < 0) begin
                rd_cyc = cyc;
                rd_ba_seen   = cmd_ba;
                rd_addr_seen = cmd_addr;
            end
            if (read_start && read_start_cyc < 0) read_start_cyc = cyc;
        end

        $display("  real measured: ACT at cycle %0d, RD at cycle %0d, read_start at cycle %0d",
                  act_cyc, rd_cyc, read_start_cyc);
        $display("  real measured gaps: ACT->RD = %0d cycles, RD->read_start = %0d cycles",
                  rd_cyc - act_cyc, read_start_cyc - rd_cyc);

        check("a real ACT command was issued", (act_cyc > 0), 1'b1);
        check("a real RD command was issued", (rd_cyc > 0), 1'b1);
        check("read_start eventually pulsed", (read_start_cyc > 0), 1'b1);
        check("ACT carried the real requested bank", act_ba_seen, bank);
        check("ACT carried the real requested row", act_addr_seen, row);
        check("RD carried the real requested bank", rd_ba_seen, bank);
        check("RD's own A10 (auto-precharge) was forced low", rd_addr_seen[10], 1'b0);
        check("RD carried the real requested column otherwise unchanged",
              (rd_addr_seen == {col[15:11], 1'b0, col[9:0]}), 1'b1);
        check("RD happened strictly after ACT, not concurrently", (rd_cyc > act_cyc), 1'b1);
        check("read_start happened strictly after RD", (read_start_cyc > rd_cyc), 1'b1);
        check_int("ACT->RD gap matches the real, measured value", rd_cyc - act_cyc, ACT_TO_RD_GAP_CYC);
        check_int("RD->read_start gap matches real CL exactly", read_start_cyc - rd_cyc, RD_TO_READ_START_GAP_CYC);
        check("no stray command during the ACT->RD wait", stray_cmd_seen, 1'b0);

        // PRECHARGE comes after read_start; wait for it, then for busy to drop.
        cyc = 0;
        while (pre_n < 1 && cyc < 60) begin @(posedge clk); cyc = cyc + 1; end
        check("a real PRECHARGE command was issued", (pre_n >= 1), 1'b1);
        check("PRECHARGE is PRECHARGE-all (A10 high)", pre_a10_all, 1'b1);
        check("busy was still high when PRECHARGE appeared (idle means banks closed)", pre_busy_seen, 1'b1);
        pre_gap_meas = pre_abs[0] - act_abs[0] - ((rd_cyc) - (act_cyc));
        $display("  real measured: RD -> PRECHARGE = %0d cycles", pre_gap_meas);
        check_int("RD->PRECHARGE gap matches the DUT's committed value exactly", pre_gap_meas, RD_TO_PRE_GAP_CYC);
        check("RD->PRECHARGE is no earlier than the datasheet minimum", (pre_gap_meas >= RD_TO_PRE_MIN_CYC), 1'b1);

        cyc = 0;
        while (busy && cyc < 40) begin @(posedge clk); cyc = cyc + 1; end
        check("busy deasserted again after the full sequence, PRECHARGE included", busy, 1'b0);
        check_int("exactly one PRECHARGE for the one transaction", pre_n, 1);

        // A second, back-to-back request proves the FSM really returns
        // to idle and can restart - not a one-shot fluke.
        bank = 3'd1; row = 16'h0F0F; col = 16'h0201;
        @(posedge clk);
        read_req = 1'b1;
        @(posedge clk);
        read_req = 1'b0;
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
        read_req = 1'b1;
        @(posedge clk);
        read_req = 1'b0;
        cyc = 0;
        while (act_n < 3 && cyc < 20) begin @(posedge clk); cyc = cyc + 1; end
        pre_to_act_meas = act_abs[2] - pre_abs[1];
        $display("  real measured: PRECHARGE -> next ACTIVATE (fastest possible caller) = %0d cycles", pre_to_act_meas);
        check("PRECHARGE -> next ACTIVATE is at least one cycle (tRP is 15 ns or less)", (pre_to_act_meas >= 1), 1'b1);
        repeat (40) @(posedge clk);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 READ SEQUENCER TEST PASSED");
        else             $display("DDR3 READ SEQUENCER TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    // A real, live monitor: once a real ACT has been seen and before
    // the real RD that closes it out arrives, no OTHER live command
    // should appear - a real DDR3 part must see NOP during the tRCD
    // wait, not another command. Watches every cycle of the whole run.
    reg act_pending = 1'b0;
    reg stray_cmd_seen = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            act_pending    <= 1'b0;
            stray_cmd_seen <= 1'b0;
        end else begin
            if (cmd_valid && cmd_cs_ras_cas_we == CMD_ACT) begin
                act_pending <= 1'b1;
            end else if (cmd_valid && cmd_cs_ras_cas_we == CMD_RD) begin
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
