// Integrated test for Phase 9 Stage 1, Part 12 (docs/roadmap.md): the
// reverse arbitration direction in rtl/soc/ddr3_ecp5_top.v - a new
// write_req/read_req must never start a transaction while a refresh is
// pending or running (Micron MT41K256M16 datasheet, Figure 40, note 5:
// "Only NOP and DES commands are allowed after a REFRESH command and
// until tRFC (MIN) is satisfied"). sim/tb_ddr3_refresh_wire.v (Part 11)
// covers the forward direction, refresh waiting for an in-flight
// transaction.
//
// Proven by sweeping a request across every alignment relative to the
// refresh deadline, not by hitting one hand-picked cycle: Part 11's own
// finding was that a single deterministic collision (or a hoped-for
// one) cannot tell working protection from none. The refresh interval is
// deterministic - the next refresh becomes due a fixed number of cycles
// after refresh_busy falls - so each round anchors on that fall and
// presents one request `k` cycles later, for every k across the window
// where the request, the pending refresh and the running refresh
// overlap.
//
// Four sweeps, because two different caller behaviours matter:
//   polite - a registered caller that respects `busy`: it decides in one
//            cycle and presents its request in the next. It must NEVER
//            be dropped: the request must run once, with the right data.
//   blind  - a caller that ignores `busy`. Its request is either
//            accepted and runs correctly, or ignored and leaves no
//            trace - never half-started, never running on stale data.
// each for writes and for reads.
//
// The independent check is sim/ddr3_model.v's own tRFC rule, which
// watches the real command pins and does not care which module issued a
// command.
`timescale 1ns/1ps
module tb_ddr3_reverse_arb;
    localparam CLK_HZ     = 25_000_000;
    localparam CLK_PERIOD = 40;   // 25 MHz

    // Request offsets swept, in cycles after refresh_busy falls. The next
    // refresh becomes due 194 cycles after that fall (measured, Part 12);
    // its hold on new requests lasts ~10 cycles after that. This range
    // brackets the whole overlap with room either side.
    localparam K_FIRST = 176;
    localparam K_LAST  = 216;

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
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done(model_seq_done)
    );

    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_o;

    wire         dq_error;

    wire [511:0] dq_error_msg;

    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs),
        .read_active(DUT.read_active_final),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_o(mem_dqs_o),
        .dq_error(dq_error), .dq_error_msg(dq_error_msg)
    );

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = mem_dq_oe ? mem_dqs_o : 1'bz;

    // ---- monitors, all sampled on the DUT's own sclk ----
    // "Accepted" is the sequencer going busy; "ignored" is a request
    // presented while the sequencer was idle but the top-level gate was
    // closed. Both are read off the DUT's own internal signals so the
    // test cannot agree with a bug by re-implementing the gate.
    reg  prev_wseq_busy = 1'b0, prev_rseq_busy = 1'b0, prev_refresh_req = 1'b0;
    integer w_accepted = 0, w_ignored = 0, w_boundary = 0, w_done = 0;
    integer r_accepted = 0, r_ignored = 0, r_boundary = 0, r_valid = 0;
    reg  [7:0] r_last_data = 8'h00;
    reg  contention_seen = 1'b0;
    integer refresh_cmds = 0;
    integer cyc = 0, last_refresh_cyc = -1, max_refresh_gap = 0;

    always @(posedge DUT.sclk) begin
        if (!rst && calib_done) begin
            cyc              <= cyc + 1;
            prev_wseq_busy   <= DUT.wseq_busy;
            prev_rseq_busy   <= DUT.rseq_busy;
            prev_refresh_req <= DUT.refresh_req;

            if (DUT.wseq_busy && !prev_wseq_busy) w_accepted <= w_accepted + 1;
            if (DUT.rseq_busy && !prev_rseq_busy) r_accepted <= r_accepted + 1;

            if (write_req && !DUT.wseq_write_req && !DUT.wseq_busy) w_ignored <= w_ignored + 1;
            if (read_req  && !DUT.rseq_read_req  && !DUT.rseq_busy) r_ignored <= r_ignored + 1;

            // accepted in the very cycle refresh_req first appears
            if (DUT.wseq_write_req && !DUT.wseq_busy && DUT.refresh_req && !prev_refresh_req)
                w_boundary <= w_boundary + 1;
            if (DUT.rseq_read_req && !DUT.rseq_busy && DUT.refresh_req && !prev_refresh_req)
                r_boundary <= r_boundary + 1;

            if (DUT.wseq_write_start) w_done <= w_done + 1;
            if (read_data_valid) begin
                r_valid     <= r_valid + 1;
                r_last_data <= read_data;
            end

            // Part 11's own check, kept: a REFRESH command must never
            // assert while either sequencer has a transaction in flight.
            // Raw refresh_cmd_valid, before the top-level mux.
            if (DUT.refresh_cmd_valid && (DUT.wseq_busy || DUT.rseq_busy))
                contention_seen <= 1'b1;

            if (DUT.refresh_cmd_valid) begin
                refresh_cmds <= refresh_cmds + 1;
                if (last_refresh_cyc >= 0 && (cyc - last_refresh_cyc) > max_refresh_gap)
                    max_refresh_gap <= cyc - last_refresh_cyc;
                last_refresh_cyc <= cyc;
            end
        end
    end

    integer errors = 0;
    task check(input [1023:0] what, input got, input want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %b, expected %b", what, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s", what);
            end
        end
    endtask

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

    // One failure line per bad round, naming the offset - a 164-round
    // sweep printing "ok" for each would bury the one that matters.
    integer round_fails = 0;
    task round_fail(input [255:0] kind, input integer k, input [1023:0] why);
        begin
            $display("  FAIL %0s k=%0d: %0s", kind, k, why);
            round_fails = round_fails + 1;
            errors = errors + 1;
        end
    endtask

    // Block until a fresh falling edge of refresh_busy is seen. The
    // caller resumes on the edge that observed it, so the request offset
    // k below is counted from a fixed, observable event.
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

    reg polite_hold_seen = 1'b0;   // a polite caller really did see busy from the hold alone
    integer first_w_boundary_k = -1, first_r_boundary_k = -1;
    integer lo_ignored_k_w = 10_000, hi_ignored_k_w = -1;
    integer lo_ignored_k_r = 10_000, hi_ignored_k_r = -1;

    task write_round(input integer k, input polite, input [7:0] data);
        integer acc0, ign0, done0, bnd0;
        reg [7:0] stored0;
        reg accepted;
        begin
            wait_fall;
            acc0 = w_accepted; ign0 = w_ignored; done0 = w_done; bnd0 = w_boundary;
            stored0 = MEM.peek(write_bank, write_row, write_col);
            write_data <= data;
            repeat (k - 1) @(posedge clk);
            if (polite) begin
                if (write_busy && !DUT.wseq_busy) polite_hold_seen = 1'b1;
                while (write_busy) @(posedge clk);
            end
            write_req <= 1'b1;
            @(posedge clk);
            write_req <= 1'b0;
            repeat (40) @(posedge clk);

            accepted = (w_accepted - acc0) == 1;
            if (w_boundary != bnd0 && first_w_boundary_k < 0) first_w_boundary_k = k;
            if ((w_ignored - ign0) > 0 && !polite) begin
                if (k < lo_ignored_k_w) lo_ignored_k_w = k;
                if (k > hi_ignored_k_w) hi_ignored_k_w = k;
            end

            if (polite) begin
                if (!accepted)                   round_fail("write polite", k, "request dropped");
                else if ((w_done - done0) != 1)  round_fail("write polite", k, "accepted but did not complete once");
                else if (MEM.peek(write_bank, write_row, write_col) !== data)    round_fail("write polite", k, "wrong data reached memory");
            end else begin
                if (accepted) begin
                    if ((w_done - done0) != 1)   round_fail("write blind", k, "accepted but did not complete once");
                    else if (MEM.peek(write_bank, write_row, write_col) !== data) round_fail("write blind", k, "accepted but wrong/stale data reached memory");
                end else begin
                    if ((w_done - done0) != 0)   round_fail("write blind", k, "ignored but a write still completed");
                    else if (MEM.peek(write_bank, write_row, write_col) !== stored0) round_fail("write blind", k, "ignored but memory changed");
                end
            end
            if (model_error) round_fail(polite ? "write polite" : "write blind", k, "protocol checker error");
        end
    endtask

    task read_round(input integer k, input polite);
        integer acc0, ign0, valid0, bnd0;
        reg accepted;
        begin
            wait_fall;
            acc0 = r_accepted; ign0 = r_ignored; valid0 = r_valid; bnd0 = r_boundary;
            repeat (k - 1) @(posedge clk);
            if (polite) begin
                if (read_busy && !DUT.rseq_busy) polite_hold_seen = 1'b1;
                while (read_busy) @(posedge clk);
            end
            read_req <= 1'b1;
            @(posedge clk);
            read_req <= 1'b0;
            repeat (40) @(posedge clk);

            accepted = (r_accepted - acc0) == 1;
            if (r_boundary != bnd0 && first_r_boundary_k < 0) first_r_boundary_k = k;
            if ((r_ignored - ign0) > 0 && !polite) begin
                if (k < lo_ignored_k_r) lo_ignored_k_r = k;
                if (k > hi_ignored_k_r) hi_ignored_k_r = k;
            end

            if (polite) begin
                if (!accepted)                      round_fail("read polite", k, "request dropped");
                else if ((r_valid - valid0) != 1)   round_fail("read polite", k, "accepted but read_data_valid not seen once");
                else if (r_last_data !== MEM.peek(write_bank, write_row, write_col)) round_fail("read polite", k, "wrong data read back");
            end else begin
                if (accepted) begin
                    if ((r_valid - valid0) != 1)    round_fail("read blind", k, "accepted but read_data_valid not seen once");
                    else if (r_last_data !== MEM.peek(write_bank, write_row, write_col)) round_fail("read blind", k, "accepted but wrong data read back");
                end else begin
                    if ((r_valid - valid0) != 0)    round_fail("read blind", k, "ignored but read data still came back");
                end
            end
            if (model_error) round_fail(polite ? "read polite" : "read blind", k, "protocol checker error");
        end
    endtask

    integer k, round_no;

    initial begin
        $display("=== DDR3 reverse arbitration - requests vs refresh (Phase 9 Stage 1, Part 12) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check("calibration completed before this test begins", calib_error, 1'b0);
        check("calibration found a working tap", calib_done, 1'b1);

        // A known value in memory before any read round, so the polite
        // and blind read sweeps are checked against something this test
        // itself put there. Every request here uses one location (bank 1,
        // row 1, column 1); the address path itself is tb_ddr3_addr.v's.
        round_no = 0;
        for (k = K_FIRST; k <= K_LAST; k = k + 1) begin
            write_round(k, 1'b1, 8'h07 + 8'd3 * round_no[7:0]);
            round_no = round_no + 1;
        end
        for (k = K_FIRST; k <= K_LAST; k = k + 1) begin
            write_round(k, 1'b0, 8'h07 + 8'd3 * round_no[7:0]);
            round_no = round_no + 1;
        end
        for (k = K_FIRST; k <= K_LAST; k = k + 1) read_round(k, 1'b1);
        for (k = K_FIRST; k <= K_LAST; k = k + 1) read_round(k, 1'b0);

        repeat (20) @(posedge clk);

        $display("");
        $display("  sweep: k = %0d..%0d, %0d rounds x 4 modes", K_FIRST, K_LAST, K_LAST - K_FIRST + 1);
        $display("  writes: %0d accepted, %0d ignored while idle, %0d accepted exactly as a refresh became due",
                 w_accepted, w_ignored, w_boundary);
        $display("  reads:  %0d accepted, %0d ignored while idle, %0d accepted exactly as a refresh became due",
                 r_accepted, r_ignored, r_boundary);
        $display("  blind writes ignored at k = %0d..%0d; blind reads ignored at k = %0d..%0d",
                 lo_ignored_k_w, hi_ignored_k_w, lo_ignored_k_r, hi_ignored_k_r);
        $display("  boundary write first hit at k=%0d, boundary read at k=%0d", first_w_boundary_k, first_r_boundary_k);
        $display("  REFRESH commands issued: %0d, longest gap between two: %0d cycles", refresh_cmds, max_refresh_gap);

        check_true("no polite caller ever had a request dropped, and every blind outcome was coherent", round_fails == 0);

        // Premises - without these a clean sweep could be a sweep that
        // never actually reached the overlap.
        check_true("blind writes really were ignored at some offsets (the gate did something)", w_ignored > 0);
        check_true("blind reads really were ignored at some offsets (the gate did something)", r_ignored > 0);
        check_true("a write was accepted in the exact cycle a refresh first became due", w_boundary > 0);
        check_true("a read was accepted in the exact cycle a refresh first became due", r_boundary > 0);
        check_true("a polite caller really did see busy from the refresh hold alone", polite_hold_seen);

        check("no REFRESH command ever asserted while a transaction was in flight", contention_seen, 1'b0);
        check("no real protocol error by the end of the test (incl. the model's tRFC rule)", model_error, 1'b0);
        check("no DQ/DQS write-burst timing error across every accepted write", dq_error, 1'b0);
        // 204 is the measured gap when nothing is in flight; a pending
        // refresh may also wait for one whole transaction, which since
        // Part 14 (PRECHARGE after every transaction) is about 22 cycles
        // for a write. Measured longest: see the line above. The bound is
        // there to catch starvation or deadlock, not to pin a number.
        check_true("refresh was never starved - longest gap between REFRESH commands stays bounded", max_refresh_gap <= 245);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 REVERSE ARBITRATION TEST PASSED");
        else             $display("DDR3 REVERSE ARBITRATION TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
