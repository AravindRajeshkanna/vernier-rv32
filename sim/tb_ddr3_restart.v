// What the DDR3 controller does when it is reset and the DRAM is not (Phase 9 Stage 3). It pins what the controller does, which
// includes a known defect (below), and says which of its restarts the DRAM would accept.
//
// The board's reset button resets the FPGA and the DRAM together (the DRAM's RESET# is the board's reset circuit's, schematic
// R02 sheet 3). Two things reset the controller alone: the debugger's `ndmreset` (rtl/soc/soc_top.v), and a bitstream loaded
// over a board that is powered. The DRAM then keeps its contents, its mode registers, its open rows and whatever burst it was
// in, and the controller starts its initialisation against that (rtl/soc/ddr3_init_seq.v's header). The protocol checker's
// RESET# and both memory models' reset follow `brd_rst` (the models' contents survive, as the DRAM's do). Two kinds of reset
// of the controller alone, by the parameter WARM:
//   WARM=1  `rst_warm`, the debugger's ndmreset: the controller knows the DRAM is running, keeps CKE up, lets what the DRAM
//           was doing finish, closes every bank and writes the mode registers again;
//   WARM=0  `rst`, the controller's cold start against a DRAM that was not reset (a bitstream loaded over a powered board,
//           which also wipes CKE): CKE falls, and the power-up sequence runs from the start.
// One scenario per run, each from a power-up:
//   0  the controller is idle                    1  a bank is open (reset at its ACTIVATE)
//   2  in the middle of a write burst            3  in the middle of a read burst
//   4  just after a REFRESH                      5  at a WRITE command, before its burst starts
//   6  at a REFRESH command
// (5 and 6 put the restart as close behind a command as a reset can: they are what shows that the controller waits for the
// DRAM to finish before its PRECHARGE ALL, since the other four leave it time enough by themselves.)
//
// What is asserted, every scenario:
//   - WARM=1: CKE never falls, init_ready falls and rises again well inside the 500 us a cold start waits, a PRECHARGE ALL is on
//     the pins, the initialisation runs in full again (four MRS and a ZQCL more), and the protocol checker has no objection in
//     any of the five (it holds a restart to the DRAM's own rules, sim/ddr3_model.v);
//   - WARM=0: CKE falls with the reset and rises again 500 us or more later, init_ready falls and rises again, and the
//     initialisation runs in full again; the checker says: idle and just after a REFRESH are clean; with a bank open the first
//     MRS is issued to a DRAM with that bank open; in the middle of a write or a read burst CKE falls in the middle of the burst;
//   - KNOWN DEFECT, docs/roadmap/index.md: after every one of them both lanes' calibration ends in an error, so the controller
//     takes no request again until the board is reset. The sweep drives a DQ/DQS burst and a read window and issues no command
//     (rtl/soc/ddr3_read_calib.v), and sim/ddr3_dq_model.v answers that only until it has seen the first command, as a DRAM
//     would answer it never. When calibration issues real commands this expectation is the one to flip (EXPECT_RECAL below).
// What it does not establish: that a restart is safe on a real DRAM, which no model here can show, or anything about retention
// (the DRAM is not refreshed for the 500 us and the rest of the sequence: ten times what JEDEC lets a refresh be postponed).
`timescale 1ns/1ps
module tb_ddr3_restart;
    parameter SCEN = 0;     // when the controller is reset: 0 idle, 1 bank open (after an ACTIVATE), 2 mid write burst, 3 mid read burst, 4 just after a REFRESH, 5 at a WRITE, 6 at a REFRESH
    parameter WARM = 1;     // 1: the debugger's ndmreset (rst_warm), 0: the cold start against a DRAM that was not reset (rst)
    localparam CLK_HZ     = 25_000_000;
    localparam CLK_PERIOD = 40;

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst     = 1'b1;     // the controller's cold reset
    reg rst_warm = 1'b0;    // the controller's warm reset (ndmreset)
    reg brd_rst = 1'b1;     // the board's: the DRAM's RESET# is its complement
    wire ddr3_reset_n = ~brd_rst;

    wire        ddr3_ck, ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [14:0] ddr3_a;
    wire        ddr3_cke, ddr3_odt;
    wire [7:0]  ddr3_dq, ddr3_dqu;
    wire        ddr3_dqs, ddr3_dm, ddr3_udqs, ddr3_udm;

    wire pll_locked, dll_locked, init_ready;
    wire calib_done, calib_error, calib1_done, calib1_error;
    wire [2:0] calib_readclksel, calib1_readclksel;

    reg         write_req  = 1'b0;
    reg  [2:0]  write_bank = 3'd0;
    reg  [15:0] write_row  = 16'd0, write_col = 16'd0, write_data = 16'd0;
    reg  [1:0]  write_be   = 2'b00;
    wire        write_busy;
    reg         read_req  = 1'b0;
    reg  [2:0]  read_bank = 3'd0;
    reg  [15:0] read_row  = 16'd0, read_col = 16'd0;
    wire        read_busy;
    wire [15:0] read_data;
    wire        read_data_valid;
    wire        refresh_busy;

    ddr3_ecp5_top DUT (
        .clk(clk), .rst(rst), .rst_warm(rst_warm),
        .ddr3_ck(ddr3_ck), .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a), .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .write_req(write_req), .write_bank(write_bank), .write_row(write_row),
        .write_col(write_col), .write_data(write_data), .write_be(write_be), .write_busy(write_busy),
        .read_req(read_req), .read_bank(read_bank), .read_row(read_row), .read_col(read_col),
        .read_busy(read_busy), .read_data(read_data), .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked), .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel), .calib_error(calib_error),
        .calib1_done(calib1_done), .calib1_readclksel(calib1_readclksel), .calib1_error(calib1_error)
    );

    wire         model_error;
    wire [511:0] model_error_msg;
    ddr3_model #(.CLK_HZ(CLK_HZ)) PROTO (
        .ck(ddr3_ck), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a), .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done()
    );

    wire [7:0] mem_dq_o;  wire mem_dq_oe, mem_dqs_oe, mem_dqs_o;  wire dq_error;  wire [511:0] dq_error_msg;
    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(brd_rst), .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n), .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
        .read_active(DUT.read_active_final),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_oe(mem_dqs_oe), .mem_dqs_o(mem_dqs_o),
        .dq_error(dq_error), .dq_error_msg(dq_error_msg)
    );
    genvar b;
    generate for (b = 0; b < 8; b = b + 1) begin : DQ_BUS assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz; end endgenerate
    assign ddr3_dqs = mem_dqs_oe ? mem_dqs_o : 1'bz;

    wire [7:0] mem_dqu_o;  wire mem_dqu_oe, mem_udqs_oe, mem_udqs_o;  wire dqu_error;  wire [511:0] dqu_error_msg;
    ddr3_dq_model MEM1 (
        .sclk(DUT.sclk), .rst(brd_rst), .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n), .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dqu), .dqs_pin(ddr3_udqs), .dm_pin(ddr3_udm),
        .read_active(DUT.read_active_final_1),
        .mem_dq_o(mem_dqu_o), .mem_dq_oe(mem_dqu_oe), .mem_dqs_oe(mem_udqs_oe), .mem_dqs_o(mem_udqs_o),
        .dq_error(dqu_error), .dq_error_msg(dqu_error_msg)
    );
    genvar b1;
    generate for (b1 = 0; b1 < 8; b1 = b1 + 1) begin : DQU_BUS assign ddr3_dqu[b1] = mem_dqu_oe ? mem_dqu_o[b1] : 1'bz; end endgenerate
    assign ddr3_udqs = mem_udqs_oe ? mem_udqs_o : 1'bz;

    // ---- the commands as the DRAM sees them ----
    wire c_act = !ddr3_ras_n &&  ddr3_cas_n &&  ddr3_we_n;
    wire c_wr  =  ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n;
    wire c_rd  =  ddr3_ras_n && !ddr3_cas_n &&  ddr3_we_n;
    wire c_ref = !ddr3_ras_n && !ddr3_cas_n &&  ddr3_we_n;
    wire c_mrs = !ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n;
    reg  ev_act = 0, ev_wr = 0, ev_rd = 0, ev_ref = 0;
    always @(posedge ddr3_ck) begin
        if (ddr3_reset_n && ddr3_cke) begin
            if (c_act) ev_act <= ~ev_act;
            if (c_wr)  ev_wr  <= ~ev_wr;
            if (c_rd)  ev_rd  <= ~ev_rd;
            if (c_ref) ev_ref <= ~ev_ref;
        end
    end
    integer n_mrs = 0, n_pre = 0, n_zq = 0;
    always @(posedge ddr3_ck) if (ddr3_reset_n && ddr3_cke) begin
        if (c_mrs) n_mrs <= n_mrs + 1;
        if (!ddr3_ras_n && ddr3_cas_n && !ddr3_we_n) n_pre <= n_pre + 1;
        if (ddr3_ras_n && ddr3_cas_n && !ddr3_we_n) n_zq <= n_zq + 1;
    end

    // ---- a log of what happens, with times ----
    reg  armed = 1'b0;     // the controller is about to be reset: the events below are the restart's
    time t_cke_fall = 0, t_cke_rise = 0, t_init_fall = 0, t_init_rise = 0;
    integer np0;
    reg     dq_early;      // a DQ model had flagged something 10 us after the reset: a burst the reset cut
    always @(negedge ddr3_cke)  if (armed && t_cke_fall == 0) t_cke_fall = $time;
    always @(posedge ddr3_cke)  if (armed && t_cke_fall != 0 && t_cke_rise == 0) t_cke_rise = $time;
    always @(negedge init_ready) if (armed && t_init_fall == 0) t_init_fall = $time;
    always @(posedge init_ready) if (armed && t_init_fall != 0 && t_init_rise == 0) t_init_rise = $time;
    always @(negedge ddr3_cke) if (!brd_rst && ddr3_reset_n) $display("  [%0d us] CKE falls (the DRAM was not reset)", $time / 1000);
    always @(posedge ddr3_cke) $display("  [%0d us] CKE rises", $time / 1000);
    always @(posedge model_error) $display("  [%0d us] PROTOCOL CHECKER: %0s", $time / 1000, model_error_msg);
    always @(posedge dq_error)  $display("  [%0d us] DQ MODEL lane 0: %0s", $time / 1000, dq_error_msg);
    always @(posedge dqu_error) $display("  [%0d us] DQ MODEL lane 1: %0s", $time / 1000, dqu_error_msg);
    always @(posedge init_ready)  $display("  [%0d us] init_ready rises", $time / 1000);
    always @(negedge init_ready)  $display("  [%0d us] init_ready falls", $time / 1000);
    always @(posedge calib_done)  $display("  [%0d us] lane 0 calibrated (tap %0d)", $time / 1000, calib_readclksel);
    always @(posedge calib_error) $display("  [%0d us] lane 0 calibration ERROR", $time / 1000);
    always @(posedge calib1_done) $display("  [%0d us] lane 1 calibrated (tap %0d)", $time / 1000, calib1_readclksel);
    always @(posedge calib1_error) $display("  [%0d us] lane 1 calibration ERROR", $time / 1000);

    integer errors = 0;
    task check(input [511:0] what, input got, input want);
        begin
            if (got !== want) begin $display("  FAIL %0s: got %b, expected %b", what, got, want); errors = errors + 1; end
            else $display("  ok   %0s", what);
        end
    endtask

    // ---- the caller ----
    integer tt;
    task do_write(input [2:0] bk, input [15:0] rw, input [15:0] cl, input [15:0] d);
        begin
            while (write_busy) @(posedge clk);
            @(posedge clk);
            write_bank <= bk; write_row <= rw; write_col <= cl; write_data <= d; write_be <= 2'b11; write_req <= 1'b1;
            @(posedge clk);
            write_req <= 1'b0;
            tt = 0; while (!write_busy && tt < 200) begin @(posedge clk); tt = tt + 1; end
            tt = 0; while (write_busy && tt < 400) begin @(posedge clk); tt = tt + 1; end
            repeat (4) @(posedge clk);
        end
    endtask
    integer     n_valid = 0;
    reg [15:0]  last_read;
    always @(posedge clk) if (read_data_valid) begin last_read <= read_data; n_valid <= n_valid + 1; end
    reg [15:0] got_word;
    task do_read(input [2:0] bk, input [15:0] rw, input [15:0] cl);
        integer n0;
        begin
            while (read_busy) @(posedge clk);
            n0 = n_valid;
            @(posedge clk);
            read_bank <= bk; read_row <= rw; read_col <= cl; read_req <= 1'b1;
            @(posedge clk);
            read_req <= 1'b0;
            tt = 0; while (!read_busy && tt < 200) begin @(posedge clk); tt = tt + 1; end
            tt = 0; while (read_busy && tt < 400) begin @(posedge clk); tt = tt + 1; end
            repeat (2) @(posedge clk);
            got_word = (n_valid == n0 + 1) ? last_read : 16'hDEAD;
        end
    endtask

    localparam [15:0] W0 = 16'hA5C3, W1 = 16'h1E78, W2 = 16'h9B2D, W3 = 16'h40F1;
    reg ea, ew, er, ef;
    integer waited;
    initial begin
        $display("=== DDR3 controller reset alone, scenario %0d ===", SCEN);
        repeat (4) @(posedge clk);
        rst = 1'b0; brd_rst = 1'b0;              // the board's reset, released as one
        while (!(calib_done && calib1_done) && !calib_error && !calib1_error && $time < 1_500_000) @(posedge clk);
        check("both lanes calibrated after the board's reset", calib_done && calib1_done, 1'b1);
        do_write(3'd0, 16'h0010, 16'h0020, W0);
        do_write(3'd1, 16'h0020, 16'h0040, W1);
        do_write(3'd2, 16'h0030, 16'h0060, W2);
        do_write(3'd3, 16'h0040, 16'h0080, W3);
        do_read(3'd0, 16'h0010, 16'h0020); check("a word written before reads back", got_word === W0, 1'b1);
        $display("  [%0d us] --- the controller is reset now (scenario %0d), the DRAM is not ---", $time / 1000, SCEN);
        ea = ev_act; ew = ev_wr; er = ev_rd; ef = ev_ref;
        case (SCEN)
            0: repeat (60) @(posedge DUT.sclk);
            1: begin   // an ACTIVATE has been issued and its bank is open: start a read of another row and reset on its ACTIVATE
                   fork
                       begin read_bank <= 3'd1; read_row <= 16'h0020; read_col <= 16'h0040; read_req <= 1'b1; @(posedge clk); read_req <= 1'b0; end
                       begin ea = ev_act; while (ev_act === ea) @(posedge ddr3_ck); end
                   join
                   @(posedge DUT.sclk);
               end
            2: begin
                   fork
                       begin write_bank <= 3'd2; write_row <= 16'h0030; write_col <= 16'h0060; write_data <= 16'hFFFF; write_be <= 2'b11; write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; end
                       begin ew = ev_wr; while (ev_wr === ew) @(posedge ddr3_ck); end
                   join
                   repeat (4) @(posedge DUT.sclk);   // the burst is on the pins about now
               end
            3: begin
                   fork
                       begin read_bank <= 3'd3; read_row <= 16'h0040; read_col <= 16'h0080; read_req <= 1'b1; @(posedge clk); read_req <= 1'b0; end
                       begin er = ev_rd; while (ev_rd === er) @(posedge ddr3_ck); end
                   join
                   repeat (4) @(posedge DUT.sclk);
               end
            4: begin ef = ev_ref; while (ev_ref === ef) @(posedge ddr3_ck); repeat (2) @(posedge DUT.sclk); end
            5: begin
                   fork
                       begin write_bank <= 3'd2; write_row <= 16'h0030; write_col <= 16'h0060; write_data <= 16'hFFFF; write_be <= 2'b11; write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; end
                       begin ew = ev_wr; while (ev_wr === ew) @(posedge ddr3_ck); end
                   join
               end
            6: begin ef = ev_ref; while (ev_ref === ef) @(posedge ddr3_ck); end
        endcase
        armed = 1'b1;
        np0 = n_pre;
        if (WARM) rst_warm = 1'b1; else rst = 1'b1;
        repeat (2) @(posedge clk);          // as short as a debugger's ndmreset can be: the reset itself gives the DRAM no time to finish
        rst_warm = 1'b0; rst = 1'b0;
        repeat (250) @(posedge clk);        // 10 us in: before the initialisation is done and calibration starts
        dq_early = dq_error || dqu_error;
        // what happens next
        waited = 0;
        while (!((calib_done || calib_error) && (calib1_done || calib1_error) && init_ready) && waited < 40000) begin @(posedge clk); waited = waited + 1; end
        $display("  [%0d us] settled: init_ready=%b lane0 done/err=%b/%b lane1 done/err=%b/%b (MRS %0d, PRE %0d, ZQ %0d seen in all)", $time / 1000,
                 init_ready, calib_done, calib_error, calib1_done, calib1_error, n_mrs, n_pre, n_zq);
        if (calib_done && calib1_done) begin
            repeat (50) @(posedge clk);
            do_read(3'd0, 16'h0010, 16'h0020); $display("  read of the word written before: %h (was %h)", got_word, W0);
            do_read(3'd1, 16'h0020, 16'h0040); $display("  read of the word written before: %h (was %h)", got_word, W1);
            do_read(3'd2, 16'h0030, 16'h0060); $display("  read of the word written before: %h (was %h)", got_word, W2);
            do_read(3'd3, 16'h0040, 16'h0080); $display("  read of the word written before: %h (was %h)", got_word, W3);
        end
        $display("  verdicts: protocol checker %b, lane 0 DQ model %b, lane 1 DQ model %b", model_error, dq_error, dqu_error);
        $display("");
        // ---- what every restart does ----
        if (WARM) begin
            check("CKE stayed up through the reset", t_cke_fall == 0 && ddr3_cke === 1'b1, 1'b1);
            check("init_ready fell and rose again", init_ready && t_init_fall != 0 && t_init_rise != 0, 1'b1);
            check("and well inside the 500 us a cold start waits", (t_init_rise - t_init_fall) < 100_000, 1'b1);
            check("a PRECHARGE ALL went out before the mode registers", n_pre > np0, 1'b1);
        end else begin
            check("CKE fell with the controller's reset", t_cke_fall != 0, 1'b1);
            check("CKE rose again 500 us or more after it fell", (t_cke_rise - t_cke_fall) >= 500_000, 1'b1);
            check("init_ready fell and rose again", init_ready && t_init_fall != 0, 1'b1);
        end
        check("the initialisation ran in full again: eight MRS in all", n_mrs == 8, 1'b1);
        check("and a second ZQCL", n_zq == 2, 1'b1);
        // ---- what the data path loses: a write burst in flight is cut at the pins by the reset itself ----
        check((SCEN == 2 || SCEN == 5) ? "the write burst in flight was cut (the DQ model saw it): its data is lost"
                                       : "nothing else was cut: the DQ models saw no burst broken by the reset", dq_early, SCEN == 2 || SCEN == 5);
        // ---- what the DRAM would say of it ----
        if (WARM) check("the protocol checker has no objection", model_error, 1'b0);
        else case (SCEN)
            0, 4, 6: check("the protocol checker has no objection (the DRAM was idle)", model_error, 1'b0);
            1:    check("the checker says: an MRS with a bank open", model_error && model_error_msg === "MRS with a bank open (all banks must be precharged first)", 1'b1);
            2, 5: check("the checker says: CKE fell in the middle of a write burst", model_error && model_error_msg === "CKE fell in the middle of a write burst (before tWRPDEN)", 1'b1);
            3:    check("the checker says: CKE fell in the middle of a read burst", model_error && model_error_msg === "CKE fell in the middle of a read burst (before tRDPDEN)", 1'b1);
        endcase
        // ---- the known defect ----
`ifdef EXPECT_RECAL
        check("both lanes recalibrated", calib_done && calib1_done && !calib_error && !calib1_error, 1'b1);
`else
        check("KNOWN DEFECT: lane 0's calibration ended in an error", calib_error && !calib_done, 1'b1);
        check("KNOWN DEFECT: lane 1's calibration ended in an error", calib1_error && !calib1_done, 1'b1);
`endif
        $display("");
        if (errors == 0) $display("DDR3 RESTART SCENARIO %0d PASSED", SCEN);
        else             $display("DDR3 RESTART SCENARIO %0d FAILED (%0d)", SCEN, errors);
        $finish;
    end
    initial begin #6_000_000; $display("TIMEOUT"); $finish; end
endmodule
