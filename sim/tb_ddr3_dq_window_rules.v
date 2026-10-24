// Self-test for the write-burst rules of sim/ddr3_dq_model.v - Phase 9 Stage 1, Part 17, rewritten at beat resolution in
// Stage 3 (docs/roadmap/phase-09-ddr.md). Same discipline as sim/tb_ddr3_model_banks.v: a checker whose rules cannot be
// shown to fire is not a checker, and the real design, once aligned, never breaks them - so each rule gets its own
// directed stream on its own model instance, driven straight onto its pins, plus legal controls so a rule that is too
// strict fails here instead of silently rejecting a correct controller.
//
// Every instance sees the same commands - an ACTIVATE, then a WRITE three sclk later - and differs only in what its DQS,
// DQ and DM pins do around the WRITE's CK edge (t = 0 below, in ns). The legal burst, for a WRITE whose CK edge is at 0 and
// WL = 6 CK = 120 ns:
//     DQS driven low from 70 ns, then eight edges at 120, 130, ... 190 ns (rising at 120, falling at 130, ...), then low
//     until 230 ns, then high-Z;
//     DQ driven from 115 to 195 ns, beat b valid from 115 + 10 b to 125 + 10 b (the strobe edge in the middle of it);
//     DM at each beat, as the instance says.
//   0  legal, DM unconnected (`z`, what every testbench predating Part 22 does): beat 0 lands in the addressed column, and
//      nothing else of the block of 8 does
//   1  legal, and DQ driven during the preamble and postamble too - the DRAM ignores DQ there, so a rule that rejects it is
//      too strict
//   2  the whole burst 40 ns early
//   3  the whole burst 40 ns late
//   4  the burst 4 ns late: inside tDQSS (+-5 ns), so accepted - a control, a rule that rejects it is too strict
//   5  the burst 7 ns late: outside tDQSS
//   6  DQ not driven at beat 2, where DM is low
//   7  DQ not driven at beat 0, where DM is low
//   8  DQ not driven at beats 4 to 7, where DM is high: accepted (a masked beat's data is not looked at)
//   9  DQS carries four edges and stops
//  10  DQS carries nine edges
//  11  one edge (the third) 8 ns late: outside tDQSS
//  12  no preamble: DQS high-Z until its first rising edge
//  13  a preamble of 10 ns: DQS driven low only that long before the first rising edge
//  14  no postamble: DQS high-Z the instant the last edge is done
//  15  DQS driven again after the burst
//  16  a DQS burst with no WRITE behind it (a READ, then - once the model's own read drive is over - the burst)
//  17  a WRITE with no burst at all
// And what lands where, on their own column (COL2, whose low three bits are 5, so the burst wraps inside the block of 8
// and a mutated column formula that does not wrap, or adds the wrong amount, lands somewhere else):
//  18  a legal burst, DM low for beat 0 only: the addressed column holds the byte, the other seven of the block stay unwritten
//  19  DM low for all eight beats, a distinct byte per beat: the eight columns the sequential order visits from COL2 - 5, 6,
//      7, then 0, 1, 2, 3, 4 of the block - each receive their own beat's byte. The hazard the data mask exists to prevent,
//      reproduced directly against the model, and the burst order proved
//  20  DM low for beats 0 to 3 only: what the design did until Phase 9 Stage 3, when one DM level covered a whole sclk
//      cycle. Four columns written (5, 6, 7 and 0 of the block), not one
//  21  DQ changing at the strobe edges (on the strobe's own grid, not half a UI ahead of it): no setup, and no hold
//  22  DM changing at the strobe edges: the same for the mask
//  23  DQ changing 1 ns after each strobe edge: setup is met (the previous change was 9 ns before), hold is not
//
// Under Verilator a floating strobe reads as low (a two-state simulator), so the rules that need high-Z (12, 13, 14, 15,
// and the first rule that fires in 2 and 16) are Icarus's; the others, the edges, the data and the mask, are both's.
`timescale 1ns/1ps
module tb_ddr3_dq_window_rules;
    localparam CLK_PERIOD = 40;
    localparam N          = 24;
    localparam FE         = 120;     // the legal first strobe edge, ns after the WRITE's CK edge

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    // the edge clock, whose rising edges fall 10 ns after each clk edge - CK
    wire eclk, pll_sclk, pll_locked;
    ddr3_eclk_pll PLL (.clk(clk), .eclk(eclk), .sclk(pll_sclk), .locked(pll_locked));
    wire ck = eclk;

    reg [N-1:0]      ras_n = {N{1'b1}};
    reg [N-1:0]      cas_n = {N{1'b1}};
    reg [N-1:0]      we_n  = {N{1'b1}};
    reg [3*N-1:0]    ba    = {3*N{1'b0}};
    reg [15*N-1:0]   a     = {15*N{1'b0}};
    // DQ, DQS and DM reach each model instance through explicit output enables. The model's pin ports are `inout` (so
    // Verilator accepts a tri-state net into them - see verilator_ddr3 in the Makefile), and an inout port must connect
    // to a net, not a reg.
    reg [8*N-1:0]    dq_v   = {8*N{1'b0}};
    reg [N-1:0]      dq_oe  = {N{1'b0}};
    reg [N-1:0]      dqs_v  = {N{1'b0}};
    reg [N-1:0]      dqs_oe = {N{1'b0}};
    reg [N-1:0]      dm_v   = {N{1'b0}};
    reg [N-1:0]      dm_oe  = {N{1'b0}};

    wire [N-1:0]     errs;
    wire [512*N-1:0] msgs;
    // what each instance's memory holds in the block of 8 columns 0x08 to 0x0F (bank 1, row ROW): byte c of instance i is at
    // [(8 * i + c) * 8 +: 8]. peek() reads the model's internal store, which a generate-scope reference with a variable index
    // cannot reach from a task, so each instance publishes its eight bytes here.
    wire [64*N-1:0]  blk;

    localparam [15:0] ROW  = 16'h0123;
    localparam [15:0] COL  = 16'h000A;
    // Instances 18 to 20's own column: its low three bits are 5, so a burst from it wraps inside the block 0x08 to 0x0F
    localparam [15:0] COL2 = 16'h000D;

    function [15:0] col_of(input integer i);
        col_of = (i >= 18) ? COL2 : COL;
    endfunction

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : M
            wire        dqs_pin;
            wire [7:0]  dq_pin;
            wire        dm_pin;
            wire        e;
            wire [511:0] m;
            wire [7:0]  mq_o;
            wire        mq_oe, mqs_oe, mqs_o;
            ddr3_dq_model MODEL (
                .sclk(clk), .rst(rst), .ck(ck),
                .ras_n(ras_n[g]), .cas_n(cas_n[g]), .we_n(we_n[g]),
                .ba(ba[3*g +: 3]), .a(a[15*g +: 15]),
                .dq_pin(dq_pin), .dqs_pin(dqs_pin), .dm_pin(dm_pin),
                .read_active(1'b0),
                .mem_dq_o(mq_o), .mem_dq_oe(mq_oe), .mem_dqs_oe(mqs_oe), .mem_dqs_o(mqs_o),
                .dq_error(e), .dq_error_msg(m)
            );
            assign dqs_pin = dqs_oe[g] ? dqs_v[g] : 1'bz;
            assign dq_pin  = dq_oe[g] ? dq_v[8*g +: 8] : 8'hzz;
            assign dm_pin  = dm_oe[g] ? dm_v[g] : 1'bz;
            assign errs[g] = e;
            assign msgs[512*g +: 512] = m;
            // peek() reads the model's internal store, so it has to be re-evaluated as that changes - a continuous assign of
            // a function of constants would not be.
            reg [63:0] pk;
            integer    pc;
            always @(posedge clk) for (pc = 0; pc < 8; pc = pc + 1) pk[8*pc +: 8] = MODEL.peek(3'd1, ROW, 16'h0008 + pc);
            assign blk[64*g +: 64] = pk;
        end
    endgenerate

    // ---- the waveforms, as functions of the instance and the time n (ns after the WRITE's CK edge) ----
    // when instance i's first strobe edge falls
    function integer first_edge(input integer i);
        case (i)
            2:       first_edge = FE - 40;
            3:       first_edge = FE + 40;
            4:       first_edge = FE + 4;
            5:       first_edge = FE + 7;
            16:      first_edge = FE + 350;
            default: first_edge = FE;
        endcase
    endfunction
    function integer n_edges(input integer i);
        case (i)
            9:       n_edges = 4;
            10:      n_edges = 9;
            default: n_edges = 8;
        endcase
    endfunction
    // when edge e falls
    function integer edge_t(input integer i, input integer e);
        edge_t = first_edge(i) + 10 * e + ((i == 11 && e == 2) ? 8 : 0);
    endfunction

    // the strobe: {oe, level}
    function [1:0] dqs_at(input integer i, input integer n);
        integer c, e, fe, last, pre, post;
        begin
            fe   = first_edge(i);
            last = edge_t(i, n_edges(i) - 1);
            pre  = (i == 13) ? fe - 10 : fe - 50;
            post = (i == 14) ? last + 1 : last + 40;
            c = 0;
            for (e = 0; e < n_edges(i); e = e + 1) if (n >= edge_t(i, e)) c = c + 1;
            dqs_at = 2'b00;                                           // high-Z
            if (i == 17) dqs_at = 2'b00;                              // a WRITE with no burst
            else if (i == 12) begin                                   // no preamble: z until the first rising edge
                if (n >= fe && n < post) dqs_at = {1'b1, (c % 2 == 1) ? 1'b1 : 1'b0};
            end else if (n >= pre && n < post) begin
                if (c == 0)  dqs_at = 2'b10;                          // driven low, ahead of the first edge
                else if (c == n_edges(i) && n_edges(i) == 9) dqs_at = (n < last + 10) ? 2'b11 : 2'b10;
                else         dqs_at = {1'b1, (c % 2 == 1) ? 1'b1 : 1'b0};
            end
            if (i == 15 && n >= last + 150 && n < last + 190) dqs_at = 2'b10;    // driven again, long after the burst
        end
    endfunction

    // the beat the time falls in (beat b is valid from fe - 5 + 10 b to fe + 5 + 10 b), or -1
    // `sh` shifts the data window earlier by that many ns (5 puts a beat's change on the strobe edge, not half a UI before it)
    function integer beat_at(input integer i, input integer n, input integer sh);
        integer fe;
        begin
            fe = first_edge(i);
            beat_at = (n >= fe - 5 - sh && n < fe + 75 - sh) ? (n - fe + 5 + sh) / 10 : -1;
        end
    endfunction

    // DQ: {oe, byte}. A distinct byte per beat for instance 19 (so the column each beat reaches shows)
    function [8:0] dq_at(input integer i, input integer n);
        integer b, fe, post, pre;
        reg [7:0] byte_v;
        reg       oe;
        begin
            fe = first_edge(i); b = beat_at(i, n, (i == 21) ? 5 : (i == 23) ? -6 : 0);
            pre = fe - 50; post = edge_t(i, n_edges(i) - 1) + 40;
            byte_v = 8'hA0 + i + (((i == 19 || i == 23) && b >= 0) ? b : 0);
            oe = (b >= 0);
            if ((i == 1 || i == 23) && n >= pre && n < post) oe = 1'b1;          // also in the preamble and postamble
            if (i == 6 && b == 2) oe = 1'b0;
            if (i == 7 && b == 0) oe = 1'b0;
            if (i == 8 && b >= 4) oe = 1'b0;
            if (i == 17) oe = 1'b0;
            dq_at = {oe, byte_v};
        end
    endfunction

    // DM: {oe, level}. Unconnected (z) for the instances that predate the mask, driven for 6, 7, 8 and 18 to 20
    function [1:0] dm_at(input integer i, input integer n);
        integer b;
        reg mode_drv, lvl;
        begin
            b = beat_at(i, n, (i == 22) ? 5 : 0);
            mode_drv = (i == 6 || i == 7 || i == 8 || i >= 18);
            lvl = 1'b1;                                                          // masked outside the burst
            if (b >= 0) begin
                case (i)
                    6, 19:   lvl = 1'b0;                                         // every beat unmasked
                    20:      lvl = (b < 4) ? 1'b0 : 1'b1;                        // beats 0 to 3
                    default: lvl = (b == 0) ? 1'b0 : 1'b1;                       // beat 0 only
                endcase
            end
            dm_at = {mode_drv, lvl};
        end
    endfunction

    integer errors = 0;
    task expect_ok(input integer i, input [1023:0] what);
        begin
            if (errs[i]) begin
                $display("  FAIL %0s: model rejected a legal burst: %0s", what, msgs[512*i +: 512]);
                errors = errors + 1;
            end else
                $display("  ok   %0s", what);
        end
    endtask
    task expect_msg(input integer i, input [1023:0] what, input [511:0] msg);
        begin
            if (!errs[i]) begin
                $display("  FAIL %0s: model did NOT flag the violation", what);
                errors = errors + 1;
            end else if (msgs[512*i +: 512] !== msg) begin
                $display("  FAIL %0s: wrong rule fired: %0s", what, msgs[512*i +: 512]);
                errors = errors + 1;
            end else
                $display("  ok   %0s", what);
        end
    endtask
    task expect_msg_either(input integer i, input [1023:0] what, input [511:0] m1, input [511:0] m2);
        begin
            if (!errs[i]) begin
                $display("  FAIL %0s: model did NOT flag the violation", what);
                errors = errors + 1;
            end else if (msgs[512*i +: 512] !== m1 && msgs[512*i +: 512] !== m2) begin
                $display("  FAIL %0s: wrong rule fired: %0s", what, msgs[512*i +: 512]);
                errors = errors + 1;
            end else
                $display("  ok   %0s", what);
        end
    endtask
    // a rule that needs high-Z: Icarus's. Verilator reads a floating strobe as low, so there it either sees nothing or a
    // different rule first; what is asserted there is only that a model that flags something flags it with a message.
    task expect_msg_z(input integer i, input [1023:0] what, input [511:0] msg_icarus, input [511:0] msg_verilator);
        begin
`ifdef VERILATOR
            if (msg_verilator == 0) $display("  --   %0s: not visible to a two-state simulator (skipped under Verilator)", what);
            else expect_msg(i, what, msg_verilator);
`else
            expect_msg(i, what, msg_icarus);
`endif
        end
    endtask
    task expect_cell(input integer i, input [1023:0] what, input [15:0] col, input [7:0] want);
        reg [7:0] got;
        begin
            got = blk[(8 * i + (col - 16'h0008)) * 8 +: 8];
            if (got !== want) begin
                $display("  FAIL %0s: column %03h holds %02h, expected %02h", what, col, got, want);
                errors = errors + 1;
            end else $display("  ok   %0s", what);
        end
    endtask
    // every column of the block 0x08 to 0x0F other than the listed ones is unwritten (x)
    task expect_block_untouched(input integer i, input [1023:0] what, input [7:0] written_mask);
        integer c, bad;
        begin
            bad = 0;
            for (c = 0; c < 8; c = c + 1)
                if (!written_mask[c] && blk[(8 * i + c) * 8 +: 8] !== 8'hxx) bad = bad + 1;
            if (bad != 0) begin
                $display("  FAIL %0s: %0d columns of the block that should be unwritten were written", what, bad);
                errors = errors + 1;
            end else $display("  ok   %0s", what);
        end
    endtask

    integer t, i, n, w;
    reg [1:0] dqsv, dmv;
    reg [8:0] dqv;
    initial begin
        $display("=== DDR3 write-burst rules, self-test, at beat resolution (Phase 9 Stage 3) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;
        repeat (12) @(posedge clk);

        // the ACTIVATE on a clk edge, the WRITE (or the READ, for instance 16) three clk edges later; each is sampled by the
        // CK rising edge ten ns after the clk edge it was driven on, and then the bus goes back to NOP
        @(posedge clk);
        ras_n <= {N{1'b0}}; cas_n <= {N{1'b1}}; we_n <= {N{1'b1}};
        for (i = 0; i < N; i = i + 1) begin ba[3*i +: 3] <= 3'd1; a[15*i +: 15] <= ROW[14:0]; end
        @(posedge ck);
        ras_n <= {N{1'b1}}; cas_n <= {N{1'b1}}; we_n <= {N{1'b1}};
        repeat (3) @(posedge clk);
        ras_n <= {N{1'b1}}; cas_n <= {N{1'b0}};
        for (i = 0; i < N; i = i + 1) begin
            ba[3*i +: 3] <= 3'd1; a[15*i +: 15] <= col_of(i);
            we_n[i] <= (i == 16) ? 1'b1 : 1'b0;           // instance 16: a READ, so the burst that follows has no WRITE behind it
        end
        // t = 0 is the CK edge that samples the WRITE: the first CK rising edge after the clk edge it was driven on
        @(posedge ck);
        ras_n <= {N{1'b1}}; cas_n <= {N{1'b1}}; we_n <= {N{1'b1}};
        for (n = 0; n <= 620; n = n + 1) begin
            for (i = 0; i < N; i = i + 1) begin
                dqsv = dqs_at(i, n);  dqv = dq_at(i, n);  dmv = dm_at(i, n);
                dqs_oe[i] <= dqsv[1];  dqs_v[i] <= dqsv[0];
                dq_oe[i]  <= dqv[8];   dq_v[8*i +: 8] <= dqv[7:0];
                dm_oe[i]  <= dmv[1];   dm_v[i] <= dmv[0];
            end
            #1;
        end
        repeat (10) @(posedge clk);

        expect_ok(0, "a legal burst at exactly WRITE + WL is accepted");
        expect_cell(0, "  and beat 0's byte lands in the addressed cell", COL, 8'hA0);
        expect_block_untouched(0, "  and, DM unconnected, no other column of the block is written", 8'h04);   // column 0x0A is bit 2
        expect_ok(1, "a legal burst that also drives DQ in the preamble and postamble is accepted");
        expect_cell(1, "  and its byte lands", COL, 8'hA1);
        expect_msg_z(2, "a burst 40 ns early is rejected",
                     "DQS driven outside the write burst a WRITE command asked for",
                     "DQS toggled outside the burst a WRITE command asked for");
        expect_msg(3, "a burst 40 ns late is rejected",
                   "write burst: a DQS edge outside tDQSS of where the WRITE puts it");
        expect_ok(4, "a burst 4 ns late, inside tDQSS, is accepted");
        expect_cell(4, "  and its byte lands", COL, 8'hA4);
        expect_msg(5, "a burst 7 ns late, outside tDQSS, is rejected",
                   "write burst: a DQS edge outside tDQSS of where the WRITE puts it");
        expect_msg(6, "DQ not driven at beat 2, where DM is low, is rejected",
                   "write burst: DQ not driven at a beat DM does not mask");
        expect_msg(7, "DQ not driven at beat 0, where DM is low, is rejected",
                   "write burst: DQ not driven at a beat DM does not mask");
        expect_ok(8, "DQ not driven at the masked beats 4 to 7 is accepted");
        expect_cell(8, "  and beat 0's byte lands", COL, 8'hA8);
        expect_msg(9, "a strobe with four edges is rejected",
                   "write burst: DQS stopped before the eighth beat");
        expect_msg(10, "a strobe with nine edges is rejected",
                   "write burst: more than eight DQS edges");
        expect_msg(11, "one edge 8 ns late is rejected",
                   "write burst: a DQS edge outside tDQSS of where the WRITE puts it");
        expect_msg_z(12, "no preamble is rejected",
                     "write preamble: DQS not driven low before its first rising edge", 0);
        expect_msg_z(13, "a preamble of 10 ns is rejected",
                     "write preamble: DQS not driven low before its first rising edge", 0);
        expect_msg_z(14, "no postamble is rejected",
                     "write postamble: DQS not driven low after the burst", 0);
        expect_msg_z(15, "DQS driven again after the burst is rejected",
                     "DQS driven outside the write burst a WRITE command asked for", 0);
        expect_msg_z(16, "a strobe with no WRITE behind it is rejected",
                     "DQS driven outside the write burst a WRITE command asked for",
                     "DQS toggled outside the burst a WRITE command asked for");
        expect_msg(17, "a WRITE with no burst at all is reported",
                   "a WRITE command without its DQS burst");
        // a burst that was rejected must leave nothing in the cell
        expect_block_untouched(3,  "a burst that was rejected for its timing leaves its block unwritten", 8'h00);
        expect_block_untouched(16, "a strobe with no WRITE behind it leaves its block unwritten", 8'h00);

        // the data mask, and the order the burst visits columns in
        expect_ok(18, "DM low for beat 0 only: a legal burst");
        expect_cell(18, "  the addressed column holds the byte", COL2, 8'hA0 + 18);
        expect_block_untouched(18, "  and the other seven columns of the block are unwritten", 8'h20);          // column 0x0D is bit 5
        expect_ok(19, "DM low for all eight beats, a byte per beat: a legal burst");
        for (w = 0; w < 8; w = w + 1)
            expect_cell(19, "  beat b lands in column {block, (5 + b) mod 8}", 16'h0008 + ((5 + w) % 8), 8'hA0 + 19 + w);
        expect_ok(20, "DM low for beats 0 to 3 only (what one level per sclk cycle did): a legal burst");
        for (w = 0; w < 4; w = w + 1)
            expect_cell(20, "  beats 0 to 3 land in four columns", 16'h0008 + ((5 + w) % 8), 8'hA0 + 20);
        expect_block_untouched(20, "  and beats 4 to 7, masked, leave the other four unwritten", 8'hE1);        // columns 5, 6, 7 and 0: bits 5, 6, 7, 0 -> 0xE1

        // setup and hold: the same legal burst, but DQ (21) or DM (22) moves at the strobe's edges instead of half a UI before them.
        // Which of the two rules fires first depends on which of the two events at that instant the simulator runs first.
        expect_msg_either(21, "DQ moving at the strobe edges is rejected (no setup, no hold)",
                          "write burst: DQ or DM changed less than tDS before a DQS edge",
                          "write burst: DQ or DM changed less than tDH after a DQS edge");
        expect_msg_either(22, "DM moving at the strobe edges is rejected (no setup, no hold)",
                          "write burst: DQ or DM changed less than tDS before a DQS edge",
                          "write burst: DQ or DM changed less than tDH after a DQS edge");

        expect_msg(23, "DQ moving 1 ns after the strobe edges is rejected (hold alone)",
                   "write burst: DQ or DM changed less than tDH after a DQS edge");

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 WRITE BURST RULES TEST PASSED");
        else             $display("DDR3 WRITE BURST RULES TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #4_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
