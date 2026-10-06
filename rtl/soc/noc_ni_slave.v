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
    parameter [3:0] ID = 4'd0
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

    assign req_ready = !busy && (q_n == 3'd0);

    assign wb_cyc   = busy || held;
    assign wb_stb   = busy;
    assign wb_we    = lat[1];
    assign wb_sel   = lat[5:2];
    assign wb_adr   = lat[47:16];
    assign wb_dat_w = lat[79:48];
    assign wb_burst = lat[80] && busy;

    assign rsp_valid = (q_n != 3'd0);
    assign rsp_pkt   = q[q_rd];

    wire done_beat = busy && (wb_ack || wb_err);
    wire last_beat = done_beat && (!lat[80] || wb_err || beats == 2'd3);
    // src/dst swap; qos echoed; err in the `we` slot; read data in `dat`.
    wire [81:0] beat_pkt = {last_beat, 1'b0, wb_dat_r, 32'b0, lat[11:8], ID, lat[7:6],
                            4'b0, wb_err, 1'b0};
    wire        pop = rsp_valid && rsp_ready;

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
            if (done_beat) begin
                q[q_wr] <= beat_pkt;
                q_wr    <= q_wr + 2'd1;
                beats   <= beats + 2'd1;
                if (last_beat) begin
                    busy <= 1'b0;
                    held <= lat[0];
                end
            end
            if (pop) q_rd <= q_rd + 2'd1;
            q_n <= q_n + {2'b0, done_beat} - {2'b0, pop};
        end
    end
endmodule
