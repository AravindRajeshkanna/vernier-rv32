`timescale 1ns/1ps
// CoreMark on both harts at once, with the two harts' images in different memories (Phase 8
// Stage 3). The same programs and checks as sim/tb_soc_2hart_coremark.v, with two changes.
//
// Where hart 1 lives. Without `SPLIT_SDRAM` both images are in block RAM, as in that testbench, so
// the two harts' instruction and data traffic goes to one slave. With it, hart 1's image is linked
// into SDRAM (software/bench/link_bench_hart1_sdram.ld, reached through
// coremark_dispatch_split.S) and loaded into the SDRAM model, so the harts use two memories and
// only meet at the interconnect. That is the case a network with more than one path to memory is for.
//
// What it reports. The bus monitor is gone: it reads the shared bus's wires, which the router
// fabric (INTERCONNECT=xbar) does not have. The measurements are the ones the programs make of
// themselves - each hart's CoreMark iteration in cycles - and the wall-clock total.
// `XBAR_QOS` turns the router fabric's traffic classes on for the run.
// Phase 15 Stage 5: CoreMark running on both harts at once, concurrently -
// not one after the other, and not the same program image executed twice.
// Every earlier Phase 15 test proved the hardware wiring, coherence and boot
// path; this one is the first to put a genuine, sustained workload on both
// harts at the same time and measure it.
//
// Three completely separate, independently-linked images share one RAM
// array (RAM_BYTES(524288), power-of-two - rtl/soc/wb_ram.v computes
// AW=$clog2(WORDS) and indexes with wb_adr[AW+1:2], so a non-power-of-two
// size would round AW up and let out-of-range addresses alias back into the
// array):
//
//   0x8000_0000  coremark_dispatch.hex - both harts fetch this at reset
//                (RESET_PC is shared by every hart in this SoC - see
//                rtl/soc/soc_top.v's hart-0 instantiation and its g_hart
//                generate loop). Reads mhartid, jumps each hart to its own
//                image below.
//   0x8000_0100  COREMARK_LOCK_ADDR     - console spinlock (core_portme.c)
//   0x8000_0104  COREMARK_RESULT0_ADDR - hart 0's own raw cycle count
//   0x8000_0108  COREMARK_RESULT1_ADDR - hart 1's own raw cycle count
//   0x8000_1000  coremark_hart0.hex - hart 0's own complete CoreMark image
//   0x8004_0000  coremark_hart1.hex - hart 1's own complete CoreMark image
//
// A statically-linked C binary bakes fixed absolute addresses for every
// global into its compiled instructions, so the *same* compiled .text run
// by two harts would always reference the *same* physical .bss/stack -
// two harts cannot safely share one CoreMark binary's own data. Two
// completely independent links (software/bench/link_bench_hart0.ld,
// link_bench_hart1.ld), each the whole program at a different base address,
// is what gives each hart's own working state a genuinely private address -
// see either linker script's own header for the full reasoning.
//
// The one thing genuinely shared is rtl/uart.v (one instance, not one per
// hart) - core_main.c prints its own report via ee_printf at several
// points, unmodifiably (software/bench/fetch-coremark.sh: the benchmark's
// own five source files are used unmodified), so two harts printing with no
// coordination would interleave their UART_THR writes byte-by-byte and
// corrupt both harts' output. core_portme.c's own COREMARK_DUAL_HART block
// serializes each hart's entire report (acquired in stop_time(), after the
// timed region has already finished, so the actual measurement stays
// lock-free; released in portable_fini()) - so the two verdicts below are
// expected to arrive as two clean, un-interleaved occurrences, not garbage.
module tb_soc_2hart_coremark_mem;
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

`ifdef XBAR_NO_LATE_GUARD
    // A MEASUREMENT, NOT A CONFIGURATION: the data caches' late-ack guard (rtl/soc/cpu_wb.v's
    // SNOOP_LATE_ACK) switched off in a router-fabric build, to see what the guard costs. Without it
    // a late ack can fill a cache line with a value another hart has already overwritten, so the
    // build is wrong under sharing whatever this run's result; it is here to separate the guard's
    // cost from the fabric's latency, and nothing else.
    defparam DUT.BUSADAPT.SNOOP_LATE_ACK = 0;
    defparam DUT.g_hart[1].BUSADAPT.SNOOP_LATE_ACK = 0;
    initial #1 $display("  (late-ack guard OFF for this run: SNOOP_LATE_ACK = %0d / %0d - NOT A CORRECT CONFIGURATION)",
                        DUT.BUSADAPT.SNOOP_LATE_ACK, DUT.g_hart[1].BUSADAPT.SNOOP_LATE_ACK);
`endif

`ifdef XBAR_QOS
    // The router fabric's traffic classes on (see sim/tb_ramboot.v): fetch the top class, data and
    // walker next, debug, then the NPU's bulk DMA last, with aging at 48 cycles.
    defparam DUT.BUS.QOS_EN    = 1;
    defparam DUT.BUS.AGE_LIMIT = 48;
    defparam DUT.BUS.QOS_DBG   = 1;
    defparam DUT.BUS.QOS_D     = 2;
    defparam DUT.BUS.QOS_W     = 2;
    defparam DUT.BUS.QOS_F     = 3;
    defparam DUT.BUS.QOS_N     = 0;
    initial $display("  (router fabric traffic classes on for this run)");
`endif

    // 25 MHz, which the SDRAM controller's timing (and the model's checks) assume.
    localparam CLK_PERIOD = 40;
    always #(CLK_PERIOD / 2) clk = ~clk;

    integer cycles = 0;
    always @(posedge clk) if (!rst) cycles = cycles + 1;

    // ---- console: decode rtl/uart.v's TX line, count both harts' own
    // verdicts. Same rolling-window mechanism sim/tb_bench.v's own single-
    // hart decoder uses, generalized from a sticky flag to a counter since
    // two harts each print their own, now-serialized, verdict. ----
    localparam WINDOW = 32;
    reg [8*WINDOW-1:0] window = 0;
    integer validated_count = 0;
    integer errors_count    = 0;

    localparam [8*27-1:0] S_OK  = "Correct operation validated";
    localparam [8*15-1:0] S_ERR = "Errors detected";

    integer i;
    reg [7:0] rx_byte;
    initial begin
        forever begin
            @(negedge uart_tx);
            #(CLK_PERIOD / 2 * CLKS_PER_BIT);
            for (i = 0; i < 8; i = i + 1) begin
                #(CLK_PERIOD * CLKS_PER_BIT);
                rx_byte[i] = uart_tx;
            end
            #(CLK_PERIOD * CLKS_PER_BIT);
            $write("%c", rx_byte);
            $fflush;
            window = {window[8*(WINDOW-1)-1:0], rx_byte};
            if (window[8*27-1:0] == S_OK)  validated_count = validated_count + 1;
            if (window[8*15-1:0] == S_ERR) errors_count    = errors_count + 1;
        end
    end

    // Word indices into DUT.RAM.mem[]: (byte address - RAM base) / 4.
    wire [31:0] result0 = DUT.RAM.mem[65];  // 0x8000_0104
    wire [31:0] result1 = DUT.RAM.mem[66];  // 0x8000_0108

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

    reg [31:0] maxcycles;

    initial begin
        if (!$value$plusargs("maxcycles=%d", maxcycles))
            maxcycles = 32'd400_000_000;

        // After time 0, so these are ordered after wb_ram's own zero-fill
        // initial block (Verilog does not order initial blocks) - the same
        // reason sim/tb_bench.v's own single $readmemh call has this delay.
        #1;
`ifdef SPLIT_SDRAM
        $readmemh("coremark_dispatch_split.hex", DUT.RAM.mem);
        $readmemh("coremark_hart0.hex",          DUT.RAM.mem, 1024);   // 0x8000_1000
        $readmemh("coremark_hart1_sdram.hex",    SDRAMCHIP.mem);       // 0x9000_0000
        $display("  (hart 0 in block RAM, hart 1 in SDRAM)");
`else
        $readmemh("coremark_dispatch.hex", DUT.RAM.mem);
        $readmemh("coremark_hart0.hex",    DUT.RAM.mem, 1024);   // 0x8000_1000
        $readmemh("coremark_hart1.hex",    DUT.RAM.mem, 65536);  // 0x8004_0000
        $display("  (both harts in block RAM)");
`endif

        repeat (4) @(posedge clk);
        rst = 0;

        while ((validated_count + errors_count) < 2 && cycles < maxcycles)
            @(posedge clk);

        // Let the tail of the console output drain.
        repeat (400 * CLKS_PER_BIT * 10) @(posedge clk);

        $display("\n---------------------------------------------");
        $display("total cycles (pair wall-clock, reset to both verdicts, includes startup/console I/O): %0d", cycles);
        // Hart 0 is core_ooo.v only under a real CORE=ooo build - under
        // CORE=hetero it stays cpu_core.v (soc_top.v's own hart-0
        // instantiation reads a *different* macro, CORE_OOO, than the
        // generate loop's CORE_HETERO), so this needs its own ifdef rather
        // than assuming "hart 0 is always the in-order one" the way an
        // earlier version of this file incorrectly did.
`ifdef CORE_OOO
        $display("hart 0 (core_ooo.v) - one CoreMark iteration: %0d cycles", result0);
`else
        $display("hart 0 (cpu_core.v) - one CoreMark iteration: %0d cycles", result0);
`endif
`ifdef CORE_HETERO
        $display("hart 1 (core_ooo.v) - one CoreMark iteration: %0d cycles", result1);
`elsif CORE_OOO
        $display("hart 1 (core_ooo.v) - one CoreMark iteration: %0d cycles", result1);
`else
        $display("hart 1 (cpu_core.v) - one CoreMark iteration: %0d cycles", result1);
`endif
        // Total work done, NOT wall-clock: labeled explicitly so this can't
        // be misread as "how long the pair took" - that is the wall-clock
        // number above, from genuinely concurrent execution.
        $display("sum of both harts' own reported cycles (total work done, not wall-clock): %0d", result0 + result1);

        check("both harts validated their own CoreMark results",
              validated_count, 2);
        check("neither hart reported a CRC error", errors_count, 0);
        check("hart 0 wrote a nonzero result", {31'b0, result0 != 0}, 32'b1);
        check("hart 1 wrote a nonzero result", {31'b0, result1 != 0}, 32'b1);
        check("neither hart trapped", {31'b0, trap}, 32'b0);

`ifdef CORE_HETERO
        // Same rob_count-based module-identity proof every other Phase 15
        // testbench uses - cheap insurance that a published "CORE=hetero"
        // number in docs/roadmap/phase-15-heterogeneous.md is honestly from a real mixed pair, not
        // an accidentally-homogeneous one that happened to still validate
        // twice. Referencing rob_count against the wrong module is a hard
        // Icarus compile error, not a silent pass - core_ooo.v is the only
        // one of the two cores with this register at all.
        check("hart 1 is genuinely core_ooo.v - its own rob_count resolves and is defined",
              {31'b0, ^DUT.g_hart[1].CPU.rob_count !== 1'bx}, 32'b1);
`endif

        if (failures == 0) $display("\nSOC-2HART-COREMARK: PASS");
        else                $display("\nSOC-2HART-COREMARK: FAIL (%0d)", failures);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #4_000_000_000;
        $display("\n---------------------------------------------");
        $display("SOC-2HART-COREMARK: FAIL (timeout)");
        $display("---------------------------------------------");
        $finish;
    end
endmodule
