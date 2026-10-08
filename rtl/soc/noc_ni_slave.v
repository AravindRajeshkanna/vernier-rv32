// Slave-side network interface (Phase 8 Stage 1): takes a request packet
// from the network, performs it as a Wishbone B4 classic *master* against one
// slave, and returns the slave's answer as response packets. Packet layout
// is documented in noc_ni_master.v.
//
// One request at a time: `req_ready` is high only when idle and every
// response packet of the last request has left, so a request that arrives
// early is held off in the network (real back-pressure), not dropped or
// queued here.
//
// ---- Bursts ----
//
// A request with `burst` set is a four-word read the slave answers with four
// acks (the SDRAM controller does, two cycles apart). This block holds `stb`
// and the address steady until the fourth, sends each ack's word as its own
// response packet (the fourth marked `last`), and tells the slave it is a
// burst through `wb_burst`. A Wishbone ack cannot be refused, so the packets
// wait in a four-entry queue: a slow network cannot lose a word.
//
// ---- BYPASS (Phase 8 Stage 3) ----
//
// A read crosses two registers in this block that the bus has none of: the latch `lat`
// the request is copied into (the slave first sees it a cycle after it arrives), and the
// response queue (the response is first visible a cycle after the slave acked). With
// BYPASS set both are skipped when they can be, for two cycles less on every access and
// the same behaviour otherwise:
//
//   - A request accepted this cycle is presented to the slave this cycle, from the packet
//     itself. It is still copied into `lat`, so that if the slave does not ack at once the
//     slave keeps seeing the same request from there, as it always did.
//   - A response whose queue is empty goes straight to the network in the cycle of the ack,
//     if the network will take it. If it will not, it is queued and offered from there,
//     unchanged, as before; and a response behind others always queues, so order is kept.
//
// Both are combinational from the slave's ack, which the bus's own path has always been.
// With BYPASS clear (the default) every expression below reduces to the original, so the
// block is unchanged to the cycle.
//
// ---- Atomics ----
//
// A request with `lock` set is the first half of a sequence the master needs
// to be indivisible (an AMO's read then write, an LR/SC pair's accesses).
// After it completes this block keeps `cyc` high with `stb` low - exactly
// what a bus master does between the two phases - and drops it only when a
// transaction with `lock` clear completes. The slave therefore sees the
// same cyc-held-across-phases pattern a locked bus gives it; keeping *other*
// masters out of the gap is the network's job (noc_node1.v's owner lock),
// and the two together are what LR/SC/AMO need to survive the crossing.
module noc_ni_slave #(
    parameter [3:0] ID = 4'd0,
    parameter       BYPASS = 0
) (
    input  wire        clk,
    input  wire        rst,

    // Network side
    input  wire        req_valid,
    input  wire [81:0] req_pkt,
    output wire        req_ready,
    output wire        rsp_valid,
    output wire [81:0] rsp_pkt,
    input  wire        rsp_ready,

    // Wishbone master port (toward the slave)
    output wire        wb_cyc,
    output wire        wb_stb,
    output wire        wb_we,
    output wire [31:0] wb_adr,
    output wire [31:0] wb_dat_w,
    output wire [3:0]  wb_sel,
    output wire        wb_burst,
    output wire [3:0]  wb_src,       // who is being served (the request's `src`), while `wb_cyc` is up
    input  wire [31:0] wb_dat_r,
    input  wire        wb_ack,
    input  wire        wb_err
);
    reg        busy;     // a request is being performed
    reg [81:0] lat;      // the request being performed
    reg        held;     // cyc kept up between a locked request and its successor
    reg [1:0]  beats;    // acks of a burst already taken

    // response queue: four packets, the most a burst makes
    reg [81:0] q [0:3];
    reg [1:0]  q_rd, q_wr;
    reg [2:0]  q_n;
    wire       q_empty = (q_n == 3'd0);

    assign req_ready = !busy && q_empty;

    // The request the slave sees. With BYPASS, one accepted this cycle is already in force.
    wire        first = (BYPASS != 0) && req_valid && req_ready;
    wire        act   = busy || first;
    wire [81:0] cur   = first ? req_pkt : lat;
    wire [1:0]  bcur  = first ? 2'd0 : beats;

    assign wb_cyc   = act || held;
    assign wb_stb   = act;
    assign wb_we    = cur[1];
    assign wb_sel   = cur[5:2];
    assign wb_adr   = cur[47:16];
    assign wb_dat_w = cur[79:48];
    assign wb_burst = cur[80] && act;
    assign wb_src   = cur[11:8];

    wire done_beat = act && (wb_ack || wb_err);
    wire last_beat = done_beat && (!cur[80] || wb_err || bcur == 2'd3);
    // src/dst swap; qos echoed; err in the `we` slot; read data in `dat`.
    wire [81:0] beat_pkt = {last_beat, 1'b0, wb_dat_r, 32'b0, cur[11:8], ID, cur[7:6],
                            4'b0, wb_err, 1'b0};

    // The response: from the queue, or with BYPASS straight from the ack when nothing is queued.
    wire direct = (BYPASS != 0) && done_beat && q_empty && rsp_ready;
    wire push   = done_beat && !direct;
    wire pop    = !q_empty && rsp_ready;
    assign rsp_valid = !q_empty || ((BYPASS != 0) && done_beat);
    assign rsp_pkt   = ((BYPASS != 0) && q_empty) ? beat_pkt : q[q_rd];

    always @(posedge clk) begin
        if (rst) begin
            busy  <= 1'b0;
            held  <= 1'b0;
            lat   <= 82'b0;
            beats <= 2'd0;
            q_rd  <= 2'd0;
            q_wr  <= 2'd0;
            q_n   <= 3'd0;
        end else begin
            if (!busy && req_ready && req_valid) begin
                lat   <= req_pkt;
                busy  <= 1'b1;
                beats <= 2'd0;
            end
            // (with BYPASS this can be the same cycle as the accept; these assignments come
            // later and win, which is what a request that is finished in its first cycle needs)
            if (done_beat) begin
                beats <= bcur + 2'd1;
                if (last_beat) begin
                    busy <= 1'b0;
                    held <= cur[0];
                end
            end
            if (push) begin
                q[q_wr] <= beat_pkt;
                q_wr    <= q_wr + 2'd1;
            end
            if (pop) q_rd <= q_rd + 2'd1;
            q_n <= q_n + {2'b0, push} - {2'b0, pop};
        end
    end
endmodule
