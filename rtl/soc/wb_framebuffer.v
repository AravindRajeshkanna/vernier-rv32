// Wishbone B4 classic framebuffer: a block-RAM pixel buffer the CPU writes
// into, scanned out by video_timing.v - plus a small fill/copy/line engine,
// Phase 10 stages 1-3 (docs/roadmap.md).
//
// This was a *display controller*, not a GPU in the compute sense: no
// drawing engine, no blitter, no second core - the CPU wrote every pixel
// itself, in a software loop. That split was deliberate for a first
// version, and this module's own header used to say so explicitly: "it
// adds no bus master, so the interconnect's two-master arbitration is
// untouched." The engine below keeps that promise - it is entirely
// internal to this module's existing Wishbone slave port, reusing the
// same address window rather than adding a new slave or a new master.
// docs/roadmap.md's Phase 10 entry has the reasoning for why *this* is
// the first increment (peripheral-sized, not core-sized) and what a
// real 3D pipeline would cost beyond it.
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
//   bit 17 = 1   the engine's control block, at FB_BASE + 0x20000:
//
//     0x00  BLIT_X       RW  point 0: left edge (fill/copy dest) or X0 (line)
//     0x04  BLIT_Y       RW  point 0: top edge (fill/copy dest) or Y0 (line)
//     0x08  BLIT_W       RW  width (fill/copy only)
//     0x0C  BLIT_H       RW  height (fill/copy only)
//     0x10  BLIT_COLOR   RW  colour, RRRGGGBB in bits [7:0] (fill/line only)
//     0x14  BLIT_CTRL    WO  bit 0 = start, bits [2:1] = op
//                             (0=fill, 1=copy, 2=line); ignored if already busy
//     0x18  BLIT_STATUS  RO  bit 0 = busy
//     0x1C  BLIT_SRC_X   RW  point 1: source left edge (copy) or X1 (line)
//     0x20  BLIT_SRC_Y   RW  point 1: source top edge (copy) or Y1 (line)
//
// Matches `wb_spi.v`'s own CTRL/STATUS naming (`docs/soc.md`) rather than
// inventing a new convention - STATUS.busy is exactly SPI's own pattern,
// reused because it already says the right thing. Every operation shares
// the same eight registers rather than each getting its own: BLIT_X/Y is
// "point 0" (a fill's rectangle origin, a copy's destination, a line's
// first endpoint) and BLIT_SRC_X/Y is "point 1" (a copy's source, a
// line's second endpoint) - reusing the same two-point shape rather than
// adding a dedicated register pair per operation. BLIT_W/H mean nothing
// to a line, and BLIT_COLOR means nothing to a copy; each op simply
// ignores the registers it has no use for, the same way BLIT_COLOR
// already went unused by copy.
//
// ---- Why an engine op blocks the CPU out of pixel data, but not STATUS ----
// The engine and the CPU's own Port A share one write port into `mem[]` -
// the same one the CPU has always written pixels through. While an
// operation is running, a CPU access to pixel data (or to any *other*
// blit register) simply is not acked, exactly like `wb_spi.v`'s own "the
// slave withholds ack until the transfer finishes" - the CPU sits in MEM
// until the operation completes, matching the one other slave in this SoC
// that already has real multi-cycle wait states. A BLIT_STATUS *read* is
// the one exception, acked immediately regardless of busy, because
// polling it is the entire point of a non-blocking engine: a program is
// expected to go do other work and come back to ask "done yet?", not to
// block on the fill the way it already blocks on an SPI transfer.
//
// ---- Why a rectangle is clamped, not rejected ----
// A width/height that would run a destination (or, for copy, a source)
// past FB_WIDTH/FB_HEIGHT is silently clamped to the buffer's own edge
// rather than either faulting or writing out of bounds - the same "acks
// with zeros rather than wedging the bus" philosophy `docs/soc.md`'s
// address map section already states for a stray pointer: turning a
// programming mistake into a merely-wrong picture, not a hang or a
// corrupted neighbouring word. A rectangle whose *origin* is already off
// the buffer (X >= FB_WIDTH or Y >= FB_HEIGHT on either side for copy, or
// a zero width/height) draws or copies nothing and completes as if it
// had - `busy` still pulses, so software that always waits for it to
// clear behaves identically whether the rectangle was real or degenerate.
//
// ---- Copy: overlap-safe, and honestly two cycles per pixel ----
// A copy is a rigid translation of a rectangle by a fixed (dx,dy) offset,
// and destination and source are allowed to overlap - the common real use
// is scrolling part of the screen. `mem[]` has exactly two ports: this
// one (read+write, shared with the CPU) and the scan-out port, which is
// permanently committed to the live raster and cannot be borrowed even
// for one cycle without corrupting the picture on screen. With only one
// read+write port available, copying a pixel is a source *read* and a
// destination *write*, and a single port cannot do both to different
// addresses in the same cycle - so a copy runs at one pixel per **two**
// cycles, half a fill's rate. That is a real hardware cost of sharing the
// port, not a design shortcut, and `sim/tb_blit.v` measures it directly
// rather than asserting it.
//
// Overlap safety is the standard 2D-blit technique (the same one behind
// `memmove`, and behind every BitBLT-style engine that allows overlapping
// source and destination): choose the row order and the column order
// independently, backward whenever the destination is on the
// higher-address side of the source on that axis, forward otherwise. That
// guarantees every source pixel is read before anything could overwrite
// it, for *any* relative offset - not just a pure horizontal or vertical
// shift - because a row (or column) is only ever written after every
// pixel that will still be read from it has already been read.
// `sim/tb_blit.v` proves this against a directional overlap in each of
// the four quadrants, not just the non-overlapping case.
//
// ---- Line: Bresenham, one write per cycle, unclipped ----
// Standard integer Bresenham (the "dy stored negative" formulation), which
// is what makes it hardware-friendly in the first place: no floating
// point, no division, one comparison and one or two additions per pixel.
// It naturally covers all eight octants and the degenerate single-point
// case (X0=X1, Y0=Y1 - dx=dy=0, the first and only plotted pixel is
// immediately also the endpoint) with no special-casing.
//
// A line is not clamped to a rectangle the way a fill or copy is -
// clipping a line segment to a viewport is a genuinely different, more
// involved problem (Cohen-Sutherland and its relatives) than clamping an
// axis-aligned rectangle, and not one this stage takes on. Instead, every
// step checks whether the pixel it is about to plot actually falls inside
// the buffer and skips the write if not, while still stepping the
// algorithm forward - so a line that starts, ends, or passes outside the
// buffer draws only the portion that is actually visible, and completes
// in a bounded number of cycles either way (at most
// max(|X1-X0|,|Y1-Y0|)+1, the same order of magnitude a fill or copy
// already costs for a comparable span). A line's endpoints are otherwise
// unclamped and unchecked - unlike a fill or copy, there is no rectangle
// whose origin can be "off the buffer" to begin with.
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
    // Fill/copy/line engine
    // =====================================================================
    localparam [1:0] OP_FILL = 2'd0, OP_COPY = 2'd1, OP_LINE = 2'd2;

    reg [11:0] blit_x_r, blit_y_r, blit_w_r, blit_h_r;
    reg [7:0]  blit_color_r;
    reg [11:0] blit_src_x_r, blit_src_y_r;   // copy source origin, or line's (X1,Y1) - raw
    reg        blit_busy_r;
    reg [1:0]  blit_op_r;                    // OP_*; latched at kickoff
    reg        blit_xdir_r, blit_ydir_r;     // 0 = increasing, 1 = decreasing
    reg        copy_phase_r;                 // copy only: 0 = read issued, 1 = write+advance
    reg [11:0] blit_cur_x, blit_cur_y;        // current DESTINATION (or line) coordinate
    reg [11:0] blit_x_end, blit_y_end;        // fill/copy only: exclusive, clamped to the buffer

    // Line-only state: Bresenham's decision variable and the fixed end
    // point, stored the "dy negative" way so both step conditions below
    // are plain comparisons against err<<1. 13 bits signed covers a delta
    // up to +-4095 with headroom for err's own range.
    reg signed [12:0] line_dx_r, line_dy_r, line_err_r;
    reg [11:0] line_x1_r, line_y1_r;

    // Constant-parameter multiply, like Port B's pixel_index below - yosys
    // reduces this to shifts and an add, not a real multiplier. Sized like
    // pixel_index (32 bits) rather than to just what 320x240 needs, so it
    // matches that known-clean width rather than inviting a new mismatch.
    wire [31:0] blit_pixel_index = (blit_cur_y * FB_WIDTH) + {20'd0, blit_cur_x};
    wire [AW-1:0] blit_word_addr = blit_pixel_index[AW+1:2];
    wire [1:0]    blit_byte_lane = blit_pixel_index[1:0];

    // X+W and Y+H, each up to 4095+4095, computed a bit wider than either
    // operand so an oversized W/H clamps correctly instead of wrapping
    // around 12 bits and reading as "already in range." Used by fill.
    wire [12:0] blit_x_sum = {1'b0, blit_x_r} + {1'b0, blit_w_r};
    wire [12:0] blit_y_sum = {1'b0, blit_y_r} + {1'b0, blit_h_r};

    // Copy clamp: the effective size is the smallest of the requested size
    // and the room left on *either* side of the translation, so neither
    // rectangle can run off the buffer. Each operand here is already
    // guaranteed below FB_WIDTH/FB_HEIGHT whenever its _ok flag is set, so
    // (unlike blit_x_sum/blit_y_sum above) plain 12-bit arithmetic cannot
    // wrap - the kickoff logic below only ever uses these values when both
    // _ok flags are true.
    wire dst_x_ok = blit_x_r     < FB_WIDTH[11:0];
    wire dst_y_ok = blit_y_r     < FB_HEIGHT[11:0];
    wire src_x_ok = blit_src_x_r < FB_WIDTH[11:0];
    wire src_y_ok = blit_src_y_r < FB_HEIGHT[11:0];
    wire [11:0] dst_x_room = FB_WIDTH[11:0]  - blit_x_r;
    wire [11:0] dst_y_room = FB_HEIGHT[11:0] - blit_y_r;
    wire [11:0] src_x_room = FB_WIDTH[11:0]  - blit_src_x_r;
    wire [11:0] src_y_room = FB_HEIGHT[11:0] - blit_src_y_r;
    wire [11:0] copy_w_room = (dst_x_room < src_x_room) ? dst_x_room : src_x_room;
    wire [11:0] copy_h_room = (dst_y_room < src_y_room) ? dst_y_room : src_y_room;
    wire [11:0] copy_w_eff = (blit_w_r < copy_w_room) ? blit_w_r : copy_w_room;
    wire [11:0] copy_h_eff = (blit_h_r < copy_h_room) ? blit_h_r : copy_h_room;

    // Per-pixel advance, shared by fill (every cycle) and copy (write
    // cycles only): direction-aware so a copy can walk each axis backward
    // when the destination overlaps the source from the high side - see
    // the header comment on overlap safety.
    wire x_last_in_row = blit_xdir_r ? (blit_cur_x == blit_x_r)
                                      : (blit_cur_x + 12'd1 >= blit_x_end);
    wire [11:0] x_next      = blit_xdir_r ? (blit_cur_x - 12'd1) : (blit_cur_x + 12'd1);
    wire [11:0] x_row_start = blit_xdir_r ? (blit_x_end - 12'd1) : blit_x_r;
    wire y_last = blit_ydir_r ? (blit_cur_y == blit_y_r)
                               : (blit_cur_y + 12'd1 >= blit_y_end);
    wire [11:0] y_next = blit_ydir_r ? (blit_cur_y - 12'd1) : (blit_cur_y + 12'd1);

    // Copy's source coordinate for the pixel currently at (blit_cur_x,
    // blit_cur_y): the same offset from the destination's own start
    // corner, regardless of which direction got it there, so it tracks a
    // fixed (dx,dy) translation exactly.
    wire [11:0] copy_rel_x = blit_cur_x - blit_x_r;
    wire [11:0] copy_rel_y = blit_cur_y - blit_y_r;
    wire [11:0] copy_src_cur_x = blit_src_x_r + copy_rel_x;
    wire [11:0] copy_src_cur_y = blit_src_y_r + copy_rel_y;
    wire [31:0] copy_src_pixel_index =
        (copy_src_cur_y * FB_WIDTH) + {20'd0, copy_src_cur_x};
    wire [AW-1:0] copy_src_word_addr = copy_src_pixel_index[AW+1:2];
    wire [1:0]    copy_src_byte_lane = copy_src_pixel_index[1:0];

    // The byte the last read cycle captured into a_q, reused here rather
    // than adding a second capture register - a_q is otherwise unused
    // while busy, since pixel-data CPU reads are blocked during that time.
    wire [7:0] copy_src_byte = (copy_src_byte_lane == 2'd0) ? a_q[7:0]   :
                               (copy_src_byte_lane == 2'd1) ? a_q[15:8]  :
                               (copy_src_byte_lane == 2'd2) ? a_q[23:16] :
                                                               a_q[31:24];

    // Line kickoff: magnitude and direction per axis, computed from the
    // stable (already-written) endpoint registers so line_dx_r/line_dy_r
    // can be latched directly from these without a same-cycle
    // read-after-write hazard. blit_xdir_r/blit_ydir_r double as the
    // line's step sign (sx/sy), the same "0 = increasing" meaning they
    // already have for fill/copy.
    wire line_x_fwd = blit_src_x_r >= blit_x_r;
    wire line_y_fwd = blit_src_y_r >= blit_y_r;
    wire [11:0] line_adx = line_x_fwd ? (blit_src_x_r - blit_x_r) : (blit_x_r - blit_src_x_r);
    wire [11:0] line_ady = line_y_fwd ? (blit_src_y_r - blit_y_r) : (blit_y_r - blit_src_y_r);
    wire signed [12:0] line_dx_init =  $signed({1'b0, line_adx});
    wire signed [12:0] line_dy_init = -$signed({1'b0, line_ady});

    // Bresenham step, evaluated every busy cycle while OP_LINE: e2 = 2*err;
    // step x when e2 >= dy (dy stored negative), step y when e2 <= dx. Both
    // can fire the same cycle (a diagonal step) - see the header comment.
    wire signed [12:0] line_e2     = line_err_r <<< 1;
    wire               line_cond_x = line_e2 >= line_dy_r;
    wire               line_cond_y = line_e2 <= line_dx_r;
    wire               line_plot_ok = (blit_cur_x < FB_WIDTH[11:0]) &&
                                       (blit_cur_y < FB_HEIGHT[11:0]);

    // =====================================================================
    // Port A: the bus
    // =====================================================================
    wire [AW-1:0] a_addr = wb_adr[AW+1:2];
    wire          is_blit_region = wb_adr[17];
    wire [3:0]    blit_reg_sel   = wb_adr[5:2];
    wire          is_status_read = is_blit_region && !wb_we && (blit_reg_sel == 4'd6);

    // While a copy's read phase is in flight, Port A's one read reference
    // is redirected to the source pixel instead of the (stalled, and
    // during this phase irrelevant) CPU address - see the header comment
    // on why copying costs two cycles per pixel.
    wire [AW-1:0] effective_read_addr =
        (blit_busy_r && blit_op_r == OP_COPY && !copy_phase_r) ? copy_src_word_addr : a_addr;

    // A fill in progress withholds ack from everything except a STATUS
    // read - see the header for why. Address and byte-enables are still
    // sampled combinationally below; they simply do not commit until
    // `a_en` is true, the same "master holds until ack" contract every
    // other slave here already relies on.
    wire a_en = wb_cyc && wb_stb && (!blit_busy_r || is_status_read);

    reg        ack_r;
    reg [31:0] a_q;
    reg        blit_region_q;
    reg [3:0]  blit_reg_sel_q;

    // One wait state, matching wb_ram.v: address in the first cycle, data and
    // ack in the second. `!ack_r` keeps the ack a single cycle and stops the
    // write being applied twice while the master holds `stb`.
    always @(posedge clk or posedge rst) begin
        if (rst) ack_r <= 1'b0;
        else     ack_r <= a_en && !ack_r;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            blit_busy_r  <= 1'b0;
            blit_op_r    <= OP_FILL;
            blit_xdir_r  <= 1'b0;
            blit_ydir_r  <= 1'b0;
            copy_phase_r <= 1'b0;
        end else begin
            if (a_en && wb_we && !ack_r && !blit_busy_r) begin
                if (is_blit_region) begin
                    case (blit_reg_sel)
                        4'd0: blit_x_r     <= wb_dat_w[11:0];
                        4'd1: blit_y_r     <= wb_dat_w[11:0];
                        4'd2: blit_w_r     <= wb_dat_w[11:0];
                        4'd3: blit_h_r     <= wb_dat_w[11:0];
                        4'd4: blit_color_r <= wb_dat_w[7:0];
                        4'd5: if (wb_dat_w[0]) begin
                            blit_op_r <= wb_dat_w[2:1];
                            case (wb_dat_w[2:1])
                                OP_COPY: begin
                                    // ---- copy: clamp both rectangles
                                    // (header comment explains why a
                                    // clamp, not a fault), only start if
                                    // both origins are on the buffer and
                                    // the effective size is non-empty,
                                    // and pick each axis's direction so
                                    // an overlapping copy reads every
                                    // source pixel before anything can
                                    // overwrite it.
                                    if (dst_x_ok && dst_y_ok && src_x_ok && src_y_ok &&
                                        copy_w_eff != 12'd0 && copy_h_eff != 12'd0) begin
                                        blit_x_end  <= blit_x_r + copy_w_eff;
                                        blit_y_end  <= blit_y_r + copy_h_eff;
                                        blit_xdir_r <= (blit_x_r > blit_src_x_r);
                                        blit_ydir_r <= (blit_y_r > blit_src_y_r);
                                        blit_cur_x  <= (blit_x_r > blit_src_x_r)
                                                       ? (blit_x_r + copy_w_eff - 12'd1) : blit_x_r;
                                        blit_cur_y  <= (blit_y_r > blit_src_y_r)
                                                       ? (blit_y_r + copy_h_eff - 12'd1) : blit_y_r;
                                        copy_phase_r <= 1'b0;
                                        blit_busy_r  <= 1'b1;
                                    end
                                end
                                OP_LINE: begin
                                    // ---- line: no start-gating - even a
                                    // fully off-buffer or single-point
                                    // line is well-defined (see header
                                    // comment) and always completes in a
                                    // bounded number of cycles.
                                    line_dx_r   <= line_dx_init;
                                    line_dy_r   <= line_dy_init;
                                    line_err_r  <= line_dx_init + line_dy_init;
                                    blit_xdir_r <= !line_x_fwd;
                                    blit_ydir_r <= !line_y_fwd;
                                    line_x1_r   <= blit_src_x_r;
                                    line_y1_r   <= blit_src_y_r;
                                    blit_cur_x  <= blit_x_r;
                                    blit_cur_y  <= blit_y_r;
                                    blit_busy_r <= 1'b1;
                                end
                                default: begin
                                    // ---- fill: as stage 1, always forward ----
                                    blit_x_end <= (blit_x_sum > {1'b0, FB_WIDTH[11:0]})
                                                  ? FB_WIDTH[11:0] : blit_x_sum[11:0];
                                    blit_y_end <= (blit_y_sum > {1'b0, FB_HEIGHT[11:0]})
                                                  ? FB_HEIGHT[11:0] : blit_y_sum[11:0];
                                    blit_xdir_r <= 1'b0;
                                    blit_ydir_r <= 1'b0;
                                    blit_cur_x  <= blit_x_r;
                                    blit_cur_y  <= blit_y_r;
                                    if (blit_w_r != 12'd0 && blit_h_r != 12'd0 &&
                                        blit_x_r < FB_WIDTH[11:0] && blit_y_r < FB_HEIGHT[11:0])
                                        blit_busy_r <= 1'b1;
                                end
                            endcase
                        end
                        4'd7: blit_src_x_r <= wb_dat_w[11:0];
                        4'd8: blit_src_y_r <= wb_dat_w[11:0];
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
                if (blit_op_r == OP_COPY && !copy_phase_r) begin
                    // Copy's read phase: the source word is being fetched
                    // into a_q via effective_read_addr this cycle, valid
                    // next cycle. Nothing to write yet.
                    copy_phase_r <= 1'b1;
                end else if (blit_op_r == OP_LINE) begin
                    // Line: one write attempt per cycle (skipped, not
                    // stalled, when the current pixel is off the buffer -
                    // see the header comment), then a Bresenham step.
                    if (line_plot_ok) begin
                        case (blit_byte_lane)
                            2'd0: mem[blit_word_addr][7:0]   <= blit_color_r;
                            2'd1: mem[blit_word_addr][15:8]  <= blit_color_r;
                            2'd2: mem[blit_word_addr][23:16] <= blit_color_r;
                            default: mem[blit_word_addr][31:24] <= blit_color_r;
                        endcase
                    end
                    if (blit_cur_x == line_x1_r && blit_cur_y == line_y1_r) begin
                        blit_busy_r <= 1'b0;
                    end else begin
                        line_err_r <= line_err_r + (line_cond_x ? line_dy_r : 13'sd0)
                                                  + (line_cond_y ? line_dx_r : 13'sd0);
                        if (line_cond_x)
                            blit_cur_x <= blit_xdir_r ? (blit_cur_x - 12'd1) : (blit_cur_x + 12'd1);
                        if (line_cond_y)
                            blit_cur_y <= blit_ydir_r ? (blit_cur_y - 12'd1) : (blit_cur_y + 12'd1);
                    end
                end else begin
                    case (blit_byte_lane)
                        2'd0: mem[blit_word_addr][7:0]   <= (blit_op_r == OP_COPY) ? copy_src_byte : blit_color_r;
                        2'd1: mem[blit_word_addr][15:8]  <= (blit_op_r == OP_COPY) ? copy_src_byte : blit_color_r;
                        2'd2: mem[blit_word_addr][23:16] <= (blit_op_r == OP_COPY) ? copy_src_byte : blit_color_r;
                        default: mem[blit_word_addr][31:24] <= (blit_op_r == OP_COPY) ? copy_src_byte : blit_color_r;
                    endcase
                    if (blit_op_r == OP_COPY) copy_phase_r <= 1'b0;
                    if (x_last_in_row) begin
                        blit_cur_x <= x_row_start;
                        if (y_last) blit_busy_r <= 1'b0;
                        else        blit_cur_y <= y_next;
                    end else begin
                        blit_cur_x <= x_next;
                    end
                end
            end
        end
    end

    // Deliberately its own block, `posedge clk` only, no reset - exactly
    // how the original Port A read (`a_q <= mem[a_addr]`) was structured
    // before this engine existed. Folding this into the write-handling
    // block above (which does need `posedge rst`, for `blit_busy_r` and
    // the rest of the engine's state) gives yosys's `synth_ecp5` flow one
    // register whose reset behavior is genuinely ambiguous - reachable
    // from an async-reset-sensitive process, yet never assigned under
    // `if (rst)` - which it reports as "Multiple edge sensitive events
    // found for this signal" rather than inferring anything. Found via
    // real FPGA synthesis (`./fpga/synth/synth_ecp5.sh`), not simulation:
    // neither Icarus nor Verilator's own lint objects to this pattern, so
    // it shipped silently across three PRs before anything actually tried
    // to place and route the result. `blit_region_q`/`blit_reg_sel_q` ride
    // along in the same block for the same reason - they are read-mux
    // bookkeeping with no reset dependency of their own, exactly like
    // `a_q`.
    always @(posedge clk) begin
        a_q            <= mem[effective_read_addr];
        blit_region_q  <= is_blit_region;
        blit_reg_sel_q <= blit_reg_sel;
    end

    reg [31:0] blit_reg_rdata;
    always @(*) begin
        case (blit_reg_sel_q)
            4'd0: blit_reg_rdata = {20'b0, blit_x_r};
            4'd1: blit_reg_rdata = {20'b0, blit_y_r};
            4'd2: blit_reg_rdata = {20'b0, blit_w_r};
            4'd3: blit_reg_rdata = {20'b0, blit_h_r};
            4'd4: blit_reg_rdata = {24'b0, blit_color_r};
            4'd6: blit_reg_rdata = {31'b0, blit_busy_r};
            4'd7: blit_reg_rdata = {20'b0, blit_src_x_r};
            4'd8: blit_reg_rdata = {20'b0, blit_src_y_r};
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
