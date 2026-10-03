`timescale 1ns/1ps
// Data-cache coherence between two harts (Phase 8, the first lever Stage 0
// named). Each hart's data cache is write-through, and nothing before this
// kept one hart's cached copy right when the other hart wrote the same word,
// which is why rtl/soc/soc_top.v turned the cache off whenever NUM_HARTS > 1.
//
// sim/gen_soc2hart_coh.py's program makes six words cross between the
// harts, each already resident in the reader's cache, three each way: a start
// flag, a data word and a done flag one way, then a data word and a go flag
// the other. With a stale cache the run hangs (a poll never sees the
// other hart's write) or reads the old value, so this fails whenever a hart's
// cache keeps serving a line the other hart has overwritten.
module tb_soc_2hart_coherence;
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
        .RAM_BYTES(1024),
        .RAM_INIT_FILE("soc2hart_coh.hex")
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .pwm_out(pwm_out),
        // No SDRAM traffic in this test - both sentinels land in block RAM
        // at 0x8000_0000, well below the SDRAM window at 0x9000_0000.
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

    // RAM words: X = 0x8000_0200 is word 128, then flag, done, result, Z,
    // go2, result2.
    initial begin
        repeat (4) @(posedge clk);
        rst = 0;

        // The program is a few dozen instructions; this is far more than a
        // coherent pair needs, and a stale pair never finishes at all.
        repeat (6000) @(posedge clk);

        check("hart 1 saw hart 0's flag and wrote X", DUT.RAM.mem[128], 32'h22222000);
        check("hart 0 saw hart 1's done flag",        DUT.RAM.mem[130], 32'h00000001);
        check("hart 0 re-read X and got the new value", DUT.RAM.mem[131], 32'h22222000);
        check("hart 1 saw hart 0's go flag", DUT.RAM.mem[133], 32'h00000001);
        check("hart 1 re-read Z and got the new value", DUT.RAM.mem[134], 32'h33333000);
        check("neither hart trapped", {31'b0, trap}, 32'b0);

        if (failures == 0) $display("\nSOC-2HART-COHERENCE-TEST: PASS");
        else               $display("\nSOC-2HART-COHERENCE-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("\nSOC-2HART-COHERENCE-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
