// A RISC-V PLIC with the standard register layout and two contexts.
//
// NUM_SOURCES level-triggered external interrupt sources, numbered
// 1..NUM_SOURCES (source 0 does not exist, matching the spec), each with a
// 3-bit priority, feeding NUM_CONTEXTS independent enable/threshold/claim
// contexts. `addr` is expected pre-decoded by the caller to be relative to
// the PLIC's base address, same convention as clint.v.
//
// ---- What changed, and why it had to change together ----
//
// The previous version had one M-mode context and a compressed register map
// of its own invention: threshold at 0x3000 and claim at 0x3004. Both were
// fine for firmware written against this SoC and both are unusable for
// anything else. Linux takes external interrupts in **S-mode**, and its PLIC
// driver - like OpenSBI's, and like every other one - finds threshold and
// claim at the spec's per-context stride. A second context without the
// standard layout would still not be drivable; the standard layout with one
// M-mode context would still not deliver to S-mode. So both, plus the
// `mip.SEIP` plumbing in csr_file.v that gives the S-mode context somewhere
// to arrive, are one change.
//
// ---- The map (offsets from the PLIC base) ----
//
//   0x000000 + 4*i      priority of source i          (i = 1..NUM_SOURCES)
//   0x001000            pending bitmap, sources 0..31
//   0x002000 + 0x80*c   enable bitmap for context c, sources 0..31
//   0x200000 + 0x1000*c threshold for context c
//   0x200004 + 0x1000*c claim/complete for context c
//
// Context 0 is hart 0 M-mode and context 1 is hart 0 S-mode, which is the
// conventional assignment and the one dts/soc.dts declares in
// `interrupts-extended`. The 0x200000 base is why this slave needs more than
// a 64 KB window - see rtl/top.v's decode, which had to widen for it.
//
// Sources are level-triggered only; no edge-detect gateway configuration.
//
// ---- claim/complete ----
//
// `in_service` is per *source*, not per context: a source claimed by one
// context must not be handed to the other before the handler that owns it
// completes. Without it a still-asserted level source would look pending
// again immediately after claim, before `complete` is even written. Claim
// atomically clears pending and sets in_service; the matching complete write
// clears in_service, letting a still-asserted level re-assert pending later.
//
// `re` must be asserted only on a cycle where a real load instruction is
// reading this address (not just "the address happens to be on the bus") -
// claim has a read side effect, and cpu_core.v's dmem address bus is driven
// combinationally from EX every cycle regardless of instruction type, so an
// unqualified address match would spuriously claim on unrelated
// instructions. rtl/soc/wb_periph_bridge.v gates it on `data_master` for the
// same reason.
module plic #(
    parameter NUM_SOURCES  = 8,     // must be <= 31: one bitmap word
    parameter NUM_CONTEXTS = 2      // 0 = hart0 M-mode, 1 = hart0 S-mode
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    input  wire        re,
    output reg  [31:0] rdata,

    input  wire [NUM_SOURCES-1:0] irq_sources, // irq_sources[k] is source (k+1)

    // One interrupt line per context. eip[0] drives mip.MEIP, eip[1] the
    // hardware half of mip.SEIP.
    output wire [NUM_CONTEXTS-1:0] eip
);
    // Wide enough to index the contexts and no wider, so the array indices
    // below do not need truncating. $clog2(2) is 1.
    localparam CTXW = (NUM_CONTEXTS <= 1) ? 1 : $clog2(NUM_CONTEXTS);
    // Likewise for indexing the source bitmaps. `claim_id` stays 8 bits wide
    // because that is what software reads out of the claim register; only the
    // slice used as an index is narrowed.
    localparam SRCW = $clog2(NUM_SOURCES + 1);

    // Packed rather than one reg per source, so the bitmap registers are a
    // slice instead of a loop, and so a context's enables can be indexed with
    // a variable in one place.
    reg [NUM_SOURCES:0] pending;
    reg [NUM_SOURCES:0] in_service;
    reg [NUM_SOURCES:0] enable_r   [0:NUM_CONTEXTS-1];
    reg [2:0]           priority_r [1:NUM_SOURCES];
    reg [2:0]           threshold_r[0:NUM_CONTEXTS-1];

    integer i, c;

    // ---- per-context priority encode ----
    //
    // Highest-priority eligible (pending, enabled for this context, above
    // this context's threshold) source; ties go to the lowest source ID.
    // The comparison against `best_prio` is load-bearing: a loop that just
    // overwrites on every eligible match degenerates into "lowest eligible ID
    // wins" regardless of priority, which is a bug this module has already
    // shipped once.
    reg [7:0] claim_id  [0:NUM_CONTEXTS-1];
    reg       claim_any [0:NUM_CONTEXTS-1];
    reg [2:0] best_prio;
    always @(*) begin
        for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
            claim_any[c] = 1'b0;
            claim_id[c]  = 8'd0;
            best_prio    = 3'd0;
            for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
                if (pending[i] && enable_r[c][i] &&
                    (priority_r[i] > threshold_r[c]) &&
                    (!claim_any[c] || priority_r[i] > best_prio)) begin
                    claim_any[c] = 1'b1;
                    claim_id[c]  = i[7:0];
                    best_prio    = priority_r[i];
                end
            end
        end
    end

    genvar g;
    generate
        for (g = 0; g < NUM_CONTEXTS; g = g + 1) begin : g_eip
            assign eip[g] = claim_any[g];
        end
    endgenerate

    // ---- address decode ----
    //
    // 24 bits, because the context block starts at 0x200000 and the slave
    // owns a 16 MB window. Written as explicit ranges rather than a case,
    // since the enable and context blocks are strided.
    wire [23:0] a = addr[23:0];

    wire        is_priority = (a[23:12] == 12'h000) && (a[1:0] == 2'b00);
    wire [9:0]  prio_idx    = a[11:2];
    wire        prio_ok     = is_priority && (prio_idx >= 1) &&
                              (prio_idx <= NUM_SOURCES);

    wire        is_pending  = (a == 24'h001000);

    wire [23:0] enable_off  = a - 24'h002000;
    wire        is_enable   = (a >= 24'h002000) &&
                              (enable_off < (NUM_CONTEXTS * 24'h80)) &&
                              (enable_off[6:0] == 7'h00);
    wire [CTXW-1:0] enable_ctx = enable_off[7 +: CTXW];

    wire [23:0] ctx_off     = a - 24'h200000;
    wire        is_ctx      = (a >= 24'h200000) &&
                              (ctx_off < (NUM_CONTEXTS * 24'h1000));
    wire [CTXW-1:0] ctx_idx    = ctx_off[12 +: CTXW];
    wire        is_thresh   = is_ctx && (ctx_off[11:0] == 12'h000);
    wire        is_claim    = is_ctx && (ctx_off[11:0] == 12'h004);

    always @(*) begin
        if (prio_ok)          rdata = {29'b0, priority_r[prio_idx]};
        else if (is_pending)  rdata = {{(31-NUM_SOURCES){1'b0}}, pending};
        else if (is_enable)   rdata = {{(31-NUM_SOURCES){1'b0}}, enable_r[enable_ctx]};
        else if (is_thresh)   rdata = {29'b0, threshold_r[ctx_idx]};
        else if (is_claim)    rdata = {24'b0, claim_id[ctx_idx]};
        else                  rdata = 32'b0;
    end

    wire claim_read_now = re && is_claim && claim_any[ctx_idx];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pending    <= {(NUM_SOURCES+1){1'b0}};
            in_service <= {(NUM_SOURCES+1){1'b0}};
            for (c = 0; c < NUM_CONTEXTS; c = c + 1) begin
                enable_r[c]    <= {(NUM_SOURCES+1){1'b0}};
                threshold_r[c] <= 3'b0;
            end
            for (i = 1; i <= NUM_SOURCES; i = i + 1)
                priority_r[i] <= 3'b0;
        end else begin
            for (i = 1; i <= NUM_SOURCES; i = i + 1) begin
                if (irq_sources[i-1] && !in_service[i])
                    pending[i] <= 1'b1;
                else if (!irq_sources[i-1])
                    pending[i] <= 1'b0;
            end

            // Overrides this cycle's loop result for the claimed index.
            if (claim_read_now) begin
                pending[claim_id[ctx_idx][SRCW-1:0]]    <= 1'b0;
                in_service[claim_id[ctx_idx][SRCW-1:0]] <= 1'b1;
            end

            if (we) begin
                if (prio_ok)
                    priority_r[prio_idx] <= wdata[2:0];
                else if (is_enable)
                    enable_r[enable_ctx] <= wdata[NUM_SOURCES:0];
                else if (is_thresh)
                    threshold_r[ctx_idx] <= wdata[2:0];
                else if (is_claim)
                    if ((wdata[7:0] >= 1) && (wdata[7:0] <= NUM_SOURCES))
                        in_service[wdata[SRCW-1:0]] <= 1'b0;
            end
        end
    end
`ifdef FORMAL
    // ---- formal properties (formal/run.sh) ----
    //
    // These live inside the module rather than in a wrapper because the
    // interesting state is in arrays, and yosys cannot follow a hierarchical
    // reference into a submodule's array with a variable index. Compiled only
    // under -DFORMAL, so simulation and synthesis never see them.
    //
    // This encoder already shipped one bug of exactly the shape these catch:
    // it overwrote its answer on every eligible source instead of comparing
    // priorities, silently degenerating into "lowest eligible ID wins". A
    // directed test happened to catch it. A solver would have caught it on
    // the first run - and now has two contexts' worth of the same logic to
    // check, which is precisely the kind of duplication a proof is cheaper
    // than a test at.
    //
    // BMC starts from a completely unconstrained state, so without this the
    // solver is free to invent a power-on state no reset sequence can reach -
    // both `pending` and `in_service` set for the same source, say - and
    // report a counterexample for it.
    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    integer f, fc;
    reg       f_any_eligible [0:NUM_CONTEXTS-1];
    reg [2:0] f_max_priority [0:NUM_CONTEXTS-1];
    always @(*) begin
        for (fc = 0; fc < NUM_CONTEXTS; fc = fc + 1) begin
            f_any_eligible[fc] = 1'b0;
            f_max_priority[fc] = 3'd0;
            for (f = 1; f <= NUM_SOURCES; f = f + 1) begin
                if (pending[f] && enable_r[fc][f] &&
                    (priority_r[f] > threshold_r[fc])) begin
                    f_any_eligible[fc] = 1'b1;
                    if (priority_r[f] > f_max_priority[fc])
                        f_max_priority[fc] = priority_r[f];
                end
            end
        end
    end

    always @(posedge clk) begin
        if (!rst) begin
            for (fc = 0; fc < NUM_CONTEXTS; fc = fc + 1) begin
                // The interrupt line is exactly "something is claimable" for
                // this context - not an approximation. A spurious eip sends
                // the hart into a handler with nothing to claim; a missing
                // one loses the interrupt.
                assert (eip[fc] == f_any_eligible[fc]);

                if (claim_any[fc]) begin
                    // A claim names a source genuinely eligible *for this
                    // context*...
                    assert (claim_id[fc] >= 1 && claim_id[fc] <= NUM_SOURCES);
                    assert (pending[claim_id[fc]]);
                    assert (enable_r[fc][claim_id[fc]]);
                    assert (priority_r[claim_id[fc]] > threshold_r[fc]);
                    // ...and the highest-priority one. This is the property
                    // the original bug violated.
                    assert (priority_r[claim_id[fc]] == f_max_priority[fc]);
                end else begin
                    // Software reads zero as "spurious interrupt, nothing to
                    // do", so a nonzero ID here would have it complete a
                    // source it never claimed.
                    assert (claim_id[fc] == 8'd0);
                end

                // A source in service is never handed out again, to *either*
                // context. This is what makes claim/complete a handshake
                // rather than a suggestion, and with two contexts it is also
                // what stops M-mode and S-mode both servicing one source.
                for (f = 1; f <= NUM_SOURCES; f = f + 1)
                    if (in_service[f] && claim_any[fc])
                        assert (claim_id[fc] != f[7:0]);
            end
        end
    end
`endif
endmodule
