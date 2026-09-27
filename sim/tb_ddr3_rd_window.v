// Test for Phase 9 Stage 1, Part 18 (docs/roadmap.md): where a read burst lands
// relative to its READ command, and what the DUT captures from it.
//
// Through Part 17 the memory model drove read data whenever the DUT said
// `read_active`, so nothing about the read path depended on when a real DRAM
// would respond, and CL_CYC left at the wrong value passed every integrated
// test (Part 16's mutation showed it). The model now drives the burst itself,
// from the READ command, at the DRAM's own read latency (Micron, DLL-off mode:
// data "AL + CL - 1 cycles after the READ command", tDQSCK 1-10 ns).
//
// For a READ driven in sclk cycle R the DRAM's side, at sclk resolution, is:
//     R+2  preamble        DQS driven low, DQ high-Z
//     R+3  burst, half 1   DQS high, DQ = beat 0's byte (the addressed column)
//     R+4  burst, half 2   DQS high, DQ = beat 4's byte (four columns on, wrapping)
//     R+5  postamble       DQS driven low
//     every other cycle    DQS and DQ high-Z
// and the DUT's side, which is what this design is responsible for:
//     - its READ window (`read_active_final`) must overlap a DQS-high cycle,
//     - it must report exactly one `read_data_valid` per READ, and
//     - the byte it returns must be beat 0's, not beat 4's.
// The two halves are given different data on purpose. A capture one cycle late
// reads half 2, which would be indistinguishable if both halves held the same
// byte.
`timescale 1ns/1ps
module tb_ddr3_rd_window;
    localparam CLK_PERIOD = 40;   // 25 MHz sclk
    localparam NREADS     = 8;
    localparam NALL       = NREADS + 2;   // + the two unwritten-cell reads
    localparam LOG        = 4096;
    // Where the DUT reports read_data_valid relative to the READ, measured off the run and pinned
    // here: the cycle after burst half 1 (R+3), when the captured byte is visible.
    localparam READ_VALID_AT = 4;

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
    wire        ddr3_dm;   // Part 22

    wire pll_locked, dll_locked, init_ready;
    wire calib_done, calib_error;
    wire [2:0] calib_readclksel;

    reg         write_req = 1'b0;
    reg  [2:0]  write_bank = 3'd0;
    reg  [15:0] write_row  = 16'h0000;
    reg  [15:0] write_col  = 16'h0000;
    reg  [7:0]  write_data = 8'h00;
    wire        write_busy;

    reg         read_req = 1'b0;
    reg  [2:0]  read_bank = 3'd0;
    reg  [15:0] read_row  = 16'h0000;
    reg  [15:0] read_col  = 16'h0000;
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
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
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

    wire        dq_error;
    wire [511:0] dq_error_msg;
    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_oe, mem_dqs_o;
    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
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

    // ---- an independent monitor of the pins and the DUT's read window ----
    integer cyc = 0;
    reg [1:0]  dqs_log  [0:LOG-1];   // 0 low, 1 high, 2 high-Z, 3 unknown
    reg        dqz_log  [0:LOG-1];   // DQ has a bit that is z or x
    reg [7:0]  dq_log   [0:LOG-1];
    reg        ract_log [0:LOG-1];   // the DUT's READ window
    reg        rdv_log  [0:LOG-1];   // read_data_valid
    reg [7:0]  rd_log   [0:LOG-1];   // read_data when it pulsed
    // The pins are read through sim/pin_probe.v's inout ports so that a floating strobe
    // reads as high-Z under Verilator as well as under Icarus (see that file).
    wire [1:0] probe_dqs_class;
    wire       probe_dq_bad;
    wire [7:0] probe_dq_value;
    pin_probe PROBE (.dqs(ddr3_dqs), .dq(ddr3_dq), .dqs_class(probe_dqs_class),
                     .dq_bad(probe_dq_bad), .dq_value(probe_dq_value));
    always @(posedge DUT.sclk) begin
        if (!rst) begin
            dqs_log [cyc % LOG] = probe_dqs_class;
            dqz_log [cyc % LOG] = probe_dq_bad;
            dq_log  [cyc % LOG] = probe_dq_value;
            ract_log[cyc % LOG] = DUT.read_active_final;
            rdv_log [cyc % LOG] = read_data_valid;
            rd_log  [cyc % LOG] = read_data;
            cyc = cyc + 1;
        end
    end

    integer rd_n = 0;
    integer rd_cyc [0:NALL-1];
    always @(posedge ddr3_ck) begin
        if (!rst && calib_done && !ddr3_cs_n && ddr3_ras_n && !ddr3_cas_n && ddr3_we_n && rd_n < NALL) begin
            rd_cyc[rd_n] = cyc;
            rd_n = rd_n + 1;
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

    // the location each read targets, and what beats 0 and 4 hold
    reg [15:0] col_a [0:NREADS-1];
    reg [7:0]  beat0 [0:NREADS-1];
    reg [7:0]  beat4 [0:NREADS-1];

    integer i, k, w, guard, dqs_fails, dq_fails, cap_fails, unw_fails, ov;
    integer rdv_count, rdv_at;
    reg [1:0] want_dqs;
    initial begin
        $display("=== DDR3 read burst window vs READ latency (Phase 9 Stage 1, Part 18) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check_true("calibration completed before this test begins", calib_done && !calib_error);

        // Write two columns four apart in one aligned 8 - beat 0 and beat 4 of a read
        // of either - with different bytes, in eight distinct rows.
        for (i = 0; i < NREADS; i = i + 1) begin
            col_a[i] = 16'h0008 * i + 16'h0002 + (i % 2) * 16'h0004;   // alternates c and c^4 style
            beat0[i] = 8'h31 + 8'h1B * i;
            beat4[i] = 8'hC8 - 8'h13 * i;
        end
        for (i = 0; i < NREADS; i = i + 1) begin
            // beat 0's column
            write_bank <= 3'd2; write_row <= 16'h0200 + i; write_col <= col_a[i]; write_data <= beat0[i];
            @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; @(posedge clk);
            guard = 0; while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
            // beat 4's column: four on, wrapping within the aligned 8
            write_col <= {col_a[i][15:3], col_a[i][2:0] ^ 3'b100}; write_data <= beat4[i];
            @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; @(posedge clk);
            guard = 0; while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
        end

        // now read each back
        for (i = 0; i < NREADS; i = i + 1) begin
            read_bank <= 3'd2; read_row <= 16'h0200 + i; read_col <= col_a[i];
            @(posedge clk); read_req <= 1'b1; @(posedge clk); read_req <= 1'b0; @(posedge clk);
            guard = 0; while (read_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
            repeat (i * 2) @(posedge clk);
        end

        // Two more reads, of cells the model has not fully been given:
        //   8: a cell written, its neighbour four columns on NOT - beat 4 must read 00
        //   9: a cell never written at all - beat 0 must read as unknown, not as a made-up byte
        write_bank <= 3'd3; write_row <= 16'h0300; write_col <= 16'h0005; write_data <= 8'h6E;
        @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; @(posedge clk);
        guard = 0; while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
        read_bank <= 3'd3; read_row <= 16'h0300; read_col <= 16'h0005;
        @(posedge clk); read_req <= 1'b1; @(posedge clk); read_req <= 1'b0; @(posedge clk);
        guard = 0; while (read_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
        read_bank <= 3'd4; read_row <= 16'h0301; read_col <= 16'h0009;
        @(posedge clk); read_req <= 1'b1; @(posedge clk); read_req <= 1'b0; @(posedge clk);
        guard = 0; while (read_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
        repeat (10) @(posedge clk);

        check_true("all ten READ commands were seen on the real command pins", rd_n == NALL);

        dqs_fails = 0; dq_fails = 0; cap_fails = 0;
        for (w = 0; w < NREADS; w = w + 1) begin
            // ---- the DRAM's side: the pins ----
            for (k = 0; k <= 7; k = k + 1) begin
                case (k)
                    2:       want_dqs = 2'd0;
                    3, 4:    want_dqs = 2'd1;
                    5:       want_dqs = 2'd0;
                    default: want_dqs = 2'd2;
                endcase
`ifdef VERILATOR
                // a floating DQS reads as low here (see tb_ddr3_wr_window.v)
                if (dqs_log[(rd_cyc[w] + k) % LOG] !== want_dqs &&
                    !(want_dqs == 2'd2 && dqs_log[(rd_cyc[w] + k) % LOG] == 2'd0)) begin
`else
                if (dqs_log[(rd_cyc[w] + k) % LOG] !== want_dqs) begin
`endif
                    if (dqs_fails < 8)
                        $display("  FAIL read %0d: R+%0d DQS is %0d, expected %0d", w, k, dqs_log[(rd_cyc[w] + k) % LOG], want_dqs);
                    dqs_fails = dqs_fails + 1;
                end
            end
            if (dqz_log[(rd_cyc[w] + 3) % LOG] || dq_log[(rd_cyc[w] + 3) % LOG] !== beat0[w]) begin
                if (dq_fails < 8) $display("  FAIL read %0d: DQ at R+3 is %02h, expected beat 0 (%02h)", w, dq_log[(rd_cyc[w] + 3) % LOG], beat0[w]);
                dq_fails = dq_fails + 1;
            end
            if (dqz_log[(rd_cyc[w] + 4) % LOG] || dq_log[(rd_cyc[w] + 4) % LOG] !== beat4[w]) begin
                if (dq_fails < 8) $display("  FAIL read %0d: DQ at R+4 is %02h, expected beat 4 (%02h)", w, dq_log[(rd_cyc[w] + 4) % LOG], beat4[w]);
                dq_fails = dq_fails + 1;
            end
            // ---- the DUT's side ----
            ov = 0; rdv_count = 0; rdv_at = -1;
            for (k = 0; k <= 9; k = k + 1) begin
                if (ract_log[(rd_cyc[w] + k) % LOG] && dqs_log[(rd_cyc[w] + k) % LOG] == 2'd1) ov = ov + 1;
                if (rdv_log[(rd_cyc[w] + k) % LOG]) begin rdv_count = rdv_count + 1; if (rdv_at < 0) rdv_at = k; end
            end
            if (ov == 0) begin
                if (cap_fails < 8) $display("  FAIL read %0d: the DUT's READ window never overlapped a DQS-high cycle", w);
                cap_fails = cap_fails + 1;
            end
            if (rdv_count != 1) begin
                if (cap_fails < 8) $display("  FAIL read %0d: read_data_valid pulsed %0d times, expected once", w, rdv_count);
                cap_fails = cap_fails + 1;
            end else begin
                if (w == 0) $display("  measured: read_data_valid at R+%0d", rdv_at);
                if (rd_log[(rd_cyc[w] + rdv_at) % LOG] !== beat0[w]) begin
                    if (cap_fails < 8)
                        $display("  FAIL read %0d: the DUT returned %02h, expected beat 0 (%02h) - beat 4 is %02h",
                                 w, rd_log[(rd_cyc[w] + rdv_at) % LOG], beat0[w], beat4[w]);
                    cap_fails = cap_fails + 1;
                end
                if (rdv_at != READ_VALID_AT) begin
                    if (cap_fails < 8)
                        $display("  FAIL read %0d: read_data_valid at R+%0d, expected R+%0d", w, rdv_at, READ_VALID_AT);
                    cap_fails = cap_fails + 1;
                end
            end
        end

        // ---- the two reads of cells that are not fully written ----
        unw_fails = 0;
        for (w = NREADS; w < NALL; w = w + 1) begin
            for (k = 0; k <= 7; k = k + 1) begin
                case (k)
                    2:       want_dqs = 2'd0;
                    3, 4:    want_dqs = 2'd1;
                    5:       want_dqs = 2'd0;
                    default: want_dqs = 2'd2;
                endcase
`ifdef VERILATOR
                // a floating DQS reads as low here (see tb_ddr3_wr_window.v)
                if (dqs_log[(rd_cyc[w] + k) % LOG] !== want_dqs &&
                    !(want_dqs == 2'd2 && dqs_log[(rd_cyc[w] + k) % LOG] == 2'd0)) begin
`else
                if (dqs_log[(rd_cyc[w] + k) % LOG] !== want_dqs) begin
`endif
                    if (unw_fails < 8) $display("  FAIL read %0d: R+%0d DQS is %0d, expected %0d", w, k, dqs_log[(rd_cyc[w] + k) % LOG], want_dqs);
                    unw_fails = unw_fails + 1;
                end
            end
        end
        // 8: beat 0 is the byte written, beat 4 - the neighbour, never written - is 00
        if (dq_log[(rd_cyc[NREADS] + 3) % LOG] !== 8'h6E || dq_log[(rd_cyc[NREADS] + 4) % LOG] !== 8'h00) begin
            $display("  FAIL read %0d: beats were %02h then %02h, expected 6e then 00", NREADS,
                     dq_log[(rd_cyc[NREADS] + 3) % LOG], dq_log[(rd_cyc[NREADS] + 4) % LOG]);
            unw_fails = unw_fails + 1;
        end
        // 9: the addressed cell was never written - the DRAM drives DQ, but with no known value
`ifndef VERILATOR
        // (Icarus only: a two-state simulator has no unknown value to return, so this check
        // cannot be made under Verilator - see the note in the Makefile at verilator_ddr3.)
        if (dq_log[(rd_cyc[NREADS + 1] + 3) % LOG] !== 8'hxx) begin
            $display("  FAIL read %0d: a never-written cell returned %02h, expected unknown (xx)", NREADS + 1,
                     dq_log[(rd_cyc[NREADS + 1] + 3) % LOG]);
            unw_fails = unw_fails + 1;
        end
`endif

        check_true("every read: DQS low at R+2, high at R+3 and R+4, low at R+5, high-Z otherwise", dqs_fails == 0);
        check_true("every read: DQ carries beat 0 at R+3 and beat 4 at R+4", dq_fails == 0);
        check_true("every read: the DUT's READ window overlaps DQS, valid once, returns beat 0 (not beat 4)", cap_fails == 0);
        check_true("an unwritten neighbour reads 00 in beat 4; a never-written cell reads as unknown, not as a byte", unw_fails == 0);
        check_true("no DQ/DQS write-burst timing error while reads and writes interleave", !dq_error);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 READ WINDOW TEST PASSED");
        else             $display("DDR3 READ WINDOW TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
