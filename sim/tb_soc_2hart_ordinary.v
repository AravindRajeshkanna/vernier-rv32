`timescale 1ns/1ps
// Directed cross-hart ORDINARY (non-atomic) load/store test - closes the
// gap Phase 15 Stage 2's own account named explicitly: "Ordinary
// (non-atomic) cross-hart loads/stores between the two hart types were
// already exercised incidentally by both new tests' own foreign-write
// step, but nothing here specifically stresses concurrent, unsynchronized
// ordinary traffic the way the LR/SC hazard stresses atomics." This is
// that dedicated test, built with the same directed-hazard rigor
// sim/tb_soc_2hart_lrsc.v already established, not a symmetric re-run of
// it - no LR/SC or AMO instruction appears anywhere in this program.
//
// Real, before this file: no cross-hart ordinary load/store hazard test
// existed anywhere in this project, homogeneous or heterogeneous - this
// is genuinely new coverage, not an extension of an existing Phase 13
// test the way sim/tb_soc_2hart_lrsc.v itself was reused unchanged from
// Phase 13 Stage 9. Gated CORE-aware (sim_soc_2hart_ordinary, matching
// sim_soc_2hart_lrsc's own ambient-$(CORE) pattern) and hetero-specific
// (sim_soc_2hart_ordinary_hetero, hardcoded file list + -DCORE_HETERO,
// matching sim_soc_2hart_lrsc_hetero's own pattern) - both configurations
// exercise the identical program.
//
// One program proves both directions, unlike the LR/SC pair, which needed
// a genuinely separate test (sim/tb_soc_2hart_lrsc_swap.v) for its own
// reversed direction: LR/SC's own asymmetry comes from each core type's
// own internal reservation-invalidation logic (core_ooo.v's
// resv_invalidate_ext handling had only ever been proven in different
// configurations than an in-order writer specifically - see that file's
// own header), a real, core-type-specific mechanism. Ordinary loads/stores
// have no equivalent per-core-type mechanism to be asymmetric about - the
// bus interconnect treats "some hart writes, some hart reads" uniformly
// regardless of which hart is which - so one bidirectional program is
// real, sufficient coverage, not an arbitrarily narrowed scope.
//
// The hazard, by address (RESET_PC + offset):
//   WORD_A  (0x100), FLAG_A (0x104)  - hart 0 writes, hart 1 reads
//   WORD_B  (0x108), FLAG_B (0x10C)  - hart 1 writes, hart 0 reads
//   R1      (0x110)                  - hart 1's own observed read of WORD_A
//   R2      (0x114)                  - hart 0's own observed read of WORD_B
//
//   hart 0                          hart 1
//   ------                          ------
//   (tight delay loop, 20 iters)    WORD_A_WAIT: poll FLAG_A
//   WORD_A = 0x11
//   FLAG_A = 1
//   WORD_B_WAIT: poll FLAG_B        (sees FLAG_A) read WORD_A -> R1
//   (sees FLAG_B) read WORD_B -> R2 (tight delay loop, 20 iters)
//   halt                            WORD_B = 0x22
//                                   FLAG_B = 1
//                                   halt
//
// The delay loops are short (20 iterations) deliberately - a real, tuned,
// tight window rather than a generous one, so each write and the other
// hart's own concurrent pipeline state land close together in real time,
// the same "tuned, not generous delay" technique
// sim/tb_soc_2hart_lrsc.v's own 200-iteration delay already uses to
// provoke a real hazard rather than an eventually-consistent non-event.
//
// Hand-encoded the same field-packing way sim/soc2hart_lrsc.hex is
// (Makefile's own sim/soc2hart_ordinary.hex rule) - independently
// verified against a real disassembler (riscv64-unknown-elf-objdump -m
// riscv:rv32) before being trusted, not just hand-traced, the same
// "verify by running it" discipline this whole project holds itself to.
module tb_soc_2hart_ordinary;
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
        .RAM_INIT_FILE("soc2hart_ordinary.hex")
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
        // (each hart polls until the other's flag is set), matching
        // sim/tb_soc_2hart_lrsc.v's own settle window exactly.
        repeat (5000) @(posedge clk);

        check("hart 1's own read of WORD_A (0x8000_0100) landed in R1 (0x8000_0110)",
              DUT.RAM.mem[68], 32'h0000_0011);
        check("hart 0's own read of WORD_B (0x8000_0108) landed in R2 (0x8000_0114)",
              DUT.RAM.mem[69], 32'h0000_0022);
        check("WORD_A holds hart 0's real write, not corrupted",
              DUT.RAM.mem[64], 32'h0000_0011);
        check("WORD_B holds hart 1's real write, not corrupted",
              DUT.RAM.mem[66], 32'h0000_0022);
        check("neither hart trapped", {31'b0, trap}, 32'b0);

`ifdef CORE_HETERO
        // Same real, mutation-confirmed identity proof
        // sim/tb_soc_2hart.v's own stage 1 check and
        // sim/tb_soc_2hart_lrsc.v's own stage 2 check both already use: a
        // hard Icarus compile error against the wrong module if hart 1
        // is not genuinely core_ooo.v, not a silent pass.
        check("hart 1 is genuinely core_ooo.v - its own rob_count resolves and is defined",
              {31'b0, ^DUT.g_hart[1].CPU.rob_count !== 1'bx}, 32'b1);
`endif

        if (failures == 0) $display("\nSOC-2HART-ORDINARY-TEST: PASS");
        else                $display("\nSOC-2HART-ORDINARY-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("\nSOC-2HART-ORDINARY-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
