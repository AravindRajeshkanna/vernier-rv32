// Integrated test for Phase 9 Stage 3 (docs/roadmap/phase-09-ddr.md), 8-beat bursts, part C, write half: a write as one
// burst. With `write_wide` high a request carries eight beats of {lane 1, lane 0} (`write_burst`) and which lane stores which
// beat (`write_burst_be`, bit 2*b for lane 0 and 2*b+1 for lane 1), and the controller (rtl/soc/ddr3_ecp5_top.v) sends it as
// one BL8 write: the first active cycle carries beats 0 to 3, the second beats 4 to 7, DM is low exactly for the beats a lane
// stores, and beat b lands in column {c[9:3], (c[2:0] + b) mod 8} of the addressed column c.
//
// What this holds, through the real top, commands and both lanes' memory models:
//   - a burst with every beat stored puts eight different words into the eight columns, in order, both lanes; from an aligned
//     column and from column 3 (it wraps inside the aligned eight);
//   - for each of the sixteen (beat, lane) pairs, a burst that stores that pair alone changes that byte of that column and
//     nothing else anywhere in the block (the first and last beat of each active cycle are in there);
//   - random masks over blocks already holding other data: exactly the selected bytes change, to the value sent, and every
//     other byte keeps what it had; a mask of zero changes nothing;
//   - the data mask on the waveform: lane 0's DM is low at as many strobe edges as its mask has beats, lane 1's likewise
//     (judged at every CK edge, which is the middle of a beat);
//   - the request is captured when it is made: the caller scrambles the burst, the mask and the wide flag the cycle after;
//   - the words written read back, through the controller, in `read_burst`;
//   - a narrow write is still beat 0 only;
//   - no write-burst timing error, no protocol error and no contention on either lane's pins.
// What it does not establish: anything on a board; the beat order on the real ODDRX2DQA (LiteDRAM's evidence, not Lattice's).
`timescale 1ns/1ps
module tb_ddr3_wide_write;
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

    reg         write_req   = 1'b0;
    reg  [2:0]  write_bank  = 3'd0;
    reg  [15:0] write_row   = 16'd0;
    reg  [15:0] write_col   = 16'd0;
    reg  [15:0] write_data  = 16'd0;
    reg  [1:0]  write_be    = 2'b00;
    reg         write_wide  = 1'b0;
    reg  [127:0] write_burst = 128'd0;
    reg  [15:0] write_burst_be = 16'd0;
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
        .write_wide(write_wide), .write_burst(write_burst), .write_burst_be(write_burst_be),
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

    // contention on either lane's pins, per bit (a reduction would report a floating bus as contended)
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

    // the data-mask waveform of each lane over one write: at how many CK edges (a CK edge is the middle of a beat: the strobe's
    // edges are CK's) it is low
    integer dm_low = 0, udm_low = 0;
    reg     counting = 1'b0;
    always @(posedge ddr3_ck or negedge ddr3_ck) begin
        if (counting && ddr3_dm  === 1'b0) dm_low  = dm_low  + 1;
        if (counting && ddr3_udm === 1'b0) udm_low = udm_low + 1;
    end

    integer errors = 0;
    task check_true(input [511:0] what, input cond);
        begin
            if (!cond) begin
                $display("  FAIL %0s", what);
                errors = errors + 1;
            end else $display("  ok   %0s", what);
        end
    endtask

    // ---- peek into each lane's byte plane (the models' content-addressable tables) ----
    reg [7:0] pk_byte;
    reg       pk_found;
    task peek(input lane, input [2:0] bk, input [14:0] rw, input [9:0] cl);
        integer j;
        begin
            pk_found = 1'b0; pk_byte = 8'hxx;
            if (!lane) begin
                for (j = 0; j < MEM.n_used; j = j + 1)
                    if (MEM.k_used[j] && MEM.k_bank[j] === bk && MEM.k_row[j] === rw && MEM.k_col[j] === cl) begin
                        pk_found = 1'b1; pk_byte = MEM.k_data[j];
                    end
            end else begin
                for (j = 0; j < MEM1.n_used; j = j + 1)
                    if (MEM1.k_used[j] && MEM1.k_bank[j] === bk && MEM1.k_row[j] === rw && MEM1.k_col[j] === cl) begin
                        pk_found = 1'b1; pk_byte = MEM1.k_data[j];
                    end
            end
        end
    endtask

    // ---- the caller: one request at a time, waiting for busy to rise and fall, as rtl/soc/wb_ddr.v does ----
    task do_narrow(input [2:0] bk, input [15:0] rw, input [15:0] cl, input [15:0] d, input [1:0] be);
        integer t;
        begin
            while (write_busy) @(posedge clk);
            @(posedge clk);
            write_bank <= bk; write_row <= rw; write_col <= cl; write_data <= d; write_be <= be; write_wide <= 1'b0;
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

    task do_wide(input [2:0] bk, input [15:0] rw, input [15:0] cl, input [127:0] d, input [15:0] be);
        integer t;
        begin
            while (write_busy) @(posedge clk);
            @(posedge clk);
            write_bank <= bk; write_row <= rw; write_col <= cl; write_wide <= 1'b1;
            write_burst <= d; write_burst_be <= be;
            write_req <= 1'b1;
            dm_low = 0; udm_low = 0; counting = 1'b1;
            @(posedge clk);
            write_req <= 1'b0;
            // The request has been handed over; a caller need not keep it stable.
            write_burst <= ~d; write_burst_be <= ~be; write_wide <= 1'b0; write_data <= 16'hDEAD; write_be <= 2'b11;
            t = 0;
            while (!write_busy && t < 200) begin @(posedge clk); t = t + 1; end
            t = 0;
            while (write_busy && t < 400) begin @(posedge clk); t = t + 1; end
            if (t >= 400) begin $display("  FAIL write never finished"); errors = errors + 1; end
            repeat (4) @(posedge clk);
            counting = 1'b0;
        end
    endtask

    // ---- reads: the burst the controller reports ----
    reg [127:0] last_burst;
    integer     n_rbv = 0;
    always @(posedge DUT.sclk) if (read_burst_valid) begin last_burst <= read_burst; n_rbv <= n_rbv + 1; end
    task do_read(input [2:0] bk, input [15:0] rw, input [15:0] cl);
        integer t, b0;
        begin
            while (read_busy) @(posedge clk);
            b0 = n_rbv;
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
            if (n_rbv != b0 + 1) begin $display("  FAIL read_burst_valid pulsed %0d times", n_rbv - b0); errors = errors + 1; end
        end
    endtask

    // xorshift32, for the random cases
    function [31:0] xorshift(input [31:0] s);
        reg [31:0] x;
        begin
            x = s;
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            xorshift = x;
        end
    endfunction

    // the word beat k of case n carries, and the sentinel word a block holds in column k before a case
    function [15:0] new_word(input integer n, input integer k);
        reg [7:0] lo;
        begin
            lo = 8'hC1 + 8'h2D * n[7:0] + 8'h07 * k[7:0];
            new_word = {lo ^ 8'hA7, lo};
        end
    endfunction
    function [15:0] old_word(input integer n, input integer k);
        reg [7:0] lo;
        begin
            lo = 8'h31 + 8'h19 * n[7:0] + 8'h05 * k[7:0];
            old_word = {~lo, lo};
        end
    endfunction

    // judge a block: `has_old` says the block held old_word(n, column) before the burst. The burst was `be` over `d` from first
    // column c0 of the aligned eight starting at column 8*blk (so beat b is column (c0 + b) mod 8).
    integer jb_fail;
    task judge(input [2:0] bk, input [15:0] rw, input integer blk, input integer c0, input [127:0] d, input [15:0] be,
               input has_old, input integer n);
        integer b, col, l;
        reg want_found, stored;
        reg [7:0] want_byte;
        begin
            jb_fail = 0;
            for (col = 0; col < 8; col = col + 1) begin
                b = (col - c0 + 8) % 8;   // the beat that goes to this column
                for (l = 0; l < 2; l = l + 1) begin
                    stored = be[2 * b + l];
                    if (stored) begin want_found = 1'b1; want_byte = d[16 * b + 8 * l +: 8]; end
                    else if (has_old) begin want_found = 1'b1; want_byte = old_word(n, col) >> (8 * l); end
                    else begin want_found = 1'b0; want_byte = 8'hxx; end
                    peek(l[0], bk, rw[14:0], 8 * blk + col);
                    if (pk_found !== want_found || (want_found && pk_byte !== want_byte)) begin
                        if (jb_fail < 6)
                            $display("  FAIL column %0d lane %0d: %s %02h, expected %s %02h (beat %0d, mask bit %0d)",
                                     col, l, pk_found ? "holds" : "empty", pk_byte, want_found ? "holds" : "empty", want_byte, b, stored);
                        jb_fail = jb_fail + 1;
                    end
                end
            end
        end
    endtask

    function integer popcount(input [15:0] v);
        integer i;
        begin popcount = 0; for (i = 0; i < 16; i = i + 1) if (v[i]) popcount = popcount + 1; end
    endfunction

    reg [127:0] dd;
    reg [15:0]  mm;
    reg [31:0]  seed;
    integer i, k, n, fails_all, wf_fails, lane_cnt0, lane_cnt1, fail_dm;
    initial begin
        $display("=== DDR3 wide write: one burst, a mask per beat and lane (Phase 9 Stage 3, 8-beat bursts part C, write half) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        while (!(calib_done && calib1_done) && !calib_error && !calib1_error && $time < 900_000) @(posedge clk);
        check_true("both lanes calibrated before this test begins", calib_done && calib1_done && !calib_error && !calib1_error);
        repeat (8) @(posedge clk);
        fails_all = 0; fail_dm = 0;

        // ---- every beat stored: eight words in order; from an aligned column and from column 3 (the wrap) ----
        for (k = 0; k < 8; k = k + 1) dd[16 * k +: 16] = new_word(0, k);
        do_wide(3'd2, 16'h0100, 16'h0010, dd, 16'hFFFF);
        judge(3'd2, 16'h0100, 2, 0, dd, 16'hFFFF, 1'b0, 0);
        check_true("aligned full burst: eight words in eight columns, both lanes", jb_fail == 0);
        fails_all = fails_all + jb_fail;
        check_true("... and DM was low at eight edges in each lane", dm_low == 8 && udm_low == 8);
        for (k = 0; k < 8; k = k + 1) dd[16 * k +: 16] = new_word(1, k);
        do_wide(3'd2, 16'h0101, 16'h0013, dd, 16'hFFFF);   // column 3 of block 2: the burst wraps
        judge(3'd2, 16'h0101, 2, 3, dd, 16'hFFFF, 1'b0, 1);
        check_true("a full burst from column 3: beat b in column (3 + b) mod 8", jb_fail == 0);
        fails_all = fails_all + jb_fail;

        // ---- each (beat, lane) pair alone, in a block nothing else has touched ----
        wf_fails = 0; lane_cnt0 = 0;
        for (i = 0; i < 16; i = i + 1) begin
            for (k = 0; k < 8; k = k + 1) dd[16 * k +: 16] = new_word(10 + i, k);
            mm = 16'h0001 << i;
            do_wide(3'd3, 16'h0200 + i, 16'h0000, dd, mm);
            judge(3'd3, 16'h0200 + i, 0, 0, dd, mm, 1'b0, 10 + i);
            wf_fails = wf_fails + jb_fail;
            if (dm_low != ((i % 2 == 0) ? 1 : 0) || udm_low != ((i % 2 == 1) ? 1 : 0)) fail_dm = fail_dm + 1;
        end
        check_true("each (beat, lane) pair alone: only that byte is written", wf_fails == 0);
        fails_all = fails_all + wf_fails;
        check_true("... and DM was low at one edge, in that pair's lane only", fail_dm == 0);

        // ---- random masks over blocks that already hold data ----
        seed = 32'h5EEDC0DE; wf_fails = 0; fail_dm = 0;
        for (i = 0; i < 8; i = i + 1) begin
            for (k = 0; k < 8; k = k + 1) do_narrow(3'd4, 16'h0300 + i, 16'h0000 + k, old_word(i, k), 2'b11);
            for (k = 0; k < 8; k = k + 1) begin
                seed = xorshift(seed); dd[16 * k +: 16] = seed[15:0];
            end
            seed = xorshift(seed); mm = (i == 0) ? 16'h0000 : seed[15:0];   // the first: nothing stored
            seed = xorshift(seed);
            do_wide(3'd4, 16'h0300 + i, 16'h0000 + seed[2:0], dd, mm);
            judge(3'd4, 16'h0300 + i, 0, seed[2:0], dd, mm, 1'b1, i);
            wf_fails = wf_fails + jb_fail;
            lane_cnt0 = 0; lane_cnt1 = 0;
            for (k = 0; k < 8; k = k + 1) begin lane_cnt0 = lane_cnt0 + mm[2 * k]; lane_cnt1 = lane_cnt1 + mm[2 * k + 1]; end
            if (dm_low != lane_cnt0 || udm_low != lane_cnt1) begin
                $display("  FAIL case %0d: DM low at %0d / %0d edges, expected %0d / %0d (mask %04h)", i, dm_low, udm_low, lane_cnt0, lane_cnt1, mm);
                fail_dm = fail_dm + 1;
            end
        end
        check_true("random masks: only the selected bytes changed, rest kept", wf_fails == 0);
        fails_all = fails_all + wf_fails;
        check_true("... DM low at as many edges as the mask has beats, per lane", fail_dm == 0);

        // ---- the words come back through the controller ----
        for (k = 0; k < 8; k = k + 1) dd[16 * k +: 16] = new_word(0, k);
        do_read(3'd2, 16'h0100, 16'h0010);
        check_true("the first burst reads back whole in read_burst", last_burst === dd);

        // ---- a narrow write is still beat 0 only ----
        do_narrow(3'd6, 16'h0400, 16'h0005, 16'hBEEF, 2'b11);
        peek(1'b0, 3'd6, 15'h0400, 10'h005); k = pk_found && pk_byte === 8'hEF;
        peek(1'b1, 3'd6, 15'h0400, 10'h005); k = k && pk_found && pk_byte === 8'hBE;
        peek(1'b0, 3'd6, 15'h0400, 10'h006); k = k && !pk_found;
        peek(1'b0, 3'd6, 15'h0400, 10'h004); k = k && !pk_found;
        peek(1'b1, 3'd6, 15'h0400, 10'h000); k = k && !pk_found;
        check_true("a narrow write stored its one column in both lanes and no other", k);

        check_true("no write-burst timing error on lane 0 or lane 1", !dq_error && !dqu_error);
        check_true("no protocol error", !model_error);
        check_true("no contention on either lane's pins", !contention_seen);
        check_true("no cell was wrong anywhere above", fails_all == 0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 WIDE WRITE TEST PASSED");
        else             $display("DDR3 WIDE WRITE TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #60_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
