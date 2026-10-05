// Slave-side network interface (Phase 8 Stage 1): takes a request packet
// from the network, performs it as a Wishbone B4 classic *master* against one
// slave, and returns the slave's answer as a response packet. Packet layout
// is documented in noc_ni_master.v.
//
// One request at a time: `req_ready` is high only when idle, so a request
// that arrives while the previous response is still waiting for the network
// is held off in the network (real back-pressure), not dropped or queued
// here.
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
    input  wire [79:0] req_pkt,
    output wire        req_ready,
    output wire        rsp_valid,
    output wire [79:0] rsp_pkt,
    input  wire        rsp_ready,

    // Wishbone master port (toward the slave)
    output wire        wb_cyc,
    output wire        wb_stb,
    output wire        wb_we,
    output wire [31:0] wb_adr,
    output wire [31:0] wb_dat_w,
    output wire [3:0]  wb_sel,
    input  wire [31:0] wb_dat_r,
    input  wire        wb_ack,
    input  wire        wb_err
);
    localparam S_IDLE = 2'd0, S_BUSY = 2'd1, S_RESP = 2'd2;

    reg [1:0]  state;
    reg [79:0] lat;      // the request being performed
    reg        held;     // cyc kept up between a locked request and its successor
    reg [31:0] r_dat;
    reg        r_err;

    assign req_ready = (state == S_IDLE);

    assign wb_cyc   = (state == S_BUSY) || held;
    assign wb_stb   = (state == S_BUSY);
    assign wb_we    = lat[1];
    assign wb_sel   = lat[5:2];
    assign wb_adr   = lat[47:16];
    assign wb_dat_w = lat[79:48];

    assign rsp_valid = (state == S_RESP);
    // src/dst swap; qos echoed; err in the `we` slot; read data in `dat`.
    assign rsp_pkt   = {r_dat, 32'b0, lat[11:8], ID, lat[7:6], 4'b0, r_err, 1'b0};

    wire done = (state == S_BUSY) && (wb_ack || wb_err);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            held  <= 1'b0;
            lat   <= 80'b0;
            r_dat <= 32'b0;
            r_err <= 1'b0;
        end else begin
            case (state)
                S_IDLE: if (req_valid) begin
                    lat   <= req_pkt;
                    state <= S_BUSY;
                end
                S_BUSY: if (done) begin
                    r_dat <= wb_dat_r;
                    r_err <= wb_err;
                    held  <= lat[0];
                    state <= S_RESP;
                end
                default: if (rsp_ready) state <= S_IDLE;
            endcase
        end
    end
endmodule
