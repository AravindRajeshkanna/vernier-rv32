`timescale 1ns/1ps
// Directed cross-hart plain-AMO test: proves amoswap.w is genuinely atomic
// with respect to the *other* hart, not just within one hart's own
// instruction stream. rtl/soc/reservation_monitor.v already proves LR/SC's
// own cross-hart coherence (sim/tb_soc_2hart_lrsc.v); this is the same bar
// for the ordinary AMOs LR/SC deliberately isn't - amoadd.w, amoswap.w, and
// the rest never go through the reservation monitor at all, and until now
// nothing in this project ever put two harts in real, sustained contention
// on a plain AMO to check whether the interconnect actually protects them
// the way its own header comment claims.
//
// It didn't: this exact scenario - two harts hammering amoswap.w on one
// shared word - deadlocked permanently within a handful of exchanges before
// rtl/soc/wb_interconnect.v's own AMO-atomicity fix (docs/roadmap.md's
// Phase 13 Stage 1 entry, corrected in place) was replaced with an explicit
// d_amo_wrphase-based mechanism. The old one was inferred from bus-level
// timing and provably never actually engaged against real hardware
// (rtl/soc/cpu_wb.v's own one-cycle decode bubble broke the inference this
// file never checked); the new one is driven directly by each core's own
// amo_wr_phase register instead.
//
// Both harts run the identical program (sim/soc2hart_amoswap.hex, generated
// the same field-packing way sim/soc2hart_lrsc.hex is): each does ITERS
// rounds of acquire (amoswap.w spin) / increment a *shared* counter with a
// plain, non-atomic load-add-store / release, then signals done. The shared
// counter is the actual proof, not a side observation: if mutual exclusion
// ever really breaks - two harts' critical sections genuinely overlapping,
// even briefly - the counter's own non-atomic read-modify-write can lose an
// update, and the final count comes out *below* 2*ITERS. It can never come
// out above (an AMO's own value is always exactly 0 or 1, so there is no
// way to gain updates, only lose them), which is what makes "exactly
// 2*ITERS, not merely close to it" a real correctness proof rather than a
// plausible-looking number.
`ifndef ITERS
`define ITERS 100
`endif

module tb_soc_2hart_amoswap;
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
        .RAM_INIT_FILE("soc2hart_amoswap.hex")
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

    // Word indices into DUT.RAM.mem[]: (0x8000_0200 + offset - RAM base) / 4.
    wire [31:0] lock_word   = DUT.RAM.mem[128];  // 0x8000_0200
    wire [31:0] counter     = DUT.RAM.mem[129];  // 0x8000_0204
    wire [31:0] hart0_done  = DUT.RAM.mem[130];  // 0x8000_0208
    wire [31:0] hart1_done  = DUT.RAM.mem[131];  // 0x8000_020C

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;

        // Generous margin: each of ITERS rounds is ~15 instructions of real
        // work over the Wishbone bus, times two harts, plus however many
        // extra cycles a genuinely contended amoswap retry costs - bounded,
        // but not tightly, since the whole point is not to assume how many
        // retries a fixed arbitration order produces.
        while ((hart0_done !== 32'd1 || hart1_done !== 32'd1) &&
               $time < 2_000_000)
            @(posedge clk);

        check("hart 0 signaled done", hart0_done, 32'd1);
        check("hart 1 signaled done", hart1_done, 32'd1);
        // The real proof: see this file's own header for why the count can
        // only ever come out at or below 2*ITERS, never above, so "exactly"
        // is a genuine mutual-exclusion proof, not an approximation.
        check("shared counter reflects every increment, no lost updates",
              counter, 32'd2 * `ITERS);
        check("lock released cleanly", lock_word, 32'd0);
        check("neither hart trapped", {31'b0, trap}, 32'b0);

`ifdef CORE_HETERO
        // Same rob_count-based module-identity proof every other Phase 15
        // testbench uses - a hard Icarus compile error against the wrong
        // module, not a silent pass, if hart 1 were ever a second
        // cpu_core.v instead of the real core_ooo.v this test's own result
        // is being published against.
        check("hart 1 is genuinely core_ooo.v - its own rob_count resolves and is defined",
              {31'b0, ^DUT.g_hart[1].CPU.rob_count !== 1'bx}, 32'b1);
`endif

        if (failures == 0) $display("\nSOC-2HART-AMOSWAP-TEST: PASS");
        else                $display("\nSOC-2HART-AMOSWAP-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("\nSOC-2HART-AMOSWAP-TEST: FAIL (timeout)");
        $display("  lock=%0d counter=%0d hart0_done=%0d hart1_done=%0d",
                  lock_word, counter, hart0_done, hart1_done);
        $finish;
    end
endmodule
