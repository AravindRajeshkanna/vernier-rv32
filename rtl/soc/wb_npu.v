// Wishbone B4 classic quantized-inference MAC engine (Phase 14): a fixed-
// depth int8 dot product, one multiply-accumulate per cycle into a 32-bit
// signed accumulator. docs/roadmap.md's Phase 14 entry names the open
// design question this answers - custom instructions versus a memory-mapped
// peripheral - and picks the peripheral: a self-contained Wishbone slave,
// matching Phase 10's blit engine and Phase 4's video path, that cannot
// destabilize either core's own timing-critical decode/hazard logic the way
// reaching into rtl/cpu_core.v/rtl/ooo/core_ooo.v directly would.
//
// One MAC per cycle, not a combinational VEC_LEN-wide multiply-add tree,
// for the same reason rtl/muldiv_div.v is a 32-iteration sequential divider
// rather than a combinational one: this project's own house style keeps
// compute-heavy datapaths sequential and simple to verify rather than wide
// and combinational, and a real inference workload's vectors only get
// longer from here - a streamed, one-element-per-cycle engine is the shape
// that scales, a wide combinational one is not.
//
// Register map (word accesses; CTRL/A*/W* writes are ignored while busy,
// matching wb_framebuffer.v's own BLIT_CTRL/BLIT_STATUS convention exactly -
// "ignored if already busy" rather than queued or errored):
//   0x00 CTRL    (WO) - bit0: start (pulse; ignored if BUSY)
//   0x04 STATUS  (RO) - bit0: BUSY
//   0x08 A0..A3  (RW) - activation vector, 4 int8 lanes per word,
//                       little-endian (byte 0 = element 4*n, byte 3 =
//                       element 4*n+3), n = (offset-0x08)/4
//   0x18 W0..W3  (RW) - weight vector, same packing
//   0x28 RESULT  (RO) - signed 32-bit accumulated dot product, valid once
//                       BUSY reads 0 after a start
//
// VEC_LEN=16 is a real, if small, first vector depth - enough to prove the
// mechanism (operand loading, streamed MAC, accumulation, busy/done) without
// the register-map size or verification cost of something bigger. A longer
// vector is a wider register map and a wider `idx_r`, not a redesign - see
// docs/roadmap.md's Phase 14 entry for why a fixed, MMIO-loaded depth is
// deliberately this stage's own scope, and what a real small-model workload
// (Phase 14's own "Done when" bar) still needs beyond it: operands loaded
// this way come from software one word at a time, which does not scale to
// a real layer's own operand count - a bus-master port reading vectors
// directly out of RAM, the same role rtl/soc/wb_ptw.v plays for page-table
// walks, is the natural next stage and is not attempted here.
module wb_npu #(
    parameter VEC_LEN = 16
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    output reg  [31:0] wb_dat_r,
    output wire        wb_ack
);
    localparam NWORDS = VEC_LEN / 4;   // words per vector; VEC_LEN=16 -> 4

    localparam [7:0] OFF_CTRL   = 8'h00;
    localparam [7:0] OFF_STATUS = 8'h04;
    localparam [7:0] OFF_A0     = 8'h08;
    localparam [7:0] OFF_W0     = 8'h18;
    localparam [7:0] OFF_RESULT = 8'h28;

    wire [7:0] a      = wb_adr[7:0];
    wire       active = wb_cyc && wb_stb;
    wire       wr     = active && wb_we;

    // Word index within the A/W register block this access names, valid
    // only when `is_a_word`/`is_w_word` is set - matches wb_timer.v's own
    // "compute the index unconditionally, gate its use with a range check"
    // shape rather than a NWORDS-branch case, since NWORDS is a parameter
    // here and a case would have to be generated to track it.
    wire is_a_word  = active && (a >= OFF_A0) && (a < OFF_A0 + 4*NWORDS) && (a[1:0] == 2'b00);
    wire is_w_word  = active && (a >= OFF_W0) && (a < OFF_W0 + 4*NWORDS) && (a[1:0] == 2'b00);
    wire [7:0] a_word_idx = (a - OFF_A0) >> 2;
    wire [7:0] w_word_idx = (a - OFF_W0) >> 2;

    reg signed [7:0] a_mem [0:VEC_LEN-1];
    reg signed [7:0] w_mem [0:VEC_LEN-1];
    reg        signed [31:0] result_r;
    reg        busy_r;
    reg [$clog2(VEC_LEN)-1:0] idx_r;
    // An explicitly IDXW-bit copy of VEC_LEN-1, matching idx_r's own
    // width exactly, for the "last element" comparison below - the same
    // fix (and the same reason) rtl/plic.v's NUM_CONTEXTS_W8 and
    // rtl/clint.v's NUM_HARTS_W14 already needed: VEC_LEN is a plain,
    // unsized parameter, so comparing idx_r directly against `VEC_LEN - 1`
    // gets Verilator's own width inference a wider intermediate type than
    // idx_r's own declared width, tripping a spurious widen-on-comparison
    // warning even though the real values are identical.
    localparam IDXW = $clog2(VEC_LEN);
    localparam [31:0] VEC_LEN_M1 = VEC_LEN - 1;
    localparam [IDXW-1:0] IDX_LAST = VEC_LEN_M1[IDXW-1:0];

    integer i;

    // ---- operand load (A/W registers), only while not busy ----
    // A same-cycle CTRL start and an operand write both target state this
    // block or the MAC block below owns exclusively - no case here
    // conflicts with the MAC state machine's own always block, since they
    // never write the same registers.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < VEC_LEN; i = i + 1) begin
                a_mem[i] <= 8'sd0;
                w_mem[i] <= 8'sd0;
            end
        end else if (wr && !busy_r) begin
            if (is_a_word) begin
                a_mem[4*a_word_idx + 0] <= wb_dat_w[7:0];
                a_mem[4*a_word_idx + 1] <= wb_dat_w[15:8];
                a_mem[4*a_word_idx + 2] <= wb_dat_w[23:16];
                a_mem[4*a_word_idx + 3] <= wb_dat_w[31:24];
            end else if (is_w_word) begin
                w_mem[4*w_word_idx + 0] <= wb_dat_w[7:0];
                w_mem[4*w_word_idx + 1] <= wb_dat_w[15:8];
                w_mem[4*w_word_idx + 2] <= wb_dat_w[23:16];
                w_mem[4*w_word_idx + 3] <= wb_dat_w[31:24];
            end
        end
    end

    // ---- the MAC engine itself: one element per cycle ----
    // `busy_r` clears the same cycle the last element accumulates, not one
    // cycle later - STATUS reads 0 as early as the result is genuinely
    // final, matching the blit engine's own "busy_r deasserts on the
    // finishing cycle, not after it" timing.
    wire start_pulse = wr && !busy_r && (a == OFF_CTRL) && wb_dat_w[0];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy_r   <= 1'b0;
            idx_r    <= {$clog2(VEC_LEN){1'b0}};
            result_r <= 32'sd0;
        end else if (busy_r) begin
            result_r <= result_r + ($signed(a_mem[idx_r]) * $signed(w_mem[idx_r]));
            if (idx_r == IDX_LAST) begin
                busy_r <= 1'b0;
            end else begin
                idx_r <= idx_r + 1'b1;
            end
        end else if (start_pulse) begin
            busy_r   <= 1'b1;
            idx_r    <= {$clog2(VEC_LEN){1'b0}};
            result_r <= 32'sd0;
        end
    end

    // ---- reads ----
    always @(*) begin
        if (a == OFF_STATUS) begin
            wb_dat_r = {31'b0, busy_r};
        end else if (a == OFF_RESULT) begin
            wb_dat_r = result_r;
        end else if (is_a_word) begin
            wb_dat_r = {a_mem[4*a_word_idx+3], a_mem[4*a_word_idx+2],
                        a_mem[4*a_word_idx+1], a_mem[4*a_word_idx+0]};
        end else if (is_w_word) begin
            wb_dat_r = {w_mem[4*w_word_idx+3], w_mem[4*w_word_idx+2],
                        w_mem[4*w_word_idx+1], w_mem[4*w_word_idx+0]};
        end else begin
            wb_dat_r = 32'b0;   // OFF_CTRL and unused offsets: WARL zero
        end
    end

    // Zero wait states, matching wb_timer.v/wb_gpio.v: every access acks
    // the same cycle, including a write that `!busy_r` above silently
    // ignores - the blit engine's own "ignored if already busy" contract
    // is honored by the write having no effect, not by stalling the bus.
    assign wb_ack = active;
endmodule
