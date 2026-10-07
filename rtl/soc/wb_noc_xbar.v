// The bus's replacement built on routers instead of one node (Phase 8
// Stage 2): the same masters and decode as wb_noc_fabric.v, with the one-node
// network replaced by a request router and a response router, so that
// transactions to *different* slaves are in flight at the same time.
//
//   master interfaces -> request router  -> slave interfaces (+ an error sink)
//   master interfaces <- response router <- slave interfaces (+ the error sink)
//
// ---- What is different from the bus, and from wb_noc_fabric.v ----
//
// *Per-slave wires.* The bus shares one set of address, data and control wires
// among all its slaves, which is why only one can ever be active. Here every
// slave has its own (`s_adr[i]`, `s_we[i]`, ...) so two can be busy at once;
// wiring a slave to them instead of the shared wires is all that changes for it.
// Likewise `s_data_master[i]` (whether the transaction at slave i is a data
// master's) and `snoop_*[i]` (the writes that slave i has completed), which the
// bus reports once for the one transaction in flight.
//
// *Atomics.* An AMO's two phases must not have another master's access to the
// same slave between them. The bus holds off everyone from the read's ack until the
// write (`d_amo_wrphase`); that is not enough here, because the slave interface
// takes its next request the moment the read finishes, a few cycles before the
// read's response is back at the core and the core can raise `d_amo_wrphase`
// (removing the lock and keeping only that hold lets another master's access in, and
// the equivalence test sees it). So the read has to be locked when it is issued. A
// read-modify-write AMO's read is certain to be followed by a write to the same word,
// and the core knows it is executing one (`d_is_rmw`; not LR, which has no write, nor
// SC, which may not - locking those would never release, and would block the hart's
// own instruction fetch). The data master sends that read with `lock` set,
// `d_amo_wrphase` ends the lock on the write, and the request router's owner lock keeps
// everyone else off that slave across the gap. The router's `hold` input, which
// noc_node1.v's gap needed, is not used here.
//
// *Unmapped addresses* go to the error sink on the extra router port and come back
// as the bus's ack with zero data.
//
// Priority, bursts, the decode and everything else are as in wb_noc_fabric.v.
module wb_noc_xbar #(
    parameter NUM_SLAVES   = 7,
    parameter NUM_HARTS    = 1,
    parameter BURST_SLAVES = 0
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [NUM_HARTS-1:0]      f_cyc,
    input  wire [NUM_HARTS-1:0]      f_stb,
    input  wire [NUM_HARTS*32-1:0]   f_adr,
    input  wire [NUM_HARTS-1:0]      f_burst,
    output wire [NUM_HARTS*32-1:0]   f_dat_r,
    output wire [NUM_HARTS-1:0]      f_ack,

    input  wire [NUM_HARTS-1:0]      d_cyc,
    input  wire [NUM_HARTS-1:0]      d_stb,
    input  wire [NUM_HARTS-1:0]      d_we,
    input  wire [NUM_HARTS*32-1:0]   d_adr,
    input  wire [NUM_HARTS*32-1:0]   d_dat_w,
    input  wire [NUM_HARTS*4-1:0]    d_sel,
    output wire [NUM_HARTS*32-1:0]   d_dat_r,
    output wire [NUM_HARTS-1:0]      d_ack,
    input  wire [NUM_HARTS-1:0]      d_amo_wrphase,
    input  wire [NUM_HARTS-1:0]      d_is_rmw,

    input  wire [NUM_HARTS-1:0]      w_cyc,
    input  wire [NUM_HARTS-1:0]      w_stb,
    input  wire [NUM_HARTS*32-1:0]   w_adr,
    output wire [NUM_HARTS*32-1:0]   w_dat_r,
    output wire [NUM_HARTS-1:0]      w_ack,

    input  wire        dbg_cyc,
    input  wire        dbg_stb,
    input  wire        dbg_we,
    input  wire [31:0] dbg_adr,
    input  wire [31:0] dbg_dat_w,
    input  wire [3:0]  dbg_sel,
    output wire [31:0] dbg_dat_r,
    output wire        dbg_ack,

    input  wire        n_cyc,
    input  wire        n_stb,
    input  wire [31:0] n_adr,
    output wire [31:0] n_dat_r,
    output wire        n_ack,

    input  wire [NUM_SLAVES*8-1:0]  s_base,
    input  wire [NUM_SLAVES*8-1:0]  s_mask,
    output wire [NUM_SLAVES-1:0]     s_cyc,
    output wire [NUM_SLAVES-1:0]     s_stb,
    output wire [NUM_SLAVES-1:0]     s_we,
    output wire [NUM_SLAVES*32-1:0]  s_adr,
    output wire [NUM_SLAVES*32-1:0]  s_dat_w,
    output wire [NUM_SLAVES*4-1:0]   s_sel,
    output wire [NUM_SLAVES-1:0]     s_burst,
    input  wire [NUM_SLAVES*32-1:0]  s_dat_r,
    input  wire [NUM_SLAVES-1:0]     s_ack,

    output wire [NUM_SLAVES-1:0]     s_data_master,

    output wire [NUM_SLAVES-1:0]            snoop_wr,
    output wire [NUM_SLAVES*32-1:0]         snoop_adr,
    output wire [NUM_SLAVES*NUM_HARTS-1:0]  snoop_src_d
);
    // master IDs, in priority order
    localparam NUM_M  = 2 + 3 * NUM_HARTS;
    localparam ID_DBG = 0;
    localparam ID_D   = 1;
    localparam ID_W   = 1 + NUM_HARTS;
    localparam ID_F   = 1 + 2 * NUM_HARTS;
    localparam ID_N   = 1 + 3 * NUM_HARTS;
    localparam [3:0] ID_D4 = 4'(ID_D);    // the same, as the four-bit IDs the packets carry
    localparam [3:0] ID_W4 = 4'(ID_W);

    // ---- decode: which slave does an address belong to ----
    function [3:0] dst_of(input [31:0] a);
        integer k;
        begin
            dst_of = NUM_SLAVES[3:0];   // nothing decodes it: the error sink, one past the last slave
            for (k = 0; k < NUM_SLAVES; k = k + 1)
                if (((a[31:24] & s_mask[8*k +: 8]) == (s_base[8*k +: 8] & s_mask[8*k +: 8])))
                    dst_of = k[3:0];
        end
    endfunction

    function is_burst_slave(input [3:0] d);
        begin
            is_burst_slave = (d < NUM_SLAVES) && (((BURST_SLAVES >> d) & 1) != 0);
        end
    endfunction

    // ---- the masters' interfaces ----
    wire [NUM_M-1:0]    mq_valid, mq_ready, mr_valid, mr_ready;
    wire [NUM_M*82-1:0] mq_pkt, mr_pkt;
    wire [NUM_M-1:0]    mi_ack, mi_err;
    wire [NUM_M*32-1:0] mi_dat;

    genvar g;
    generate
        // debug
        noc_ni_master #(.ID(4'(ID_DBG))) NI_DBG (
            .clk(clk), .rst(rst),
            .wb_cyc(dbg_cyc), .wb_stb(dbg_stb), .wb_we(dbg_we), .wb_adr(dbg_adr),
            .wb_dat_w(dbg_dat_w), .wb_sel(dbg_sel), .wb_dst(dst_of(dbg_adr)),
            .wb_qos(2'd0), .wb_lock(1'b0), .wb_burst(1'b0),
            .wb_dat_r(mi_dat[32*ID_DBG +: 32]), .wb_ack(mi_ack[ID_DBG]), .wb_err(mi_err[ID_DBG]),
            .req_valid(mq_valid[ID_DBG]), .req_pkt(mq_pkt[82*ID_DBG +: 82]), .req_ready(mq_ready[ID_DBG]),
            .rsp_valid(mr_valid[ID_DBG]), .rsp_pkt(mr_pkt[82*ID_DBG +: 82]), .rsp_ready(mr_ready[ID_DBG]));
        // each hart's data, walker and fetch masters
        for (g = 0; g < NUM_HARTS; g = g + 1) begin : g_hart
            noc_ni_master #(.ID(4'(ID_D + g))) NI_D (
                .clk(clk), .rst(rst),
                .wb_cyc(d_cyc[g]), .wb_stb(d_stb[g]), .wb_we(d_we[g]), .wb_adr(d_adr[32*g +: 32]),
                .wb_dat_w(d_dat_w[32*g +: 32]), .wb_sel(d_sel[4*g +: 4]),
                .wb_dst(dst_of(d_adr[32*g +: 32])),
                .wb_qos(2'd0), .wb_lock(d_is_rmw[g] && !d_amo_wrphase[g]), .wb_burst(1'b0),
                .wb_dat_r(mi_dat[32*(ID_D+g) +: 32]), .wb_ack(mi_ack[ID_D+g]), .wb_err(mi_err[ID_D+g]),
                .req_valid(mq_valid[ID_D+g]), .req_pkt(mq_pkt[82*(ID_D+g) +: 82]), .req_ready(mq_ready[ID_D+g]),
                .rsp_valid(mr_valid[ID_D+g]), .rsp_pkt(mr_pkt[82*(ID_D+g) +: 82]), .rsp_ready(mr_ready[ID_D+g]));
            noc_ni_master #(.ID(4'(ID_W + g))) NI_W (
                .clk(clk), .rst(rst),
                .wb_cyc(w_cyc[g]), .wb_stb(w_stb[g]), .wb_we(1'b0), .wb_adr(w_adr[32*g +: 32]),
                .wb_dat_w(32'b0), .wb_sel(4'hf), .wb_dst(dst_of(w_adr[32*g +: 32])),
                .wb_qos(2'd0), .wb_lock(1'b0), .wb_burst(1'b0),
                .wb_dat_r(mi_dat[32*(ID_W+g) +: 32]), .wb_ack(mi_ack[ID_W+g]), .wb_err(mi_err[ID_W+g]),
                .req_valid(mq_valid[ID_W+g]), .req_pkt(mq_pkt[82*(ID_W+g) +: 82]), .req_ready(mq_ready[ID_W+g]),
                .rsp_valid(mr_valid[ID_W+g]), .rsp_pkt(mr_pkt[82*(ID_W+g) +: 82]), .rsp_ready(mr_ready[ID_W+g]));
            noc_ni_master #(.ID(4'(ID_F + g))) NI_F (
                .clk(clk), .rst(rst),
                .wb_cyc(f_cyc[g]), .wb_stb(f_stb[g]), .wb_we(1'b0), .wb_adr(f_adr[32*g +: 32]),
                .wb_dat_w(32'b0), .wb_sel(4'hf), .wb_dst(dst_of(f_adr[32*g +: 32])),
                .wb_qos(2'd0), .wb_lock(1'b0),
                .wb_burst(f_burst[g] && is_burst_slave(dst_of(f_adr[32*g +: 32]))),
                .wb_dat_r(mi_dat[32*(ID_F+g) +: 32]), .wb_ack(mi_ack[ID_F+g]), .wb_err(mi_err[ID_F+g]),
                .req_valid(mq_valid[ID_F+g]), .req_pkt(mq_pkt[82*(ID_F+g) +: 82]), .req_ready(mq_ready[ID_F+g]),
                .rsp_valid(mr_valid[ID_F+g]), .rsp_pkt(mr_pkt[82*(ID_F+g) +: 82]), .rsp_ready(mr_ready[ID_F+g]));

            // an error response is an ack with zero data (every master here
            // has no error input); the interface already zeroes its data
            assign d_dat_r[32*g +: 32] = mi_dat[32*(ID_D+g) +: 32];
            assign w_dat_r[32*g +: 32] = mi_dat[32*(ID_W+g) +: 32];
            assign f_dat_r[32*g +: 32] = mi_dat[32*(ID_F+g) +: 32];
            assign d_ack[g] = mi_ack[ID_D+g] | mi_err[ID_D+g];
            assign w_ack[g] = mi_ack[ID_W+g] | mi_err[ID_W+g];
            assign f_ack[g] = mi_ack[ID_F+g] | mi_err[ID_F+g];
        end
    endgenerate
    // the NPU's DMA master: reads only
    noc_ni_master #(.ID(4'(ID_N))) NI_N (
        .clk(clk), .rst(rst),
        .wb_cyc(n_cyc), .wb_stb(n_stb), .wb_we(1'b0), .wb_adr(n_adr),
        .wb_dat_w(32'b0), .wb_sel(4'hf), .wb_dst(dst_of(n_adr)),
        .wb_qos(2'd0), .wb_lock(1'b0), .wb_burst(1'b0),
        .wb_dat_r(mi_dat[32*ID_N +: 32]), .wb_ack(mi_ack[ID_N]), .wb_err(mi_err[ID_N]),
        .req_valid(mq_valid[ID_N]), .req_pkt(mq_pkt[82*ID_N +: 82]), .req_ready(mq_ready[ID_N]),
        .rsp_valid(mr_valid[ID_N]), .rsp_pkt(mr_pkt[82*ID_N +: 82]), .rsp_ready(mr_ready[ID_N]));

    assign dbg_dat_r = mi_dat[32*ID_DBG +: 32];
    assign dbg_ack   = mi_ack[ID_DBG] | mi_err[ID_DBG];
    assign n_dat_r   = mi_dat[32*ID_N +: 32];
    assign n_ack     = mi_ack[ID_N] | mi_err[ID_N];

    // ---- the routers ----
    localparam NUM_P = NUM_SLAVES + 1;     // the slaves, and the error sink

    wire [NUM_P-1:0]    qo_valid, qo_ready;      // request router outputs
    wire [NUM_P*82-1:0] qo_pkt;
    wire [NUM_P-1:0]    ri_valid, ri_ready;      // response router inputs
    wire [NUM_P*82-1:0] ri_pkt;

    wire qr_misroute, rr_misroute;        // never set: the decode only produces ports
    noc_router #(.NUM_IN(NUM_M), .NUM_OUT(NUM_P), .DEPTH(2)) QR (
        .clk(clk), .rst(rst),
        .in_valid(mq_valid), .in_pkt(mq_pkt), .in_ready(mq_ready),
        .out_valid(qo_valid), .out_pkt(qo_pkt), .out_ready(qo_ready),
        .hold_v(1'b0), .hold_id(4'd0), .misroute(qr_misroute));

    noc_router #(.NUM_IN(NUM_P), .NUM_OUT(NUM_M), .DEPTH(2)) RR (
        .clk(clk), .rst(rst),
        .in_valid(ri_valid), .in_pkt(ri_pkt), .in_ready(ri_ready),
        .out_valid(mr_valid), .out_pkt(mr_pkt), .out_ready(mr_ready),
        .hold_v(1'b0), .hold_id(4'd0), .misroute(rr_misroute));

    // ---- the slaves' interfaces, and the error sink ----
    wire [NUM_SLAVES-1:0] si_cyc, si_stb;
    wire [NUM_SLAVES*4-1:0] si_src;

    genvar sg;
    generate
        for (sg = 0; sg < NUM_SLAVES; sg = sg + 1) begin : g_slave
            noc_ni_slave #(.ID(4'(sg))) NI_S (
                .clk(clk), .rst(rst),
                .req_valid(qo_valid[sg]), .req_pkt(qo_pkt[82*sg +: 82]), .req_ready(qo_ready[sg]),
                .rsp_valid(ri_valid[sg]), .rsp_pkt(ri_pkt[82*sg +: 82]), .rsp_ready(ri_ready[sg]),
                .wb_cyc(si_cyc[sg]), .wb_stb(si_stb[sg]), .wb_we(s_we[sg]),
                .wb_adr(s_adr[32*sg +: 32]), .wb_dat_w(s_dat_w[32*sg +: 32]),
                .wb_sel(s_sel[4*sg +: 4]), .wb_burst(s_burst[sg]), .wb_src(si_src[4*sg +: 4]),
                .wb_dat_r(s_dat_r[32*sg +: 32]), .wb_ack(s_ack[sg]), .wb_err(1'b0));

            // a data master is the one being served at this slave
            assign s_data_master[sg] = si_cyc[sg] &&
                                       (si_src[4*sg +: 4] >= ID_D4) && (si_src[4*sg +: 4] < ID_W4);

            // writes this slave has completed, for the data caches to snoop
            assign snoop_wr[sg]  = si_stb[sg] && s_we[sg] && s_ack[sg];
            assign snoop_adr[32*sg +: 32] = s_adr[32*sg +: 32];
            for (g = 0; g < NUM_HARTS; g = g + 1) begin : g_src
                assign snoop_src_d[sg*NUM_HARTS + g] = si_stb[sg] && (si_src[4*sg +: 4] == 4'(ID_D + g));
            end
        end
    endgenerate
    assign s_cyc = si_cyc;
    assign s_stb = si_stb;

    // Which masters are being served at some slave, under the names the bus's
    // monitoring (sim/bus_monitor.v) reads: a master is "granted" while a slave
    // interface holds its transaction.
    reg [15:0] served;                  // the whole four-bit ID space
    integer sv;
    always @* begin
        served = 16'b0;
        for (sv = 0; sv < NUM_SLAVES; sv = sv + 1)
            if (si_cyc[sv]) served[si_src[4*sv +: 4]] = 1'b1;
    end
    wire [NUM_HARTS-1:0] sel_d   = served[ID_D +: NUM_HARTS];
    wire [NUM_HARTS-1:0] sel_w   = served[ID_W +: NUM_HARTS];
    wire [NUM_HARTS-1:0] sel_f   = served[ID_F +: NUM_HARTS];
    wire                 sel_dbg = served[ID_DBG];
    wire                 sel_n   = served[ID_N];

    noc_err_sink #(.ID(NUM_SLAVES[3:0])) ERRSINK (
        .clk(clk), .rst(rst),
        .req_valid(qo_valid[NUM_SLAVES]), .req_pkt(qo_pkt[82*NUM_SLAVES +: 82]), .req_ready(qo_ready[NUM_SLAVES]),
        .rsp_valid(ri_valid[NUM_SLAVES]), .rsp_pkt(ri_pkt[82*NUM_SLAVES +: 82]), .rsp_ready(ri_ready[NUM_SLAVES]));
endmodule
