// Self-test for the per-bank rules added to sim/ddr3_model.v in Phase 9
// Stage 1, Part 14 (docs/roadmap.md). The model is test infrastructure;
// a checker whose rules cannot be shown to fire is not a checker, and two
// of these rules cannot be triggered by the real design at all (a design
// that follows them never breaks them), so they need their own directed
// proof. Same "a testbench that can fail" discipline every other piece of
// this project is held to.
//
// Twelve independent model instances share one real init sequence (the same
// ddr3_init_seq.v + ddr3_phy_ecp5.v that tb_ddr3_init.v uses) and then each
// gets its own directed command stream on its own pins:
//   - two LEGAL controls, one of them at the exact minimum spacings, so a
//     rule that is too strict fails here rather than silently rejecting a
//     correct controller
//   - one stream per rule, each expected to trip exactly that rule and no
//     other, identified by the model's own message
// Every spacing below is in CK cycles between two sampled commands (since
// Part 16 the model samples on CK's rising edge), from the datasheet's own
// numbers (Micron 4Gb DDR3L, notes 33/34, the tRTP row and the tRAS row),
// not from the model's own constants, so this test does not just agree
// with the model by construction. Commands are set at CK's falling edge and
// cleared at the next, so each is sampled at exactly one rising edge.
`timescale 1ns/1ps
module tb_ddr3_model_banks;
    localparam CLK_HZ     = 25_000_000;
    localparam CLK_PERIOD = 40;   // 25 MHz
    localparam N          = 12;

    // Datasheet minimums, in CK: WRITE->PRECHARGE = CWL(6) + BL/2(4) + tWR(4),
    // READ->PRECHARGE = tRTP(4), ACTIVATE->PRECHARGE = tRAS (37.5 ns worst
    // bin = 2 CK at 20 ns per CK).
    localparam WR_TO_PRE  = 14;
    localparam RD_TO_PRE  = 4;
    localparam ACT_TO_PRE = 2;
    // REFRESH -> next command: tRFC 260 ns for this 4Gb part = 13 CK at 20 ns.
    localparam REF_TO_CMD = 13;

    localparam K_ACT = 0, K_WR = 1, K_RD = 2, K_PRE = 3, K_REF = 4;

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    // ---- the one real init sequence every instance sees ----
    wire        cmd_valid;
    wire [2:0]  cmd_cs_ras_cas_we, cmd_ba;
    wire [15:0] cmd_addr;
    wire        cmd_cke, cmd_reset_n, cmd_odt, ready;

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

    // ---- per-instance command pins, taking over once init is done ----
    reg               tb_live = 1'b0;
    reg [N-1:0]       tb_cs_n  = {N{1'b1}};
    reg [N-1:0]       tb_ras_n = {N{1'b1}};
    reg [N-1:0]       tb_cas_n = {N{1'b1}};
    reg [N-1:0]       tb_we_n  = {N{1'b1}};
    reg [3*N-1:0]     tb_ba    = {3*N{1'b0}};
    reg [16*N-1:0]    tb_a     = {16*N{1'b0}};

    wire [N-1:0]      errs;
    wire [512*N-1:0]  msgs;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : M
            wire        e;
            wire [511:0] m;
            ddr3_model #(.CLK_HZ(CLK_HZ)) MODEL (
                .ck(ddr3_ck),
                .cs_n (tb_live ? tb_cs_n[g]  : ddr3_cs_n),
                .ras_n(tb_live ? tb_ras_n[g] : ddr3_ras_n),
                .cas_n(tb_live ? tb_cas_n[g] : ddr3_cas_n),
                .we_n (tb_live ? tb_we_n[g]  : ddr3_we_n),
                .ba   (tb_live ? tb_ba[3*g +: 3]   : ddr3_ba),
                .a    (tb_live ? tb_a[16*g +: 16]  : ddr3_a),
                .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
                .error(e), .error_msg(m), .seq_done()
            );
            assign errs[g] = e;
            assign msgs[512*g +: 512] = m;
        end
    endgenerate

    // Drive one command on instance i for exactly one sampled cycle. The
    // task returns on the edge the model samples it, so the next issue's
    // assignments land for the following edge (spacing 1); `next` inserts
    // spacing-1 idle edges first.
    task issue(input integer i, input integer kind, input [2:0] bank, input [15:0] addr);
        begin
            tb_cs_n[i] <= 1'b0;
            case (kind)
                K_ACT: begin tb_ras_n[i] <= 1'b0; tb_cas_n[i] <= 1'b1; tb_we_n[i] <= 1'b1; end
                K_WR:  begin tb_ras_n[i] <= 1'b1; tb_cas_n[i] <= 1'b0; tb_we_n[i] <= 1'b0; end
                K_RD:  begin tb_ras_n[i] <= 1'b1; tb_cas_n[i] <= 1'b0; tb_we_n[i] <= 1'b1; end
                K_PRE: begin tb_ras_n[i] <= 1'b0; tb_cas_n[i] <= 1'b1; tb_we_n[i] <= 1'b0; end
                K_REF: begin tb_ras_n[i] <= 1'b0; tb_cas_n[i] <= 1'b0; tb_we_n[i] <= 1'b1; end
            endcase
            tb_ba[3*i +: 3]   <= bank;
            tb_a[16*i +: 16]  <= addr;
            @(negedge ddr3_ck);
            tb_cs_n[i]  <= 1'b1;
            tb_ras_n[i] <= 1'b1; tb_cas_n[i] <= 1'b1; tb_we_n[i] <= 1'b1;
        end
    endtask

    task next(input integer i, input integer spacing, input integer kind,
              input [2:0] bank, input [15:0] addr);
        begin
            if (spacing > 1) repeat (spacing - 1) @(negedge ddr3_ck);
            issue(i, kind, bank, addr);
        end
    endtask

    localparam [15:0] A10 = 16'h0400;   // PRECHARGE: A10 high = all banks
    localparam [15:0] NO  = 16'h0000;

    integer errors = 0;
    task expect_legal(input integer i, input [511:0] what);
        begin
            if (errs[i]) begin
                $display("  FAIL %0s: model rejected a legal stream: %0s", what, msgs[512*i +: 512]);
                errors = errors + 1;
            end else
                $display("  ok   %0s", what);
        end
    endtask
    task expect_msg(input integer i, input [511:0] what, input [511:0] msg);
        begin
            if (!errs[i]) begin
                $display("  FAIL %0s: model did NOT flag the violation", what);
                errors = errors + 1;
            end else if (msgs[512*i +: 512] !== msg) begin
                $display("  FAIL %0s: wrong rule fired: %0s", what, msgs[512*i +: 512]);
                errors = errors + 1;
            end else
                $display("  ok   %0s", what);
        end
    endtask

    initial begin
        $display("=== DDR3 model bank-state rules, self-test (Phase 9 Stage 1, Part 14) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!ready) @(posedge clk);
        repeat (700) @(posedge clk);   // clear of the model's own post-ZQCL wait
        tb_live = 1'b1;
        @(negedge ddr3_ck);

        // 0: legal, at the exact datasheet minimums
        issue(0, K_ACT, 3'd1, 16'h0123);
        next (0,  3, K_WR,  3'd1, NO);
        next (0, WR_TO_PRE, K_PRE, 3'd0, A10);      // PRECHARGE-all exactly at the minimum
        next (0,  1, K_ACT, 3'd1, 16'h0123);        // reopen right after
        next (0,  3, K_RD,  3'd1, NO);
        next (0, RD_TO_PRE, K_PRE, 3'd1, NO);       // single-bank PRECHARGE exactly at tRTP
        next (0,  1, K_PRE, 3'd1, NO);              // to an already-idle bank: a NOP, legal
        next (0,  1, K_REF, 3'd0, NO);
        next (0, REF_TO_CMD, K_ACT, 3'd2, 16'h0044); // exactly tRFC after the REFRESH
        next (0, ACT_TO_PRE, K_PRE, 3'd2, NO);      // ACTIVATE->PRECHARGE exactly at tRAS

        // 1: legal, several banks open at once, closed by PRECHARGE-all and
        // by per-bank PRECHARGEs, each followed by a REFRESH
        issue(1, K_ACT, 3'd1, 16'h0010);
        next (1,  2, K_ACT, 3'd2, 16'h0020);
        next (1,  2, K_ACT, 3'd5, 16'h0030);
        next (1,  2, K_PRE, 3'd0, A10);
        next (1,  2, K_REF, 3'd0, NO);
        next (1, REF_TO_CMD, K_ACT, 3'd3, 16'h0040);
        next (1,  2, K_ACT, 3'd4, 16'h0050);
        next (1,  2, K_PRE, 3'd3, NO);
        next (1,  2, K_PRE, 3'd4, NO);
        next (1,  2, K_REF, 3'd0, NO);

        // 2: ACTIVATE to a bank already open, same row (Part 9's own
        // write-then-read round trip did exactly this)
        issue(2, K_ACT, 3'd1, 16'h0010);
        next (2,  5, K_ACT, 3'd1, 16'h0010);

        // 3: READ to a bank never opened
        issue(3, K_RD, 3'd1, NO);

        // 4: PRECHARGE one cycle short of write recovery
        issue(4, K_ACT, 3'd1, 16'h0010);
        next (4,  3, K_WR,  3'd1, NO);
        next (4, WR_TO_PRE - 1, K_PRE, 3'd0, A10);

        // 5: PRECHARGE one cycle short of tRTP
        issue(5, K_ACT, 3'd1, 16'h0010);
        next (5,  3, K_RD,  3'd1, NO);
        next (5, RD_TO_PRE - 1, K_PRE, 3'd1, NO);

        // 6: REFRESH with a bank open
        issue(6, K_ACT, 3'd1, 16'h0010);
        next (6,  5, K_REF, 3'd0, NO);

        // 7: REFRESH after a single-bank PRECHARGE while a different bank
        // is still open - also proves A10 low closes only its own bank
        issue(7, K_ACT, 3'd1, 16'h0010);
        next (7,  2, K_ACT, 3'd2, 16'h0020);
        next (7,  2, K_PRE, 3'd1, NO);
        next (7,  2, K_REF, 3'd0, NO);

        // 8: READ to a bank that was open but has been precharged
        issue(8, K_ACT, 3'd1, 16'h0010);
        next (8,  2, K_PRE, 3'd1, NO);
        next (8,  3, K_RD,  3'd1, NO);

        // 9: ACTIVATE of a DIFFERENT row in a bank already open - the case
        // the datasheet states outright ("A PRECHARGE command must be
        // issued before opening a different row in the same bank")
        issue(9, K_ACT, 3'd1, 16'h0010);
        next (9,  5, K_ACT, 3'd1, 16'h0011);

        // 10: PRECHARGE one CK after ACTIVATE - short of tRAS (2 CK)
        issue(10, K_ACT, 3'd1, 16'h0010);
        next (10, ACT_TO_PRE - 1, K_PRE, 3'd1, NO);

        // 11: a command one CK short of tRFC after a REFRESH
        issue(11, K_REF, 3'd0, NO);
        next (11, REF_TO_CMD - 1, K_ACT, 3'd1, 16'h0010);

        repeat (30) @(posedge clk);

        expect_legal(0, "legal stream at the exact minimum spacings is accepted");
        expect_legal(1, "legal multi-bank stream, PRECHARGE-all and per-bank, is accepted");
        expect_msg(2, "ACTIVATE to an open bank (same row) is rejected",
                   "ACTIVATE to a bank that is already open (no PRECHARGE first)");
        expect_msg(3, "READ to a bank that was never opened is rejected",
                   "READ or WRITE to a bank that is not open");
        expect_msg(4, "PRECHARGE one cycle before write recovery is rejected",
                   "PRECHARGE before write recovery elapsed after WRITE");
        expect_msg(5, "PRECHARGE one cycle before tRTP is rejected",
                   "PRECHARGE before tRTP elapsed after READ");
        expect_msg(6, "REFRESH with a bank open is rejected",
                   "REFRESH with a bank still open (all banks must be precharged)");
        expect_msg(7, "REFRESH with a second bank still open is rejected",
                   "REFRESH with a bank still open (all banks must be precharged)");
        expect_msg(8, "READ to a bank closed by PRECHARGE is rejected",
                   "READ or WRITE to a bank that is not open");
        expect_msg(9, "ACTIVATE of a different row in an open bank is rejected",
                   "ACTIVATE to a bank that is already open (no PRECHARGE first)");
        expect_msg(10, "PRECHARGE one CK after ACTIVATE (short of tRAS) is rejected",
                   "PRECHARGE before tRAS elapsed after ACTIVATE");
        expect_msg(11, "a command one CK short of tRFC after REFRESH is rejected",
                   "command issued during tRFC after REFRESH (only NOP/DES allowed)");

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 MODEL BANK RULES TEST PASSED");
        else             $display("DDR3 MODEL BANK RULES TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #4_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
