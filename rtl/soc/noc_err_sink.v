// The end of the line for a request nothing decodes (Phase 8 Stage 2): takes
// a request packet and answers it with an error response, the equivalent of
// the bus's decode-error ack. It is one more output port on the request router
// and one more input port on the response router, so an unmapped address is
// answered like any other request and the fabric never waits on one.
// Packet layout is in noc_ni_master.v.
module noc_err_sink #(
    parameter [3:0] ID = 4'd0
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        req_valid,
    input  wire [81:0] req_pkt,
    output wire        req_ready,
    output wire        rsp_valid,
    output wire [81:0] rsp_pkt,
    input  wire        rsp_ready
);
    reg        full;
    reg [3:0]  dst;      // the requester
    reg [1:0]  qos;

    assign req_ready = !full;
    assign rsp_valid = full;
    // last, no burst, zero data, address zero, src/dst swapped, qos echoed, err set
    assign rsp_pkt   = {1'b1, 1'b0, 32'b0, 32'b0, dst, ID, qos, 4'b0, 1'b1, 1'b0};

    always @(posedge clk) begin
        if (rst) begin
            full <= 1'b0; dst <= 4'd0; qos <= 2'd0;
        end else if (req_valid && req_ready) begin
            full <= 1'b1; dst <= req_pkt[11:8]; qos <= req_pkt[7:6];
        end else if (rsp_valid && rsp_ready) begin
            full <= 1'b0;
        end
    end
endmodule
