// Multi-cycle DIV/DIVU/REM/REMU unit: a 32-iteration restoring
// shift-subtract divider operating on operand magnitudes, with RISC-V's
// mandated divide-by-zero (quotient=all-1s, remainder=dividend) and
// signed-overflow (INT_MIN / -1: quotient=dividend, remainder=0) cases
// special-cased to finish in 1 cycle rather than run the iteration.
//
// Handshake: pulse `start` for one cycle with `dividend`/`divisor`/
// `is_signed` valid; `busy` is high until `done` pulses (for exactly one
// cycle) with the final `quotient`/`remainder` available combinationally
// that same cycle. `is_signed` selects DIV/REM (1) vs DIVU/REMU (0)
// semantics - both quotient and remainder are always produced; the caller
// picks whichever the instruction asked for.
module muldiv_div (
    input  wire        clk,
    input  wire        rst,

    input  wire        start,
    input  wire [31:0] dividend,
    input  wire [31:0] divisor,
    input  wire        is_signed,

    output wire [31:0] quotient,
    output wire [31:0] remainder,
    output wire        busy,
    output wire        done
);
    reg        busy_r;
    reg [5:0]  count;       // iterations remaining (0..32)
    reg [32:0] p;           // restoring-division accumulator
    reg [31:0] a;           // quotient shift register
    reg [31:0] m;           // |divisor|
    reg        q_neg, r_neg;
    reg        special;
    reg [31:0] special_q, special_r;

    assign busy = busy_r;
    assign done = busy_r && (count == 6'd0);

    // one restoring-division iteration, combinationally derived from the
    // current state - shift {p,a} left by one bit, trial-subtract m, and
    // either keep the subtracted result (quotient bit 1) or restore
    // (quotient bit 0).
    wire [32:0] shifted_p = {p[31:0], a[31]};
    wire [31:0] shifted_a = {a[30:0], 1'b0};
    wire [32:0] trial      = shifted_p - {1'b0, m};

    wire [31:0] raw_q = a;
    wire [31:0] raw_r = p[31:0];
    assign quotient  = special ? special_q : (q_neg ? (~raw_q + 32'd1) : raw_q);
    assign remainder = special ? special_r : (r_neg ? (~raw_r + 32'd1) : raw_r);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy_r <= 1'b0;
            count  <= 6'd0;
        end else if (start) begin
            busy_r <= 1'b1;
            if (divisor == 32'b0) begin
                special   <= 1'b1;
                special_q <= 32'hFFFF_FFFF;
                special_r <= dividend;
                count     <= 6'd0;
            end else if (is_signed && dividend == 32'h8000_0000 && divisor == 32'hFFFF_FFFF) begin
                special   <= 1'b1;
                special_q <= 32'h8000_0000;
                special_r <= 32'b0;
                count     <= 6'd0;
            end else begin
                special <= 1'b0;
                q_neg   <= is_signed && (dividend[31] ^ divisor[31]);
                r_neg   <= is_signed && dividend[31];
                a       <= (is_signed && dividend[31]) ? (~dividend + 32'd1) : dividend;
                m       <= (is_signed && divisor[31])  ? (~divisor  + 32'd1) : divisor;
                p       <= 33'b0;
                count   <= 6'd32;
            end
        end else if (busy_r && count != 6'd0) begin
            if (!trial[32]) begin
                p <= trial;
                a <= {shifted_a[31:1], 1'b1};
            end else begin
                p <= shifted_p;
                a <= {shifted_a[31:1], 1'b0};
            end
            count <= count - 6'd1;
        end else if (busy_r && count == 6'd0) begin
            busy_r <= 1'b0; // result has been visible via `done`; clear for next op
        end
    end
endmodule
