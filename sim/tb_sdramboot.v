`timescale 1ns/1ps
// The SoC running a program out of external SDRAM.
//
// sim/tb_sdram.v proves the controller against sim/sdram_model.v at the bus.
// This proves the thing docs/roadmap.md's Phase 2 actually asks for: a CPU
// fetching every instruction from SDRAM, through the instruction cache, over
// the shared interconnect, running a program whose image is larger than the
// entire block RAM it is not using.
//
// Three things are deliberately *not* changed from the other SoC testbenches:
//
//   * **Block RAM is still there, at 0x8000_0000.** The verdict word is
//     written to it, so the pass/fail signal does not depend on the memory
//     under test still working. software/soc/main.c has always reported this
//     way; keeping it means a broken SDRAM shows up as a timeout with the
//     console output that got as far as it got, not as a corrupt magic word
//     that might read "PASS" by luck.
//   * **The clock is 40 ns**, matching soc_top's CLK_HZ default of 25 MHz.
//     That is load-bearing here in a way it is nowhere else: sdram_model.v
//     checks tRCD, tRP, tRFC and the refresh interval in *nanoseconds*, and
//     wb_sdram.v derives its cycle counts from CLK_HZ, so a testbench that
//     ran the clock faster than CLK_HZ claims would violate real timing while
//     the controller believed it was compliant. The model would say so - that
//     is the point of it being in nanoseconds - but it is worth not needing
//     to be told.
//   * **RESET_PC points straight at SDRAM.** No boot ROM, no SD card. The
//     first instruction fetch therefore lands on a controller that is still
//     100 us into its power-up sequence and cannot answer, which exercises
//     the one piece of the handshake nothing else does: a slave that does not
//     ack for two and a half thousand cycles, with the CPU simply waiting.
module tb_sdramboot;
    localparam CLK_PERIOD   = 40;              // 25 MHz, matching CLK_HZ
    localparam CLKS_PER_BIT = 4;               // must match soc_top's UART divisor
    localparam ROW_BITS     = 13;
    localparam COL_BITS     = 9;
    localparam BA_BITS      = 2;

    // 4 MB of modelled storage: the program's LOAD and RUN regions occupy the
    // first megabyte and sdramtest.c's sweep runs from 0x9010_0000 for
    // 256 KB. sdram_model.v errors on an access past this rather than
    // aliasing, so a test that outgrows it fails loudly.
    localparam MEM_WORDS = (1 << 21);

    reg clk = 0;
    reg rst = 1;
    always #(CLK_PERIOD / 2) clk = ~clk;

    wire uart_tx;
    wire spi_sck, spi_mosi, spi_cs_n;
    wire [15:0] gpio_out, gpio_dir;
    wire        trap;
    wire [15:0] gpio_in = (gpio_out & gpio_dir) | (16'hxxxx & ~gpio_dir);
    wire        spi_miso = 1'b1;               // no card; MISO idles high

    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [ROW_BITS-1:0] sd_a;
    wire [BA_BITS-1:0]  sd_ba;
    wire [1:0]  sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;

    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    soc_top #(
        .ROM_WORDS(4096),
        .RAM_BYTES(65536),                     // the board's block RAM, unchanged
        .ROM_INIT_FILE(""),
        .RAM_INIT_FILE(""),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT),
        .GPIO_WIDTH(16),
        .RESET_PC(32'h9000_0000),
        .CLK_HZ(25_000_000),
        .SDRAM_ROW_BITS(ROW_BITS),
        .SDRAM_COL_BITS(COL_BITS),
        .SDRAM_BA_BITS(BA_BITS)
    ) DUT (
        .clk(clk), .rst(rst),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n),
        .vid_r(), .vid_g(), .vid_b(),
        .vid_de(), .vid_hsync(), .vid_vsync(),
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n),
        .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
        .trap(trap)
    );

    // Clocked 180 degrees from the controller, because that is what the board
    // does: fpga/sdram_clk_out.v drives the part's clock from an ODDRX1F so
    // its rising edge lands on the internal clock's falling edge. Clocking
    // the model from `clk` here would simulate a machine no board is, and
    // would be the *aligned* configuration that hardware rejected.
    sdram_model #(
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BA_BITS(BA_BITS),
        .MEM_WORDS(MEM_WORDS)
    ) MEM (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n),
        .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );

    // ---- UART receiver, same shape as the other SoC testbenches ----
    reg [7:0] rx_byte;
    integer   b;
    initial begin
        forever begin
            @(negedge uart_tx);
            #(CLK_PERIOD * CLKS_PER_BIT / 2);
            for (b = 0; b < 8; b = b + 1) begin
                #(CLK_PERIOD * CLKS_PER_BIT);
                rx_byte[b] = uart_tx;
            end
            #(CLK_PERIOD * CLKS_PER_BIT);
            $write("%c", rx_byte);
            $fflush;
        end
    end

    // The verdict lives in block RAM, not in the memory under test.
    wire [31:0] result_word = DUT.RAM.mem[0];
    localparam [31:0] RESULT_PASS = 32'h50415353;  // "PASS"
    localparam [31:0] RESULT_FAIL = 32'h4641494C;  // "FAIL"

    integer cycles = 0;
    always @(posedge clk) cycles = cycles + 1;

    initial begin
        $dumpfile("wave_sdramboot.vcd");
        $dumpvars(0, tb_sdramboot);

        // After time 0, so this lands on top of the model's own initial
        // block rather than under it - Verilog does not order initial blocks,
        // and sim/tb_bench.v learned that the same way.
        #1;
        $readmemh("sdramimage.hex", MEM.mem);

        $display("=== SoC running from external SDRAM ===");

        repeat (4) @(posedge clk);
        rst = 0;

        while (result_word !== RESULT_PASS && result_word !== RESULT_FAIL &&
               cycles < 40_000_000)
            @(posedge clk);

        repeat (200 * CLKS_PER_BIT * 10) @(posedge clk);

        $display("\n---------------------------------------------");
        $display("cycles: %0d", cycles);
        $display("SDRAM refreshes issued: %0d", MEM.refresh_count);
        $display("result word (expect \"PASS\"): 0x%08x", result_word);
        if (result_word === RESULT_PASS) $display("SDRAMBOOT TEST PASSED");
        else if (result_word === RESULT_FAIL) $display("SDRAMBOOT TEST FAILED");
        else $display("SDRAMBOOT TEST FAILED (timed out after %0d cycles)", cycles);
        $display("---------------------------------------------");
        $finish;
    end
endmodule
