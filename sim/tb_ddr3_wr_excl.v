// Integrated test for Phase 9 Stage 1, Part 13 (docs/roadmap.md): at most
// one DDR3 transaction in flight. Part 12's own probe found that a
// write_req and read_req presented together run in lockstep - the command
// mux's fixed priority lets the write's ACT/WR reach the pins, the read's
// never do, yet its read_start still pulses and read_data comes back `z`,
// with the protocol checker silent because the pins look legal.
//
// The property under test is about acceptance, not timing: every request
// is either fully accepted (its ACT and its WR/RD both reach the pins, it
// completes, the data is right) or fully ignored (it leaves no trace).
// Never half-way. Stated as counts against the real command pins, which
// no internal signal can fake:
//     ACT on pins == accepted writes + accepted reads
//     PRE on pins == accepted writes + accepted reads (Part 14: every
//                    transaction ends by closing its bank)
//     WR  on pins == accepted writes,   RD on pins == accepted reads
//     completions and read_data_valid pulses == acceptances
// plus two global invariants - both sequencers never busy together, and
// never both driving a command at once.
//
// Swept, not sampled: a second request is presented at every offset d
// from the first (d = 0, the same cycle, through well past completion),
// for all four pairs (W->W, W->R, R->W, R->R), as a blind caller (ignores
// busy) and as a polite one (a single caller that waits for busy to rise
// and fall before presenting). A polite second request must never be
// dropped. Rounds are anchored on refresh_busy falling and run in the
// quiet stretch before the next refresh is due, so they do not interact
// with Part 12's refresh hold.
`timescale 1ns/1ps
module tb_ddr3_wr_excl;
    localparam CLK_HZ     = 25_000_000;
    localparam CLK_PERIOD = 40;   // 25 MHz
    localparam D_MAX      = 30;   // offsets swept; a transaction is ~18-22 cycles (with its PRECHARGE)

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

    reg         write_req = 1'b0;
    reg  [2:0]  write_bank = 3'd1;
    reg  [15:0] write_row  = 16'h0001;
    reg  [15:0] write_col  = 16'h0001;
    reg  [7:0]  write_data = 8'hC3;
    wire        write_busy;

    reg         read_req = 1'b0;
    reg  [2:0]  read_bank = 3'd1;
    reg  [15:0] read_row  = 16'h0001;
    reg  [15:0] read_col  = 16'h0001;
    wire        read_busy;
    wire [7:0]  read_data;
    wire        read_data_valid;
    wire        refresh_busy;

    ddr3_ecp5_top DUT (
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs),
        .write_req(write_req), .write_bank(write_bank), .write_row(write_row),
        .write_col(write_col), .write_data(write_data), .write_busy(write_busy),
        .read_req(read_req), .read_bank(read_bank), .read_row(read_row), .read_col(read_col),
        .read_busy(read_busy), .read_data(read_data), .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked),
        .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

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

    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_o;

    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .wr_d0(DUT.wr_data_final), .wr_en(DUT.write_start_final),
        .read_active(DUT.read_active_final),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_o(mem_dqs_o)
    );

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = mem_dq_oe ? mem_dqs_o : 1'bz;

    // ---- monitors, all on the DUT's own sclk ----
    // Pin-level command counts. Decoded from the real DDR3 pins with the
    // same {ras_n,cas_n,we_n} convention the model uses, so an accepted
    // transaction whose command never reached the pins shows up here as a
    // missing count, whatever the sequencers themselves believe.
    integer act_pins = 0, wr_pins = 0, rd_pins = 0, pre_pins = 0;
    // "Accepted" is read off the sequencer's own state, not its busy
    // flag: a request presented in the one cycle a sequencer is back in
    // S_IDLE but its busy has not yet dropped is accepted by the
    // sequencer even though busy still reads high.
    integer w_acc = 0, r_acc = 0, w_done = 0, r_done = 0, r_valid = 0;
    integer w_ign = 0, r_ign = 0;
    reg [7:0] r_log [0:4095];
    reg both_busy_seen = 1'b0;
    reg cmd_contention_seen = 1'b0;

    wire w_accept_now = DUT.wseq_write_req && (DUT.WSEQ.state == 3'd0);
    wire r_accept_now = DUT.rseq_read_req  && (DUT.RSEQ.state == 3'd0);

    always @(posedge DUT.sclk) begin
        if (!rst && calib_done) begin
            if (!ddr3_cs_n && !ddr3_ras_n &&  ddr3_cas_n &&  ddr3_we_n) act_pins <= act_pins + 1;
            if (!ddr3_cs_n &&  ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n) wr_pins  <= wr_pins  + 1;
            if (!ddr3_cs_n &&  ddr3_ras_n && !ddr3_cas_n &&  ddr3_we_n) rd_pins  <= rd_pins  + 1;
            if (!ddr3_cs_n && !ddr3_ras_n &&  ddr3_cas_n && !ddr3_we_n) pre_pins <= pre_pins + 1;

            if (w_accept_now) w_acc <= w_acc + 1;
            if (r_accept_now) r_acc <= r_acc + 1;
            if (write_req && !w_accept_now) w_ign <= w_ign + 1;
            if (read_req  && !r_accept_now) r_ign <= r_ign + 1;

            if (DUT.wseq_write_start) w_done <= w_done + 1;
            if (DUT.rseq_read_start)  r_done <= r_done + 1;
            if (read_data_valid) begin
                r_log[r_valid % 4096] <= read_data;
                r_valid <= r_valid + 1;
            end

            if (DUT.wseq_busy && DUT.rseq_busy)           both_busy_seen      <= 1'b1;
            if (DUT.wseq_cmd_valid && DUT.rseq_cmd_valid) cmd_contention_seen <= 1'b1;
        end
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

    integer round_fails = 0;
    task round_fail(input [127:0] kind, input polite, input integer d, input [1023:0] why);
        begin
            $display("  FAIL %0s %0s d=%0d: %0s", kind, polite ? "polite" : "blind", d, why);
            round_fails = round_fails + 1;
            errors = errors + 1;
        end
    endtask

    task wait_fall;
        reg bp, found;
        begin
            bp    = refresh_busy;
            found = 1'b0;
            while (!found) begin
                @(posedge clk);
                if (bp && !refresh_busy) found = 1'b1;
                bp = refresh_busy;
            end
        end
    endtask

    // Coverage per pair: a blind second request must have been ignored at
    // some offsets AND accepted at others, or the sweep never exercised
    // both sides of the gate.
    integer ign_cov [0:3], acc_cov [0:3];
    integer same_cycle_rounds = 0;
    integer round_no = 0;

    task pair_round(input first_w, input second_w, input integer d, input polite);
        integer act0, wr0, rd0, pre0, wacc0, racc0, wdone0, rdone0, valid0;
        integer wacc, racc, k;
        reg [7:0] a_data, b_data, stored0, exp_stored, exp_read;
        reg second_accepted;
        integer kidx;
        reg [127:0] kname;
        begin
            kidx  = (first_w ? 2 : 0) + (second_w ? 1 : 0);
            kname = (first_w ? (second_w ? "W->W" : "W->R") : (second_w ? "R->W" : "R->R"));
            round_no = round_no + 1;
            a_data = 8'hA0 + round_no[7:0];
            b_data = 8'hB0 + round_no[7:0];

            wait_fall;
            repeat (30) @(posedge clk);   // well clear of the next refresh (due ~194 after the fall)

            act0 = act_pins; wr0 = wr_pins; rd0 = rd_pins; pre0 = pre_pins;
            wacc0 = w_acc; racc0 = r_acc; wdone0 = w_done; rdone0 = r_done; valid0 = r_valid;
            stored0 = MEM.peek(write_bank, write_row, write_col);

            // first request, sampled by the DUT on the next edge (T)
            if (first_w) begin write_data <= a_data; write_req <= 1'b1; end
            else         begin read_req <= 1'b1; end
            // d == 0: the second request in the very same cycle
            if (d == 0) begin
                if (second_w) begin write_data <= a_data; write_req <= 1'b1; end
                else          begin read_req <= 1'b1; end
                same_cycle_rounds = same_cycle_rounds + 1;
            end
            @(posedge clk);                // T
            write_req <= 1'b0; read_req <= 1'b0;

            if (d > 0) begin
                if (polite) begin
                    // decides at T+d, having seen busy for its own first
                    // request (d >= 1), then presents once THE BUSY OF THE
                    // DIRECTION IT IS ABOUT TO USE is low - the natural
                    // per-direction contract, and deliberately not "check
                    // both busies", which would make the hazard invisible
                    repeat (d) @(posedge clk);
                    while (second_w ? write_busy : read_busy) @(posedge clk);
                end else begin
                    repeat (d - 1) @(posedge clk);
                end
                if (second_w) begin write_data <= b_data; write_req <= 1'b1; end
                else          begin read_req <= 1'b1; end
                @(posedge clk);
                write_req <= 1'b0; read_req <= 1'b0;
            end
            repeat (70) @(posedge clk);

            wacc = w_acc - wacc0; racc = r_acc - racc0;
            second_accepted = (wacc + racc) >= 2;

            // ---- acceptance is all-or-nothing, counted on the real pins ----
            if ((act_pins - act0) != (wacc + racc))
                round_fail(kname, polite, d, "ACT count on the pins does not match accepted requests");
            if ((pre_pins - pre0) != (wacc + racc))
                round_fail(kname, polite, d, "PRECHARGE count on the pins does not match accepted requests");
            if ((wr_pins - wr0) != wacc)
                round_fail(kname, polite, d, "WR count on the pins does not match accepted writes");
            if ((rd_pins - rd0) != racc)
                round_fail(kname, polite, d, "RD count on the pins does not match accepted reads");
            if ((w_done - wdone0) != wacc)
                round_fail(kname, polite, d, "completed writes do not match accepted writes");
            if ((r_done - rdone0) != racc)
                round_fail(kname, polite, d, "completed reads do not match accepted reads");
            if ((r_valid - valid0) != racc)
                round_fail(kname, polite, d, "read_data_valid pulses do not match accepted reads");

            // the first request is always accepted (it is alone until d)
            if ((first_w ? wacc : racc) < 1)
                round_fail(kname, polite, d, "the first request was not accepted");
            // a polite second request is never dropped
            if (polite && !second_accepted)
                round_fail(kname, polite, d, "polite second request was dropped");
            // the documented tie-break: in the same cycle a write beats a read
            if (d == 0 && !(wacc == 1 && racc == 0))
                round_fail(kname, polite, d, "same cycle: exactly the write should have been accepted");
            // never more than two, never a duplicate
            if ((wacc + racc) > 2)
                round_fail(kname, polite, d, "more than two transactions accepted");

            // ---- data ----
            exp_stored = stored0;
            if (first_w) exp_stored = a_data;
            if (second_accepted && second_w) exp_stored = b_data;
            if (MEM.peek(write_bank, write_row, write_col) !== exp_stored)
                round_fail(kname, polite, d, "wrong (or stale) data reached memory");

            for (k = 0; k < (r_valid - valid0); k = k + 1) begin
                // a read sees the value in memory when it runs: after the
                // first write if there was one, else what was there before
                exp_read = first_w ? a_data : stored0;
                if (r_log[(valid0 + k) % 4096] !== exp_read)
                    round_fail(kname, polite, d, "a read returned the wrong data");
            end

            if (model_error)
                round_fail(kname, polite, d, "protocol checker error");

            if (!polite && d > 0) begin
                if (second_accepted) acc_cov[kidx] = acc_cov[kidx] + 1;
                else                 ign_cov[kidx] = ign_cov[kidx] + 1;
            end
        end
    endtask

    integer kk, dd;

    initial begin
        for (kk = 0; kk < 4; kk = kk + 1) begin ign_cov[kk] = 0; acc_cov[kk] = 0; end

        $display("=== DDR3 one transaction at a time (Phase 9 Stage 1, Part 13) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check_true("calibration completed before this test begins", calib_done && !calib_error);

        // blind: d = 0 (same cycle, mixed pairs only) .. D_MAX
        for (dd = 0; dd <= D_MAX; dd = dd + 1) begin
            if (dd > 0) pair_round(1'b1, 1'b1, dd, 1'b0);   // W->W
            pair_round(1'b1, 1'b0, dd, 1'b0);               // W->R
            if (dd > 0) pair_round(1'b0, 1'b1, dd, 1'b0);   // R->W
            if (dd > 0) pair_round(1'b0, 1'b0, dd, 1'b0);   // R->R
        end
        // polite: a single caller that waits for busy (d >= 1)
        for (dd = 1; dd <= D_MAX; dd = dd + 1) begin
            pair_round(1'b1, 1'b1, dd, 1'b1);
            pair_round(1'b1, 1'b0, dd, 1'b1);
            pair_round(1'b0, 1'b1, dd, 1'b1);
            pair_round(1'b0, 1'b0, dd, 1'b1);
        end

        repeat (20) @(posedge clk);

        $display("");
        $display("  sweep: d = 0..%0d, blind (4 pairs) + polite (4 pairs), %0d rounds", D_MAX, round_no);
        $display("  same-cycle rounds: %0d", same_cycle_rounds);
        $display("  blind second request ignored / accepted, per pair (W->W, W->R, R->W, R->R):");
        $display("    ignored:  %0d %0d %0d %0d", ign_cov[3], ign_cov[2], ign_cov[1], ign_cov[0]);
        $display("    accepted: %0d %0d %0d %0d", acc_cov[3], acc_cov[2], acc_cov[1], acc_cov[0]);
        $display("  pins: %0d ACT, %0d WR, %0d RD, %0d PRE for %0d accepted writes and %0d accepted reads",
                 act_pins, wr_pins, rd_pins, pre_pins, w_acc, r_acc);

        check_true("every request was fully accepted or fully ignored, and no polite request was dropped",
                   round_fails == 0);
        check_true("the two sequencers were never busy at the same time", !both_busy_seen);
        check_true("the two sequencers never drove a command in the same cycle", !cmd_contention_seen);
        check_true("no real protocol error by the end of the test", !model_error);

        // Premises - without these a clean sweep could be one that never
        // reached the overlap.
        check_true("blind W->W was ignored at some offsets and accepted at others", ign_cov[3] > 0 && acc_cov[3] > 0);
        check_true("blind W->R was ignored at some offsets and accepted at others", ign_cov[2] > 0 && acc_cov[2] > 0);
        check_true("blind R->W was ignored at some offsets and accepted at others", ign_cov[1] > 0 && acc_cov[1] > 0);
        check_true("blind R->R was ignored at some offsets and accepted at others", ign_cov[0] > 0 && acc_cov[0] > 0);
        check_true("a write and a read really were presented in the same cycle", same_cycle_rounds > 0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 ONE-TRANSACTION TEST PASSED");
        else             $display("DDR3 ONE-TRANSACTION TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
