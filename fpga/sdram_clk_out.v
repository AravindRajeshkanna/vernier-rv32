// The SDRAM's clock output pin, and the phase it is given.
//
// Shared by fpga/ulx3s_top.v and fpga/ulx3s_sdram.v so that the two cannot
// drift apart: a probe that clocks the part differently from the SoC would
// pass and prove nothing about the SoC, which is the one failure a bring-up
// instrument must not have.
//
// ---- Why this is not `assign sdram_clk = clk` ----
//
// It was, and the board said no. `make sim_sdramcheck` passes, the pins are
// right, and on hardware a 256 KB sweep came back with single-bit errors -
// one word in roughly a thousand, a different bit each time, and the value
// read matching no other address in the sweep, so not aliasing. See
// fpga/README.md for the log.
//
// Driving the pin straight from the input clock routes it: input pad ->
// global buffer -> output pad. The design's own flops clock off that same
// global net, so **the data leaves the FPGA at the same moment the clock
// edge does**. The part therefore sees them edge-aligned and has essentially
// no setup time: it captures whatever the bus happens to be doing while it is
// still changing. A bit that does not change is captured correctly, which is
// why walking ones passed and a pseudo-random sweep did not.
//
// The fix is to move the clock the part sees half a period away from the
// moment the data changes. `ODDRX1F` with D0=0 and D1=1 emits a clock whose
// rising edge lands on the internal clock's *falling* edge - 180 degrees, or
// 20 ns at 25 MHz - so:
//
//   writes  data launched on the rising edge has half a period to settle
//           before the part samples it
//   reads   data launched by the part on its edge has half a period to get
//           back before the FPGA samples it
//
// and it does that in the IO logic, where the delay is fixed and known,
// rather than through general fabric routing.
//
// ---- There is no knob for the old behaviour ----
//
// An aligned clock is not a slower configuration, it is a broken one, and it
// is only half of the change: rtl/soc/wb_sdram.v's read capture point moved
// by a cycle to match this, so the two are a matched pair. A build option
// that selected the aligned clock would select a design whose read timing is
// then wrong by a full cycle rather than by 5.4 ns - worse than what the
// board did, and not a reproduction of it. The failing configuration is
// recorded in fpga/README.md, which is where it belongs.
module sdram_clk_out (
    input  wire clk,
    output wire sdram_clk
);
`ifdef SYNTHESIS
    ODDRX1F clkout (
        .SCLK(clk),
        .RST(1'b0),
        .D0(1'b0),      // first half of the period: low
        .D1(1'b1),      // second half: high -> rising edge at clk's falling edge
        .Q(sdram_clk)
    );
`else
    // Simulation. ODDRX1F is an ECP5 primitive with no model here, and what
    // matters to a testbench is the phase rather than the IO path - so this
    // is the inversion the ODDR produces, and sim/tb_ulx3s.v asserts it
    // rather than taking it on trust.
    assign sdram_clk = ~clk;
`endif
endmodule
