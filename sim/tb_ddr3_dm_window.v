// Test for Phase 9 Stage 1, Part 22 (docs/roadmap/phase-09-ddr.md): the data-mask (DM) waveform
// relative to a WRITE, from the real pin, and the correctness question DM exists to
// answer - does an unmasked byte actually stay out of the column next to it.
//
// Through Part 21 this design drove no `ddr3_dm` pin at all, and sim/ddr3_dq_model.v
// never modeled the write burst's second sclk-visible half touching a column either -
// so nothing could show whether a real BL8 write, left unmasked, would silently
// overwrite a real neighbour column with the same byte. `rtl/soc/ddr3_dm_drv_ecp5.v`
// now drives DM; this test pins its waveform down and then asks the real question.
//
// For a WRITE driven in sclk cycle W (Part 17's own timing, unchanged), DM at each strobe edge:
//     W+3  beat 0          DM low  (write it - the addressed column)
//     every other beat of the burst (beats 1 to 7), and everywhere outside it: DM high (masked)
//
// Phase 9 Stage 3: judged at beat resolution. Until then DM was one level per sclk cycle and "low in W+3" meant four
// beats, which on a real part writes the byte to four columns; the test could not see it, and its neighbour check looked
// at one neighbour (the column four on). DM is now sampled at each strobe edge, 10, 20, 30 and 40 ns after every sclk edge,
// and the neighbour check covers every other column of the aligned block of 8 the burst belongs to: each is given a
// sentinel byte first, and none may change.
`timescale 1ns/1ps
module tb_ddr3_dm_window;
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
    wire        ddr3_dm;
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
    wire [7:0]  write_data_hi = ~write_data;   // lane 1's byte: the complement of lane 0's, so the lanes cannot be taken for each other
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
        .write_col(write_col), .write_data({write_data_hi, write_data}), .write_be(2'b11), .write_busy(write_busy),
        .read_req(1'b0), .read_bank(3'b0), .read_row(16'b0), .read_col(16'b0),
        .read_busy(read_busy), .read_data({read_data_hi, read_data}), .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked),
        .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    // Lane 1's memory (Part 26): the controller takes no request until both lanes have calibrated, and a
    // lane calibrates by looping its pattern back through a DRAM. Since Phase 9 Stage 3 this test looks at both lanes:
    // each write stores both bytes, and each lane's mask and neighbour protection are judged on its own.
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

    // ---- an independent monitor of the DM pin ----
    // DM is a plain, always-driven output (no tri-state - rtl/soc/ddr3_dm_drv_ecp5.v's
    // own header says why), so a direct sample is enough; no probe module needed the
    // way the tri-stated DQ/DQS pins in tb_ddr3_wr_window.v need one.
    // `ncyc` counts sclk edges, the cycle an edge opens is numbered by the count before it, and DM is sampled at 10, 20, 30
    // and 40 ns after the edge: dm_ui[4c + j] is DM at the strobe edge ending slot j of cycle c, which is beat j of a burst
    // that starts in cycle c. (The 40 ns one is taken at the next edge, so the sampling sequence never runs into it.)
    integer ncyc = 0;
    reg dm_ui  [0:LOG*4-1];     // lane 0's DM
    reg udm_ui [0:LOG*4-1];     // lane 1's DM
    integer mc;
    always @(posedge DUT.sclk) begin
        if (!rst) begin
            if (ncyc > 0) begin
                dm_ui [((ncyc - 1) * 4 + 3) % (LOG * 4)] = ddr3_dm;
                udm_ui[((ncyc - 1) * 4 + 3) % (LOG * 4)] = ddr3_udm;
            end
            mc = ncyc;
            ncyc = ncyc + 1;
            #10; dm_ui[(mc * 4 + 0) % (LOG * 4)] = ddr3_dm;  udm_ui[(mc * 4 + 0) % (LOG * 4)] = ddr3_udm;
            #10; dm_ui[(mc * 4 + 1) % (LOG * 4)] = ddr3_dm;  udm_ui[(mc * 4 + 1) % (LOG * 4)] = ddr3_udm;
            #10; dm_ui[(mc * 4 + 2) % (LOG * 4)] = ddr3_dm;  udm_ui[(mc * 4 + 2) % (LOG * 4)] = ddr3_udm;
        end
    end

    integer wr_n = 0;
    integer wr_cyc [0:NWRITES-1];
    always @(posedge ddr3_ck) begin
        if (!rst && calib_done && ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n && wr_n < NWRITES) begin
            wr_cyc[wr_n] = ncyc - 1;    // the cycle the sclk edge ten ns ago opened
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

    // One aligned block of 8 columns: seven of them are given a sentinel byte, then the eighth is written. If the design ever
    // left DM low for a beat other than beat 0 - the first, as the old model's "second half" or the four beats of a cycle -
    // a sentinel would change, because a real burst writes sequential columns from the addressed one, wrapping inside the block.
    localparam [2:0]  NB_BANK = 3'd4;
    localparam [15:0] NB_ROW  = 16'h0222;
    localparam [15:0] NB_BASE = 16'h0030;   // the block: columns 0x30 to 0x37
    localparam integer NB_TGT = 3;          // the one the final write addresses: column 0x33

    // lane 1's sentinel for column n of the block: the complement of lane 0's, as an 8-bit value
    function [7:0] sent1(input integer n);
        sent1 = ~(8'h50 + n[7:0]);
    endfunction
    integer i, k, u, w, n, dm_fails, guard;
    reg wanted_dm;
    reg nb_ok;
    initial begin
        $display("=== DDR3 data mask (DM) window and neighbour-column protection (Phase 9 Stage 1, Part 22) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!calib_done && !calib_error && $time < 900_000) @(posedge clk);
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
                for (u = 0; u < 4; u = u + 1) begin
                    wanted_dm = (k == 3 && u == 0) ? 1'b0 : 1'b1;   // low only at beat 0, the burst's first strobe edge
                    if (dm_ui[((wr_cyc[w] + k) * 4 + u) % (LOG * 4)] !== wanted_dm) begin
                        if (dm_fails < 8)
                            $display("  FAIL write %0d: DM at W+%0d edge %0d is %b, expected %b", w, k, u,
                                     dm_ui[((wr_cyc[w] + k) * 4 + u) % (LOG * 4)], wanted_dm);
                        dm_fails = dm_fails + 1;
                    end
                    if (udm_ui[((wr_cyc[w] + k) * 4 + u) % (LOG * 4)] !== wanted_dm) begin
                        if (dm_fails < 8)
                            $display("  FAIL write %0d: UDM (lane 1) at W+%0d edge %0d is %b, expected %b", w, k, u,
                                     udm_ui[((wr_cyc[w] + k) * 4 + u) % (LOG * 4)], wanted_dm);
                        dm_fails = dm_fails + 1;
                    end
                end
            end
        end
        check_true("every write: both lanes' DM low at beat 0 only, high at the other seven beats and everywhere else", dm_fails == 0);

        // ---- does DM actually protect the other seven columns of the block? ----
        // Sentinels first (a byte per column, none the one the final write uses), through the same controller.
        for (n = 0; n < 8; n = n + 1) begin
            if (n != NB_TGT) begin
                write_bank <= NB_BANK; write_row <= NB_ROW; write_col <= NB_BASE + n; write_data <= 8'h50 + n;
                @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; @(posedge clk);
                guard = 0; while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
            end
        end
        nb_ok = 1'b1;
        for (n = 0; n < 8; n = n + 1)
            if (n != NB_TGT && (MEM.peek(NB_BANK, NB_ROW, NB_BASE + n) !== (8'h50 + n) ||
                                LANE1.MEM.peek(NB_BANK, NB_ROW, NB_BASE + n) !== sent1(n))) nb_ok = 1'b0;
        check_true("each of the block's other columns accepts a write, in both lanes (sanity: the models can store there)", nb_ok);

        // Now the target, a byte of its own: the seven sentinels must be untouched by THIS write's burst.
        write_bank <= NB_BANK; write_row <= NB_ROW; write_col <= NB_BASE + NB_TGT; write_data <= 8'hC3;
        @(posedge clk); write_req <= 1'b1; @(posedge clk); write_req <= 1'b0; @(posedge clk);
        guard = 0; while (write_busy && guard < 400) begin @(posedge clk); guard = guard + 1; end
        repeat (10) @(posedge clk);

        check_true("the addressed column holds the byte this write sent, in both lanes",
                    MEM.peek(NB_BANK, NB_ROW, NB_BASE + NB_TGT) === 8'hC3 &&
                    LANE1.MEM.peek(NB_BANK, NB_ROW, NB_BASE + NB_TGT) === ~8'hC3);
        nb_ok = 1'b1;
        for (n = 0; n < 8; n = n + 1) begin
            if (n != NB_TGT && MEM.peek(NB_BANK, NB_ROW, NB_BASE + n) !== (8'h50 + n)) begin
                nb_ok = 1'b0;
                $display("  FAIL lane 0, column %0d of the block holds %02h, expected its sentinel %02h", n,
                         MEM.peek(NB_BANK, NB_ROW, NB_BASE + n), 8'h50 + n);
            end
            if (n != NB_TGT && LANE1.MEM.peek(NB_BANK, NB_ROW, NB_BASE + n) !== sent1(n)) begin
                nb_ok = 1'b0;
                $display("  FAIL lane 1, column %0d of the block holds %02h, expected its sentinel %02h", n,
                         LANE1.MEM.peek(NB_BANK, NB_ROW, NB_BASE + n), sent1(n));
            end
        end
        check_true("the other seven columns of the block are unchanged by this write, in both lanes: DM protected every one", nb_ok);
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
