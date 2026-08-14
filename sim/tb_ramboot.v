`timescale 1ns/1ps
// Testbench for the *preloaded-RAM* boot path, at the board's real memory size.
//
// sim/tb_soc.v boots the SoC the way a finished product would: off the SD card
// model, with 256 KB of RAM. `BOARD=ulx3s85-ram` builds a board that does
// neither. The program is baked into the bitstream (fpga/soc_fpga.v's
// PRELOAD_RAM -> wb_ram's RAM_INIT_FILE), the boot ROM notices RAM already
// holds a program and skips the card entirely, and the RAM is 64 KB because
// 256 KB costs 244 ECP5 block RAMs and does not fit any ECP5 there is.
//
// Both of those differences are load-bearing, and neither was simulated:
//
//   * **64 KB, not 256 KB.** wb_interconnect.v decodes on addr[31:24] alone,
//     so the whole 16 MB window reaches wb_ram, which indexes with only the
//     address bits its size needs. Running off the end therefore *aliases*
//     back to the start rather than faulting. With 256 KB in simulation the
//     wrap point sits at 0x8004_0000, four times higher than on the board, so
//     a stack or heap that overruns is invisible here and silently corrupts
//     low RAM there. This testbench puts the wrap point where the board has
//     it.
//
//   * **The preload path itself.** Nothing exercised RAM_INIT_FILE or the boot
//     ROM's "RAM already holds a program" branch, so the code that every
//     bring-up bitstream depends on was only ever tested on hardware.
//
// The image is chosen at compile time, so one testbench serves both programs:
//
//   make sim_ramboot   -> the acceptance test   (sim/ramimage.hex)
//   make sim_probe     -> the newlib probe      (sim/probeimage.hex)
//
// Verdict comes from the same magic word tb_soc.v uses, so a run is
// machine-checkable rather than something a human has to read - and an
// unexpected trap now writes FAIL there itself (software/soc/trap.c) instead
// of leaving the run to time out with nothing to show.
`ifndef RAM_IMAGE
`define RAM_IMAGE "ramimage.hex"
`endif

module tb_ramboot;
    localparam CLKS_PER_BIT = 4;   // must match soc_top's UART_CLKS_PER_BIT

    // fpga/soc_fpga.v's RAM_BYTES. This is the number that makes the run
    // faithful; raising it to tb_soc.v's 256 KB would hide exactly the class
    // of bug this testbench exists to expose.
    localparam RAM_BYTES = 65536;

    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire spi_sck, spi_mosi, spi_miso, spi_cs_n;
    wire [15:0] gpio_out, gpio_dir;
    wire        trap;

    // Same pad model as tb_soc.v: a pin the SoC drives reads back what it
    // drives, and an undriven one reads X because ulx3s.lpf sets PULLMODE=NONE
    // on the whole header.
    wire [15:0] gpio_in = (gpio_out & gpio_dir) | (16'hxxxx & ~gpio_dir);

    // No SD card: MISO idles high through its pull-up, exactly as it does on a
    // board with an empty slot. If the boot ROM ever fell through to the card
    // path, it would fail there rather than appearing to work.
    assign spi_miso = 1'b1;

    soc_top #(
        .RAM_BYTES(RAM_BYTES),
        .ROM_INIT_FILE("bootrom.hex"),
        .RAM_INIT_FILE(`RAM_IMAGE),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT)
    ) DUT (
        .clk(clk), .rst(rst),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .trap(trap)
    );

    // 25 MHz, matching CPU_HZ in software/soc/soc.h and CLK_HZ in soc_fpga.v.
    localparam CLK_PERIOD = 40;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ---- UART receiver: decode the TX line back into characters ----
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

    wire [31:0] result_word = DUT.RAM.mem[0];
    localparam [31:0] RESULT_PASS = 32'h50415353;  // "PASS"
    localparam [31:0] RESULT_FAIL = 32'h4641494C;  // "FAIL"

    initial begin
        $dumpfile("wave_ramboot.vcd");
        $dumpvars(0, tb_ramboot);

        $display("=== preloaded-RAM boot: %s into %0d KB ===",
                 `RAM_IMAGE, RAM_BYTES / 1024);

        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;

        while (result_word !== RESULT_PASS && result_word !== RESULT_FAIL)
            @(posedge clk);

        // Let the last console output drain before printing the verdict.
        repeat (200 * CLKS_PER_BIT * 10) @(posedge clk);

        $display("\n---------------------------------------------");
        $display("run 1 result word (expect \"PASS\"): 0x%08x", result_word);
        if (result_word === RESULT_PASS) $display("RAMBOOT TEST PASSED");
        else                              $display("RAMBOOT TEST FAILED");
        $display("---------------------------------------------");

`ifdef RERUN
        // ---- press the reset button ----
        //
        // A board does this constantly: flash the bitstream, open a terminal,
        // tap reset to see the banner from the top. It is not the same as a
        // fresh start. Block RAM is initialised at *configuration* time, so a
        // CPU reset re-runs the program over memory the previous run already
        // wrote - and while _start zeroes .bss, nothing restores .data.
        //
        // That is invisible on the SD path, where the loader copies the whole
        // image (.data included) on every boot, and it is why this only ever
        // showed up on a preloaded bitstream.
        //
        // Modelled exactly: the result word is cleared so the second run has
        // something to publish, and *nothing else about RAM is touched*.
        $display("\n=== reset, without reloading RAM - as the button does ===");
        DUT.RAM.mem[0] = 32'h0;
        @(posedge clk);

        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;

        while (result_word !== RESULT_PASS && result_word !== RESULT_FAIL)
            @(posedge clk);
        repeat (200 * CLKS_PER_BIT * 10) @(posedge clk);

        $display("\n---------------------------------------------");
        $display("run 2 result word (expect \"PASS\"): 0x%08x", result_word);
        if (result_word === RESULT_PASS)
            $display("RERUN TEST PASSED - the program survives a reset");
        else
            $display("RERUN TEST FAILED - the program only works once per configuration");
        $display("---------------------------------------------");
`endif
        $finish;
    end

    // Same budget as tb_soc.v even though there is no SPI transfer to wait
    // for. Dropping the card saves a few milliseconds; what actually sets the
    // scale is the acceptance test's framebuffer ramp, which is 76800 pixels
    // and two divisions each on a multi-cycle divider. Measured runs: the
    // newlib probe finishes in ~4 ms of simulated time and the trap checks in
    // ~1.6 ms, but the acceptance test needs well over 40 ms.
    initial begin
        #400_000_000;
        $display("\n---------------------------------------------");
        $display("TIMEOUT - no result word was written");
        $display("last result word: 0x%08x", result_word);
        $display("RAMBOOT TEST FAILED");
        $display("---------------------------------------------");
        $finish;
    end
endmodule
