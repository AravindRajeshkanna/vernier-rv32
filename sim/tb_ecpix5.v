// Board-wrapper test for fpga/ecpix5_top.v - Stage 0 (docs/roadmap/phase-09-ddr.md's Phase 9
// entry): board bring-up. Compiled with -DDDR3_ENABLE (`make sim_ecpix5_ddr3`) it is also the test
// of the board's DDR3 variant: the same wrapper with the controller and its pins in, a behavioural
// DDR3 behind each byte lane, and the question whether both lanes calibrate through the board top.
//
// Compiled with -DDDR3_ENABLE -DPRELOAD_RAM -DDDR3_CHECK (`make sim_ecpix5_ddr3_check`) it is the
// test of BOARD=ecpix5-ddr3-check, the self-checking bitstream: software/soc/ddrcheck.c is preloaded
// into block RAM, the boot ROM jumps to it, and the CPU itself stores to and loads from the DDR3
// through the board's pins. Nothing is forced; the testbench decodes the board's UART pin and waits
// for the program's own verdict, as a person with a serial terminal would. One difference from the
// board: the UART runs at 6.25 Mbaud (4 clocks a bit) here, not 115200, because the program prints
// about 800 characters and at 115200 that is 70 ms of simulated time. The divider is fpga/soc_fpga.v's
// CLK_HZ / BAUD_RATE and is not what this test is about.
//
// Compiled with -DDDR3_ENABLE -DLEDS_LANE1_DEAD (`make sim_ecpix5_ddr3_lane1`) it is the test of the board's
// status LEDs (fpga/ecpix5_ddr3_leds.v) in the case the normal run cannot show: no memory behind byte lane 1,
// so lane 1's calibration fails and its LED must say so while lane 0's and the controller's do not. The same
// run without the define checks the LEDs of the good board.
//
// Same reason sim/tb_ulx3s.v exists: fpga/top_fpga.v sat in the tree for
// months with unconnected ports because nothing built it. `make verify`
// now builds and runs this one too, so the same thing cannot happen to
// a second board wrapper. It checks what this wrapper is responsible
// for - reset polarity, the UART pass-through, the one real LED, and
// that every tied-off port (Stage 0 has no real pin for SD/SPI, GPIO,
// JTAG, or SDRAM yet) is tied off safely rather than left floating into
// X. It does not re-test the SoC - sim/tb_soc.v does that.
`timescale 1ns/1ps
module tb_ecpix5;
    localparam CLK_PERIOD = 10;     // 100 MHz, the ECPIX-5's own K23 oscillator
`ifdef DDR3_ENABLE
    localparam DDR3_WAIT_CLKS = 2_000_000;   // board clocks (100 MHz) the calibration may take: 20 ms
`ifdef DDR3_CHECK
    localparam WATCHDOG_NS    = 30_000_000;   // the program needs about 1.5 ms; a hang is not left to run
    localparam PROGRAM_CLKS   = 1_500_000;    // board clocks the program may take: 15 ms, ten times that
`else
    localparam WATCHDOG_NS    = 40_000_000;
`endif
`else
    localparam WATCHDOG_NS    = 2_000_000;
`endif
    reg clk_sys = 0;
    always #(CLK_PERIOD / 2) clk_sys = ~clk_sys;

    reg  rst_n = 1'b0;              // active low - asserted at start
    wire uart_tx;
    reg  uart_rx = 1'b1;            // idle high, matching a real UART line
    wire led2_g;
`ifdef DDR3_ENABLE
    // The board's RGB LEDs are active low (a 74HC244 sinks them, schematic R02, sheet 17): 0 is lit.
    wire led0_r_n, led0_g_n, led0_b_n, led1_r_n, led1_g_n, led1_b_n;
    wire led2_r_n, led2_b_n, led3_r_n, led3_g_n, led3_b_n;
    wire [2:0] led0_rgb = ~{led0_b_n, led0_g_n, led0_r_n};   // {blue, green, red}, 1 = lit
    wire [2:0] led1_rgb = ~{led1_b_n, led1_g_n, led1_r_n};
    wire [2:0] led3_rgb = ~{led3_b_n, led3_g_n, led3_r_n};
`endif

`ifdef DDR3_ENABLE
    // ---- the DDR3 side: the board's pins, and the behavioural models behind them ----
    // The hierarchical paths below are DUT (the board top) / SOC (soc_fpga) / SOC (soc_top) / DDR3 (wb_ddr) /
    // DDR (ddr3_ecp5_top): the same instances sim/tb_ramboot.v reaches from soc_top, three levels further down.
    wire        ddr3_ck;
    wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n;
    wire [2:0]  ddr3_ba;
    wire [14:0] ddr3_a;
    wire        ddr3_cke, ddr3_odt;
    // The DRAM's RESET# is not the FPGA's (Part 27): the board's reset circuit drives it (schematic R02, sheet 3), from
    // the same event that drives rst_n, and its CS# is tied low. So the testbench plays that circuit.
    wire        ddr3_reset_n = rst_n;
    time        ddr3_t_reset_high = 0, ddr3_t_cke_high = 0;
    always @(posedge ddr3_reset_n) ddr3_t_reset_high = $time;
    always @(posedge ddr3_cke) if (ddr3_t_cke_high == 0) ddr3_t_cke_high = $time;
    reg nd_armed = 1'b0, nd_cke_fell = 1'b0;     // the debugger's ndmreset, below: CKE must not fall with it
    always @(negedge ddr3_cke) if (nd_armed) nd_cke_fell = 1'b1;
    // when each LED stage is reached, from the board's reset: how long the blue and the dark states last
    time ddr3_t_init = 0, ddr3_t_lane0 = 0, ddr3_t_lane1 = 0;
    always @(posedge DUT.SOC.SOC.DDR3.init_ready)  if (ddr3_t_init  == 0) ddr3_t_init  = $time;
    always @(posedge DUT.SOC.SOC.DDR3.calib_done)  if (ddr3_t_lane0 == 0) ddr3_t_lane0 = $time;
    always @(posedge DUT.SOC.SOC.DDR3.calib1_done) if (ddr3_t_lane1 == 0) ddr3_t_lane1 = $time;
    wire [7:0]  ddr3_dq, ddr3_dqu;
    wire        ddr3_dqs, ddr3_udqs, ddr3_dm, ddr3_udm;
`endif

    ecpix5_top DUT (
        .clk_sys(clk_sys), .rst_n(rst_n),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .led2_g(led2_g)
`ifdef DDR3_ENABLE
        ,
        .led0_r_n(led0_r_n), .led0_g_n(led0_g_n), .led0_b_n(led0_b_n),
        .led1_r_n(led1_r_n), .led1_g_n(led1_g_n), .led1_b_n(led1_b_n),
        .led2_r_n(led2_r_n), .led2_b_n(led2_b_n),
        .led3_r_n(led3_r_n), .led3_g_n(led3_g_n), .led3_b_n(led3_b_n),
        .ddr3_ck(ddr3_ck),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm)
`endif
    );

`ifdef DDR3_ENABLE
    wire        ddr3_model_error;
    wire [511:0] ddr3_model_error_msg;
    ddr3_model #(.CLK_HZ(25_000_000)) DDR3PROTO (
        .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .cke(ddr3_cke), .reset_n(ddr3_reset_n), .odt(ddr3_odt),
        .error(ddr3_model_error), .error_msg(ddr3_model_error_msg), .seq_done()
    );

    wire [7:0] ddr3_mem_dq_o;
    wire       ddr3_mem_dq_oe, ddr3_mem_dqs_oe, ddr3_mem_dqs_o;
    wire       ddr3_dq_error;
    wire [511:0] ddr3_dq_error_msg;
    ddr3_dq_model DDR3MEM (
        .sclk(DUT.SOC.SOC.DDR3.DDR.sclk), .rst(DUT.SOC.SOC.DDR3.DDR.rst_all),
        .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dq_pin(ddr3_dq), .dqs_pin(ddr3_dqs), .dm_pin(ddr3_dm),
        .read_active(DUT.SOC.SOC.DDR3.DDR.read_active_final),
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
    // Lane 1's memory: the controller takes no request until both lanes have calibrated, and a lane
    // calibrates by looping a pattern back through a DRAM (sim/tb_ramboot.v says the same).
    reg ck_seen = 1'b0;                 // CK reached the pin and moved
    always @(ddr3_ck) if (ddr3_ck !== 1'bx) ck_seen = 1'b1;

    // One Wishbone classic cycle on the DDR3 slave, issued from here. Its inputs are forced: nothing else in this
    // testbench can drive them (the CPU is in its boot ROM and never touches 0xA0000000 on its own), and a program
    // that did would be the whole boot-and-load flow of `make sim_uartload_ddr3`, minutes where this is microseconds.
    // The cycle ends in the cycle of the ack, as sim/tb_wb_ddr.v's does. Icarus only: force and release on nets.
    wire dclk = DUT.SOC.SOC.DDR3.clk;
    integer ddr3_guard;
    task ddr3_access(input we, input [31:0] adr, input [31:0] dat_w, input [3:0] sel, output [31:0] dat_r);
        begin
            @(posedge dclk);
            force DUT.SOC.SOC.DDR3.wb_cyc = 1'b1;  force DUT.SOC.SOC.DDR3.wb_stb = 1'b1;
            force DUT.SOC.SOC.DDR3.wb_we = we;     force DUT.SOC.SOC.DDR3.wb_adr = adr;
            force DUT.SOC.SOC.DDR3.wb_dat_w = dat_w; force DUT.SOC.SOC.DDR3.wb_sel = sel;
            @(posedge dclk);
            ddr3_guard = 0;
            while (DUT.SOC.SOC.DDR3.wb_ack !== 1'b1 && ddr3_guard < 20000) begin
                @(posedge dclk);
                ddr3_guard = ddr3_guard + 1;
            end
            dat_r = (DUT.SOC.SOC.DDR3.wb_ack === 1'b1) ? DUT.SOC.SOC.DDR3.wb_dat_r : 32'hxxxxxxxx;
            release DUT.SOC.SOC.DDR3.wb_cyc;   release DUT.SOC.SOC.DDR3.wb_stb;
            release DUT.SOC.SOC.DDR3.wb_we;    release DUT.SOC.SOC.DDR3.wb_adr;
            release DUT.SOC.SOC.DDR3.wb_dat_w; release DUT.SOC.SOC.DDR3.wb_sel;
            @(posedge dclk);
        end
    endtask
`ifndef LEDS_LANE1_DEAD
    ddr3_lane1_mem DDR3MEM1 (
        .sclk(DUT.SOC.SOC.DDR3.DDR.sclk), .rst(DUT.SOC.SOC.DDR3.DDR.rst_all), .ck(ddr3_ck),
        .ras_n(ddr3_ras_n), .cas_n(ddr3_cas_n), .we_n(ddr3_we_n),
        .ba(ddr3_ba), .a(ddr3_a),
        .dqu(ddr3_dqu), .udqs(ddr3_udqs), .udm(ddr3_udm),
        .read_active(DUT.SOC.SOC.DDR3.DDR.read_active_final_1), .dq_error()
    );
`endif

`ifdef DDR3_CHECK
    // ---- the board's UART, decoded at the pin, as a serial terminal would ----
    // 4 clocks a bit instead of fpga/soc_fpga.v's 217 (see the header). The decoder keeps the last 32
    // characters and looks for the lines the boot ROM and software/soc/ddrcheck.c print.
    defparam DUT.SOC.BAUD_RATE = 6_250_000;
    localparam UART_BIT_NS = 160;                 // 4 SoC clocks of 40 ns
    reg [7:0]   rx_byte;
    reg [255:0] console_tail = 256'b0;
    integer     console_chars = 0, console_fail_lines = 0;
    reg         console_found_prog = 1'b0, console_passed = 1'b0, console_failed = 1'b0;
    integer     rx_i, line_n = 0, line_i;
    time        console_last = 0;                 // when the last character arrived
    reg [7:0]   line [0:255];
    always begin
        @(negedge uart_tx);                       // a start bit
        #(UART_BIT_NS * 3 / 2);                   // the middle of bit 0
        for (rx_i = 0; rx_i < 8; rx_i = rx_i + 1) begin
            rx_byte[rx_i] = uart_tx;
            #(UART_BIT_NS);
        end                                       // now in the middle of the stop bit
        console_tail  = {console_tail[247:0], rx_byte};
        console_chars = console_chars + 1;
        console_last  = $time;
        // a line at a time, in one step, so that the testbench's own lines never split one of the program's
        if (rx_byte == 8'h0A || line_n == 255) begin
            for (line_i = 0; line_i < line_n; line_i = line_i + 1) $write("%c", line[line_i]);
            $write("\n");
            line_n = 0;
        end else if (rx_byte != 8'h0D) begin
            line[line_n] = rx_byte;
            line_n = line_n + 1;
        end
        if (console_tail[215:0]  === "RAM already holds a program")  console_found_prog = 1'b1;
        if (console_tail[199:0]  === "DDR3 CPU-PATH TEST PASSED")    console_passed     = 1'b1;
        if (console_tail[199:0]  === "DDR3 CPU-PATH TEST FAILED")    console_failed     = 1'b1;
        if (console_tail[39:0]   === "FAIL ")                        console_fail_lines = console_fail_lines + 1;
    end
`endif
`endif

    integer errors = 0;

    task check(input [511:0] what, input got, input want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %b, expected %b", what, got, want);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s", what);
            end
        end
    endtask

    initial begin
        $display("=== ECPIX-5 board wrapper (Stage 0) ===");

        // ---- reset polarity ----
        repeat (4) @(posedge clk_sys);
        check("rst_n low -> SoC held in reset", DUT.SOC.rst, 1'b1);

        rst_n = 1'b1;               // release
        repeat (16) @(posedge clk_sys);
        check("rst_n high -> SoC out of reset", DUT.SOC.rst, 1'b0);

        // ---- the PLL actually divides, not just elaborates ----
        // fpga/ecpix5_clk_pll.v's own behavioral model divides by 4;
        // this is the wrapper's own responsibility to wire correctly,
        // not the PLL's own dedicated correctness (which would be a
        // separate, PLL-scoped test if this project adds one the way
        // sim_video_pll/sim_underclock_pll already exist for the other
        // two clock primitives).
        check("PLL reports locked", DUT.SOC_PLL.locked, 1'b1);

        // ---- UART pass-through, not swapped ----
        // soc_fpga.v drives uart_tx whenever the boot ROM sends a byte;
        // checking it eventually toggles is enough to prove the wrapper
        // did not swap tx/rx - a swap would leave uart_tx idle forever
        // (driven from soc_fpga.v's own idle-high default) while
        // uart_rx silently absorbs the SoC's own transmitted bits.
        begin : uart_check
            integer i;
            reg saw_toggle;
            reg last;
            saw_toggle = 1'b0;
            last = uart_tx;
            for (i = 0; i < 20000; i = i + 1) begin
                @(posedge clk_sys);
                if (uart_tx !== last) saw_toggle = 1'b1;
                last = uart_tx;
            end
            check("uart_tx toggles (boot ROM is sending)", saw_toggle, 1'b1);
        end

        // ---- a tied-off input still produces a defined output ----
        // Stage 0 has no real pin yet for SD/SPI, GPIO, or SDRAM - see
        // fpga/ecpix5_top.v's own header for why. spi_cs_n is a port on
        // the `SOC` instance itself (unconnected at the ecpix5_top
        // level, so referenced through it, not as a top-level wire).
        //
        // The equivalent JTAG check (jtag_tdo not X) was tried and
        // removed: a TAP's TDO is only meaningful once TCK has clocked
        // its state machine into a shift state, which never happens
        // here since tck is permanently tied to 0 - the whole point of
        // that tie-off. TDO reading X forever under a never-clocked TCK
        // is a real, correct property of the TAP, not something this
        // wrapper's own tie-off could be wrong about.
        check("spi_cs_n not X (SPI logic sane with SD tied off)",
              ^DUT.SOC.spi_cs_n !== 1'bx, 1'b1);

`ifdef DDR3_ENABLE
        // ---- both DDR3 byte lanes calibrate through the board top ----
        // The controller starts on its own after reset: initialisation, then each lane's read-capture
        // calibration against the model behind its pins. Waiting here for it (no CPU involved) shows that
        // the board top's DDR3 ports reach the controller's, and its second PLL runs off the first one's
        // output, which no earlier test saw: sim/tb_ramboot.v has the controller one level up, on the SoC
        // clock itself.
        begin : ddr3_check
            integer waited;
            waited = 0;
            // The state before the lanes have anything to say: the DRAM's power-up wait is about 500 us from the board's
            // reset (the checks above took 200 us of it), so the controller's PLL and DLL are locked and the initialisation
            // is not done. LED0 is blue and the lanes' LEDs are dark; only a decoder with the right inputs on the right
            // LEDs shows that, since all three are green a little later.
            while (!(DUT.SOC.SOC.DDR3.pll_locked === 1'b1 && DUT.SOC.SOC.DDR3.dll_locked === 1'b1) && waited < DDR3_WAIT_CLKS) begin
                @(posedge clk_sys);
                waited = waited + 1;
            end
            @(posedge clk_sys);
            check("(the DRAM is still initialising)", DUT.SOC.SOC.DDR3.init_ready, 1'b0);
            check("LED0 (controller) is blue while the DRAM initialises", led0_rgb === 3'b100, 1'b1);
            check("LED1 (lane 0) is dark: calibration has not started", led1_rgb === 3'b000, 1'b1);
            check("LED3 (lane 1) is dark: calibration has not started", led3_rgb === 3'b000, 1'b1);
            waited = 0;
`ifdef LEDS_LANE1_DEAD
            // No memory behind lane 1: its sweep finds no working tap and ends in an error, lane 0's does not.
            while (!(DUT.SOC.SOC.DDR3.calib_done === 1'b1 && DUT.SOC.SOC.DDR3.calib1_error === 1'b1) &&
                   waited < DDR3_WAIT_CLKS) begin
                @(posedge clk_sys);
                waited = waited + 1;
            end
            $display("  (lane 0 calibrated and lane 1 failed after %0d board clocks)", waited);
            check("lane 0 calibrated", DUT.SOC.SOC.DDR3.calib_done, 1'b1);
            check("no calibration error, lane 0", DUT.SOC.SOC.DDR3.calib_error, 1'b0);
            check("lane 1 reports its calibration error", DUT.SOC.SOC.DDR3.calib1_error, 1'b1);
            check("lane 1 is not calibrated", DUT.SOC.SOC.DDR3.calib1_done, 1'b0);
`else
            while (!(DUT.SOC.SOC.DDR3.calib_done === 1'b1 && DUT.SOC.SOC.DDR3.calib1_done === 1'b1) &&
                   waited < DDR3_WAIT_CLKS) begin
                @(posedge clk_sys);
                waited = waited + 1;
            end
            $display("  (both lanes calibrated after %0d board clocks)", waited);
            check("lane 0 calibrated", DUT.SOC.SOC.DDR3.calib_done, 1'b1);
            check("lane 1 calibrated", DUT.SOC.SOC.DDR3.calib1_done, 1'b1);
            check("no calibration error, lane 0", DUT.SOC.SOC.DDR3.calib_error, 1'b0);
            check("no calibration error, lane 1", DUT.SOC.SOC.DDR3.calib1_error, 1'b0);
`endif
            // The status LEDs, at the board's pins (active low: lit is 0). LED0 is the controller, LED1 lane 0, LED3 lane 1;
            // LED2's green is the CPU's heartbeat and its red and blue are driven off, like every channel nobody uses.
            @(posedge clk_sys);
            check("LED0 (controller) is green: PLL and DLL locked, DRAM initialised", led0_rgb === 3'b010, 1'b1);
            check("LED1 (lane 0) is green: calibrated", led1_rgb === 3'b010, 1'b1);
`ifdef LEDS_LANE1_DEAD
            check("LED3 (lane 1) is red: its calibration failed", led3_rgb === 3'b001, 1'b1);
`else
            check("LED3 (lane 1) is green: calibrated", led3_rgb === 3'b010, 1'b1);
`endif
`ifdef LEDS_LANE1_DEAD
            $display("  (from the board's reset: initialisation done after %0d us, lane 0 calibrated after %0d us)",
                     (ddr3_t_init - ddr3_t_reset_high) / 1000, (ddr3_t_lane0 - ddr3_t_reset_high) / 1000);
`else
            $display("  (from the board's reset: initialisation done after %0d us, lane 0 calibrated after %0d us, lane 1 after %0d us)",
                     (ddr3_t_init - ddr3_t_reset_high) / 1000, (ddr3_t_lane0 - ddr3_t_reset_high) / 1000,
                     (ddr3_t_lane1 - ddr3_t_reset_high) / 1000);
`endif
            check("LED2's red is driven off", led2_r_n === 1'b1, 1'b1);
            check("LED2's blue is driven off", led2_b_n === 1'b1, 1'b1);
            check("CK reaches its pin and moves", ck_seen, 1'b1);
            check("CKE is high at its pin", ddr3_cke, 1'b1);
            $display("  (CKE rose %0d ns after the board's reset was released)", ddr3_t_cke_high - ddr3_t_reset_high);
            check("CKE rises 500 us or more after the board's reset is released",
                  (ddr3_t_cke_high - ddr3_t_reset_high) >= 500_000, 1'b1);
            check("the DDR3 protocol checker saw nothing wrong", ddr3_model_error, 1'b0);
            check("the DQ model saw nothing wrong", ddr3_dq_error, 1'b0);
        end

`ifndef LEDS_LANE1_DEAD
        // ---- words through the bus, both lanes, with byte enables ----
        // The calibration above is command-driven (rtl/soc/ddr3_read_calib.v: a WRITE and READs of one column), so it
        // already fails on a swap of RAS# with CAS# and of a strobe with the other lane's. What it does not look at is the
        // data masks, the byte placement and the addresses beyond its one column. A store and a load do: each lane's mask
        // must reach its own byte, a store that selects one lane must leave the other's byte alone, and a second block
        // must not disturb the first.
        //
        // Every load below follows a load from another block. The slave keeps the block it last touched (rtl/soc/wb_ddr.v:
        // a store writes through and updates that copy), so a load straight after a store is answered from the copy
        // and says nothing about the DRAM; the access to the other block throws the copy away, and the load that
        // follows fetches the block from the memory behind the pins.
`ifdef DDR3_CHECK
        // ---- the program does it, through the CPU ----
        // Nothing is forced. The boot ROM finds software/soc/ddrcheck.c in block RAM (preloaded, as the bitstream
        // has it), jumps to it, and the program stores to and loads from the DDR3 through the real interconnect,
        // the slave, the controller and the board's pins, and prints each check and then its verdict. A lane
        // that did not calibrate would hang its first access (the slave waits for both), and the watchdog says so.
        begin : ddr3_program
            integer waited;
            waited = 0;
            while (!console_passed && !console_failed && waited < PROGRAM_CLKS) begin
                @(posedge clk_sys);
                waited = waited + 1;
            end
            // the verdict line is not finished when its last letter arrives: let the program's last lines out
            while (($time - console_last) < 40_000) @(posedge clk_sys);
            $display("\n  (the program's verdict after %0d board clocks, %0d characters)", waited, console_chars);
            check("the boot ROM found the program in RAM and ran it", console_found_prog, 1'b1);
            check("the program says DDR3 CPU-PATH TEST PASSED", console_passed, 1'b1);
            check("no check of the program failed", console_fail_lines == 0 && !console_failed, 1'b1);
            check("the DDR3 protocol checker saw nothing wrong", ddr3_model_error, 1'b0);
            check("the DQ model saw nothing wrong", ddr3_dq_error, 1'b0);
        end
`else
        begin : ddr3_data
            reg [31:0] r;
            ddr3_access(1'b1, 32'hA000_0000, 32'h1122_3344, 4'b1111, r);
            ddr3_access(1'b0, 32'hA000_0100, 32'h0,         4'b1111, r);
            ddr3_access(1'b0, 32'hA000_0000, 32'h0,         4'b1111, r);
            check("a word written to DDR3 reads back from the memory", r === 32'h1122_3344, 1'b1);
            ddr3_access(1'b1, 32'hA000_0000, 32'h0000_0099, 4'b0001, r);
            ddr3_access(1'b0, 32'hA000_0100, 32'h0,         4'b1111, r);
            ddr3_access(1'b0, 32'hA000_0000, 32'h0,         4'b1111, r);
            check("a store of lane 0's byte alone leaves the rest", r === 32'h1122_3399, 1'b1);
            ddr3_access(1'b1, 32'hA000_0000, 32'h0000_AA00, 4'b0010, r);
            ddr3_access(1'b0, 32'hA000_0100, 32'h0,         4'b1111, r);
            ddr3_access(1'b0, 32'hA000_0000, 32'h0,         4'b1111, r);
            check("a store of lane 1's byte alone leaves the rest", r === 32'h1122_AA99, 1'b1);
            ddr3_access(1'b1, 32'hA000_0000, 32'h5566_0000, 4'b1100, r);
            ddr3_access(1'b0, 32'hA000_0100, 32'h0,         4'b1111, r);
            ddr3_access(1'b0, 32'hA000_0000, 32'h0,         4'b1111, r);
            check("a store of the upper half alone leaves the lower", r === 32'h5566_AA99, 1'b1);
            ddr3_access(1'b1, 32'hA000_0010, 32'hCAFE_F00D, 4'b1111, r);
            ddr3_access(1'b0, 32'hA000_0100, 32'h0,         4'b1111, r);
            ddr3_access(1'b0, 32'hA000_0000, 32'h0,         4'b1111, r);
            check("a second block's store does not disturb the first", r === 32'h5566_AA99, 1'b1);
            ddr3_access(1'b0, 32'hA000_0010, 32'h0,         4'b1111, r);
            check("and the second block reads back itself", r === 32'hCAFE_F00D, 1'b1);
            check("the DDR3 protocol checker still saw nothing wrong", ddr3_model_error, 1'b0);
            check("the DQ model still saw nothing wrong", ddr3_dq_error, 1'b0);
        end

        // ---- the debugger's ndmreset resets the controller and the slave, and not the DRAM ----
        // The debug module's ndmreset restarts the SoC without touching the board (rtl/debug/dm.v), and the DRAM's RESET# is the
        // board's: so this must reach the controller as a warm reset, which keeps CKE up (rtl/soc/ddr3_init_seq.v), and reset the
        // slave's own state (the block it holds) as it always has. Forced here, since no JTAG host is attached. The unit
        // version, with the DRAM mid-burst and with a bank open, is sim/tb_ddr3_restart.v (make sim_ddr3_restart).
        begin : ddr3_ndmreset
            integer waited;
            check("(the slave holds a block before the reset)", DUT.SOC.SOC.DDR3.block_valid, 1'b1);
            check("(and the controller is initialised)", DUT.SOC.SOC.DDR3.init_ready, 1'b1);
            nd_armed = 1'b1;
            force DUT.SOC.SOC.dbg_ndmreset = 1'b1;
            repeat (4) @(posedge clk_sys);
            release DUT.SOC.SOC.dbg_ndmreset;
            check("the slave's own state was reset: it no longer holds a block", DUT.SOC.SOC.DDR3.block_valid, 1'b0);
            check("the controller was reset: init_ready fell", DUT.SOC.SOC.DDR3.init_ready, 1'b0);
            waited = 0;
            while (DUT.SOC.SOC.DDR3.init_ready !== 1'b1 && waited < 60_000) begin @(posedge clk_sys); waited = waited + 1; end
            check("init_ready returned within 100 us (10,000 board clocks), well before a cold start's 500 us", waited < 10_000, 1'b1);
            check("CKE never fell", nd_cke_fell, 1'b0);
            check("the DDR3 protocol checker has no objection to the restart", ddr3_model_error, 1'b0);
        end
`endif
`endif
`endif

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("ECPIX5 WRAPPER TEST PASSED");
        else             $display("ECPIX5 WRAPPER TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    // The wrapper only claims to be correct about wiring; if the CPU
    // somehow never leaves reset this would spin forever without saying
    // why.
    initial begin
        #WATCHDOG_NS;
        $display("TIMEOUT - the wrapper test never completed");
        $finish;
    end
endmodule
