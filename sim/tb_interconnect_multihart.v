// Directed test for wb_interconnect.v's new NUM_HARTS parameter (Phase 13
// stage 3, docs/roadmap.md) - proves two of the arbitration behaviors
// formal/fv_interconnect.v proves in the abstract actually play out over a
// real cycle-by-cycle trace: cross-hart priority (a lower-priority tier
// from one hart must not preempt a higher-priority tier from another) and
// the per-hart AMO write-phase exclusivity override (hart A's own
// in-flight AMO wins even against a request from hart B that formal's own
// property 4z would otherwise let through).
//
// Test 2's own scenario used to drive this purely through d_cyc timing - a
// hart's own `dmem_is_amo` was assumed to stay continuously asserted across
// an AMO's two phases, so this file modeled that by literally holding
// d_cyc[0] high the whole time and let the interconnect infer the rest
// (`d_continuing`). That assumption was real, correct about this file in
// isolation, and false about the actual system: rtl/soc/cpu_wb.v's own
// one-cycle decode bubble drops the bus-level d_cyc for exactly one cycle
// at the read-to-write transition regardless of what the core's own
// dmem_is_amo does, so the inferred mechanism never actually engaged
// against real hardware (docs/roadmap.md's Phase 13 Stage 1 entry has the
// full correction). This file now drives the replacement directly -
// d_amo_wrphase, a free-standing signal instead of something inferred from
// d_cyc - the same way a real core does: asserted starting the cycle after
// the read's own ack, independently of whether d_cyc happens to be up.
//
// One real, multi-cycle slave (a tiny 1-word-deep, 1-wait-state RAM model,
// same timing shape as rtl/soc/wb_ram.v) at slave 0 - a zero-wait-state
// slave would never exercise the lock, and the lock is what makes the
// gap this test's own Test 2 exercises real in the first place.
`timescale 1ns/1ps
module tb_interconnect_multihart;
    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    localparam NH = 2;
    localparam NS = 1;

    reg  [NH-1:0]    f_cyc = 0, f_stb = 0;
    reg  [NH*32-1:0] f_adr = 0;
    reg  [NH-1:0]    d_cyc = 0, d_stb = 0, d_we = 0;
    reg  [NH*32-1:0] d_adr = 0, d_dat_w = 0;
    reg  [NH*4-1:0]  d_sel = 0;
    reg  [NH-1:0]    d_amo_wrphase = 0;
    reg  [NH-1:0]    w_cyc = 0, w_stb = 0;
    reg  [NH*32-1:0] w_adr = 0;
    reg              dbg_cyc = 0, dbg_stb = 0, dbg_we = 0;
    reg  [31:0]      dbg_adr = 0, dbg_dat_w = 0;
    reg  [3:0]       dbg_sel = 0;

    wire [NH*32-1:0] f_dat_r, d_dat_r, w_dat_r;
    wire [NH-1:0]    f_ack, d_ack, w_ack;
    wire [31:0]      dbg_dat_r;
    wire             dbg_ack;
    wire             s_cyc, s_we, s_data_master;
    wire [NS-1:0]    s_stb;
    wire [31:0]      s_adr, s_dat_w;
    wire [3:0]       s_sel;
    wire [NS*32-1:0] s_dat_r;
    wire [NS-1:0]    s_ack;

    wb_interconnect #(.NUM_SLAVES(NS), .NUM_HARTS(NH)) DUT (
        .clk(clk), .rst(rst),
        .f_cyc(f_cyc), .f_stb(f_stb), .f_adr(f_adr),
        .f_dat_r(f_dat_r), .f_ack(f_ack),
        .d_cyc(d_cyc), .d_stb(d_stb), .d_we(d_we), .d_adr(d_adr),
        .d_dat_w(d_dat_w), .d_sel(d_sel),
        .d_dat_r(d_dat_r), .d_ack(d_ack),
        .d_amo_wrphase(d_amo_wrphase),
        .w_cyc(w_cyc), .w_stb(w_stb), .w_adr(w_adr),
        .w_dat_r(w_dat_r), .w_ack(w_ack),
        .dbg_cyc(dbg_cyc), .dbg_stb(dbg_stb), .dbg_we(dbg_we), .dbg_adr(dbg_adr),
        .dbg_dat_w(dbg_dat_w), .dbg_sel(dbg_sel),
        .dbg_dat_r(dbg_dat_r), .dbg_ack(dbg_ack),
        // Not exercised by this file - its own tests are about per-hart
        // arbitration - but tied to explicit constants rather than left
        // floating, the same X-poisoning reason every other tie-off in
        // this tree already is.
        .n_cyc(1'b0), .n_stb(1'b0), .n_adr(32'b0),
        .n_dat_r(), .n_ack(),
        .s_base(8'h00), .s_mask(8'hFF),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
        .s_dat_r(s_dat_r), .s_ack(s_ack),
        .s_data_master(s_data_master)
    );

    // One real, 1-wait-state slave, matching wb_ram.v's own timing: address
    // in the first cycle, ack (and, for a read, data) in the second.
    reg [31:0] mem0 = 32'hAAAA_0000;
    reg        ack_r = 0;
    always @(posedge clk or posedge rst) begin
        if (rst) ack_r <= 1'b0;
        else     ack_r <= s_stb[0] && !ack_r;
    end
    always @(posedge clk) if (s_stb[0] && s_we && !ack_r) mem0 <= s_dat_w;
    assign s_ack[0]        = ack_r;
    assign s_dat_r[31:0]   = mem0;

    integer errors = 0;
    task check(input [599:0] name, input [31:0] got, input [31:0] expected);
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: got %08h expected %08h", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: %08h", name, got);
            end
        end
    endtask

    initial begin
        @(posedge clk); @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        // ---- 1: cross-hart priority - hart 1's data outranks hart 0's
        // walker, exactly as hart 0's own data would (the tier generalizes,
        // it does not just happen to still work for hart 0). ----
        d_cyc[1] = 1'b1; d_stb[1] = 1'b1; d_we[1] = 1'b0;
        d_adr[63:32] = 32'h0000_0000;
        w_cyc[0] = 1'b1; w_stb[0] = 1'b1; w_adr[31:0] = 32'h0000_0000;
        #1;
        check("hart1 data beats hart0 walker: s_data_master",
              {31'b0, s_data_master}, {31'b0, 1'b1});
        check("hart0 walker not acked while hart1 data is granted",
              {31'b0, w_ack[0]}, {31'b0, 1'b0});
        // Let the read complete.
        @(posedge clk); #1;
        @(posedge clk); #1;
        d_cyc[1] = 1'b0; d_stb[1] = 1'b0;
        w_cyc[0] = 1'b0; w_stb[0] = 1'b0;
        @(posedge clk); #1;

        // ---- 2: per-hart AMO write-phase exclusivity - hart 0's own
        // d_amo_wrphase, not d_cyc continuity, is what protects its
        // read-to-write gap now. Modeled on the real timing this replaced:
        // a core's own dmem_is_amo/cyc genuinely drops for one cycle at the
        // gap (rtl/soc/cpu_wb.v's own decode bubble - see this file's own
        // header) even though d_amo_wrphase does not, so hart 0's own d_cyc
        // is dropped here too, deliberately, rather than held continuously
        // the way the old (wrong) mechanism's own test modeled it. Hart 1's
        // own data request, asking the entire time, must not win the gap
        // regardless of what hart 0's own d_cyc happens to be doing. ----
        d_cyc[0] = 1'b1; d_stb[0] = 1'b1; d_we[0] = 1'b0; // read phase
        d_adr[31:0] = 32'h0000_0000;
        d_cyc[1] = 1'b1; d_stb[1] = 1'b1; d_we[1] = 1'b0; // asking the whole time
        d_adr[63:32] = 32'h0000_0000;
        @(posedge clk); #1; // edge 1: hart0 wins the ordinary tier, acks
        check("hart0 data granted over hart1 (lower index wins the normal tier)",
              {31'b0, s_data_master}, {31'b0, 1'b1});
        check("hart0's read phase acked", {31'b0, d_ack[0]}, {31'b0, 1'b1});
        check("hart1 not acked on hart0's own ack cycle",
              {31'b0, d_ack[1]}, {31'b0, 1'b0});
        // One more edge, stb still held, before the real gap - the same
        // "lock needs a clean edge to see fin_ack and release" reasoning
        // edge 4/5 below rely on for the write phase, needed here too:
        // without it, `lock` (engaged one cycle late relative to the ack it
        // was deciding about, an artifact of nonblocking-assignment timing)
        // would still be covering hart0 by coincidence going into the gap,
        // and the gap checks below would pass whether or not d_amo_wrphase
        // did anything at all - the exact "test that cannot fail" shape
        // docs/practices.md section 1 warns about. Confirmed the hard way:
        // without this edge, forcing d_amo_wrphase to a constant 0 (as if
        // the fix did not exist) left every check below passing anyway.
        @(posedge clk); #1;
        check("hart0's read ack pulse has already cleared",
              {31'b0, d_ack[0]}, {31'b0, 1'b0});
        // The real gap: hart0's own d_cyc/d_stb drop for exactly one cycle
        // here (cpu_wb.v's own decode bubble, not modeled as continuous
        // anymore), while d_amo_wrphase[0] - a core's amo_wr_phase register,
        // asserted starting the cycle after its own read ack - is what now
        // holds the grant instead. `lock` itself is genuinely 0 by this
        // point (cleared on the edge just above), so this is arbitration
        // genuinely reopening, not the multi-cycle-transfer lock coasting.
        d_cyc[0] = 1'b0; d_stb[0] = 1'b0;
        d_amo_wrphase[0] = 1'b1;
        @(posedge clk); #1; // edge 2: the gap - d_amo_wrphase protects it
        check("hart0 still granted through the gap (amo_wrphase, not the ordinary tier)",
              {31'b0, s_data_master}, {31'b0, 1'b1});
        check("hart0 itself does not ack during its own gap cycle (not asking)",
              {31'b0, d_ack[0]}, {31'b0, 1'b0});
        check("hart1 does not steal the gap cycle",
              {31'b0, d_ack[1]}, {31'b0, 1'b0});
        // The RMW result is ready now (the read landed at edge 1); present
        // the write for the next ack. d_amo_wrphase stays up - the write
        // phase is still part of the same held sequence.
        d_cyc[0] = 1'b1; d_stb[0] = 1'b1; d_we[0] = 1'b1;
        @(posedge clk); #1; // edge 3: hart0's write phase acks
        check("hart0's write phase acked", {31'b0, d_ack[0]}, {31'b0, 1'b1});
        check("hart1 still excluded through hart0's own AMO",
              {31'b0, d_ack[1]}, {31'b0, 1'b0});
        // d_amo_wrphase can clear now (amo_done, in a real core) - the
        // write itself already acked. The lock re-engages on this same
        // edge (its own decision is made from the *pre*-edge fin_ack, one
        // step behind ack_r's update in the same edge - the ordinary
        // multi-cycle-transfer path, unrelated to d_amo_wrphase) and needs
        // one more clean edge, with hart 0's stb still held, to see
        // fin_ack and release it. Dropping stb before that edge would
        // leave the lock's own grant pointed at a master that has stopped
        // asking, with nothing left to ever satisfy fin_ack again.
        d_amo_wrphase[0] = 1'b0;
        @(posedge clk); #1; // edge 4: the lock releases
        d_cyc[0] = 1'b0; d_stb[0] = 1'b0; d_we[0] = 1'b0;
        @(posedge clk); #1; // edge 5: hart0 done; hart1 finally granted
        check("hart1 granted once hart0 stops asking",
              {31'b0, s_data_master}, {31'b0, 1'b1});
        check("hart1's own access acked", {31'b0, d_ack[1]}, {31'b0, 1'b1});
        d_cyc[1] = 1'b0; d_stb[1] = 1'b0;

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("INTERCONNECT-MULTIHART-TEST: PASS");
        else             $display("INTERCONNECT-MULTIHART-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the interconnect multi-hart test never completed");
        $finish;
    end
endmodule
