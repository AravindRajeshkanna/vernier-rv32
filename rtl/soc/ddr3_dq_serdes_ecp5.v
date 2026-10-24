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
    // cycle, D0 first in time, D3 last. (This comment said the opposite until
    // Phase 9 Stage 3. D0 first is the order LiteDRAM's ECP5 PHY, which runs on
    // boards, relies on: its strobe is an ODDRX2DQSB with D_n = (0b1010 >> n) & 1,
    // low then high, and its DQ takes beat n of a chunk on D_n. Not checked against
    // Lattice's own document here.) ----
    input  wire [DQ_WIDTH-1:0]     wr_d3, wr_d2, wr_d1, wr_d0,
    input  wire                    wr_en,   // the DQ enable window (Part 17: rtl/soc/ddr3_ecp5_top.v drives it from the DQS FSM's burst_active, so DQ is enabled exactly while DQS toggles), drives every lane's TSHX2DQA the same way

    // ---- read side: the same 4-bit-wide shape, captured; Q0 is the earliest beat of the four, as D0 is on the write side ----
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
            // cycle/phase-accurate) stand-in. Phase 9 Stage 3: both sides are
            // at beat resolution now - the write side (below) puts four UI on the
            // pin per sclk, D0 first, on a grid a quarter of CK from the strobe's;
            // the read side takes four samples per sclk, at the middle of each UI
            // a DRAM that drives its beats edge-aligned with the strobe (sim/
            // ddr3_dq_model.v) would hold them, and presents them on Q0 to Q3,
            // Q0 the earliest. (LiteDRAM's ECP5 PHY, which runs on boards, relies
            // on the same order: its IDDRX2DQA Q0 to Q3 feed a four-bit word whose
            // bit 0 is the first beat, and the older sclk cycle of two carries beats
            // 0 to 3. Not checked against Lattice's own document here.)
            // The samples are taken at +5, +15, +25 and +35 ns into the sclk cycle
            // in which the DRAM's beats are on the pins, and the word appears at the
            // next sclk edge: the timing the one-sample-per-sclk stand-in had.
            // Through Stage 2 the capture took one word per edge and repeated it on
            // Q0 to Q3.
            reg rd_s0, rd_s1, rd_s2, rd_s3;
            reg rd_q3_r, rd_q2_r, rd_q1_r, rd_q0_r;
            initial begin rd_s0 = 1'b0; rd_s1 = 1'b0; rd_s2 = 1'b0; rd_s3 = 1'b0; end
            always @(posedge sclk) begin
                #5  rd_s0 <= dq_i[i];
                #10 rd_s1 <= dq_i[i];
                #10 rd_s2 <= dq_i[i];
                #10 rd_s3 <= dq_i[i];
            end
            always @(posedge sclk or posedge rst) begin
                if (rst) begin
                    rd_q3_r <= 1'b0; rd_q2_r <= 1'b0;
                    rd_q1_r <= 1'b0; rd_q0_r <= 1'b0;
                end else begin
                    rd_q3_r <= rd_s3;
                    rd_q2_r <= rd_s2;
                    rd_q1_r <= rd_s1;
                    rd_q0_r <= rd_s0;
                end
            end
            assign rd_q3[i] = rd_q3_r;
            assign rd_q2[i] = rd_q2_r;
            assign rd_q1[i] = rd_q1_r;
            assign rd_q0[i] = rd_q0_r;
            // The write side at the pin: one value per UI, four per sclk, D0 first, on the grid a quarter of CK (5 ns)
            // later than the strobe's (rtl/soc/ddr3_dm_drv_ecp5.v says why), and the enable on the same grid, so DQ is
            // driven from half a UI before the first strobe edge to half a UI after the last. Phase 9 Stage 3: through
            // Stage 2 this was `assign dq_o = wr_d0`, one value per sclk.
            reg dq_w_r, oe_w_r;
            initial begin dq_w_r = 1'b0; oe_w_r = 1'b0; end
            always @(posedge sclk) begin
                #5  begin dq_w_r <= wr_d0[i]; oe_w_r <= wr_en; end
                #10 dq_w_r <= wr_d1[i];
                #10 dq_w_r <= wr_d2[i];
                #10 dq_w_r <= wr_d3[i];
            end
            assign dq_o[i]  = dq_w_r;
            assign dq_oe[i] = oe_w_r;
            assign dq_t[i]  = !oe_w_r;
`endif
        end
    endgenerate
endmodule
