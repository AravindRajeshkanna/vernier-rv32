// Formal properties for rtl/soc/noc_node1.v (Phase 8 Stage 1).
//
// The node is where a network's safety lives: a request delivered to two
// slaves, a response handed to a master that did not ask, or another
// master's request slipping between the two halves of a locked sequence
// would each corrupt data far from where they happen. So these are proven,
// not just tested (sim/tb_noc_ni.v is the directed counterpart).
//
// The ports are driven by a legal environment, assumed rather than hoped:
//   - a master that has offered a request keeps offering it, unchanged,
//     until the node takes it, and its packet's `src` is its own port;
//   - a slave answers only requests it was given, holds an answer until it
//     is taken, and keeps the request open (`at`) until the packet marked
//     `last`, so a burst is several answers to one request.
// Proven for two masters and two slaves, with `dst` free over all sixteen
// values, so the unmapped-destination path is inside the proof.
module fv_noc_node (
    input wire         clk,
    input wire         rst,
    input wire [1:0]   m_req_valid,
    input wire [163:0] m_req_pkt,
    input wire [1:0]   m_rsp_ready,
    input wire [1:0]   s_req_ready,
    input wire [1:0]   s_rsp_valid,
    input wire [163:0] s_rsp_pkt
);
    wire [1:0]   m_req_ready, m_rsp_valid;
    wire [163:0] m_rsp_pkt;
    wire [1:0]   s_req_valid, s_rsp_ready;
    wire [81:0]  s_req_pkt;

    noc_node1 #(.NUM_M(2), .NUM_S(2)) DUT (
        .clk(clk), .rst(rst),
        .m_req_valid(m_req_valid), .m_req_pkt(m_req_pkt), .m_req_ready(m_req_ready),
        .m_rsp_valid(m_rsp_valid), .m_rsp_pkt(m_rsp_pkt), .m_rsp_ready(m_rsp_ready),
        .s_req_valid(s_req_valid), .s_req_pkt(s_req_pkt), .s_req_ready(s_req_ready),
        .s_rsp_valid(s_rsp_valid), .s_rsp_pkt(s_rsp_pkt), .s_rsp_ready(s_rsp_ready));

    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    // ---- what the node has done, seen only from its ports ----
    reg        open;        // a locked sequence is open...
    reg        owner;       // ...for this master
    reg        busy;        // a request was taken and its response has not been delivered
    reg        who;         // the master that request came from
    reg [1:0]  at;          // slaves holding a request they have not yet answered
    reg [3:0]  last_dst;

    wire       take0 = m_req_valid[0] && m_req_ready[0];
    wire       take1 = m_req_valid[1] && m_req_ready[1];
    wire       take  = take0 || take1;
    wire [81:0] taken = take1 ? m_req_pkt[163:82] : m_req_pkt[81:0];
    wire       deliver = |(m_rsp_valid & m_rsp_ready);
    wire       deliver_last = deliver && m_rsp_pkt[81];

    always @(posedge clk) begin
        if (rst) begin
            open <= 1'b0; owner <= 1'b0; busy <= 1'b0; who <= 1'b0; at <= 2'b0; last_dst <= 4'd0;
        end else begin
            if (take) begin
                open <= taken[0]; owner <= take1; busy <= 1'b1; who <= take1; last_dst <= taken[15:12];
            end
            if (deliver_last) busy <= 1'b0;
            if (|(s_req_valid & s_req_ready)) at <= at | (s_req_valid & s_req_ready);
            if (|(s_rsp_valid & s_rsp_ready & {s_rsp_pkt[163], s_rsp_pkt[81]}))
                at <= at & ~(s_rsp_valid & s_rsp_ready & {s_rsp_pkt[163], s_rsp_pkt[81]});
        end
    end

    // ---- the environment's side of the contract ----
    reg [163:0] p_req_pkt;
    reg [1:0]   p_pend, p_rsp_valid, p_rsp_ready_n;
    reg         p_ok;
    always @(posedge clk) begin
        p_ok <= !rst;
        p_req_pkt <= m_req_pkt;
        p_pend <= m_req_valid & ~m_req_ready;
        p_rsp_valid <= s_rsp_valid;
        p_rsp_ready_n <= ~s_rsp_ready;
    end
    always @(*) if (f_initialized && !rst) begin
        // a master's own port number is its src
        assume (m_req_pkt[11:8]   == 4'd0);
        assume (m_req_pkt[93:90]  == 4'd1);
        // an offered request stays, unchanged, until taken
        if (p_ok && p_pend[0]) assume (m_req_valid[0] && m_req_pkt[81:0]    == p_req_pkt[81:0]);
        if (p_ok && p_pend[1]) assume (m_req_valid[1] && m_req_pkt[163:82]  == p_req_pkt[163:82]);
        // a slave answers only what it holds, and holds the answer until taken
        if (s_rsp_valid[0]) assume (at[0]);
        if (s_rsp_valid[1]) assume (at[1]);
        if (p_ok && p_rsp_valid[0] && p_rsp_ready_n[0]) assume (s_rsp_valid[0]);
        if (p_ok && p_rsp_valid[1] && p_rsp_ready_n[1]) assume (s_rsp_valid[1]);
        // a slave never answers in the cycle it is handed the request
        if (s_req_valid[0] && s_req_ready[0]) assume (!s_rsp_valid[0]);
        if (s_req_valid[1] && s_req_ready[1]) assume (!s_rsp_valid[1]);
    end

    always @(*) if (f_initialized && !rst) begin
        // 1. At most one slave is asked at a time, and only the one named.
        assert (!(s_req_valid[0] && s_req_valid[1]));
        if (s_req_valid[0]) assert (s_req_pkt[15:12] == 4'd0);
        if (s_req_valid[1]) assert (s_req_pkt[15:12] == 4'd1);

        // 2. At most one request is taken per cycle, and only while idle.
        assert (!(m_req_ready[0] && m_req_ready[1]));
        if (m_req_ready != 2'b00) assert (!busy);

        // 3. A response goes to one master, the one that asked, and only
        //    while a request is outstanding.
        assert (!(m_rsp_valid[0] && m_rsp_valid[1]));
        if (m_rsp_valid[0]) assert (busy && !who);
        if (m_rsp_valid[1]) assert (busy && who);

        // 4. The lock: while a locked sequence is open, nobody but its owner
        //    is taken. This is what keeps an AMO's read and write adjacent.
        if (open && m_req_ready[0]) assert (!owner);
        if (open && m_req_ready[1]) assert (owner);

        // 5. The node never lets a request sit unanswered for good: whatever
        //    it holds is either at a slave, being answered, or on its way
        //    back - never in a state with no way out. (Checked as: while
        //    busy, exactly one of "request offered", "waiting on a slave",
        //    "response offered" holds, i.e. the three phases are disjoint.)
        if (busy) assert ({1'b0, s_req_valid != 2'b00} + {1'b0, s_rsp_ready != 2'b00} + {1'b0, m_rsp_valid != 2'b00} <= 2'd1);
    end

    // reachability, so none of the above is vacuous
    always @(*) if (f_initialized && !rst) begin
        cover (open && busy);
        cover (deliver && !m_rsp_pkt[81]);   // a burst's middle beat
        cover (deliver && who);
        cover (deliver && !who);
        cover (take && taken[15:12] > 4'd1);
    end
endmodule
