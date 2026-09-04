// Wishbone B4 classic framebuffer: a block-RAM pixel buffer the CPU writes
// into, scanned out by video_timing.v - plus a small solid-fill engine,
// Phase 10 stage 1 (docs/roadmap.md).
//
// This was a *display controller*, not a GPU in the compute sense: no
// drawing engine, no blitter, no second core - the CPU wrote every pixel
// itself, in a software loop. That split was deliberate for a first
// version, and this module's own header used to say so explicitly: "it
// adds no bus master, so the interconnect's two-master arbitration is
// untouched." The fill engine below keeps that promise - it is entirely
// internal to this module's existing Wishbone slave port, reusing the
// same address window rather than adding a new slave or a new master.
// docs/roadmap.md's Phase 10 entry has the reasoning for why *this* is
// the first increment (peripheral-sized, not core-sized) and what a
// blit/copy engine or a real 3D pipeline would each cost beyond it.
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
// ---- Address map within this slave's own 16 MB window ----
// Bit 17 of the offset (well above anything pixel data ever needs - the
// buffer is 76,800 bytes, under 2^17) splits the window in two:
//
//   bit 17 = 0   pixel data, exactly as before - FB_BASE + y*FB_WIDTH + x
//   bit 17 = 1   the fill engine's control block, at FB_BASE + 0x20000:
//
//     0x00  BLIT_X       RW  left edge of the fill rectangle
//     0x04  BLIT_Y       RW  top edge
//     0x08  BLIT_W       RW  width
//     0x0C  BLIT_H       RW  height
//     0x10  BLIT_COLOR   RW  fill colour, RRRGGGBB in bits [7:0]
//     0x14  BLIT_CTRL    WO  bit 0 = start; ignored if already busy
//     0x18  BLIT_STATUS  RO  bit 0 = busy
//
// Matches `wb_spi.v`'s own CTRL/STATUS naming (`docs/soc.md`) rather than
// inventing a new convention - STATUS.busy is exactly SPI's own pattern,
// reused because it already says the right thing.
//
// ---- Why a fill blocks the CPU out of pixel data, but not STATUS ----
// The fill engine and the CPU's own Port A share one write port into
// `mem[]` - the same one the CPU has always written pixels through. While
// a fill is running, a CPU access to pixel data (or to any *other* blit
// register) simply is not acked, exactly like `wb_spi.v`'s own "the slave
// withholds ack until the transfer finishes" - the CPU sits in MEM until
// the fill completes, matching the one other slave in this SoC that
// already has real multi-cycle wait states. A BLIT_STATUS *read* is the
// one exception, acked immediately regardless of busy, because polling it
// is the entire point of a non-blocking engine: a program is expected to
// go do other work and come back to ask "done yet?", not to block on the
// fill the way it already blocks on an SPI transfer.
//
// ---- Why the rectangle is clamped, not rejected ----
// A width/height that would run past FB_WIDTH/FB_HEIGHT is silently
// clamped to the buffer's own edge rather than either faulting or writing
// out of bounds - the same "acks with zeros rather than wedging the bus"
// philosophy `docs/soc.md`'s address map section already states for a
// stray pointer: turning a programming mistake into a merely-wrong
// picture, not a hang or a corrupted neighbouring word. A rectangle whose
// *origin* is already off the buffer (X >= FB_WIDTH or Y >= FB_HEIGHT, or
// a zero width/height) draws nothing and completes as if it had - `busy`
// still pulses, so software that always waits for it to clear behaves
// identically whether the rectangle was real or degenerate.
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
    // Fill engine
    // =====================================================================
    reg [11:0] blit_x_r, blit_y_r, blit_w_r, blit_h_r;
    reg [7:0]  blit_color_r;
    reg        blit_busy_r;
    reg [11:0] blit_cur_x, blit_cur_y;
    reg [11:0] blit_x_end, blit_y_end;   // exclusive, already clamped to the buffer

    // Constant-parameter multiply, like Port B's pixel_index below - yosys
    // reduces this to shifts and an add, not a real multiplier. Sized like
    // pixel_index (32 bits) rather than to just what 320x240 needs, so it
    // matches that known-clean width rather than inviting a new mismatch.
    wire [31:0] blit_pixel_index = (blit_cur_y * FB_WIDTH) + {20'd0, blit_cur_x};
    wire [AW-1:0] blit_word_addr = blit_pixel_index[AW+1:2];
    wire [1:0]    blit_byte_lane = blit_pixel_index[1:0];

    // X+W and Y+H, each up to 4095+4095, computed a bit wider than either
    // operand so an oversized W/H clamps correctly instead of wrapping
    // around 12 bits and reading as "already in range."
    wire [12:0] blit_x_sum = {1'b0, blit_x_r} + {1'b0, blit_w_r};
    wire [12:0] blit_y_sum = {1'b0, blit_y_r} + {1'b0, blit_h_r};

    // =====================================================================
    // Port A: the bus
    // =====================================================================
    wire [AW-1:0] a_addr = wb_adr[AW+1:2];
    wire          is_blit_region = wb_adr[17];
    wire [2:0]    blit_reg_sel   = wb_adr[4:2];
    wire          is_status_read = is_blit_region && !wb_we && (blit_reg_sel == 3'd6);

    // A fill in progress withholds ack from everything except a STATUS
    // read - see the header for why. Address and byte-enables are still
    // sampled combinationally below; they simply do not commit until
    // `a_en` is true, the same "master holds until ack" contract every
    // other slave here already relies on.
    wire a_en = wb_cyc && wb_stb && (!blit_busy_r || is_status_read);

    reg        ack_r;
    reg [31:0] a_q;
    reg        blit_region_q;
    reg [2:0]  blit_reg_sel_q;

    // One wait state, matching wb_ram.v: address in the first cycle, data and
    // ack in the second. `!ack_r` keeps the ack a single cycle and stops the
    // write being applied twice while the master holds `stb`.
    always @(posedge clk or posedge rst) begin
        if (rst) ack_r <= 1'b0;
        else     ack_r <= a_en && !ack_r;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            blit_busy_r <= 1'b0;
        end else begin
            if (a_en && wb_we && !ack_r && !blit_busy_r) begin
                if (is_blit_region) begin
                    case (blit_reg_sel)
                        3'd0: blit_x_r     <= wb_dat_w[11:0];
                        3'd1: blit_y_r     <= wb_dat_w[11:0];
                        3'd2: blit_w_r     <= wb_dat_w[11:0];
                        3'd3: blit_h_r     <= wb_dat_w[11:0];
                        3'd4: blit_color_r <= wb_dat_w[7:0];
                        3'd5: if (wb_dat_w[0]) begin
                            // Clamp to the buffer's own edge (header
                            // comment above explains why this is a clamp,
                            // not a fault) and only actually start if the
                            // origin itself is on the buffer and the
                            // rectangle is non-empty.
                            blit_x_end <= (blit_x_sum > {1'b0, FB_WIDTH[11:0]})
                                          ? FB_WIDTH[11:0] : blit_x_sum[11:0];
                            blit_y_end <= (blit_y_sum > {1'b0, FB_HEIGHT[11:0]})
                                          ? FB_HEIGHT[11:0] : blit_y_sum[11:0];
                            blit_cur_x <= blit_x_r;
                            blit_cur_y <= blit_y_r;
                            if (blit_w_r != 12'd0 && blit_h_r != 12'd0 &&
                                blit_x_r < FB_WIDTH[11:0] && blit_y_r < FB_HEIGHT[11:0])
                                blit_busy_r <= 1'b1;
                        end
                        default: ; // BLIT_STATUS is read-only
                    endcase
                end else begin
                    if (wb_sel[0]) mem[a_addr][7:0]   <= wb_dat_w[7:0];
                    if (wb_sel[1]) mem[a_addr][15:8]  <= wb_dat_w[15:8];
                    if (wb_sel[2]) mem[a_addr][23:16] <= wb_dat_w[23:16];
                    if (wb_sel[3]) mem[a_addr][31:24] <= wb_dat_w[31:24];
                end
            end

            if (blit_busy_r) begin
                case (blit_byte_lane)
                    2'd0: mem[blit_word_addr][7:0]   <= blit_color_r;
                    2'd1: mem[blit_word_addr][15:8]  <= blit_color_r;
                    2'd2: mem[blit_word_addr][23:16] <= blit_color_r;
                    default: mem[blit_word_addr][31:24] <= blit_color_r;
                endcase
                if (blit_cur_x + 12'd1 >= blit_x_end) begin
                    blit_cur_x <= blit_x_r;
                    if (blit_cur_y + 12'd1 >= blit_y_end) blit_busy_r <= 1'b0;
                    else blit_cur_y <= blit_cur_y + 12'd1;
                end else begin
                    blit_cur_x <= blit_cur_x + 12'd1;
                end
            end
        end

        a_q            <= mem[a_addr];
        blit_region_q  <= is_blit_region;
        blit_reg_sel_q <= blit_reg_sel;
    end

    reg [31:0] blit_reg_rdata;
    always @(*) begin
        case (blit_reg_sel_q)
            3'd0: blit_reg_rdata = {20'b0, blit_x_r};
            3'd1: blit_reg_rdata = {20'b0, blit_y_r};
            3'd2: blit_reg_rdata = {20'b0, blit_w_r};
            3'd3: blit_reg_rdata = {20'b0, blit_h_r};
            3'd4: blit_reg_rdata = {24'b0, blit_color_r};
            3'd6: blit_reg_rdata = {31'b0, blit_busy_r};
            default: blit_reg_rdata = 32'b0; // BLIT_CTRL and unused offsets: WARL zero
        endcase
    end

    assign wb_dat_r = blit_region_q ? blit_reg_rdata : a_q;
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
    wire _unused_ok = &{1'b0, wb_adr[31:18], wb_adr[1:0],
                        pixel_index[31:AW+2], 1'b0};
endmodule
