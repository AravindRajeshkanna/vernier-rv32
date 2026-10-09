// rtl/soc/noc_router.v against formal/noc_router_ref.v, the router as it was before Phase 8 Part 30
// (one array holding every input's FIFO entries) - for every input sequence from reset, up to the
// bound, the two must agree at every port on every cycle: which inputs are ready, which outputs are
// offering, what they offer, and the misroute flag.
//
// The inputs are free: any packets (a destination that is not a port included), offered and
// withdrawn at will, locks, holds, an output refusing for as long as it likes. Nothing about a legal
// sender is assumed, so nothing about one can hide a difference.
//
// One reduction, stated: only the low 20 bits of each packet are free; the 62 above them are held at
// zero. The router reads four fields (lock, qos, source, destination, all in the low 16 bits) and
// otherwise stores a packet and hands it on, alike for every bit, so what the 62 bits could add is more
// of the same storage path, at a cost that makes the proof take hours instead of minutes. Four payload
// bits (16 to 19) remain, enough to tell one packet from another in the FIFO.
//
// What an output carries while it is not offering anything is not compared. Both routers show whatever
// their storage holds there, and storage nothing has written yet holds nothing in particular.
module fv_noc_router_equiv #(
    parameter QOS_EN    = 0,
    parameter AGE_LIMIT = 0
) (
    input wire         clk,
    input wire         rst,
    input wire [1:0]   in_valid,
    input wire [163:0] in_pkt,
    input wire [1:0]   out_ready,
    input wire         hold_v,
    input wire [3:0]   hold_id
);
    wire [1:0]   in_ready_n, in_ready_r;
    wire [1:0]   out_valid_n, out_valid_r;
    wire [163:0] out_pkt_n, out_pkt_r;
    wire         misroute_n, misroute_r;

    noc_router #(.NUM_IN(2), .NUM_OUT(2), .DEPTH(2), .QOS_EN(QOS_EN), .AGE_LIMIT(AGE_LIMIT)) NEW (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_pkt(in_pkt), .in_ready(in_ready_n),
        .out_valid(out_valid_n), .out_pkt(out_pkt_n), .out_ready(out_ready),
        .hold_v(hold_v), .hold_id(hold_id), .misroute(misroute_n));

    noc_router_ref #(.NUM_IN(2), .NUM_OUT(2), .DEPTH(2), .QOS_EN(QOS_EN), .AGE_LIMIT(AGE_LIMIT)) REF (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_pkt(in_pkt), .in_ready(in_ready_r),
        .out_valid(out_valid_r), .out_pkt(out_pkt_r), .out_ready(out_ready),
        .hold_v(hold_v), .hold_id(hold_id), .misroute(misroute_r));

    // the reduction above
    always @(*) begin
        assume (in_pkt[ 81: 20] == 62'b0);
        assume (in_pkt[163: 102] == 62'b0);
    end

    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    always @(*) if (f_initialized && !rst) begin
        assert (in_ready_n  == in_ready_r);
        assert (out_valid_n == out_valid_r);
        assert (misroute_n  == misroute_r);
        if (out_valid_n[0]) assert (out_pkt_n[81:0]    == out_pkt_r[81:0]);
        if (out_valid_n[1]) assert (out_pkt_n[163:82]  == out_pkt_r[163:82]);
    end

    // reachability, so that agreeing is not agreeing about nothing: an input held off by a full FIFO,
    // both outputs moving packets in one cycle, a packet taken from an input whose FIFO held two,
    // and a misrouted packet dropped
    always @(*) if (f_initialized && !rst) begin
        cover (|(in_valid & ~in_ready_n));
        cover (out_valid_n[0] && out_ready[0] && out_valid_n[1] && out_ready[1]);
        cover (out_valid_n[0] && out_ready[0] && out_pkt_n[7:6] == 2'd3);
        cover (misroute_n);
    end
endmodule

module fv_noc_router_qos_equiv (
    input wire         clk,
    input wire         rst,
    input wire [1:0]   in_valid,
    input wire [163:0] in_pkt,
    input wire [1:0]   out_ready,
    input wire         hold_v,
    input wire [3:0]   hold_id
);
    fv_noc_router_equiv #(.QOS_EN(1), .AGE_LIMIT(3)) P (.clk(clk), .rst(rst), .in_valid(in_valid), .in_pkt(in_pkt),
        .out_ready(out_ready), .hold_v(hold_v), .hold_id(hold_id));
endmodule
