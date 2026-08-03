// Wishbone B4 classic framebuffer: a block-RAM pixel buffer the CPU writes
// into, scanned out by video_timing.v.
//
// This is a *display controller*, not a GPU in the compute sense - there is
// no drawing engine, no blitter and no second core. The CPU writes pixels;
// this reads them out in raster order. That split is deliberate for a first
// version: it is the piece everything else would need underneath it anyway,
// and it adds no bus master, so the interconnect's two-master arbitration is
// untouched.
//
// ---- Organization ----
// 8 bits per pixel in **RRRGGGBB** direct colour - no palette, so a pixel
// value maps to a colour with nothing to configure and no second memory. The
// expansion to RGB888 replicates the high bits, so 3'b111 becomes 8'hFF
// rather than 8'hE0 and white is actually white.
//
// The buffer is word-organized with byte write enables, exactly like
// wb_ram.v, because that is what lets software write one pixel with a plain
// `sb` and four with a `sw`. It costs roughly 2x the theoretical block-RAM
// minimum for the same reason wb_ram.v does - a 32-bit memory with byte
// enables cannot use a DP16KD's full 18 Kbit in one instance - and that cost
// is why FB_WIDTH/FB_HEIGHT are parameters rather than fixed.
//
// ---- Scan-out ----
// Port B reads a word every pixel clock; the byte lane is selected from the
// low address bits. The pixel path is two registers deep, so the syncs are
// delayed by two to match - see the alignment comment below, which is where
// this module's one real bug was. Reading every cycle rather than only when
// the word changes is deliberate: it costs nothing on a dual-port RAM and
// removes a whole class of off-by-one.
//
// Pixel doubling (`PIXEL_DOUBLE`) maps a 320x240 buffer onto a 640x480
// raster, which is what makes a modest framebuffer fill a standard mode.
module wb_framebuffer #(
    parameter FB_WIDTH     = 320,
    parameter FB_HEIGHT    = 240,
    parameter PIXEL_DOUBLE = 1,     // 1 = each buffer pixel covers 2x2 screen pixels
    parameter INIT_FILE    = ""
)(
    input  wire        clk,
    input  wire        rst,

    // ---- Wishbone slave: the CPU's view ----
    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    input  wire [3:0]  wb_sel,
    output wire [31:0] wb_dat_r,
    output wire        wb_ack,

    // ---- raster position, from video_timing.v ----
    input  wire [11:0] vid_x,
    input  wire [11:0] vid_y,
    input  wire        vid_de,
    input  wire        vid_hsync,
    input  wire        vid_vsync,

    // ---- pixel stream out, TWO cycles behind the inputs above ----
    output reg  [7:0]  vid_r,
    output reg  [7:0]  vid_g,
    output reg  [7:0]  vid_b,
    output reg         vid_de_out,
    output reg         vid_hsync_out,
    output reg         vid_vsync_out
);
    localparam PIXELS = FB_WIDTH * FB_HEIGHT;
    localparam WORDS  = (PIXELS + 3) / 4;
    localparam AW     = $clog2(WORDS);

    reg [31:0] mem [0:WORDS-1];
    integer i;

    // Guarded for the same reason wb_ram.v's is: yosys unrolls this into one
    // assignment per word, which is what used to make full-SoC synthesis
    // appear to hang. Simulation needs it, because an unwritten Verilog array
    // reads X and a captured frame full of X is not a useful picture.
    initial begin
`ifndef SYNTHESIS
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = 32'b0;
`endif
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // =====================================================================
    // Port A: the bus
    // =====================================================================
    wire [AW-1:0] a_addr = wb_adr[AW+1:2];
    wire          a_en   = wb_cyc && wb_stb;

    reg        ack_r;
    reg [31:0] a_q;

    // One wait state, matching wb_ram.v: address in the first cycle, data and
    // ack in the second. `!ack_r` keeps the ack a single cycle and stops the
    // write being applied twice while the master holds `stb`.
    always @(posedge clk or posedge rst) begin
        if (rst) ack_r <= 1'b0;
        else     ack_r <= a_en && !ack_r;
    end

    always @(posedge clk) begin
        if (a_en && wb_we && !ack_r) begin
            if (wb_sel[0]) mem[a_addr][7:0]   <= wb_dat_w[7:0];
            if (wb_sel[1]) mem[a_addr][15:8]  <= wb_dat_w[15:8];
            if (wb_sel[2]) mem[a_addr][23:16] <= wb_dat_w[23:16];
            if (wb_sel[3]) mem[a_addr][31:24] <= wb_dat_w[31:24];
        end
        a_q <= mem[a_addr];
    end

    assign wb_dat_r = a_q;
    assign wb_ack   = ack_r;

    // =====================================================================
    // Port B: scan-out
    // =====================================================================
    // Buffer coordinates for this screen position.
    wire [11:0] fb_x = PIXEL_DOUBLE ? (vid_x >> 1) : vid_x;
    wire [11:0] fb_y = PIXEL_DOUBLE ? (vid_y >> 1) : vid_y;

    // Linear pixel index. The multiply is by a constant, so yosys reduces it
    // to shifts and an add rather than inferring a multiplier.
    wire [31:0] pixel_index = (fb_y * FB_WIDTH) + {20'd0, fb_x};

    wire [AW-1:0] b_addr = pixel_index[AW+1:2];
    reg  [31:0]   b_q;
    reg  [1:0]    b_lane;

    always @(posedge clk) begin
        b_q    <= mem[b_addr];
        b_lane <= pixel_index[1:0];
    end

    reg [7:0] pixel;
    always @(*) begin
        case (b_lane)
            2'd0:    pixel = b_q[7:0];
            2'd1:    pixel = b_q[15:8];
            2'd2:    pixel = b_q[23:16];
            default: pixel = b_q[31:24];
        endcase
    end

    // ---- sync alignment: the pixel path is TWO registers deep, not one ----
    // Raster position -> address is combinational, the block RAM read costs a
    // register (`b_q`), and the colour expansion costs another (`vid_r`). So
    // a pixel appears on the output two cycles after the raster position it
    // belongs to, and the syncs have to be delayed by the same two.
    //
    // Delaying them by one - which is the obvious thing to write, and what
    // this module did first - shifts the whole image one pixel left relative
    // to the syncs. On a monitor that is a barely perceptible offset; in a
    // captured frame it is every pixel wrong by one position. sim/tb_video.v
    // caught it by comparing readback against what was written, which an
    // eyeballed "looks like a picture" check would not have.
    reg de_d1, hsync_d1, vsync_d1;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            de_d1    <= 1'b0;
            hsync_d1 <= 1'b1;
            vsync_d1 <= 1'b1;
        end else begin
            de_d1    <= vid_de;
            hsync_d1 <= vid_hsync;
            vsync_d1 <= vid_vsync;
        end
    end

    // Stage 2, in step with `b_q`: RRRGGGBB -> RGB888, replicating high bits
    // so full-scale stays full. Blanking is forced black rather than left as
    // whatever the buffer happened to hold.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vid_r         <= 8'd0;
            vid_g         <= 8'd0;
            vid_b         <= 8'd0;
            vid_de_out    <= 1'b0;
            vid_hsync_out <= 1'b1;   // sync idles high (active low)
            vid_vsync_out <= 1'b1;
        end else begin
            vid_r         <= de_d1 ? {pixel[7:5], pixel[7:5], pixel[7:6]} : 8'd0;
            vid_g         <= de_d1 ? {pixel[4:2], pixel[4:2], pixel[4:3]} : 8'd0;
            vid_b         <= de_d1 ? {pixel[1:0], pixel[1:0],
                                      pixel[1:0], pixel[1:0]}             : 8'd0;
            vid_de_out    <= de_d1;
            vid_hsync_out <= hsync_d1;
            vid_vsync_out <= vsync_d1;
        end
    end

    // `wb_adr`'s high bits were consumed by the interconnect's decode, and
    // the raster counters are wider than any buffer that fits here.
    wire _unused_ok = &{1'b0, wb_adr[31:AW+2], wb_adr[1:0],
                        pixel_index[31:AW+2], 1'b0};
endmodule
