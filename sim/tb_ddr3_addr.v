// Integrated test for Phase 9 Stage 1, Part 15 (docs/roadmap.md): a write
// lands in the cell it was asked to, and a read comes from it. Until
// sim/ddr3_dq_model.v was made address-decoded this could not be seen at
// all - the memory was one byte, so a bug in the bank, row or column path
// would have passed every DDR3 test.
//
// Three independent ways to see an address bug, because each misses cases
// the others catch (measured, see docs/roadmap.md's Part 15 account):
//   1. Read-back through the DUT. Distinct data is written to a spread of
//      locations and every one is read back. This catches aliasing (two
//      requests landing in one cell) and any write/read disagreement - but
//      a bug that maps bank/row/column the same way on both paths (a
//      consistent permutation) is invisible to it: measured at zero
//      failures for a bank-bit swap applied to both paths.
//   2. The model, asked directly (`MEM.peek`) where each written byte
//      landed, by the address the test requested. This catches a
//      permutation, since the model holds the byte at the address that
//      actually reached the pins.
//   3. The pins. For every transaction, the ACT's bank and row and the
//      WR/RD's bank and column on the REAL command pins must equal what was
//      requested, decoded the way the part decodes them (Micron Table 2,
//      256 Meg x 16: row A[14:0], bank BA[2:0], column A[9:0]). This
//      catches a dropped or shifted bit directly.
//
// The location set is built to expose single-bit faults: every bank, every
// single-bit row (15) and column (10) with the other fields fixed, both
// all-ones extremes, and one location per combination of a low/high value
// in each field, so a bug coupling two fields cannot hide. Locations never
// written must read back `x`, so a read returning stale data from somewhere
// else cannot pass as a hit. It runs long enough to cross many refreshes,
// so data integrity across them is checked too.
`timescale 1ns/1ps
module tb_ddr3_addr;
    localparam CLK_HZ     = 25_000_000;
    localparam CLK_PERIOD = 40;   // 25 MHz
    localparam MAXLOC     = 128;

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
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs),
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

    wire        model_error;
    wire [511:0] model_error_msg;
    wire        model_seq_done;

    ddr3_model #(.CLK_HZ(CLK_HZ)) PROTO (
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done(model_seq_done)
    );

    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_o;

    wire         dq_error;

    wire [511:0] dq_error_msg;

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

    // ---- what actually appeared on the real command pins, sampled on CK's
    // rising edge where the DRAM samples them (Part 16: commands sit in the
    // first of two slots per sclk) ----
    integer act_n = 0, col_n = 0, refresh_cmds = 0;
    reg [2:0]  pin_act_ba = 3'bx, pin_col_ba = 3'bx;
    reg [15:0] pin_act_a  = 16'bx, pin_col_a  = 16'bx;
    always @(posedge ddr3_ck) begin
        if (!rst && calib_done) begin
            if (!ddr3_cs_n && !ddr3_ras_n &&  ddr3_cas_n &&  ddr3_we_n) begin
                act_n      <= act_n + 1;
                pin_act_ba <= ddr3_ba;
                pin_act_a  <= ddr3_a;
            end
            if (!ddr3_cs_n &&  ddr3_ras_n && !ddr3_cas_n) begin   // WR or RD
                col_n      <= col_n + 1;
                pin_col_ba <= ddr3_ba;
                pin_col_a  <= ddr3_a;
            end
            if (!ddr3_cs_n && !ddr3_ras_n && !ddr3_cas_n &&  ddr3_we_n) refresh_cmds <= refresh_cmds + 1;
        end
    end

    integer r_n = 0;
    reg [7:0] r_data = 8'hxx;
    always @(posedge DUT.sclk) begin
        if (!rst && read_data_valid) begin
            r_n    <= r_n + 1;
            r_data <= read_data;
        end
    end

    // ---- the location set ----
    reg [2:0]  L_bank [0:MAXLOC-1];
    reg [15:0] L_row  [0:MAXLOC-1];
    reg [15:0] L_col  [0:MAXLOC-1];
    reg [7:0]  L_data [0:MAXLOC-1];
    integer nloc = 0;

    task add_loc(input [2:0] bank, input [15:0] row, input [15:0] col);
        begin
            L_bank[nloc] = bank;
            L_row[nloc]  = row;
            L_col[nloc]  = col;
            L_data[nloc] = (nloc * 37 + 11) & 8'hFF;   // unique for the first 256 locations
            nloc = nloc + 1;
        end
    endtask

    // A value no location currently holds, so a read that came from the
    // wrong place cannot pass by coincidence.
    function [7:0] fresh_value(input [7:0] want);
        integer m, t;
        reg     clash;
        begin
            fresh_value = want;
            clash = 1'b1;
            while (clash) begin
                clash = 1'b0;
                for (m = 0; m < nloc; m = m + 1)
                    if (L_data[m] === fresh_value) clash = 1'b1;
                if (clash) fresh_value = fresh_value + 8'd1;
            end
        end
    endfunction

    integer errors = 0;
    integer addr_fails = 0;
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
    task loc_fail(input [255:0] phase, input integer idx, input [1023:0] why);
        begin
            if (addr_fails < 12)
                $display("  FAIL %0s loc %0d (bank %0d row %04h col %04h): %0s",
                         phase, idx, L_bank[idx], L_row[idx], L_col[idx], why);
            addr_fails = addr_fails + 1;
            errors = errors + 1;
        end
    endtask

    // One polite transaction: wait for idle, present, wait for completion,
    // then check the address that reached the real pins.
    integer pin_fails = 0;
    task op(input is_wr, input integer idx, input [7:0] wdata, input [255:0] phase);
        integer act0, col0, r0, guard;
        begin
            act0 = act_n; col0 = col_n; r0 = r_n;
            guard = 0;
            while ((is_wr ? write_busy : read_busy) && guard < 300) begin @(posedge clk); guard = guard + 1; end
            if (is_wr) begin
                write_bank <= L_bank[idx]; write_row <= L_row[idx]; write_col <= L_col[idx];
                write_data <= wdata; write_req <= 1'b1;
            end else begin
                read_bank <= L_bank[idx]; read_row <= L_row[idx]; read_col <= L_col[idx];
                read_req <= 1'b1;
            end
            @(posedge clk);
            write_req <= 1'b0; read_req <= 1'b0;
            @(posedge clk);
            guard = 0;
            while ((is_wr ? write_busy : read_busy) && guard < 300) begin @(posedge clk); guard = guard + 1; end
            repeat (4) @(posedge clk);

            if ((act_n - act0) != 1 || (col_n - col0) != 1) begin
                loc_fail(phase, idx, "transaction did not put exactly one ACT and one WR/RD on the pins");
                pin_fails = pin_fails + 1;
            end else begin
                if (pin_act_ba !== L_bank[idx])
                    begin loc_fail(phase, idx, "ACT bank on the pins is not the requested bank"); pin_fails = pin_fails + 1; end
                if (pin_act_a[14:0] !== L_row[idx][14:0])
                    begin loc_fail(phase, idx, "ACT row on the pins is not the requested row"); pin_fails = pin_fails + 1; end
                if (pin_col_ba !== L_bank[idx])
                    begin loc_fail(phase, idx, "WR/RD bank on the pins is not the requested bank"); pin_fails = pin_fails + 1; end
                if (pin_col_a[9:0] !== L_col[idx][9:0])
                    begin loc_fail(phase, idx, "WR/RD column on the pins is not the requested column"); pin_fails = pin_fails + 1; end
                if (pin_col_a[10] !== 1'b0)
                    begin loc_fail(phase, idx, "WR/RD A10 (auto-precharge) was not low"); pin_fails = pin_fails + 1; end
            end
            if (!is_wr && (r_n - r0) != 1)
                loc_fail(phase, idx, "read did not produce exactly one read_data_valid");
        end
    endtask

    integer i, j, nrows;

    initial begin
        $display("=== DDR3 address path, decoded memory (Phase 9 Stage 1, Part 15) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check_true("calibration completed before this test begins", calib_done && !calib_error);

        // 1. every bank, one row/column
        for (i = 0; i < 8; i = i + 1) add_loc(i[2:0], 16'h2AAA, 16'h0155);
        // 2. every single-bit row, plus the extremes, one bank/column
        add_loc(3'd3, 16'h0000, 16'h00AA);
        for (i = 0; i < 15; i = i + 1) add_loc(3'd3, 16'h0001 << i, 16'h00AA);
        add_loc(3'd3, 16'h7FFF, 16'h00AA);
        add_loc(3'd3, 16'h5555, 16'h00AA);
        // 3. every single-bit column, plus the extremes, one bank/row
        add_loc(3'd5, 16'h1234, 16'h0000);
        for (i = 0; i < 10; i = i + 1) add_loc(3'd5, 16'h1234, 16'h0001 << i);
        add_loc(3'd5, 16'h1234, 16'h03FF);
        add_loc(3'd5, 16'h1234, 16'h02AA);
        // 4. every low/high combination across bank, row and column
        for (i = 0; i < 8; i = i + 1)
            add_loc((i & 1) ? 3'd7 : 3'd0, (i & 2) ? 16'h4000 : 16'h0001, (i & 4) ? 16'h0200 : 16'h0001);

        check_true("the location set is large enough to mean something", nloc >= 40);

        // Phase 1: write every location, forward
        for (i = 0; i < nloc; i = i + 1) op(1'b1, i, L_data[i], "write");
        // the model must hold each one where the part would put it
        for (i = 0; i < nloc; i = i + 1)
            if (MEM.peek(L_bank[i], L_row[i], L_col[i]) !== L_data[i])
                loc_fail("write", i, "the memory model does not hold the written data at the requested location");

        // Phase 2: read every location back, in reverse
        for (i = nloc - 1; i >= 0; i = i - 1) begin
            op(1'b0, i, 8'h00, "readback");
            if (r_data !== L_data[i]) loc_fail("readback", i, "read returned data from the wrong place");
        end

        // Phase 3: overwrite every fifth location; the rest must not move
        for (i = 0; i < nloc; i = i + 5) begin
            L_data[i] = fresh_value(~L_data[i]);
            op(1'b1, i, L_data[i], "overwrite");
        end
        for (i = 0; i < nloc; i = i + 1) begin
            op(1'b0, i, 8'h00, "reread");
            if (r_data !== L_data[i]) loc_fail("reread", i, "wrong data after overwriting neighbours");
        end

        // Phase 4: locations never written read back as x. Each differs from
        // a written one in exactly one field.
        nrows = nloc;
        add_loc(3'd3, 16'h0006, 16'h00AA);          // an unwritten row (bank 3's rows: 0, single bits, 7FFF, 5555)
        add_loc(3'd5, 16'h1234, 16'h02BA);          // an unwritten column (02AA is written; this differs in bit 4)
        add_loc(3'd2, 16'h0001, 16'h0001);          // an unwritten bank (bank 2 was only ever used at row 2AAA)
        for (i = nrows; i < nloc; i = i + 1) begin
            op(1'b0, i, 8'h00, "unwritten");
            if (r_data !== 8'hxx) loc_fail("unwritten", i, "an unwritten location did not read back as x");
        end

        // Phase 5: bits outside the part's address decode are not address
        // bits, so two requests differing only there hit the same cell -
        // as on the real part (row A15; column A11).
        add_loc(3'd1, 16'h0055, 16'h0033);
        i = nloc - 1;
        op(1'b1, i, 8'hC1, "alias-a");
        add_loc(3'd1, 16'h8055, 16'h0833);              // row bit 15 and column bit 11 set
        j = nloc - 1;
        op(1'b1, j, 8'hC2, "alias-b");
        op(1'b0, i, 8'h00, "alias-read");
        check_true("bits outside the part's decode (row A15, column A11) alias, as on the real part", r_data === 8'hC2);

        repeat (20) @(posedge clk);

        $display("");
        $display("  locations: %0d, transactions on the pins: %0d ACT / %0d column commands, %0d REFRESH commands crossed",
                 nloc, act_n, col_n, refresh_cmds);
        $display("  address failures: %0d (of which on the pins: %0d)", addr_fails, pin_fails);
        check_true("every ACT and WR/RD carried the requested bank, row and column on the real pins", pin_fails == 0);
        check_true("every read returned what was written to its own location, and nothing else", addr_fails == 0);
        check_true("the memory model never ran out of room", !MEM.overflowed);
        check_true("no real protocol error by the end of the test", !model_error);
        check_true("no DQ/DQS write-burst timing error across every write", !dq_error);
        check_true("many refreshes were crossed, so integrity across them was exercised", refresh_cmds >= 5);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 ADDRESS PATH TEST PASSED");
        else             $display("DDR3 ADDRESS PATH TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
