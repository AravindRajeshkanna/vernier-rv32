// What the ECPIX-5's status LEDs say about the DDR3 controller - Phase 9 Stage 3.
//
// A board that has never been loaded, with nothing coming out of its UART, tells you nothing: the CPU may be dead, the
// serial port may be on another channel, or the controller may never have come up. The controller itself starts without
// the CPU (initialisation, then each byte lane's read calibration), and seven of its signals say how far it got. This turns
// them into colours, so that the first thing to look at is the board.
//
// Three LEDs, one stage each, and one colour per state:
//
//   LED0  the controller's clocks and the DRAM's initialisation
//           dark   the controller's PLL has not locked (the FPGA is configured, the controller has not started)
//           red    the PLL is locked and the DLL is not: a fault if it stays
//           blue   both locked, the DRAM's power-up sequence is running (JEDEC's 500 us wait, then the mode registers)
//           green  initialisation done
//   LED1  lane 0's read calibration,  LED3  lane 1's
//           dark   waiting: calibration is held in reset until the initialisation is done
//           blue   sweeping the eight capture taps for one that reads a pattern back
//           green  calibrated: a tap reads the pattern back through the DRAM and the board's traces
//           red    every tap failed: nothing came back (no DRAM, no strobe, a wrong or open pin)
//
// A good board is three green LEDs about half a millisecond after the board's reset: in simulation (sim/tb_ecpix5.v) the
// initialisation is done 522 us after it and each lane calibrates within 1 us of that. So the blue states are not seen
// going by (the longest is 522 us); a blue that stays is the finding. The rest is in fpga/README.md: what each colour says
// to do next. LED2's green is the CPU's heartbeat (fpga/ecpix5_top.v) and has nothing to do with this.
//
// What it is not. Green on a lane means a read tap was found against a pattern the lane wrote itself, so the pins, the
// strobe and the DRAM answered; it is not a memory test and says nothing about refresh over time or about any address
// but the one the calibration used. Dark and blue are told apart from "the FPGA has no bitstream" only by LED2 blinking.
//
// Inputs are rtl/soc/soc_top.v's ddr3_status: [0] pll_locked, [1] dll_locked, [2] init_ready, [3] calib_done,
// [4] calib_error, [5] calib1_done, [6] calib1_error. Outputs are {blue, green, red}, 1 = lit; the polarity of the
// board's LEDs is fpga/ecpix5_top.v's to know. Combinational on purpose: the inputs come from the controller's own clock
// domains and stay put once reached, so a decoder that sampled them in a third domain would be a crossing for nothing,
// and a glitch for a few nanoseconds on an LED nobody can see is not a fault.
module ecpix5_ddr3_leds (
    input  wire [6:0] ddr3_status,
    output wire [2:0] led_ctl_rgb,    // LED0
    output wire [2:0] led_l0_rgb,     // LED1
    output wire [2:0] led_l1_rgb      // LED3
);
    localparam [2:0] DARK = 3'b000, RED = 3'b001, GREEN = 3'b010, BLUE = 3'b100;    // {blue, green, red}

    wire pll_locked  = ddr3_status[0];
    wire dll_locked  = ddr3_status[1];
    wire init_ready  = ddr3_status[2];
    wire calib_done  = ddr3_status[3];
    wire calib_error = ddr3_status[4];
    wire calib1_done = ddr3_status[5];
    wire calib1_error = ddr3_status[6];

    // An error is red whatever else is set: the two cannot both be (a lane ends in one state or the other), and if they
    // ever were, the LED must say the bad thing.
    function [2:0] lane(input init, input done, input err);
        lane = !init ? DARK : err ? RED : done ? GREEN : BLUE;
    endfunction

    assign led_ctl_rgb = !pll_locked ? DARK : !dll_locked ? RED : !init_ready ? BLUE : GREEN;
    assign led_l0_rgb  = lane(init_ready, calib_done,  calib_error);
    assign led_l1_rgb  = lane(init_ready, calib1_done, calib1_error);
endmodule
