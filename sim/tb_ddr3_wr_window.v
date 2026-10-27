// Test for Phase 9 Stage 1, Part 17 (docs/roadmap/phase-09-ddr.md): where a write burst
// lands relative to its WRITE command, judged from the real DQ and DQS pins by
// a monitor that shares nothing with sim/ddr3_dq_model.v's own checker.
//
// The Part 14/15 survey measured that DQ was enabled for one cycle, one cycle
// before DQS was enabled and two before its first active toggle, so the eight
// beats of a BL8 burst saw no DQ enable. Every test passed, because the memory
// model stored an internal tap and never compared DQ against DQS. With the
// pin-based checker in place the same design could not even complete
// calibration (its test-pattern write never reached the memory). This test
// pins the corrected timing down in numbers.
//
// For a WRITE driven in sclk cycle W (Part 16: commands sit in the first of the
// two command slots per sclk) the datasheet's write latency is WL = CWL = 6 CK
// = 3 sclk, so the first DQS rising edge falls 10 ns into cycle W+3:
//     W+2  preamble        DQS driven low
//     W+3  burst, half 1   DQS toggling (low, high, low, high), DQ driven: beats 0 to 3
//     W+4  burst, half 2   DQS toggling the same way, DQ driven: beats 4 to 7
//     W+5  postamble       DQS driven low
//     every other cycle    DQS high-Z
// Several writes with different bytes, banks and gaps, so a timing that only
// held for the first one, or only for one data value, would not pass.
//
// Phase 9 Stage 3: judged at beat resolution. Until then this sampled the pins once per sclk cycle, at its end, and the
// strobe was one level per cycle; now it toggles every 10 ns, and a once-per-cycle sample sees only the last of its four
// unit intervals (it would still have passed for a strobe that stayed high). The monitor samples DQS in the middle of each
// of the four 10 ns slots of a cycle, and DQ at each strobe edge (10 ns, 20 ns, 30 ns and 40 ns after the sclk edge), which
// is the middle of each beat: beat b of a burst is DQ at W+3's start + 10 (b + 1) ns. Checked: the strobe's four slots in
// every cycle of the window, DQ driven at all eight beats, and the byte at beat 0 (beats 1 to 7 are masked by DM; the DM
// test, sim/tb_ddr3_dm_window.v, looks at the mask).
`timescale 1ns/1ps
module tb_ddr3_wr_window;
    localparam CLK_PERIOD = 40;   // 25 MHz sclk
    localparam NWRITES    = 8;
    localparam LOG        = 4096;

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
    wire        write_busy, read_busy, read_data_valid, refresh_busy;
    wire [7:0]  read_data;
    wire [7:0]  read_data_hi;   // lane 1's byte (Part 26); this test is about lane 0

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
        .read_req(1'b0), .read_bank(3'b0), .read_row(16'b0), .read_col(16'b0),
        .read_busy(read_busy), .read_data({read_data_hi, read_data}), .read_data_valid(read_data_valid),
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

    // ---- an independent pin monitor, at beat resolution ----
    // `ncyc` counts sclk edges; the cycle an edge opens is numbered by the count before it. DQS is sampled in the middle of
    // each of the cycle's four 10 ns slots (5, 15, 25 and 35 ns after the edge), DQ at each strobe edge (10, 20, 30 and 40 ns
    // after it): slot j of cycle c is dqs_ui[4c + j], and the beat the strobe edge at (c, j) closes is dq_ui[4c + j].
    integer ncyc = 0;
    reg [1:0]  dqs_ui [0:LOG*4-1];   // 0 low, 1 high, 2 high-Z, 3 unknown
    reg        dqz_ui [0:LOG*4-1];   // DQ has a bit that is z or x
    reg [7:0]  dq_ui  [0:LOG*4-1];
    // The pins are read through sim/pin_probe.v's inout ports so that a floating strobe
    // reads as high-Z under Verilator as well as under Icarus (see that file).
    wire [1:0] probe_dqs_class;
    wire       probe_dq_bad;
    wire [7:0] probe_dq_value;
    pin_probe PROBE (.dqs(ddr3_dqs), .dq(ddr3_dq), .dqs_class(probe_dqs_class),
                     .dq_bad(probe_dq_bad), .dq_value(probe_dq_value));
    integer mc;
    // The sampling takes 35 ns of the 40: a sequence that took the whole period would still be running at the next edge and
    // miss it. Beat 3 of a cycle closes at the next cycle's edge, so it is taken first thing there.
    always @(posedge DUT.sclk) begin
        if (!rst) begin
            if (ncyc > 0) begin
                dqz_ui[((ncyc - 1) * 4 + 3) % (LOG * 4)] = probe_dq_bad; dq_ui[((ncyc - 1) * 4 + 3) % (LOG * 4)] = probe_dq_value;
            end
            mc = ncyc;
            ncyc = ncyc + 1;
            #5;  dqs_ui[(mc * 4 + 0) % (LOG * 4)] = probe_dqs_class;
            #5;  dqz_ui[(mc * 4 + 0) % (LOG * 4)] = probe_dq_bad; dq_ui[(mc * 4 + 0) % (LOG * 4)] = probe_dq_value;
            #5;  dqs_ui[(mc * 4 + 1) % (LOG * 4)] = probe_dqs_class;
            #5;  dqz_ui[(mc * 4 + 1) % (LOG * 4)] = probe_dq_bad; dq_ui[(mc * 4 + 1) % (LOG * 4)] = probe_dq_value;
            #5;  dqs_ui[(mc * 4 + 2) % (LOG * 4)] = probe_dqs_class;
            #5;  dqz_ui[(mc * 4 + 2) % (LOG * 4)] = probe_dq_bad; dq_ui[(mc * 4 + 2) % (LOG * 4)] = probe_dq_value;
            #5;  dqs_ui[(mc * 4 + 3) % (LOG * 4)] = probe_dqs_class;
        end
    end

    // Every WRITE, timestamped in the sclk cycle it was sampled in.
    integer wr_n = 0;
    integer wr_cyc [0:NWRITES-1];
    reg [7:0] wr_byte [0:NWRITES-1];
    always @(posedge ddr3_ck) begin
        if (!rst && calib_done && ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n && wr_n < NWRITES) begin
            wr_cyc[wr_n] = ncyc - 1;    // the cycle the sclk edge ten ns ago opened
            wr_byte[wr_n] = write_data;
            wr_n = wr_n + 1;
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

    integer i, k, u, w, dqs_fails, dq_fails, guard;
    reg [1:0] want_dqs;
    initial begin
        $display("=== DDR3 write burst window vs WRITE latency (Phase 9 Stage 1, Part 17) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!calib_done && !calib_error && $time < 900_000) @(posedge clk);
        check_true("calibration completed before this test begins", calib_done && !calib_error);

        // eight writes, different banks and bytes, different gaps between them
        for (i = 0; i < NWRITES; i = i + 1) begin
            write_bank <= i[2:0];
            write_row  <= 16'h0100 + i;
            write_col  <= 16'h0008 * i;
            write_data <= 8'h11 + 8'h2D * i;
            @(posedge clk);
            write_req <= 1'b1;
            @(posedge clk);
            write_req <= 1'b0;
            @(posedge clk);
            guard = 0;
            while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
            repeat (i * 3) @(posedge clk);      // vary the gap
        end
        repeat (10) @(posedge clk);

        check_true("all eight WRITE commands were seen on the real command pins", wr_n == NWRITES);

        dqs_fails = 0; dq_fails = 0;
        for (w = 0; w < NWRITES; w = w + 1) begin
            for (k = 0; k <= 7; k = k + 1) begin
                for (u = 0; u < 4; u = u + 1) begin
                    // what the DRAM requires in each slot of each cycle relative to the WRITE
                    case (k)
                        2:       want_dqs = 2'd0;                           // preamble: driven low
                        3, 4:    want_dqs = (u % 2 == 1) ? 2'd1 : 2'd0;     // the two burst cycles: low, high, low, high
                        5:       want_dqs = 2'd0;                           // postamble: driven low
                        default: want_dqs = 2'd2;                           // otherwise high-Z
                    endcase
                    // Under Verilator a floating DQS reads as low (a two-state simulator has no z on a
                    // net two modules drive), so "high-Z" is checked as "not active" there. Icarus
                    // keeps the strict check; see verilator_ddr3 in the Makefile.
`ifdef VERILATOR
                    if (dqs_ui[((wr_cyc[w] + k) * 4 + u) % (LOG * 4)] !== want_dqs &&
                        !(want_dqs == 2'd2 && dqs_ui[((wr_cyc[w] + k) * 4 + u) % (LOG * 4)] == 2'd0)) begin
`else
                    if (dqs_ui[((wr_cyc[w] + k) * 4 + u) % (LOG * 4)] !== want_dqs) begin
`endif
                        if (dqs_fails < 8)
                            $display("  FAIL write %0d: W+%0d slot %0d DQS is %0d, expected %0d (0 low, 1 high, 2 high-Z)",
                                     w, k, u, dqs_ui[((wr_cyc[w] + k) * 4 + u) % (LOG * 4)], want_dqs);
                        dqs_fails = dqs_fails + 1;
                    end
                end
            end
            // DQ at the eight strobe edges of the burst: beat b closes at W+3's start + 10 (b + 1) ns
            for (k = 0; k < 8; k = k + 1) begin
                if (dqz_ui[((wr_cyc[w] + 3) * 4 + k) % (LOG * 4)]) begin
                    if (dq_fails < 8) $display("  FAIL write %0d: DQ not driven at beat %0d", w, k);
                    dq_fails = dq_fails + 1;
                end else if (k == 0 && dq_ui[((wr_cyc[w] + 3) * 4 + k) % (LOG * 4)] !== wr_byte[w]) begin
                    if (dq_fails < 8)
                        $display("  FAIL write %0d: DQ at beat 0 is %02h, expected the requested byte %02h",
                                 w, dq_ui[((wr_cyc[w] + 3) * 4 + k) % (LOG * 4)], wr_byte[w]);
                    dq_fails = dq_fails + 1;
                end
            end
        end

        check_true("every write: DQS low at W+2, toggling at W+3 and W+4, low at W+5, high-Z otherwise", dqs_fails == 0);
        check_true("every write: DQ driven at all eight beats, beat 0 the requested byte", dq_fails == 0);
        check_true("the memory model, judging from the same pins, agrees (no DQ/DQS timing error)", !dq_error);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 WRITE WINDOW TEST PASSED");
        else             $display("DDR3 WRITE WINDOW TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
