// DDR3 data-mask (DM) drive, ECP5 - Phase 9 Stage 1, Part 22 (docs/roadmap.md).
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
// Scope, at this design's own established sclk resolution (rtl/soc/ddr3_dq_serdes_ecp5.v's
// header: "real ECLK-rate serialization is not meaningfully observable ... this
// approximates at SCLK granularity"): `dm_level` is one value per sclk cycle, broadcast
// to all four UI that cycle covers, exactly the way `dq_data_hold` broadcasts one byte
// to `wr_d3`..`wr_d0`. So this does not achieve real per-UI masking (DM high on seven
// of eight UI, low on the eighth) - it achieves the honest analogue this project has
// used throughout: DM low during the sclk cycle this design treats as the addressed
// column (rtl/soc/ddr3_ecp5_top.v drives it from `active0`, Part 22), high during the
// other. Real per-UI fidelity needs the beat-level resolution this project does not
// model, named as still open in every account since Part 15's survey.
module ddr3_dm_drv_ecp5 (
    input  wire sclk,
    input  wire eclk,
    input  wire rst,
    input  wire dqsw270,

    input  wire dm_level,   // 1 = mask (DM high, do not write this cycle's UI), 0 = write (DM low)
    output wire dm_o        // the real DM pin
);
`ifdef SYNTHESIS
    ODDRX2DQA DRV (
        .D3(dm_level), .D2(dm_level), .D1(dm_level), .D0(dm_level),
        .DQSW270(dqsw270), .SCLK(sclk), .ECLK(eclk), .RST(rst),
        .Q(dm_o)
    );
`else
    // Simulation. ODDRX2DQA has no behavioral model in this toolchain (the same real
    // gap every other DDR-I/O primitive in this stage already found) - combinational
    // passthrough at sclk granularity, the same stand-in
    // rtl/soc/ddr3_dq_serdes_ecp5.v's own simulation body uses for DQ
    // (`assign dq_o[i] = wr_d0[i];`) and rtl/soc/ddr3_dqs_write_ecp5.v's own simulation
    // body uses for DQS (`assign dqs_o = d[3];`). A first version registered this
    // instead, and a real run caught it: DM then read the PREVIOUS cycle's `dm_level`,
    // one `sclk` late against the state register `active0` is read from directly -
    // masked exactly where it should write and vice versa.
    assign dm_o = dm_level;

    wire _unused_ok = &{1'b0, rst, eclk, dqsw270, 1'b0};
`endif
endmodule
