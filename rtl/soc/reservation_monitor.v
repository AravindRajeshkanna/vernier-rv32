// Cross-hart LR/SC reservation invalidation - the second of the two real
// coherence gaps docs/roadmap.md's Phase 13 assessment named (the first,
// rtl/soc/cpu_wb.v's D-cache, was closed by a DCACHE_ENABLE bypass - a
// reservation is a correctness primitive, not a performance feature, so
// there is no equivalent "just disable it" option here).
//
// Each hart's own LR/SC reservation (rtl/cpu_core.v's `reservation_valid`/
// `reservation_addr`, and the same shape in rtl/ooo/core_ooo.v) is a
// private register today, invalidated only by that same hart's own
// subsequent trap/SC/write (`any_successful_write`, in cpu_core.v) - correct
// for the one hart that exists in any build today, and a direct violation
// of LR/SC's cross-hart contract for two: hart A's SC must fail if hart B
// wrote the reserved address in between, and today nothing tells hart A
// that happened.
//
// This module is the missing cross-hart link, built and proven standalone
// before either core is wired to it, matching every earlier Phase 13
// stage's own "verify the hard piece in isolation" sequencing - nothing in
// this tree instantiates it yet. NUM_HARTS defaults to 2, the near-term
// target, rather than 1: unlike cpu_wb.v/wb_interconnect.v/clint.v/plic.v,
// there is no existing single-hart shape for this module to collapse back
// to, since nothing wires a hart to it at all today.
//
// ---- Interface, and why it is shaped this way ----
//
// Each hart exposes its own held reservation (`resv_valid`/`resv_addr`) and
// its own completed writes (`store_fire`/`store_addr`) - a plain store, an
// SC's own write phase, or an AMO's write phase all count, since all three
// modify memory and cpu_core.v's own `any_successful_write` already
// aggregates exactly this set for the single-hart case. Deliberately wired
// from each core's own write-completion signal rather than tapped off the
// shared bus post-arbitration: the bus's own broadcast address only carries
// *which* master currently owns it (`rtl/soc/wb_interconnect.v`'s
// `s_data_master`), not which *hart*, and turning that into a hart index
// would need the interconnect to expose one it does not have a use for
// otherwise. Taking each hart's own signal directly needs nothing new from
// the interconnect and mirrors how a real snoop unit is typically wired -
// from the requester's own commit point, not observed secondhand off a bus
// that has already lost the information this needs.
//
// A hart's own write to its own reservation is deliberately excluded here
// (`hit[g][g]` below is always 0) - that case is already correct, handled
// entirely by each core's own existing local logic (`any_successful_write`
// clearing `reservation_valid` unconditionally on the writing hart's own
// next cycle). This module's entire job is the case nothing local can see:
// a *different* hart's write landing on an address this hart still holds a
// reservation on.
module reservation_monitor #(
    parameter NUM_HARTS = 2
)(
    input  wire [NUM_HARTS-1:0]    resv_valid,
    input  wire [NUM_HARTS*32-1:0] resv_addr,
    input  wire [NUM_HARTS-1:0]    store_fire,
    input  wire [NUM_HARTS*32-1:0] store_addr,

    // Pulses for exactly the cycle(s) some other hart's write lands on this
    // hart's currently-held reservation. A future wiring of this into
    // cpu_core.v/core_ooo.v would OR this into that core's own reservation-
    // clearing condition (`any_sc_this_cycle || any_successful_write` in
    // cpu_core.v today) - not implemented here; see docs/roadmap.md's
    // Phase 13 entry for what remains open.
    output wire [NUM_HARTS-1:0]    resv_invalidate
);
    genvar g, k;
    generate
        for (g = 0; g < NUM_HARTS; g = g + 1) begin : g_hart
            wire [NUM_HARTS-1:0] hit;
            for (k = 0; k < NUM_HARTS; k = k + 1) begin : g_writer
                if (k == g) begin : g_self
                    assign hit[k] = 1'b0;
                end else begin : g_other
                    assign hit[k] = store_fire[k] &&
                                    (store_addr[32*k +: 32] == resv_addr[32*g +: 32]);
                end
            end
            assign resv_invalidate[g] = resv_valid[g] && (|hit);
        end
    endgenerate
endmodule
