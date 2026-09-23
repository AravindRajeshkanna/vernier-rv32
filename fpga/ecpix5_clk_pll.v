// The ECPIX-5's own system clock is 100 MHz (real, cited pin K23 - see
// fpga/constraints/ecpix5.lpf's own header for the two independent
// sources that agree on this), far above what this design's own
// measured Fmax supports - fpga/README.md's own Fmax table puts
// CORE=inorder at 23.18-25.92 MHz on the existing ULX3S board, the
// same RTL this PLL's output feeds on ECPIX-5. Running the SoC directly
// off the raw 100 MHz oscillator would not be a slower, safer choice
// the way fpga/underclock_pll.v's own voluntary underclock is - it
// would be roughly 4x over the design's own real ceiling, guaranteed
// to fail timing, not just short of the board's own headroom.
//
// This derives 25 MHz instead - a clean 1/4 division, and the same
// frequency this project's whole software stack (CLK_HZ, baud-rate
// math, delay loops - see fpga/ulx3s_top.v's own default) is already
// calibrated to, so nothing downstream needs re-tuning for a new
// number the way a genuinely novel target frequency would.
//
// Generated with this project's own `ecppll` tool, the same discipline
// fpga/video_pll.v and fpga/underclock_pll.v's own headers state -
// never hand-picked:
//
//   ecppll -i 100 -n ecpix5_clk_pll --clkin_name clk_sys \
//       --clkout0_name clk_soc --clkout0 25 -f fpga/ecpix5_clk_pll.v
//
// Unlike fpga/underclock_pll.v's own 5 MHz target, this printed no
// warning - 25 MHz from a 100 MHz input is comfortably inside
// `ecppll`'s own normal operating range (VCO 600 MHz, CLKOP_DIV=24,
// both ordinary values).
//
// No `locked` gating, matching this project's own established
// convention for every other clock primitive it wraps - see
// fpga/video_out.v's own comment: "nothing here gates on lock ...
// don't either."
module ecpix5_clk_pll (
    input  wire clk_sys,   // 100 MHz, 0 deg - the board's own oscillator
    output wire clk_soc,   // 25 MHz, 0 deg
    output wire locked
);
`ifdef SYNTHESIS
    (* FREQUENCY_PIN_CLKI="100" *)
    (* FREQUENCY_PIN_CLKOP="25" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"), .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(4), .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(24),
        .CLKOP_CPHASE(11), .CLKOP_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(1)
    ) pll_i (
        .RST(1'b0), .STDBY(1'b0), .CLKI(clk_sys), .CLKOP(clk_soc),
        .CLKFB(clk_soc), .CLKINTFB(), .PHASESEL0(1'b0), .PHASESEL1(1'b0),
        .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0), .ENCLKOP(1'b0), .LOCK(locked)
    );
`else
    // Behavioral divide-by-4: a comparator-based shape, not a
    // toggle-based one - fpga/underclock_pll.v's own header explains
    // why a toggle (`clk_soc_r <= ~clk_soc_r` on wraparound) silently
    // doubles the real output period instead of dividing by the
    // counter's own modulus. Single tap off the real clk_sys input,
    // matching underclock_pll.v's own simulation model shape, not a
    // self-generated free-running reference.
    reg       clk_soc_r = 1'b0;
    reg [1:0] div_count = 2'd0;
    reg       locked_r  = 1'b0;
    always @(posedge clk_sys) begin
        div_count <= (div_count == 2'd3) ? 2'd0 : div_count + 2'd1;
        clk_soc_r <= (div_count < 2'd2);
    end
    initial begin
        repeat (8) @(posedge clk_sys);
        locked_r = 1'b1;
    end
    assign clk_soc = clk_soc_r;
    assign locked  = locked_r;
`endif
endmodule
