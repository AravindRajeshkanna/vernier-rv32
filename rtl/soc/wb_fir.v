// Wishbone B4 classic streaming FIR filter coprocessor (Phase 11): a fixed-
// depth finite impulse response filter, one multiply-accumulate per cycle
// into a saturating signed accumulator. docs/roadmap.md's Phase 11 entry
// names the open design question this answers - hardware float, packed
// SIMD, or a dedicated coprocessor - and picks the coprocessor: a
// self-contained Wishbone slave, matching Phase 14's own wb_npu.v and
// Phase 10's blit engine, that cannot destabilize either core's own
// timing-critical decode/hazard logic the way a new rtl/cpu_core.v
// execution unit would.
//
// ---- What is genuinely new here, not just a copy of wb_npu.v ----
//
// wb_npu.v computes one dot product from two vectors loaded once, then
// stops. A real DSP filter is not "load data once, compute once" - it is
// "one new sample arrives, one new output comes out, forever," which needs
// state this module's predecessor never had to carry: a sliding window of
// the last N_TAPS input samples (the delay line every FIR filter textbook
// draws), shifted on every new sample rather than loaded fresh.
//
// It also needs a real answer to overflow that a bounded int8 dot product
// never had to give. Two 16-bit samples multiply to a 32-bit product, and
// summing N_TAPS of them can exceed 32 bits (worst case, N_TAPS=8: up to
// roughly 2^33) - accumulated here in a 40-bit register, wide enough that
// this specific worst case cannot overflow it, then **saturated** (clamped
// to INT32_MIN/INT32_MAX), not silently wrapped, into the 32-bit OUTPUT
// register. Wrapping is how a real fixed-point audio path produces a
// jarring wraparound pop instead of a clipped-but-recognizable waveform;
// saturation is the standard, correct behavior every real fixed-point DSP
// core implements, not an approximation of it.
//
// One MAC per cycle, not a combinational N_TAPS-wide multiply-add tree,
// the same rtl/muldiv_div.v/wb_npu.v precedent: a streamed, sequential
// datapath is simpler to verify and scales to more taps without redesign.
//
// Register map (word accesses; every write below is ignored while busy,
// matching wb_npu.v's/wb_framebuffer.v's own convention - "ignored if
// already busy" rather than queued or errored):
//   0x00 CTRL    (WO) - bit0: reset (pulse; ignored if BUSY) - clears the
//                        history buffer and OUTPUT to 0, coefficients
//                        untouched
//   0x04 STATUS  (RO) - bit0: BUSY
//   0x08 COEF0..COEF7 (RW) - h[0..N_TAPS-1], signed 16-bit each (low
//                        half of the word; read back sign-extended)
//   0x28 INPUT   (WO) - low 16 bits: a new signed sample x[n]. Writing it
//                        shifts the history buffer (the oldest sample is
//                        dropped) and starts a new N_TAPS-cycle MAC over
//                        the updated window; ignored while BUSY
//   0x2C OUTPUT  (RO) - saturated signed 32-bit y[n] = sum(h[k] *
//                        history[k]), valid once BUSY reads 0 after an
//                        INPUT write
//
// N_TAPS=8 is a real, if small, first filter length - enough to prove the
// mechanism (coefficient load, streamed shift-and-MAC, saturation,
// busy/done) without the verification cost of something bigger. A longer
// filter is a wider register map and a wider idx_r, not a redesign.
module wb_fir #(
    parameter N_TAPS = 8
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
    localparam [7:0] OFF_CTRL   = 8'h00;
    localparam [7:0] OFF_STATUS = 8'h04;
    localparam [7:0] OFF_COEF0  = 8'h08;
    localparam [7:0] OFF_INPUT  = 8'h28;
    localparam [7:0] OFF_OUTPUT = 8'h2C;

    // Same WIDTHEXPAND/WIDTHTRUNC fix rtl/plic.v, rtl/clint.v and
    // rtl/soc/wb_npu.v all already needed: N_TAPS is a bare, unsized
    // parameter, so comparing idx_r directly against `N_TAPS - 1`, or
    // indexing an N_TAPS-deep array with a wider wire, gets a wider
    // intermediate type than the narrower signal's own declared width
    // infers, tripping a spurious width-mismatch warning even though the
    // real values are identical. Declared here, ahead of every use below.
    localparam IDXW = $clog2(N_TAPS);
    localparam [31:0] N_TAPS_M1 = N_TAPS - 1;
    localparam [IDXW-1:0] IDX_LAST = N_TAPS_M1[IDXW-1:0];

    wire [7:0] a      = wb_adr[7:0];
    wire       active = wb_cyc && wb_stb;
    wire       wr     = active && wb_we;

    // Matches wb_npu.v's own "compute the index unconditionally, gate its
    // use with a range check" shape - N_TAPS is a parameter here too, so a
    // case statement would have to be generated to track it.
    wire       is_coef   = active && (a >= OFF_COEF0) &&
                            (a < OFF_COEF0 + 4*N_TAPS) && (a[1:0] == 2'b00);
    wire [7:0] coef_off_word = (a - OFF_COEF0) >> 2;
    // Sliced down to exactly the array's own index width rather than left
    // at coef_off_word's natural 8 bits - an 8-bit index into a narrower
    // array is the same width mismatch idx_r's own comparison against
    // N_TAPS-1 needs fixing above, just on an array index instead of a
    // comparison.
    wire [IDXW-1:0] coef_idx = coef_off_word[IDXW-1:0];

    reg signed [15:0] h_mem    [0:N_TAPS-1];
    reg signed [15:0] hist_mem [0:N_TAPS-1];
    reg        signed [31:0] output_r;
    reg               busy_r;
    reg [IDXW-1:0] idx_r;
    reg        signed [39:0] acc_r;

    localparam signed [39:0] I32_MAX = 40'sd2147483647;
    localparam signed [39:0] I32_MIN = -40'sd2147483648;

    integer i;

    // ---- coefficient load, only while not busy ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < N_TAPS; i = i + 1) h_mem[i] <= 16'sd0;
        end else if (wr && !busy_r && is_coef) begin
            h_mem[coef_idx] <= wb_dat_w[15:0];
        end
    end

    wire reset_pulse = wr && !busy_r && (a == OFF_CTRL) && wb_dat_w[0];
    wire push_pulse  = wr && !busy_r && (a == OFF_INPUT);

    // Next accumulator value and its saturated 32-bit form, computed
    // combinationally so the very last busy cycle can both stop and latch
    // OUTPUT in the same edge - matching wb_npu.v's own "busy_r deasserts
    // on the finishing cycle, not after it" timing, extended here to the
    // result register too since this module, unlike wb_npu.v, needs the
    // saturation step to happen before the caller can read a valid answer.
    wire signed [39:0] product  = $signed(h_mem[idx_r]) * $signed(hist_mem[idx_r]);
    wire signed [39:0] acc_next = acc_r + product;
    wire signed [31:0] acc_next_sat =
        (acc_next > I32_MAX) ? 32'sh7FFFFFFF :
        (acc_next < I32_MIN) ? 32'sh80000000 :
        acc_next[31:0];

    // ---- history shift + MAC state machine ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < N_TAPS; i = i + 1) hist_mem[i] <= 16'sd0;
            output_r <= 32'sd0;
            busy_r   <= 1'b0;
            idx_r    <= {IDXW{1'b0}};
            acc_r    <= 40'sd0;
        end else if (reset_pulse) begin
            for (i = 0; i < N_TAPS; i = i + 1) hist_mem[i] <= 16'sd0;
            output_r <= 32'sd0;
        end else if (busy_r) begin
            acc_r <= acc_next;
            if (idx_r == IDX_LAST) begin
                busy_r   <= 1'b0;
                output_r <= acc_next_sat;
            end else begin
                idx_r <= idx_r + 1'b1;
            end
        end else if (push_pulse) begin
            for (i = N_TAPS - 1; i > 0; i = i - 1)
                hist_mem[i] <= hist_mem[i-1];
            hist_mem[0] <= wb_dat_w[15:0];
            busy_r <= 1'b1;
            idx_r  <= {IDXW{1'b0}};
            acc_r  <= 40'sd0;
        end
    end

    // ---- reads ----
    always @(*) begin
        if (a == OFF_STATUS) begin
            wb_dat_r = {31'b0, busy_r};
        end else if (a == OFF_OUTPUT) begin
            wb_dat_r = output_r;
        end else if (is_coef) begin
            wb_dat_r = {{16{h_mem[coef_idx][15]}}, h_mem[coef_idx]};
        end else begin
            wb_dat_r = 32'b0;   // OFF_CTRL, OFF_INPUT and unused offsets: WARL zero
        end
    end

    // Zero wait states, matching wb_timer.v/wb_npu.v: every access acks the
    // same cycle, including a write that a busy guard above silently
    // ignores.
    assign wb_ack = active;
endmodule
