// Board-wrapper test for fpga/ulx3s_top.v.
//
// This exists because of what happened to fpga/top_fpga.v: RTL that no build
// exercises rots silently. That file sat in the tree with its page-table
// walker ports unconnected - it still elaborated, it just could never have
// worked - and nothing noticed, because nothing built it. `make verify` now
// builds and runs this one so the same thing cannot happen twice.
//
// It checks the things a board wrapper can get wrong that the SoC underneath
// cannot: pin direction, polarity, and which signal is tied to which. It does
// *not* re-test the SoC - sim/tb_soc.v does that.
//
// The GPIO case is here because it caught a real bug. The wrapper originally
// connected the header with `assign gp[13:0] = gpio[13:0];`, which is
// one-directional: outputs reached the pins, and every input was silently
// dropped, because a continuous assignment cannot carry a value backwards.
// It compiled, linted, synthesized and produced a bitstream. Against the
// broken version the four GPIO checks below read `x`.
`timescale 1ns/1ps
module tb_ulx3s;
    localparam CLK_PERIOD = 40;     // 25 MHz, the ULX3S oscillator
    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg  [6:0] btn = 7'b0000010;    // btn[1] high = pressed = reset asserted
    wire [7:0] led;
    wire       ftdi_rxd, wifi_gpio0;
    wire       sd_clk, sd_cmd;
    wire [3:0] sd_d;

    // External drivers on two header pins, one from each bank.
    reg gp0_drive = 1'b0;
    reg gn0_drive = 1'b0;
    wire [13:0] gp, gn;
    assign gp[0] = gp0_drive;
    assign gn[0] = gn0_drive;

    // The SDRAM pins. Wired to nothing but this testbench: what is being
    // checked here is the *wrapper*, not the memory - that the pins are
    // driven at all, that the clock reaches its pad, and that the data bus is
    // released when the controller is not writing. The memory itself is
    // checked in sim/tb_sdram.v and sim/tb_ulx3s_sdram.v.
    wire        sdram_clk, sdram_cke, sdram_csn, sdram_wen;
    wire        sdram_rasn, sdram_casn;
    wire [12:0] sdram_a;
    wire [1:0]  sdram_ba, sdram_dqm;
    wire [15:0] sdram_d;

    ulx3s_top DUT (
        .clk_25mhz(clk),
        .ftdi_rxd(ftdi_rxd), .ftdi_txd(1'b1),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_d(sd_d), .sd_cdn(1'b0),
        .btn(btn), .led(led), .wifi_gpio0(wifi_gpio0),
        .gp(gp), .gn(gn),
        .sdram_clk(sdram_clk), .sdram_cke(sdram_cke), .sdram_csn(sdram_csn),
        .sdram_wen(sdram_wen), .sdram_rasn(sdram_rasn),
        .sdram_casn(sdram_casn), .sdram_a(sdram_a), .sdram_ba(sdram_ba),
        .sdram_dqm(sdram_dqm), .sdram_d(sdram_d)
    );

    // wb_gpio's synchronized view of the pins: gpio[0] <- gp[0],
    // gpio[14] <- gn[0].
    wire [15:0] gpio_seen = DUT.SOC.SOC.GPIO.in_sync2;

    integer errors = 0;
    reg     sdram_clk_ok;

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

    task check16(input [511:0] what, input [15:0] got, input [15:0] want);
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
        $display("=== ULX3S board wrapper ===");

        // ---- things that must be true while reset is asserted ----
        repeat (4) @(posedge clk);
        check("wifi_gpio0 driven high (ESP32 hold-off)", wifi_gpio0, 1'b1);
        check("btn[1] pressed -> SoC held in reset", DUT.SOC.rst, 1'b1);

        btn[1] = 1'b0;              // release
        repeat (8) @(posedge clk);
        check("btn[1] released -> SoC out of reset", DUT.SOC.rst, 1'b0);

        // ---- SD lines, SPI mode ----
        check("sd_d[2] parked high (unused in SPI mode)", sd_d[2], 1'b1);
        check("sd_d[1] parked high (unused in SPI mode)", sd_d[1], 1'b1);
        check("sd_d[0] not driven by the FPGA (it is MISO)", sd_d[0], 1'bz);
        check("sd_cmd follows the SoC's MOSI", sd_cmd, DUT.spi_mosi);
        check("sd_clk follows the SoC's SCK",  sd_clk, DUT.spi_sck);
        check("sd_d[3] follows the SoC's chip select", sd_d[3], DUT.spi_cs_n);

        // ---- SDRAM pins ----
        // Not a memory test. These are the three ways the *wrapper* can be
        // wrong: a clock pin left undriven (the part sees nothing and the
        // symptom is indistinguishable from a dead controller), CKE tied low
        // (the part stays in standby and never accepts a command), and a data
        // bus held by the FPGA (the part can never drive read data back, which
        // looks exactly like a clock-phase problem and is not).
        // 180 degrees out, not aligned - fpga/sdram_clk_out.v, and the reason
        // is a hardware failure rather than a preference. Asserted here so
        // that quietly going back to an aligned clock is a failing test.
        //
        // Sampled a quarter period *after each edge*, so both phases are
        // checked and neither sample can land on a transition. Comparing
        // `sdram_clk` against `~clk` at a clock edge races the continuous
        // assignment that produces it - the testbench reads the new `clk` and
        // the old `sdram_clk` in the same time step - and that race reported
        // a failure for a wrapper that was correct. Free-running samples at a
        // quarter period did no better, because they drift onto an edge
        // depending on when the check happens to start.
        sdram_clk_ok = 1'b1;
        @(posedge clk); #(CLK_PERIOD / 4);      // clk high, settled
        if (sdram_clk !== 1'b0) sdram_clk_ok = 1'b0;
        @(negedge clk); #(CLK_PERIOD / 4);      // clk low, settled
        if (sdram_clk !== 1'b1) sdram_clk_ok = 1'b0;
        check("sdram_clk is the board clock, inverted", sdram_clk_ok, 1'b1);
        check("sdram_cke asserted", sdram_cke, 1'b1);
        check("sdram_d released while not writing",
              DUT.sdram_dq_oe ? 1'b1 : (sdram_d === 16'bz), 1'b1);

        // ---- GPIO must be bidirectional ----
        // GPIO_DIR resets to all-inputs, so every header pin is an input.
        gp0_drive = 1'b1; gn0_drive = 1'b0;
        repeat (6) @(posedge clk);
        check16("gp[0] driven high reaches gpio[0]",
                gpio_seen & 16'h4001, 16'h0001);

        gp0_drive = 1'b0; gn0_drive = 1'b1;
        repeat (6) @(posedge clk);
        check16("gn[0] driven high reaches gpio[14]",
                gpio_seen & 16'h4001, 16'h4000);

        gp0_drive = 1'b1; gn0_drive = 1'b1;
        repeat (6) @(posedge clk);
        check16("both header pins high", gpio_seen & 16'h4001, 16'h4001);

        gp0_drive = 1'b0; gn0_drive = 1'b0;
        repeat (6) @(posedge clk);
        check16("both header pins low", gpio_seen & 16'h4001, 16'h0000);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("ULX3S WRAPPER TEST PASSED");
        else             $display("ULX3S WRAPPER TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    // The wrapper only claims to be correct about wiring; if the CPU somehow
    // never leaves reset this would spin forever without saying why.
    initial begin
        #2_000_000;
        $display("TIMEOUT - the wrapper test never completed");
        $finish;
    end
endmodule
