// Integrated test for Phase 9 Stage 3 (docs/roadmap/phase-09-ddr.md), 8-beat bursts, part B: the read side at beat
// resolution. A READ brings back a BL8 burst; the controller (rtl/soc/ddr3_ecp5_top.v) captures the four beats of each
// of its two sclk cycles on Q0 to Q3 (rtl/soc/ddr3_dq_serdes_ecp5.v) and reports all eight in `read_burst`, beat b in
// [16*b +: 16] as {lane 1, lane 0}; `read_data` is beat 0, as it always was.
//
// What this holds, through the real top, commands and both lanes' memory models:
//   - a block written with a different word in each of its eight columns reads back in the order the part gives it: from
//     the addressed column c, beat b is column (c + b) mod 8 of the aligned eight, so from column 0 it is 0 to 7 and from
//     column 3 it is 3 to 7 then 0 to 2 (the wrap), from column 7 it is 7 then 0 to 6;
//   - in each beat both lanes' bytes are the ones written, in the right lane (the two lanes carry different data in every
//     column, so a crossed lane or a beat taken from the wrong column shows);
//   - `read_data` is beat 0 and `read_burst_valid` pulses once per read, two cycles after `read_data_valid`, and never
//     during a write;
//   - a second read, of another block, replaces the first read's burst whole (no beat is left over from the last);
//   - no write-burst timing error and no protocol error on the way.
// What it does not establish: anything on a board. The four-phase capture's order (Q0 earliest) is LiteDRAM's, not
// checked against Lattice's document; and the strobe is a stand-in in the simulation (rtl/soc/ddr3_dqs_ecp5.v), so the
// capture is aligned by construction here, not by the strobe.
`timescale 1ns/1ps
module tb_ddr3_burst_read;
    localparam CLK_HZ     = 25_000_000;
    localparam CLK_PERIOD = 40;   // 25 MHz

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    wire        ddr3_ck;
    wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [14:0] ddr3_a;
    wire        ddr3_cke, ddr3_odt;
    wire        ddr3_reset_n = ~rst;
    wire [7:0]  ddr3_dq;
    wire        ddr3_dqs;
    wire        ddr3_dm;
    wire [7:0]  ddr3_dqu;
    wire        ddr3_udqs;
    wire        ddr3_udm;

    wire pll_locked, dll_locked, init_ready;
    wire calib_done, calib_error, calib1_done, calib1_error;
    wire [2:0] calib_readclksel, calib1_readclksel;

    reg         write_req  = 1'b0;
    reg  [2:0]  write_bank = 3'd0;
    reg  [15:0] write_row  = 16'd0;
    reg  [15:0] write_col  = 16'd0;
    reg  [15:0] write_data = 16'd0;
    reg  [1:0]  write_be   = 2'b11;
    wire        write_busy;

    reg         read_req  = 1'b0;
    reg  [2:0]  read_bank = 3'd0;
    reg  [15:0] read_row  = 16'd0;
    reg  [15:0] read_col  = 16'd0;
    wire        read_busy;
    wire [15:0] read_data;
    wire        read_data_valid;
    wire [127:0] read_burst;
    wire        read_burst_valid;
    wire        refresh_busy;

    ddr3_ecp5_top DUT (
        .rst_warm(1'b0),
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .write_req(write_req), .write_bank(write_bank), .write_row(write_row),
        .write_col(write_col), .write_data(write_data), .write_be(write_be), .write_busy(write_busy),
        .read_req(read_req), .read_bank(read_bank), .read_row(read_row), .read_col(read_col),
        .read_busy(read_busy), .read_data(read_data), .read_data_valid(read_data_valid),
        .read_burst(read_burst), .read_burst_valid(read_burst_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked), .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel), .calib_error(calib_error),
        .calib1_done(calib1_done), .calib1_readclksel(calib1_readclksel), .calib1_error(calib1_error)
    );

    wire         model_error;
    wire [511:0] model_error_msg;
    ddr3_model #(.CLK_HZ(CLK_HZ)) PROTO (
        .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done()
    );

    wire [7:0]   mem_dq_o;
    wire         mem_dq_oe, mem_dqs_oe, mem_dqs_o;
    wire         dq_error;
    wire [511:0] dq_error_msg;
    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
        .read_active(DUT.read_active_final),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_oe(mem_dqs_oe), .mem_dqs_o(mem_dqs_o),
        .dq_error(dq_error), .dq_error_msg(dq_error_msg)
    );
    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = mem_dqs_oe ? mem_dqs_o : 1'bz;

    wire [7:0]   mem_dqu_o;
    wire         mem_dqu_oe, mem_udqs_oe, mem_udqs_o;
    wire         dqu_error;
    wire [511:0] dqu_error_msg;
    ddr3_dq_model MEM1 (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dqu), .dqs_pin(ddr3_udqs), .dm_pin(ddr3_udm),
        .read_active(DUT.read_active_final_1),
        .mem_dq_o(mem_dqu_o), .mem_dq_oe(mem_dqu_oe), .mem_dqs_oe(mem_udqs_oe), .mem_dqs_o(mem_udqs_o),
        .dq_error(dqu_error), .dq_error_msg(dqu_error_msg)
    );
    genvar b1;
    generate
        for (b1 = 0; b1 < 8; b1 = b1 + 1) begin : DQU_BUS
            assign ddr3_dqu[b1] = mem_dqu_oe ? mem_dqu_o[b1] : 1'bz;
        end
    endgenerate
    assign ddr3_udqs = mem_udqs_oe ? mem_udqs_o : 1'bz;

    integer errors = 0;
    task check16(input [511:0] what, input [15:0] got, input [15:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %04h, expected %04h", what, got, want);
                errors = errors + 1;
            end
        end
    endtask
    task check_true(input [511:0] what, input cond);
        begin
            if (!cond) begin
                $display("  FAIL %0s", what);
                errors = errors + 1;
            end else $display("  ok   %0s", what);
        end
    endtask

    // ---- what the controller reports, on its own clock ----
    integer     cyc = 0;
    integer     n_rdv = 0, n_rbv = 0;
    integer     rdv_cyc = -1, rbv_cyc = -1;
    reg [15:0]  last_read;
    reg [127:0] last_burst;
    reg         rbv_during_write = 1'b0;
    always @(posedge DUT.sclk) begin
        cyc = cyc + 1;
        if (read_data_valid) begin
            n_rdv   <= n_rdv + 1;
            rdv_cyc <= cyc;
            last_read <= read_data;
        end
        if (read_burst_valid) begin
            n_rbv   <= n_rbv + 1;
            rbv_cyc <= cyc;
            last_burst <= read_burst;
            if (write_busy) rbv_during_write <= 1'b1;
        end
    end

    // ---- the caller: one request at a time, waiting for busy to rise and fall, as rtl/soc/wb_ddr.v does ----
    task do_write(input [2:0] bk, input [15:0] rw, input [15:0] cl, input [15:0] d);
        integer t;
        begin
            while (write_busy) @(posedge clk);
            @(posedge clk);
            write_bank <= bk; write_row <= rw; write_col <= cl; write_data <= d;
            write_req <= 1'b1;
            @(posedge clk);
            write_req <= 1'b0;
            t = 0;
            while (!write_busy && t < 200) begin @(posedge clk); t = t + 1; end
            t = 0;
            while (write_busy && t < 400) begin @(posedge clk); t = t + 1; end
            if (t >= 400) begin $display("  FAIL write never finished"); errors = errors + 1; end
            repeat (4) @(posedge clk);
        end
    endtask

    integer reads_seen;
    integer rdv0, rbv0;   // the pulses calibration's own reads made: they are the controller's, not this test's
    task do_read(input [2:0] bk, input [15:0] rw, input [15:0] cl);
        integer t, r0, b0;
        begin
            while (read_busy) @(posedge clk);
            r0 = n_rdv; b0 = n_rbv;
            @(posedge clk);
            read_bank <= bk; read_row <= rw; read_col <= cl; read_req <= 1'b1;
            @(posedge clk);
            read_req <= 1'b0;
            t = 0;
            while (!read_busy && t < 200) begin @(posedge clk); t = t + 1; end
            t = 0;
            while (read_busy && t < 400) begin @(posedge clk); t = t + 1; end
            if (t >= 400) begin $display("  FAIL read never finished"); errors = errors + 1; end
            repeat (6) @(posedge clk);
            if (n_rdv != r0 + 1) begin
                $display("  FAIL read_data_valid pulsed %0d times for one read", n_rdv - r0);
                errors = errors + 1;
            end
            if (n_rbv != b0 + 1) begin
                $display("  FAIL read_burst_valid pulsed %0d times for one read", n_rbv - b0);
                errors = errors + 1;
            end
            reads_seen = reads_seen + 1;
        end
    endtask

    // the word written in column k of block `blk` (a different one in every column of every block, and different in the lanes)
    function [15:0] word(input integer blk, input integer k);
        reg [7:0] lo;
        begin
            lo   = 8'h21 + 8'h37 * blk + 8'h0B * k;
            word = {~(lo ^ 8'h5A) + 8'h03 * k[7:0], lo};
        end
    endfunction

    task write_block(input [2:0] bk, input [15:0] rw, input [15:0] first_col, input integer blk);
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) do_write(bk, rw, first_col + k, word(blk, k));
        end
    endtask

    // read from column `first_col + c` and compare the burst with the block's words in burst order
    integer beat_fails;
    task read_and_check(input [2:0] bk, input [15:0] rw, input [15:0] first_col, input integer c, input integer blk);
        integer k;
        reg [15:0] want;
        begin
            do_read(bk, rw, first_col + c);
            check16("read_data is beat 0", last_read, word(blk, c));
            if (rbv_cyc - rdv_cyc != 2) begin
                $display("  FAIL read_burst_valid is %0d cycles after read_data_valid, expected 2", rbv_cyc - rdv_cyc);
                errors = errors + 1;
            end
            for (k = 0; k < 8; k = k + 1) begin
                want = word(blk, (c + k) % 8);
                if (last_burst[16 * k +: 16] !== want) begin
                    $display("  FAIL read from column %0d: beat %0d is %04h, expected %04h (column %0d)",
                             c, k, last_burst[16 * k +: 16], want, (c + k) % 8);
                    errors = errors + 1;
                    beat_fails = beat_fails + 1;
                end
            end
        end
    endtask

    integer i;
    initial begin
        $display("=== DDR3 read burst at beat resolution (Phase 9 Stage 3, 8-beat bursts part B) ===");
        reads_seen = 0; beat_fails = 0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!(calib_done && calib1_done) && !calib_error && !calib1_error && $time < 900_000) @(posedge clk);
        check_true("both lanes calibrated before this test begins", calib_done && calib1_done && !calib_error && !calib1_error);

        repeat (8) @(posedge clk);
        rdv0 = n_rdv; rbv0 = n_rbv; rbv_during_write <= 1'b0;
        // two blocks in different banks and rows, eight different words each
        write_block(3'd1, 16'h0123, 16'h0010, 0);
        write_block(3'd5, 16'h4001, 16'h0018, 1);
        check_true("no read_burst_valid during the writes", n_rbv == rbv0 && !rbv_during_write);

        read_and_check(3'd1, 16'h0123, 16'h0010, 0, 0);   // aligned: beats 0 to 7
        read_and_check(3'd1, 16'h0123, 16'h0010, 3, 0);   // wraps: 3 to 7, then 0 to 2
        read_and_check(3'd1, 16'h0123, 16'h0010, 7, 0);   // 7, then 0 to 6
        read_and_check(3'd5, 16'h4001, 16'h0018, 2, 1);   // another block: nothing is left over from the one before
        read_and_check(3'd1, 16'h0123, 16'h0010, 5, 0);   // and back
        check_true("every beat of every burst was the word written there", beat_fails == 0);
        check_true("one read_burst_valid per read, none in between", n_rbv - rbv0 == reads_seen && n_rdv - rdv0 == reads_seen);
        // calibration's own reads included: a read whose window the controller rejects (the early taps of the sweep) reports
        // neither a word nor a burst, so the two pulse counts are always equal
        check_true("read_burst_valid pulses exactly as often as read_data_valid", n_rbv == n_rdv && n_rbv > rbv0);

        check_true("no write-burst timing error on lane 0 or lane 1", !dq_error && !dqu_error);
        check_true("no protocol error", !model_error);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 BURST READ TEST PASSED");
        else             $display("DDR3 BURST READ TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
