// Formal properties for rtl/soc/noc_router.v (Phase 8 Stage 2), two inputs,
// two outputs, two-deep FIFOs.
//
// A router's failures are a packet lost, repeated, reordered or sent out of
// the wrong port, and an exclusion (a locked sequence, an AMO hold) that lets
// someone in. Each would corrupt a transaction far from the router.
//
// Sequence numbers make ordering and conservation provable from the ports:
// every packet an input accepts carries the count of packets that input has
// accepted before it, modulo 16 (the environment is assumed to do that), so if every
// packet that leaves an input arrives with exactly the next number, nothing
// was lost, repeated or reordered. The environment is otherwise assumed
// legal: a packet that is offered and not taken stays, and `dst` names a port.
module fv_noc_router (
    input wire        clk,
    input wire        rst,
    input wire [1:0]  in_valid,
    input wire [163:0] in_pkt,
    input wire [1:0]  out_ready,
    input wire        hold_v,
    input wire [3:0]  hold_id
);
    wire [1:0]   in_ready, out_valid;
    wire [163:0] out_pkt;
    wire         misroute;

    noc_router #(.NUM_IN(2), .NUM_OUT(2), .DEPTH(2)) DUT (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_pkt(in_pkt), .in_ready(in_ready),
        .out_valid(out_valid), .out_pkt(out_pkt), .out_ready(out_ready),
        .hold_v(hold_v), .hold_id(hold_id), .misroute(misroute));

    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    // ---- shadow state, from the ports ----
    wire [1:0] acc = in_valid & in_ready;
    wire [1:0] xfer = out_valid & out_ready;
    wire [81:0] op0 = out_pkt[81:0];
    wire [81:0] op1 = out_pkt[163:82];
    wire [3:0] src0 = op0[11:8], src1 = op1[11:8];

    reg [3:0]  seq_in [0:1];       // packets each input has accepted (mod 16: a FIFO two deep cannot tell more apart)
    reg [3:0]  seq_out [0:1];      // packets each input has had leave
    reg [1:0]  occ [0:1];          // how many of its packets are inside
    reg        lk_v [0:1];
    reg [3:0]  lk_own [0:1];
    reg [3:0]  last_out [0:1];
    reg [1:0]  p_pend;
    reg [81:0] p_pkt [0:1];
    reg [1:0]  p_in_pend;
    reg [81:0] p_in [0:1];
    reg        p_ok;

    integer k;
    always @(posedge clk) begin
        p_ok <= !rst;
        p_pend <= out_valid & ~out_ready;
        p_pkt[0] <= op0;  p_pkt[1] <= op1;
        p_in_pend <= in_valid & ~in_ready;
        p_in[0] <= in_pkt[81:0];  p_in[1] <= in_pkt[163:82];
        if (rst) begin
            for (k = 0; k < 2; k = k + 1) begin
                seq_in[k] <= 4'd0; seq_out[k] <= 4'd0; occ[k] <= 2'd0;
                lk_v[k] <= 1'b0; lk_own[k] <= 4'd0; last_out[k] <= 4'd15;
            end
        end else begin
            for (k = 0; k < 2; k = k + 1) begin
                if (acc[k]) seq_in[k] <= seq_in[k] + 4'd1;
                occ[k] <= occ[k] + {1'b0, acc[k]}
                          - {1'b0, ((xfer[0] && src0 == k) || (xfer[1] && src1 == k))};
            end
            if (xfer[0]) begin
                seq_out[src0[0]] <= seq_out[src0[0]] + 4'd1;
                last_out[src0[0]] <= 4'd0;
                if (op0[0]) begin lk_v[0] <= 1'b1; lk_own[0] <= src0; end
                else if (lk_v[0] && lk_own[0] == src0) lk_v[0] <= 1'b0;
            end
            if (xfer[1]) begin
                seq_out[src1[0]] <= seq_out[src1[0]] + 4'd1;
                last_out[src1[0]] <= 4'd1;
                if (op1[0]) begin lk_v[1] <= 1'b1; lk_own[1] <= src1; end
                else if (lk_v[1] && lk_own[1] == src1) lk_v[1] <= 1'b0;
            end
        end
    end

    // ---- the legal environment ----
    always @(*) if (f_initialized && !rst) begin
        // input k's packets: its own source ID, a destination that is a port, the next number
        assume (in_pkt[11:8]    == 4'd0 && in_pkt[93:90] == 4'd1);
        assume (in_pkt[15:12]   <= 4'd1 && in_pkt[97:94] <= 4'd1);
        assume (in_pkt[51:48]   == seq_in[0]);
        assume (in_pkt[133:130] == seq_in[1]);
        assume (hold_id <= 4'd1);
        // an offered packet stays, unchanged, until taken
        if (p_ok && p_in_pend[0]) assume (in_valid[0] && in_pkt[81:0]   == p_in[0]);
        if (p_ok && p_in_pend[1]) assume (in_valid[1] && in_pkt[163:82] == p_in[1]);
    end

    always @(*) if (f_initialized && !rst) begin
        // 1. A packet leaves by the port its `dst` names, and nothing is misrouted.
        if (out_valid[0]) assert (op0[15:12] == 4'd0);
        if (out_valid[1]) assert (op1[15:12] == 4'd1);
        assert (!misroute);

        // 2. No loss, no repeat, no reorder: what leaves an input is its next packet.
        if (xfer[0]) assert (op0[51:48] == seq_out[src0[0]]);
        if (xfer[1]) assert (op1[51:48] == seq_out[src1[0]]);
        // ...and an input leaves through one port at a time
        assert (!(xfer[0] && xfer[1] && src0 == src1));

        // 3. Occupancy: an input is ready exactly while it has room.
        assert (occ[0] <= 2'd2 && occ[1] <= 2'd2);
        assert (in_ready[0] == (occ[0] < 2'd2));
        assert (in_ready[1] == (occ[1] < 2'd2));

        // 4. An offer, once made, stays and does not change.
        if (p_ok && p_pend[0]) assert (out_valid[0] && op0 == p_pkt[0]);
        if (p_ok && p_pend[1]) assert (out_valid[1] && op1 == p_pkt[1]);

        // 5. A locked sequence excludes everyone else at its output.
        if (out_valid[0] && lk_v[0]) assert (src0 == lk_own[0]);
        if (out_valid[1] && lk_v[1]) assert (src1 == lk_own[1]);

        // 6. The hold: a *new* offer (not one carried from a cycle before the
        //    hold rose) at the output the holder last used is the holder's.
        if (hold_v && out_valid[0] && !(p_ok && p_pend[0]) && last_out[hold_id[0]] == 4'd0)
            assert (src0 == hold_id);
        if (hold_v && out_valid[1] && !(p_ok && p_pend[1]) && last_out[hold_id[0]] == 4'd1)
            assert (src1 == hold_id);
    end

    always @(*) if (f_initialized && !rst) begin
        cover (xfer[0] && xfer[1]);               // two outputs at once
        cover (occ[0] == 2'd2);                   // a full FIFO
        cover (xfer[0] && op0[0]);                // a locked packet
        cover (hold_v && out_valid[0] && src0 == hold_id);
        cover (hold_v && in_valid[1] && !out_valid[0] && last_out[0] == 4'd0 && hold_id == 4'd0);
    end
endmodule
