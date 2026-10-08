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

// $(CORE)-suffixed by the Makefile (bootrom_$(CORE).hex) - the boot ROM's
// own embedded device tree varies with $(CORE) now (Phase 15, Stage 3's
// second half: dts/soc.dts's own header has the reasoning), so the ROM
// image itself must vary with $(CORE) too, the same "no fixed-name file
// hides which build produced it" discipline every other CORE-dependent
// artifact in the Makefile already follows.
`ifndef ROM_IMAGE
`define ROM_IMAGE "bootrom.hex"
`endif

// 16-bit words of modelled SDRAM. 1 M words is 2 MB, which is all the tests
// that only *touch* SDRAM need. `make sim_mmusdram` overrides it because its
// whole point is the top half of a 32 MB part: its page table maps addresses
// above 0x9100_0000, and sdram_model.v errors on an access past MEM_WORDS
// rather than aliasing, so a model too small fails loudly instead of
// pretending the upper half is there.
`ifndef SDRAM_WORDS
`define SDRAM_WORDS (1 << 20)
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

    // ---- external SDRAM ----
    // Attached here, not only in sim/tb_sdramboot.v, and it costs almost
    // nothing: the SoC never touches 0x90 in these runs, so all the model
    // does is assert that the controller keeps issuing AUTO REFRESH on
    // schedule while the CPU is busy doing something else entirely. Nothing
    // else checks that, and `make sim_rerun` additionally puts a reset
    // through it - which is why sim/sdram_model.v has a reset input at all.
    //
    // It is also what makes `make sim_sdramcheck` work: same testbench, same
    // 64 KB block RAM, a different RAM_IMAGE, and a real memory behind the
    // window that image is about to hammer.
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [12:0] sd_a;
    wire [1:0]  sd_ba, sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;

    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    // Clocked 180 degrees from the controller, because that is what the board
    // does: fpga/sdram_clk_out.v drives the part's clock from an ODDRX1F so
    // its rising edge lands on the internal clock's falling edge. Clocking
    // the model from `clk` here would simulate a machine no board is, and
    // would be the *aligned* configuration that hardware rejected.
    sdram_model #(.MEM_WORDS(`SDRAM_WORDS)) SDRAMCHIP (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );

    // ---- DDR3 (Phase 9 Stage 2) ----
    // The wires are declared unconditionally - rtl/soc/soc_top.v's own
    // ddr3_* ports always exist (its own DDR3 slave itself is what is
    // gated - see that file's own header), so these are always validly
    // driven by the DUT either way. Only the real protocol/memory models
    // below are gated behind `DDR3_ENABLE` (`make sim_ddrcheck` alone
    // passes it): `DUT.DDR3.DDR` does not exist to reach by hierarchical
    // reference unless this exact compilation also enabled it, and every
    // other check sharing this testbench (trapcheck, pmptest, uartirq and
    // the rest) has never touched DDR3_BASE, so there is nothing here for
    // them to gain from carrying it.
    wire        ddr3_ck, ddr3_ck_n;
    wire        ddr3_cs_n, ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [15:0] ddr3_a;
    wire        ddr3_cke, ddr3_reset_n, ddr3_odt;
    wire [7:0]  ddr3_dq;
    wire        ddr3_dqs;
    wire        ddr3_dm;
    wire [7:0]  ddr3_dqu;
    wire        ddr3_udqs;
    wire        ddr3_udm;

`ifdef DDR3_ENABLE
    wire        ddr3_model_error;
    wire [511:0] ddr3_model_error_msg;
    ddr3_model #(.CLK_HZ(25_000_000)) DDR3PROTO (
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(ddr3_model_error), .error_msg(ddr3_model_error_msg), .seq_done()
    );

    wire [7:0] ddr3_mem_dq_o;
    wire       ddr3_mem_dq_oe, ddr3_mem_dqs_oe, ddr3_mem_dqs_o;
    wire       ddr3_dq_error;
    wire [511:0] ddr3_dq_error_msg;
    ddr3_dq_model DDR3MEM (
        .sclk(DUT.DDR3.DDR.sclk), .rst(DUT.DDR3.DDR.rst_all),
        .ck(ddr3_ck),
        .cs_n(ddr3_cs_n), .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
        .read_active(DUT.DDR3.DDR.read_active),
        .mem_dq_o(ddr3_mem_dq_o), .mem_dq_oe(ddr3_mem_dq_oe),
        .mem_dqs_oe(ddr3_mem_dqs_oe), .mem_dqs_o(ddr3_mem_dqs_o),
        .dq_error(ddr3_dq_error), .dq_error_msg(ddr3_dq_error_msg)
    );
    genvar dqi;
    generate
        for (dqi = 0; dqi < 8; dqi = dqi + 1) begin : DDR3_DQ_BUS
            assign ddr3_dq[dqi] = ddr3_mem_dq_oe ? ddr3_mem_dq_o[dqi] : 1'bz;
        end
    endgenerate
    assign ddr3_dqs = ddr3_mem_dqs_oe ? ddr3_mem_dqs_o : 1'bz;
    // Lane 1 carries no real data yet (rtl/soc/wb_ddr.v's own header) -
    // nothing drives ddr3_dqu/ddr3_udqs here, the same as real silicon with
    // nothing behind the upper byte lane.
`endif

    soc_top #(
        .RAM_BYTES(RAM_BYTES),
        .ROM_INIT_FILE(`ROM_IMAGE),
        .RAM_INIT_FILE(`RAM_IMAGE),
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
        .pwm_out(),
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n),
        .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .trap(trap)
    );

    // 25 MHz, matching CPU_HZ in software/soc/soc.h and CLK_HZ in soc_fpga.v.
    localparam CLK_PERIOD = 40;
    always #(CLK_PERIOD / 2) clk = ~clk;

`ifdef XBAR_QOS
    // The router fabric's traffic classes on for this run (Phase 8 Stage 3): fetch the top
    // class, data and walker next, debug, then the NPU's bulk DMA last, with aging at 48
    // cycles. Only meaningful with INTERCONNECT=xbar; defparam reaches the fabric's own
    // parameters, so no RTL changes for a measurement.
    defparam DUT.BUS.QOS_EN    = 1;
    defparam DUT.BUS.AGE_LIMIT = 48;
    defparam DUT.BUS.QOS_DBG   = 1;
    defparam DUT.BUS.QOS_D     = 2;
    defparam DUT.BUS.QOS_W     = 2;
    defparam DUT.BUS.QOS_F     = 3;
    defparam DUT.BUS.QOS_N     = 0;
    initial $display("  (router fabric traffic classes on for this run)");
`endif

`ifdef BUS_MONITOR
    // Phase 8 Stage 0: a passive observer of the shared bus, reported once per
    // phase of the program under test. The program marks a phase boundary by
    // writing GPIO_OUT: 0x00FF clears the counters (start of the measured
    // region), any other value N reports the phase that has just ended and
    // clears again. See sim/bus_monitor.v and software/soc/npuload.c.
    localparam MON_SLAVES = 13;   // must equal soc_top.v's NUM_SLAVES; checked below
    initial #1 if (DUT.NUM_SLAVES != MON_SLAVES) begin
        $display("  FAIL bus monitor built for %0d slaves, soc_top has %0d", MON_SLAVES, DUT.NUM_SLAVES);
        $finish;
    end
    bus_monitor #(.NUM_HARTS(1), .NUM_SLAVES(MON_SLAVES)) MON (
        .clk(clk), .rst(rst),
        .f_cyc(DUT.BUS.f_cyc), .d_cyc(DUT.BUS.d_cyc), .w_cyc(DUT.BUS.w_cyc),
        .dbg_cyc(DUT.BUS.dbg_cyc), .n_cyc(DUT.BUS.n_cyc),
        .sel_f(DUT.BUS.sel_f), .sel_d(DUT.BUS.sel_d), .sel_w(DUT.BUS.sel_w),
        .sel_dbg(DUT.BUS.sel_dbg), .sel_n(DUT.BUS.sel_n),
        .s_cyc(DUT.BUS.s_cyc), .s_stb(DUT.BUS.s_stb)
    );
`ifdef NO_DCACHE
    // The data cache off, as every multi-hart build had it until Phase 8
    // Part 5 (soc_top.v's HART_DCACHE_ENABLE), so a single hart's bus traffic is
    // what it was there. No RTL changes; defparam reaches the bus adapter's own parameter.
    defparam DUT.BUSADAPT.DCACHE_ENABLE = 1'b0;
    initial $display("  (data cache disabled for this run)");
`endif
    always @(gpio_out) if (!rst) begin
        if (gpio_out === 16'h00FF) begin
            MON.clear;
        end else if (^gpio_out !== 1'bx) begin
            $display("[bus] phase %0d complete", gpio_out);
            MON.report;
            MON.clear;
        end
    end
`endif

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
            $dumpfile("wave_ramboot.vcd");
            $dumpvars(0, tb_ramboot);
        end
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
