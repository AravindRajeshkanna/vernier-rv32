// A drop-in replacement for wb_interconnect.v built from the Phase 8 network
// pieces (Stage 1): the same ports and the same decode, with every master
// behind a noc_ni_master, every slave behind a noc_ni_slave, and a
// noc_node1 between them in place of the arbiter and shared wires.
//
// The point is the roadmap's Stage 1 Done-when, "the same functional
// behaviour as the bus": a module that can stand where the bus stands, run
// against the bus's own tests and the real slaves, and be compared with it
// side by side. It is not faster - a transaction costs a few cycles more
// than on the bus - and says nothing yet about a real multi-node router.
//
// ---- How each piece of the bus's behaviour is kept ----
//
// *Priority.* Master IDs are assigned in the bus's priority order (debug,
// then each hart's data, walker and fetch masters, then the NPU), and the
// node serves the lowest ID, so debug > data > walker > fetch > NPU, and the
// lowest hart within a tier, exactly as `wb_interconnect.v`'s header gives.
//
// *Atomics.* The bus keeps everyone out of an AMO's gap with `d_amo_wrphase`;
// here that signal drives the node's `hold`, which lets only that hart's
// data master through, even while it has nothing to offer.
//
// *Unmapped addresses.* The bus acks an address nothing decodes, with
// zeros, so a core is never left waiting. The node answers such a request
// with an error response, and this module turns an error back into an ack
// with zero data for every master, since no master here has an error input.
//
// *Bursts.* A fetch master's `f_burst` becomes a burst request only when the
// slave it addresses is one of BURST_SLAVES, as in the bus; otherwise it is
// an ordinary single read.
//
// *The shared slave-side wires.* The slaves in soc_top hang off one set of
// shared signals (`s_adr`, `s_we`, `s_dat_w`, one `s_stb` per slave, ...).
// Only one slave interface is active at a time, so each shared wire is the
// OR of the interfaces' outputs, each gated by its own `stb`.
//
// *Snooping.* `snoop_wr` is a write acked by a slave; `snoop_src_d` marks the
// requesting hart's data master, so a hart does not invalidate its own line.
//
// What differs, on purpose: a master that has `cyc` high with `stb` low is
// invisible here, where on the bus it still outranks everyone below it
// (that is how the bus kept an AMO's gap closed before `d_amo_wrphase`
// existed, and the gap is now closed by `hold` alone). The cores here
// raise `cyc` and `stb` together except in that gap.
module wb_noc_fabric #(
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
    output wire                      s_cyc,
    output wire [NUM_SLAVES-1:0]     s_stb,
    output wire                      s_we,
    output wire [31:0]               s_adr,
    output wire [31:0]               s_dat_w,
    output wire [3:0]                s_sel,
    input  wire [NUM_SLAVES*32-1:0]  s_dat_r,
    input  wire [NUM_SLAVES-1:0]     s_ack,

    output wire                      s_data_master,
    output wire                      s_burst,

    output wire                      snoop_wr,
    output wire [31:0]               snoop_adr,
    output wire [NUM_HARTS-1:0]      snoop_src_d
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
            dst_of = 4'd15;     // nothing: the node answers with an error
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
                .wb_qos(2'd0), .wb_lock(1'b0), .wb_burst(1'b0),
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

    // ---- the node ----
    wire [NUM_SLAVES-1:0]    sq_valid, sq_ready, sr_valid, sr_ready;
    wire [81:0]              sq_pkt;
    wire [NUM_SLAVES*82-1:0] sr_pkt;
    wire                     t_at_slave;
    wire [3:0]               t_src;

    // the lowest hart's data master holds the gap, as the bus's own pick does
    // (continuous assignments, not an always block: with `d_amo_wrphase` held
    // at zero nothing would ever trigger the block, and the signal would stay
    // unknown in simulation)
    wire       hold_v = |d_amo_wrphase;
    reg  [3:0] hold_id_f;
    integer    hh;
    always @* begin
        hold_id_f = 4'd0;
        for (hh = NUM_HARTS - 1; hh >= 0; hh = hh - 1)
            if (d_amo_wrphase[hh]) hold_id_f = ID_D4 + hh[3:0];
    end
    wire [3:0] hold_id = hold_id_f;

    noc_node1 #(.NUM_M(NUM_M), .NUM_S(NUM_SLAVES)) NODE (
        .clk(clk), .rst(rst),
        .m_req_valid(mq_valid), .m_req_pkt(mq_pkt), .m_req_ready(mq_ready),
        .m_rsp_valid(mr_valid), .m_rsp_pkt(mr_pkt), .m_rsp_ready(mr_ready),
        .s_req_valid(sq_valid), .s_req_pkt(sq_pkt), .s_req_ready(sq_ready),
        .s_rsp_valid(sr_valid), .s_rsp_pkt(sr_pkt), .s_rsp_ready(sr_ready),
        .hold_v(hold_v), .hold_id(hold_id),
        .t_at_slave(t_at_slave), .t_src(t_src));

    // ---- the slaves' interfaces, and the shared wires they drive ----
    wire [NUM_SLAVES-1:0]    si_cyc, si_stb, si_we, si_burst;
    wire [NUM_SLAVES*32-1:0] si_adr, si_dat_w;
    wire [NUM_SLAVES*4-1:0]  si_sel;

    generate
        for (g = 0; g < NUM_SLAVES; g = g + 1) begin : g_slave
            noc_ni_slave #(.ID(4'(g))) NI_S (
                .clk(clk), .rst(rst),
                .req_valid(sq_valid[g]), .req_pkt(sq_pkt), .req_ready(sq_ready[g]),
                .rsp_valid(sr_valid[g]), .rsp_pkt(sr_pkt[82*g +: 82]), .rsp_ready(sr_ready[g]),
                .wb_cyc(si_cyc[g]), .wb_stb(si_stb[g]), .wb_we(si_we[g]),
                .wb_adr(si_adr[32*g +: 32]), .wb_dat_w(si_dat_w[32*g +: 32]),
                .wb_sel(si_sel[4*g +: 4]), .wb_burst(si_burst[g]),
                .wb_dat_r(s_dat_r[32*g +: 32]), .wb_ack(s_ack[g]), .wb_err(1'b0));
        end
    endgenerate

    reg [31:0] r_adr, r_dat_w;
    reg [3:0]  r_sel;
    reg        r_we, r_burst;
    integer    ss;
    always @* begin
        r_adr = 32'b0; r_dat_w = 32'b0; r_sel = 4'b0; r_we = 1'b0; r_burst = 1'b0;
        for (ss = 0; ss < NUM_SLAVES; ss = ss + 1)
            if (si_stb[ss]) begin
                r_adr   = r_adr   | si_adr[32*ss +: 32];
                r_dat_w = r_dat_w | si_dat_w[32*ss +: 32];
                r_sel   = r_sel   | si_sel[4*ss +: 4];
                r_we    = r_we    | si_we[ss];
                r_burst = r_burst | si_burst[ss];
            end
    end

    assign s_cyc   = |si_cyc;
    assign s_stb   = si_stb;
    assign s_we    = r_we;
    assign s_adr   = r_adr;
    assign s_dat_w = r_dat_w;
    assign s_sel   = r_sel;
    assign s_burst = r_burst;

    // a data master is at the slaves
    assign s_data_master = t_at_slave && (t_src >= ID_D4) && (t_src < ID_W4);

    // acks of the current burst already delivered, as the bus counts them:
    // the verification harness reads it (with `s_burst` and `s_adr`) to know
    // which word of the line an ack carries.
    reg [1:0] burst_acks;
    always @(posedge clk) begin
        if (rst || !(|si_stb))                  burst_acks <= 2'd0;
        else if (r_burst && (|(si_stb & s_ack))) burst_acks <= burst_acks + 2'd1;
    end

    // What the bus calls the master it is serving and the transfer it is
    // finishing, kept under the same names for the Verilator harness
    // (sim/verilator_soc.cpp reads them to check every read against memory
    // and to count bus use). `sel_*` is the node having that master's request
    // at a slave; `fin_ack`/`fin_dat` are a slave's own ack and read data, in
    // the cycle it gives them - as they are on the bus, ahead of the master's.
    wire [NUM_HARTS-1:0] sel_d, sel_w, sel_f;
    wire                 sel_dbg = t_at_slave && (t_src == 4'(ID_DBG));
    wire                 sel_n   = t_at_slave && (t_src == 4'(ID_N));
    wire                 fin_ack = |(si_stb & s_ack);
    reg  [31:0]          fin_dat;
    integer              fd;
    always @* begin
        fin_dat = 32'b0;
        for (fd = 0; fd < NUM_SLAVES; fd = fd + 1)
            if (si_stb[fd]) fin_dat = fin_dat | s_dat_r[32*fd +: 32];
    end
    generate
        for (g = 0; g < NUM_HARTS; g = g + 1) begin : g_sel
            assign sel_d[g] = t_at_slave && (t_src == 4'(ID_D + g));
            assign sel_w[g] = t_at_slave && (t_src == 4'(ID_W + g));
            assign sel_f[g] = t_at_slave && (t_src == 4'(ID_F + g));
        end
    endgenerate

    assign snoop_wr  = r_we && fin_ack;
    assign snoop_adr = r_adr;
    generate
        for (g = 0; g < NUM_HARTS; g = g + 1) begin : g_snoop
            assign snoop_src_d[g] = sel_d[g];
        end
    endgenerate
endmodule
