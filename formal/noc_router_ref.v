// The router as it was before Phase 8 Part 30, kept verbatim as the reference that
// formal/fv_noc_router_equiv.v holds rtl/soc/noc_router.v equal to. Part 30 changed how the input FIFOs
// are stored (one array per input instead of one array for all of them) to cut the response router
// from 65,805 LUT4s to a small fraction of that, and that must change nothing a port can see. This copy
// keeps the original single-array storage, so that the proof compares the new storage with the old,
// cycle for cycle, over every input sequence, instead of resting on the tests alone.
//
// It is the router's text at commit a947eba with the module renamed and its `ifdef FORMAL block
// (which is proved on the real module) removed. Nothing else is different; do not "improve" it.
// A packet router (Phase 8 Stage 2): NUM_IN input ports and NUM_OUT output
// ports joined by a crossbar, so packets bound for *different* outputs move in
// the same cycle - which noc_node1.v, carrying one transaction at a time like
// the bus it stands in for, cannot do. Packet layout is in noc_ni_master.v.
//
// ---- What it does ----
//
// Each input has a small FIFO (DEPTH packets) and its head packet's `dst`
// field names the output port it wants. Each output serves, per cycle, the
// lowest-numbered input whose head wants it, so the priority between inputs
// is the same fixed order the bus and the one-node network use. A packet is
// one flit - a whole Wishbone request or one beat of a response - so
// there is nothing to hold across cycles the way a wormhole router holds a
// path, and no virtual channels: nothing here is wider than one transfer.
//
// A grant, once an output has offered a packet, is held until the receiver
// takes it (`out_valid` never drops and the packet never changes while it
// waits), so the receiver may rely on the usual valid/ready contract.
//
// ---- Ordering ----
//
// Packets between one input and one output leave in the order they arrived:
// an input's FIFO is first in, first out and an output takes only an input's
// head. That is the ordering a master relies on (it has one request
// outstanding, so across outputs it needs none).
//
// ---- Quality of service (QOS_EN, AGE_LIMIT) ----
//
// With `QOS_EN` clear (the default) the `qos` field is ignored and the
// priority is the input order alone, as above. With it set, an output serves
// the input whose head packet has the highest `qos` class (0 to 3), the lowest
// input number among equals: a latency-critical class goes ahead of bulk
// traffic that arrived first.
//
// Strict class priority starves a low class under a steady stream of a higher
// one, so `AGE_LIMIT` bounds it: a head packet that has waited `AGE_LIMIT`
// cycles is treated as the top class (3) from then on. The wait of any packet
// is then bounded by AGE_LIMIT plus the time to serve every other aged head
// ahead of it, whatever the traffic. `AGE_LIMIT` 0 turns aging off (pure class
// priority, which can starve).
//
// ---- Atomics ----
//
// Two ways to keep an AMO's two phases adjacent, as in noc_node1.v. A packet
// with `lock` set makes its source the owner of the output it went to: the
// output then serves nobody else until a packet with `lock` clear from that
// source has gone. And `hold_v`/`hold_id`, from outside, blocks the output the
// holding input last used to everyone but the holder - a core raises it when
// the read of an AMO is acked, since it cannot say "lock" on the read.
//
// ---- A destination that is not a port ----
//
// A `dst` >= NUM_OUT means the sender got it wrong. The packet is taken and
// discarded, `misroute` goes high and stays high, and nothing waits for it:
// better a flag a test can see than a deadlock that looks like a hang. The
// network interfaces' address decode never produces one.
module noc_router_ref #(
    parameter NUM_IN    = 2,
    parameter NUM_OUT   = 2,
    parameter DEPTH     = 2,
    parameter QOS_EN    = 0,
    parameter AGE_LIMIT = 0
) (
    input  wire                clk,
    input  wire                rst,

    input  wire [NUM_IN-1:0]     in_valid,
    input  wire [NUM_IN*82-1:0]  in_pkt,
    output wire [NUM_IN-1:0]     in_ready,

    output wire [NUM_OUT-1:0]    out_valid,
    output wire [NUM_OUT*82-1:0] out_pkt,
    input  wire [NUM_OUT-1:0]    out_ready,

    input  wire                hold_v,
    input  wire [3:0]          hold_id,

    output reg                 misroute
);
    // ---- the input FIFOs ----
    reg [81:0] mem   [0:NUM_IN*DEPTH-1];
    reg [7:0]  rd    [0:NUM_IN-1];
    reg [7:0]  wr    [0:NUM_IN-1];
    reg [7:0]  cnt   [0:NUM_IN-1];
    // Per-input views are sixteen wide, the whole four-bit ID space, so an ID
    // can index them exactly; the entries past NUM_IN are never selected.
    reg [3:0]  last_out [0:15];           // the output each input last used

    wire [NUM_IN-1:0] f_valid;            // an input has a head packet
    wire [81:0]       head [0:15];
    wire [3:0]        h_dst [0:15];
    wire [3:0]        h_src [0:15];
    wire              h_lock [0:15];

    genvar gi;
    generate
        for (gi = NUM_IN; gi < 16; gi = gi + 1) begin : g_pad
            assign head[gi]   = 82'b0;
            assign h_dst[gi]  = 4'd0;
            assign h_src[gi]  = 4'd0;
            assign h_lock[gi] = 1'b0;
        end
        for (gi = 0; gi < NUM_IN; gi = gi + 1) begin : g_in
            assign f_valid[gi] = (cnt[gi] != 8'd0);
            assign head[gi]    = mem[gi*DEPTH + {24'b0, rd[gi]}];
            assign h_dst[gi]   = head[gi][15:12];
            assign h_src[gi]   = head[gi][11:8];
            assign h_lock[gi]  = head[gi][0];
            assign in_ready[gi] = (cnt[gi] < DEPTH);
        end
    endgenerate

    // ---- per-output state: the owner of a locked sequence, a held grant ----
    reg [NUM_OUT-1:0] lk_v;
    reg [3:0]         lk_own [0:NUM_OUT-1];
    reg [NUM_OUT-1:0] gnt_v;              // a packet was offered and not yet taken
    reg [3:0]         gnt_i  [0:NUM_OUT-1];

    // ---- how long each input's head has waited, and its effective class ----
    // (flat vectors, not arrays, so that everything that reads them is sensitive to them)
    reg  [16*NUM_IN-1:0] agev;
    wire [31:0]          eqv;
    genvar ge;
    generate
        for (ge = 0; ge < 16; ge = ge + 1) begin : g_eq
            if (ge < NUM_IN) begin : g_in
                assign eqv[2*ge +: 2] = (AGE_LIMIT != 0 && agev[16*ge +: 16] >= AGE_LIMIT) ? 2'd3 :
                                        (QOS_EN != 0)                                      ? head[ge][7:6] : 2'd0;
            end else begin : g_pad
                assign eqv[2*ge +: 2] = 2'd0;
            end
        end
    endgenerate

    // ---- who each output serves this cycle ----
    reg [NUM_OUT-1:0] sel_v;
    reg [3:0]         sel_i [0:NUM_OUT-1];
    reg [NUM_IN-1:0]  take;               // an input's head leaves this cycle
    reg [NUM_IN-1:0]  drop;               // ...discarded as misrouted
    reg               found, ok;
    reg [1:0]         bestq;
    integer o, i;
    always @* begin
        found = 1'b0;
        ok    = 1'b0;
        bestq = 2'd0;
        for (o = 0; o < NUM_OUT; o = o + 1) begin
            sel_v[o] = 1'b0;
            sel_i[o] = 4'd0;
            if (gnt_v[o]) begin
                sel_v[o] = 1'b1;
                sel_i[o] = gnt_i[o];
            end else begin
                // the highest class among the inputs that may be served...
                found = 1'b0;
                bestq = 2'd0;
                for (i = 0; i < NUM_IN; i = i + 1) begin
                    ok = f_valid[i] && h_dst[i] == o[3:0] &&
                         (!lk_v[o] || lk_own[o] == h_src[i]) &&
                         !(hold_v && last_out[hold_id] == o[3:0] && h_src[i] != hold_id);
                    if (ok && (!found || eqv[2*i +: 2] > bestq)) begin
                        found = 1'b1;
                        bestq = eqv[2*i +: 2];
                    end
                end
                // ...and of those, the lowest-numbered
                for (i = NUM_IN - 1; i >= 0; i = i - 1) begin
                    ok = f_valid[i] && h_dst[i] == o[3:0] &&
                         (!lk_v[o] || lk_own[o] == h_src[i]) &&
                         !(hold_v && last_out[hold_id] == o[3:0] && h_src[i] != hold_id);
                    if (ok && eqv[2*i +: 2] == bestq) begin
                        sel_v[o] = 1'b1;
                        sel_i[o] = i[3:0];
                    end
                end
            end
        end
        for (i = 0; i < NUM_IN; i = i + 1) begin
            take[i] = 1'b0;
            drop[i] = f_valid[i] && ({28'b0, h_dst[i]} >= NUM_OUT);
            for (o = 0; o < NUM_OUT; o = o + 1)
                if (sel_v[o] && sel_i[o] == i[3:0] && out_ready[o]) take[i] = 1'b1;
        end
    end

    genvar go;
    generate
        for (go = 0; go < NUM_OUT; go = go + 1) begin : g_out
            assign out_valid[go]          = sel_v[go];
            assign out_pkt[go*82 +: 82]   = head[sel_i[go]];
        end
    endgenerate

    // ---- state update ----
    integer k;
    always @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < NUM_IN; k = k + 1) begin
                rd[k] <= 8'd0; wr[k] <= 8'd0; cnt[k] <= 8'd0; agev[16*k +: 16] <= 16'd0;
            end
            for (k = 0; k < 16; k = k + 1) last_out[k] <= 4'd15;
            for (k = 0; k < NUM_OUT; k = k + 1) begin
                lk_own[k] <= 4'd0; gnt_i[k] <= 4'd0;
            end
            lk_v     <= {NUM_OUT{1'b0}};
            gnt_v    <= {NUM_OUT{1'b0}};
            misroute <= 1'b0;
        end else begin
            for (k = 0; k < NUM_OUT; k = k + 1) begin
                if (sel_v[k] && !out_ready[k]) begin
                    gnt_v[k] <= 1'b1;
                    gnt_i[k] <= sel_i[k];
                end else begin
                    gnt_v[k] <= 1'b0;
                end
                if (sel_v[k] && out_ready[k]) begin
                    if (h_lock[sel_i[k]]) begin
                        lk_v[k]   <= 1'b1;
                        lk_own[k] <= h_src[sel_i[k]];
                    end else if (lk_v[k] && lk_own[k] == h_src[sel_i[k]]) begin
                        lk_v[k]   <= 1'b0;
                    end
                    last_out[sel_i[k]] <= k[3:0];
                end
            end
            for (k = 0; k < NUM_IN; k = k + 1) begin
                // push (a packet arriving this cycle) and pop (the head leaving)
                if (in_valid[k] && in_ready[k]) begin
                    mem[k*DEPTH + {24'b0, wr[k]}] <= in_pkt[k*82 +: 82];
                    wr[k] <= (wr[k] == DEPTH - 1) ? 8'd0 : wr[k] + 8'd1;
                end
                if (take[k] || drop[k]) rd[k] <= (rd[k] == DEPTH - 1) ? 8'd0 : rd[k] + 8'd1;
                cnt[k] <= cnt[k] + ((in_valid[k] && in_ready[k]) ? 8'd1 : 8'd0)
                                 - ((take[k] || drop[k]) ? 8'd1 : 8'd0);
                if (drop[k]) misroute <= 1'b1;
                // a head that is still waiting ages (saturating); a new head starts at zero
                if (f_valid[k] && !(take[k] || drop[k]))
                    agev[16*k +: 16] <= (agev[16*k +: 16] == 16'hFFFF) ? agev[16*k +: 16]
                                                                       : agev[16*k +: 16] + 16'd1;
                else
                    agev[16*k +: 16] <= 16'd0;
            end
        end
    end

endmodule
