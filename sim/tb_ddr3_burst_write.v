// A BL8 write burst through the real write-side drivers, with eight distinct bytes and a mask per beat - Phase 9 Stage 3
// (docs/roadmap/phase-09-ddr.md). The controller still writes one column per request (rtl/soc/ddr3_ecp5_top.v feeds the
// serdes one byte on all four UI and masks every beat but the first), so nothing in the design exercises what the drivers
// are for: a real burst. This does. It drives rtl/soc/ddr3_dqs_write_ecp5.v (the strobe), rtl/soc/ddr3_dq_serdes_ecp5.v (DQ)
// and rtl/soc/ddr3_dm_drv_ecp5.v (DM) directly, as the controller wires them, with a WRITE sent to sim/ddr3_dq_model.v on
// the command pins, and looks at which columns of the block the memory ends up with:
//   1  eight distinct bytes, nothing masked, from a column at the start of its block: beat b lands in column b, in order
//   2  from a column in the middle (low bits 3): the burst wraps inside the block of 8, beat b in column (3 + b) mod 8
//   3  a mask per beat (beats 3, 5, 6 and 7 masked): only the unmasked beats land, each in its own column
//   4  a single-beat write, as the controller does it, into a block that holds sentinels: only the addressed column changes
//   5  the same burst twice in a row with the strobe's gap between them: the second burst is not confused by the first
// The write data for a burst is given as two sclk cycles of four UI each, D0 first, which is how the primitives take it:
// cycle one beats 0 to 3, cycle two beats 4 to 7. The mask likewise, a bit per UI.
// What it does not establish: the same beat order and phase on the ECP5's real ODDRX2DQA / ODDRX2DQSB, which no simulation
// here has (the strobe pattern is LiteDRAM's, the beat order follows from it, and where DQSW and DQSW270 fall is bring-up's).
`timescale 1ns/1ps
module tb_ddr3_burst_write;
    localparam CLK_PERIOD = 40;
    localparam CLK_HZ     = 25_000_000;
    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    wire eclk, sclk, pll_locked;
    ddr3_eclk_pll PLL (.clk(clk), .eclk(eclk), .sclk(sclk), .locked(pll_locked));
    wire ck = eclk;

    // ---- the DRAM's command pins, driven from the test ----
    reg        ras_n = 1'b1, cas_n = 1'b1, we_n = 1'b1;
    reg  [2:0] ba = 3'd0;
    reg [14:0] a  = 15'd0;

    // ---- the write machinery under test ----
    reg         write_start = 1'b0;
    wire        dqs_o, dqs_oe, dqs_t, burst_active, active0;
    ddr3_dqs_write_ecp5 DQS_WR (
        .sclk(sclk), .eclk(eclk), .dqsw(eclk), .rst(rst),
        .write_start(write_start),
        .dqs_o(dqs_o), .dqs_oe(dqs_oe), .dqs_t(dqs_t), .burst_active(burst_active), .active0(active0)
    );

    // the burst to send: byte b and mask bit b (1 = masked) are beat b
    reg [63:0] burst_bytes = 64'd0;
    reg  [7:0] burst_mask  = 8'hFF;
    wire [7:0] b0 = burst_bytes[7:0],   b1 = burst_bytes[15:8],  b2 = burst_bytes[23:16], b3 = burst_bytes[31:24];
    wire [7:0] b4 = burst_bytes[39:32], b5 = burst_bytes[47:40], b6 = burst_bytes[55:48], b7 = burst_bytes[63:56];
    // the first active cycle carries beats 0 to 3 (D0 first), the second beats 4 to 7
    wire [7:0] wr_d0 = active0 ? b0 : b4;
    wire [7:0] wr_d1 = active0 ? b1 : b5;
    wire [7:0] wr_d2 = active0 ? b2 : b6;
    wire [7:0] wr_d3 = active0 ? b3 : b7;
    wire [3:0] dm_mask = active0 ? burst_mask[3:0] : (burst_active ? burst_mask[7:4] : 4'b1111);

    wire [7:0] dq;
    wire [7:0] dq_o, dq_oe, dq_t;
    wire [7:0] rd_q3, rd_q2, rd_q1, rd_q0;
    ddr3_dq_serdes_ecp5 #(.DQ_WIDTH(8)) SERDES (
        .sclk(sclk), .eclk(eclk), .rst(rst),
        .dqsr90(1'b0), .dqsw270(1'b0), .rdpntr(3'b0), .wrpntr(3'b0),
        .wr_d3(wr_d3), .wr_d2(wr_d2), .wr_d1(wr_d1), .wr_d0(wr_d0), .wr_en(burst_active),
        .rd_q3(rd_q3), .rd_q2(rd_q2), .rd_q1(rd_q1), .rd_q0(rd_q0),
        .dq_o(dq_o), .dq_oe(dq_oe), .dq_t(dq_t), .dq_i(dq)
    );
    genvar gb;
    generate for (gb = 0; gb < 8; gb = gb + 1) begin : DQ_BUS assign dq[gb] = dq_oe[gb] ? dq_o[gb] : 1'bz; end endgenerate

    wire dm_o, dm;
    ddr3_dm_drv_ecp5 DM_DRV (.sclk(sclk), .eclk(eclk), .rst(rst), .dqsw270(1'b0), .dm_mask(dm_mask), .dm_o(dm_o));
    assign dm = dm_o;

    wire dqs;
    assign dqs = dqs_oe ? dqs_o : 1'bz;

    // ---- the memory ----
    wire         dq_error;
    wire [511:0] dq_error_msg;
    wire [7:0]   mem_dq_o;
    wire         mem_dq_oe, mem_dqs_oe, mem_dqs_o;
    ddr3_dq_model MEM (
        .sclk(clk), .rst(rst), .ck(ck),
        .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .ba(ba), .a(a),
        .dq_pin(dq), .dqs_pin(dqs), .dm_pin(dm),
        .read_active(1'b0),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_oe(mem_dqs_oe), .mem_dqs_o(mem_dqs_o),
        .dq_error(dq_error), .dq_error_msg(dq_error_msg)
    );

    integer errors = 0;
    task check(input [1023:0] what, input cond);
        begin
            if (!cond) begin $display("  FAIL %0s", what); errors = errors + 1; end
            else $display("  ok   %0s", what);
        end
    endtask

    // ACTIVATE bank 1 row ROW, wait, WRITE at `col` with the burst set up, the strobe started in the cycle after it
    // (rtl/soc/ddr3_write_seq.v starts it then: preamble W+2, burst W+3 and W+4, postamble W+5), wait for the burst to end
    localparam [14:0] ROW = 15'h0123;
    task burst(input [14:0] col);
        begin
            @(posedge clk);
            ras_n <= 1'b0; cas_n <= 1'b1; we_n <= 1'b1; ba <= 3'd1; a <= ROW;
            @(posedge ck);
            ras_n <= 1'b1;
            repeat (3) @(posedge clk);
            // the cycle W: WRITE on the pins
            ras_n <= 1'b1; cas_n <= 1'b0; we_n <= 1'b0; ba <= 3'd1; a <= col;
            @(posedge ck);
            cas_n <= 1'b1; we_n <= 1'b1;
            @(posedge clk);                        // W+1: the strobe FSM is told to go
            write_start <= 1'b1;
            @(posedge clk);
            write_start <= 1'b0;
            repeat (8) @(posedge clk);             // past the postamble
        end
    endtask

    function [7:0] peekb(input [15:0] col);
        peekb = MEM.peek(3'd1, {1'b0, ROW}, col);
    endfunction

    integer c, bad;
    reg [7:0] want;
    initial begin
        $display("=== DDR3 BL8 write burst, eight distinct beats through the real drivers (Phase 9 Stage 3) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (12) @(posedge clk);

        // 1: eight distinct bytes, nothing masked, from the start of the block 0x10
        burst_bytes = {8'h88, 8'h77, 8'h66, 8'h55, 8'h44, 8'h33, 8'h22, 8'h11};
        burst_mask  = 8'h00;
        burst(15'h0010);
        bad = 0;
        for (c = 0; c < 8; c = c + 1) if (peekb(16'h0010 + c) !== (8'h11 + 8'h11 * c)) bad = bad + 1;
        check("1: eight distinct bytes land in eight columns, beat b in column b", bad == 0);

        // 2: from the middle of a block 0x20: columns 0x23 ... 0x27, then 0x20, 0x21, 0x22
        burst_bytes = {8'hA8, 8'hA7, 8'hA6, 8'hA5, 8'hA4, 8'hA3, 8'hA2, 8'hA1};
        burst_mask  = 8'h00;
        burst(15'h0023);
        bad = 0;
        for (c = 0; c < 8; c = c + 1) if (peekb(16'h0020 + ((3 + c) % 8)) !== (8'hA1 + c)) bad = bad + 1;
        check("2: from column 3 the burst wraps inside the block: beat b in column (3 + b) mod 8", bad == 0);

        // 3: a mask per beat: beats 3, 5, 6 and 7 masked, from the start of the block 0x30
        burst_bytes = {8'hE8, 8'hE7, 8'hE6, 8'hE5, 8'hE4, 8'hE3, 8'hE2, 8'hE1};
        burst_mask  = 8'b1110_1000;
        burst(15'h0030);
        bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            want = burst_mask[c] ? 8'hxx : (8'hE1 + c);
            if (peekb(16'h0030 + c) !== want) bad = bad + 1;
        end
        check("3: only the unmasked beats land (beats 0, 1, 2 and 4), each in its own column", bad == 0);

        // 4: a single-beat write, as the controller does it, into a block of sentinels
        burst_bytes = {8'h58, 8'h57, 8'h56, 8'h55, 8'h54, 8'h53, 8'h52, 8'h51};
        burst_mask  = 8'h00;
        burst(15'h0040);                                          // the sentinels: column 0x40 + n holds 0x51 + n
        burst_bytes = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC3};
        burst_mask  = 8'b1111_1110;                              // beat 0 only
        burst(15'h0045);
        bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            want = (c == 5) ? 8'hC3 : (8'h51 + c);
            if (peekb(16'h0040 + c) !== want) bad = bad + 1;
        end
        check("4: a one-beat write changes the addressed column and nothing else of the block", bad == 0);

        // 5: two bursts in a row, different blocks
        burst_bytes = {8'h18, 8'h17, 8'h16, 8'h15, 8'h14, 8'h13, 8'h12, 8'h11};
        burst_mask  = 8'h00;
        burst(15'h0050);
        burst_bytes = {8'h28, 8'h27, 8'h26, 8'h25, 8'h24, 8'h23, 8'h22, 8'h21};
        burst(15'h0058);
        bad = 0;
        for (c = 0; c < 8; c = c + 1) begin
            if (peekb(16'h0050 + c) !== (8'h11 + c)) bad = bad + 1;
            if (peekb(16'h0058 + c) !== (8'h21 + c)) bad = bad + 1;
        end
        check("5: two bursts one after the other each land whole", bad == 0);

        check("the memory model saw no violation of the strobe, DQ or DM rules throughout", !dq_error);
        if (dq_error) $display("       (%0s)", dq_error_msg);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 BURST WRITE TEST PASSED");
        else             $display("DDR3 BURST WRITE TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
