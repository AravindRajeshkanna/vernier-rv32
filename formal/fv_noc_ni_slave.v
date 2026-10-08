// Formal properties for rtl/soc/noc_ni_slave.v (Phase 8 Stage 1; the bypass, Stage 3).
//
// The slave interface turns a request packet into a Wishbone transaction
// and the slave's acks into response packets. What can go wrong is lost or
// invented data - a response packet dropped when the queue overflows, a
// burst that never ends, a transaction that ends early - which surfaces far
// from here as a wrong word in a register. So the conservation is proved.
//
// With BYPASS set (fv_noc_ni_slave_bypass, below) the interface also shortcuts two registers:
// a request accepted this cycle is presented to the slave this cycle, and a response with
// nothing queued ahead of it leaves in the cycle of the ack. Both are where a wrong word
// could now come from (a request that changes between its first cycle and the next, a
// response offered and then queued differently), so those are what is added: the request the
// slave sees never changes while it is waiting, a response that is offered and not taken
// stays as it was, and every packet that leaves carries the data, error and last flags of
// the ack it answers, in order. The last two are checked without the bypass too.
//
// The environment is assumed legal: a request that is offered and not taken
// stays, unchanged, until taken; a burst is a read; the slave acks (or
// errors, never both) only while it is being strobed.
module fv_noc_ni_slave #(
    parameter BYPASS = 0
) (
    input wire        clk,
    input wire        rst,
    input wire        req_valid,
    input wire [81:0] req_pkt,
    input wire        rsp_ready,
    input wire [31:0] wb_dat_r,
    input wire        wb_ack,
    input wire        wb_err
);
    wire        req_ready, rsp_valid;
    wire [81:0] rsp_pkt;
    wire        wb_cyc, wb_stb, wb_we, wb_burst;
    wire [31:0] wb_adr, wb_dat_w;
    wire [3:0]  wb_sel;

    noc_ni_slave #(.ID(4'd3), .BYPASS(BYPASS)) DUT (
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_pkt(req_pkt), .req_ready(req_ready),
        .rsp_valid(rsp_valid), .rsp_pkt(rsp_pkt), .rsp_ready(rsp_ready),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we), .wb_adr(wb_adr),
        .wb_dat_w(wb_dat_w), .wb_sel(wb_sel), .wb_burst(wb_burst),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack), .wb_err(wb_err));

    reg f_initialized = 1'b0;
    always @(posedge clk) f_initialized <= 1'b1;
    always @(*) if (!f_initialized) assume (rst);

    // ---- the transaction and the queue, as seen from the ports ----
    wire accept = req_valid && req_ready;
    wire beat   = wb_stb && (wb_ack || wb_err);
    wire pop    = rsp_valid && rsp_ready;      // a packet leaves, queued or not

    reg        out;          // a request is being performed
    reg        cur_burst, cur_lock, held;
    reg [1:0]  beats;
    reg [2:0]  qn;           // response packets owed to the network and not yet gone

    // The request in force this cycle: with BYPASS, one accepted now already is.
    wire       first = (BYPASS != 0) && accept;
    wire       cb    = first ? req_pkt[80] : cur_burst;
    wire       cl    = first ? req_pkt[0]  : cur_lock;
    wire [1:0] bc    = first ? 2'd0        : beats;
    wire       last_beat = beat && (!cb || wb_err || bc == 2'd3);

    // What each ack must come out as, in order: its data, whether it was an error, whether it ended
    // the transaction. A packet is compared with the oldest one still owed; with BYPASS that can be
    // the ack of this very cycle.
    reg [31:0] sd [0:3];
    reg        se [0:3];
    reg        sl [0:3];
    reg [1:0]  s_rd, s_wr;

    always @(posedge clk) begin
        if (rst) begin
            out <= 1'b0; cur_burst <= 1'b0; cur_lock <= 1'b0; held <= 1'b0;
            beats <= 2'd0; qn <= 3'd0; s_rd <= 2'd0; s_wr <= 2'd0;
        end else begin
            if (accept) begin
                out <= 1'b1; cur_burst <= req_pkt[80]; cur_lock <= req_pkt[0]; beats <= 2'd0;
            end
            if (beat) begin
                beats <= bc + 2'd1;
                sd[s_wr] <= wb_dat_r; se[s_wr] <= wb_err; sl[s_wr] <= last_beat;
                s_wr <= s_wr + 2'd1;
            end
            if (last_beat) begin out <= 1'b0; held <= cl; end
            if (pop) s_rd <= s_rd + 2'd1;
            qn <= qn + {2'b0, beat} - {2'b0, pop};
        end
    end
    wire [31:0] want_dat  = (qn == 3'd0) ? wb_dat_r  : sd[s_rd];
    wire        want_err  = (qn == 3'd0) ? wb_err    : se[s_rd];
    wire        want_last = (qn == 3'd0) ? last_beat : sl[s_rd];

    // ---- the legal environment ----
    reg        p_ok = 1'b0, p_pend = 1'b0;
    reg [81:0] p_pkt;
    // what the slave saw last cycle, if the transaction goes on, and what the network was offered
    reg        w_pend = 1'b0, r_pend = 1'b0;
    reg [1+4+32+32+1-1:0] w_prev;
    reg [81:0] r_prev;
    always @(posedge clk) begin
        p_ok   <= !rst;
        p_pend <= req_valid && !req_ready;
        p_pkt  <= req_pkt;
        w_pend <= wb_stb && !last_beat;
        w_prev <= {wb_we, wb_sel, wb_adr, wb_dat_w, wb_burst};
        r_pend <= rsp_valid && !rsp_ready;
        r_prev <= rsp_pkt;
    end
    always @(*) if (f_initialized && !rst) begin
        if (p_ok && p_pend) assume (req_valid && req_pkt == p_pkt);
        if (req_pkt[80])    assume (!req_pkt[1]);          // a burst is a read
        assume (!(wb_ack && wb_err));
        if (wb_ack || wb_err) assume (wb_stb);             // acks only to a strobe
    end

    always @(*) if (f_initialized && !rst) begin
        // 1. The strobe is up exactly while a request is outstanding (or being accepted, with
        //    BYPASS), and cyc is up then and across a locked pair's gap.
        assert (wb_stb == (out || first));
        assert (wb_cyc == (out || held || first));

        // 2. A request is taken only when nothing is outstanding and every
        //    response packet of the last one has left.
        if (req_ready) assert (!out && qn == 3'd0);

        // 3. Conservation: every ack became exactly one packet, none lost
        //    to an overflow (the queue holds the most a burst makes) and
        //    none invented.
        assert (qn <= 3'd4);
        assert (rsp_valid == (qn != 3'd0 || (BYPASS != 0 && beat)));
        assert (!out || beats <= 2'd3);

        // 4. A transaction ends where it should: its last packet is marked,
        //    nothing is queued behind it, and an error is always last.
        if (rsp_valid && rsp_pkt[81]) assert ((qn == 3'd1 && !out) || (qn == 3'd0 && last_beat));
        if (rsp_valid && rsp_pkt[1])  assert (rsp_pkt[81]);

        // 5. The response is addressed back: source and destination swapped,
        //    this interface's own ID as the sender.
        if (rsp_valid) assert (rsp_pkt[11:8] == 4'd3);

        // 6. What leaves is what the slave answered, in order: the data, the error flag, and the
        //    mark on the last one.
        if (rsp_valid) begin
            assert (rsp_pkt[79:48] == want_dat);
            assert (rsp_pkt[1]     == want_err);
            assert (rsp_pkt[81]    == want_last);
        end

        // 7. A response that is offered and not taken is offered again, unchanged.
        if (p_ok && r_pend) assert (rsp_valid && rsp_pkt == r_prev);

        // 8. The slave sees one request throughout: while a transaction goes on, what it is
        //    shown does not change, from the first cycle (which with BYPASS is the cycle the
        //    request is accepted) to the last.
        if (p_ok && w_pend) assert (wb_stb && {wb_we, wb_sel, wb_adr, wb_dat_w, wb_burst} == w_prev);

        // 9. With BYPASS the request shown in the cycle it is accepted is the packet's own.
        if (BYPASS != 0 && accept)
            assert (wb_we == req_pkt[1] && wb_sel == req_pkt[5:2] && wb_adr == req_pkt[47:16] &&
                    wb_dat_w == req_pkt[79:48] && wb_burst == req_pkt[80]);
    end

    // reachability, so none of the above is vacuous
    always @(*) if (f_initialized && !rst) begin
        cover (qn == 3'd4);
        cover (last_beat && cb && bc == 2'd3);
        cover (last_beat && wb_err);
        cover (accept && req_pkt[0]);
        if (BYPASS != 0) begin
            cover (accept && last_beat);                          // finished in its first cycle
            cover (accept && beat && !last_beat);                 // a burst's first beat in its first cycle
            cover (beat && qn == 3'd0 && rsp_valid && !rsp_ready);// offered at once, refused, queued instead
            cover (beat && qn == 3'd0 && pop);                    // straight through
        end
    end
endmodule

// The same, with the bypass on.
module fv_noc_ni_slave_bypass (
    input wire        clk,
    input wire        rst,
    input wire        req_valid,
    input wire [81:0] req_pkt,
    input wire        rsp_ready,
    input wire [31:0] wb_dat_r,
    input wire        wb_ack,
    input wire        wb_err
);
    fv_noc_ni_slave #(.BYPASS(1)) P (.clk(clk), .rst(rst), .req_valid(req_valid), .req_pkt(req_pkt),
                                     .rsp_ready(rsp_ready), .wb_dat_r(wb_dat_r), .wb_ack(wb_ack), .wb_err(wb_err));
endmodule
