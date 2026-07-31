// Direct-mapped branch target buffer with a 2-bit saturating counter per
// entry: predicts taken/not-taken and a cached target for branches/JAL/
// JALR at IF, trained at EX once the real outcome is known. A cold entry
// (or one that's never been trained) predicts not-taken via the reset
// value of its counter (2'b01, "weakly not-taken") - the same behavior
// as the old static predict-not-taken scheme until an entry has actually
// been seen once.
//
// Reading (IF, this cycle's fetch) and writing (EX, training an older
// branch) can target the same index in the same cycle; ordinary
// synchronous-write/combinational-read semantics mean the read sees the
// *old* entry that cycle. That's harmless here - BTB predictions are
// never architecturally authoritative, EX always independently
// recomputes the real outcome/target and can override - so a stale read
// in that one cycle just costs a missed prediction opportunity, never an
// incorrect final result.
module btb #(
    parameter ENTRIES = 64
)(
    input  wire        clk,
    input  wire        rst,

    // consulted at IF (combinational)
    input  wire [31:0] predict_pc,
    output wire         predicted_taken,
    output wire [31:0]  predicted_target,

    // trained at EX: fires for every branch/JAL/JALR that reaches EX
    // with id_ex_valid (never for a flushed/bubbled instruction)
    input  wire        train_en,
    input  wire [31:0] train_pc,
    input  wire        train_taken,
    input  wire [31:0] train_target
);
    localparam IDX_BITS = $clog2(ENTRIES);
    localparam TAG_BITS = 32 - IDX_BITS - 2;

    reg                 valid  [0:ENTRIES-1];
    reg [TAG_BITS-1:0]  tag    [0:ENTRIES-1];
    reg [31:0]          target [0:ENTRIES-1];
    reg [1:0]           counter[0:ENTRIES-1];

    wire [IDX_BITS-1:0] predict_idx = predict_pc[IDX_BITS+1:2];
    wire [TAG_BITS-1:0] predict_tag = predict_pc[31:IDX_BITS+2];
    wire                predict_hit = valid[predict_idx] && (tag[predict_idx] == predict_tag);

    assign predicted_taken  = predict_hit && counter[predict_idx][1];
    assign predicted_target = target[predict_idx];

    wire [IDX_BITS-1:0] train_idx = train_pc[IDX_BITS+1:2];
    wire [TAG_BITS-1:0] train_tag = train_pc[31:IDX_BITS+2];
    wire                train_hit = valid[train_idx] && (tag[train_idx] == train_tag);

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid[i]   <= 1'b0;
                counter[i] <= 2'b01;
            end
        end else if (train_en) begin
            valid[train_idx]  <= 1'b1;
            tag[train_idx]    <= train_tag;
            target[train_idx] <= train_target; // always overwritten: a changed target
                                                // (e.g. a JALR return address) must win
                                                // even without a counter change
            if (!train_hit) begin
                counter[train_idx] <= train_taken ? 2'b10 : 2'b01;
            end else begin
                case (counter[train_idx])
                    2'b00: counter[train_idx] <= train_taken ? 2'b01 : 2'b00;
                    2'b01: counter[train_idx] <= train_taken ? 2'b10 : 2'b00;
                    2'b10: counter[train_idx] <= train_taken ? 2'b11 : 2'b01;
                    2'b11: counter[train_idx] <= train_taken ? 2'b11 : 2'b10;
                endcase
            end
        end
    end
endmodule
