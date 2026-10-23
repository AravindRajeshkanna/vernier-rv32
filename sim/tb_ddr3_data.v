// Directed test for the DDR3 read calibration, command-driven (Phase 9 Stage 3; the injected scheme it replaces was
// Stage 1, Part 2: docs/roadmap/phase-09-ddr.md). Through Stage 2 this ran rtl/soc/ddr3_read_calib.v by itself against a
// DQ model that answered a pattern the calibration drove onto the pins with no command behind it. The calibration now
// asks the controller's own sequencers for a real WRITE and real READs, so this runs the controller (rtl/soc/
// ddr3_ecp5_top.v), against the DRAM's protocol checker (sim/ddr3_model.v) and both lanes' memory models, and looks at what
// reaches the pins:
//   - the sweep is a WRITE of the pattern to the reserved column (bank 7, row 0x7FFF, column 0x3F8), then one READ of it
//     per tap, each READ with its ACTIVATE, until both lanes have a tap: the simulation's DQSBUFM has a valid window of
//     taps 2 to 5, so taps 0, 1 and 2 are tried and both lanes take 2 (the first that passes, not a lucky default);
//   - the protocol checker and both DQ models have no objection to any of it, and no pin is ever driven by two sides;
//   - the pattern is really in the DRAM: a read of the reserved column through the controller's own caller interface,
//     at the tap the sweep found, returns it, lane 0's byte and lane 1's;
//   - the controller is usable the moment `calib_done` rises (it is not still finishing the sweep's last PRECHARGE).
// What it does not establish: the sweep on silicon. The DQSBUFM here is a stand-in that does not look at the DQS pin.
`timescale 1ns/1ps
module tb_ddr3_data;
    localparam CLK_PERIOD = 40;   // 25 MHz, this project's own default
    localparam CLK_HZ     = 25_000_000;
    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    wire        ddr3_ck, ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [14:0] ddr3_a;
    wire        ddr3_cke, ddr3_odt;
    wire        ddr3_reset_n = ~rst;
    wire [7:0]  ddr3_dq, ddr3_dqu;
    wire        ddr3_dqs, ddr3_dm, ddr3_udqs, ddr3_udm;

    wire pll_locked, dll_locked, init_ready;
    wire calib_done, calib_error, calib1_done, calib1_error;
    wire [2:0] calib_readclksel, calib1_readclksel;

    reg         read_req = 1'b0;
    reg  [2:0]  read_bank = 3'd0;
    reg  [15:0] read_row = 16'd0, read_col = 16'd0;
    wire        read_busy, write_busy, read_data_valid, refresh_busy;
    wire [15:0] read_data;

    ddr3_ecp5_top DUT (
        .rst_warm(1'b0),
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck), .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a), .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .write_req(1'b0), .write_bank(3'b0), .write_row(16'b0),
        .write_col(16'b0), .write_data(16'b0), .write_be(2'b00), .write_busy(write_busy),
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
        .sclk(DUT.sclk), .rst(DUT.rst_all), .ck(ddr3_ck),
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
        .sclk(DUT.sclk), .rst(DUT.rst_all), .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n), .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dqu), .dqs_pin(ddr3_udqs), .dm_pin(ddr3_udm),
        .read_active(DUT.read_active_final_1),
        .mem_dq_o(mem_dqu_o), .mem_dq_oe(mem_dqu_oe), .mem_dqs_oe(mem_udqs_oe), .mem_dqs_o(mem_udqs_o),
        .dq_error(dqu_error), .dq_error_msg(dqu_error_msg)
    );
    genvar b1;
    generate for (b1 = 0; b1 < 8; b1 = b1 + 1) begin : DQU_BUS assign ddr3_dqu[b1] = mem_dqu_oe ? mem_dqu_o[b1] : 1'bz; end endgenerate
    assign ddr3_udqs = mem_udqs_oe ? mem_udqs_o : 1'bz;

    // ---- the commands as the DRAM sees them, and what they addressed ----
    wire c_act = !ddr3_ras_n &&  ddr3_cas_n &&  ddr3_we_n;
    wire c_wr  =  ddr3_ras_n && !ddr3_cas_n && !ddr3_we_n;
    wire c_rd  =  ddr3_ras_n && !ddr3_cas_n &&  ddr3_we_n;
    reg calib_done_seen = 1'b0;     // the sweep is over: what follows is the test's own read
    always @(posedge calib_done) calib_done_seen <= 1'b1;
    integer n_act = 0, n_wr = 0, n_rd = 0;
    reg [2:0]  act_bank = 3'd0, wr_bank = 3'd0, rd_bank = 3'd0;
    reg [14:0] act_row = 15'd0;
    reg [9:0]  wr_col = 10'd0, rd_col = 10'd0;
    reg        sweep_cmds_ok = 1'b1;    // every ACTIVATE, WRITE and READ of the sweep addressed the reserved column
    always @(posedge ddr3_ck) if (!rst && ddr3_reset_n && ddr3_cke && !calib_done_seen) begin
        if (c_act) begin n_act = n_act + 1; act_bank = ddr3_ba; act_row = ddr3_a;
                         if (ddr3_ba !== 3'd7 || ddr3_a !== 15'h7FFF) sweep_cmds_ok = 1'b0; end
        if (c_wr)  begin n_wr  = n_wr  + 1; wr_bank = ddr3_ba;  wr_col = ddr3_a[9:0];
                         if (ddr3_ba !== 3'd7 || ddr3_a[9:0] !== 10'h3F8) sweep_cmds_ok = 1'b0; end
        if (c_rd)  begin n_rd  = n_rd  + 1; rd_bank = ddr3_ba;  rd_col = ddr3_a[9:0];
                         if (ddr3_ba !== 3'd7 || ddr3_a[9:0] !== 10'h3F8) sweep_cmds_ok = 1'b0; end
    end
    // ---- no pin ever driven by two sides (per bit: a reduction would hide an x behind a 1) ----
    function automatic has_real_x(input [7:0] v);
        integer i;
        begin has_real_x = 1'b0; for (i = 0; i < 8; i = i + 1) if (v[i] === 1'bx) has_real_x = 1'b1; end
    endfunction
    reg contention = 1'b0;
    always @(posedge DUT.sclk) if (!rst && (has_real_x(ddr3_dq) || has_real_x(ddr3_dqu) || ddr3_dqs === 1'bx || ddr3_udqs === 1'bx)) contention <= 1'b1;

    integer errors = 0;
    task check(input [511:0] what, input got, input want);
        begin
            if (got !== want) begin $display("  FAIL %0s: got %b, expected %b", what, got, want); errors = errors + 1; end
            else $display("  ok   %0s", what);
        end
    endtask

    integer     tt;
    reg  [15:0] got_word;
    integer     busy_at_done;
    initial begin
        $display("=== DDR3 read calibration, command-driven (Phase 9 Stage 3) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (8) @(posedge clk);
        check("PLL locked", pll_locked, 1'b1);
        check("DLL locked", dll_locked, 1'b1);

        while (!((calib_done || calib_error) && (calib1_done || calib1_error)) && $time < 900_000) @(posedge clk);
        busy_at_done = (read_busy || write_busy) ? 1 : 0;
        check("calibration completed on lane 0 (not errored)", calib_error, 1'b0);
        check("calibration found a working tap on lane 0", calib_done, 1'b1);
        check("calibration completed on lane 1 (not errored)", calib1_error, 1'b0);
        check("calibration found a working tap on lane 1", calib1_done, 1'b1);
        $display("  calibrated READCLKSEL = %0d (lane 0), %0d (lane 1)", calib_readclksel, calib1_readclksel);
        check("first passing tap, lane 0: 2 (taps 0, 1 are outside the window)", calib_readclksel == 3'd2, 1'b1);
        check("first passing tap, lane 1: 2", calib1_readclksel == 3'd2, 1'b1);
        check("the controller is idle when calib_done rises", busy_at_done == 0, 1'b1);

        // ---- what the DRAM was asked ----
        $display("  the sweep sent the DRAM %0d ACTIVATE, %0d WRITE, %0d READ", n_act, n_wr, n_rd);
        check("one WRITE of the pattern", n_wr == 1, 1'b1);
        check("one READ per tap tried: taps 0, 1 and 2", n_rd == 3, 1'b1);
        check("four ACTIVATEs: one for the write, one for each read", n_act == 4, 1'b1);
        check("every sweep command addressed bank 7 row 0x7FFF column 0x3F8", sweep_cmds_ok, 1'b1);

        // ---- the pattern is in the DRAM, and a caller reads it ----
        begin : readback
            integer n0, g;
            n0 = 0;
            @(posedge clk);
            read_bank <= 3'd7; read_row <= 16'h7FFF; read_col <= 16'h03F8;
            @(posedge clk); read_req <= 1'b1; @(posedge clk); read_req <= 1'b0;
            g = 0; while (!read_data_valid && g < 400) begin @(posedge clk); g = g + 1; end
            got_word = read_data;
            g = 0; while (read_busy && g < 400) begin @(posedge clk); g = g + 1; end
        end
        check("a caller's read of the reserved column: lane 0's byte is 0xA5", got_word[7:0] === 8'hA5, 1'b1);
        check("and lane 1's byte is 0x3C", got_word[15:8] === 8'h3C, 1'b1);

        repeat (8) @(posedge clk);
        check("the DRAM's protocol checker has no objection", model_error, 1'b0);
        check("lane 0's DQ model has no objection", dq_error, 1'b0);
        check("lane 1's DQ model has no objection", dqu_error, 1'b0);
        check("no pin was ever driven by two sides at once", contention, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 DATA PATH TEST PASSED");
        else             $display("DDR3 DATA PATH TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #1_500_000;
        $display("TIMEOUT - calibration never completed");
        $finish;
    end
endmodule
