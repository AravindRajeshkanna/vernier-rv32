// Integrated test for Phase 9 Stage 1, Part 11 (docs/roadmap.md): the
// real refresh-vs-write/read arbitration rtl/soc/ddr3_ecp5_top.v now
// provides - rtl/soc/ddr3_refresh_ctrl.v's own real REFRESH command
// must never contend with a real ACT/WR/RD for the shared `cmd_*` bus.
// Proven by deliberately colliding a real write with a real pending
// refresh request (not by running a long write stream and hoping one
// happens to overlap somewhere in it - a first draft did exactly that,
// and it could not distinguish a working grant from a completely
// broken one, since two fixed, deterministic schedules that do not
// happen to collide prove nothing).
//
// Real, honestly scoped: this test only proves the direction this
// integration actually built - refresh waiting for write/read. The
// reverse direction (a new write/read request arriving while refresh
// is itself mid-tRFC) is real, deliberately unbuilt, and named as such
// in rtl/soc/ddr3_ecp5_top.v's own header - not exercised here because
// there is nothing yet to observe protecting against it.
`timescale 1ns/1ps
module tb_ddr3_refresh_wire;
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
    reg  [2:0]  write_bank = 3'd1;
    reg  [15:0] write_row  = 16'h0001;
    reg  [15:0] write_col  = 16'h0001;
    reg  [7:0]  write_data = 8'hC3;
    wire        write_busy;

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
        .read_req(1'b0), .read_bank(3'b0), .read_row(16'b0), .read_col(16'b0),
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
        .clk(clk), .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(model_error), .error_msg(model_error_msg), .seq_done(model_seq_done)
    );

    wire [7:0] mem_dq_o;
    wire       mem_dq_oe, mem_dqs_o;

    ddr3_dq_model MEM (
        .sclk(DUT.sclk), .rst(DUT.rst_all),
        .wr_d0(DUT.wr_data_final), .wr_en(DUT.write_start_final),
        .read_active(DUT.read_active_final),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_o(mem_dqs_o)
    );

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQ_BUS
            assign ddr3_dq[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = mem_dq_oe ? mem_dqs_o : 1'bz;

    localparam [2:0] CMD_REF = 3'b001;

    // Real, continuously-running monitors from the start of the test,
    // not a post-hoc, precisely-timed search window - a first draft's
    // own bounded 20-cycle search after the write stream ended missed
    // the real command entirely, confirmed by a real probe to be
    // because the real REFRESH command actually fires *during* the
    // write stream, in one of its own brief inter-write gaps (real
    // tREFI is short enough that this real test's own 40-write stream
    // spans two real refresh cycles, not one), not only after it -
    // exactly the class of same-instant/precisely-timed-window mistake
    // this project's own investigation has hit more than once.
    reg contention_seen = 1'b0;
    reg real_refresh_cmd_seen = 1'b0;
    always @(posedge DUT.sclk) begin
        if (!rst && DUT.phy_cmd_valid && (DUT.phy_cmd_cs_ras_cas_we == CMD_REF))
            real_refresh_cmd_seen <= 1'b1;
    end

    // The real contention check has to watch REFRESH's own raw
    // `cmd_valid` (`DUT.refresh_cmd_valid`, before the top-level mux),
    // not the muxed `phy_cmd_valid` a caller actually sees on the pins
    // - a first draft here checked the muxed signal and a real
    // mutation (forcing `refresh_grant` to a constant 1, ignoring
    // `write_busy`/`read_busy` entirely) passed clean despite the real
    // hazard it introduces. The mux's own fixed priority (SEQ > WSEQ >
    // RSEQ > REFRESH) silently lets a real in-flight write win that
    // cycle, so the muxed output never actually shows the REFRESH
    // encoding at all - but `ddr3_refresh_ctrl.v` itself still believes
    // its own command was issued (moving on to its own real `S_RFC_WAIT`
    // state) even though the real DRAM pins never saw it. That is a
    // real, silent correctness bug a muxed-output-only check cannot
    // see by construction, not a benign non-event.
    always @(posedge DUT.sclk) begin
        if (!rst && DUT.refresh_cmd_valid && write_busy)
            contention_seen <= 1'b1;
    end

    reg refresh_busy_during_writes = 1'b0;

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

    initial begin
        $display("=== DDR3 refresh-vs-write arbitration (Phase 9 Stage 1, Part 11) ===");
        repeat (4) @(posedge clk);
        rst = 1'b0;

        while (!calib_done && !calib_error && $time < 600_000) @(posedge clk);
        check("calibration completed before this test begins", calib_error, 1'b0);
        check("calibration found a working tap", calib_done, 1'b1);

        // A real, deliberate collision, not a hoped-for one. Both the
        // real tREFI interval and this test's own write timing are
        // fully deterministic - a first draft here ran a long,
        // free-running write stream and simply hoped a refresh would
        // become due while some write was still in flight somewhere in
        // it. It happened to (confirmed by a real probe), which is
        // exactly why that same draft's own version of this check
        // could not tell a working grant from a completely broken one
        // (a mutation removing the `!write_busy && !read_busy` gate
        // entirely still passed clean) - two fixed, deterministic
        // schedules that do not happen to collide prove nothing about
        // whether real protection exists.
        //
        // A second draft tried to react to `refresh_req` itself (wait
        // for it, then issue write_req) - also wrong, confirmed by a
        // real probe: since `write_busy` was already 0 the instant
        // `refresh_req` first appeared, real grant logic (working
        // correctly) issues the real command and moves on to
        // `S_RFC_WAIT` within that same cycle, before this test's own
        // `write_req` pulse (necessarily one real cycle later) could
        // possibly land - reacting to the request is already too late
        // to collide with a *working* grant, which is exactly the
        // scenario this test most needs to exercise.
        //
        // Fixed by anticipating the real, deterministic deadline
        // instead of reacting to it: `ddr3_refresh_ctrl.v`'s own real
        // `T_REFI` (195 cycles, Part 10's own primary-datasheet-verified
        // value) counts from `calib_done`'s own real rising edge. Real
        // write transactions measure roughly 10-11 cycles start to
        // finish (Part 6/9's own real measurements) - issuing write_req
        // 5 cycles before the real 195-cycle mark keeps the write
        // genuinely in flight well past it, comfortably covering the
        // exact cycle grant logic has to make its own real decision.
        repeat (190) @(posedge clk);
        write_req <= 1'b1;
        @(posedge clk);
        write_req <= 1'b0;
        // One more real settle cycle before checking `write_busy` -
        // `ddr3_write_seq.v`'s own `busy <= 1'b1;` is scheduled via NBA
        // on the same edge `write_req` is first seen, so reading it
        // back in the same simulation instant (as a first draft here
        // did) sees the stale, pre-update value - confirmed by a real,
        // separate monitor showing the collision genuinely working
        // correctly one cycle later, not a real DUT defect.
        @(posedge clk);
        check("the deliberately-collided write is genuinely in flight", write_busy, 1'b1);

        while (write_busy) begin
            @(posedge clk);
            if (refresh_busy) refresh_busy_during_writes = 1'b1;
        end

        // `refresh_busy` legitimately asserts the moment tREFI elapses
        // - before grant, before any real command - so seeing it high
        // during the deliberately-collided write is the *expected*,
        // correct signal, not a fault. The real, meaningful property is
        // that no real command ever asserts during that overlap, which
        // `contention_seen` below checks directly against
        // `ddr3_refresh_ctrl.v`'s own raw `cmd_valid` output, not the
        // muxed one a caller sees on the pins - see that check's own
        // header for why the muxed signal alone cannot tell a real
        // grant-logic failure apart from a working one.
        check("refresh was genuinely pending during the deliberately-collided write - confirms the collision was real",
              refresh_busy_during_writes, 1'b1);
        check("no real REFRESH-vs-write contention was ever seen (checked against the raw, pre-mux signal)",
              contention_seen, 1'b0);
        check("no real protocol error during the collided write", model_error, 1'b0);

        // The collided write has finished - the still-pending refresh
        // should now be free to proceed.
        repeat (30) @(posedge clk);
        check("a real REFRESH command appeared on the shared cmd bus at some point", real_refresh_cmd_seen, 1'b1);

        while (refresh_busy && $time < 950_000) @(posedge clk);
        check("refresh_busy deasserted again after the real tRFC wait", refresh_busy, 1'b0);
        check("no real protocol error by the end of the test", model_error, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("DDR3 REFRESH WIRING TEST PASSED");
        else             $display("DDR3 REFRESH WIRING TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
