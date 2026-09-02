// TMDS 8b/10b encoder: one channel of the DVI/HDMI Transition-Minimized
// Differential Signaling encoding, DVI 1.0 spec section 3.2.2.
//
// This is stage 1 of Phase 4 (video out) - the part that is entirely
// independent of the FPGA board, a PLL or a serializer, and can be proven
// correct against known-good vectors on this laptop before any of that
// exists. `fpga/README.md`'s "What would actually work" already names the
// two things still missing after this: a 5x-pixel-clock PLL, and a 10:1 (or
// DDR 5:1) serializer onto the GPDI pins (`fpga/constraints/ulx3s.lpf` has
// no gpdi_* entries yet). Neither is here. What is here is the one part a
// wrong bit costs the most to debug once it is driving real pins: a
// transposed XOR/XNOR branch or a disparity-sign flip produces a signal
// that *displays*, just wrong, on some fraction of pixel values - the kind
// of bug a "does a monitor show anything" test would never catch.
//
// ---- What this does, in one pass ----
//
// A pixel channel (R, G or B, one instance per channel) is 8 data bits
// during the visible raster and 2 control bits during blanking - `de`
// selects which. The 8-to-10 encoding runs in two stages:
//
//  1. Pick XOR or XNOR chaining across the 8 input bits, whichever produces
//     fewer transitions - the "transition-minimized" half of TMDS, and the
//     reason a byte does not just get zero-extended.
//  2. Pick whether to send that 8-bit result inverted or not, tracking a
//     running disparity counter (`cnt`) across the whole active line, so
//     the number of 1s and 0s sent stays close to balanced over time - the
//     "differential signaling" half, which is what lets the receiver's PLL
//     stay locked without a separate clock wire per data line.
//
// Control periods (`de` low) use one of four fixed, spec-defined 10-bit
// codes keyed by `c0`/`c1` and reset the disparity counter to zero - the
// codes are chosen to already be perfectly balanced, so the next active
// line always starts from a known state rather than carrying over
// whatever the previous line's last pixel left behind.
//
// ---- Which channel gets c0/c1 ----
//
// DVI carries `hsync`/`vsync` only on channel 0 (by convention, the one
// wired to Blue on this board - `fpga/constraints/ulx3s.lpf`'s eventual
// gpdi_dp[0]/gpdi_dn[0]). Channels 1 and 2 (Green, Red) must see `c0`/`c1`
// tied to zero during blanking - the spec reserves the other three control
// combinations on those channels for HDMI's InfoFrame signaling, which this
// project does not implement, and a stray 1 there would produce a control
// token no plain-DVI monitor is required to recognize. This module does not
// enforce that itself - it takes whatever c0/c1 it is given - because which
// channel is which is a top-level wiring decision, made once, in one place,
// not a fact this module should assume about its caller.
//
// ---- Registered, one cycle of latency ----
//
// `q_out` is a register, not a combinational function of `d`/`de`/`c0`/`c1`.
// Nothing downstream exists yet to care about the latency - the serializer
// this eventually feeds runs off its own PLL-derived clock domain regardless
// - and a registered output is the shape every other piece of pixel-clock
// logic in this SoC already uses (`rtl/soc/wb_framebuffer.v`'s two-deep
// scan-out pipeline, `rtl/soc/video_timing.v`'s counters).
//
// ---- Verified against ----
//
// `sim/tb_tmds_encode.v` checks this against hand-derived vectors, not just
// "it runs": 0x10 and 0xEF are disparity-independent (their XOR/XNOR result
// is already exactly balanced, so the same code comes out regardless of
// `cnt`) and act as a check on stage 1 alone. 0x00 and 0xFF are the two most
// unbalanced possible inputs and, fed twice in a row, exercise stage 2's
// disparity tracking actually flipping the encoding on the second occurrence
// to compensate for the first - the one behavior a per-symbol lookup table
// could never get right, because it depends on history. The four control
// tokens are checked verbatim against the DVI spec's fixed values.
module tmds_encode (
    input  wire       clk,
    input  wire        rst,

    input  wire [7:0]  d,        // pixel data for this channel, valid while de
    input  wire         c0,       // control bit 0, valid while !de
    input  wire         c1,       // control bit 1, valid while !de
    input  wire         de,       // display enable: 1 = d is a pixel, 0 = c0/c1

    output reg  [9:0]   q_out
);
    // ---- Stage 1: minimize transitions ----
    // Counting ones rather than comparing intermediate XOR/XNOR results
    // directly is what the spec's own algorithm does - the choice depends
    // only on how many of the 8 bits are set, not on their positions.
    wire [3:0] ones_d = d[0] + d[1] + d[2] + d[3] + d[4] + d[5] + d[6] + d[7];
    wire       use_xnor = (ones_d > 4'd4) || (ones_d == 4'd4 && d[0] == 1'b0);

    wire [7:0] xored, xnored;
    assign xored[0]  = d[0];
    assign xnored[0] = d[0];
    genvar gi;
    generate
        for (gi = 1; gi < 8; gi = gi + 1) begin : chain
            assign xored[gi]  = xored[gi-1]  ^  d[gi];
            assign xnored[gi] = xnored[gi-1] ~^ d[gi];
        end
    endgenerate

    // q_m[7:0] is the chained result; q_m[8] (`qm8`) records which chain was
    // used - 1 for XOR, 0 for XNOR, per the spec's own bit convention, which
    // stage 2 needs to decide how to fold `cnt`'s sign into the inversion.
    wire [7:0] qm   = use_xnor ? xnored : xored;
    wire       qm8  = use_xnor ? 1'b0   : 1'b1;
    wire [3:0] ones_qm = qm[0] + qm[1] + qm[2] + qm[3] +
                          qm[4] + qm[5] + qm[6] + qm[7];
    wire [3:0] zeros_qm = 4'd8 - ones_qm;

    // ---- Stage 2: balance disparity across the line ----
    // Signed and generously wide: each pixel shifts `cnt` by at most +-8,
    // rebalancing resets it to 0 at every blanking period (see below), and
    // the branch conditions below only ever test its sign - not a specific
    // magnitude - so there is no failure mode from the width being "only"
    // generous rather than exactly sized.
    reg signed [5:0] cnt;

    wire balanced_now = (cnt == 6'sd0) || (ones_qm == zeros_qm);

    wire        inv_a   = ~qm8;                          // balanced-now branch
    wire [9:0]  qout_a  = {inv_a, qm8, qm8 ? qm : ~qm};
    wire signed [5:0] cnt_a =
        cnt + (qm8 ? ($signed({2'b0, ones_qm}) - $signed({2'b0, zeros_qm}))
                   : ($signed({2'b0, zeros_qm}) - $signed({2'b0, ones_qm})));

    wire take_invert = (cnt > 6'sd0 && ones_qm > zeros_qm) ||
                       (cnt < 6'sd0 && zeros_qm > ones_qm);
    wire [9:0] qout_b =
        take_invert ? {1'b1, qm8, ~qm} : {1'b0, qm8, qm};
    wire signed [5:0] cnt_b =
        take_invert
            ? cnt + (2 * $signed({5'b0, qm8})) +
                    ($signed({2'b0, zeros_qm}) - $signed({2'b0, ones_qm}))
            : cnt - (2 * $signed({5'b0, ~qm8})) +
                    ($signed({2'b0, ones_qm}) - $signed({2'b0, zeros_qm}));

    wire [9:0]        qout_data = balanced_now ? qout_a : qout_b;
    wire signed [5:0] cnt_data  = balanced_now ? cnt_a  : cnt_b;

    // ---- Control tokens: fixed, spec-defined, and DC-balanced already ----
    wire [9:0] ctrl_token = {c1, c0} == 2'b00 ? 10'b1101010100 :
                             {c1, c0} == 2'b01 ? 10'b0010101011 :
                             {c1, c0} == 2'b10 ? 10'b0101010100 :
                                                  10'b1010101011;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            q_out <= 10'b0;
            cnt   <= 6'sd0;
        end else if (de) begin
            q_out <= qout_data;
            cnt   <= cnt_data;
        end else begin
            q_out <= ctrl_token;
            cnt   <= 6'sd0;
        end
    end
endmodule
