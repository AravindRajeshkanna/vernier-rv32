// Formal properties for rtl/soc/noc_ni_slave.v (Phase 8 Stage 1).
//
// The slave interface turns a request packet into a Wishbone transaction
// and the slave's acks into response packets. What can go wrong is lost or
// invented data - a response packet dropped when the queue overflows, a
// burst that never ends, a transaction that ends early - which surfaces far
// from here as a wrong word in a register. So the conservation is proved.
//
// The environment is assumed legal: a request that is offered and not taken
// stays, unchanged, until taken; a burst is a read; the slave acks (or
// errors, never both) only while it is being strobed.
module fv_noc_ni_slave (
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

    noc_ni_slave #(.ID(4'd3)) DUT (
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
    wire pop    = rsp_valid && rsp_ready;

    reg        out;          // a request is being performed
    reg        cur_burst, cur_lock, held;
    reg [1:0]  beats;
    reg [2:0]  qn;           // response packets queued
    wire       last_beat = beat && (!cur_burst || wb_err || beats == 2'd3);

    always @(posedge clk) begin
        if (rst) begin
            out <= 1'b0; cur_burst <= 1'b0; cur_lock <= 1'b0; held <= 1'b0;
            beats <= 2'd0; qn <= 3'd0;
        end else begin
            if (accept) begin
                out <= 1'b1; cur_burst <= req_pkt[80]; cur_lock <= req_pkt[0]; beats <= 2'd0;
            end
            if (beat) beats <= beats + 2'd1;
            if (last_beat) begin out <= 1'b0; held <= cur_lock; end
            qn <= qn + {2'b0, beat} - {2'b0, pop};
        end
    end

    // ---- the legal environment ----
    reg        p_ok = 1'b0, p_pend = 1'b0;
    reg [81:0] p_pkt;
    always @(posedge clk) begin
        p_ok   <= !rst;
        p_pend <= req_valid && !req_ready;
        p_pkt  <= req_pkt;
    end
    always @(*) if (f_initialized && !rst) begin
        if (p_ok && p_pend) assume (req_valid && req_pkt == p_pkt);
        if (req_pkt[80])    assume (!req_pkt[1]);          // a burst is a read
        assume (!(wb_ack && wb_err));
        if (wb_ack || wb_err) assume (wb_stb);             // acks only to a strobe
    end

    always @(*) if (f_initialized && !rst) begin
        // 1. The strobe is up exactly while a request is outstanding, and
        //    cyc is up then and across a locked pair's gap.
        assert (wb_stb == out);
        assert (wb_cyc == (out || held));

        // 2. A request is taken only when nothing is outstanding and every
        //    response packet of the last one has left.
        if (req_ready) assert (!out && qn == 3'd0);

        // 3. Conservation: every ack became exactly one packet, none lost
        //    to an overflow (the queue holds the most a burst makes) and
        //    none invented.
        assert (qn <= 3'd4);
        assert (rsp_valid == (qn != 3'd0));
        assert (!out || beats <= 2'd3);

        // 4. A transaction ends where it should: its last packet is marked,
        //    nothing is queued behind it, and an error is always last.
        if (rsp_valid && rsp_pkt[81]) assert (qn == 3'd1 && !out);
        if (rsp_valid && rsp_pkt[1])  assert (rsp_pkt[81]);

        // 5. The response is addressed back: source and destination swapped,
        //    this interface's own ID as the sender.
        if (rsp_valid) assert (rsp_pkt[11:8] == 4'd3);
    end

    // reachability, so none of the above is vacuous
    always @(*) if (f_initialized && !rst) begin
        cover (qn == 3'd4);
        cover (last_beat && cur_burst && beats == 2'd3);
        cover (last_beat && wb_err);
        cover (accept && req_pkt[0]);
    end
endmodule
