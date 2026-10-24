// Standalone proof for Phase 9 Stage 2, Part 1 (docs/roadmap/phase-09-ddr.md):
// rtl/soc/wb_ddr.v against a real DDR3 protocol checker and a real
// per-location memory model, driven by a plain Wishbone master - not yet
// wired into rtl/soc/soc_top.v (that is later, separate work).
//
// Proves: a 32-bit store then load round-trips exactly (through a real
// read-fill miss, since nothing is resident at reset); a second store to
// the same already-open block updates the cached copy coherently (a hit,
// not a re-fill); a store to a different block evicts cleanly and a later
// re-read of the first block re-fills and still returns what was written
// (nothing was corrupted by the neighbour-column write-through mechanism
// the header explains); and a partial-byte store (`wb_sel` not all set)
// changes only the selected bytes, leaving the others exactly as they
// were.
//
// Since Phase 9 Stage 3 (8-beat bursts, part C, read half) a fill is ONE controller read, not eight: the slave asks for the
// block's first column and takes all eight columns from the burst that comes back (`read_burst`). This holds that too:
//   - a miss sends exactly one READ command to the DRAM, to the block's first column, and is acknowledged within a bound
//     (measured: it took eight times as long when a fill was eight reads);
//   - all four words of a block come back right after a fill, each from its own column (eight different words, the block read
//     from a cold start of the slave, so the columns' order is what the data shows);
//   - a fill whose burst the controller rejects (a lane's capture window never opened) is acknowledged, does not hang the bus,
//     and does not mark the block resident, so the next access fills it again and gets what was stored (Icarus only: it forces
//     the controller's verdict).
//
// Since Stage 2, Part 14 the slave is x16 and its window the part's whole 512 MB, and this holds that too:
//   - the address geometry, written out again here from the part's own addressing (row A[28:14],
//     bank A[13:11], column A[10:1], lane A[0]) and not from the slave's: a word written at each of
//     thirteen addresses (the first and the last, a walking one through the row, bank and column, the
//     edge of the old 256 MB window, the first word above it, and a pair 256 MB apart) lands in the
//     cell and lane that geometry names, in the right plane of the memory, and reads back as itself
//     through the bus;
//   - a single byte stored at each of the 16 offsets of a block, each in turn, changes exactly that
//     byte of the word and no other, in either lane;
//   - a random sweep across the whole 512 MB against a byte-wise reference: stores with random
//     byte selects, then every word read back, each byte compared where the reference holds one.
`timescale 1ns/1ps
module tb_wb_ddr;
    localparam CLK_HZ    = 25_000_000;
    localparam CLK_PERIOD = 40;   // 25 MHz

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;
    reg rst = 1'b1;

    reg         wb_cyc, wb_stb, wb_we;
    reg  [31:0] wb_adr, wb_dat_w;
    reg  [3:0]  wb_sel;
    wire [31:0] wb_dat_r;
    wire        wb_ack;

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
    wire calib1_done, calib1_error;
    wire [2:0] calib1_readclksel;

    wb_ddr WB (
        .rst_warm(1'b0),
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
        .ddr3_ck(ddr3_ck),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .pll_locked(pll_locked), .dll_locked(dll_locked), .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error),
        .calib1_done(calib1_done), .calib1_readclksel(calib1_readclksel),
        .calib1_error(calib1_error)
    );

    // ---- the real protocol checker, same as every Stage 1 integration
    // testbench ----
    wire        model_error;
    wire [511:0] model_error_msg;
    wire        model_seq_done;
    ddr3_model #(.CLK_HZ(CLK_HZ)) PROTO (
        .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done(model_seq_done)
    );

    // ---- the real per-location DQ memory - lane 0's own real data, the
    // same model wb_ddr.v's own header explains is what makes 16 separate
    // single-byte calls safe ----
    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_oe, mem_dqs_o;
    wire       dq_error;
    wire [511:0] dq_error_msg;
    ddr3_dq_model MEM (
        .sclk(WB.DDR.sclk), .rst(WB.DDR.rst_all),
        .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
        .read_active(WB.DDR.read_active_final),
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

    // Lane 1's memory (Part 26): the controller takes no request until both lanes have calibrated, and
    // a lane calibrates by looping its pattern back through a DRAM; the slave stores in it from Part 14.
    ddr3_lane1_mem LANE1 (
        .sclk(WB.DDR.sclk), .rst(WB.DDR.rst_all), .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dqu(ddr3_dqu), .udqs(ddr3_udqs), .udm(ddr3_udm),
        .read_active(WB.DDR.read_active_final_1), .dq_error()
    );

    integer errors = 0;
    task check(input [511:0] what, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %h, expected %h", what, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s (%h)", what, got);
            end
        end
    endtask

    // One full Wishbone classic-cycle access, waiting for wb_ack.
    task wb_access(input we, input [31:0] adr, input [31:0] dat_w, input [3:0] sel,
                   output [31:0] dat_r);
        begin
            @(posedge clk);
            wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= we;
            wb_adr <= adr; wb_dat_w <= dat_w; wb_sel <= sel;
            @(posedge clk);
            while (!wb_ack) @(posedge clk);
            dat_r = wb_dat_r;
            wb_cyc <= 1'b0; wb_stb <= 1'b0; wb_we <= 1'b0;
            @(posedge clk);
        end
    endtask

    // Latches if the slave ever acknowledges while calib_done is still low.
    reg early_ack = 1'b0;
    always @(posedge clk) if (wb_ack && !calib_done) early_ack <= 1'b1;

    integer ack_count = 0;
    always @(posedge clk) if (wb_ack) ack_count <= ack_count + 1;
    integer n_ack0, t_wait;

    // READ commands on the pins, as the DRAM samples them (CS# is tied low on the board, so any slot with RAS# high, CAS# low and
    // WE# high is a READ), and where the last of them went.
    integer rd_cmds = 0;
    reg [2:0]  rd_last_ba;
    reg [9:0]  rd_last_col;
    always @(posedge ddr3_ck)
        if (!rst && ddr3_ras_n === 1'b1 && ddr3_cas_n === 1'b0 && ddr3_we_n === 1'b1) begin
            rd_cmds    = rd_cmds + 1;
            rd_last_ba  = ddr3_ba;
            rd_last_col = ddr3_a[9:0];
        end
    // clock cycles an access takes: the slave's own accounting of request to acknowledge
    integer t_acc;
    // how long before the controller says its read transaction is over (`read_busy` falls) the burst arrived
    integer cyc = 0, t_burst_seen = -1, t_busy_fell = -1;
    reg busy_prev = 1'b0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (WB.read_burst_valid) t_burst_seen = cyc;
        if (busy_prev && !WB.read_busy) t_busy_fell = cyc;
        busy_prev <= WB.read_busy;
    end

    // ---- the part's own geometry, for the x16 checks (Phase 9 Stage 2, Part 14) ----
    // byte address -> bank, row, column, lane. Written from the part's addressing, not from rtl/soc/wb_ddr.v.
    reg [2:0]  c_bank;
    reg [14:0] c_row;
    reg [9:0]  c_col;
    reg        c_lane;
    task cell_of(input [31:0] a);
        begin
            c_row  = a[28:14];
            c_bank = a[13:11];
            c_col  = a[10:1];
            c_lane = a[0];
        end
    endtask

    // the byte a lane's memory holds at a cell
    reg [7:0] p_byte;
    reg       p_found;
    task peek_cell(input lane, input [2:0] bk, input [14:0] rw, input [9:0] cl);
        integer j;
        begin
            p_found = 1'b0; p_byte = 8'hxx;
            if (!lane) begin
                for (j = 0; j < MEM.n_used; j = j + 1)
                    if (MEM.k_used[j] && MEM.k_bank[j] === bk && MEM.k_row[j] === rw && MEM.k_col[j] === cl) begin
                        p_found = 1'b1; p_byte = MEM.k_data[j];
                    end
            end else begin
                for (j = 0; j < LANE1.MEM.n_used; j = j + 1)
                    if (LANE1.MEM.k_used[j] && LANE1.MEM.k_bank[j] === bk && LANE1.MEM.k_row[j] === rw && LANE1.MEM.k_col[j] === cl) begin
                        p_found = 1'b1; p_byte = LANE1.MEM.k_data[j];
                    end
            end
        end
    endtask

    // xorshift32, for the random sweep
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

    // the byte-wise reference for the random sweep: every byte address stored so far, and its value
    localparam N_OPS = 56;
    reg [31:0] ref_a [0:N_OPS*4-1];
    reg [7:0]  ref_v [0:N_OPS*4-1];
    integer    n_ref;
    task ref_store(input [31:0] a, input [7:0] v);
        integer j;
        reg hit;
        begin
            hit = 1'b0;
            for (j = 0; j < n_ref; j = j + 1)
                if (ref_a[j] === a) begin ref_v[j] = v; hit = 1'b1; end
            if (!hit) begin ref_a[n_ref] = a; ref_v[n_ref] = v; n_ref = n_ref + 1; end
        end
    endtask
    reg [7:0] ref_val;
    reg       ref_has;
    reg       ref_seen [0:N_OPS*4-1];   // compared at least once
    integer   ref_idx;
    task ref_find(input [31:0] a);
        integer j;
        begin
            ref_has = 1'b0; ref_val = 8'h00; ref_idx = -1;
            for (j = 0; j < n_ref; j = j + 1)
                if (ref_a[j] === a) begin ref_has = 1'b1; ref_val = ref_v[j]; ref_idx = j; end
        end
    endtask

    // the word every address in the geometry test stores: a different one for each
    reg [31:0] geo_adr [0:12];
    integer    gi, gj, ok_cells;
    reg [31:0] seed, wa, wd, rd;
    reg [3:0]  ws;
    integer    op;

    reg [31:0] got;

    // like wb_access, and counts the clock cycles from the request to the acknowledge
    task wb_timed(input we, input [31:0] adr, input [31:0] dat_w, input [3:0] sel, output [31:0] dat_r);
        begin
            @(posedge clk);
            wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= we;
            wb_adr <= adr; wb_dat_w <= dat_w; wb_sel <= sel;
            t_acc = 0;
            @(posedge clk);
            while (!wb_ack) begin @(posedge clk); t_acc = t_acc + 1; end
            dat_r = wb_dat_r;
            wb_cyc <= 1'b0; wb_stb <= 1'b0; wb_we <= 1'b0;
            @(posedge clk);
        end
    endtask

    reg [31:0] blk_w [0:3];
    integer    n_rd0;

    initial begin
        $display("=== wb_ddr.v standalone (Phase 9 Stage 2, Part 1) ===");
        wb_cyc = 1'b0; wb_stb = 1'b0; wb_we = 1'b0;
        wb_adr = 32'b0; wb_dat_w = 32'b0; wb_sel = 4'b0;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        // ---- a store issued before calibration is done ----
        // The controller's command sequencers are held in reset until
        // calib_done, so a request pulse sent to them earlier is lost. A boot
        // ROM loading a program into DDR3 does exactly this, and it showed up
        // as the first byte of the image missing. The access has to wait, not
        // be acknowledged.
        wb_access(1'b1, 32'h0000_0020, 32'h0BAD_F00D, 4'b1111, got);
        check("nothing was acknowledged before calibration finished",
              {31'b0, early_ack}, 32'b0);

        while (!(calib_done || calib_error) && $time < 700_000) @(posedge clk);
        check("lane 0 calibration completed (not errored)", {31'b0, calib_error}, 32'b0);
        check("lane 0 calibration found a working tap", {31'b0, calib_done}, 32'b1);

        // ---- store then load, block 0 (a real read-fill miss on the load) ----
        wb_access(1'b1, 32'h0000_0000, 32'hDEAD_BEEF, 4'b1111, got);
        wb_access(1'b0, 32'h0000_0000, 32'b0, 4'b1111, got);
        check("store-then-load round trip, word 0 of block 0", got, 32'hDEAD_BEEF);

        // ---- a second word in the SAME (already-open) block: a hit-path
        // store, and the read of word 0 must still be exactly right ----
        wb_access(1'b1, 32'h0000_0004, 32'h1234_5678, 4'b1111, got);
        wb_access(1'b0, 32'h0000_0004, 32'b0, 4'b1111, got);
        check("store-then-load, word 1 of block 0 (cache hit path)", got, 32'h1234_5678);
        wb_access(1'b0, 32'h0000_0000, 32'b0, 4'b1111, got);
        check("word 0 of block 0 unchanged by word 1's own store", got, 32'hDEAD_BEEF);

        wb_access(1'b0, 32'h0000_0020, 32'b0, 4'b1111, got);
        check("the store issued before calibration landed", got, 32'h0BAD_F00D);

        // ---- a different block evicts the open one; the first block must
        // still read back correctly once it is re-filled later ----
        wb_access(1'b1, 32'h0000_0010, 32'hCAFE_F00D, 4'b1111, got);
        wb_access(1'b0, 32'h0000_0010, 32'b0, 4'b1111, got);
        check("store-then-load, block 1 (a different block)", got, 32'hCAFE_F00D);
        wb_access(1'b0, 32'h0000_0000, 32'b0, 4'b1111, got);
        check("block 0's word 0 survives eviction and a real re-fill", got, 32'hDEAD_BEEF);
        wb_access(1'b0, 32'h0000_0004, 32'b0, 4'b1111, got);
        check("block 0's word 1 survives eviction and a real re-fill", got, 32'h1234_5678);

        // ---- partial-byte store: only the low two bytes change ----
        wb_access(1'b1, 32'h0000_0000, 32'hFFFF_0022, 4'b0011, got);
        wb_access(1'b0, 32'h0000_0000, 32'b0, 4'b1111, got);
        check("partial wb_sel store changes only the selected bytes", got, 32'hDEAD_0022);

        // ---- the x16 geometry (Part 14): each word lands in the cell and lane the part's addressing names ----
        $display("  the address geometry...");
        geo_adr[0]  = 32'h0000_0000;   // the first word
        geo_adr[1]  = 32'h0000_0014;   // block 1, word 1: an offset inside a block
        geo_adr[2]  = 32'h0000_0010;   // column bit 3 (block bit 0)
        geo_adr[3]  = 32'h0000_0400;   // column bit 9 (block bit 6): the top column bit
        geo_adr[4]  = 32'h0000_0800;   // bank bit 0 (block bit 7)
        geo_adr[5]  = 32'h0000_2000;   // bank bit 2 (block bit 9)
        geo_adr[6]  = 32'h0000_4000;   // row bit 0 (block bit 10)
        geo_adr[7]  = 32'h0800_0000;   // row bit 13
        geo_adr[8]  = 32'h0FFF_FFFC;   // the last word of the old 256 MB window
        geo_adr[9]  = 32'h1000_0000;   // the first word above it: row bit 14
        geo_adr[10] = 32'h1000_0040;   // ... and the old window's mirror of address 0x40, which must not alias
        geo_adr[11] = 32'h0000_0040;   // the word 256 MB below it, read right after it: the open block must not answer
        geo_adr[12] = 32'h1FFF_FFFC;   // the last word of the part
        for (gi = 0; gi < 13; gi = gi + 1)
            wb_access(1'b1, geo_adr[gi], 32'hA5000000 + {gi[7:0], 8'h11, 8'h22, 8'h33} ^ geo_adr[gi], 4'b1111, got);
        ok_cells = 0;
        for (gi = 0; gi < 13; gi = gi + 1) begin
            wd = 32'hA5000000 + {gi[7:0], 8'h11, 8'h22, 8'h33} ^ geo_adr[gi];
            for (gj = 0; gj < 4; gj = gj + 1) begin
                cell_of(geo_adr[gi] + gj);
                peek_cell(c_lane, c_bank, c_row, c_col);
                if (!p_found || p_byte !== wd[8*gj +: 8]) begin
                    $display("  FAIL %08h byte %0d: cell (bank %0d, row %04h, col %03h, lane %0d) holds %02h, expected %02h",
                             geo_adr[gi], gj, c_bank, c_row, c_col, c_lane, p_byte, wd[8*gj +: 8]);
                    errors = errors + 1;
                end else ok_cells = ok_cells + 1;
            end
        end
        check("13 words: every byte in its cell and lane (of 52)", ok_cells, 32'd52);
        for (gi = 0; gi < 13; gi = gi + 1) begin
            wb_access(1'b0, geo_adr[gi], 32'b0, 4'b1111, got);
            wd = 32'hA5000000 + {gi[7:0], 8'h11, 8'h22, 8'h33} ^ geo_adr[gi];
            if (got !== wd) begin
                $display("  FAIL read of %08h through the bus: got %08h, expected %08h", geo_adr[gi], got, wd);
                errors = errors + 1;
            end
        end

        // ---- one byte at a time, at each of the 16 offsets of a block ----
        $display("  a byte at each offset of a block...");
        for (gi = 0; gi < 4; gi = gi + 1)
            wb_access(1'b1, 32'h0000_3000 + 4*gi, 32'h00000000, 4'b1111, got);
        for (gi = 0; gi < 16; gi = gi + 1) begin
            wa = 32'h0000_3000 + gi;
            wb_access(1'b1, wa & 32'hFFFF_FFFC, {4{8'h10 + gi[7:0]}}, 4'b0001 << gi[1:0], got);
            wb_access(1'b0, wa & 32'hFFFF_FFFC, 32'b0, 4'b1111, got);
            if (got !== ((32'hFF << (8*gi[1:0])) & {4{8'h10 + gi[7:0]}})) begin
                $display("  FAIL byte offset %0d: the word reads %08h", gi, got);
                errors = errors + 1;
            end
            wb_access(1'b1, wa & 32'hFFFF_FFFC, 32'h00000000, 4'b1111, got);   // clear it for the next
        end
        // every offset's byte survives the others, then the whole block together
        for (gi = 0; gi < 16; gi = gi + 1) begin
            wa = 32'h0000_3000 + gi;
            wb_access(1'b1, wa & 32'hFFFF_FFFC, {4{8'h40 + gi[7:0]}}, 4'b0001 << gi[1:0], got);
        end
        for (gi = 0; gi < 4; gi = gi + 1) begin
            wb_access(1'b0, 32'h0000_3000 + 4*gi, 32'b0, 4'b1111, got);
            wd = {8'h43 + 8'd4*gi[7:0], 8'h42 + 8'd4*gi[7:0], 8'h41 + 8'd4*gi[7:0], 8'h40 + 8'd4*gi[7:0]};
            if (got !== wd) begin
                $display("  FAIL block word %0d: got %08h, expected %08h", gi, got, wd);
                errors = errors + 1;
            end
        end
        // selects that straddle the two columns of a word, and the two lanes
        wb_access(1'b1, 32'h0000_3000, 32'hAABBCCDD, 4'b0110, got);
        wb_access(1'b0, 32'h0000_3000, 32'b0, 4'b1111, got);
        check("select of the inner two bytes (lane 1 col 0, lane 0 col 1)", got, 32'h43BB_CC40);
        wb_access(1'b1, 32'h0000_3000, 32'h11223344, 4'b1001, got);
        wb_access(1'b0, 32'h0000_3000, 32'b0, 4'b1111, got);
        check("a select of the outer two bytes", got, 32'h11BB_CC44);

        // ---- a fill is one READ (Phase 9 Stage 3, 8-beat bursts, part C, read half) ----
        $display("  a fill is one controller read...");
        blk_w[0] = 32'h8C21_A001; blk_w[1] = 32'h5E37_B102; blk_w[2] = 32'hF04D_C203; blk_w[3] = 32'h1259_D304;
        for (gi = 0; gi < 4; gi = gi + 1)
            wb_access(1'b1, 32'h0000_5A40 + 4*gi, blk_w[gi], 4'b1111, got);
        wb_access(1'b0, 32'h0000_5A50, 32'b0, 4'b1111, got);        // another block resident: block 0x500 is not
        n_rd0 = rd_cmds;
        wb_timed(1'b0, 32'h0000_5A48, 32'b0, 4'b1111, got);          // a miss, on word 2
        check("the miss returns the word stored there", got, blk_w[2]);
        check("a miss sent exactly one READ to the DRAM", rd_cmds - n_rd0, 32'd1);
        // block 0x5A4: column bits [9:3] = 0x24, so the block's first column is 0x120; bank 3
        check("... to the block's first column", {22'b0, rd_last_col}, 32'h120);
        check("... in the block's bank", {29'b0, rd_last_ba}, 32'd3);
        $display("  measured: a miss took %0d clock cycles from the request to the acknowledge", t_acc);
        $display("  measured: the burst's pulse at cycle %0d, read_busy fell at %0d", t_burst_seen, t_busy_fell);
        check("the burst arrived no later than the cycle read_busy fell", {31'b0, t_burst_seen <= t_busy_fell}, 32'b1);
        check("a miss is acknowledged within 60 clock cycles", {31'b0, t_acc <= 60}, 32'b1);
        for (gi = 0; gi < 4; gi = gi + 1) begin
            wb_access(1'b0, 32'h0000_5A40 + 4*gi, 32'b0, 4'b1111, got);
            check("word of the filled block", got, blk_w[gi]);
        end
        check("... and none of those re-read the DRAM (the block was resident)", rd_cmds - n_rd0, 32'd1);

`ifndef VERILATOR
        // a fill whose burst the controller rejects: lane 1's capture window held shut by hand
        wb_access(1'b0, 32'h0000_5A50, 32'b0, 4'b1111, got);        // the other block is resident now
        n_rd0 = rd_cmds;
        force WB.DDR.datavalid_seen_1 = 1'b0;
        t_wait = 0;
        @(posedge clk);
        wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= 1'b0; wb_adr <= 32'h0000_5A44; wb_sel <= 4'b1111;
        @(posedge clk);
        while (!wb_ack && t_wait < 2000) begin @(posedge clk); t_wait = t_wait + 1; end
        check("a fill whose burst was rejected is acknowledged (no hang)", {31'b0, wb_ack}, 32'b1);
        wb_cyc <= 1'b0; wb_stb <= 1'b0;
        @(posedge clk);
        release WB.DDR.datavalid_seen_1;
        repeat (4) @(posedge clk);
        check("... after one READ", rd_cmds - n_rd0, 32'd1);
        wb_access(1'b0, 32'h0000_5A44, 32'b0, 4'b1111, got);
        check("... block not left resident: next access fills it again", rd_cmds - n_rd0, 32'd2);
        check("... and returns what was stored", got, blk_w[1]);
`endif

        // ---- a random sweep over the whole 512 MB against a byte-wise reference ----
        $display("  a random sweep over the whole part...");
        seed = 32'h1BADB002;
        n_ref = 0;
        for (gi = 0; gi < N_OPS*4; gi = gi + 1) ref_seen[gi] = 1'b0;
        for (op = 0; op < N_OPS; op = op + 1) begin
            seed = xorshift(seed); wa = {3'b000, seed[28:2], 2'b00} & 32'h1FFF_FFFC;
            seed = xorshift(seed); wd = seed;
            seed = xorshift(seed); ws = seed[3:0];
            if (ws == 4'b0000) ws = 4'b1111;
            wb_access(1'b1, wa, wd, ws, got);
            for (gj = 0; gj < 4; gj = gj + 1)
                if (ws[gj]) ref_store(wa + gj, wd[8*gj +: 8]);
        end
        // each word touched, read back: the bytes the reference holds must match
        ok_cells = 0;
        for (gi = 0; gi < n_ref; gi = gi + 1) begin
            wa = ref_a[gi] & 32'hFFFF_FFFC;
            wb_access(1'b0, wa, 32'b0, 4'b1111, rd);
            for (gj = 0; gj < 4; gj = gj + 1) begin
                ref_find(wa + gj);
                if (ref_has) begin
                    if (rd[8*gj +: 8] !== ref_val) begin
                        $display("  FAIL sweep byte %08h: got %02h, expected %02h", wa + gj, rd[8*gj +: 8], ref_val);
                        errors = errors + 1;
                    end else if (!ref_seen[ref_idx]) begin
                        ref_seen[ref_idx] = 1'b1;
                        ok_cells = ok_cells + 1;
                    end
                end
            end
        end
        $display("  %0d bytes stored by %0d stores, %0d of them read back correctly", n_ref, N_OPS, ok_cells);
        check("every byte the sweep stored reads back", ok_cells, n_ref);

`ifndef VERILATOR
        // ---- a lane that has not calibrated holds the slave back (Phase 9 Stage 1, Part 26) ----
        // The controller takes no request until both lanes have calibrated, and drops one sent earlier, so
        // a slave that waited for lane 0 alone would send its request into the void and then wait for a
        // busy that never rises. The two lanes calibrate together here, so lane 1's `calib1_done` is held
        // low by hand. (Verilator's release of a forced net does not give it back to its driver, so only
        // Icarus runs this; see sim/tb_ddr3_x16.v.)
        force WB.calib1_done = 1'b0;
        repeat (4) @(posedge clk);
        n_ack0 = ack_count;
        @(posedge clk);
        wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= 1'b1;
        wb_adr <= 32'h0000_0100; wb_dat_w <= 32'hC0DE_0001; wb_sel <= 4'b1111;
        repeat (300) @(posedge clk);
        check("nothing is acknowledged while lane 1 is uncalibrated", {31'b0, ack_count != n_ack0}, 32'b0);
        release WB.calib1_done;
        t_wait = 0;
        while (!wb_ack && t_wait < 20000) begin @(posedge clk); t_wait = t_wait + 1; end
        check("the access completes once lane 1 has calibrated", {31'b0, wb_ack}, 32'b1);
        wb_cyc <= 1'b0; wb_stb <= 1'b0; wb_we <= 1'b0;   // dropped in the cycle of the ack, as wb_access does
        @(posedge clk);
        wb_access(1'b0, 32'h0000_0100, 32'b0, 4'b1111, got);
        check("... and it stored what it was given", got, 32'hC0DE_0001);
`endif

        check("no DDR3 protocol error the whole run", {31'b0, model_error}, 32'b0);
        check("no DQ/DQS timing error the whole run", {31'b0, dq_error}, 32'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("WB_DDR TEST PASSED");
        else             $display("WB_DDR TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
