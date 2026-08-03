// Raster timing generator: counts out a display frame and says, for every
// clock, where on the screen we are and whether that position is visible.
//
// Defaults are 640x480 @ 60 Hz, which wants a 25.175 MHz pixel clock. This
// SoC runs at 25 MHz, and **the difference is deliberate and currently
// harmless**: with no physical display attached, the pixel clock only has to
// be self-consistent for the framebuffer scan-out and the testbench that
// captures it. Driving a real monitor needs 25.175 MHz from a PLL and a
// clock-domain crossing to the CPU - see fpga/README.md. Until then this runs
// in the CPU's own clock domain, which is why there is no CDC anywhere in the
// video path.
//
// 0.7% slow is within what most monitors tolerate, but that is a claim about
// somebody else's hardware and is not made here.
//
// Sync polarity for 640x480 @ 60 Hz is negative on both, which is why
// `hsync`/`vsync` are asserted *low* during their sync interval.
module video_timing #(
    // Horizontal, in pixel clocks.
    parameter H_VISIBLE     = 640,
    parameter H_FRONT_PORCH = 16,
    parameter H_SYNC        = 96,
    parameter H_BACK_PORCH  = 48,

    // Vertical, in lines.
    parameter V_VISIBLE     = 480,
    parameter V_FRONT_PORCH = 10,
    parameter V_SYNC        = 2,
    parameter V_BACK_PORCH  = 33
)(
    input  wire        clk,
    input  wire        rst,

    output reg  [11:0] x,           // 0..H_VISIBLE-1 while `de`; junk otherwise
    output reg  [11:0] y,           // 0..V_VISIBLE-1 while `de`
    output wire        de,          // display enable: this pixel is visible
    output wire        hsync,       // active low
    output wire        vsync,       // active low
    output wire        frame_start  // one cycle at the top-left visible pixel
);
    localparam H_TOTAL = H_VISIBLE + H_FRONT_PORCH + H_SYNC + H_BACK_PORCH;
    localparam V_TOTAL = V_VISIBLE + V_FRONT_PORCH + V_SYNC + V_BACK_PORCH;

    // Raw counters run across the whole frame including blanking; `x`/`y` are
    // only meaningful while `de` is high.
    reg [11:0] hcount;
    reg [11:0] vcount;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            hcount <= 12'd0;
            vcount <= 12'd0;
        end else if (hcount == H_TOTAL - 1) begin
            hcount <= 12'd0;
            vcount <= (vcount == V_TOTAL - 1) ? 12'd0 : vcount + 12'd1;
        end else begin
            hcount <= hcount + 12'd1;
        end
    end

    always @(*) begin
        x = hcount;
        y = vcount;
    end

    assign de = (hcount < H_VISIBLE) && (vcount < V_VISIBLE);

    // Sync pulses sit after the front porch. Active low.
    assign hsync = ~((hcount >= H_VISIBLE + H_FRONT_PORCH) &&
                     (hcount <  H_VISIBLE + H_FRONT_PORCH + H_SYNC));
    assign vsync = ~((vcount >= V_VISIBLE + V_FRONT_PORCH) &&
                     (vcount <  V_VISIBLE + V_FRONT_PORCH + V_SYNC));

    assign frame_start = (hcount == 12'd0) && (vcount == 12'd0);
endmodule
