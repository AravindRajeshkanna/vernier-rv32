// DDR3 read-burst active-window extender - Phase 9 Stage 1, Part 8
// (docs/roadmap.md). Converts `rtl/soc/ddr3_read_seq.v`'s own single-
// cycle `read_start` pulse into a real, held-high `read_active` signal
// spanning this design's own real burst-length-8 duration -
// reconciling a real mismatch Part 7's own header named explicitly:
// `ddr3_read_seq.v`'s `read_start` pulses once, CL-aligned, but
// `rtl/soc/ddr3_dqs_ecp5.v`'s own `read_active` input needs to stay
// high for the whole real capture window, not pulse once, for its
// real `DQSBUFM` wiring (`READ0`/`READ1`) to work.
//
// ---- Why 2 cycles, not 1 ----
// Burst length 8 (BL8, this design's own fixed choice - see
// `rtl/soc/ddr3_init_seq.v`'s own MR0) is 8 UI. `rtl/soc/
// ddr3_dq_serdes_ecp5.v`'s own header already establishes this
// design's real 4:1 `SCLK`:UI ratio (`IDDRX2DQA`/`ODDRX2DQA`'s own
// real 4-bit-wide `D3:D0`/`Q3:Q0` ports), so one full BL8 burst spans
// exactly 8/4 = 2 real `SCLK` cycles - the same arithmetic
// `rtl/soc/ddr3_dqs_write_ecp5.v`'s own two `S_ACTIVE0`/`S_ACTIVE1`
// states already use for the write side.
//
// ---- Scope: this proves the extension mechanism, not a full
// integration yet ----
// Proven standalone first, matching every part in this stage's own
// "narrow proof first" discipline - not yet wired into
// `rtl/soc/ddr3_ecp5_top.v`. Wiring `rtl/soc/ddr3_write_seq.v` and
// `rtl/soc/ddr3_read_seq.v` into that top-level module (alongside
// `rtl/soc/ddr3_read_calib.v`'s own existing direct-injection
// calibration path, not replacing it - calibration still needs its
// own simple mechanism to find a working `READCLKSEL` tap before any
// command-driven read/write can be trusted) is later, separate work.
// The write side needs no equivalent extender:
// `rtl/soc/ddr3_dqs_write_ecp5.v` already takes `write_start` as a
// single-cycle pulse directly and handles its own real multi-cycle
// preamble/active/postamble timing internally - only the read side's
// own `read_active` input has this real shape mismatch.
module ddr3_read_burst_ext (
    input  wire clk,
    input  wire rst,

    input  wire read_start,   // single-cycle pulse from ddr3_read_seq.v
    output wire read_active   // held high for BURST_CYC real sclk cycles
);
    // BURST_CYC (2) real sclk cycles total: the live pulse itself,
    // plus one delayed copy - not a parameterized shift register (this
    // design's own BL8/4:1 ratio fixes the real answer at exactly 2,
    // not a value meant to be tuned), so the width math cannot go
    // wrong the way a generalized N-cycle version's own off-by-one
    // indexing could.
    reg delay_r;

    always @(posedge clk or posedge rst) begin
        if (rst) delay_r <= 1'b0;
        else     delay_r <= read_start;
    end

    assign read_active = read_start || delay_r;
endmodule
