`timescale 1ns/1ps
// Directed cross-hart LR/SC test for Phase 13 stage 9: rtl/soc/soc_top.v
// with rtl/soc/reservation_monitor.v actually wired to both harts'
// reservation ports. sim/tb_soc_2hart.v (stage 8) proved the hardware
// wiring - two harts fetching, executing and reaching the shared bus
// without corruption - but never touched LR/SC, so it says nothing about
// coherence. This is the roadmap's own stated "Done when" bar for Phase
// 13: an LR/SC pair split across both harts behaving per spec.
//
// RESET_PC points straight into RAM, preloaded with a hand-assembled
// program (sim/soc2hart_lrsc.hex, generated the same field-packing way
// sim/jtagram.hex is) - software/soc/bootrom.c does not know a second hart
// exists yet, so this cannot boot through the real boot ROM.
//
// CORE=inorder only, always: rtl/ooo/core_ooo.v was never given the
// reservation ports Stage 7 gave rtl/cpu_core.v, so under CORE_OOO
// rtl/soc/soc_top.v ties every hart's resv_valid/store_fire to 0 and this
// test's own SC-must-fail expectation would just be wrong. The Makefile
// target builds this DUT with a fixed in-order-only flag/file set, not
// $(IVFLAGS)/$(SOC_RTL), so it always exercises the in-order core
// regardless of `make verify_ooo`'s own ambient CORE=ooo.
//
// Hart 0 makes exactly zero memory writes between its LR and its SC - not
// stylistic, load-bearing: rtl/cpu_core.v's reservation-clearing logic
// invalidates a hart's own reservation on *any* successful write by that
// same hart, to any address (`any_successful_write`, address-independent -
// see docs/architecture.md's LR/SC section). A first version of this test
// had hart 0 write its own "reservation set" flag right after the LR to
// hand-shake with hart 1 - which passed, but for the wrong reason: hart
// 0's own flag write cleared its own reservation before hart 1 ever did
// anything, making the test vacuous. Caught by the same "run it against a
// version that shouldn't pass" discipline every directed test in this
// project uses, just aimed at the *test* this time instead of the RTL:
// forcing hart 0's `resv_invalidate_ext` to a constant 0 (simulating a
// disconnected monitor) should have failed this test, and instead it
// still passed - the tell that something other than cross-hart coherence
// was making the SC fail.
//
// Fixed by only ever giving hart 1 a fixed, generous cycle budget to reach
// its own write - no signal from hart 0 required in that direction at all,
// so hart 0 never needs to write anything before its SC:
//
//   hart 0                          hart 1
//   ------                          ------
//   lr.w  x6, (RESV_ADDR)           (fixed delay - hart 0 has already
//   (waits for FLAG1, reads only)    reached its LR long before this
//                                    delay loop can possibly finish)
//                                   RESV_ADDR = 0xCD   <- the foreign write
//                                   FLAG1 = 1
//   FLAG1_WAIT: poll FLAG1
//   sc.w  x11, x9, (RESV_ADDR)      halt
//   RESULT = x11 (expect 1: FAILED)
//   halt
//
// Hart 1 sets FLAG1 only *after* its own store to RESV_ADDR - in program
// order, on the same hart, so the write is genuinely committed (and
// reservation_monitor.v's combinational resv_invalidate has already fired,
// well before hart 1 even reaches its own next instruction) by the time
// hart 0's poll of FLAG1 can possibly observe it set. FLAG1 is a write by
// hart 1, not hart 0, so it does not touch hart 0's own reservation. This
// proves the *wiring* between two real cores over the real bus, not the
// monitor's own logic (already exhaustively proven in isolation by
// sim/tb_reservation_monitor.v, stage 6) or cpu_core.v's own handling of
// resv_invalidate_ext (already proven by sim/tb_cpu_resv_ports.v, stage 7).
module tb_soc_2hart_lrsc;
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
        .RAM_INIT_FILE("soc2hart_lrsc.hex")
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

        // Generous margin: the handshake itself has no fixed cycle count
        // (each hart polls until the other's flag is set), so this bounds
        // the whole test, not any one step of it.
        repeat (5000) @(posedge clk);

        check("hart 1's foreign write landed on RESV_ADDR (0x8000_0200)",
              DUT.RAM.mem[128], 32'h0000_00CD);
        check("hart 0's SC failed (rd=1) after the cross-hart invalidation",
              DUT.RAM.mem[194], 32'd1);
        check("hart 0 never trapped", {31'b0, trap}, 32'b0);

        if (failures == 0) $display("\nSOC-2HART-LRSC-TEST: PASS");
        else                $display("\nSOC-2HART-LRSC-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("\nSOC-2HART-LRSC-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
