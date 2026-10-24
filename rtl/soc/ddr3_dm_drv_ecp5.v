// DDR3 data-mask (DM) drive, ECP5 - Phase 9 Stage 1, Part 22 (docs/roadmap/phase-09-ddr.md).
//
// Through Part 21 this design had no data-mask pin at all: every write burst drove
// all eight real UI with the same one byte (rtl/soc/ddr3_ecp5_top.v's `dq_data_hold`,
// broadcast to `wr_d3`..`wr_d0` unchanged), and nothing told the DRAM which of those
// UI to actually accept. Micron's own datasheet: "Input data is masked when DM is
// sampled HIGH along with the input data during a write access." Left undriven
// (or driven low throughout, which is the same as never masking), a real BL8 write
// therefore does not write one byte to one column - it writes the same byte to eight
// sequential columns, silently overwriting seven real neighbours every time. That is
// a correctness defect, not a missing nicety: `sim/ddr3_dq_model.v`'s own header has
// said as much since Part 15 ("a byte-granular write on real hardware needs the data
// mask ... with the burst started at the wanted column") without anything acting on it.
//
// Unlike DQ, DM is FPGA-output-only on this part: the DRAM never drives it back, so
// there is no tri-state to arbitrate and no read capture to provide - `ODDRX2DQA`
// alone, clocked the same way `rtl/soc/ddr3_dq_serdes_ecp5.v`'s own write side is
// (`DQSW270`, the same clock DQ's data uses), continuously driven rather than gated by
// an enable. Lattice's own FPGA-TN-02035, section 6.3.3/Figure 6.9, groups DM with DQ
// under the same `ODDRX2DQA`-generated write side for exactly this reason.
//
// ---- Phase 9 Stage 3: a mask per unit interval ----
// Through Phase 9 Stage 2 `dm_level` was ONE value per sclk cycle, broadcast to all four UI that cycle covers (the
// four `ODDRX2DQA` inputs below were tied together), so a "single-column" write that kept DM low for the first sclk cycle
// of the burst kept it low for four beats: on a real part that writes the same byte to FOUR columns, beats 0 to 3
// (sequential order, wrapping inside the aligned block of 8), and the Wishbone slave's eight column stores per block
// clobber each other. The simulation could not show it: its data path was one value per sclk. `dm_mask` is now one bit
// per UI: bit k is the mask for the k-th UI of the cycle (1 = masked, DM high, the DRAM ignores that beat; 0 = written),
// D0 first, the order DQ's own `ODDRX2DQA` and the strobe's use. A write of one column keeps DM low for beat 0 only.
module ddr3_dm_drv_ecp5 (
    input  wire sclk,
    input  wire eclk,
    input  wire rst,
    input  wire dqsw270,

    input  wire [3:0] dm_mask,  // bit k: 1 = mask (DM high, the DRAM ignores UI k of this cycle), 0 = write (DM low); UI 0 first
    output wire dm_o            // the real DM pin
);
`ifdef SYNTHESIS
    ODDRX2DQA DRV (
        .D3(dm_mask[3]), .D2(dm_mask[2]), .D1(dm_mask[1]), .D0(dm_mask[0]),
        .DQSW270(dqsw270), .SCLK(sclk), .ECLK(eclk), .RST(rst),
        .Q(dm_o)
    );
`else
    // Simulation. ODDRX2DQA has no behavioral model in this toolchain (the same real gap every other DDR-I/O primitive in
    // this stage found), so this does what it does at the pin: one value per UI, four per sclk, D0 first. The UI grid of
    // the data pins is shifted a quarter of CK (5 ns) later than the strobe's, so that each strobe edge falls in the middle
    // of a data beat: DQ and DM are launched 5, 15, 25 and 35 ns after the sclk edge (rtl/soc/ddr3_dqs_write_ecp5.v has the
    // strobe, at 0, 10, 20 and 30). Designed, not derived: where the ECP5's DQSW and DQSW270 put these on silicon is the
    // bring-up's to show. The mask for the cycle is read when each UI is launched, from the signals the design drives for
    // that cycle (they are settled after the edge), which is the alignment the passthrough this replaces had.
    reg dm_r;
    initial dm_r = 1'b1;
    always @(posedge sclk) begin
        #5  dm_r <= dm_mask[0];
        #10 dm_r <= dm_mask[1];
        #10 dm_r <= dm_mask[2];
        #10 dm_r <= dm_mask[3];
    end
    assign dm_o = dm_r;

    wire _unused_ok = &{1'b0, rst, eclk, dqsw270, 1'b0};
`endif
endmodule
