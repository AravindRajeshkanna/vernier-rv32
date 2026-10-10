`timescale 1ns/1ps
// Four harts, one image: atomics, a lock, LR/SC, cache coherence and reservations (Phase 8 Stage 3,
// Part 34). The program is software/bench/mh4.S - read its header for what each phase does and for the
// mailbox and result layout this testbench fills in and reads back.
//
// Every earlier multi-hart test ran two harts. This one builds the SoC with four, over whichever
// interconnect and core the build selects, so a design that is only right for a pair (a monitor that
// compares one pair of harts, a snoop that assumes one other writer, ids with room for two) fails here.
//
// Everything that varies between runs is a plusarg, so one compiled simulation covers every row of
// the matrix (sim/mh4_matrix.py):
//   +nharts=N     how many harts take part, 1 to 4 (default 4); the others park
//   +base=HEX     where the shared data lives: 80010000 (block RAM, the default) or 90000000 (SDRAM)
//   +rounds=N     iterations of the amoadd, lock and LR/SC phases per hart (default 64)
//   +ring=N       rounds of the token ring (default 16)
//   +sets=N       rounds of each reservation test (default 4)
//   +maxcycles=N  give up after this many cycles (default 500000: a passing run takes under 100000, and a
//                 stuck one is worth at most a few minutes of simulation)
// A mistyped value fails the run instead of running a case the table does not say (a lesson of
// sim/tb_soc_2hart_irq.v): nharts must be 1 to 4 and base one of the two.
module tb_soc_4hart;
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

`ifdef XBAR_QOS
    // The router fabric's traffic classes on, as sim/tb_ramboot.v has them: fetch the top class, data and
    // walker next, debug, then the NPU last, with aging at 48 cycles.
    defparam DUT.BUS.QOS_EN    = 1;
    defparam DUT.BUS.AGE_LIMIT = 48;
    defparam DUT.BUS.QOS_DBG   = 1;
    defparam DUT.BUS.QOS_D     = 2;
    defparam DUT.BUS.QOS_W     = 2;
    defparam DUT.BUS.QOS_F     = 3;
    defparam DUT.BUS.QOS_N     = 0;
    initial $display("  (router fabric traffic classes on for this run)");
`endif

    integer cycles = 0;
    always @(posedge clk) if (!rst) cycles = cycles + 1;

    // Word indices into DUT.RAM.mem[]: (byte address - 0x8000_0000) / 4. These are the addresses in mh4.S's header.
    localparam P_NHARTS = 512;    // 0x8000_0800
    localparam P_BASE   = 513;
    localparam P_ROUNDS = 514;
    localparam P_RING   = 515;
    localparam P_SETS   = 516;
    localparam W_ERRORS = 544;    // 0x8000_0880
    localparam R_HART0  = 576;    // 0x8000_0900, sixteen words a hart
    localparam OBS      = 640;    // 0x8000_0A00
    localparam R_STATUS = 0, R_SCFAIL = 1, R_ERRORS = 2;

    reg [31:0] nharts, base, rounds, ring, sets, maxcycles;

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

    integer h;
    reg all_done;
    reg [31:0] total_err;

    initial begin
        if (!$value$plusargs("nharts=%d", nharts))     nharts = 4;
        if (!$value$plusargs("base=%h", base))         base = 32'h8001_0000;
        if (!$value$plusargs("rounds=%d", rounds))     rounds = 64;
        if (!$value$plusargs("ring=%d", ring))         ring = 16;
        if (!$value$plusargs("sets=%d", sets))         sets = 4;
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 32'd500_000;

        // After time 0, so these are ordered after wb_ram's own zero-fill initial block (Verilog
        // does not order initial blocks).
        #1;
        $readmemh("mh4.hex", DUT.RAM.mem);
        DUT.RAM.mem[P_NHARTS] = nharts;
        DUT.RAM.mem[P_BASE]   = base;
        DUT.RAM.mem[P_ROUNDS] = rounds;
        DUT.RAM.mem[P_RING]   = ring;
        DUT.RAM.mem[P_SETS]   = sets;

        $display("MH4 config nharts=%0d base=%08h rounds=%0d ring=%0d sets=%0d", nharts, base, rounds, ring, sets);

        repeat (4) @(posedge clk);
        rst = 0;

        all_done = 0;
        while (!all_done && cycles < maxcycles) begin
            @(posedge clk);
            all_done = 1;
            for (h = 0; h < MAXH; h = h + 1)
                if (h < nharts && DUT.RAM.mem[R_HART0 + 16 * h + R_STATUS] == 0) all_done = 0;
        end

        $display("\n---------------------------------------------");
        $display("MH4 total cycles=%0d", cycles);
        total_err = DUT.RAM.mem[W_ERRORS];
        $display("MH4 errors=%0d", total_err);
        for (h = 0; h < MAXH; h = h + 1)
            $display("MH4 hart %0d status=%0d scfail=%0d errors=%0d", h, DUT.RAM.mem[R_HART0 + 16 * h + R_STATUS],
                     DUT.RAM.mem[R_HART0 + 16 * h + R_SCFAIL], DUT.RAM.mem[R_HART0 + 16 * h + R_ERRORS]);
        $display("MH4 observed c1=%0d c2=%0d c3=%0d scfail=%0d seq=%0d succ=%0d bad=%0d",
                 DUT.RAM.mem[OBS + 0], DUT.RAM.mem[OBS + 1], DUT.RAM.mem[OBS + 2], DUT.RAM.mem[OBS + 3],
                 DUT.RAM.mem[OBS + 4], DUT.RAM.mem[OBS + 5], DUT.RAM.mem[OBS + 7]);

        // A mistyped plusarg ("nharts=x") would otherwise run a case the table does not say.
        check("nharts is 1 to 4", {31'b0, nharts >= 1 && nharts <= MAXH}, 32'b1);
        check("base is block RAM or SDRAM", {31'b0, base === 32'h8001_0000 || base === 32'h9000_0000}, 32'b1);
        check("the run finished before the cycle limit", {31'b0, cycles < maxcycles}, 32'b1);
`ifdef INTERCONNECT_XBAR
        // Without aging, three harts contending for a lock starve the holder's instruction fetch for ever
        // (docs/roadmap/phase-08-noc.md, Part 34). Say so by name, ahead of the unfinished harts it shows as.
        if (nharts >= 3)
            check("the fabric's routers age (XBAR_AGE_LIMIT)", {31'b0, DUT.BUS.AGE_LIMIT != 0}, 32'b1);
`endif
        for (h = 0; h < MAXH; h = h + 1) begin
            if (h < nharts) begin
                check("a hart taking part finished", DUT.RAM.mem[R_HART0 + 16 * h + R_STATUS], 32'd1);
                check("...and found nothing wrong", DUT.RAM.mem[R_HART0 + 16 * h + R_ERRORS], 32'd0);
            end else begin
                check("a hart not taking part did nothing", DUT.RAM.mem[R_HART0 + 16 * h + R_STATUS], 32'd0);
            end
        end
        check("no hart added to the error count", total_err, 32'd0);
        check("amoadd: every add landed", DUT.RAM.mem[OBS + 0], nharts * rounds);
        check("lock: every increment under the lock landed", DUT.RAM.mem[OBS + 1], nharts * rounds);
        check("LR/SC: every increment landed", DUT.RAM.mem[OBS + 2], nharts * rounds);
        check("ring: the token went all the way round", DUT.RAM.mem[OBS + 4], nharts * ring);
        if (nharts >= 2)
            check("reservations: exactly one SC of each contested round succeeded", DUT.RAM.mem[OBS + 5], sets);
        check("hart 0 found no phase wrong", DUT.RAM.mem[OBS + 7], 32'd0);
        if (nharts >= 3)
            check("LR/SC: the harts really contended (some SC failed)", {31'b0, DUT.RAM.mem[OBS + 3] != 0}, 32'b1);

        if (failures == 0) $display("\nSOC-4HART: PASS");
        else               $display("\nSOC-4HART: FAIL (%0d)", failures);
        $display("---------------------------------------------");
        $finish;
    end
endmodule
