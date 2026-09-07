// Directed test for wb_interconnect.v's new NUM_HARTS parameter (Phase 13
// stage 3, docs/roadmap.md) - proves two of the arbitration behaviors
// formal/fv_interconnect.v proves in the abstract actually play out over a
// real cycle-by-cycle trace: cross-hart priority (a lower-priority tier
// from one hart must not preempt a higher-priority tier from another) and
// the per-hart AMO-continuation override (hart A's own follow-up phase
// wins even against a request from hart B that formal's own property 4z
// would otherwise let through).
//
// One real, multi-cycle slave (a tiny 1-word-deep, 1-wait-state RAM model,
// same timing shape as rtl/soc/wb_ram.v) at slave 0 - a zero-wait-state
// slave would never exercise the lock, and the lock is exactly what stage
// 1's own AMO-continuation mechanism depends on.
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
        .w_cyc(w_cyc), .w_stb(w_stb), .w_adr(w_adr),
        .w_dat_r(w_dat_r), .w_ack(w_ack),
        .dbg_cyc(dbg_cyc), .dbg_stb(dbg_stb), .dbg_we(dbg_we), .dbg_adr(dbg_adr),
        .dbg_dat_w(dbg_dat_w), .dbg_sel(dbg_sel),
        .dbg_dat_r(dbg_dat_r), .dbg_ack(dbg_ack),
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

        // ---- 2: per-hart AMO continuation - hart 0 holds cyc (and, since
        // every master ties stb to cyc, stb too) across a read-then-write
        // pair, the same shape cpu_core.v's dmem_is_amo gives a real AMO;
        // hart 1's own data request, asking the entire time, must not win
        // the one-cycle gap between hart 0's two phases.
        //
        // Against this file's own 1-wait-state slave model, holding
        // stb+cyc continuously makes its ack register toggle every other
        // cycle by construction (ack_r <= stb && !ack_r) - edge1 acks,
        // edge2 is the gap (ack_r flips back to 0 even though hart 0 is
        // still asking and still granted), edge3 acks again. That gap at
        // edge2 - stb still high, nothing acking yet - is exactly the
        // one-cycle window the continuing-override protects, and this test
        // checks hart 1 specifically during it, not just around it. ----
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
        @(posedge clk); #1; // edge 2: the gap - continuing protects it
        check("hart0 still granted through the gap (continuing, not the ordinary tier)",
              {31'b0, s_data_master}, {31'b0, 1'b1});
        check("hart0 itself does not ack during its own gap cycle",
              {31'b0, d_ack[0]}, {31'b0, 1'b0});
        check("hart1 does not steal the gap cycle",
              {31'b0, d_ack[1]}, {31'b0, 1'b0});
        // The RMW result is ready now (the read landed at edge 1); present
        // the write for the next ack.
        d_we[0] = 1'b1;
        @(posedge clk); #1; // edge 3: hart0's write phase acks
        check("hart0's write phase acked", {31'b0, d_ack[0]}, {31'b0, 1'b1});
        check("hart1 still excluded through hart0's own AMO",
              {31'b0, d_ack[1]}, {31'b0, 1'b0});
        // The lock re-engages on this same edge (its own decision is made
        // from the *pre*-edge fin_ack, one step behind ack_r's update in
        // the same edge - the ordinary multi-cycle-transfer path, not
        // anything specific to continuation) and needs one more clean edge,
        // with hart 0's stb still held, to see fin_ack and release it.
        // Dropping stb before that edge would leave the lock's own grant
        // pointed at a master that has stopped asking, with nothing left
        // to ever satisfy fin_ack again.
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
