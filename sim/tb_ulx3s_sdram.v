`timescale 1ns/1ps
// Simulates the hardware SDRAM probe before it is flashed.
//
// fpga/ulx3s_sdram.v goes on a board and reports through five LEDs. That is a
// four-bit-wide diagnostic channel attached to a device you cannot single-step,
// so the one thing it must not do is arrive at the board untested: a probe that
// is itself wrong turns "the memory does not work" into a wild goose chase
// through the memory, the pinout and the clock, when the fault is in the
// instrument.
//
// So the probe runs here first, against sim/sdram_model.v, and this testbench
// asserts the same thing a person reads off the board: all five stage LEDs lit.
// docs/practices.md §14 - anything nothing builds will rot, and this is worse
// than rot, because it would rot silently and then lie.
//
// IDLE_CYCLES is turned right down. On a board it is ~100 ms, which is what
// makes led[4] a real retention test; here the model asserts that AUTO REFRESH
// arrives within 2x tREFI regardless, so 2000 cycles proves the logic without
// simulating a tenth of a second.
module tb_ulx3s_sdram;
    localparam CLK_PERIOD = 40;        // 25 MHz, matching CLK_HZ

    reg clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg [6:0] btn = 7'b0000010;        // btn[1] pressed = reset asserted
    wire [7:0] led;
    wire       wifi_gpio0;

    wire        sd_clk, sd_cke, sd_csn, sd_wen, sd_rasn, sd_casn;
    wire [12:0] sd_a;
    wire [1:0]  sd_ba, sd_dqm;
    wire [15:0] sd_d;

    ulx3s_sdram #(
        .CLK_HZ(25_000_000),
        .IDLE_CYCLES(2000)
    ) PROBE (
        .clk_25mhz(clk), .btn(btn), .led(led), .wifi_gpio0(wifi_gpio0),
        .sdram_clk(sd_clk), .sdram_cke(sd_cke), .sdram_csn(sd_csn),
        .sdram_wen(sd_wen), .sdram_rasn(sd_rasn), .sdram_casn(sd_casn),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_d(sd_d)
    );

    // The probe drives sdram_clk from its own input clock, so the model is
    // clocked from the pin rather than from `clk` - which is the wiring a
    // board has, and means a probe that forgot to drive the clock pin fails
    // here instead of on the bench.
    //
    // The reset comes out of the probe by hierarchical reference because the
    // probe makes its own from btn[1], and the model has to see the same one:
    // its refresh-gap check would otherwise fire part-way through the 100 us
    // power-up that a reset restarts. See sim/sdram_model.v's reset input.
    // 8 M words = 16 MB of byte address, which is what the probe's walking
    // address test needs: its top entry is byte address 1<<24. Costs the
    // simulator a few tens of megabytes and buys coverage of every address
    // line the controller drives.
    sdram_model #(.MEM_WORDS((1 << 23) + 16)) MEM (
        .clk(sd_clk), .rst(PROBE.rst), .cke(sd_cke), .cs_n(sd_csn), .ras_n(sd_rasn),
        .cas_n(sd_casn), .we_n(sd_wen),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_d)
    );

    localparam [4:0] ALL_PASS = 5'b11111;

    integer cycles = 0;
    always @(posedge clk) cycles = cycles + 1;

    task show(input [1023:0] name, input bit_val);
        begin
            $write("  %-40s", name);
            $display("%0s", bit_val ? "lit" : "DARK");
        end
    endtask

    initial begin
        $dumpfile("wave_ulx3s_sdram.vcd");
        $dumpvars(0, tb_ulx3s_sdram);

        $display("");
        $display("=== hardware SDRAM probe, in simulation ===");

        repeat (8) @(posedge clk);
        btn[1] = 1'b0;                 // release reset

        // The probe restarts forever, so wait for the first full pass rather
        // than for it to stop.
        while (led[4:0] !== ALL_PASS && cycles < 2_000_000)
            @(posedge clk);

        $display("");
        show("led[0]  controller finished power-up", led[0]);
        show("led[1]  single word read back", led[1]);
        show("led[2]  walking ones, all 32 bits", led[2]);
        show("led[3]  one address per address bit", led[3]);
        show("led[4]  survived idle - refresh works", led[4]);
        $display("");
        $display("  cycles: %0d, SDRAM refreshes issued: %0d",
                 cycles, MEM.refresh_count);
        $display("");

        if (led[4:0] === ALL_PASS) $display("SDRAM PROBE TEST PASSED");
        else                       $display("SDRAM PROBE TEST FAILED");
        $display("");
        $finish;
    end
endmodule
