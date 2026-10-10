`timescale 1ns/1ps
// Interrupt service on hart 0 while hart 1 streams through memory (Phase 8 Stage 3, Part 32). The
// program is software/bench/irq2.S - read its header for what each hart does and for the mailbox
// and result layout this testbench fills in and reads back.
//
// Everything that varies between runs is a plusarg, so one compiled simulation per interconnect
// and core covers every row of the matrix (sim/irq2_matrix.py):
//   +mode=N       2 hart 1 streams, 0 it parks (hart 0 always runs; default 2)
//   +irq=N        1 hart 0 takes the timer interrupt, 0 it does not (default 1)
//   +period=N     the timer's period in cycles (default 2000)
//   +window=N     cycles hart 0's window lasts, and hart 1's (default 200000)
//   +base1=HEX    start of hart 1's array (default 0x8002_0000, block RAM; 0x9000_0000 is SDRAM)
//   +nwords=N     hart 1's array length in words, a multiple of 64 (default 1024: 4 KB)
//   +maxcycles=N  give up after this many cycles
// A hart 1 that is not streaming parks, and the checks below insist that it did nothing, so a run
// "alone" really is alone.
//
// What it reports is what the programs measure of themselves: how many passes hart 0's loop made
// and how long they took, how many interrupts it took and two timings of each (lat and done; see
// irq2.S), and how many 64-word blocks hart 1 read. The windows start together, after a barrier,
// so the harts compete for the whole of them.
module tb_soc_2hart_irq;
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

    // The accesses hart 0 completes on the interconnect, counted as acknowledgements at its own ports (so
    // a four-word line fill is four, and the same wires are read whichever interconnect is built), and kept
    // as a running total for every cycle so that the window, which the program only reports at its end, can
    // be cut out afterwards. The window is hart 0's own cycle counter's, which this testbench's counter
    // follows to within a cycle or two.
    localparam ACC_CYCLES = 524288;
    reg [31:0] acc_d [0:ACC_CYCLES-1];
    reg [31:0] acc_f [0:ACC_CYCLES-1];
    reg [31:0] run_d = 0, run_f = 0;
    integer    acc_t = 0;
    always @(posedge clk) if (!rst) begin
        if (DUT.dwb_cyc[0] && DUT.dwb_ack[0]) run_d = run_d + 1;
        if (DUT.iwb_cyc[0] && DUT.iwb_ack[0]) run_f = run_f + 1;
        if (acc_t < ACC_CYCLES) begin acc_d[acc_t] = run_d; acc_f[acc_t] = run_f; end
        acc_t = acc_t + 1;
    end

    // Word indices into DUT.RAM.mem[]: (byte address - 0x8000_0000) / 4. These are the addresses in
    // irq2.S's header.
    localparam P_MODE    = 512;   // 0x8000_0800
    localparam P_IRQ     = 513;
    localparam P_PERIOD  = 514;
    localparam P_WINDOW  = 515;
    localparam P_BASE1   = 516;
    localparam P_NWORDS  = 517;
    localparam P_NACTIVE = 518;
    localparam R_HART0   = 576;   // 0x8000_0900, eight words each
    localparam R_HART1   = 584;   // 0x8000_0920
    localparam IRQ_LOG   = 1024;  // 0x8000_1000, two words (lat, done) an interrupt
    localparam LOG_MAX   = 256;
    // hart 0's block
    localparam H_STATUS = 0, H_PASSES = 1, H_ELAPSED = 2, H_START = 3, H_N = 4, H_BAD = 5, H_ACC = 6, H_WANT = 7;
    // hart 1's block
    localparam S_STATUS = 0, S_BLOCKS = 1, S_CYCLES = 2, S_START = 3, S_FAILBLK = 4, S_GOT = 5, S_WANT = 6;

    reg [31:0] mode, irq, period, window, base1, nwords, maxcycles;

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

    reg [31:0] skew, n, shown, i, lat, dn, bad_samples, expect_n;
    reg        h1_on;

    initial begin
        if (!$value$plusargs("mode=%d", mode))         mode = 2;
        if (!$value$plusargs("irq=%d", irq))           irq = 1;
        if (!$value$plusargs("period=%d", period))     period = 2000;
        if (!$value$plusargs("window=%d", window))     window = 200000;
        if (!$value$plusargs("base1=%h", base1))       base1 = 32'h8002_0000;
        if (!$value$plusargs("nwords=%d", nwords))     nwords = 1024;
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 32'd20_000_000;
        h1_on = mode[1];

        // After time 0, so these are ordered after wb_ram's own zero-fill initial block (Verilog
        // does not order initial blocks).
        #1;
        $readmemh("irq2.hex", DUT.RAM.mem);
        DUT.RAM.mem[P_MODE]    = mode;
        DUT.RAM.mem[P_IRQ]     = irq;
        DUT.RAM.mem[P_PERIOD]  = period;
        DUT.RAM.mem[P_WINDOW]  = window;
        DUT.RAM.mem[P_BASE1]   = base1;
        DUT.RAM.mem[P_NWORDS]  = nwords;
        DUT.RAM.mem[P_NACTIVE] = h1_on ? 32'd2 : 32'd1;

        $display("IRQ2 config mode=%0d irq=%0d period=%0d window=%0d base1=%08h nwords=%0d", mode, irq, period, window, base1, nwords);

        repeat (4) @(posedge clk);
        rst = 0;

        while (!((DUT.RAM.mem[R_HART0 + H_STATUS] != 0) && (!h1_on || DUT.RAM.mem[R_HART1 + S_STATUS] != 0))
               && cycles < maxcycles)
            @(posedge clk);

        n = DUT.RAM.mem[R_HART0 + H_N];
        $display("\n---------------------------------------------");
        $display("IRQ2 total cycles=%0d", cycles);
        $display("IRQ2 hart0 status=%0d passes=%0d elapsed=%0d start=%0d n=%0d bad=%0d",
                 DUT.RAM.mem[R_HART0 + H_STATUS], DUT.RAM.mem[R_HART0 + H_PASSES], DUT.RAM.mem[R_HART0 + H_ELAPSED],
                 DUT.RAM.mem[R_HART0 + H_START], n, DUT.RAM.mem[R_HART0 + H_BAD]);
        $display("IRQ2 hart1 status=%0d blocks=%0d cycles=%0d start=%0d",
                 DUT.RAM.mem[R_HART1 + S_STATUS], DUT.RAM.mem[R_HART1 + S_BLOCKS],
                 DUT.RAM.mem[R_HART1 + S_CYCLES], DUT.RAM.mem[R_HART1 + S_START]);
        if (DUT.RAM.mem[R_HART0 + H_STATUS] == 2)
            $display("  hart 0: checksum %08h, expected %08h", DUT.RAM.mem[R_HART0 + H_ACC], DUT.RAM.mem[R_HART0 + H_WANT]);
        if (DUT.RAM.mem[R_HART1 + S_STATUS] == 2)
            $display("  hart 1: block %0d summed to %0d, expected %0d", DUT.RAM.mem[R_HART1 + S_FAILBLK],
                     DUT.RAM.mem[R_HART1 + S_GOT], DUT.RAM.mem[R_HART1 + S_WANT]);

        // Hart 0's accesses in its window, which are 256 loads a pass and, when it is interrupted, the handler's.
        if (DUT.RAM.mem[R_HART0 + H_START] + DUT.RAM.mem[R_HART0 + H_ELAPSED] < ACC_CYCLES)
            $display("IRQ2 acc0 data=%0d fetch=%0d",
                     acc_d[DUT.RAM.mem[R_HART0 + H_START] + DUT.RAM.mem[R_HART0 + H_ELAPSED]] - acc_d[DUT.RAM.mem[R_HART0 + H_START]],
                     acc_f[DUT.RAM.mem[R_HART0 + H_START] + DUT.RAM.mem[R_HART0 + H_ELAPSED]] - acc_f[DUT.RAM.mem[R_HART0 + H_START]]);

        // The log: the first interrupt of the window is dropped by the matrix (it may have been
        // pending since the barrier); a sample as long as the period would mean the timer wrapped twice.
        shown = (n < LOG_MAX) ? n : LOG_MAX;
        bad_samples = 0;
        for (i = 0; i < shown; i = i + 1) begin
            lat = DUT.RAM.mem[IRQ_LOG + 2 * i];
            dn  = DUT.RAM.mem[IRQ_LOG + 2 * i + 1];
            $display("IRQ2 s %0d %0d", lat, dn);
            if (i != 0 && (lat >= period || dn >= period || dn < lat)) bad_samples = bad_samples + 1;
        end

        // A mistyped plusarg ("+mode=2 +irq=0" in quotes reads as x) would otherwise run a case the table does not say.
        check("mode is 0 or 2", {31'b0, mode === 32'd0 || mode === 32'd2}, 32'b1);
        check("irq is 0 or 1", {31'b0, irq === 32'd0 || irq === 32'd1}, 32'b1);
        check("hart 0 finished with the right checksum", DUT.RAM.mem[R_HART0 + H_STATUS], 32'd1);
        check("hart 0 made at least one pass", {31'b0, DUT.RAM.mem[R_HART0 + H_PASSES] != 0}, 32'b1);
        check("hart 0's window lasted at least as long as asked", {31'b0, DUT.RAM.mem[R_HART0 + H_ELAPSED] >= window}, 32'b1);
        check("the handler claimed only the timer's source", DUT.RAM.mem[R_HART0 + H_BAD], 32'd0);
        if (irq) begin
            // The timer wraps once a period; one more than that can be counted, because the first
            // interrupt of the window may have been raised, and left pending, before the window began.
            expect_n = DUT.RAM.mem[R_HART0 + H_ELAPSED] / period;
            check("every period delivered (elapsed/period, -1 to +2)",
                  {31'b0, n + 1 >= expect_n && n <= expect_n + 2}, 32'b1);
            check("enough interrupts to measure (12 or more) and none past the log", {31'b0, n >= 12 && n < LOG_MAX}, 32'b1);
            check("no logged sample as long as the period", bad_samples, 32'd0);
        end else begin
            check("hart 0 was not interrupted", n, 32'd0);
        end
        if (h1_on) begin
            check("hart 1 finished with every block sum right", DUT.RAM.mem[R_HART1 + S_STATUS], 32'd1);
            check("hart 1 read at least one block", {31'b0, DUT.RAM.mem[R_HART1 + S_BLOCKS] != 0}, 32'b1);
            check("hart 1 streamed for the whole window", {31'b0, DUT.RAM.mem[R_HART1 + S_CYCLES] >= window}, 32'b1);
            skew = (DUT.RAM.mem[R_HART0 + H_START] > DUT.RAM.mem[R_HART1 + S_START]) ?
                   (DUT.RAM.mem[R_HART0 + H_START] - DUT.RAM.mem[R_HART1 + S_START]) :
                   (DUT.RAM.mem[R_HART1 + S_START] - DUT.RAM.mem[R_HART0 + H_START]);
            $display("IRQ2 window start skew=%0d cycles", skew);
            check("the two windows start together (skew under 5% of the window)", {31'b0, (skew * 20) < window}, 32'b1);
        end else begin
            check("hart 1 stayed parked", DUT.RAM.mem[R_HART1 + S_STATUS] | DUT.RAM.mem[R_HART1 + S_BLOCKS], 32'd0);
        end
        // A run that never finished would otherwise show only as a missing status.
        check("the run finished before the cycle limit", {31'b0, cycles < maxcycles}, 32'b1);

        if (failures == 0) $display("\nSOC-2HART-IRQ: PASS");
        else               $display("\nSOC-2HART-IRQ: FAIL (%0d)", failures);
        $display("---------------------------------------------");
        $finish;
    end
endmodule
