// DDR3 DQS write-drive, ECP5 - Phase 9 Stage 1, Part 4 (docs/roadmap/phase-09-ddr.md).
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
    // The same control with the polarity the ECP5's pad takes: high = TRI-STATED. It is
    // TSHX2DQSA's own Q (fed `!oe` below), and must reach the pad's T input directly - see
    // the note on `dq_t` in rtl/soc/ddr3_dq_serdes_ecp5.v (Part 21). `dqs_oe` is the
    // enable the simulation branch defines; in the synthesis branch it is derived, and unused.
    output wire        dqs_t,

    // High exactly during the two active cycles (S_ACTIVE0, S_ACTIVE1) - the eight
    // beats of the BL8 burst. rtl/soc/ddr3_ecp5_top.v drives DQ from this, so DQ is
    // enabled, and carries data, in the same cycles DQS is toggling.
    output wire        burst_active,

    // High during S_ACTIVE0 only - the first of the burst's two sclk-visible halves,
    // the one this design's data path treats as the addressed column (Part 18's read
    // side and Part 17's write side both single out "the first half" the same way).
    // rtl/soc/ddr3_ecp5_top.v drives DM from this (Part 22): DM low - unmasked, write
    // it - for beat 0 only, the first UI of this cycle (rtl/soc/ddr3_dm_drv_ecp5.v takes a mask
    // per UI since Phase 9 Stage 3; through Stage 2 one level covered all four UI of the cycle,
    // which on a real part writes four columns), high for every other beat of the burst.
    output wire        active0
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

    // D0 first in time, D3 last (Phase 9 Stage 3: this comment said the opposite until then, and the pattern below
    // would have put the first rising edge at the start of the active cycle instead of 10 ns into it, half a CK
    // early). The ordering is the one LiteDRAM's ECP5 PHY, which runs on boards, uses: its DQS is an `ODDRX2DQSB` with
    // D_n = (0b1010 >> n) & 1, so D0 low and D1 high, the same pattern as here, and its DQ takes beat n of a chunk on D_n.
    // A real write strobe toggles every UI during the active cycles; held low (with OE already asserted) during
    // preamble/postamble.
    reg [3:0] d;
    reg       oe;

    assign burst_active = (state == S_ACTIVE0) || (state == S_ACTIVE1);
    assign active0       = (state == S_ACTIVE0);

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
        .Q(dqs_t)
    );
    assign dqs_oe = !dqs_t;
`else
    // Simulation. Neither ODDRX2DQSB nor TSHX2DQSA has a behavioral model in this toolchain - the same real gap every
    // other DDR-I/O primitive in this stage found - so this does what the primitive does at the pin: the four values of
    // the cycle, D0 first, one per UI (10 ns, half a CK), starting at the sclk edge. The enable is `oe`, from `state`, as
    // it has always been.
    // Phase 9 Stage 3: through Stage 2 this was `assign dqs_o = d[3]`, one level per sclk cycle, so nothing in a
    // simulation ever saw the strobe toggle and the memory model judged a burst by which cycles the strobe was high in.
    // Now the strobe toggles: rising 10 ns into the first active cycle (WL = 6 CK after the WRITE's CK edge, which
    // is 10 ns into its own cycle), then every 10 ns, eight edges for the eight beats, falling at the end of the second
    // active cycle. Designed, not derived: the 90 degree relation of DQSW to ECLK is the bring-up's to show.
    // How: D0 is low in every state, so the first UI of a cycle is "low" whatever the state is, and the others are read
    // from `d` as they come, 10, 20 and 30 ns later. Nothing the rest of the design samples at an sclk edge is assigned by
    // a process that waits: a nonblocking assignment in such a process is not treated the same way by every Verilator
    // (CI's 5.020 saw the enable a cycle early, which 5.052 does not), so the "first UI is low" flag is a pair of
    // toggles, one flipped at the edge by a process that never waits and one chasing it 10 ns later by the one that does.
    reg first_ui_a, first_ui_b;       // the strobe is in the first UI of the cycle while they differ
    reg dqs_late;                     // the strobe's level in UI 1 to 3 of the cycle
    initial begin first_ui_a = 1'b0; first_ui_b = 1'b0; dqs_late = 1'b0; end
    always @(posedge sclk) first_ui_a <= ~first_ui_a;
    always @(posedge sclk) begin
        #10 begin dqs_late <= d[1]; first_ui_b <= first_ui_a; end
        #10 dqs_late <= d[2];
        #10 dqs_late <= d[3];
    end
    assign dqs_o  = (first_ui_a != first_ui_b) ? 1'b0 : dqs_late;
    assign dqs_oe = oe;
    assign dqs_t  = !oe;

    wire _unused_ok = &{1'b0, eclk, dqsw, 1'b0};
`endif
endmodule
