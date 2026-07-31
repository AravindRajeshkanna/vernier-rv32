`timescale 1ns/1ps
// Self-checking testbench for the 5-stage pipelined RV32IMA core with
// full M/S/U privilege modes + trap delegation, a data AND instruction
// Sv32 MMU, a BTB branch predictor, and a real prioritized/claimable
// PLIC alongside the CLINT timer/software interrupt.
//
// program.hex (hand-assembled via a throwaway Python encoder, not part of
// the repo) runs a series of checks back to back, each ORing a distinct
// bit into x5 (the cumulative fail flag) on failure, then stores x5 once
// at the end - so the full 32-bit word at mem[4..7] being zero means
// every check passed (a single byte stopped being enough once the fail
// bits started needing more than 8 of them). A single M-mode
// trap_handler is shared by every synchronous exception and interrupt
// that lands in M: it tells them apart via `mcause`'s sign (negative =
// an interrupt, since bit 31 is set) and, for exceptions, compares
// against an expected-cause value the main line sets in x14 right before
// each trigger; it also counts every entry in x31 as a global sanity
// check that traps that should have fired actually did. A separate
// s_trap_handler (reached via `stvec`) handles the one delegated trap.
//
//  1. Arithmetic/branch/jump, 2. load-use hazard, 3. ECALL/MRET,
//  4. illegal instruction, 5. MUL family, 6. DIV family, 7. timer
//  interrupt, 8. data-only Sv32 MMU (translate/store/load, page fault,
//  TLB+SFENCE.VMA) - all unchanged from the previous update.
//  9. A extension: AMOADD.W/AMOSWAP.W round trips, then LR.W/SC.W - one
//     successful reservation and one deliberately broken by an
//     intervening store, expecting SC.W to fail without writing memory.
//  10. S/U privilege modes + trap delegation: MRET drops to U-mode;
//      ECALL-from-U (cause 8) is delegated (medeleg) to s_trap_handler,
//      which fixes up sepc, deliberately raises its own ECALL-from-S
//      (cause 9, undelegated) to bounce through M and back, then SRETs
//      to U-mode; U-mode finally raises EBREAK (cause 3, undelegated) as
//      a clean way back to M (the M-mode handler forces mstatus.MPP=M
//      before its own mret, since MRET/SRET always restore the *actual*
//      previous privilege).
//  11. BTB: a single bounded backward-branch loop naturally exercises a
//      cold-miss mispredict (first taken branch), steady correct
//      prediction for every iteration in between, and a loop-exit
//      mispredict (predicted taken, actually falls through) - checked
//      via `DUT.CPU.mispredict_count`, a hierarchical reference to an
//      internal counter with no other architectural visibility.
//  12. PLIC: three sources (priorities 5/3/1) held permanently asserted
//      by this testbench (safe - the PLIC only reports a source as
//      pending-and-eligible once software enables it, so asserting the
//      raw lines from reset doesn't interfere with any earlier part);
//      threshold=2 makes the priority-1 source never eligible. The
//      handler must claim the priority-5 source first, then priority-3,
//      demonstrating real claim/complete semantics (not just a single
//      pending bit).
//  13. Instruction-fetch page fault (cause 12): a 4MB identity-mapping
//      superpage keeps this program's own code fetchable once satp is
//      enabled and the hart drops to U-mode, but a second mapping is
//      deliberately non-executable (X=0) - jumping there must fault via
//      the *instruction* MMU's own permission check, recovered the same
//      forced-return-to-M way as the EBREAK case above.
module tb_top;
    // Whole-program total, not just Part 11's loop: every branch/JAL/
    // JALR/MRET/SRET in the entire run trains the same BTB and can
    // mispredict, so this is a regression baseline determined by running
    // the design once and recording `DUT.CPU.mispredict_count`'s final
    // value, not something hand-derived from first principles - a real
    // control-flow change anywhere in program.hex will legitimately move
    // this number, at which point it should be recomputed, not bumped
    // blindly. What it actually demonstrates: Part 11's 20-iteration
    // loop contributes only 2 of these (a cold-miss on the first taken
    // branch, a loop-exit mispredict on the last) rather than one per
    // iteration, which is the predictor actually working.
    localparam EXPECT_MISPREDICTS = 54;

    reg clk = 0;
    reg rst = 1;
    reg [7:0] irq_sources = 8'b0;

    top #(
        .INIT_FILE("program.hex")
    ) DUT (
        .clk(clk),
        .rst(rst),
        .irq_sources(irq_sources),
        .uart_rx(1'b1) // idle-high (real UART idle level); this test doesn't exercise the UART
    );

    always #5 clk = ~clk; // 100 MHz virtual clock

    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_top);

        rst = 1;
        repeat (2) @(posedge clk);
        rst = 0;

        // Sources 1,2,3 (bits 0,1,2) held asserted throughout - harmless
        // until Part 12 enables them, since PLIC pending-and-eligible
        // requires software-set `enable` regardless of the raw level.
        irq_sources = 8'b0000_0111;

        // ~430 instructions, several taken branches/jumps/traps/
        // interrupts (2-cycle flush each, or free once the BTB predicts
        // correctly), a load-use stall, ~6 multi-cycle divides (~33
        // cycles each), two bounded spin loops, a handful of MMU/ITLB
        // walks (a few cycles each), and an M/S/U privilege round trip
        // -> generous margin at 20000 cycles
        repeat (20000) @(posedge clk);

        $display("---------------------------------------------");
        $display("mem[0..3] (expect 15,0,0,0): %0d %0d %0d %0d",
                  DUT.DMEM.mem[0], DUT.DMEM.mem[1], DUT.DMEM.mem[2], DUT.DMEM.mem[3]);
        $display("fail word (expect 0 = PASS): 0x%08x",
                  {DUT.DMEM.mem[7], DUT.DMEM.mem[6], DUT.DMEM.mem[5], DUT.DMEM.mem[4]});
        $display("BTB mispredict_count (expect %0d): %0d", EXPECT_MISPREDICTS, DUT.CPU.mispredict_count);

        if ({DUT.DMEM.mem[7], DUT.DMEM.mem[6], DUT.DMEM.mem[5], DUT.DMEM.mem[4]} == 32'h0 &&
            DUT.DMEM.mem[0] == 8'd15 &&
            DUT.CPU.mispredict_count == EXPECT_MISPREDICTS) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED");
        end
        $display("---------------------------------------------");

        $finish;
    end

    // Safety timeout in case of a hang
    initial begin
        #250000;
        $display("TIMEOUT - simulation did not finish in time");
        $finish;
    end
endmodule
