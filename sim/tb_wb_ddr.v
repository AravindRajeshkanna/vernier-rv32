// Standalone proof for Phase 9 Stage 2, Part 1 (docs/roadmap.md):
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

    wire        ddr3_ck, ddr3_ck_n;
    wire        ddr3_cs_n, ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [15:0] ddr3_a;
    wire        ddr3_cke, ddr3_reset_n, ddr3_odt;
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
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(wb_sel),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt),
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
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
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
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
        .read_active(WB.DDR.read_active),
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

    reg [31:0] got;

    initial begin
        $display("=== wb_ddr.v standalone (Phase 9 Stage 2, Part 1) ===");
        wb_cyc = 1'b0; wb_stb = 1'b0; wb_we = 1'b0;
        wb_adr = 32'b0; wb_dat_w = 32'b0; wb_sel = 4'b0;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        while (!(calib_done || calib_error) && $time < 400_000) @(posedge clk);
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
        #4_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
