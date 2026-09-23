// DDR3 PHY edge-clock PLL - Phase 9 Stage 1, Part 2 (docs/roadmap.md).
//
// ---- Why a second, DDR3-PHY-scoped PLL, rather than reusing the SoC's
// own existing clock ----
// `IDDRX2DQA`/`ODDRX2DQA`/`ODDRX2DQSB`/`TSHX2DQA`/`TSHX2DQSA` (the DQ/
// DQS capture and drive primitives Part 2 needs) each take *two*
// separate clock inputs, `SCLK` (the fabric-rate clock) and `ECLK`
// (a pin-rate edge clock at twice `SCLK`'s own frequency) - a real,
// local 1:2 relationship these specific primitives require, confirmed
// against this toolchain's own blackbox declarations, and a
// genuinely different thing from `rtl/soc/ddr3_phy_ecp5.v`'s own
// Part 1 design, where command/address and `CK`/`CK#` share one
// clock (correct there: DDR3 command/address is single-data-rate,
// sampled once per real `CK` edge, so no 2x relationship is needed for
// that path at all).
//
// A second, DDR3-PHY-scoped PLL - rather than deriving `ECLK` from the
// SoC's own main clock some other way, or making the SoC's own main
// clock depend on this PHY - keeps the blast radius contained to the
// new DDR3 PHY files only. Both outputs come from the *same* PLL
// instance (`CLKOP`=`eclk`, `CLKOS`=`sclk`), so they are phase-locked
// to each other by construction, not just nominally the same
// frequency ratio - the same "one real oscillator, multiple real taps"
// discipline `fpga/video_pll.v` and `fpga/underclock_pll.v` already
// established for this project's other PLL wrappers.
//
// Generated with this project's own `ecppll` tool, never hand-picked:
//
//   ecppll -i 25 -n ddr3_eclk_pll --clkin_name clk --clkout0_name eclk \
//       --clkout0 50 --clkout1_name sclk --clkout1 25 \
//       -f rtl/soc/ddr3_eclk_pll.v
//
// No warning this time (unlike fpga/underclock_pll.v's own 5 MHz
// target) - 50/25 MHz from a 25 MHz input are both comfortably inside
// `ecppll`'s normal range. `clk` here is this project's own existing
// 25 MHz system clock (matching every other board target's own
// default) - not the real DDR3 CK frequency Part 1's own
// `rtl/soc/ddr3_phy_ecp5.v` drives the DRAM at; reconciling the two
// (this PHY's own internal SCLK/ECLK pair vs. Part 1's own single
// `clk`) is real, deliberate, later work once this narrow slice's own
// mechanism is proven, not assumed correct here.
//
// No `locked` gating, matching this project's own established
// convention for every other clock primitive it wraps.
module ddr3_eclk_pll #(
    // Simulation only - must match the real period of whatever `clk`
    // this module is actually driven with in a given testbench. Real
    // hardware needs no such parameter (`clk`'s real frequency is
    // fixed by the board oscillator and PLL config above); this one
    // exists purely so the behavioral `eclk` generator below can be a
    // plain, unambiguous delay-based square wave rather than a
    // combinational construction derived from `clk`'s own edges - a
    // first attempt at the latter was tried and found to produce a
    // degenerate, near-zero-duration glitch instead of a real clock
    // edge (caught by tracing a real simulation run, not assumed
    // correct from the Verilog alone), the same "verify, don't trust
    // your own construction" discipline `fpga/underclock_pll.v`'s own
    // header already documents finding a real bug this same way.
    parameter CLK_PERIOD_NS = 40   // 40 ns = 25 MHz, this project's own default
)(
    input  wire clk,     // this project's own existing 25 MHz system clock
    output wire eclk,    // 50 MHz, 0 deg - the DQ/DQS primitives' own edge clock
    output wire sclk,    // 25 MHz, 0 deg - the DQ/DQS primitives' own fabric clock
    output wire locked
);
`ifdef SYNTHESIS
    (* FREQUENCY_PIN_CLKI="25" *)
    (* FREQUENCY_PIN_CLKOP="50" *)
    (* FREQUENCY_PIN_CLKOS="25" *)
    (* ICP_CURRENT="12" *) (* LPF_RESISTOR="8" *) (* MFG_ENABLE_FILTEROPAMP="1" *) (* MFG_GMCREF_SEL="2" *)
    EHXPLLL #(
        .PLLRST_ENA("DISABLED"), .INTFB_WAKE("DISABLED"),
        .STDBY_ENABLE("DISABLED"), .DPHASE_SOURCE("DISABLED"),
        .OUTDIVIDER_MUXA("DIVA"), .OUTDIVIDER_MUXB("DIVB"),
        .OUTDIVIDER_MUXC("DIVC"), .OUTDIVIDER_MUXD("DIVD"),
        .CLKI_DIV(1),
        .CLKOP_ENABLE("ENABLED"), .CLKOP_DIV(12),
        .CLKOP_CPHASE(5), .CLKOP_FPHASE(0),
        .CLKOS_ENABLE("ENABLED"), .CLKOS_DIV(24),
        .CLKOS_CPHASE(5), .CLKOS_FPHASE(0),
        .FEEDBK_PATH("CLKOP"), .CLKFB_DIV(2)
    ) pll_i (
        .RST(1'b0), .STDBY(1'b0), .CLKI(clk),
        .CLKOP(eclk), .CLKOS(sclk), .CLKFB(eclk), .CLKINTFB(),
        .PHASESEL0(1'b0), .PHASESEL1(1'b0),
        .PHASEDIR(1'b1), .PHASESTEP(1'b1), .PHASELOADREG(1'b1),
        .PLLWAKESYNC(1'b0), .ENCLKOP(1'b0), .LOCK(locked)
    );
`else
    // Simulation. `eclk` is a plain, unambiguous delay-based square
    // wave at exactly 2x `clk`'s own rate (real period, not derived
    // from `clk`'s own edges - see CLK_PERIOD_NS's own header comment
    // for why). `sclk` is simply `clk` passed through unchanged (both
    // PLL outputs share the same real VCO in hardware; in simulation,
    // tying sclk directly to clk is the simpler, exactly equivalent
    // behavioral stand-in - no separate divider needed since there is
    // nothing here to divide).
    reg eclk_r = 1'b0;
    always #(CLK_PERIOD_NS / 4) eclk_r = ~eclk_r;
    assign eclk = eclk_r;
    assign sclk = clk;

    reg locked_r = 1'b0;
    initial begin
        repeat (8) @(posedge clk);
        locked_r = 1'b1;
    end
    assign locked = locked_r;
`endif
endmodule
