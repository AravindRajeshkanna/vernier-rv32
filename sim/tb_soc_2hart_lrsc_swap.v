`timescale 1ns/1ps
// Directed cross-hart LR/SC test for Phase 15 stage 2 - the mirror image
// of sim/tb_soc_2hart_lrsc.v's own roles, needed because CORE=hetero makes
// the two directions genuinely different tests rather than symmetric
// re-runs of one another.
//
// sim/tb_soc_2hart_lrsc.v has hart 0 hold the reservation (LR/SC) and
// hart 1 make the foreign write. Under CORE=hetero that already proves
// one real asymmetric direction - an in-order hart's own reservation
// invalidated by an out-of-order hart's write - for free, with no changes
// to that file at all. It says nothing about the *other* direction: an
// out-of-order hart's own reservation (held while its own pipeline may be
// speculating, reordering, or still draining its own store buffer)
// invalidated by a plain, synchronous in-order write. `rtl/ooo/
// core_ooo.v`'s own `resv_invalidate_ext` handling was already proven in
// isolation (`sim/tb_ooo_resv_ports.v`, stage 15) and wired for real
// against another `core_ooo.v` hart (stage 16) - but never yet against an
// in-order writer specifically, which is the actual new risk a
// heterogeneous pair introduces here.
//
// The swap is exactly one instruction from the original program
// (sim/soc2hart_lrsc.hex): the branch that sends "hart != 0" to the
// delay-then-write block and lets "hart == 0" fall through to the LR/SC
// block is BNE there and BEQ here (sim/soc2hart_lrsc_swap.hex) - every
// other word, every address, and every expected result is identical,
// because the addresses and values involved (RESV_ADDR, FLAG1, RESULT)
// don't care which hart reaches them, only which *role* each hart plays.
// See that file's own Makefile recipe for the one-line diff.
//
//   hart 0 (cpu_core.v)             hart 1 (core_ooo.v)
//   -------------------             -------------------
//   (fixed delay)                   lr.w  x6, (RESV_ADDR)
//   RESV_ADDR = 0xCD  <- foreign     (waits for FLAG1, reads only)
//   FLAG1 = 1
//   halt                            FLAG1_WAIT: poll FLAG1
//                                   sc.w  x11, x9, (RESV_ADDR)
//                                   RESULT = x11 (expect 1: FAILED)
//                                   halt
//
// This is deliberately built only against CORE=hetero (see this test's
// own Makefile target), never against the ambient $(CORE): under a
// homogeneous CORE=inorder or CORE=ooo build, swapping which hart plays
// which role proves nothing new - both harts are the same module either
// way, so this would just be the mirror image of an already-symmetric
// scenario, redundant CI cost with no new signal. It is a genuinely
// different test only when the two harts are different types.
//
// Also checks that hart 1 is genuinely `core_ooo.v`, not a `cpu_core.v`
// the CORE_HETERO generate-loop arm quietly picked by mistake - the same
// `rob_count`-based proof sim/tb_soc_2hart.v's own Stage 1 check uses,
// for the same reason: the two sentinel/RAM checks below would pass
// identically either way, since the program is plain RV32IA.
module tb_soc_2hart_lrsc_swap;
    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire spi_sck, spi_mosi, spi_miso, spi_cs_n;
    wire [15:0] gpio_out, gpio_dir;
    wire        pwm_out;
    wire        trap;
    wire [15:0] gpio_in = 16'b0;

    soc_top #(
        .NUM_HARTS(2),
        .RESET_PC(32'h8000_0000),
        .RAM_BYTES(2048),
        .RAM_INIT_FILE("soc2hart_lrsc_swap.hex")
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .pwm_out(pwm_out),
        .sdram_dq_i(16'b0),
        .trap(trap)
    );

    localparam CLK_PERIOD = 40;  // 25 MHz, matching soc_top's own CLK_HZ default
    always #(CLK_PERIOD / 2) clk = ~clk;

    integer failures = 0;
    task check(input [511:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %08h expected %08h", name, got, want);
                failures = failures + 1;
            end else begin
                $display("  ok   %0s: %08h", name, got);
            end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;

        // Same generous margin as sim/tb_soc_2hart_lrsc.v's own, for the
        // same reason: the handshake has no fixed cycle count.
        repeat (5000) @(posedge clk);

        check("hart 0's foreign write landed on RESV_ADDR (0x8000_0200)",
              DUT.RAM.mem[128], 32'h0000_00CD);
        check("hart 1's SC failed (rd=1) after the cross-hart invalidation",
              DUT.RAM.mem[194], 32'd1);
        check("hart 0 never trapped", {31'b0, trap}, 32'b0);

`ifdef CORE_HETERO
        check("hart 1 is genuinely core_ooo.v - its own rob_count resolves and is defined",
              {31'b0, ^DUT.g_hart[1].CPU.rob_count !== 1'bx}, 32'b1);
`endif

        if (failures == 0) $display("\nSOC-2HART-LRSC-SWAP-TEST: PASS");
        else                $display("\nSOC-2HART-LRSC-SWAP-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("\nSOC-2HART-LRSC-SWAP-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
