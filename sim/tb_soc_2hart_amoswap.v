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
// rtl/soc/wb_interconnect.v's own AMO-atomicity fix (docs/roadmap/phase-13-multicore.md's
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

`ifndef AMO_HEX
`define AMO_HEX "soc2hart_amoswap.hex"
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

`ifdef SDRAM_DATA
    // The shared data lives in the SDRAM window (the program's base register
    // is 0x9000_0000, see the Makefile's `_sdram.hex` rules), so the data
    // cache covers it; code still runs from block RAM. The model's array
    // starts as X, and a poll on an X word would prove nothing, so the words
    // the program uses are zeroed.
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [12:0] sd_a;
    wire [1:0]  sd_ba, sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;
    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    sdram_model #(.MEM_WORDS(1 << 20)) SDRAMCHIP (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );
    integer k;
    initial for (k = 0; k < 4096; k = k + 1) SDRAMCHIP.mem[k] = 16'h0000;
`endif

    // The 32-bit word at byte offset 4*idx from the data base, wherever the
    // data lives. In SDRAM a word is two halfwords, low first (wb_sdram.v's
    // burst of 2), and for offsets under 1 KB the model's flat index is
    // simply offset/2.
    function [31:0] wordat(input integer idx);
`ifdef SDRAM_DATA
        wordat = {SDRAMCHIP.mem[2*idx+1], SDRAMCHIP.mem[2*idx]};
`else
        wordat = DUT.RAM.mem[idx];
`endif
    endfunction

    soc_top #(
        .NUM_HARTS(2),
        .RESET_PC(32'h8000_0000),
        .RAM_BYTES(2048),
        .RAM_INIT_FILE(`AMO_HEX)
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .pwm_out(pwm_out),
`ifdef SDRAM_DATA
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n),
        .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
`else
        .sdram_dq_i(16'b0),
`endif
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
    // Sampled each clock through wordat(), since the words may live in the
    // SDRAM model and a continuous assign would not see an array element change.
    reg [31:0] lock_word, counter, hart0_done, hart1_done;
    always @(posedge clk) begin
        lock_word  <= wordat(128);  // base + 0x200
        counter    <= wordat(129);  // base + 0x204
        hart0_done <= wordat(130);  // base + 0x208
        hart1_done <= wordat(131);  // base + 0x20C
    end

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
