// Formal properties for the router's quality of service (Phase 8 Stage 3):
// three inputs, two outputs, classes honoured, aging after three cycles.
//
// The arbiter's rule lives inside rtl/soc/noc_router.v under `ifdef FORMAL`, because
// it needs the per-input state (each head's effective class, the waits) that the ports
// do not show: whenever an output picks afresh, no input that could have been served had
// a higher effective class, and among equal classes none had a lower number. Aging makes
// "effective class" a function of how long a head has waited, so the same assertion proves
// that a head that has waited long enough is preferred over every one that has not.
// Here the router is simply exercised with free inputs, so the solver tries every
// arrival pattern, lock and hold included.
module fv_noc_router_qos (
    input wire         clk,
    input wire         rst,
    input wire [2:0]   in_valid,
    input wire [245:0] in_pkt,
    input wire [1:0]   out_ready,
    input wire         hold_v,
    input wire [3:0]   hold_id
);
    wire [2:0]   in_ready;
    wire [1:0]   out_valid;
    wire [163:0] out_pkt;
    wire         misroute;

    noc_router #(.NUM_IN(3), .NUM_OUT(2), .DEPTH(2), .QOS_EN(1), .AGE_LIMIT(3)) DUT (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_pkt(in_pkt), .in_ready(in_ready),
        .out_valid(out_valid), .out_pkt(out_pkt), .out_ready(out_ready),
        .hold_v(hold_v), .hold_id(hold_id), .misroute(misroute));

    // legal senders: their own ID as source, a destination that is a port
    always @(*) begin
        assume (in_pkt[11:8]    == 4'd0 && in_pkt[93:90]   == 4'd1 && in_pkt[175:172] == 4'd2);
        assume (in_pkt[15:12]   <= 4'd1 && in_pkt[97:94]   <= 4'd1 && in_pkt[179:176] <= 4'd1);
        assume (hold_id <= 4'd2);
    end

    reg f_seen = 1'b0;
    always @(posedge clk) f_seen <= 1'b1;
    // reachability: an aged head that overtakes a higher class, and a higher class that overtakes
    always @(*) if (f_seen && !rst) begin
        cover (out_valid[0] && out_ready[0] && out_pkt[7:6] == 2'd3);
        cover (out_valid[0] && out_ready[0] && out_pkt[7:6] == 2'd0 && in_valid[0] && in_pkt[7:6] == 2'd3);
    end
endmodule
