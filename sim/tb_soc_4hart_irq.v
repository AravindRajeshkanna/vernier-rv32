`timescale 1ns/1ps
// Interrupt service on one of four harts while the other three stream through memory (Phase 8 Stage 3,
// Part 36). The program is software/bench/irq4.S - read its header for what each hart does and for the
// mailbox and result layout this testbench fills in and reads back. Part 32's test
// (sim/tb_soc_2hart_irq.v) with two more harts, and with the interrupted hart chosen by a plusarg.
//
// Everything that varies between runs is a plusarg, so one compiled simulation per interconnect
// and core covers every row of the matrix (sim/irq4_matrix.py):
//   +measured=N   which hart runs the loop and takes the interrupt, 0 to 3 (default 0)
//   +mode=N       which harts stream, bit h for hart h; the measured hart's bit is ignored (default 14)
//   +irq=N        1 the measured hart takes the timer interrupt, 0 it does not (default 1)
//   +period=N     the timer's period in cycles (default 30000)
//   +window=N     cycles the measured hart's window lasts (default 400000); the streamers stream until it is done
//   +start=N      the cycle count at which the windows open (default 150000)
//   +nwords=N     each streamer's array length in words, a multiple of 64 (default 1024: 4 KB)
//   +base0=HEX .. +base3=HEX  start of hart h's array (default 0x8002_0000 + 0x1_0000 * h, block RAM;
//                 0x9000_0000 is SDRAM)
//   +maxcycles=N  give up after this many cycles
// A streamer that is not asked to stream parks, and the checks below insist that it did nothing, so a run
// "alone" really is alone.
//
// What it reports is what the programs measure of themselves: how many passes the measured hart's loop made
// and how long they took, how many interrupts it took and two timings of each (lat and done; see irq4.S),
// and how many 64-word blocks each streamer read. The windows open at one cycle count agreed in advance, so
// the harts compete for the whole of them.
module tb_soc_4hart_irq;
    localparam CLKS_PER_BIT = 4;
    localparam MAXH = 4;

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
        .NUM_HARTS(MAXH),
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

    reg [31:0] mode, irq, period, window, start, nwords, measured, maxcycles;
    reg [31:0] base0, base1, base2, base3;
    reg [31:0] base [0:MAXH-1];

    // The accesses the measured hart completes on the interconnect, counted as acknowledgements at its own
    // ports (so a four-word line fill is four, and the same wires are read whichever interconnect is built),
    // and kept as a running total for every cycle so that the window, which the program only reports at its
    // end, can be cut out afterwards. The window is the hart's own cycle counter's, which this testbench's
    // counter follows to within a cycle or two.
    localparam ACC_CYCLES = 786432;
    reg [31:0] acc_d [0:ACC_CYCLES-1];
    reg [31:0] acc_f [0:ACC_CYCLES-1];
    reg [31:0] run_d = 0, run_f = 0;
    integer    acc_t = 0;
    always @(posedge clk) if (!rst) begin
        if (DUT.dwb_cyc[measured[1:0]] && DUT.dwb_ack[measured[1:0]]) run_d = run_d + 1;
        if (DUT.iwb_cyc[measured[1:0]] && DUT.iwb_ack[measured[1:0]]) run_f = run_f + 1;
        if (acc_t < ACC_CYCLES) begin acc_d[acc_t] = run_d; acc_f[acc_t] = run_f; end
        acc_t = acc_t + 1;
    end

    // Word indices into DUT.RAM.mem[]: (byte address - 0x8000_0000) / 4. These are the addresses in
    // irq4.S's header.
    localparam P_MODE    = 512;   // 0x8000_0800
    localparam P_IRQ     = 513;
    localparam P_PERIOD  = 514;
    localparam P_WINDOW  = 515;
    localparam P_NWORDS  = 516;
    localparam P_START   = 517;
    localparam P_MEAS    = 518;
    localparam P_BASE0   = 519;   // four words, one a hart
    localparam R_MEAS    = 576;   // 0x8000_0900, eight words
    localparam R_STREAM0 = 640;   // 0x8000_0A00, eight words a hart
    localparam IRQ_LOG   = 1024;  // 0x8000_1000, two words (lat, done) an interrupt
    localparam LOG_MAX   = 256;
    // the measured hart's block
    localparam H_STATUS = 0, H_PASSES = 1, H_ELAPSED = 2, H_START = 3, H_N = 4, H_BAD = 5, H_ACC = 6, H_WANT = 7;
    // a streamer's block
    localparam S_STATUS = 0, S_BLOCKS = 1, S_CYCLES = 2, S_START = 3, S_FAILBLK = 4, S_GOT = 5, S_WANT = 6;

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

    function done_h(input integer h);
        begin
            if (h == measured) done_h = (DUT.RAM.mem[R_MEAS + H_STATUS] != 0);
            else               done_h = !mode[h] || (DUT.RAM.mem[R_STREAM0 + 8 * h + S_STATUS] != 0);
        end
    endfunction

    integer h;
    reg all_done;
    reg [31:0] n, shown, i, lat, dn, bad_samples, expect_n, smin, smax, hend, send, hstart;
    reg        any_streamer;

    initial begin
        if (!$value$plusargs("measured=%d", measured)) measured = 0;
        if (!$value$plusargs("mode=%d", mode))         mode = 14;
        if (!$value$plusargs("irq=%d", irq))           irq = 1;
        if (!$value$plusargs("period=%d", period))     period = 30000;
        if (!$value$plusargs("window=%d", window))     window = 400000;
        if (!$value$plusargs("start=%d", start))       start = 150000;
        if (!$value$plusargs("nwords=%d", nwords))     nwords = 1024;
        if (!$value$plusargs("base0=%h", base0))       base0 = 32'h8002_0000;
        if (!$value$plusargs("base1=%h", base1))       base1 = 32'h8003_0000;
        if (!$value$plusargs("base2=%h", base2))       base2 = 32'h8004_0000;
        if (!$value$plusargs("base3=%h", base3))       base3 = 32'h8005_0000;
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 32'd20_000_000;
        base[0] = base0; base[1] = base1; base[2] = base2; base[3] = base3;
        // the measured hart's own bit means nothing; leave it out so that every check below reads the real set
        if (measured < MAXH) mode[measured[1:0]] = 1'b0;

        // After time 0, so these are ordered after wb_ram's own zero-fill initial block (Verilog
        // does not order initial blocks).
        #1;
        $readmemh("irq4.hex", DUT.RAM.mem);
        DUT.RAM.mem[P_MODE]    = mode;
        DUT.RAM.mem[P_IRQ]     = irq;
        DUT.RAM.mem[P_PERIOD]  = period;
        DUT.RAM.mem[P_WINDOW]  = window;
        DUT.RAM.mem[P_NWORDS]  = nwords;
        DUT.RAM.mem[P_START]   = start;
        DUT.RAM.mem[P_MEAS]    = measured;
        for (h = 0; h < MAXH; h = h + 1) DUT.RAM.mem[P_BASE0 + h] = base[h];

        $display("IRQ4 config measured=%0d mode=%0d irq=%0d period=%0d window=%0d start=%0d nwords=%0d bases=%08h,%08h,%08h,%08h",
                 measured, mode, irq, period, window, start, nwords, base[0], base[1], base[2], base[3]);

        repeat (4) @(posedge clk);
        rst = 0;

        all_done = 0;
        while (!all_done && cycles < maxcycles) begin
            @(posedge clk);
            all_done = 1;
            for (h = 0; h < MAXH; h = h + 1) if (!done_h(h)) all_done = 0;
        end

        n = DUT.RAM.mem[R_MEAS + H_N];
        $display("\n---------------------------------------------");
        $display("IRQ4 total cycles=%0d", cycles);
        $display("IRQ4 measured hart %0d status=%0d passes=%0d elapsed=%0d start=%0d n=%0d bad=%0d", measured,
                 DUT.RAM.mem[R_MEAS + H_STATUS], DUT.RAM.mem[R_MEAS + H_PASSES], DUT.RAM.mem[R_MEAS + H_ELAPSED],
                 DUT.RAM.mem[R_MEAS + H_START], n, DUT.RAM.mem[R_MEAS + H_BAD]);
        for (h = 0; h < MAXH; h = h + 1)
            if (h != measured)
                $display("IRQ4 stream hart %0d status=%0d blocks=%0d cycles=%0d start=%0d", h,
                         DUT.RAM.mem[R_STREAM0 + 8 * h + S_STATUS], DUT.RAM.mem[R_STREAM0 + 8 * h + S_BLOCKS],
                         DUT.RAM.mem[R_STREAM0 + 8 * h + S_CYCLES], DUT.RAM.mem[R_STREAM0 + 8 * h + S_START]);
        if (DUT.RAM.mem[R_MEAS + H_STATUS] == 2)
            $display("  measured hart: checksum %08h, expected %08h", DUT.RAM.mem[R_MEAS + H_ACC], DUT.RAM.mem[R_MEAS + H_WANT]);
        for (h = 0; h < MAXH; h = h + 1)
            if (h != measured && DUT.RAM.mem[R_STREAM0 + 8 * h + S_STATUS] == 2)
                $display("  hart %0d: block %0d summed to %0d, expected %0d", h, DUT.RAM.mem[R_STREAM0 + 8 * h + S_FAILBLK],
                         DUT.RAM.mem[R_STREAM0 + 8 * h + S_GOT], DUT.RAM.mem[R_STREAM0 + 8 * h + S_WANT]);

        // The measured hart's accesses in its window: 256 loads a pass, which hit its data cache, and when it is interrupted the handler's.
        hstart = DUT.RAM.mem[R_MEAS + H_START];
        if (hstart + DUT.RAM.mem[R_MEAS + H_ELAPSED] < ACC_CYCLES)
            $display("IRQ4 acc0 data=%0d fetch=%0d",
                     acc_d[hstart + DUT.RAM.mem[R_MEAS + H_ELAPSED]] - acc_d[hstart],
                     acc_f[hstart + DUT.RAM.mem[R_MEAS + H_ELAPSED]] - acc_f[hstart]);

        // The log: the first interrupt of the window is dropped by the matrix (it may have been
        // pending since the start); a sample as long as the period would mean the timer wrapped twice.
        shown = (n < LOG_MAX) ? n : LOG_MAX;
        bad_samples = 0;
        for (i = 0; i < shown; i = i + 1) begin
            lat = DUT.RAM.mem[IRQ_LOG + 2 * i];
            dn  = DUT.RAM.mem[IRQ_LOG + 2 * i + 1];
            $display("IRQ4 s %0d %0d", lat, dn);
            if (i != 0 && (lat >= period || dn >= period || dn < lat)) bad_samples = bad_samples + 1;
        end

        // A mistyped plusarg ("+mode=2 +irq=0" in quotes reads as x) would otherwise run a case the table does not say.
        check("measured is 0 to 3", {31'b0, measured <= 3}, 32'b1);
        check("mode is 0 to 15", {31'b0, mode <= 15}, 32'b1);
        check("irq is 0 or 1", {31'b0, irq === 32'd0 || irq === 32'd1}, 32'b1);
        check("the measured hart finished with the right checksum", DUT.RAM.mem[R_MEAS + H_STATUS], 32'd1);
        check("it made at least one pass", {31'b0, DUT.RAM.mem[R_MEAS + H_PASSES] != 0}, 32'b1);
        check("its window lasted at least as long as asked", {31'b0, DUT.RAM.mem[R_MEAS + H_ELAPSED] >= window}, 32'b1);
        check("the handler claimed only the timer's source", DUT.RAM.mem[R_MEAS + H_BAD], 32'd0);
        if (irq) begin
            // How many periods the window held and how many interrupts were taken are reported and not checked:
            // a hart the interconnect starves can take longer to serve one than the period (the timer's interrupt
            // stays pending and the next is not queued), and a sample as long as the period is then not a latency
            // (its counter wrapped). That is the finding of a starved case, not a broken test. What is checked is that
            // interrupts were taken at all and that the log did not overflow.
            expect_n = DUT.RAM.mem[R_MEAS + H_ELAPSED] / period;
            $display("IRQ4 delivered n=%0d of %0d periods; %0d logged samples as long as the period or longer", n, expect_n, bad_samples);
            check("interrupts were taken in the window, and none past the log", {31'b0, n >= 1 && n < LOG_MAX}, 32'b1);
        end else begin
            check("the measured hart was not interrupted", n, 32'd0);
        end

        any_streamer = 1'b0;
        smin = 32'hFFFF_FFFF; smax = 0;
        for (h = 0; h < MAXH; h = h + 1) begin
            if (h == measured) begin
                // nothing: its block is the measured hart's
            end else if (mode[h]) begin
                any_streamer = 1'b1;
                send = DUT.RAM.mem[R_STREAM0 + 8 * h + S_START] + DUT.RAM.mem[R_STREAM0 + 8 * h + S_CYCLES];
                check("a streamer finished with every block sum right", DUT.RAM.mem[R_STREAM0 + 8 * h + S_STATUS], 32'd1);
                check("...and read at least one block", {31'b0, DUT.RAM.mem[R_STREAM0 + 8 * h + S_BLOCKS] != 0}, 32'b1);
                // the measured window lies inside every streamer's, so that all of it is contended
                hend = hstart + DUT.RAM.mem[R_MEAS + H_ELAPSED];
                check("...and was still streaming when the measured window ended", {31'b0, send >= hend}, 32'b1);
                check("...and had started before the measured window began", {31'b0, DUT.RAM.mem[R_STREAM0 + 8 * h + S_START] <= hstart}, 32'b1);
                if (DUT.RAM.mem[R_STREAM0 + 8 * h + S_START] < smin) smin = DUT.RAM.mem[R_STREAM0 + 8 * h + S_START];
                if (DUT.RAM.mem[R_STREAM0 + 8 * h + S_START] > smax) smax = DUT.RAM.mem[R_STREAM0 + 8 * h + S_START];
            end else begin
                check("a hart not asked to stream stayed parked",
                      DUT.RAM.mem[R_STREAM0 + 8 * h + S_STATUS] | DUT.RAM.mem[R_STREAM0 + 8 * h + S_BLOCKS] |
                      DUT.RAM.mem[R_STREAM0 + 8 * h + S_START], 32'd0);
            end
        end
        if (any_streamer) begin
            $display("IRQ4 streamers' window start skew=%0d cycles", smax - smin);
            check("the streamers' windows open together (within 100 cycles)", {31'b0, (smax - smin) <= 100}, 32'b1);
        end
        // A run that never finished would otherwise show only as a missing status.
        check("the run finished before the cycle limit", {31'b0, cycles < maxcycles}, 32'b1);

        if (failures == 0) $display("\nSOC-4HART-IRQ: PASS");
        else               $display("\nSOC-4HART-IRQ: FAIL (%0d)", failures);
        $display("---------------------------------------------");
        $finish;
    end
endmodule
