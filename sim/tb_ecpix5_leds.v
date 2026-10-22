// Test for fpga/ecpix5_ddr3_leds.v: what the ECPIX-5's three controller LEDs say for every value of the status bus.
//
// The decoder is a pure function of seven bits, so the test is the whole of its domain: 128 values, each checked against
// properties that do not repeat the decoder's own expressions, and then a list of named situations, read as a person
// reading the board would read them.
//
//   - A LED never shows two colours at once: a mixed colour (red and green make yellow on these LEDs) would be a state
//     the README's table does not have, and nobody could tell it from a fault.
//   - Nothing is lit before the controller's PLL has locked: that is what "the FPGA is configured and the controller has
//     not started" looks like, and it must look different from every state in which it has.
//   - A lane's LED is dark until the DRAM's initialisation is done: calibration is held in reset until then
//     (rtl/soc/ddr3_ecp5_top.v), so a lane cannot have anything to say.
//   - A lane that reports an error is red, whatever else its bits say (an error and a done at once cannot happen, and
//     if they ever did the LED must say the bad thing).
//
// Status bus, rtl/soc/soc_top.v's ddr3_status: [0] pll_locked, [1] dll_locked, [2] init_ready, [3] calib_done,
// [4] calib_error, [5] calib1_done, [6] calib1_error. Outputs are {blue, green, red}, 1 = lit.
`timescale 1ns/1ps
module tb_ecpix5_leds;
    reg  [6:0] st;
    wire [2:0] ctl, l0, l1;
    ecpix5_ddr3_leds DUT (.ddr3_status(st), .led_ctl_rgb(ctl), .led_l0_rgb(l0), .led_l1_rgb(l1));

    localparam OFF = 3'b000, RED = 3'b001, GREEN = 3'b010, BLUE = 3'b100;   // {blue, green, red}

    integer errors = 0, i;

    function onehot_or_zero(input [2:0] c);
        onehot_or_zero = (c == 3'b000) || (c == 3'b001) || (c == 3'b010) || (c == 3'b100);
    endfunction

    task say(input [511:0] what, input [2:0] got_ctl, input [2:0] want_ctl, input [2:0] got_l0, input [2:0] want_l0,
             input [2:0] got_l1, input [2:0] want_l1);
        begin
            if (got_ctl !== want_ctl || got_l0 !== want_l0 || got_l1 !== want_l1) begin
                $display("  FAIL %0s: controller/lane0/lane1 = %b/%b/%b, expected %b/%b/%b", what,
                         got_ctl, got_l0, got_l1, want_ctl, want_l0, want_l1);
                errors = errors + 1;
            end else
                $display("  ok   %0s", what);
        end
    endtask

    task situation(input [511:0] what, input [6:0] bits, input [2:0] want_ctl, input [2:0] want_l0, input [2:0] want_l1);
        begin
            st = bits; #1;
            say(what, ctl, want_ctl, l0, want_l0, l1, want_l1);
        end
    endtask

    initial begin
        $display("=== ECPIX-5 controller LEDs ===");

        // ---- the properties, over every value ----
        for (i = 0; i < 128; i = i + 1) begin
            st = i[6:0]; #1;
            if (!onehot_or_zero(ctl) || !onehot_or_zero(l0) || !onehot_or_zero(l1)) begin
                $display("  FAIL status %b shows a mixed colour: %b/%b/%b", st, ctl, l0, l1);
                errors = errors + 1;
            end
            if (!st[0] && (ctl !== OFF)) begin
                $display("  FAIL status %b: the controller LED is lit before its PLL has locked: %b", st, ctl);
                errors = errors + 1;
            end
            if (!st[2] && (l0 !== OFF || l1 !== OFF)) begin
                $display("  FAIL status %b: a lane LED is lit before initialisation is done: %b/%b", st, l0, l1);
                errors = errors + 1;
            end
            if (st[2] && st[4] && l0 !== RED) begin
                $display("  FAIL status %b: lane 0 has an error and is not red: %b", st, l0);
                errors = errors + 1;
            end
            if (st[2] && st[6] && l1 !== RED) begin
                $display("  FAIL status %b: lane 1 has an error and is not red: %b", st, l1);
                errors = errors + 1;
            end
            if (st[2] && st[3] && !st[4] && l0 !== GREEN) begin
                $display("  FAIL status %b: lane 0 is calibrated and is not green: %b", st, l0);
                errors = errors + 1;
            end
            if (st[2] && st[5] && !st[6] && l1 !== GREEN) begin
                $display("  FAIL status %b: lane 1 is calibrated and is not green: %b", st, l1);
                errors = errors + 1;
            end
            // each lane depends on its own bits and not the other lane's
            if (l0 !== DUT_LANE_REF(st[2], st[3], st[4])) begin
                $display("  FAIL status %b: lane 0 = %b, expected %b from its own bits", st, l0, DUT_LANE_REF(st[2], st[3], st[4]));
                errors = errors + 1;
            end
            if (l1 !== DUT_LANE_REF(st[2], st[5], st[6])) begin
                $display("  FAIL status %b: lane 1 = %b, expected %b from its own bits", st, l1, DUT_LANE_REF(st[2], st[5], st[6]));
                errors = errors + 1;
            end
        end
        $display("  (128 values checked against the properties)");

        // ---- the situations, in the order a board goes through them ----
        //                                        status {c1err,c1done,cerr,cdone,init,dll,pll}   controller lane0  lane1
        situation("power-up, nothing started",               7'b0000000, OFF,   OFF,   OFF);
        situation("PLL locked, DLL not (a fault if it stays)", 7'b0000001, RED,   OFF,   OFF);
        situation("PLL and DLL locked, initialising",         7'b0000011, BLUE,  OFF,   OFF);
        situation("initialisation done, lanes sweeping",      7'b0000111, GREEN, BLUE,  BLUE);
        situation("lane 0 calibrated, lane 1 sweeping",       7'b0001111, GREEN, GREEN, BLUE);
        situation("lane 1 calibrated, lane 0 sweeping",       7'b0100111, GREEN, BLUE,  GREEN);
        situation("both lanes calibrated: the good board",    7'b0101111, GREEN, GREEN, GREEN);
        situation("lane 1 failed, lane 0 calibrated",         7'b1001111, GREEN, GREEN, RED);
        situation("lane 0 failed, lane 1 calibrated",         7'b0110111, GREEN, RED,   GREEN);
        situation("both lanes failed (no DRAM, or no clock)", 7'b1010111, GREEN, RED,   RED);
        situation("an error beats a done, lane 0",            7'b0011111, GREEN, RED,   BLUE);
        situation("an error beats a done, lane 1",            7'b1100111, GREEN, BLUE,  RED);
        situation("PLL bit low, the rest set: controller dark",  7'b0101110, OFF,   GREEN, GREEN);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("ECPIX5 LEDS TEST PASSED");
        else             $display("ECPIX5 LEDS TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    // A lane's colour from its three bits alone, written as a table and not as the decoder writes it.
    function [2:0] DUT_LANE_REF(input init, input done, input err);
        begin
            case ({init, err, done})
                3'b000, 3'b001, 3'b010, 3'b011: DUT_LANE_REF = OFF;     // initialisation not done
                3'b100:                         DUT_LANE_REF = BLUE;    // sweeping
                3'b101:                         DUT_LANE_REF = GREEN;   // calibrated
                3'b110, 3'b111:                 DUT_LANE_REF = RED;     // error, whatever else
            endcase
        end
    endfunction
endmodule
