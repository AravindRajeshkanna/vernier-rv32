// DDR3 DQS write-drive, ECP5 - Phase 9 Stage 1, Part 4 (docs/roadmap.md).
// `ODDRX2DQSB` + `TSHX2DQSA`, generating a real write preamble/active-
// toggle/postamble DQS waveform for one byte lane - closing the gap
// Part 3 named explicitly: `rtl/soc/ddr3_dq_serdes_ecp5.v` can already
// drive DQ out for a write (`ODDRX2DQA`/`TSHX2DQA`), but nothing drove
// DQS, and a real DDR3 chip cannot sample DQ without a real strobe
// alongside it.
//
// ---- Scope: this proves the primitive mechanism, not a full write
// path yet ----
// A single `write_start` pulse (1 `sclk` cycle) drives one real,
// fixed-shape burst-length-8 write waveform - preamble, two active
// toggle cycles (4 UI each, matching `ODDRX2DQSB`'s own real 4-bit-
// wide `D3:D0` port and this design's own already-established 4:1
// SCLK:UI ratio - see `rtl/soc/ddr3_dq_serdes_ecp5.v`'s own header),
// postamble. Wiring this into a real command-level write sequencer
// (triggered by an actual WR command through `ddr3_phy_ecp5.v`, timed
// off `CWL`) and proving a memory model actually samples DQ on these
// real DQS edges (rather than being told the write data directly, the
// way every DQ/DQS test through Part 3 still does) are both later,
// separate work - named here rather than implied done.
//
// ---- Preamble/postamble length: reasoned, not primary-datasheet-
// verified ----
// JEDEC's own minimum write preamble (tWPRE) is 0.35-0.5 tCK and
// postamble (tWPST) 0.4-0.6 tCK depending on speed grade - this file
// drives a full 1 SCLK cycle (4 UI) of low-with-OE-asserted for each,
// a conservative, simple, real margin above the documented minimum
// rather than a tight fit to it. The same open verification gap
// `rtl/soc/ddr3_init_seq.v`'s own header already names for its MR
// field values applies here too: this was not checked against the
// primary Micron datasheet this round (that PDF fetch failed earlier
// in this same investigation), only reasoned from general JEDEC
// documentation.
module ddr3_dqs_write_ecp5 (
    input  wire        sclk,
    input  wire        eclk,
    input  wire        dqsw,      // from rtl/soc/ddr3_dqs_ecp5.v's own DQSBUFM
    input  wire        rst,

    input  wire        write_start,  // one real sclk-cycle pulse - starts one BL8 write burst

    output wire        dqs_o,
    output wire        dqs_oe,

    // High exactly during the two active cycles (S_ACTIVE0, S_ACTIVE1) - the eight
    // beats of the BL8 burst. rtl/soc/ddr3_ecp5_top.v drives DQ from this, so DQ is
    // enabled, and carries data, in the same cycles DQS is toggling.
    output wire        burst_active
);
    localparam [2:0]
        S_IDLE      = 3'd0,
        S_PREAMBLE  = 3'd1,
        S_ACTIVE0   = 3'd2,
        S_ACTIVE1   = 3'd3,
        S_POSTAMBLE = 3'd4;

    reg [2:0] state;

    always @(posedge sclk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE:      state <= write_start ? S_PREAMBLE : S_IDLE;
                S_PREAMBLE:  state <= S_ACTIVE0;
                S_ACTIVE0:   state <= S_ACTIVE1;
                S_ACTIVE1:   state <= S_POSTAMBLE;
                S_POSTAMBLE: state <= S_IDLE;
                default:     state <= S_IDLE;
            endcase
        end
    end

    // D3 first in time, D0 last - matching ODDRX2DQA/IDDRX2DQA's own
    // real bit-time ordering (rtl/soc/ddr3_dq_serdes_ecp5.v's own
    // header). A real write strobe toggles every UI during the active
    // cycles; held low (with OE already asserted) during
    // preamble/postamble.
    reg [3:0] d;
    reg       oe;

    assign burst_active = (state == S_ACTIVE0) || (state == S_ACTIVE1);

    always @(*) begin
        case (state)
            S_PREAMBLE:  begin d = 4'b0000; oe = 1'b1; end
            S_ACTIVE0:   begin d = 4'b1010; oe = 1'b1; end
            S_ACTIVE1:   begin d = 4'b1010; oe = 1'b1; end
            S_POSTAMBLE: begin d = 4'b0000; oe = 1'b1; end
            default:     begin d = 4'b0000; oe = 1'b0; end
        endcase
    end

`ifdef SYNTHESIS
    ODDRX2DQSB DRV (
        .D3(d[3]), .D2(d[2]), .D1(d[1]), .D0(d[0]),
        .SCLK(sclk), .ECLK(eclk), .DQSW(dqsw), .RST(rst),
        .Q(dqs_o)
    );
    TSHX2DQSA OE_DRV (
        .T1(!oe), .T0(!oe), .SCLK(sclk), .ECLK(eclk), .DQSW(dqsw), .RST(rst),
        .Q(dqs_oe)
    );
`else
    // Simulation. Neither ODDRX2DQSB nor TSHX2DQSA has a behavioral
    // model in this toolchain - the same real gap every other DDR-I/O
    // primitive in this stage already found. Presents the intended
    // waveform at sclk granularity, the same honest, not eclk-
    // accurate, approximation rtl/soc/ddr3_dq_serdes_ecp5.v's own
    // simulation body already uses - a real DQS toggles at 2x this
    // rate, but that finer edge is not meaningfully observable in a
    // plain Verilog testbench against an equally-behavioral model.
    // Combinational from `state`, deliberately matching `oe`'s own
    // combinational timing above rather than adding a second register
    // with its own separate latency - a first draft registered this
    // signal instead and a real run caught it: `oe` dropped low
    // immediately on leaving the active window while this register's
    // own one-cycle lag kept showing DQS high for one extra cycle,
    // an artifact of this simulation substitute's own inconsistency,
    // not of the real ODDRX2DQSB/TSHX2DQSA primitives (which both
    // take D/T combinationally at the same real cadence). `d[3]` is 1
    // exactly during S_ACTIVE0/S_ACTIVE1 (see the pattern above) and 0
    // everywhere else, so it doubles as a low/high activity indicator
    // - not a claim of real per-UI toggling, the same honestly
    // sclk-granularity-only approximation
    // rtl/soc/ddr3_dq_serdes_ecp5.v's own simulation body already
    // uses.
    assign dqs_o  = d[3];
    assign dqs_oe = oe;

    wire _unused_ok = &{1'b0, eclk, dqsw, 1'b0};
`endif
endmodule
