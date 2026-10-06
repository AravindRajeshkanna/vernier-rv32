// One-node network (Phase 8 Stage 1): NUM_M master-side and NUM_S slave-side
// network-interface ports joined by a single routing point. This is the
// degenerate network the roadmap names - it carries today's shared bus's
// behaviour expressed as packets - and the place a real router replaces in
// Stage 2.
//
// Like the bus it stands in for, it carries one transaction at a time:
//
//   IDLE      pick the lowest-numbered requesting master and take its packet
//   REQ       present it to the slave its `dst` names until that slave takes it
//   WAIT      wait for the slave's response packet
//   RSP       hand the response to the master named by the request's `src`
//             (back to WAIT for the next beat of a burst, else to IDLE)
//
// ---- Bursts ----
//
// A burst read is one transaction that comes back as four response packets.
// The node takes it like any other request, then cycles between WAIT (a
// beat from the slave) and RSP (that beat to the master) until the beat
// marked `last` has gone, and only then takes another request - so nothing
// can fall between a burst's words, which is what the bus's burst lock does.
//
// ---- Ordering ----
//
// A master has one request outstanding and the node has one transaction
// outstanding, so a master's requests are performed, and answered, in the
// order it issued them. That is per-master ordering by construction; the
// property a later multi-path router has to keep, not gain.
//
// ---- Atomics: the owner lock ----
//
// When the request just carried had `lock` set, the node remembers its
// master as the owner and, until a request with `lock` clear from that
// master has been carried, accepts requests from nobody else. That is the
// arbiter lock `wb_interconnect.v` takes with `cyc` held across an AMO's two
// phases, expressed in the packet: an AMO's read goes out with `lock=1`, its
// write with `lock=0`, and no other master's request can fall between them.
// A locked master that never sends its closing request holds the network
// for good; the cores here cannot (an AMO's second phase always follows),
// and the same is true of the bus.
//
// ---- Unmapped destinations ----
//
// A `dst` that names no slave is answered by the node itself with an error
// response, the equivalent of the bus's decode-error ack, so a master never
// waits on an address nothing answers.
//
// `qos` is carried and ignored: the arbitration is fixed priority, the same
// as the bus. Stage 3 is where it starts to mean something.
module noc_node1 #(
    parameter NUM_M = 2,
    parameter NUM_S = 2
) (
    input  wire               clk,
    input  wire               rst,

    // Master-side ports (to each noc_ni_master)
    input  wire [NUM_M-1:0]    m_req_valid,
    input  wire [NUM_M*82-1:0] m_req_pkt,
    output wire [NUM_M-1:0]    m_req_ready,
    output wire [NUM_M-1:0]    m_rsp_valid,
    output wire [NUM_M*82-1:0] m_rsp_pkt,
    input  wire [NUM_M-1:0]    m_rsp_ready,

    // Slave-side ports (to each noc_ni_slave)
    output wire [NUM_S-1:0]    s_req_valid,
    output wire [81:0]         s_req_pkt,
    input  wire [NUM_S-1:0]    s_req_ready,
    input  wire [NUM_S-1:0]    s_rsp_valid,
    input  wire [NUM_S*82-1:0] s_rsp_pkt,
    output wire [NUM_S-1:0]    s_rsp_ready,

    // The AMO gap, from outside. While `hold_v` is set only master `hold_id`
    // may be taken, even when it has nothing to offer yet: the bus gives a
    // hart's `d_amo_wrphase` the same power (a core cannot say "lock" on an
    // AMO's read, since it does not know yet that a write follows, so it
    // raises the hold when the read is acked instead). The request's own
    // `lock` bit and this are two ways to the same end.
    input  wire                hold_v,
    input  wire [3:0]          hold_id,

    // Whose transaction is at the slave side, for whoever has to rebuild the
    // bus's shared signals from it: `t_at_slave` is high from the cycle the
    // request is offered to a slave until its answer is back, `t_src` is the
    // requesting master's ID throughout.
    output wire                t_at_slave,
    output wire [3:0]          t_src
);
    localparam S_IDLE = 2'd0, S_REQ = 2'd1, S_WAIT = 2'd2, S_RSP = 2'd3;

    reg [1:0]  state;
    reg [81:0] pkt;         // the request in flight
    reg [81:0] rsp;         // its response, on the way back
    reg        owner_v;     // a locked sequence is open...
    reg [3:0]  owner;        // ...and belongs to this master

    wire [3:0] p_src = pkt[11:8];
    wire [3:0] p_dst = pkt[15:12];
    wire       dst_ok = (p_dst < NUM_S);

    // the node IDs are four bits, so up to sixteen of each side; padding
    // lets a four-bit ID index the port vectors exactly
    wire [15:0] s_req_ready_x = {{(16-NUM_S){1'b0}}, s_req_ready};
    wire [15:0] s_rsp_valid_x = {{(16-NUM_S){1'b0}}, s_rsp_valid};
    wire [15:0] m_rsp_ready_x = {{(16-NUM_M){1'b0}}, m_rsp_ready};

    // ---- who may be taken next ----
    reg        pick_v;
    reg [3:0]  pick;
    integer    i;
    always @* begin
        pick_v = 1'b0;
        pick   = 4'd0;
        for (i = NUM_M - 1; i >= 0; i = i - 1)
            if (m_req_valid[i] && (!owner_v || owner == i[3:0]) &&
                (!hold_v || hold_id == i[3:0])) begin
                pick_v = 1'b1;
                pick   = i[3:0];
            end
    end

    genvar g;
    generate
        for (g = 0; g < NUM_M; g = g + 1) begin : g_m
            assign m_req_ready[g] = (state == S_IDLE) && pick_v && (pick == g);
            assign m_rsp_valid[g] = (state == S_RSP) && (p_src == g);
            assign m_rsp_pkt[g*82 +: 82] = rsp;
        end
        for (g = 0; g < NUM_S; g = g + 1) begin : g_s
            assign s_req_valid[g] = (state == S_REQ)  && dst_ok && (p_dst == g);
            assign s_rsp_ready[g] = (state == S_WAIT) && dst_ok && (p_dst == g);
        end
    endgenerate
    assign s_req_pkt  = pkt;
    assign t_at_slave = (state == S_REQ) || (state == S_WAIT);
    assign t_src      = p_src;

    wire [81:0] picked = m_req_pkt[pick*82 +: 82];
    wire [81:0] chosen = s_rsp_pkt[p_dst*82 +: 82];

    // A response to a request nothing decodes: dst/src swapped, err set.
    wire [81:0] nodev = {1'b1, 1'b0, 32'b0, 32'b0, pkt[11:8], pkt[15:12], pkt[7:6], 4'b0, 1'b1, 1'b0};

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            pkt     <= 82'b0;
            rsp     <= 82'b0;
            owner_v <= 1'b0;
            owner   <= 4'd0;
        end else begin
            case (state)
                S_IDLE: if (pick_v) begin
                    pkt     <= picked;
                    owner_v <= picked[0];
                    owner   <= picked[11:8];
                    state   <= S_REQ;
                end
                S_REQ: begin
                    if (!dst_ok) begin
                        rsp   <= nodev;
                        state <= S_RSP;
                    end else if (s_req_ready_x[p_dst]) begin
                        state <= S_WAIT;
                    end
                end
                S_WAIT: if (s_rsp_valid_x[p_dst]) begin
                    rsp   <= chosen;
                    state <= S_RSP;
                end
                default: if (m_rsp_ready_x[p_src]) state <= rsp[81] ? S_IDLE : S_WAIT;
            endcase
        end
    end
endmodule
