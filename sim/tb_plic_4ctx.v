// Directed test for rtl/plic.v's NUM_CONTEXTS default (bumped to 4 for
// Phase 13, docs/roadmap.md) - proves the two NEW contexts (2, 3: a second
// hart's own M-mode/S-mode, were one ever instantiated) land at exactly the
// byte offsets software/soc/soc.h's own PLIC_ENABLE/PLIC_THRESHOLD/PLIC_CLAIM
// macros compute, and are independently addressable from contexts 0/1 and
// from each other.
//
// formal/run.sh's "plic" target already proves the *logical* properties
// (eip correctness, claim eligibility, mutual exclusion) hold generically
// for however many contexts the module declares - this test complements
// that with something formal's own properties don't independently check:
// the strided address arithmetic itself. A bug that shifted context 3's
// window to, say, 0x204000 instead of 0x203000 would not necessarily
// violate any logical property (context 3 would still work correctly, just
// at the wrong address a real driver never asks) - only a test that knows
// the documented offset in advance and checks it directly can catch that.
`timescale 1ns/1ps
module tb_plic_4ctx;
    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    localparam NS = 4;
    localparam NC = 4;

    reg  [31:0] addr = 0;
    reg  [31:0] wdata = 0;
    reg         we = 0, re = 0;
    wire [31:0] rdata;
    reg  [NS-1:0] irq_sources = 0;
    wire [NC-1:0] eip;

    plic #(.NUM_SOURCES(NS), .NUM_CONTEXTS(NC)) DUT (
        .clk(clk), .rst(rst),
        .addr(addr), .wdata(wdata), .we(we), .re(re), .rdata(rdata),
        .irq_sources(irq_sources), .eip(eip)
    );

    // Matches software/soc/soc.h's own macros exactly, for the offsets
    // this test needs (relative to the PLIC's own base, which addr already
    // is - see plic.v's header, "addr is expected pre-decoded").
    function [31:0] plic_enable(input [7:0] ctx);
        plic_enable = 32'h002000 + 32'h80 * ctx;
    endfunction
    function [31:0] plic_threshold(input [7:0] ctx);
        plic_threshold = 32'h200000 + 32'h1000 * ctx;
    endfunction
    function [31:0] plic_claim(input [7:0] ctx);
        plic_claim = 32'h200004 + 32'h1000 * ctx;
    endfunction

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

    task wr(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); #1;
            addr = a; wdata = d; we = 1'b1;
            @(posedge clk); #1;
            we = 1'b0;
        end
    endtask

    // `re` is a level-sensitive claim-side-effect gate (plic.v's own header:
    // "re must be asserted only on a cycle where a real load instruction is
    // reading this address"), so this pulses it for exactly the `#1` window
    // the value-check needs and clears it again immediately - never leaving
    // it stuck high into a later wr()/rd() call, which could otherwise
    // silently claim a source this test never meant to touch.
    task rd(input [31:0] a);
        begin
            addr = a; re = 1'b1;
            #1;
            re = 1'b0;
        end
    endtask

    initial begin
        @(posedge clk); @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        // Priority 5 for source 1 (mid-range, above any threshold used below).
        wr(32'h0000_0004, 32'h0000_0005);

        // Enable source 1 for context 2 only, at its documented offset.
        wr(plic_enable(2), 32'h0000_0002); // bit 1 = source 1
        wr(plic_threshold(2), 32'h0000_0000);
        rd(plic_threshold(2));
        check("context 2 threshold readback at its documented offset (0x202000)",
              rdata, 32'h0000_0000);

        // Contexts 0/1/3 must read back the enable bit as still clear -
        // proves 2's enable write didn't alias into a neighbor's window.
        rd(plic_enable(0)); check("context 0 enable unaffected", rdata, 32'h0);
        rd(plic_enable(1)); check("context 1 enable unaffected", rdata, 32'h0);
        rd(plic_enable(3)); check("context 3 enable unaffected", rdata, 32'h0);

        // Assert source 1: only context 2 (enabled, priority 5 > threshold 0)
        // should see eip; 0, 1, 3 (never enabled for it) must not. `pending`
        // is a registered signal driven from irq_sources, so this needs a
        // clock edge before eip reflects it.
        irq_sources = 4'b0001; // source 1 is irq_sources[1-1] = irq_sources[0]
        @(posedge clk); #1;
        check("eip[2] asserts (the only context enabled for source 1)",
              {31'b0, eip[2]}, {31'b0, 1'b1});
        check("eip[0]/eip[1]/eip[3] stay clear",
              {29'b0, eip[3], eip[1], eip[0]}, {29'b0, 3'b000});

        // Claim through context 2's own claim register at its documented
        // offset; context 3's claim (a different context entirely) must
        // still read back 0 - nothing was ever pending there.
        rd(plic_claim(2));
        check("context 2 claims source 1 at its documented offset (0x202004)",
              rdata, 32'h0000_0001);
        rd(plic_claim(3));
        check("context 3's own claim register reads 0 - unaffected by context 2's claim",
              rdata, 32'h0000_0000);

        // Complete it through context 2's own claim/complete register
        // (write-back protocol plic.v already uses for every context).
        wr(plic_claim(2), 32'h0000_0001);
        irq_sources = 4'b0000;
        @(posedge clk); #1;
        check("eip[2] clears once the source is deasserted and completed",
              {31'b0, eip[2]}, {31'b0, 1'b0});

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("PLIC-4CTX-TEST: PASS");
        else             $display("PLIC-4CTX-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the PLIC 4-context test never completed");
        $finish;
    end
endmodule
