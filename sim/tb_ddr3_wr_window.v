// Test for Phase 9 Stage 1, Part 17 (docs/roadmap.md): where a write burst
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
//     W+3  burst, half 1   DQS active, DQ driven with the byte
//     W+4  burst, half 2   DQS active, DQ driven with the byte
//     W+5  postamble       DQS driven low
//     every other cycle    DQS high-Z
// Several writes with different bytes, banks and gaps, so a timing that only
// held for the first one, or only for one data value, would not pass.
`timescale 1ns/1ps
module tb_ddr3_wr_window;
    localparam CLK_PERIOD = 40;   // 25 MHz sclk
    localparam NWRITES    = 8;
    localparam LOG        = 4096;

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
    reg  [2:0]  write_bank = 3'd0;
    reg  [15:0] write_row  = 16'h0000;
    reg  [15:0] write_col  = 16'h0000;
    reg  [7:0]  write_data = 8'h00;
    wire        write_busy, read_busy, read_data_valid, refresh_busy;
    wire [7:0]  read_data;

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
        .read_req(1'b0), .read_bank(3'b0), .read_row(16'b0), .read_col(16'b0),
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
    wire       mem_dq_oe, mem_dqs_o;
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

    // ---- an independent pin monitor ----
    // One record per sclk cycle: what DQS and DQ were doing in it. `cyc` counts sclk
    // edges; a value sampled at an edge is what the cycle that just ended held.
    integer cyc = 0;
    reg [1:0]  dqs_log [0:LOG-1];   // 0 low, 1 high, 2 high-Z, 3 unknown
    reg        dqz_log [0:LOG-1];   // DQ has a bit that is z or x
    reg [7:0]  dq_log  [0:LOG-1];
    always @(posedge DUT.sclk) begin
        if (!rst) begin
            dqs_log[cyc % LOG] = (ddr3_dqs === 1'b0) ? 2'd0 : (ddr3_dqs === 1'b1) ? 2'd1 :
                                 (ddr3_dqs === 1'bz) ? 2'd2 : 2'd3;
            dqz_log[cyc % LOG] = ((^ddr3_dq) === 1'bx);
            dq_log [cyc % LOG] = ddr3_dq;
            cyc = cyc + 1;
        end
    end

    // Every WRITE, timestamped in the sclk cycle it was sampled in.
    integer wr_n = 0;
    integer wr_cyc [0:NWRITES-1];
    reg [7:0] wr_byte [0:NWRITES-1];
    always @(posedge ddr3_ck) begin
        if (!rst && calib_done && !ddr3_cs_n && ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n && wr_n < NWRITES) begin
            wr_cyc[wr_n] = cyc;         // cyc already counts the edge that opened this cycle
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

    integer i, k, w, dqs_fails, dq_fails, guard;
    reg [1:0] want_dqs;
    initial begin
        $display("=== DDR3 write burst window vs WRITE latency (Phase 9 Stage 1, Part 17) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
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
                // what the DRAM requires in each cycle relative to the WRITE
                case (k)
                    2:       want_dqs = 2'd0;    // preamble: driven low
                    3, 4:    want_dqs = 2'd1;    // the two burst cycles: DQS active
                    5:       want_dqs = 2'd0;    // postamble: driven low
                    default: want_dqs = 2'd2;    // otherwise high-Z
                endcase
                if (dqs_log[(wr_cyc[w] + k) % LOG] !== want_dqs) begin
                    if (dqs_fails < 8)
                        $display("  FAIL write %0d: W+%0d DQS is %0d, expected %0d (0 low, 1 high, 2 high-Z)",
                                 w, k, dqs_log[(wr_cyc[w] + k) % LOG], want_dqs);
                    dqs_fails = dqs_fails + 1;
                end
            end
            for (k = 3; k <= 4; k = k + 1) begin
                if (dqz_log[(wr_cyc[w] + k) % LOG]) begin
                    if (dq_fails < 8) $display("  FAIL write %0d: DQ not driven in burst cycle W+%0d", w, k);
                    dq_fails = dq_fails + 1;
                end else if (dq_log[(wr_cyc[w] + k) % LOG] !== wr_byte[w]) begin
                    if (dq_fails < 8)
                        $display("  FAIL write %0d: DQ in W+%0d is %02h, expected the requested byte %02h",
                                 w, k, dq_log[(wr_cyc[w] + k) % LOG], wr_byte[w]);
                    dq_fails = dq_fails + 1;
                end
            end
        end

        check_true("every write: DQS low at W+2, active at W+3 and W+4, low at W+5, high-Z otherwise", dqs_fails == 0);
        check_true("every write: DQ driven with the requested byte in both burst cycles", dq_fails == 0);
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
