// A simplified real PLIC: NUM_SOURCES level-triggered external interrupt
// sources (numbered 1..NUM_SOURCES; source 0 doesn't exist, matching the
// real PLIC convention), each with a 3-bit priority, feeding a single
// M-mode context via the standard enable/threshold/claim-complete model.
// `addr` is expected pre-decoded by the caller (top.v) to be relative to
// the PLIC's base address, same convention as clint.v.
//
// Deliberately simplified vs. the real spec: only one context (M-mode) -
// S-mode/SEIP delivery isn't implemented this round (real SEIP semantics,
// an OR of a hardware pin and a software-writable mip bit, is a fiddly
// spec corner not worth risking here; mip.SEIP stays hardwired 0 in
// csr_file.v). Sources are level-triggered only (no edge-detect gateway
// configuration).
//
// The `in_service` bit per source is what makes claim/complete actually
// observable: without it, a still-asserted level source would look
// pending again immediately after claim, before `complete` is even
// written. A source can only (re-)become pending while it isn't already
// in service; claim atomically clears pending and sets in_service; the
// matching complete write clears in_service, letting a still-asserted
// level re-assert pending on a later cycle.
//
// `re` must be asserted only on a cycle where a real load instruction is
// reading this address (not just "the address happens to be on the
// bus") - claim has a read side effect, and cpu_core.v's dmem address bus
// is driven combinationally from EX every cycle regardless of
// instruction type, so an unqualified address match would spuriously
// claim on unrelated instructions.
module plic #(
    parameter NUM_SOURCES = 8
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    input  wire        re,
    output reg  [31:0] rdata,

    input  wire [NUM_SOURCES-1:0] irq_sources, // irq_sources[k] is source (k+1)

    output wire        eip
);
    localparam [15:0] OFF_PENDING = 16'h1000;
    localparam [15:0] OFF_ENABLE  = 16'h2000;
    localparam [15:0] OFF_THRESH  = 16'h3000;
    localparam [15:0] OFF_CLAIM   = 16'h3004;

    reg [2:0] priority_r [1:NUM_SOURCES];
    reg       pending    [1:NUM_SOURCES];
    reg       in_service [1:NUM_SOURCES];
    reg       enable_r   [1:NUM_SOURCES];
    reg [2:0] threshold_r;

    integer i;

    // Priority-encode the highest-priority eligible (pending, enabled,
    // above-threshold) source; ties go to the lowest source ID. Must
    // actually compare priorities against the best candidate found so
    // far - a loop that just overwrites on every eligible match (without
    // that comparison) silently degenerates into "lowest eligible ID
    // wins," regardless of priority.
    reg [7:0] claim_id;
    reg       claim_any;
    reg [2:0] best_priority;
    always @(*) begin
        claim_any     = 1'b0;
        claim_id      = 8'd0;
        best_priority = 3'd0;
        for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
            if (pending[i] && enable_r[i] && (priority_r[i] > threshold_r) &&
                (!claim_any || priority_r[i] > best_priority)) begin
                claim_any     = 1'b1;
                claim_id      = i[7:0];
                best_priority = priority_r[i];
            end
        end
    end

    assign eip = claim_any;

    wire [15:0] a = addr[15:0];
    wire        is_priority_reg = (a < OFF_PENDING) && (a[1:0] == 2'b00);
    wire [7:0]  priority_idx    = a[9:2];
    wire        priority_idx_ok = is_priority_reg && (priority_idx >= 1) && (priority_idx <= NUM_SOURCES);

    reg [31:0] pending_bits, enable_bits;
    always @(*) begin
        pending_bits = 32'b0;
        enable_bits  = 32'b0;
        for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
            pending_bits[i] = pending[i];
            enable_bits[i]  = enable_r[i];
        end
    end

    always @(*) begin
        if (priority_idx_ok) begin
            rdata = {29'b0, priority_r[priority_idx]};
        end else begin
            case (a)
                OFF_PENDING: rdata = pending_bits;
                OFF_ENABLE:  rdata = enable_bits;
                OFF_THRESH:  rdata = {29'b0, threshold_r};
                OFF_CLAIM:   rdata = {24'b0, claim_id};
                default:     rdata = 32'b0;
            endcase
        end
    end

    wire claim_read_now = re && (a == OFF_CLAIM) && claim_any;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            threshold_r <= 3'b0;
            for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
                priority_r[i] <= 3'b0;
                pending[i]    <= 1'b0;
                in_service[i] <= 1'b0;
                enable_r[i]   <= 1'b0;
            end
        end else begin
            for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
                if (irq_sources[i-1] && !in_service[i])
                    pending[i] <= 1'b1;
                else if (!irq_sources[i-1])
                    pending[i] <= 1'b0;
            end

            if (claim_read_now) begin
                pending[claim_id]    <= 1'b0; // overrides this cycle's for-loop result for this index
                in_service[claim_id] <= 1'b1;
            end

            if (we) begin
                if (priority_idx_ok) begin
                    priority_r[priority_idx] <= wdata[2:0];
                end else begin
                    case (a)
                        OFF_ENABLE: for (i = 1; i <= NUM_SOURCES; i = i + 1) enable_r[i] <= wdata[i];
                        OFF_THRESH: threshold_r <= wdata[2:0];
                        OFF_CLAIM:  if ((wdata[7:0] >= 1) && (wdata[7:0] <= NUM_SOURCES))
                                        in_service[wdata[7:0]] <= 1'b0;
                        default: ;
                    endcase
                end
            end
        end
    end
`ifdef FORMAL
    // ---- formal properties (formal/run.sh) ----
    //
    // These live inside the module rather than in a wrapper because the
    // interesting state is in arrays (`pending`, `enable_r`, `priority_r`),
    // and yosys cannot follow a hierarchical reference into a submodule's
    // array with a variable index. Compiled only under -DFORMAL, so
    // simulation and synthesis never see them.
    //
    // This encoder already shipped one bug of exactly the shape these
    // properties catch: it overwrote its answer on every eligible source
    // instead of comparing priorities, silently degenerating into "lowest
    // eligible ID wins". A directed test happened to catch it. A solver
    // checking all 2^30-odd priority/enable/pending/threshold combinations
    // would have caught it on the first run.
    // BMC starts from a completely unconstrained state, so without this the
    // solver is free to invent a power-on state no reset sequence can reach
    // - both `pending` and `in_service` set for the same source, say - and
    // report a counterexample for it. Requiring reset in the first step
    // makes every trace it explores start from the real reset state.
    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    integer f;
    reg       f_any_eligible;
    reg [2:0] f_max_priority;
    always @(*) begin
        f_any_eligible = 1'b0;
        f_max_priority = 3'd0;
        for (f = 1; f <= NUM_SOURCES; f = f + 1) begin
            if (pending[f] && enable_r[f] && (priority_r[f] > threshold_r)) begin
                f_any_eligible = 1'b1;
                if (priority_r[f] > f_max_priority)
                    f_max_priority = priority_r[f];
            end
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            // The interrupt line is exactly "something is claimable" - not an
            // approximation. A spurious eip sends the CPU into a handler with
            // nothing to claim; a missing one loses the interrupt.
            assert (eip == f_any_eligible);

            if (claim_any) begin
                // A claim names a source that is genuinely eligible...
                assert (claim_id >= 1 && claim_id <= NUM_SOURCES);
                assert (pending[claim_id]);
                assert (enable_r[claim_id]);
                assert (priority_r[claim_id] > threshold_r);
                // ...and the *highest*-priority one. This is the property the
                // original bug violated.
                assert (priority_r[claim_id] == f_max_priority);
            end else begin
                // Software reads zero as "spurious interrupt, nothing to do",
                // so a nonzero ID here would have it complete a source it
                // never claimed.
                assert (claim_id == 8'd0);
            end

            // A source in service is never handed out again. This is what
            // makes claim/complete a handshake rather than a suggestion: a
            // still-asserted level source must not be re-claimed before the
            // handler that owns it has finished.
            for (f = 1; f <= NUM_SOURCES; f = f + 1)
                if (in_service[f] && claim_any)
                    assert (claim_id != f[7:0]);
        end
    end
`endif
endmodule
