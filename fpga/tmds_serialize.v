// Shifts one TMDS channel's 10-bit encoded word (rtl/soc/tmds_encode.v) out
// onto a single pin, 2 bits per `clk_bit` cycle via `ODDRX1F` - the same
// primitive `fpga/sdram_clk_out.v` already uses, here doing 5:1 instead of a
// fixed 180-degree shift. `fpga/video_pll.v` is the clock source this
// expects: `clk_bit` at exactly 5x `clk_pixel`, both off the same PLL.
//
// ---- Why this treats clk_pixel as a domain to cross, not a known phase ----
//
// `video_pll.v`'s `EHXPLLL` gives `clk_bit`/`clk_pixel` a *fixed* phase
// relationship - but fixed and *known to this design* are different claims.
// Nothing in this project can simulate `EHXPLLL` (no Icarus model, same as
// every other ECP5 hard primitive), so there is no way to verify a specific
// assumed alignment - "load a fresh word on bit-clock cycle N of 5" would be
// a number nothing here can check. Instead this treats `clk_pixel` as a
// signal to detect the edge of, in the `clk_bit` domain, with an ordinary
// two-flop synchronizer - the standard technique for a signal that changes
// synchronously with its own clock but is read by a different, faster one.
// The two are close enough in frequency (5x, not 500x) that this is normally
// where a design would instead just use the phase relationship directly, but
// doing it this way makes the design correct regardless of what that
// relationship turns out to be on real silicon - it depends only on the
// frequency ratio, which the PLL guarantees exactly, not on a phase this
// project cannot verify before a board exists to check it against.
//
// `tmds_word` itself is not synchronized bit-by-bit - that is the classic
// way to tear a multi-bit value (rtl/debug/dmi_cdc.v's header has the same
// argument for the same reason). It does not need to be: `tmds_word` is
// held stable by rtl/soc/tmds_encode.v for a whole `clk_pixel` period before
// changing again, and the edge detector's own two-flop latency (a handful of
// `clk_bit` cycles) is captured well inside that window, so by the time this
// module samples `tmds_word` it has been unchanged for several `clk_bit`
// edges already - the same "let the edge prove stability first" structure
// dmi_cdc.v uses for its own payload, just without the full four-phase
// handshake that module needs for a clock that can stop; `clk_bit` never
// does.
//
// ---- Bit order ----
//
// LSB first: `tmds_word[0]` is the first bit driven out after each detected
// pixel edge, `tmds_word[9]` the last. This module does not itself claim
// that is what a DVI receiver expects on the wire - it is recorded here as
// what THIS module does, for whoever wires the GPDI pins to state whether it
// is or is not the required order.
module tmds_serialize (
    input  wire        clk_pixel,   // rtl/soc/tmds_encode.v's own clock
    input  wire        clk_bit,     // fpga/video_pll.v's clk_bit: 5x clk_pixel
    input  wire        rst,         // clk_bit domain

    input  wire [9:0]  tmds_word,   // from tmds_encode.v, stable a full clk_pixel period

    output wire         tmds_out    // serial bit stream, ODDRX1F's Q
);
    // ---- two-flop synchronizer + rising-edge detector, in clk_bit ----
    reg [2:0] px_sync;
    always @(posedge clk_bit or posedge rst) begin
        if (rst) px_sync <= 3'b0;
        else     px_sync <= {px_sync[1:0], clk_pixel};
    end
    // Rising edge of the *synchronized* signal - clk_pixel toggles at half
    // its own period each phase, but tmds_word only changes on its rising
    // edge, matching tmds_encode.v's `always @(posedge clk)`.
    //
    // Used directly, not registered again first: `pos`/`word_r` below react
    // to `px_rise` one `clk_bit` cycle after it is first true, the same way
    // any register reacting to a wire driven by another register on the
    // same edge does - non-blocking assignment means `pos`'s own update
    // this edge is computed from `px_sync`'s *pre*-this-edge state, not the
    // shift that is committing this same edge. That is not a race to fix,
    // just the ordinary one-cycle latency of a register-to-register path -
    // an extra register here would only add a second, equally ordinary
    // cycle of the same thing, not remove any actual hazard.
    wire px_rise = px_sync[1] && !px_sync[2];

    // ---- load on the detected edge, otherwise advance through the word ----
    reg [9:0] word_r;
    reg [2:0] pos;   // which bit pair (0&1, 2&3, ..., 8&9) is on D0/D1 now

    always @(posedge clk_bit or posedge rst) begin
        if (rst) begin
            word_r <= 10'b0;
            pos    <= 3'd0;
        end else if (px_rise) begin
            // A fresh edge always restarts the sequence at bit 0, regardless
            // of where `pos` had reached - correct whether the previous word
            // finished exactly on time, which it always should if the PLL's
            // 5:1 ratio holds, or not.
            word_r <= tmds_word;
            pos    <= 3'd0;
        end else begin
            pos <= (pos == 3'd4) ? 3'd0 : pos + 3'd1;
        end
    end

    reg d0_r, d1_r;
    always @(*) begin
        case (pos)
            3'd0: begin d0_r = word_r[0]; d1_r = word_r[1]; end
            3'd1: begin d0_r = word_r[2]; d1_r = word_r[3]; end
            3'd2: begin d0_r = word_r[4]; d1_r = word_r[5]; end
            3'd3: begin d0_r = word_r[6]; d1_r = word_r[7]; end
            default: begin d0_r = word_r[8]; d1_r = word_r[9]; end  // 3'd4
        endcase
    end

`ifdef SYNTHESIS
    ODDRX1F serdes (
        .SCLK(clk_bit),
        .RST(rst),
        .D0(d0_r),
        .D1(d1_r),
        .Q(tmds_out)
    );
`else
    // Simulation. ODDRX1F has no Icarus model - same situation
    // fpga/sdram_clk_out.v documents for its own use of this primitive, and
    // the same fallback shape: that module's own D0=0/D1=1 case simulates as
    // `~clk`, which is `SCLK ? D0 : D1` with those constants - so this is
    // that same relationship with D0/D1 driven dynamically instead of tied.
    assign tmds_out = clk_bit ? d0_r : d1_r;
`endif
endmodule
