// Behavioral DDR3 data (DQ/DQS) model - Phase 9 Stage 1, Part 2
// (docs/roadmap.md). Stores one real byte at a fixed test location and
// replays it on a real read - scoped to what this slice's own
// calibration proof needs, not a general-purpose memory array (that is
// later, separate work once the real command/address path from Part 1
// is wired to this data path, which it is not yet).
//
// DQS is modeled as a genuinely source-synchronous signal - it only
// toggles while `read_active` is high, staying idle otherwise - the
// real behavior `rtl/soc/ddr3_dqs_ecp5.v`'s own `READ0`/`READ1` gating
// depends on, not a free-running clock.
module ddr3_dq_model (
    input  wire       sclk,
    input  wire       rst,

    input  wire [7:0] wr_d0,
    input  wire       wr_en,

    input  wire       read_active,
    output reg  [7:0] mem_dq_o,
    output reg        mem_dq_oe,
    output reg        mem_dqs_o
);
    reg [7:0] stored;

    always @(posedge sclk or posedge rst) begin
        if (rst) begin
            stored <= 8'b0;
        end else if (wr_en) begin
            stored <= wr_d0;
        end
    end

    always @(posedge sclk or posedge rst) begin
        if (rst) begin
            mem_dq_o  <= 8'b0;
            mem_dq_oe <= 1'b0;
            mem_dqs_o <= 1'b0;
        end else begin
            mem_dq_o  <= stored;
            mem_dq_oe <= read_active;
            // Real DQS behavior: idle when no read is happening, a
            // real toggle only while one is - `mem_dqs_o` here is a
            // simplified, sclk-rate toggle (matching
            // rtl/soc/ddr3_dq_serdes_ecp5.v's own honest sclk-rate,
            // not eclk-rate, simulation approximation), not a claim of
            // real DQS bit-timing.
            mem_dqs_o <= read_active ? ~mem_dqs_o : 1'b0;
        end
    end
endmodule
