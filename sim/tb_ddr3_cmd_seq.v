// Integrated test for Phase 9 Stage 1, Part 9 (docs/roadmap.md): the
// first real, command-driven write-then-read round trip through
// rtl/soc/ddr3_ecp5_top.v - a real ACT+WR (rtl/soc/ddr3_write_seq.v)
// followed by a real ACT+RD (rtl/soc/ddr3_read_seq.v), not
// rtl/soc/ddr3_read_calib.v's own direct-signal-injection scheme,
// which this test still exercises first (calibration has to complete
// before either command sequencer is allowed to start - see
// ddr3_ecp5_top.v's own header).
//
// Real, honestly scoped: sim/ddr3_dq_model.v is still the same single-
// stored-location model every part through Part 8 already used - it
// does not address-decode `write_bank`/`write_row`/`write_col` at all,
// so this test proves the real command *timing and wiring* (does the
// write-drive/DQ-drive/capture mechanism fire at the right real cycle
// relative to a genuine ACT+WR/ACT+RD sequence), not a real multi-
// location memory array. A real memory model is later, separate work.
`timescale 1ns/1ps
module tb_ddr3_cmd_seq;
    localparam CLK_HZ    = 25_000_000;
    localparam CLK_PERIOD = 40;   // 25 MHz

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
    reg  [2:0]  write_bank = 3'd4;
    reg  [15:0] write_row  = 16'hBEEF;
    reg  [15:0] write_col  = 16'h0212;
    reg  [7:0]  write_data = 8'h5A;
    wire        write_busy;

    reg         read_req = 1'b0;
    reg  [2:0]  read_bank = 3'd4;
    reg  [15:0] read_row  = 16'hBEEF;
    reg  [15:0] read_col  = 16'h0212;
    wire        read_busy;
    wire [7:0]  read_data;
    wire        read_data_valid;

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
        .pll_locked(pll_locked), .dll_locked(dll_locked),
        .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    // ---- Part 1's own real protocol checker, watching the same real
    // command/address pins - now also watching the real ACT+WR/ACT+RD
    // sequences ddr3_write_seq.v/ddr3_read_seq.v issue, not just the
    // init sequence's own MR-write commands ----
    wire        model_error;
    wire [511:0] model_error_msg;
    wire        model_seq_done;

    ddr3_model #(.CLK_HZ(CLK_HZ)) PROTO (
        .clk(clk), .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done(model_seq_done)
    );

    // ---- Part 2's own real byte-lane DQ/DQS memory - tapped off the
    // real, combined (calibration OR real-command) trigger signals,
    // not the calibration-only ones tb_ddr3_top.v's own test still
    // uses (that test's own job is calibration in isolation; this
    // test's job is the real command path on top of it) ----
    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_o;

    wire [7:0] tap_wr_data      = DUT.wr_data_final;
    wire       tap_write_start  = DUT.write_start_final;
    wire       tap_read_active  = DUT.read_active_final;

    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .wr_d0(tap_wr_data), .wr_en(tap_write_start),
        .read_active(tap_read_active),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_o(mem_dqs_o)
    );

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = mem_dq_oe ? mem_dqs_o : 1'bz;

    // Real per-bit X-detection contention checks - the same fix
    // sim/tb_ddr3_top.v's own investigation already found necessary
    // (a reduction-XOR misreports a floating bus as contended; an
    // internal-signal tap can miss a real tristate-assignment bug a
    // resolved-pin check would catch). Gated on !rst, matching that
    // same investigation's own finding that every signal is benignly
    // `x` before the first real reset edge lands.
    function automatic has_real_x;
        input [7:0] v;
        integer i;
        begin
            has_real_x = 1'b0;
            for (i = 0; i < 8; i = i + 1)
                if (v[i] === 1'bx) has_real_x = 1'b1;
        end
    endfunction

    reg dq_contention_seen = 1'b0;
    always @(posedge DUT.sclk) if (!rst && has_real_x(ddr3_dq)) dq_contention_seen <= 1'b1;

    reg dqs_contention_seen = 1'b0;
    always @(posedge DUT.sclk) if (!rst && (ddr3_dqs === 1'bx)) dqs_contention_seen <= 1'b1;

    integer errors = 0;
    task check(input [511:0] what, input got, input want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %b, expected %b", what, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s", what);
            end
        end
    endtask

    task check_byte(input [511:0] what, input [7:0] got, input [7:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %02h, expected %02h", what, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: %02h", what, got);
            end
        end
    endtask

    reg [7:0] captured_read_data;
    reg       captured_read_valid;

    initial begin
        $display("=== DDR3 real command-driven read/write round trip (Phase 9 Stage 1, Part 9) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        repeat (8) @(posedge clk);
        check("PLL locked", pll_locked, 1'b1);
        check("DLL locked", dll_locked, 1'b1);

        while (!init_ready && !model_error && $time < 400_000) @(posedge clk);
        check("real protocol checker saw no error after init", model_error, 1'b0);
        check("init sequence reports ready", init_ready, 1'b1);

        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check("calibration completed (not errored)", calib_error, 1'b0);
        check("calibration found a working tap", calib_done, 1'b1);
        if (calib_done) $display("  calibrated READCLKSEL = %0d", calib_readclksel);

        // ---- real command-driven write ----
        check("write_busy idle before the real write request", write_busy, 1'b0);
        @(posedge clk);
        write_req <= 1'b1;
        @(posedge clk);
        write_req <= 1'b0;

        while (!write_busy && $time < 700_000) @(posedge clk);   // real ACT->WR->CWL takes a few cycles to even assert busy's own first real cycle
        while (write_busy && $time < 900_000) @(posedge clk);
        check("write_busy deasserted again after the real write", write_busy, 1'b0);
        check("no real protocol error during the write", model_error, 1'b0);

        // ---- real command-driven read of the same location ----
        check("read_busy idle before the real read request", read_busy, 1'b0);
        captured_read_valid = 1'b0;
        captured_read_data  = 8'b0;

        fork
            begin
                @(posedge clk);
                read_req <= 1'b1;
                @(posedge clk);
                read_req <= 1'b0;
            end
            begin : CAPTURE
                while (!captured_read_valid && $time < 1_100_000) begin
                    @(posedge clk);
                    if (read_data_valid) begin
                        captured_read_valid = 1'b1;
                        captured_read_data  = read_data;
                    end
                end
            end
        join

        while (read_busy && $time < 1_300_000) @(posedge clk);
        check("read_busy deasserted again after the real read", read_busy, 1'b0);
        check("no real protocol error during the read", model_error, 1'b0);
        check("read_data_valid pulsed at some point during the real read", captured_read_valid, 1'b1);
        check_byte("real read-back data matches the real write, through actual ACT+WR/ACT+RD commands",
                   captured_read_data, write_data);

        repeat (4) @(posedge clk);
        check("no DQ bus contention seen at any point", dq_contention_seen, 1'b0);
        check("no DQS bus contention seen at any point", dqs_contention_seen, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 COMMAND-DRIVEN RW TEST PASSED");
        else             $display("DDR3 COMMAND-DRIVEN RW TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
