// Master-side network interface (Phase 8 Stage 1): a Wishbone B4 classic
// *slave* port facing one master (a hart's fetch, data or walker port, the
// debug module, the NPU DMA) on one side, and a request/response packet
// channel into the network on the other.
//
// ---- Packet format (shared with noc_ni_slave.v and noc_node1.v) ----
//
// One 80-bit packet, request and response alike, so a router stage never has
// to know which it is carrying beyond the `rsp` convention below:
//
//    [0]      lock  request: more transactions from this master follow, keep
//                   the path to it (the bus's `cyc` held across an AMO's two
//                   phases). Response: unused, 0.
//    [1]      we    request: 1 = write, 0 = read.   Response: err (the slave
//                   answered with an error, or nothing decodes the address).
//    [5:2]    sel   byte enables (request); response: 0.
//    [7:6]    qos   traffic class. Carried end to end and echoed in the
//                   response; nothing arbitrates on it yet (Stage 3).
//    [11:8]   src   sender's node ID. A request's src is the master's ID; a
//                   response's src is the answering slave's ID.
//    [15:12]  dst   receiver's node ID, same convention.
//    [47:16]  adr   byte address (request); response: 0.
//    [79:48]  dat   write data (request) / read data (response).
//
// ---- What this block does ----
//
// One transaction outstanding at a time, which is all a classic Wishbone
// master can have. `req_valid` is combinational from the master's own
// `cyc & stb`, so the request stays presented, unchanged, until the network
// takes it (`req_ready`): that is the back-pressure path, and the master
// sees it as an ordinary wait state. The response ack is the response packet
// itself, delivered the cycle it arrives.
//
// `wb_dst`, `wb_qos` and `wb_lock` are sideband inputs presented with the
// request. The destination is a function of the address - whoever owns the
// address map decodes it, so this block does not carry a second copy of it.
// `wb_lock` is what a bus carries implicitly by holding `cyc` across two
// strobes: the network cannot see that, so the master says it in the packet.
//
// Limitation: a master must hold its request until acked, as classic
// Wishbone requires of every master in this tree. A master that dropped
// `stb` mid-transaction would have the late response consumed and discarded
// here, not delivered to a later request.
module noc_ni_master #(
    parameter [3:0] ID = 4'd0
) (
    input  wire        clk,
    input  wire        rst,

    // Wishbone slave port (toward the master)
    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    input  wire [3:0]  wb_sel,
    input  wire [3:0]  wb_dst,
    input  wire [1:0]  wb_qos,
    input  wire        wb_lock,
    output wire [31:0] wb_dat_r,
    output wire        wb_ack,
    output wire        wb_err,

    // Network side
    output wire        req_valid,
    output wire [79:0] req_pkt,
    input  wire        req_ready,
    input  wire        rsp_valid,
    input  wire [79:0] rsp_pkt,
    output wire        rsp_ready
);
    reg sent;   // the request has gone; waiting for its response

    assign req_valid = wb_cyc && wb_stb && !sent;
    assign req_pkt   = {wb_dat_w, wb_adr, wb_dst, ID, wb_qos, wb_sel, wb_we, wb_lock};

    assign rsp_ready = sent;
    wire   rsp_take  = rsp_valid && sent;
    wire   rsp_err   = rsp_pkt[1];

    assign wb_dat_r = rsp_pkt[79:48];
    assign wb_ack   = rsp_take && wb_cyc && wb_stb && !rsp_err;
    assign wb_err   = rsp_take && wb_cyc && wb_stb && rsp_err;

    always @(posedge clk) begin
        if (rst)                         sent <= 1'b0;
        else if (req_valid && req_ready) sent <= 1'b1;
        else if (rsp_take)               sent <= 1'b0;
    end
endmodule
