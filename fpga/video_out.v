// Wires the framebuffer's pixel stream (rtl/soc/wb_framebuffer.v, via
// soc_top.v's vid_* ports) to the four GPDI channels: encode
// (rtl/soc/tmds_encode.v) then serialize (fpga/tmds_serialize.v) per
// channel, plus a fourth serializer alone for the fixed clock-channel
// pattern DVI requires. Stage 4 of Phase 4 - see docs/roadmap.md.
//
// ---- Clocking: deliberately not video_pll.v's clk_pixel tap ----
//
// `clk` here is the SoC's own clock - the same net `wb_framebuffer.v` is
// clocked from - not `video_pll.v`'s `clk_pixel` output. docs/roadmap.md's
// Phase 4 section has the full argument: `clk_pixel` and the SoC's `clk`
// are both nominally 25 MHz but are two different nets related by a fixed,
// unverifiable-in-simulation PLL delay, and unlike the 5:1 `clk_bit`:
// `clk_pixel` relationship `fpga/tmds_serialize.v`'s synchronizer handles
// safely, a 1:1 same-frequency crossing has no oversampling margin at all -
// a bad alignment could tear a pixel deterministically, every frame. Using
// the SoC's own `clk` for both the framebuffer and the encoder removes the
// crossing entirely rather than trying to synchronize across it.
// `video_pll.v`'s `clk_pixel` output is simply not connected to anything
// here.
//
// ---- Which channel carries hsync/vsync ----
//
// By DVI convention, only channel 0 carries `c0`/`c1` (mapped to hsync/
// vsync) during blanking; the other two must see them tied to zero, or a
// receiver could read a channel-1/2 control combination as HDMI InfoFrame
// signaling this design does not send. Channel 0 is Blue on this board's
// GPDI pinout (`fpga/constraints/ulx3s.lpf`'s `gpdi_dp[0]` = "Blue +").
//
// ---- The clock channel ----
//
// DVI's fourth differential pair does not carry TMDS-encoded data - it is
// a fixed, repeating 10-bit pattern, transmitted through the same 5:1
// serializer as the data channels so all four channels share identical
// timing characteristics. `10'b0000011111` shifts out (LSB first, per
// fpga/tmds_serialize.v's own documented bit order) as five 1s then five
// 0s: a plain square wave at the pixel rate, which is what a receiver's
// PLL locks onto to recover the pixel clock. No `tmds_encode` instance
// feeds this channel; there is nothing to encode.
module video_out (
    input  wire        clk,          // SoC's own clock; see header above
    input  wire        clk_25mhz,    // board oscillator, video_pll.v's input
    input  wire        rst,

    input  wire [7:0]  vid_r,
    input  wire [7:0]  vid_g,
    input  wire [7:0]  vid_b,
    input  wire        vid_de,
    input  wire        vid_hsync,
    input  wire        vid_vsync,

    output wire [3:0]  gpdi_dp       // gpdi_dn is not a Verilog signal -
                                      // see fpga/constraints/ulx3s.lpf
);
    wire clk_bit, clk_pixel_unused, pll_locked;
    video_pll PLL (
        .clk_25mhz(clk_25mhz),
        .clk_bit(clk_bit),
        .clk_pixel(clk_pixel_unused),
        .locked(pll_locked)
    );

    // ---- channel 0: Blue, carries hsync/vsync ----
    wire [9:0] q_blue;
    tmds_encode ENC_BLUE (
        .clk(clk), .rst(rst),
        .d(vid_b), .c0(vid_hsync), .c1(vid_vsync), .de(vid_de),
        .q_out(q_blue)
    );
    tmds_serialize SER_BLUE (
        .clk_pixel(clk), .clk_bit(clk_bit), .rst(rst),
        .tmds_word(q_blue), .tmds_out(gpdi_dp[0])
    );

    // ---- channel 1: Green, c0/c1 tied low ----
    wire [9:0] q_green;
    tmds_encode ENC_GREEN (
        .clk(clk), .rst(rst),
        .d(vid_g), .c0(1'b0), .c1(1'b0), .de(vid_de),
        .q_out(q_green)
    );
    tmds_serialize SER_GREEN (
        .clk_pixel(clk), .clk_bit(clk_bit), .rst(rst),
        .tmds_word(q_green), .tmds_out(gpdi_dp[1])
    );

    // ---- channel 2: Red, c0/c1 tied low ----
    wire [9:0] q_red;
    tmds_encode ENC_RED (
        .clk(clk), .rst(rst),
        .d(vid_r), .c0(1'b0), .c1(1'b0), .de(vid_de),
        .q_out(q_red)
    );
    tmds_serialize SER_RED (
        .clk_pixel(clk), .clk_bit(clk_bit), .rst(rst),
        .tmds_word(q_red), .tmds_out(gpdi_dp[2])
    );

    // ---- channel 3: fixed clock pattern, no encoder ----
    tmds_serialize SER_CLOCK (
        .clk_pixel(clk), .clk_bit(clk_bit), .rst(rst),
        .tmds_word(10'b0000011111), .tmds_out(gpdi_dp[3])
    );

    // pll_locked/clk_pixel_unused: genuinely unused. Nothing here gates on
    // lock (this project's other clock-primitive wrappers - sdram_clk_out.v,
    // video_pll.v itself - don't either), and clk_pixel is deliberately not
    // wired to anything, per the header above.
endmodule
