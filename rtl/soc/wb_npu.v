// Wishbone B4 classic quantized-inference MAC engine (Phase 14): a fixed-
// depth int8 dot product, one multiply-accumulate per cycle into a 32-bit
// signed accumulator. docs/roadmap.md's Phase 14 entry names the open
// design question this answers - custom instructions versus a memory-mapped
// peripheral - and picks the peripheral: a self-contained Wishbone slave,
// matching Phase 10's blit engine and Phase 4's video path, that cannot
// destabilize either core's own timing-critical decode/hazard logic the way
// reaching into rtl/cpu_core.v/rtl/ooo/core_ooo.v directly would.
//
// One MAC per cycle, not a combinational multiply-add tree, for the same
// reason rtl/muldiv_div.v is a 32-iteration sequential divider rather than
// a combinational one: this project's own house style keeps compute-heavy
// datapaths sequential and simple to verify rather than wide and
// combinational.
//
// ---- Two ways to load operands: the original MMIO path, and DMA ----
//
// Stage 1 shipped a fixed VEC_LEN=16 vector loaded one MMIO word at a time
// (A0-A3/W0-W3 below) - real, but named plainly as not scaling to a real
// layer's own operand count, since software has to write every element by
// hand before a single MAC can run. This stage adds a second, independent
// way to reach the same MAC engine: a Wishbone bus-master port
// (m_cyc/m_stb/m_adr/m_dat_r/m_ack) that streams operands directly out of
// RAM, the same role rtl/soc/wb_ptw.v plays for page-table walks. A_ADDR/
// W_ADDR/LEN below configure it; CTRL bit 1 starts it. LEN is a runtime
// register, not a synthesis-time parameter, so a DMA-driven vector is not
// capped at VEC_LEN the way the MMIO path still is - the whole point of
// this stage.
//
// The two paths are independent alternatives sharing the same accumulator
// and STATUS/RESULT registers - not concurrent, not combined. Starting one
// while the other is running is impossible by construction: both starts
// are gated on `!busy_r`, the same guard every register write already
// respects.
//
// Register map (word accesses; every write below is ignored while busy,
// matching wb_framebuffer.v's own BLIT_CTRL/BLIT_STATUS convention exactly -
// "ignored if already busy" rather than queued or errored):
//   0x00 CTRL    (WO) - bit0: start MMIO-mode MAC (pulse; ignored if BUSY)
//                        bit1: start DMA-mode MAC (pulse; ignored if BUSY)
//   0x04 STATUS  (RO) - bit0: BUSY
//   0x08 A0..A3  (RW) - activation vector, 4 int8 lanes per word,
//                       little-endian (byte 0 = element 4*n, byte 3 =
//                       element 4*n+3), n = (offset-0x08)/4. MMIO mode only.
//   0x18 W0..W3  (RW) - weight vector, same packing. MMIO mode only.
//   0x28 RESULT  (RO) - signed 32-bit accumulated dot product, valid once
//                       BUSY reads 0 after a start (either mode)
//   0x30 A_ADDR  (RW) - DMA mode: byte address of the activation vector in
//                       RAM, same 4-lanes-per-word little-endian packing
//   0x34 W_ADDR  (RW) - DMA mode: byte address of the weight vector in RAM
//   0x38 LEN     (RW) - DMA mode: element count, any value - not tied to
//                       VEC_LEN, which DMA mode does not use at all
//
// VEC_LEN=16 (the MMIO path's own fixed depth) is unchanged from Stage 1 -
// still real, if small, and now clearly the *smaller* of two ways to reach
// this engine rather than the only one.
module wb_npu #(
    parameter VEC_LEN = 16
)(
    input  wire        clk,
    input  wire        rst,

    // ---- Wishbone slave: the register interface (CTRL/STATUS/A*/W*/
    // RESULT/A_ADDR/W_ADDR/LEN), driven by the CPU ----
    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    output reg  [31:0] wb_dat_r,
    output wire        wb_ack,

    // ---- Wishbone master: DMA reads of the A/W vectors out of RAM ----
    // Read-only, matching rtl/soc/wb_ptw.v's own master port shape exactly -
    // no wb_we/wb_dat_w/wb_sel, since this module never writes memory.
    output wire        m_cyc,
    output wire        m_stb,
    output wire [31:0] m_adr,
    input  wire [31:0] m_dat_r,
    input  wire        m_ack
);
    localparam NWORDS = VEC_LEN / 4;   // words per vector; VEC_LEN=16 -> 4

    localparam [7:0] OFF_CTRL   = 8'h00;
    localparam [7:0] OFF_STATUS = 8'h04;
    localparam [7:0] OFF_A0     = 8'h08;
    localparam [7:0] OFF_W0     = 8'h18;
    localparam [7:0] OFF_RESULT = 8'h28;
    localparam [7:0] OFF_A_ADDR = 8'h30;
    localparam [7:0] OFF_W_ADDR = 8'h34;
    localparam [7:0] OFF_LEN    = 8'h38;

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

    // ---- DMA mode state ----
    reg [31:0] a_addr_r, w_addr_r, len_r;
    reg [31:0] a_word_buf, w_word_buf;
    reg [31:0] dma_word_idx;    // which 4-element word of the vectors
    reg [1:0]  dma_byte_idx;    // which byte (0-3) within the current word
    reg [31:0] dma_elem_count;  // total elements processed so far, vs len_r

    localparam [2:0] S_IDLE        = 3'd0,
                     S_MMIO_MAC    = 3'd1,
                     S_DMA_FETCH_A = 3'd2,
                     S_DMA_FETCH_W = 3'd3,
                     S_DMA_MAC     = 3'd4;
    reg [2:0] state_r;

    assign m_cyc = (state_r == S_DMA_FETCH_A) || (state_r == S_DMA_FETCH_W);
    assign m_stb = m_cyc;
    // dma_word_idx << 2: 4 bytes per word, same packing OFF_A0/OFF_W0's
    // own a_word_idx/w_word_idx already use. A 32-bit shift left, top bits
    // discarded - address wraparound at the 4 GB boundary, never reached
    // in practice.
    assign m_adr = (state_r == S_DMA_FETCH_A) ? (a_addr_r + (dma_word_idx << 2))
                                               : (w_addr_r + (dma_word_idx << 2));

    integer i;

    // ---- operand load (A/W registers) and DMA config registers, only
    // while not busy ----
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
            a_addr_r <= 32'b0;
            w_addr_r <= 32'b0;
            len_r    <= 32'b0;
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
            end else if (a == OFF_A_ADDR) begin
                a_addr_r <= wb_dat_w;
            end else if (a == OFF_W_ADDR) begin
                w_addr_r <= wb_dat_w;
            end else if (a == OFF_LEN) begin
                len_r <= wb_dat_w;
            end
        end
    end

    // ---- the MAC engine itself: one element per cycle, either mode ----
    // `busy_r` clears the same cycle the last element accumulates, not one
    // cycle later - STATUS reads 0 as early as the result is genuinely
    // final, matching the blit engine's own "busy_r deasserts on the
    // finishing cycle, not after it" timing. True in both modes below.
    wire start_pulse     = wr && !busy_r && (a == OFF_CTRL) && wb_dat_w[0];
    wire start_dma_pulse = wr && !busy_r && (a == OFF_CTRL) && wb_dat_w[1];

    // Signed bytes at the currently-selected lane of the two DMA word
    // buffers - a dynamic part-select (base = 8*dma_byte_idx, a variable
    // 0/8/16/24; width fixed at 8), the same +: idiom this file's own
    // A0-A3/W0-W3 packing above already relies on, just indexed at run
    // time here instead of by a compile-time offset.
    wire signed [7:0] dma_a_byte = a_word_buf[8*dma_byte_idx +: 8];
    wire signed [7:0] dma_w_byte = w_word_buf[8*dma_byte_idx +: 8];

    // True on the cycle S_DMA_MAC processes the vector's last element -
    // dma_elem_count has not yet been incremented for it, so this compares
    // against len_r-1, not len_r.
    wire dma_last_elem = (dma_elem_count == len_r - 32'd1);
    wire dma_word_done = (dma_byte_idx == 2'd3) || dma_last_elem;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy_r         <= 1'b0;
            idx_r          <= {$clog2(VEC_LEN){1'b0}};
            result_r       <= 32'sd0;
            state_r        <= S_IDLE;
            dma_word_idx   <= 32'b0;
            dma_byte_idx   <= 2'b0;
            dma_elem_count <= 32'b0;
            a_word_buf     <= 32'b0;
            w_word_buf     <= 32'b0;
        end else begin
            case (state_r)
                S_IDLE: begin
                    if (start_pulse) begin
                        busy_r   <= 1'b1;
                        idx_r    <= {$clog2(VEC_LEN){1'b0}};
                        result_r <= 32'sd0;
                        state_r  <= S_MMIO_MAC;
                    end else if (start_dma_pulse) begin
                        busy_r         <= 1'b1;
                        result_r       <= 32'sd0;
                        dma_word_idx   <= 32'b0;
                        dma_byte_idx   <= 2'b0;
                        dma_elem_count <= 32'b0;
                        state_r        <= S_DMA_FETCH_A;
                    end
                end

                S_MMIO_MAC: begin
                    result_r <= result_r + ($signed(a_mem[idx_r]) * $signed(w_mem[idx_r]));
                    if (idx_r == IDX_LAST) begin
                        busy_r  <= 1'b0;
                        state_r <= S_IDLE;
                    end else begin
                        idx_r <= idx_r + 1'b1;
                    end
                end

                // Hold m_cyc/m_stb (combinational, above) until the bus
                // acks - a multi-cycle wait is exactly what rtl/soc/
                // wb_interconnect.v's own lock mechanism exists to make
                // safe, the same contract rtl/soc/wb_ptw.v already relies
                // on for its own two walkers.
                S_DMA_FETCH_A: begin
                    if (m_ack) begin
                        a_word_buf <= m_dat_r;
                        state_r    <= S_DMA_FETCH_W;
                    end
                end
                S_DMA_FETCH_W: begin
                    if (m_ack) begin
                        w_word_buf <= m_dat_r;
                        state_r    <= S_DMA_MAC;
                    end
                end

                S_DMA_MAC: begin
                    result_r       <= result_r + ($signed(dma_a_byte) * $signed(dma_w_byte));
                    dma_elem_count <= dma_elem_count + 32'd1;
                    if (dma_last_elem) begin
                        busy_r  <= 1'b0;
                        state_r <= S_IDLE;
                    end else if (dma_word_done) begin
                        dma_byte_idx <= 2'b0;
                        dma_word_idx <= dma_word_idx + 32'd1;
                        state_r      <= S_DMA_FETCH_A;
                    end else begin
                        dma_byte_idx <= dma_byte_idx + 2'd1;
                    end
                end

                default: state_r <= S_IDLE;
            endcase
        end
    end

    // ---- reads ----
    always @(*) begin
        if (a == OFF_STATUS) begin
            wb_dat_r = {31'b0, busy_r};
        end else if (a == OFF_RESULT) begin
            wb_dat_r = result_r;
        end else if (a == OFF_A_ADDR) begin
            wb_dat_r = a_addr_r;
        end else if (a == OFF_W_ADDR) begin
            wb_dat_r = w_addr_r;
        end else if (a == OFF_LEN) begin
            wb_dat_r = len_r;
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

    // Zero wait states on the slave side, matching wb_timer.v/wb_gpio.v:
    // every access acks the same cycle, including a write that `!busy_r`
    // above silently ignores - the blit engine's own "ignored if already
    // busy" contract is honored by the write having no effect, not by
    // stalling the bus. The master side (m_cyc/m_ack above) is the one
    // that genuinely waits, for real bus cycles this module does not
    // control.
    assign wb_ack = active;
endmodule
