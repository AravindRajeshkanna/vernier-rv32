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

    // GPIO loopback: pins 8-15 (inputs) see whatever pins 0-7 (outputs)
    // drive. `gpio_dir` is respected so an undriven pin reads 0 rather than
    // whatever the output register happens to hold.
    wire [15:0] gpio_in = {gpio_out[7:0] & gpio_dir[7:0], 8'b0};

    soc_top #(
        .ROM_INIT_FILE("bootrom.hex"),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT)
    ) DUT (
        .clk(clk), .rst(rst),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .trap(trap)
    );

    sd_card_model #(
        .CARD_BYTES(65536),
        .INIT_FILE("card.hex")
    ) SDCARD (
        .sck(spi_sck), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n)
    );

    always #5 clk = ~clk;   // 100 MHz virtual clock

    // ---- UART receiver: decode the TX line back into characters ----
    // Mirrors rtl/uart.v's transmitter - wait for the start bit, then sample
    // in the middle of each of the 8 data bits.
    integer i;
    reg [7:0] rx_byte;
    initial begin
        forever begin
            @(negedge uart_tx);                       // start bit
            #(5 * CLKS_PER_BIT * 10 / 10);            // align to mid-bit
            for (i = 0; i < 8; i = i + 1) begin
                #(10 * CLKS_PER_BIT);
                rx_byte[i] = uart_tx;
            end
            #(10 * CLKS_PER_BIT);                     // stop bit
            $write("%c", rx_byte);
            $fflush;
        end
    end

    // ---- result ----
    // Byte 0..3 of RAM is TEST_RESULT_ADDR (0x8000_0000).
    wire [31:0] result_word = {DUT.RAM.mem[3], DUT.RAM.mem[2],
                                DUT.RAM.mem[1], DUT.RAM.mem[0]};
    localparam [31:0] RESULT_PASS = 32'h50415353;  // "PASS"
    localparam [31:0] RESULT_FAIL = 32'h4641494C;  // "FAIL"

    initial begin
        $dumpfile("wave_soc.vcd");
        $dumpvars(0, tb_soc);

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
    // in over SPI one bit at a time, which is genuinely slow in simulation.
    initial begin
        #80_000_000;
        $display("\n---------------------------------------------");
        $display("TIMEOUT - no result word was written");
        $display("last result word: 0x%08x", result_word);
        $display("SOC TEST FAILED");
        $display("---------------------------------------------");
        $finish;
    end
endmodule
