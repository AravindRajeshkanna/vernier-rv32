// Directed test for rtl/pmp.v against hand-derived scenarios from the
// RISC-V Privileged spec's PMP chapter, not just "it runs". rtl/pmp.v is
// pure combinational logic (no clk/rst), so this drives inputs and checks
// `fault` after a settling delay - no clock needed.
//
// What's covered, and why each one is here rather than assumed from reading
// the RTL:
//   1. Default rule when nothing matches: M allowed, S/U denied - the rule
//      that makes turning PMP hardware *on* a hazard for every existing
//      S/U-mode test the moment it's wired to an access path (see
//      rtl/pmp.v's header and docs/roadmap.md).
//   2. NA4 - the minimum region size, and the one riscv-tests' own
//      rv32mi-p-pmpaddr also assumes G=0 supports.
//   3. NAPOT at a small size (8 bytes) - the smallest size NAPOT actually
//      adds over NA4.
//   4. NAPOT at the maximal size (the whole 32-bit space) - the exact
//      encoding (`pmpaddr = -1`) real firmware uses to open everything at
//      boot, and the one case that needs the extra address bit rtl/pmp.v's
//      33-bit base/top carries specifically to avoid a wraparound here.
//   5. TOR, including a straddling access - the one region shape where a
//      naturally-aligned access can still straddle a boundary, since TOR
//      bounds are arbitrary byte addresses rather than power-of-two-aligned.
//   6. Priority order - two entries that would disagree about the same
//      address; the lower-numbered one must be the one that's consulted.
//   7. Lock bit - both that it denies M-mode too, and that it leaves
//      everything outside that one entry's range unaffected.
`timescale 1ns/1ps
module tb_pmp;
    localparam [1:0] PRIV_U = 2'b00, PRIV_S = 2'b01, PRIV_M = 2'b11;

    reg [127:0] pmpcfg  = 128'b0;
    reg [511:0] pmpaddr = 512'b0;
    reg [31:0]  addr    = 32'b0;
    reg [1:0]   size    = 2'd2;
    reg         is_write = 1'b0;
    reg         is_fetch = 1'b0;
    reg [1:0]   priv    = PRIV_M;
    wire        fault;

    pmp UUT (
        .pmpcfg(pmpcfg), .pmpaddr(pmpaddr),
        .addr(addr), .size(size), .is_write(is_write), .is_fetch(is_fetch),
        .priv(priv), .fault(fault)
    );

    integer errors = 0;

    task check(input [599:0] name, input got, input expected);
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: got fault=%0b expected fault=%0b", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: fault=%0b", name, got);
            end
        end
    endtask

    // Sets entry i's cfg (l,a,x,w,r packed the spec's way) and addr word.
    task set_entry(input integer i, input l, input [1:0] a, input x, input w, input r,
                    input [31:0] addrword);
        begin
            pmpcfg[8*i +: 8]   = {l, 2'b00, a, x, w, r};
            pmpaddr[32*i +: 32] = addrword;
        end
    endtask

    task clear_all;
        begin
            pmpcfg  = 128'b0;
            pmpaddr = 512'b0;
        end
    endtask

    initial begin
        // ---- 1. default rule when nothing matches ----
        clear_all;
        addr = 32'h1000; size = 2'd2; is_write = 1'b0; is_fetch = 1'b0;
        priv = PRIV_M; #1; check("default/M/unmatched", fault, 1'b0);
        priv = PRIV_S; #1; check("default/S/unmatched", fault, 1'b1);
        priv = PRIV_U; #1; check("default/U/unmatched", fault, 1'b1);

        // ---- 2. NA4: 4 bytes at 0x1000, R=1 W=0 X=0, unlocked ----
        clear_all;
        set_entry(0, 1'b0, 2'b10, 1'b0, 1'b0, 1'b1, 32'h1000 >> 2);
        priv = PRIV_S; is_write = 1'b0; is_fetch = 1'b0;
        addr = 32'h1000; size = 2'd2; #1; check("NA4/S/read-in-range", fault, 1'b0);
        addr = 32'h1000; is_write = 1'b1; #1; check("NA4/S/write-denied(no W)", fault, 1'b1);
        is_write = 1'b0; addr = 32'h1004; #1; check("NA4/S/read-out-of-range", fault, 1'b1);
        priv = PRIV_M; addr = 32'h1004; #1; check("NA4/M/unlocked-bypass-elsewhere", fault, 1'b0);

        // ---- 3. NAPOT, 8 bytes at 0x2000, R=1 W=1 X=0 ----
        clear_all;
        set_entry(1, 1'b0, 2'b11, 1'b0, 1'b1, 1'b1, (32'h2000 >> 2)); // trailing 1s=0 -> 8 bytes
        priv = PRIV_S; is_write = 1'b0;
        addr = 32'h2000; size = 2'd2; #1; check("NAPOT8/S/read@base", fault, 1'b0);
        addr = 32'h2004; #1; check("NAPOT8/S/read@base+4(still-in)", fault, 1'b0);
        addr = 32'h2008; #1; check("NAPOT8/S/read@base+8(out)", fault, 1'b1);
        is_write = 1'b1; addr = 32'h2000; #1; check("NAPOT8/S/write@base(W=1)", fault, 1'b0);

        // ---- 4. NAPOT maximal: whole 32-bit space, R=W=X=1 (real firmware's
        //         "open everything" encoding: pmpaddr = all-ones) ----
        clear_all;
        set_entry(2, 1'b0, 2'b11, 1'b1, 1'b1, 1'b1, 32'hFFFF_FFFF);
        priv = PRIV_S; is_write = 1'b0; is_fetch = 1'b0;
        addr = 32'h0000_0000; size = 2'd2; #1; check("NAPOT-max/S/read@0", fault, 1'b0);
        addr = 32'hFFFF_FFFC; size = 2'd2; #1; check("NAPOT-max/S/read@top-word", fault, 1'b0);
        is_write = 1'b1; #1; check("NAPOT-max/S/write@top-word", fault, 1'b0);
        is_fetch = 1'b1; is_write = 1'b0; #1; check("NAPOT-max/S/fetch@top-word", fault, 1'b0);
        priv = PRIV_U; #1; check("NAPOT-max/U/fetch@top-word", fault, 1'b0);

        // ---- 5. TOR: [0x100, 0x108), R=1 W=1 X=0 - 8 bytes, using the
        //         *preceding* entry's pmpaddr as the base even though that
        //         entry (2) itself stays OFF - TOR's base comes from
        //         pmpaddr[i-1] regardless of entry i-1's own mode. ----
        clear_all;
        pmpaddr[32*2 +: 32] = 32'h100 >> 2; // entry 2 stays OFF; only its addr matters
        set_entry(3, 1'b0, 2'b01, 1'b0, 1'b1, 1'b1, 32'h108 >> 2);
        priv = PRIV_S; is_write = 1'b0; is_fetch = 1'b0;
        addr = 32'h100; size = 2'd2; #1; check("TOR/S/word@base(fully-in)", fault, 1'b0);
        addr = 32'h104; size = 2'd2; #1; check("TOR/S/word@base+4(fully-in)", fault, 1'b0);
        addr = 32'h108; size = 2'd2; #1; check("TOR/S/word@top(out)", fault, 1'b1);
        // Defensive-only: a word access that isn't 4-byte-aligned, which
        // cpu_core.v's mem_misaligned would already have rejected before
        // PMP ever ran (see rtl/pmp.v's header) - straddles the boundary
        // regardless, fed here directly since this module has no way to
        // enforce that precondition on its own caller.
        addr = 32'h106; size = 2'd2; #1; check("TOR/S/word@0x106(deliberately-misaligned,straddles-top)", fault, 1'b1);

        // ---- 6. priority: entry 0 denies, entry 1 (wider, would allow)
        //         must never be consulted once entry 0 overlaps ----
        clear_all;
        set_entry(0, 1'b0, 2'b11, 1'b0, 1'b0, 1'b0, (32'h3000 >> 2)); // NAPOT 8B @0x3000, no perms
        set_entry(1, 1'b0, 2'b11, 1'b1, 1'b1, 1'b1, 32'hFFFF_FFFF);   // open everything
        priv = PRIV_S; is_write = 1'b0; is_fetch = 1'b0;
        addr = 32'h3000; size = 2'd2; #1; check("priority/entry0-wins-and-denies", fault, 1'b1);
        addr = 32'h4000; size = 2'd2; #1; check("priority/entry0-no-match-falls-to-entry1", fault, 1'b0);

        // ---- 7. lock bit: applies to M too, and only to its own entry ----
        clear_all;
        set_entry(4, 1'b1, 2'b10, 1'b0, 1'b0, 1'b1, 32'h5000 >> 2); // locked NA4, R only
        priv = PRIV_M; is_write = 1'b0; is_fetch = 1'b0;
        addr = 32'h5000; size = 2'd2; #1; check("lock/M/read-locked-region(R=1)", fault, 1'b0);
        is_write = 1'b1; #1; check("lock/M/write-locked-region(W=0)-denied-even-at-M", fault, 1'b1);
        is_write = 1'b0; addr = 32'h5004; #1; check("lock/M/elsewhere-unaffected-by-unrelated-lock", fault, 1'b0);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("PMP-TEST: PASS");
        else             $display("PMP-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the PMP test never completed");
        $finish;
    end
endmodule
