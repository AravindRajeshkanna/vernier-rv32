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
`ifdef FORMAL
    // ---- formal properties (formal/run.sh) ----
    //
    // The BTB is never architecturally authoritative - EX recomputes every
    // outcome and overrides a wrong prediction - so its bugs cost
    // performance, not correctness, and a pass/fail test cannot see them.
    // The only other check on this module is a single recorded mispredict
    // count in sim/tb_top.v, which says nothing about *why* a prediction
    // was made. Compiled only under -DFORMAL.
    // BMC starts from a completely unconstrained state, so without this the
    // solver is free to invent a power-on state no reset sequence can reach
    // - a witness register already armed against garbage, say - and report a
    // counterexample for it. Requiring reset in the first step
    // makes every trace it explores start from the real reset state.
    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    always @(posedge clk) begin
        if (!rst) begin
            if (predicted_taken) begin
                // No prediction without a tag match. This is the aliasing
                // property: the table is direct-mapped, so two PCs sharing an
                // index will collide, and the tag is the only thing stopping
                // one branch from inheriting another's target.
                assert (valid[predict_idx]);
                assert (tag[predict_idx] == predict_tag);
                // And it is genuinely in a taken counter state - predicting
                // taken from weakly-not-taken would make the counter pointless.
                assert (counter[predict_idx][1]);
            end
        end
    end

    // Training touches only the entry it indexes. Watched via one
    // arbitrary-but-fixed witness entry: if training could corrupt a
    // neighbour, unrelated branches would start mispredicting with nothing
    // in the trace to explain it.
    reg [IDX_BITS-1:0] f_witness_idx;
    reg [31:0]         f_witness_target;
    reg                f_witness_valid;
    reg [TAG_BITS-1:0] f_witness_tag;
    reg                f_armed;

    // Synchronous reset only: an assertion inside a block with two edge
    // triggers is not something yosys's async2sync can lower.
    always @(posedge clk) begin
        if (rst) begin
            f_armed <= 1'b0;
        end else if (!f_armed) begin
            f_witness_idx    <= train_idx + 1'b1; // any index but the trained one
            f_witness_target <= target[train_idx + 1'b1];
            f_witness_valid  <= valid[train_idx + 1'b1];
            f_witness_tag    <= tag[train_idx + 1'b1];
            f_armed          <= 1'b1;
        end else if (!(train_en && train_idx == f_witness_idx)) begin
            assert (target[f_witness_idx] == f_witness_target);
            assert (valid[f_witness_idx]  == f_witness_valid);
            assert (tag[f_witness_idx]    == f_witness_tag);
        end else begin
            f_armed <= 1'b0; // the witness got trained; stop watching it
        end
    end
`endif
endmodule
