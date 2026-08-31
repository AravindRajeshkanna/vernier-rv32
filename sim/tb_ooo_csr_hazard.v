// Directed test: does rtl/ooo/core_ooo.v's register-form CSR write ever
// assert csr_file's `we` before its source operand is actually registered
// ready? docs/roadmap.md's "CORE=ooo has no Fmax" entry (round 2) traced
// every consumer of headS_op1/headS_op2's cdbB/cdbL bypass arms against the
// registered `headS_ready` and found five gated correctly - and one that
// is not: csr_file's `.we` port is gated by `head_ex_commit`, which does
// not include headS_ready/rob_r1_ready[rob_head] anywhere in its chain.
// That was left as an open, testable question rather than a confirmed bug.
// This settles it empirically instead of by more reading: a multi-cycle
// producer (DIV, which is not single-cycle) immediately followed by a
// register-form CSR write of its result, with nothing between them to
// absorb the latency, watched cycle by cycle via hierarchical reference -
// the same kind of internal-signal check sim/tb_cpu_halt.v already uses
// for exactly this reason (this testbench deliberately does reach into the
// design, unlike sim/tb_jtag.v's protocol-level style, because the thing
// under test - a specific control signal's timing - has no black-box
// observation point).
`timescale 1ns / 1ps

module tb_ooo_csr_hazard;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    wire [7:0] irq_sources = 8'b0;
    wire uart_tx;

    top TOP (
        .clk(clk), .rst(rst),
        .irq_sources(irq_sources),
        .uart_tx(uart_tx), .uart_rx(1'b1)
    );

    // li a1, 1000000 / li a2, 7 / div a5, a1, a2 / csrrw x0, mscratch, a5 /
    // csrrs a6, mscratch, x0 / j . - encodings verified against
    // riscv64-unknown-elf-as/objdump, not hand-derived:
    //   lui   a1, 0xf4          -> 000f45b7
    //   addi  a1, a1, 576       -> 24058593   (a1 = 0xf4240 = 1000000)
    //   addi  a2, x0, 7         -> 00700613
    //   div   a5, a1, a2        -> 02c5c7b3   (a5 = 1000000/7 = 142857)
    //   csrrw x0, mscratch, a5  -> 34079073
    //   csrrs a6, mscratch, x0  -> 34002873
    //   jal   x0, 0 (j .)       -> 0000006f
    initial begin
        TOP.IMEM.mem[0] = 32'h000f45b7;
        TOP.IMEM.mem[1] = 32'h24058593;
        TOP.IMEM.mem[2] = 32'h00700613;
        TOP.IMEM.mem[3] = 32'h02c5c7b3;
        TOP.IMEM.mem[4] = 32'h34079073;
        TOP.IMEM.mem[5] = 32'h34002873;
        TOP.IMEM.mem[6] = 32'h0000006f;
    end

    localparam [31:0] EXPECTED_QUOTIENT = 32'd142857;  // 1000000 / 7

    integer premature_hits  = 0;
    integer wrong_value_hits = 0;
    integer failures        = 0;

    // Watch every cycle: `we` asserted for a CSR instruction sitting at
    // rob_head while that same entry's own r1 operand is not yet
    // registered ready is exactly the window the roadmap entry flagged.
    // `!rst` only - X-compares against `!==` before reset would just add
    // noise, and nothing meaningful happens before rst deasserts anyway.
    always @(posedge clk) begin
        if (!rst && TOP.CPU.CSR.we && TOP.CPU.rob_is_csr[TOP.CPU.rob_head] &&
            !TOP.CPU.headS_ready) begin
            premature_hits = premature_hits + 1;
            $display("  [t=%0t] we asserted before headS_ready: csr_op_operand=%h (want %h)",
                     $time, TOP.CPU.csr_op_operand, EXPECTED_QUOTIENT);
            if (TOP.CPU.csr_op_operand !== EXPECTED_QUOTIENT)
                wrong_value_hits = wrong_value_hits + 1;
        end
    end

    task check(input [511:0] name, input ok);
        begin
            $write("  %0s", name);
            $write("%0s\n", ok ? " ok" : " FAILED");
            if (!ok) failures = failures + 1;
        end
    endtask

    initial begin
        $display("\n=== OOO CSR-write-before-ready hazard ===");
        repeat (4) @(posedge clk);
        rst = 0;

        repeat (200) @(posedge clk);

        // The architectural, black-box checks: what actually landed.
        // regfile_phys has no architectural index of its own - the RAT
        // (core_ooo.v's rat[]) says which physical register a6 (x16)
        // currently maps to, and that is what a later reader would see.
        check("mscratch holds the DIV result (csr_file's own register)",
              TOP.CPU.CSR.mscratch_r === EXPECTED_QUOTIENT);
        check("a6 (csrrs's own destination, via the RAT) also holds it",
              TOP.CPU.RF.regs[TOP.CPU.rat[16]] === EXPECTED_QUOTIENT);

        // The internal-signal check: whether `we` was ever asserted before
        // the operand was registered ready, and if so, whether the value
        // it used at that moment was already correct anyway - the question
        // the architectural checks alone cannot answer, because a correct
        // *final* value does not rule out a wrong transient one along the
        // way (see the roadmap entry's own reasoning on what would and
        // would not be observable).
        $display("  we asserted before headS_ready: %0d time(s)", premature_hits);
        check("no premature we assertion used a value other than the correct one",
              wrong_value_hits == 0);

        $display("");
        if (failures == 0) $display("OOO-CSR-HAZARD-TEST: PASS");
        else                $display("OOO-CSR-HAZARD-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #20_000;
        $display("\nOOO-CSR-HAZARD-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
