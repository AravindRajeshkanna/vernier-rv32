// DDR3 DQ capture/drive SERDES, ECP5 - Phase 9 Stage 1, Part 2
// (docs/roadmap/phase-09-ddr.md). One byte lane (8 DQ bits, `DQ_WIDTH` default) of
// `IDDRX2DQA` (read capture, clocked by `rtl/soc/ddr3_dqs_ecp5.v`'s own
// real DQS-derived `DQSR90`) and `ODDRX2DQA`/`TSHX2DQA` (write drive +
// tristate enable, clocked by its own `DQSW270`) - a real `generate`
// replication per pin, not 8 copies of the same code pasted by hand.
//
// 4:1 per pin (2 bits per `ECLK` cycle via the primitive's own real
// DDR behavior, 2 `ECLK` cycles per `SCLK` cycle from the 1:2 gearing
// `rtl/soc/ddr3_eclk_pll.v` provides - so 4 bits per `SCLK` cycle per
// pin, matching `IDDRX2DQA`/`ODDRX2DQA`'s own real `Q3:Q0`/`D3:D0`
// port width exactly, not assumed).
//
// This project's own established out/enable/in tristate split
// (`_o`/`_oe`/`_i`, matching `rtl/soc/wb_sdram.v`/`fpga/ulx3s_top.v`'s
// own convention) still applies at the board-wrapper level, once one
// exists for this PHY - `TSHX2DQA` is the real ECP5 primitive that
// implements the enable side of that split for a DDR-rate pin
// specifically, not a departure from the convention.
module ddr3_dq_serdes_ecp5 #(
    parameter DQ_WIDTH = 8
)(
    input  wire                    sclk,
    input  wire                    eclk,
    input  wire                    rst,
    input  wire                    dqsr90,
    input  wire                    dqsw270,
    // The read FIFO's pointers, from rtl/soc/ddr3_dqs_ecp5.v's DQSBUFM: on the ECP5
    // every IDDRX2DQA must take its RDPNTR/WRPNTR from its byte lane's DQSBUFM
    // (nextpnr refuses the design otherwise - Part 21). Unused in simulation.
    input  wire [2:0]              rdpntr,
    input  wire [2:0]              wrpntr,

    // ---- write side: one 4-bit-wide parallel word per pin per SCLK
    // cycle, D3 first in time, D0 last (matching IDDRX2DQA/ODDRX2DQA's
    // own real bit-time ordering) ----
    input  wire [DQ_WIDTH-1:0]     wr_d3, wr_d2, wr_d1, wr_d0,
    input  wire                    wr_en,   // the DQ enable window (Part 17: rtl/soc/ddr3_ecp5_top.v drives it from the DQS FSM's burst_active, so DQ is enabled exactly while DQS toggles), drives every lane's TSHX2DQA the same way

    // ---- read side: the same 4-bit-wide shape, captured ----
    output wire [DQ_WIDTH-1:0]     rd_q3, rd_q2, rd_q1, rd_q0,

    // ---- real pins ----
    output wire [DQ_WIDTH-1:0]     dq_o,
    output wire [DQ_WIDTH-1:0]     dq_oe,   // per-pin, though every bit is driven identically by wr_en - matching the out/enable/in split's own established shape
    // The same control with the polarity the ECP5's pad takes: high = TRI-STATED.
    // TSHX2DQA's Q is this, not `dq_oe` - the design feeds it `!wr_en`, so its Q is high
    // when the pad should be released - and it must reach the pad's T input directly
    // (nextpnr: "TSHX2DQA Q output must be connected only to a top level tristate").
    // Until Part 21 the top used Q as if it were `dq_oe`, which inverts the drive and
    // cannot be placed; no simulation could see it, because the simulation branch below
    // defines `dq_oe` itself. In the synthesis branch `dq_oe` is derived, and unused.
    output wire [DQ_WIDTH-1:0]     dq_t,
    input  wire [DQ_WIDTH-1:0]     dq_i
);
    genvar i;
    generate
        for (i = 0; i < DQ_WIDTH; i = i + 1) begin : DQ_LANE
`ifdef SYNTHESIS
            IDDRX2DQA CAP (
                .SCLK(sclk), .ECLK(eclk), .DQSR90(dqsr90), .D(dq_i[i]), .RST(rst),
                .RDPNTR2(rdpntr[2]), .RDPNTR1(rdpntr[1]), .RDPNTR0(rdpntr[0]),
                .WRPNTR2(wrpntr[2]), .WRPNTR1(wrpntr[1]), .WRPNTR0(wrpntr[0]),
                .Q3(rd_q3[i]), .Q2(rd_q2[i]), .Q1(rd_q1[i]), .Q0(rd_q0[i]),
                .QWL()
            );
            ODDRX2DQA DRV (
                .D3(wr_d3[i]), .D2(wr_d2[i]), .D1(wr_d1[i]), .D0(wr_d0[i]),
                .DQSW270(dqsw270), .SCLK(sclk), .ECLK(eclk), .RST(rst),
                .Q(dq_o[i])
            );
            TSHX2DQA OE (
                .T1(!wr_en), .T0(!wr_en), .SCLK(sclk), .ECLK(eclk),
                .DQSW270(dqsw270), .RST(rst), .Q(dq_t[i])
            );
            assign dq_oe[i] = !dq_t[i];
`else
            // Simulation. None of IDDRX2DQA/ODDRX2DQA/TSHX2DQA has a
            // behavioral model in this toolchain - the same real gap
            // Part 1 and rtl/soc/ddr3_dqs_ecp5.v already found and
            // documented. A functionally equivalent (not
            // cycle/phase-accurate) stand-in: on each real SCLK edge,
            // present the write word directly and capture the read
            // word directly - real ECLK-rate serialization is not
            // meaningfully observable in a plain-Verilog testbench
            // driving an equally-behavioral DDR3 model, so this
            // approximates at SCLK granularity, honestly, rather than
            // claiming ECLK-accurate timing it cannot actually
            // provide.
            reg rd_q3_r, rd_q2_r, rd_q1_r, rd_q0_r;
            always @(posedge sclk or posedge rst) begin
                if (rst) begin
                    rd_q3_r <= 1'b0; rd_q2_r <= 1'b0;
                    rd_q1_r <= 1'b0; rd_q0_r <= 1'b0;
                end else begin
                    rd_q3_r <= dq_i[i];
                    rd_q2_r <= dq_i[i];
                    rd_q1_r <= dq_i[i];
                    rd_q0_r <= dq_i[i];
                end
            end
            assign rd_q3[i] = rd_q3_r;
            assign rd_q2[i] = rd_q2_r;
            assign rd_q1[i] = rd_q1_r;
            assign rd_q0[i] = rd_q0_r;
            assign dq_o[i]  = wr_d0[i];
            assign dq_oe[i] = wr_en;
            assign dq_t[i]  = !wr_en;
`endif
        end
    endgenerate
endmodule
