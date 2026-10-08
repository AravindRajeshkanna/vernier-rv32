`timescale 1ns/1ps
// Two harts streaming through arrays far bigger than their data caches, so the interconnect is
// the bottleneck (Phase 8 Stage 3, Part 27). The program is software/bench/stream2.S - read its
// header for what a hart does and for the mailbox layout this testbench fills in and reads back.
//
// Everything that varies between runs is a plusarg, so one compiled simulation per interconnect
// covers every row of the matrix (sim/stream2_matrix.py):
//   +mode=N       which harts stream: 1 hart 0 alone, 2 hart 1 alone, 3 both (default 3)
//   +base0=HEX    start of hart 0's array (default 0x8001_0000, block RAM)
//   +base1=HEX    start of hart 1's array (default 0x8002_0000, block RAM; 0x9000_0000 and up is SDRAM)
//   +window=N     cycles each hart streams for (default 200000)
//   +nwords=N     array length in words, a multiple of 64 (default 1024: 4 KB, 4x the data cache)
//   +maxcycles=N  give up after this many cycles
// A hart that is not streaming parks, and the checks below insist that it did nothing, so a run
// "alone" really is alone.
//
// What it reports is what the programs measure of themselves: how many 64-word blocks each hart
// read in its window, and how long that window really was. The windows start together, after a
// barrier, so the harts compete for the whole of them (the start skew is checked).
module tb_soc_2hart_stream;
    localparam CLKS_PER_BIT = 4;

    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire [15:0] gpio_out, gpio_dir;
    wire spi_sck, spi_mosi, spi_cs_n;
    wire trap;

    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [12:0] sd_a;
    wire [1:0]  sd_ba, sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;
    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    soc_top #(
        .NUM_HARTS(2),
        .RESET_PC(32'h8000_0000),
        .RAM_BYTES(524288),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT)
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(16'b0), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(1'b1), .spi_cs_n(spi_cs_n),
        .pwm_out(),
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n),
        .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
        .trap(trap)
    );

    // The SDRAM model, clocked from the opposite edge as on the board (see sim/tb_ramboot.v).
    sdram_model #(.MEM_WORDS(1 << 20)) SDRAMCHIP (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );

    // 25 MHz, which the SDRAM controller's timing (and the model's checks) assume.
    localparam CLK_PERIOD = 40;
    always #(CLK_PERIOD / 2) clk = ~clk;

    integer cycles = 0;
    always @(posedge clk) if (!rst) cycles = cycles + 1;

    // Word indices into DUT.RAM.mem[]: (byte address - 0x8000_0000) / 4. These are the mailbox
    // addresses in stream2.S's header.
    localparam P_MODE    = 128;   // 0x8000_0200
    localparam P_BASE0   = 129;
    localparam P_BASE1   = 130;
    localparam P_WINDOW  = 131;
    localparam P_NWORDS  = 132;
    localparam P_NACTIVE = 133;
    localparam R_HART0   = 192;   // 0x8000_0300, eight words per hart
    localparam R_HART1   = 200;
    localparam R_STATUS = 0, R_BLOCKS = 1, R_CYCLES = 2, R_START = 3, R_FAILBLK = 4, R_GOT = 5, R_WANT = 6;

    reg [31:0] mode, base0, base1, window, nwords, maxcycles;

    // A hart that is not streaming counts as done from the start.
    function done_h(input integer r, input act);
        begin
            done_h = !act || (DUT.RAM.mem[r + R_STATUS] != 0);
        end
    endfunction

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

    task report(input integer h, input integer r);
        begin
            $display("STREAM2 hart %0d status=%0d blocks=%0d cycles=%0d start=%0d",
                     h, DUT.RAM.mem[r + R_STATUS], DUT.RAM.mem[r + R_BLOCKS],
                     DUT.RAM.mem[r + R_CYCLES], DUT.RAM.mem[r + R_START]);
            if (DUT.RAM.mem[r + R_STATUS] == 2)
                $display("  hart %0d: block %0d summed to %0d, expected %0d", h,
                         DUT.RAM.mem[r + R_FAILBLK], DUT.RAM.mem[r + R_GOT], DUT.RAM.mem[r + R_WANT]);
        end
    endtask

    task check_hart(input integer h, input integer r, input active);
        begin
            if (active) begin
                check(h == 0 ? "hart 0 finished with every block sum right" :
                               "hart 1 finished with every block sum right",
                      DUT.RAM.mem[r + R_STATUS], 32'd1);
                check(h == 0 ? "hart 0 read at least one block" : "hart 1 read at least one block",
                      {31'b0, DUT.RAM.mem[r + R_BLOCKS] != 0}, 32'b1);
                check(h == 0 ? "hart 0 streamed for the whole window" : "hart 1 streamed for the whole window",
                      {31'b0, DUT.RAM.mem[r + R_CYCLES] >= window}, 32'b1);
            end else begin
                check(h == 0 ? "hart 0 stayed parked" : "hart 1 stayed parked",
                      DUT.RAM.mem[r + R_STATUS] | DUT.RAM.mem[r + R_BLOCKS], 32'd0);
            end
        end
    endtask

    reg [31:0] skew;

    initial begin
        if (!$value$plusargs("mode=%d", mode))         mode = 3;
        if (!$value$plusargs("base0=%h", base0))       base0 = 32'h8001_0000;
        if (!$value$plusargs("base1=%h", base1))       base1 = 32'h8002_0000;
        if (!$value$plusargs("window=%d", window))     window = 200000;
        if (!$value$plusargs("nwords=%d", nwords))     nwords = 1024;
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 32'd20_000_000;

        // After time 0, so these are ordered after wb_ram's own zero-fill initial block (Verilog
        // does not order initial blocks).
        #1;
        $readmemh("stream2.hex", DUT.RAM.mem);
        DUT.RAM.mem[P_MODE]    = mode;
        DUT.RAM.mem[P_BASE0]   = base0;
        DUT.RAM.mem[P_BASE1]   = base1;
        DUT.RAM.mem[P_WINDOW]  = window;
        DUT.RAM.mem[P_NWORDS]  = nwords;
        DUT.RAM.mem[P_NACTIVE] = {31'b0, mode[0]} + {31'b0, mode[1]};

        $display("STREAM2 config mode=%0d base0=%08h base1=%08h window=%0d nwords=%0d", mode, base0, base1, window, nwords);

        repeat (4) @(posedge clk);
        rst = 0;

        while (!(done_h(R_HART0, mode[0]) && done_h(R_HART1, mode[1])) && cycles < maxcycles)
            @(posedge clk);

        $display("\n---------------------------------------------");
        $display("STREAM2 total cycles=%0d", cycles);
        report(0, R_HART0);
        report(1, R_HART1);

        // A run in which nothing was asked to stream would otherwise pass: both harts "stayed parked".
        check("at least one hart was asked to stream (mode 1, 2 or 3)", {31'b0, mode >= 1 && mode <= 3}, 32'b1);
        check("neither hart trapped", {31'b0, trap}, 32'b0);
        check_hart(0, R_HART0, mode[0]);
        check_hart(1, R_HART1, mode[1]);
        if (mode[0] && mode[1]) begin
            skew = (DUT.RAM.mem[R_HART0 + R_START] > DUT.RAM.mem[R_HART1 + R_START]) ?
                   (DUT.RAM.mem[R_HART0 + R_START] - DUT.RAM.mem[R_HART1 + R_START]) :
                   (DUT.RAM.mem[R_HART1 + R_START] - DUT.RAM.mem[R_HART0 + R_START]);
            $display("STREAM2 window start skew=%0d cycles", skew);
            check("the two windows start together (skew under 5% of the window)",
                  {31'b0, (skew * 20) < window}, 32'b1);
        end

        if (failures == 0) $display("\nSOC-2HART-STREAM: PASS");
        else               $display("\nSOC-2HART-STREAM: FAIL (%0d)", failures);
        $display("---------------------------------------------");
        $finish;
    end
endmodule
