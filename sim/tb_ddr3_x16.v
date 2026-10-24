// Integrated test for Phase 9 Stage 1, Part 26 (docs/roadmap/phase-09-ddr.md): the controller is x16.
// A request moves a 16-bit word at its column, lane 1 carries the upper byte, and `write_be` says
// which of the two lanes a write stores. Both lanes' memory models watch the same command pins, so
// each holds its own byte plane, the way the two halves of a real x16 part do.
//
// What this holds, through the real top (rtl/soc/ddr3_ecp5_top.v), commands and all:
//   - a word written to a cell reads back whole, at the corners of the address space and at a walking
//     one through each of bank, row and column, with a different word in every cell, so a cell that
//     answers for another (an alias) or a byte that lands in the wrong lane shows up;
//   - `write_be` is honoured per lane: a write that stores one lane leaves the other lane's byte
//     alone, one that stores neither changes nothing, and the data mask of the lane not stored
//     stays high for the whole write (the waveform, not only its effect);
//   - the neighbour column the burst's second half would reach (Part 22) is protected on lane 1 as
//     it always was on lane 0;
//   - each lane's byte is in its own plane of the memory (lane 0's in MEM, lane 1's in MEM1);
//   - the request's data and enables are captured at request time: the caller scrambles them the
//     cycle after, as a caller that has handed its request over may, and nothing changes;
//   - neither memory model sees a write-burst timing error, no lane's pins are ever contended, and
//     the protocol checker is quiet through enough transactions that several refreshes land among them.
// What it does not establish: a lane 1 that calibrates later than lane 0 (they calibrate in
// lockstep here, so the controller waiting for both is not observable), the ECP5's own capture
// latency on lane 1, or anything about hardware-faithful bursts.
`timescale 1ns/1ps
module tb_ddr3_x16;
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
    wire        ddr3_reset_n = ~rst;   // the board: the DRAM's RESET# is the system reset's complement (Part 27)
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
    reg  [1:0]  write_be   = 2'b00;
    wire        write_busy;

    reg         read_req  = 1'b0;
    reg  [2:0]  read_bank = 3'd0;
    reg  [15:0] read_row  = 16'd0;
    reg  [15:0] read_col  = 16'd0;
    wire        read_busy;
    wire [15:0] read_data;
    wire        read_data_valid;
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
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked), .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel), .calib_error(calib_error),
        .calib1_done(calib1_done), .calib1_readclksel(calib1_readclksel), .calib1_error(calib1_error)
    );

    // The protocol checker, on the shared command pins.
    wire         model_error;
    wire [511:0] model_error_msg;
    ddr3_model #(.CLK_HZ(CLK_HZ)) PROTO (
        .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done()
    );

    // Lane 0's byte plane, on lane 0's pins.
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

    // Lane 1's byte plane, on lane 1's pins, watching the same command pins as lane 0's.
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

    // Contention on either lane's pins, per bit (a reduction would report a floating bus as contended).
    function automatic has_real_x;
        input [7:0] v;
        integer i;
        begin
            has_real_x = 1'b0;
            for (i = 0; i < 8; i = i + 1)
                if (v[i] === 1'bx) has_real_x = 1'b1;
        end
    endfunction
    reg contention_seen = 1'b0;
    always @(posedge DUT.sclk)
        if (!rst && (has_real_x(ddr3_dq) || has_real_x(ddr3_dqu) || ddr3_dqs === 1'bx || ddr3_udqs === 1'bx))
            contention_seen <= 1'b1;

    // The data-mask waveform of each lane over one write: at how many strobe edges it is low (DM is low for beat 0 only, so one
    // for a write that stores the lane and none otherwise). Sampled on CK's rising edge, where a beat falls (Phase 9 Stage 3).
    integer dm_low = 0, udm_low = 0;
    reg     counting = 1'b0;
    always @(posedge ddr3_ck) begin
        if (counting && ddr3_dm  === 1'b0) dm_low  <= dm_low  + 1;
        if (counting && ddr3_udm === 1'b0) udm_low <= udm_low + 1;
    end

    // Commands on the pins: how many CK edges the DRAM samples a command on (CS# is tied low on the
    // board, so a command is any sample with RAS#, CAS# or WE# low; the NOP between commands is 111).
    integer cmds = 0;
    always @(posedge ddr3_ck)
        if (!rst && (ddr3_ras_n === 1'b0 || ddr3_cas_n === 1'b0 || ddr3_we_n === 1'b0)) cmds = cmds + 1;

    integer errors = 0;
    task check(input [511:0] what, input got, input want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %b, expected %b", what, got, want);
                errors = errors + 1;
            end
        end
    endtask
    task check16(input [511:0] what, input [15:0] got, input [15:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %04h, expected %04h", what, got, want);
                errors = errors + 1;
            end
        end
    endtask
    task check8(input [511:0] what, input [7:0] got, input [7:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %02h, expected %02h", what, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // ---- the caller: one request at a time, waiting for busy to rise and fall, the way
    // rtl/soc/wb_ddr.v does ----
    task do_write(input [2:0] bk, input [15:0] rw, input [15:0] cl, input [15:0] d, input [1:0] be);
        integer t;
        begin
            while (write_busy) @(posedge clk);
            @(posedge clk);
            write_bank <= bk; write_row <= rw; write_col <= cl; write_data <= d; write_be <= be;
            write_req <= 1'b1;
            dm_low = 0; udm_low = 0; counting = 1'b1;
            @(posedge clk);
            write_req <= 1'b0;
            // The request has been handed over; a caller need not keep it stable.
            write_data <= ~d; write_be <= ~be;
            t = 0;
            while (!write_busy && t < 200) begin @(posedge clk); t = t + 1; end
            t = 0;
            while (write_busy && t < 400) begin @(posedge clk); t = t + 1; end
            if (t >= 400) begin $display("  FAIL write never finished"); errors = errors + 1; end
            repeat (4) @(posedge clk);
            counting = 1'b0;
        end
    endtask

    integer     n_valid = 0;
    reg [15:0]  last_read;
    always @(posedge clk) if (read_data_valid) begin last_read <= read_data; n_valid <= n_valid + 1; end

    reg [15:0] got_word;
    task do_read(input [2:0] bk, input [15:0] rw, input [15:0] cl);
        integer t, n0;
        begin
            while (read_busy) @(posedge clk);
            n0 = n_valid;
            @(posedge clk);
            read_bank <= bk; read_row <= rw; read_col <= cl; read_req <= 1'b1;
            @(posedge clk);
            read_req <= 1'b0;
            t = 0;
            while (!read_busy && t < 200) begin @(posedge clk); t = t + 1; end
            t = 0;
            while (read_busy && t < 400) begin @(posedge clk); t = t + 1; end
            if (t >= 400) begin $display("  FAIL read never finished"); errors = errors + 1; end
            repeat (2) @(posedge clk);
            if (n_valid != n0 + 1) begin
                $display("  FAIL read_data_valid pulsed %0d times for one read", n_valid - n0);
                errors = errors + 1;
            end
            got_word = last_read;
        end
    endtask

    // ---- peek into each lane's byte plane (the models' content-addressable tables) ----
    reg [7:0] peek_byte;
    reg       peek_found;
    task peek0(input [2:0] bk, input [14:0] rw, input [9:0] cl);
        integer j;
        begin
            peek_found = 1'b0; peek_byte = 8'hxx;
            for (j = 0; j < MEM.n_used; j = j + 1)
                if (MEM.k_used[j] && MEM.k_bank[j] === bk && MEM.k_row[j] === rw && MEM.k_col[j] === cl) begin
                    peek_found = 1'b1; peek_byte = MEM.k_data[j];
                end
        end
    endtask
    task peek1(input [2:0] bk, input [14:0] rw, input [9:0] cl);
        integer j;
        begin
            peek_found = 1'b0; peek_byte = 8'hxx;
            for (j = 0; j < MEM1.n_used; j = j + 1)
                if (MEM1.k_used[j] && MEM1.k_bank[j] === bk && MEM1.k_row[j] === rw && MEM1.k_col[j] === cl) begin
                    peek_found = 1'b1; peek_byte = MEM1.k_data[j];
                end
        end
    endtask

    // A different word for every cell: a hash of the address.
    function [15:0] word_for(input [2:0] bk, input [15:0] rw, input [15:0] cl);
        reg [31:0] h;
        begin
            h = {13'b0, bk, rw} * 32'd2654435761 + {16'b0, cl} * 32'd40503 + 32'd12345;
            word_for = h[23:8] ^ {rw[7:0], cl[7:0]};
        end
    endfunction

    // The cells the sweep visits: the corners, a walking one through each field, and a neighbour pair.
    localparam N_CELLS = 18;
    reg [2:0]  cb [0:N_CELLS-1];
    reg [15:0] cr [0:N_CELLS-1];
    reg [15:0] cc [0:N_CELLS-1];
    integer i;
    initial begin
        cb[0]  = 3'd0; cr[0]  = 16'h0000; cc[0]  = 16'h0000;   // the first cell
        cb[1]  = 3'd7; cr[1]  = 16'h7FFF; cc[1]  = 16'h03FF;   // the last cell
        cb[2]  = 3'd1; cr[2]  = 16'h0000; cc[2]  = 16'h0000;   // bank bit 0
        cb[3]  = 3'd2; cr[3]  = 16'h0000; cc[3]  = 16'h0000;   // bank bit 1
        cb[4]  = 3'd4; cr[4]  = 16'h0000; cc[4]  = 16'h0000;   // bank bit 2
        cb[5]  = 3'd0; cr[5]  = 16'h0001; cc[5]  = 16'h0000;   // row bit 0
        cb[6]  = 3'd0; cr[6]  = 16'h0100; cc[6]  = 16'h0000;   // row bit 8
        cb[7]  = 3'd0; cr[7]  = 16'h4000; cc[7]  = 16'h0000;   // row bit 14, the top
        cb[8]  = 3'd0; cr[8]  = 16'h0000; cc[8]  = 16'h0001;   // column bit 0
        cb[9]  = 3'd0; cr[9]  = 16'h0000; cc[9]  = 16'h0008;   // column bit 3
        cb[10] = 3'd0; cr[10] = 16'h0000; cc[10] = 16'h0080;   // column bit 7
        cb[11] = 3'd0; cr[11] = 16'h0000; cc[11] = 16'h0200;   // column bit 9, the top
        cb[12] = 3'd3; cr[12] = 16'h1234; cc[12] = 16'h0155;   // a neighbour pair: columns c and c ^ 4
        cb[13] = 3'd3; cr[13] = 16'h1234; cc[13] = 16'h0151;
        cb[14] = 3'd5; cr[14] = 16'h2AAA; cc[14] = 16'h02AA;   // alternating bits
        cb[15] = 3'd2; cr[15] = 16'h5555; cc[15] = 16'h0155;
        cb[16] = 3'd6; cr[16] = 16'h0F0F; cc[16] = 16'h00F0;
        cb[17] = 3'd1; cr[17] = 16'h7FFE; cc[17] = 16'h03FE;
    end

    reg [15:0] expect_word;
    integer    n_cmds0, n_before, t_wait, lane;
    initial begin
        $display("=== DDR3 x16: lane 1 carries data (Phase 9 Stage 1, Part 26) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (8) @(posedge clk);
        check("PLL locked", pll_locked, 1'b1);
        check("DLL locked", dll_locked, 1'b1);

        while (!init_ready && !model_error && $time < 700_000) @(posedge clk);
        check("init sequence reports ready", init_ready, 1'b1);
        while (!((calib_done || calib_error) && (calib1_done || calib1_error)) && $time < 1_100_000) @(posedge clk);
        check("lane 0 calibrated", calib_done, 1'b1);
        check("lane 1 calibrated", calib1_done, 1'b1);
        check("lane 0 calibration did not error", calib_error, 1'b0);
        check("lane 1 calibration did not error", calib1_error, 1'b0);

        // ---- every cell holds its own word, whole ----
        $display("  a different word in each of %0d cells, then each read back...", N_CELLS);
        for (i = 0; i < N_CELLS; i = i + 1)
            do_write(cb[i], cr[i], cc[i], word_for(cb[i], cr[i], cc[i]), 2'b11);
        for (i = 0; i < N_CELLS; i = i + 1) begin
            do_read(cb[i], cr[i], cc[i]);
            expect_word = word_for(cb[i], cr[i], cc[i]);
            if (got_word !== expect_word) begin
                $display("  FAIL cell (%0d,%04h,%04h): got %04h, expected %04h", cb[i], cr[i], cc[i], got_word, expect_word);
                errors = errors + 1;
            end
        end
        // each byte is in its own lane's plane
        for (i = 0; i < N_CELLS; i = i + 1) begin
            expect_word = word_for(cb[i], cr[i], cc[i]);
            peek0(cb[i], cr[i][14:0], cc[i][9:0]);
            if (!peek_found || peek_byte !== expect_word[7:0]) begin
                $display("  FAIL cell (%0d,%04h,%04h): lane 0 plane holds %02h, expected %02h", cb[i], cr[i], cc[i], peek_byte, expect_word[7:0]);
                errors = errors + 1;
            end
            peek1(cb[i], cr[i][14:0], cc[i][9:0]);
            if (!peek_found || peek_byte !== expect_word[15:8]) begin
                $display("  FAIL cell (%0d,%04h,%04h): lane 1 plane holds %02h, expected %02h", cb[i], cr[i], cc[i], peek_byte, expect_word[15:8]);
                errors = errors + 1;
            end
        end

        // ---- byte enables, one cell ----
        $display("  byte enables...");
        do_write(3'd2, 16'h0123, 16'h0045, 16'hA55A, 2'b11);
        do_read (3'd2, 16'h0123, 16'h0045);               check16("both lanes stored", got_word, 16'hA55A);
        check("both data masks went low for a write that stores both", (dm_low > 0) && (udm_low > 0), 1'b1);

        do_write(3'd2, 16'h0123, 16'h0045, 16'h1234, 2'b01);
        check("lane 0 mask low, lane 1 mask never low, for a write that stores lane 0 only", (dm_low > 0) && (udm_low == 0), 1'b1);
        do_read (3'd2, 16'h0123, 16'h0045);               check16("lane 0 stored, lane 1 left alone", got_word, 16'hA534);

        do_write(3'd2, 16'h0123, 16'h0045, 16'h5678, 2'b10);
        check("lane 1 mask low, lane 0 mask never low, for a write that stores lane 1 only", (dm_low == 0) && (udm_low > 0), 1'b1);
        do_read (3'd2, 16'h0123, 16'h0045);               check16("lane 1 stored, lane 0 left alone", got_word, 16'h5634);

        do_write(3'd2, 16'h0123, 16'h0045, 16'hFFFF, 2'b00);
        check("neither mask goes low for a write that stores nothing", (dm_low == 0) && (udm_low == 0), 1'b1);
        do_read (3'd2, 16'h0123, 16'h0045);               check16("a write that stores nothing changed nothing", got_word, 16'h5634);

        // ---- the neighbour column (Part 22), on both lanes ----
        $display("  the neighbour column...");
        do_write(3'd4, 16'h0222, 16'h0102, 16'h1122, 2'b11);   // column c
        do_write(3'd4, 16'h0222, 16'h0106, 16'h3344, 2'b11);   // column c ^ 4: its burst's second half reaches c
        do_read (3'd4, 16'h0222, 16'h0102);               check16("column c survived a write to c ^ 4", got_word, 16'h1122);
        do_read (3'd4, 16'h0222, 16'h0106);               check16("column c ^ 4 holds its own word", got_word, 16'h3344);
        do_write(3'd4, 16'h0222, 16'h0102, 16'h99AA, 2'b10);   // lane 1 only, at c
        do_read (3'd4, 16'h0222, 16'h0106);               check16("column c ^ 4 survived a lane-1 write to c", got_word, 16'h3344);
        do_read (3'd4, 16'h0222, 16'h0102);               check16("a lane-1 write changed lane 1 and not lane 0", got_word, 16'h9922);

        // ---- the whole sweep again, read in the opposite order, after all that traffic ----
        $display("  the sweep again, backwards...");
        for (i = N_CELLS - 1; i >= 0; i = i - 1) begin
            do_read(cb[i], cr[i], cc[i]);
            expect_word = word_for(cb[i], cr[i], cc[i]);
            if (got_word !== expect_word) begin
                $display("  FAIL cell (%0d,%04h,%04h) the second time: got %04h, expected %04h", cb[i], cr[i], cc[i], got_word, expect_word);
                errors = errors + 1;
            end
        end

`ifndef VERILATOR
        // The two scenarios below force a net inside the DUT and release it. Verilator's release does not
        // give the net back to the module that drives it, so every read after the first one returns garbage:
        // under Verilator this test stops at the sweep, and Icarus (make sim_ddr3_x16, in make verify) runs
        // these.
        // ---- a lane that has not calibrated holds the whole controller back ----
        // The two lanes calibrate in lockstep here, so a lane's `calib_done` is held low by hand, as it
        // would be for a lane that finds its tap later than the other. Each lane in turn.
        for (lane = 0; lane < 2; lane = lane + 1) begin
            $display("  commands wait for lane %0d's calibration...", lane);
            if (lane == 0) force DUT.calib_done  = 1'b0;
            else           force DUT.calib1_done = 1'b0;
            repeat (4) @(posedge clk);
            n_cmds0 = cmds;
            write_bank <= 3'd1; write_row <= 16'h0042; write_col <= 16'h0007; write_data <= 16'hBEEF; write_be <= 2'b11;
            write_req <= 1'b1;
            @(posedge clk);
            write_req <= 1'b0;
            repeat (80) @(posedge clk);
            check("no command reaches the pins while a lane is uncalibrated", cmds == n_cmds0, 1'b1);
            check("the controller does not report busy for a request it did not take", write_busy, 1'b0);
            if (lane == 0) release DUT.calib_done;
            else           release DUT.calib1_done;
            repeat (4) @(posedge clk);
            do_write(3'd1, 16'h0042, 16'h0007, 16'hBEEF, 2'b11);
            do_read (3'd1, 16'h0042, 16'h0007);           check16("once both lanes have calibrated the controller takes requests", got_word, 16'hBEEF);
        end

        // ---- a read is complete only if both lanes saw their data window ----
        for (lane = 0; lane < 2; lane = lane + 1) begin
            $display("  a read is valid only if lane %0d's window opened too...", lane);
            if (lane == 0) force DUT.datavalid   = 1'b0;
            else           force DUT.datavalid_1 = 1'b0;
            n_before = n_valid;
            while (read_busy) @(posedge clk);
            @(posedge clk);
            read_bank <= 3'd1; read_row <= 16'h0042; read_col <= 16'h0007; read_req <= 1'b1;
            @(posedge clk);
            read_req <= 1'b0;
            t_wait = 0;
            while (!read_busy && t_wait < 200) begin @(posedge clk); t_wait = t_wait + 1; end
            t_wait = 0;
            while (read_busy && t_wait < 400) begin @(posedge clk); t_wait = t_wait + 1; end
            repeat (4) @(posedge clk);
            check("no valid pulse for a read whose window never opened on a lane", n_valid == n_before, 1'b1);
            if (lane == 0) release DUT.datavalid;
            else           release DUT.datavalid_1;
            repeat (4) @(posedge clk);
            do_read (3'd1, 16'h0042, 16'h0007);           check16("a read with both windows open is valid again", got_word, 16'hBEEF);
        end

`endif
        check("the protocol checker saw nothing wrong", model_error, 1'b0);
        check("lane 0's memory saw no write-burst timing error", dq_error, 1'b0);
        check("lane 1's memory saw no write-burst timing error", dqu_error, 1'b0);
        check("no contention on either lane's pins", contention_seen, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 X16 TEST PASSED");
        else             $display("DDR3 X16 TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
