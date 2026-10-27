// Test for Phase 9 Stage 1, Part 18 (docs/roadmap/phase-09-ddr.md): where a read burst lands
// relative to its READ command, and what the DUT captures from it.
//
// Through Part 17 the memory model drove read data whenever the DUT said
// `read_active`, so nothing about the read path depended on when a real DRAM
// would respond, and CL_CYC left at the wrong value passed every integrated
// test (Part 16's mutation showed it). The model now drives the burst itself,
// from the READ command, at the DRAM's own read latency (Micron, DLL-off mode:
// data "AL + CL - 1 cycles after the READ command", tDQSCK 1-10 ns).
//
// For a READ driven in sclk cycle R the DRAM's side is (Phase 9 Stage 3: beat by beat, it was one value per sclk):
//     R+2  preamble        DQS driven low, DQ high-Z
//     R+3, R+4  burst      DQS toggles: eight edges, the first (rising) 110 ns after the READ's CK edge, 10 ns apart;
//                          DQ carries beat b from 1 ns after edge b: the byte of column (c + b) mod 8 of the aligned 8
//     R+5  postamble       DQS driven low
//     every other cycle    DQS and DQ high-Z
// and the DUT's side, which is what this design is responsible for:
//     - its READ window (`read_active_final`) must overlap the burst's cycles,
//     - it must report exactly one `read_data_valid` per READ,
//     - the byte it returns must be beat 0's, not beat 4's, and
//     - `read_burst`, two cycles later, must hold all eight beats in order (lane 0's byte; this test is about lane 0).
// Beats 0 and 4 are given different data on purpose, and the rest of the block is never written (it reads 00). A capture
// one cycle late reads beat 4 instead of beat 0, which would be indistinguishable if both held the same byte; a capture that
// drops a phase or reverses the four of a cycle moves a nonzero byte to a place that should hold 00.
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

    wire        ddr3_ck;
    wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [14:0] ddr3_a;
    wire        ddr3_cke, ddr3_odt;
    wire        ddr3_reset_n = ~rst;   // the board: the DRAM's RESET# is the system reset's complement (Part 27)
    wire [7:0]  ddr3_dq;
    wire        ddr3_dqs;
    wire        ddr3_dm;   // Part 22
    wire [7:0]  ddr3_dqu;
    wire        ddr3_udqs;
    wire        ddr3_udm;

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
    wire [7:0]  read_data_hi;   // lane 1's byte (Part 26); this test is about lane 0
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
        .write_wide(1'b0), .write_burst(128'b0), .write_burst_be(16'b0),
        .write_req(write_req), .write_bank(write_bank), .write_row(write_row),
        .write_col(write_col), .write_data({8'h00, write_data}), .write_be(2'b01), .write_busy(write_busy),
        .read_req(read_req), .read_bank(read_bank), .read_row(read_row), .read_col(read_col),
        .read_busy(read_busy), .read_data({read_data_hi, read_data}), .read_data_valid(read_data_valid),
        .read_burst(read_burst), .read_burst_valid(read_burst_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked),
        .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    // Lane 1's memory (Part 26): the controller takes no request until both lanes have calibrated, and a
    // lane calibrates by looping its pattern back through a DRAM. This test is about lane 0.
    ddr3_lane1_mem LANE1 (
        .sclk(DUT.sclk), .rst(DUT.rst_all), .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dqu(ddr3_dqu), .udqs(ddr3_udqs), .udm(ddr3_udm),
        .read_active(DUT.read_active_final_1), .dq_error()
    );


    wire        dq_error;
    wire [511:0] dq_error_msg;
    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_oe, mem_dqs_o;
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

    // ---- an independent monitor of the pins and the DUT's read window ----
    integer cyc = 0;
    reg [1:0]  dqs_log  [0:LOG-1];   // DQS at the sclk edge ending the cycle: 0 low, 1 high, 2 high-Z, 3 unknown
    reg        ract_log [0:LOG-1];   // the DUT's READ window
    reg        rdv_log  [0:LOG-1];   // read_data_valid
    reg [7:0]  rd_log   [0:LOG-1];   // read_data when it pulsed
    reg        rbv_log  [0:LOG-1];   // read_burst_valid
    reg [63:0] rb_log   [0:LOG-1];   // lane 0's byte of each of the eight beats of read_burst
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
            ract_log[cyc % LOG] = DUT.read_active_final;
            rdv_log [cyc % LOG] = read_data_valid;
            rd_log  [cyc % LOG] = read_data;
            rbv_log [cyc % LOG] = read_burst_valid;
            rb_log  [cyc % LOG] = {read_burst[119:112], read_burst[103:96], read_burst[87:80], read_burst[71:64],
                                   read_burst[55:48],   read_burst[39:32],  read_burst[23:16],  read_burst[7:0]};
            cyc = cyc + 1;
        end
    end

    // The strobe's edges, with the DQ byte 5 ns after each (the middle of the beat): only transitions between two driven
    // levels count, so the preamble's start and the postamble's end, which are to and from high-Z, are not edges.
    localparam EMAX = 8192;
    real       edge_t   [0:EMAX-1];
    reg        edge_v   [0:EMAX-1];   // the level after the edge
    reg [7:0]  edge_dq  [0:EMAX-1];
    reg        edge_bad [0:EMAX-1];   // some DQ bit was z or x then
    integer    ne = 0;
    reg [1:0]  cls_prev = 2'd2;
    always @(probe_dqs_class) begin
        if (!rst && probe_dqs_class <= 2'd1 && cls_prev <= 2'd1 && probe_dqs_class != cls_prev && ne < EMAX) begin
            edge_t[ne] = $realtime;
            edge_v[ne] = probe_dqs_class[0];
            #5;
            edge_dq[ne]  = probe_dq_value;
            edge_bad[ne] = probe_dq_bad;
            ne = ne + 1;
        end
        cls_prev = probe_dqs_class;
    end

    integer rd_n = 0;
    integer rd_cyc [0:NALL-1];
    real    rd_t   [0:NALL-1];
    always @(posedge ddr3_ck) begin
        if (!rst && calib_done && ddr3_ras_n && !ddr3_cas_n && ddr3_we_n && rd_n < NALL) begin
            rd_cyc[rd_n] = cyc;
            rd_t[rd_n]   = $realtime;
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

    // the byte beat k of read w carries: reads 0 to 7 wrote beats 0 and 4 and nothing else of their block, read 8 wrote beat 0
    // only, read 9 wrote nothing (beat 0 is then unknown: the model's choice, so that a stale read cannot pass as a hit)
    function [7:0] want_beat(input integer w, input integer k);
        begin
            if (w < NREADS)       want_beat = (k == 0) ? beat0[w] : (k == 4) ? beat4[w] : 8'h00;
            else if (w == NREADS) want_beat = (k == 0) ? 8'h6E : 8'h00;
            else                  want_beat = (k == 0) ? 8'hxx : 8'h00;
        end
    endfunction

    // Walk the strobe edges that fall in read w's burst window (100 to 260 ns after its READ): count them, and check the first
    // eight for time (110 + 10 n ns, within half a ns), polarity (rising first) and the byte on DQ 5 ns after the edge.
    // sc_bad is the number of those checks that failed; first_e is the index of the first edge.
    integer pin_fails;
    integer sc_n, sc_bad, sc_e, first_e;
    task scan_beats(input integer w);
        begin
            sc_n = 0; sc_bad = 0; first_e = -1;
            for (sc_e = 0; sc_e < ne; sc_e = sc_e + 1) begin
                if (edge_t[sc_e] >= rd_t[w] + 100.0 && edge_t[sc_e] <= rd_t[w] + 260.0) begin
                    if (first_e < 0) first_e = sc_e;
                    if (sc_n < 8) begin
                        if (edge_t[sc_e] < rd_t[w] + 110.0 + 10.0 * sc_n - 0.5 ||
                            edge_t[sc_e] > rd_t[w] + 110.0 + 10.0 * sc_n + 0.5) begin
                            if (pin_fails + sc_bad < 8)
                                $display("  FAIL read %0d: strobe edge %0d is %0.2f ns after the READ, expected %0d",
                                         w, sc_n, edge_t[sc_e] - rd_t[w], 110 + 10 * sc_n);
                            sc_bad = sc_bad + 1;
                        end
                        if (edge_v[sc_e] !== ((sc_n % 2) == 0)) begin
                            if (pin_fails + sc_bad < 8)
                                $display("  FAIL read %0d: strobe edge %0d goes %0d, expected %0d", w, sc_n, edge_v[sc_e], (sc_n % 2) == 0);
                            sc_bad = sc_bad + 1;
                        end
                        if (w == NREADS + 1 && sc_n == 0) begin
                            // beat 0 of a never-written cell: unknown, judged separately below (Icarus only)
                        end else if (edge_bad[sc_e] || edge_dq[sc_e] !== want_beat(w, sc_n)) begin
                            if (pin_fails + sc_bad < 8)
                                $display("  FAIL read %0d: DQ in beat %0d is %02h, expected %02h", w, sc_n, edge_dq[sc_e], want_beat(w, sc_n));
                            sc_bad = sc_bad + 1;
                        end
                    end
                    sc_n = sc_n + 1;
                end
            end
        end
    endtask

    integer i, k, w, guard, dqs_fails, cap_fails, unw_fails, burst_fails, ov;
    integer rdv_count, rdv_at, rbv_count, rbv_at;
    reg [1:0] want_dqs;
    initial begin
        $display("=== DDR3 read burst window vs READ latency (Phase 9 Stage 1, Part 18) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!calib_done && !calib_error && $time < 900_000) @(posedge clk);
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

        // ---- the DRAM's side: the strobe's edges and the beat on DQ in the middle of each ----
        pin_fails = 0; dqs_fails = 0; cap_fails = 0; unw_fails = 0; burst_fails = 0;
        for (w = 0; w < NALL; w = w + 1) begin
            scan_beats(w);
            if (sc_n != 8) begin
                if (pin_fails < 8) $display("  FAIL read %0d: %0d strobe edges in the burst's window, expected 8", w, sc_n);
                sc_bad = sc_bad + 1;
            end
            pin_fails = pin_fails + sc_bad;
            // DQS at the end of each sclk cycle: driven low from the preamble to the postamble, high-Z otherwise
            for (k = 0; k <= 7; k = k + 1) begin
                want_dqs = (k >= 2 && k <= 5) ? 2'd0 : 2'd2;
`ifdef VERILATOR
                // a floating DQS reads as low here (see tb_ddr3_wr_window.v)
                if (dqs_log[(rd_cyc[w] + k) % LOG] !== want_dqs &&
                    !(want_dqs == 2'd2 && dqs_log[(rd_cyc[w] + k) % LOG] == 2'd0)) begin
`else
                if (dqs_log[(rd_cyc[w] + k) % LOG] !== want_dqs) begin
`endif
                    if (dqs_fails < 8)
                        $display("  FAIL read %0d: R+%0d DQS is %0d at the cycle's end, expected %0d", w, k, dqs_log[(rd_cyc[w] + k) % LOG], want_dqs);
                    dqs_fails = dqs_fails + 1;
                end
            end
        end

        // ---- the DUT's side ----
        for (w = 0; w <= NREADS; w = w + 1) begin
            ov = 0; rdv_count = 0; rdv_at = -1; rbv_count = 0; rbv_at = -1;
            for (k = 0; k <= 9; k = k + 1) begin
                if (ract_log[(rd_cyc[w] + k) % LOG] && (k == 3 || k == 4)) ov = ov + 1;
                if (rdv_log[(rd_cyc[w] + k) % LOG]) begin rdv_count = rdv_count + 1; if (rdv_at < 0) rdv_at = k; end
                if (rbv_log[(rd_cyc[w] + k) % LOG]) begin rbv_count = rbv_count + 1; if (rbv_at < 0) rbv_at = k; end
            end
            if (ov == 0) begin
                if (cap_fails < 8) $display("  FAIL read %0d: the DUT's READ window never overlapped the burst (R+3, R+4)", w);
                cap_fails = cap_fails + 1;
            end
            if (rdv_count != 1) begin
                if (cap_fails < 8) $display("  FAIL read %0d: read_data_valid pulsed %0d times, expected once", w, rdv_count);
                cap_fails = cap_fails + 1;
            end else begin
                if (w == 0) $display("  measured: read_data_valid at R+%0d", rdv_at);
                if (rd_log[(rd_cyc[w] + rdv_at) % LOG] !== want_beat(w, 0)) begin
                    if (cap_fails < 8)
                        $display("  FAIL read %0d: the DUT returned %02h, expected beat 0 (%02h) - beat 4 is %02h",
                                 w, rd_log[(rd_cyc[w] + rdv_at) % LOG], want_beat(w, 0), want_beat(w, 4));
                    cap_fails = cap_fails + 1;
                end
                if (rdv_at != READ_VALID_AT) begin
                    if (cap_fails < 8)
                        $display("  FAIL read %0d: read_data_valid at R+%0d, expected R+%0d", w, rdv_at, READ_VALID_AT);
                    cap_fails = cap_fails + 1;
                end
            end
            // the whole burst, two cycles after read_data_valid, once, with the eight beats in order
            if (rbv_count != 1) begin
                if (burst_fails < 8) $display("  FAIL read %0d: read_burst_valid pulsed %0d times, expected once", w, rbv_count);
                burst_fails = burst_fails + 1;
            end else begin
                if (w == 0) $display("  measured: read_burst_valid at R+%0d", rbv_at);
                if (rbv_at != READ_VALID_AT + 2) begin
                    if (burst_fails < 8) $display("  FAIL read %0d: read_burst_valid at R+%0d, expected R+%0d", w, rbv_at, READ_VALID_AT + 2);
                    burst_fails = burst_fails + 1;
                end
                for (k = 0; k < 8; k = k + 1) begin
                    if (rb_log[(rd_cyc[w] + rbv_at) % LOG][8 * k +: 8] !== want_beat(w, k)) begin
                        if (burst_fails < 8)
                            $display("  FAIL read %0d: read_burst beat %0d is %02h, expected %02h", w, k,
                                     rb_log[(rd_cyc[w] + rbv_at) % LOG][8 * k +: 8], want_beat(w, k));
                        burst_fails = burst_fails + 1;
                    end
                end
            end
        end

        // ---- the two reads of cells that are not fully written ----
        // 8: beat 0 is the byte written, and every other column of the block - never written - reads 00 (checked in the
        //    edge scan above, with the other reads)
        // 9: the addressed cell was never written - the DRAM drives DQ, but with no known value
`ifndef VERILATOR
        // (Icarus only: a two-state simulator has no unknown value to return, so this check
        // cannot be made under Verilator - see the note in the Makefile at verilator_ddr3.)
        scan_beats(NREADS + 1);
        if (sc_n == 8 && !edge_bad[first_e]) begin
            $display("  FAIL read %0d: a never-written cell returned %02h, expected unknown (xx)", NREADS + 1, edge_dq[first_e]);
            unw_fails = unw_fails + 1;
        end
`endif

        check_true("every read: DQS driven low from the preamble (R+2) to the postamble (R+5), high-Z otherwise", dqs_fails == 0);
        check_true("every read: eight strobe edges, rising first, 110 ns after the READ and 10 ns apart, each with its beat's byte", pin_fails == 0);
        check_true("the DUT's READ window overlaps the burst, valid once, returns beat 0 (not beat 4)", cap_fails == 0);
        check_true("read_burst: once, two cycles after read_data_valid, the eight beats in order", burst_fails == 0);
        check_true("a never-written cell reads as unknown, not as a byte", unw_fails == 0);
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
