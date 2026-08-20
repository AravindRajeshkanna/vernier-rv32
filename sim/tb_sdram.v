`timescale 1ns/1ps
// Unit test for rtl/soc/wb_sdram.v against sim/sdram_model.v.
//
// This runs before the SoC-level test on purpose. A controller bug seen
// through a booting CPU looks like "the program crashed", and the distance
// between that and "the write burst put the high halfword in the wrong
// column" is most of a debugging session. Here a failure names the word, the
// address, and what was expected.
//
// The model refuses illegal protocol outright (see its header), so a large
// part of what this testbench checks is not written down here at all: every
// access below also asserts tRCD, tRP, tRC, tRFC, refresh interval, row
// ownership and burst containment, in the model, at the point the command is
// issued.
//
// What is written down here is the part the model cannot know: that the data
// that comes back is the data that went in, through a 16-bit part, a 32-bit
// bus, byte lanes, row boundaries and bank boundaries.
module tb_sdram;
    localparam CLK_HZ   = 25_000_000;
    localparam ROW_BITS = 13;
    localparam COL_BITS = 9;
    localparam BA_BITS  = 2;

    // Bytes per row (512 columns x 2 bytes) and per bank rotation, derived
    // rather than written, because the two have to track wb_sdram.v's address
    // mapping and a duplicated 1024 would not.
    localparam ROW_BYTES  = (1 << COL_BITS) * 2;
    localparam BANK_SPAN  = ROW_BYTES * (1 << BA_BITS);

    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;          // 25 MHz

    reg  [31:0] wb_adr   = 0;
    reg  [31:0] wb_dat_w = 0;
    reg  [3:0]  wb_sel   = 4'b1111;
    reg         wb_we    = 0;
    reg         wb_cyc   = 0;
    reg         wb_stb   = 0;
    wire [31:0] wb_dat_r;
    wire        wb_ack;

    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [ROW_BITS-1:0] sd_a;
    wire [BA_BITS-1:0]  sd_ba;
    wire [1:0]  sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;
    wire        sd_ready;

    // The one place a real bidirectional bus is modelled. The controller
    // drives out/oe and reads `dq` back, so a controller that kept driving
    // through a read would show up here as x on the bus rather than as
    // silence.
    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    wb_sdram #(
        .CLK_HZ(CLK_HZ), .ROW_BITS(ROW_BITS),
        .COL_BITS(COL_BITS), .BA_BITS(BA_BITS)
    ) DUT (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n), .sdram_ras_n(sd_ras_n),
        .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
        .sdram_ready(sd_ready)
    );

    // Clocked 180 degrees from the controller, because that is what the board
    // does: fpga/sdram_clk_out.v drives the part's clock from an ODDRX1F so
    // its rising edge lands on the internal clock's falling edge. Clocking
    // the model from `clk` here would simulate a machine no board is, and
    // would be the *aligned* configuration that hardware rejected.
    sdram_model #(
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BA_BITS(BA_BITS),
        .MEM_WORDS(1 << 20)
    ) MEM (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );

    integer errors = 0;
    integer i;
    reg [31:0] got;
    reg [31:0] addr;

    task wb_write(input [31:0] a, input [31:0] d, input [3:0] s);
        begin
            @(negedge clk);
            wb_adr = a; wb_dat_w = d; wb_sel = s;
            wb_we = 1'b1; wb_cyc = 1'b1; wb_stb = 1'b1;
            @(negedge clk);
            while (!wb_ack) @(negedge clk);
            wb_cyc = 1'b0; wb_stb = 1'b0; wb_we = 1'b0;
        end
    endtask

    task wb_read(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk);
            wb_adr = a; wb_sel = 4'b1111;
            wb_we = 1'b0; wb_cyc = 1'b1; wb_stb = 1'b1;
            @(negedge clk);
            while (!wb_ack) @(negedge clk);
            d = wb_dat_r;
            wb_cyc = 1'b0; wb_stb = 1'b0;
        end
    endtask

    task expect_word(input [31:0] a, input [31:0] want, input [1023:0] what);
        begin
            wb_read(a, got);
            if (got !== want) begin
                $display("  FAIL %0s: [%08h] = %08h, expected %08h",
                         what, a, got, want);
                errors = errors + 1;
            end
        end
    endtask

    integer errs_before;
    task check(input [1023:0] name);
        begin
            $write("  %-34s", name);
            $display("%0s", (errors == errs_before) ? "ok" : "FAILED");
            errs_before = errors;
        end
    endtask

    initial begin
        $dumpfile("wave_sdram.vcd");
        $dumpvars(0, tb_sdram);

        repeat (4) @(posedge clk);
        rst = 0;
        errs_before = 0;

        $display("");
        $display("=== SDRAM controller test ===");

        // ---- the power-up sequence has to finish before anything works ----
        // Not merely "wait a bit": the model refuses every command until
        // 100 us has elapsed, so if the controller shortened its own wait the
        // run would already have stopped with a protocol error.
        wait (sd_ready);
        if ($time < 100_000) begin
            $display("  FAIL: sdram_ready before the 100 us power-up interval");
            errors = errors + 1;
        end
        check("power-up sequence");

        // ---- a word goes in and comes back ----
        wb_write(32'h0000_0000, 32'hDEAD_BEEF, 4'b1111);
        expect_word(32'h0000_0000, 32'hDEAD_BEEF, "first word");
        check("single word");

        // ---- walking ones, so a stuck or swapped data bit is named ----
        for (i = 0; i < 32; i = i + 1) begin
            wb_write(32'h0000_0100, 32'h1 << i, 4'b1111);
            expect_word(32'h0000_0100, 32'h1 << i, "walking ones");
        end
        check("walking ones across 32 bits");

        // ---- byte lanes ----
        // The halves of a 32-bit word go out as two separate 16-bit beats
        // with their own DQM, so a byte write is the case most likely to
        // mask the wrong beat.
        wb_write(32'h0000_0200, 32'h1122_3344, 4'b1111);
        wb_write(32'h0000_0200, 32'hxxxx_xx99, 4'b0001);
        expect_word(32'h0000_0200, 32'h1122_3399, "byte 0");
        wb_write(32'h0000_0200, 32'hxxxx_88xx, 4'b0010);
        expect_word(32'h0000_0200, 32'h1122_8899, "byte 1");
        wb_write(32'h0000_0200, 32'hxx77_xxxx, 4'b0100);
        expect_word(32'h0000_0200, 32'h1177_8899, "byte 2");
        wb_write(32'h0000_0200, 32'h66xx_xxxx, 4'b1000);
        expect_word(32'h0000_0200, 32'h6677_8899, "byte 3");
        check("byte lanes, each half separately");

        // ---- halfword lanes ----
        wb_write(32'h0000_0300, 32'hAAAA_5555, 4'b1111);
        wb_write(32'h0000_0300, 32'hxxxx_1234, 4'b0011);
        expect_word(32'h0000_0300, 32'hAAAA_1234, "low half");
        wb_write(32'h0000_0300, 32'h5678_xxxx, 4'b1100);
        expect_word(32'h0000_0300, 32'h5678_1234, "high half");
        check("halfword lanes");

        // ---- the last word of a row, and the first of the next ----
        // A burst of two starting in the last column would run off the end of
        // the row; the mapping is supposed to make that unreachable, and the
        // model errors out if it ever happens.
        addr = ROW_BYTES - 4;
        wb_write(addr,     32'h0BADF00D, 4'b1111);
        wb_write(addr + 4, 32'hFEEDFACE, 4'b1111);
        expect_word(addr,     32'h0BADF00D, "last word of row 0");
        expect_word(addr + 4, 32'hFEEDFACE, "first word of the next row");
        check("row boundary");

        // ---- crossing every bank, which forces precharge/activate churn ----
        for (i = 0; i < 8; i = i + 1)
            wb_write(i * ROW_BYTES, 32'hB000_0000 + i, 4'b1111);
        for (i = 0; i < 8; i = i + 1)
            expect_word(i * ROW_BYTES, 32'hB000_0000 + i, "bank walk");
        check("all four banks, twice round");

        // ---- interleaving two rows, so every access misses the open row ----
        for (i = 0; i < 16; i = i + 1) begin
            wb_write(32'h0001_0000 + i*4, 32'hC0000000 + i, 4'b1111);
            wb_write(32'h0008_0000 + i*4, 32'hD0000000 + i, 4'b1111);
        end
        for (i = 0; i < 16; i = i + 1) begin
            expect_word(32'h0001_0000 + i*4, 32'hC0000000 + i, "interleave lo");
            expect_word(32'h0008_0000 + i*4, 32'hD0000000 + i, "interleave hi");
        end
        check("interleaved rows, all misses");

        // ---- address uniqueness over more than 64 KB ----
        // The point of the whole phase: this span cannot be block RAM. If any
        // two addresses aliased - a dropped row bit, a bank field one place
        // out - the readback finds it.
        for (i = 0; i < 32768; i = i + 1)
            wb_write(32'h0002_0000 + i*4, 32'hA5A50000 + i, 4'b1111);
        for (i = 0; i < 32768; i = i + 1)
            expect_word(32'h0002_0000 + i*4, 32'hA5A50000 + i, "uniqueness");
        check("128 KB of unique addresses");

        // ---- data survives refresh ----
        // Idle for well over ten refresh intervals. The model is already
        // asserting that they arrive; this asserts that they do not eat the
        // data while they do.
        wb_write(32'h0000_0400, 32'h5AA55AA5, 4'b1111);
        repeat (4000) @(posedge clk);      // 160 us, ~20 refresh intervals
        expect_word(32'h0000_0400, 32'h5AA55AA5, "after 160 us idle");
        check("data survives refresh");

        $display("");
        $display("  refreshes issued: %0d", MEM.refresh_count);
        $display("  bytes proved unique: %0d", 32768*4);
        if (MEM.refresh_count < 20) begin
            $display("  FAIL: too few refreshes for the elapsed time");
            errors = errors + 1;
        end

        $display("");
        if (errors == 0) $display("SDRAM TEST PASSED");
        else             $display("SDRAM TEST FAILED (%0d errors)", errors);
        $display("");
        $finish;
    end

    // A hang is a failure with a name, not a run that never ends.
    initial begin
        #400_000_000;
        $display("SDRAM TEST FAILED (timeout)");
        $finish;
    end
endmodule
