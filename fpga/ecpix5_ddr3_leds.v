// What the ECPIX-5's status LEDs say about the DDR3 controller - Phase 9 Stage 3.
//
// A board that has never been loaded, with nothing coming out of its UART, tells you nothing: the CPU may be dead, the
// serial port may be on another channel, or the controller may never have come up. The controller itself starts without
// the CPU (initialisation, then each byte lane's read calibration), and eight of its signals say how far it got. This turns
// them into colours, so that the first thing to look at is the board.
//
// Three LEDs, one stage each, and one colour per state (the one mixed colour is LED0's yellow, below):
//
//   LED0  the controller's clocks and the DRAM's initialisation
//           dark   the controller's PLL has not locked (the FPGA is configured, the controller has not started)
//           red    the PLL is locked and the DLL is not: a fault if it stays
//           blue   both locked, the DRAM's power-up sequence is running (JEDEC's 500 us wait, then the mode registers)
//           green  initialisation done
//           yellow initialisation done and, since the board's reset, a read of the DRAM came back without its data (the
//                  controller rejected it, rtl/soc/wb_ddr.v counts them): the one mixed colour here, because the four single
//                  ones were taken, and it stays until the board is reset. The access was acknowledged with stale data.
//   LED1  lane 0's read calibration,  LED3  lane 1's
//           dark   waiting: calibration is held in reset until the initialisation is done
//           blue   sweeping the eight capture taps for one that reads a pattern back
//           green  calibrated: a pattern written to the DRAM came back right through the lane's pins at some tap
//           red    every tap failed: nothing came back right (no DRAM behind the lane, a wrong or open DQ or DQS pin, a strobe that
//                  never reaches the capture)
//
// In simulation (sim/tb_ecpix5.v) the three go green about half a millisecond after the board's reset: the initialisation is
// done 522 us after it and each lane calibrates within 2 us of that. So the blue states are not seen going by (the longest
// is 522 us); a blue that stays is the finding. The rest is in fpga/README.md: what each colour says
// to do next. LED2's green is the CPU's heartbeat (fpga/ecpix5_top.v) and has nothing to do with this.
//
// What it is not. Green on a lane means the sweep (rtl/soc/ddr3_read_calib.v) wrote a known pattern to one column of the DRAM,
// with a real ACTIVATE and WRITE, and read it back at a tap with a real ACTIVATE and READ, and got the pattern and the
// DQSBUFM's `datavalid`. So the DRAM took part: the lane's DQ pins and the command pins were good enough for that. It is not a
// memory test (one column, two bytes), it says nothing about refresh over time, and the tap is the first that passed, the edge
// of the valid window and not its middle. In simulation the DQSBUFM is a stand-in that does not look at the DQS pin, so the
// strobe's own path is not shown here. (Through Phase 9 Stage 2 the sweep injected its pattern onto the pins and sent the DRAM
// no command, and green meant none of this: docs/roadmap/phase-09-ddr.md.) Dark and blue are told apart from "the FPGA has no
// bitstream" only by LED2 blinking.
//
// Inputs are rtl/soc/soc_top.v's ddr3_status: [0] pll_locked, [1] dll_locked, [2] init_ready, [3] calib_done,
// [4] calib_error, [5] calib1_done, [6] calib1_error, [7] read_rejected. Outputs are {blue, green, red}, 1 = lit; the polarity of the
// board's LEDs is fpga/ecpix5_top.v's to know. Combinational on purpose: the inputs come from the controller's own clock
// domains and stay put once reached, so a decoder that sampled them in a third domain would be a crossing for nothing,
// and a glitch for a few nanoseconds on an LED nobody can see is not a fault.
module ecpix5_ddr3_leds (
    input  wire [7:0] ddr3_status,
    output wire [2:0] led_ctl_rgb,    // LED0
    output wire [2:0] led_l0_rgb,     // LED1
    output wire [2:0] led_l1_rgb      // LED3
);
    localparam [2:0] DARK = 3'b000, RED = 3'b001, GREEN = 3'b010, BLUE = 3'b100;    // {blue, green, red}
    localparam [2:0] YELLOW = RED | GREEN;

    wire pll_locked  = ddr3_status[0];
    wire dll_locked  = ddr3_status[1];
    wire init_ready  = ddr3_status[2];
    wire calib_done  = ddr3_status[3];
    wire calib_error = ddr3_status[4];
    wire calib1_done = ddr3_status[5];
    wire calib1_error = ddr3_status[6];
    wire read_rejected = ddr3_status[7];

    // An error is red whatever else is set: the two cannot both be (a lane ends in one state or the other), and if they
    // ever were, the LED must say the bad thing.
    function [2:0] lane(input init, input done, input err);
        lane = !init ? DARK : err ? RED : done ? GREEN : BLUE;
    endfunction

    // The rejected-read bit only counts once the controller is up: it cannot be set earlier (a read needs both lanes calibrated),
    // and if it ever were, the stage the controller is stuck at is what the LED must show.
    assign led_ctl_rgb = !pll_locked ? DARK : !dll_locked ? RED : !init_ready ? BLUE : read_rejected ? YELLOW : GREEN;
    assign led_l0_rgb  = lane(init_ready, calib_done,  calib_error);
    assign led_l1_rgb  = lane(init_ready, calib1_done, calib1_error);
endmodule
