// Directed test for clint.v's new NUM_HARTS parameter (Phase 13 stage 2,
// docs/roadmap.md) - proves the standard per-hart-strided msip/mtimecmp
// addressing (hart h: msip at 0x0000+4h, mtimecmp at 0x4000+8h) actually
// reaches independent storage per hart and that mtime stays a single,
// shared counter, rather than trusting the address-math by inspection.
//
// Two DUTs:
//   DUT_MULTI (NUM_HARTS=2) - the new behavior.
//   DUT_SINGLE (NUM_HARTS=1, the default) - every real instantiation in
//     this tree (rtl/top.v, rtl/soc/soc_top.v) still builds this, so this
//     confirms the generalized address math collapses back to exactly the
//     old fixed offsets and does not accidentally widen what a NUM_HARTS=1
//     build responds to (e.g. hart1's would-be mtimecmp at 0x4008 must
//     stay a no-op, not silently alias into hart0's storage).
//
// Driven directly against clint.v's addr/we/wdata port, same convention as
// sim/tb_pmp_csr.v.
`timescale 1ns/1ps
module tb_clint_multihart;
    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    // ---- DUT_MULTI: NUM_HARTS=2 ----
    reg  [31:0] addr_m = 32'b0;
    reg         we_m = 1'b0;
    reg  [31:0] wdata_m = 32'b0;
    wire [31:0] rdata_m;
    wire [1:0]  mtip_m, msip_out_m;
    wire [63:0] mtime_m;

    clint #(.NUM_HARTS(2)) DUT_MULTI (
        .clk(clk), .rst(rst),
        .addr(addr_m), .wdata(wdata_m), .we(we_m), .rdata(rdata_m),
        .mtip(mtip_m), .msip_out(msip_out_m), .mtime_out(mtime_m)
    );

    // ---- DUT_SINGLE: NUM_HARTS=1 (the default, matching every real build) ----
    reg  [31:0] addr_s = 32'b0;
    reg         we_s = 1'b0;
    reg  [31:0] wdata_s = 32'b0;
    wire [31:0] rdata_s;
    wire        mtip_s, msip_out_s;
    wire [63:0] mtime_s;

    clint DUT_SINGLE (
        .clk(clk), .rst(rst),
        .addr(addr_s), .wdata(wdata_s), .we(we_s), .rdata(rdata_s),
        .mtip(mtip_s), .msip_out(msip_out_s), .mtime_out(mtime_s)
    );

    integer errors = 0;

    task check(input [599:0] name, input [63:0] got, input [63:0] expected);
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: got %0h expected %0h", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: %0h", name, got);
            end
        end
    endtask

    // Same #1-before-stimulus discipline as sim/tb_pmp_csr.v: two processes
    // (this task, the DUT's own clocked always block) react to the same
    // posedge, so driving new stimulus in direct response to it races the
    // DUT's evaluation - which runs first is simulator-defined.
    task wrm(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); #1;
            addr_m = a; wdata_m = d; we_m = 1'b1;
            @(posedge clk); #1;
            we_m = 1'b0;
        end
    endtask

    task rdm(input [31:0] a);
        begin
            addr_m = a;
            #1;
        end
    endtask

    task wrs(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); #1;
            addr_s = a; wdata_s = d; we_s = 1'b1;
            @(posedge clk); #1;
            we_s = 1'b0;
        end
    endtask

    task rds(input [31:0] a);
        begin
            addr_s = a;
            #1;
        end
    endtask

    initial begin
        @(posedge clk); @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        // ---- DUT_MULTI: msip is independently addressable per hart ----
        wrm(32'h0000, 32'h1); // msip[0] = 1
        wrm(32'h0004, 32'h0); // msip[1] = 0
        check("msip[0]/msip[1] independent after msip0=1,msip1=0",
              {30'b0, msip_out_m}, {30'b0, 2'b01});
        wrm(32'h0000, 32'h0); // msip[0] = 0
        wrm(32'h0004, 32'h1); // msip[1] = 1
        check("msip[0]/msip[1] independent after msip0=0,msip1=1 (not aliased to one bit)",
              {30'b0, msip_out_m}, {30'b0, 2'b10});

        // ---- DUT_MULTI: mtimecmp is independently addressable per hart,
        // hi/lo words land correctly ----
        wrm(32'h4000, 32'h0000_0032); // mtimecmp[0] lo = 50
        wrm(32'h4004, 32'h0000_0000); // mtimecmp[0] hi = 0
        wrm(32'h4008, 32'hFFFF_FFFF); // mtimecmp[1] lo = max
        wrm(32'h400C, 32'hFFFF_FFFF); // mtimecmp[1] hi = max (never fires)
        rdm(32'h4000); check("mtimecmp[0] lo readback", {32'b0, rdata_m}, {32'b0, 32'h0000_0032});
        rdm(32'h4008); check("mtimecmp[1] lo readback, distinct storage from hart0's",
              {32'b0, rdata_m}, {32'b0, 32'hFFFF_FFFF});

        // Push the shared mtime past hart0's mtimecmp but nowhere near
        // hart1's: proves mtip is per-hart (only hart0 fires) even though
        // mtime is the one counter both compare against.
        wrm(32'hBFF8, 32'h0000_0064); // mtime lo = 100
        wrm(32'hBFFC, 32'h0000_0000); // mtime hi = 0
        #1;
        check("mtip[0] fires (mtime=100 >= mtimecmp[0]=50)", {31'b0, mtip_m[0]}, {31'b0, 1'b1});
        check("mtip[1] does not (mtime=100 << mtimecmp[1]=max), proving per-hart compare",
              {31'b0, mtip_m[1]}, {31'b0, 1'b0});

        // ---- DUT_SINGLE: NUM_HARTS=1 default still behaves exactly like
        // the pre-parameterization fixed-offset module ----
        wrs(32'h0000, 32'h1);
        rds(32'h0000); check("DUT_SINGLE msip readback unchanged", {31'b0, rdata_s[0]}, {31'b0, 1'b1});
        wrs(32'h4000, 32'h0000_002A); // mtimecmp lo = 42
        rds(32'h4000); check("DUT_SINGLE mtimecmp lo readback unchanged", {32'b0, rdata_s}, {32'b0, 32'h0000_002A});

        // Hart1's would-be mtimecmp (only meaningful once NUM_HARTS>=2) must
        // be a no-op here, not silently alias into hart0's own mtimecmp -
        // the exact off-by-one this module's bounds check exists to avoid.
        wrs(32'h4008, 32'hDEAD_BEEF);
        rds(32'h4000); check("hart0 mtimecmp unaffected by a write to hart1's (nonexistent) slot",
              {32'b0, rdata_s}, {32'b0, 32'h0000_002A});
        rds(32'h4008); check("hart1's (nonexistent) mtimecmp slot reads back 0, not DEAD_BEEF",
              {32'b0, rdata_s}, {32'b0, 32'h0000_0000});

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("CLINT-MULTIHART-TEST: PASS");
        else             $display("CLINT-MULTIHART-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the CLINT multi-hart test never completed");
        $finish;
    end
endmodule
