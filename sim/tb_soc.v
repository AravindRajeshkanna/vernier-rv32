`timescale 1ns/1ps
// Testbench for the full SoC (rtl/soc/soc_top.v): CPU on a Wishbone bus with
// boot ROM, RAM, CLINT, PLIC, UART, GPIO and SPI, plus a simulated SD card.
//
// This runs the real boot flow end to end. Nothing is preloaded into RAM -
// the boot ROM is the only thing baked into the design. It brings up SPI,
// initializes the card, reads the image header, pulls the program in block by
// block, and jumps to it; the program then runs its own acceptance tests and
// reports over the UART. So the console output below is not a canned string,
// it is the actual byte stream coming off rtl/uart.v's TX pin, decoded back
// into characters by the receiver state machine in this file.
//
// Pass/fail is taken from a magic word the program writes to a fixed RAM
// address (software/soc/soc.h's TEST_RESULT_ADDR), so the result is machine-
// checkable rather than something a human has to read.
//
// GPIO is looped back here - the low 8 pins drive the high 8 - which is what
// the program's GPIO test checks.
module tb_soc;
    localparam CLKS_PER_BIT = 4;   // must match soc_top's UART_CLKS_PER_BIT

    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire spi_sck, spi_mosi, spi_miso, spi_cs_n;
    wire [15:0] gpio_out, gpio_dir;
    wire        trap;

    // ---- GPIO pads ----
    // This used to be a loopback - `{gpio_out[7:0] & gpio_dir[7:0], 8'b0}` -
    // which fed the SoC's own output register back into its input port and
    // called pins 8-15 a copy of pins 0-7. No such wire exists on a board:
    // gpio[15:8] is {gn[1:0], gp[13:8]}, bare header pins. The GPIO test
    // built on it passed here for as long as it existed and failed the first
    // time it met real hardware.
    //
    // What it models now is a pad. A pin the SoC is driving reads back the
    // value it drives, which is what an IOBUF's input path does. A pin it is
    // *not* driving reads X, not 0, because fpga/constraints/ulx3s.lpf sets
    // PULLMODE=NONE on the whole header: an undriven pin there has no defined
    // level, and the honest model of an unknown value is X. Anything that
    // depends on one now fails in simulation rather than on a board.
    wire [15:0] gpio_in = (gpio_out & gpio_dir) | (16'hxxxx & ~gpio_dir);

    soc_top #(
        .ROM_INIT_FILE("bootrom.hex"),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT)
    ) DUT (
        .clk(clk), .rst(rst),
        // No debug host in this testbench. TCK parked low means the TAP's
        // state machine never advances and the Debug Module stays in reset,
        // which is exactly what a board with no debug cable does.
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        // No SDRAM in this simulation: the controller inside soc_top still
        // initialises and refreshes an imaginary part, which costs nothing and
        // keeps one SoC rather than two. Nothing here decodes to 0x90.
        .sdram_dq_i(16'b0),
        .trap(trap)
    );

    sd_card_model #(
        .CARD_BYTES(65536),
        .INIT_FILE("card.hex")
    ) SDCARD (
        .sck(spi_sck), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n)
    );

    // Clock period in ns. This is not arbitrary any more: sd_card_model.v
    // checks the SD initialization clock against a real-time ceiling, and the
    // divider producing that clock is computed by software from CPU_HZ in
    // software/soc/soc.h. The two have to describe the same clock or the check
    // is measuring a fiction, so this is CPU_HZ's period - 25 MHz, 40 ns.
    localparam CLK_PERIOD = 40;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ---- UART receiver: decode the TX line back into characters ----
    // Mirrors rtl/uart.v's transmitter - wait for the start bit, then sample
    // in the middle of each of the 8 data bits.
    integer i;
    reg [7:0] rx_byte;
    initial begin
        forever begin
            @(negedge uart_tx);                          // start bit
            #(CLK_PERIOD * CLKS_PER_BIT / 2);            // align to mid-bit
            for (i = 0; i < 8; i = i + 1) begin
                #(CLK_PERIOD * CLKS_PER_BIT);
                rx_byte[i] = uart_tx;
            end
            #(CLK_PERIOD * CLKS_PER_BIT);                // stop bit
            $write("%c", rx_byte);
            $fflush;
        end
    end

    // ---- result ----
    // Word 0 of RAM is TEST_RESULT_ADDR (0x8000_0000). wb_ram is a 32-bit
    // word array, so this is one entry rather than four bytes reassembled.
    wire [31:0] result_word = DUT.RAM.mem[0];
    localparam [31:0] RESULT_PASS = 32'h50415353;  // "PASS"
    localparam [31:0] RESULT_FAIL = 32'h4641494C;  // "FAIL"

    initial begin
    // Waveforms are opt-in: run with `+dump`, or `make <target> DUMP=1`.
    //
    // This used to be unconditional, and the cost scales with how long the
    // run is - which for the SoC-level tests is millions of cycles over a
    // whole SoC. `make sim_sdramboot` alone wrote a **6.2 GB** VCD, and
    // `make sim_uartload` an **18 GB** one, so a single `make verify` filled
    // a 228 GB disk to 100% and took the machine down with it. Nobody looks
    // at these files unless they are debugging, and when they are, one
    // plusarg is not a hardship.
        if ($test$plusargs("dump")) begin
            $dumpfile("wave_soc.vcd");
            $dumpvars(0, tb_soc);
        end
        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;

        // Wait for the program to publish a result rather than guessing a
        // fixed cycle budget - the boot path's length depends on the image
        // size, which changes whenever the firmware does.
        while (result_word !== RESULT_PASS && result_word !== RESULT_FAIL)
            @(posedge clk);

        // Let the last console output drain before printing the verdict.
        repeat (200 * CLKS_PER_BIT * 10) @(posedge clk);

        $display("\n---------------------------------------------");
        $display("result word (expect \"PASS\"): 0x%08x", result_word);
        if (result_word === RESULT_PASS) $display("SOC TEST PASSED");
        else                              $display("SOC TEST FAILED");
        $display("---------------------------------------------");
        $finish;
    end

    // Safety timeout. Generous: the boot path shifts the whole program image
    // in over SPI one bit at a time, which is genuinely slow in simulation -
    // and more so now that initialization runs at the ~350 kHz the SD spec
    // requires rather than at the divider's maximum.
    initial begin
        #400_000_000;
        $display("\n---------------------------------------------");
        $display("TIMEOUT - no result word was written");
        $display("last result word: 0x%08x", result_word);
        $display("SOC TEST FAILED");
        $display("---------------------------------------------");
        $finish;
    end
endmodule
