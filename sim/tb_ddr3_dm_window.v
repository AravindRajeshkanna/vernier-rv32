// Test for Phase 9 Stage 1, Part 22 (docs/roadmap.md): the data-mask (DM) waveform
// relative to a WRITE, from the real pin, and the correctness question DM exists to
// answer - does an unmasked byte actually stay out of the column next to it.
//
// Through Part 21 this design drove no `ddr3_dm` pin at all, and sim/ddr3_dq_model.v
// never modeled the write burst's second sclk-visible half touching a column either -
// so nothing could show whether a real BL8 write, left unmasked, would silently
// overwrite a real neighbour column with the same byte. `rtl/soc/ddr3_dm_drv_ecp5.v`
// now drives DM; this test pins its waveform down and then asks the real question.
//
// For a WRITE driven in sclk cycle W (Part 17's own timing, unchanged):
//     W+2  preamble        DM high (masked)
//     W+3  burst, half 1   DM low  (write it - the addressed column)
//     W+4  burst, half 2   DM high (masked - the neighbour column this design never
//                                    intends to touch)
//     W+5  postamble       DM high
//     every other cycle    DM high (the safe idle default)
`timescale 1ns/1ps
module tb_ddr3_dm_window;
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
    wire        ddr3_dm;

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
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
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

    // ---- an independent monitor of the DM pin ----
    // DM is a plain, always-driven output (no tri-state - rtl/soc/ddr3_dm_drv_ecp5.v's
    // own header says why), so a direct sample is enough; no probe module needed the
    // way the tri-stated DQ/DQS pins in tb_ddr3_wr_window.v need one.
    integer cyc = 0;
    reg dm_log [0:LOG-1];
    always @(posedge DUT.sclk) begin
        if (!rst) begin
            dm_log[cyc % LOG] = ddr3_dm;
            cyc = cyc + 1;
        end
    end

    integer wr_n = 0;
    integer wr_cyc [0:NWRITES-1];
    always @(posedge ddr3_ck) begin
        if (!rst && calib_done && !ddr3_cs_n && ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n && wr_n < NWRITES) begin
            wr_cyc[wr_n] = cyc;
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

    // Two locations four columns apart (an aligned-8 pair, the same wrap the write
    // burst's second half lands on), each written with its OWN test to keep the
    // neighbour-protection check honest: if the design ever failed to mask that
    // second half, the earlier write's byte would appear here even though this
    // location itself was never addressed.
    localparam [2:0]  NB_BANK = 3'd4;
    localparam [15:0] NB_ROW  = 16'h0222;
    localparam [15:0] NB_COL  = 16'h0033;   // col[2:0] = 3'b011; the neighbour is col ^ 4 = ...111

    integer i, k, w, dm_fails, guard;
    reg wanted_dm;
    initial begin
        $display("=== DDR3 data mask (DM) window and neighbour-column protection (Phase 9 Stage 1, Part 22) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check_true("calibration completed before this test begins", calib_done && !calib_error);

        // eight writes, different banks, bytes and gaps - the DM waveform must hold for
        // all of them, not just the first
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
            repeat (i * 3) @(posedge clk);
        end
        repeat (10) @(posedge clk);

        check_true("all eight WRITE commands were seen on the real command pins", wr_n == NWRITES);

        dm_fails = 0;
        for (w = 0; w < NWRITES; w = w + 1) begin
            for (k = 0; k <= 7; k = k + 1) begin
                wanted_dm = (k == 3) ? 1'b0 : 1'b1;   // low only in the first burst half (W+3)
                if (dm_log[(wr_cyc[w] + k) % LOG] !== wanted_dm) begin
                    if (dm_fails < 8)
                        $display("  FAIL write %0d: DM at W+%0d is %b, expected %b", w, k, dm_log[(wr_cyc[w] + k) % LOG], wanted_dm);
                    dm_fails = dm_fails + 1;
                end
            end
        end
        check_true("every write: DM low only in the burst's first half (W+3), high everywhere else", dm_fails == 0);

        // ---- does DM actually protect the neighbour column? ----
        // Write once to the neighbour column itself, with a byte the intended-write check
        // below does not use, so a leak would be unmistakable.
        write_bank <= NB_BANK; write_row <= NB_ROW; write_col <= (NB_COL ^ 16'h0004); write_data <= 8'h5A;
        @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; @(posedge clk);
        guard = 0; while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
        check_true("the neighbour column itself accepts a write (sanity: the model can store there)",
                    MEM.peek(NB_BANK, NB_ROW, NB_COL ^ 16'h0004) === 8'h5A);

        // Now write the ADDRESSED column, a different byte, and confirm the neighbour
        // written above is untouched by THIS write's own burst.
        write_bank <= NB_BANK; write_row <= NB_ROW; write_col <= NB_COL; write_data <= 8'hC3;
        @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; @(posedge clk);
        guard = 0; while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
        repeat (10) @(posedge clk);

        check_true("the addressed column holds the byte this write sent",
                    MEM.peek(NB_BANK, NB_ROW, NB_COL) === 8'hC3);
        check_true("the neighbour column - written earlier, four columns off - is unchanged by this write: DM protected it",
                    MEM.peek(NB_BANK, NB_ROW, NB_COL ^ 16'h0004) === 8'h5A);
        check_true("no DQ/DQS/DM timing error across any of the above", !dq_error);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 DATA MASK TEST PASSED");
        else             $display("DDR3 DATA MASK TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
