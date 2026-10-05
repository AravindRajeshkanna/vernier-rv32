`timescale 1ns/1ps
// Network interfaces and the one-node network (Phase 8 Stage 1).
//
// Part A - two masters, two slaves, through noc_ni_master -> noc_node1 ->
//   noc_ni_slave. Each master runs a random read/write mix against private
//   words in both slaves (random gaps, some back to back) and checks every
//   read against its own reference copy: round-trip correctness, and per
//   master ordering, because a read right after a write to the same word has
//   to see it. Byte enables, an error response from a slave, and an unmapped
//   address (the node answers with an error) are covered.
//
//   Then both masters do locked read-modify-write increments of ONE shared
//   word. The final count is exact only if no master's request falls between
//   another's read and write - the AMO/LR-SC property the packet's `lock`
//   bit and the node's owner lock exist for. The slave also has to see its
//   `cyc` held across the two phases, which is counted.
//
// Part B - one master straight to one slave through the interfaces with a
//   channel between them that randomly refuses to pass a request or a
//   response for a cycle (valid and ready each gated), proving the
//   valid/ready handshakes hold under real back-pressure and that no packet
//   changes while it is waiting.
module tb_noc_ni;
    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;

    reg partb_go = 0, partb_done = 0;
    integer failures = 0;
    task fail(input [8*48-1:0] what);
        begin
            failures = failures + 1;
            $display("  FAIL %0s", what);
        end
    endtask

    // ---------------------------------------------------------------- Part A
    localparam NM = 2, NS = 2;

    reg  [NM-1:0]    m_cyc = 0, m_stb = 0, m_we = 0, m_lock = 0, m_burst = 0;
    reg  [NM*32-1:0] m_adr = 0, m_dat_w = 0;
    reg  [NM*4-1:0]  m_sel = 0, m_dst = 0;
    wire [NM*32-1:0] m_dat_r;
    wire [NM-1:0]    m_ack, m_err;

    wire [NM-1:0]    mq_valid, mq_ready, mr_valid, mr_ready;
    wire [NM*82-1:0] mq_pkt, mr_pkt;
    wire [NS-1:0]    sq_valid, sq_ready, sr_valid, sr_ready;
    wire [81:0]      sq_pkt;
    wire [NS*82-1:0] sr_pkt;

    wire [NS-1:0]    s_cyc, s_stb, s_we, s_ack, s_err, s_burst;
    wire [NS*32-1:0] s_adr, s_dat_w, s_dat_r;
    wire [NS*4-1:0]  s_sel;

    genvar g;
    generate
        for (g = 0; g < NM; g = g + 1) begin : g_mni
            noc_ni_master #(.ID(g)) NIM (
                .clk(clk), .rst(rst),
                .wb_cyc(m_cyc[g]), .wb_stb(m_stb[g]), .wb_we(m_we[g]),
                .wb_adr(m_adr[g*32 +: 32]), .wb_dat_w(m_dat_w[g*32 +: 32]),
                .wb_sel(m_sel[g*4 +: 4]), .wb_dst(m_dst[g*4 +: 4]),
                .wb_qos(2'd0), .wb_lock(m_lock[g]), .wb_burst(m_burst[g]),
                .wb_dat_r(m_dat_r[g*32 +: 32]), .wb_ack(m_ack[g]), .wb_err(m_err[g]),
                .req_valid(mq_valid[g]), .req_pkt(mq_pkt[g*82 +: 82]), .req_ready(mq_ready[g]),
                .rsp_valid(mr_valid[g]), .rsp_pkt(mr_pkt[g*82 +: 82]), .rsp_ready(mr_ready[g]));
        end
        for (g = 0; g < NS; g = g + 1) begin : g_sni
            noc_ni_slave #(.ID(g)) NIS (
                .clk(clk), .rst(rst),
                .req_valid(sq_valid[g]), .req_pkt(sq_pkt), .req_ready(sq_ready[g]),
                .rsp_valid(sr_valid[g]), .rsp_pkt(sr_pkt[g*82 +: 82]), .rsp_ready(sr_ready[g]),
                .wb_cyc(s_cyc[g]), .wb_stb(s_stb[g]), .wb_we(s_we[g]),
                .wb_adr(s_adr[g*32 +: 32]), .wb_dat_w(s_dat_w[g*32 +: 32]),
                .wb_sel(s_sel[g*4 +: 4]), .wb_burst(s_burst[g]),
                .wb_dat_r(s_dat_r[g*32 +: 32]), .wb_ack(s_ack[g]), .wb_err(s_err[g]));
            wb_memmodel #(.SEED(g + 7), .ERR_WORD(g == 1 ? 254 : -1)) MEM (
                .clk(clk), .cyc(s_cyc[g]), .stb(s_stb[g]), .we(s_we[g]),
                .adr(s_adr[g*32 +: 32]), .dat_w(s_dat_w[g*32 +: 32]), .sel(s_sel[g*4 +: 4]), .burst(s_burst[g]),
                .dat_r(s_dat_r[g*32 +: 32]), .ack(s_ack[g]), .err(s_err[g]));
        end
    endgenerate

    noc_node1 #(.NUM_M(NM), .NUM_S(NS)) NODE (
        .clk(clk), .rst(rst),
        .m_req_valid(mq_valid), .m_req_pkt(mq_pkt), .m_req_ready(mq_ready),
        .m_rsp_valid(mr_valid), .m_rsp_pkt(mr_pkt), .m_rsp_ready(mr_ready),
        .s_req_valid(sq_valid), .s_req_pkt(sq_pkt), .s_req_ready(sq_ready),
        .s_rsp_valid(sr_valid), .s_rsp_pkt(sr_pkt), .s_rsp_ready(sr_ready));

    // Address map: bit 12 picks the slave, bit 31 means "nothing decodes this".
    function [3:0] decode(input [31:0] a);
        decode = a[31] ? 4'd7 : {3'b0, a[12]};
    endfunction

    // One Wishbone transfer from master m. Drives just after a clock edge,
    // holds until acked, leaves cyc up when the caller says more follows.
    task automatic xfer(input integer m, input we, input [31:0] adr, input [31:0] dat,
                        input [3:0] sel, input lock, output [31:0] rd, output e);
        begin
            m_cyc[m] = 1'b1;  m_stb[m] = 1'b1;  m_we[m] = we;
            m_adr[m*32 +: 32] = adr;  m_dat_w[m*32 +: 32] = dat;
            m_sel[m*4 +: 4] = sel;  m_dst[m*4 +: 4] = decode(adr);  m_lock[m] = lock;
            // not `disable`: that would end every master's wait at once
            @(posedge clk);
            while (!(m_ack[m] || m_err[m])) @(posedge clk);
            rd = m_dat_r[m*32 +: 32];
            e  = m_err[m];
            #1;
            m_stb[m] = 1'b0;  m_lock[m] = 1'b0;
            if (!lock) m_cyc[m] = 1'b0;
        end
    endtask

    // A four-word burst read from master m: one request, held through four
    // acks, each ack carrying the next word of the line. `n` counts the acks
    // seen before the transaction ended; an error ends it early.
    task automatic burst_rd(input integer m, input [31:0] adr, output [127:0] words,
                            output integer n, output e);
        reg fin;
        begin
            m_cyc[m] = 1'b1;  m_stb[m] = 1'b1;  m_we[m] = 1'b0;  m_burst[m] = 1'b1;
            m_adr[m*32 +: 32] = adr;  m_dat_w[m*32 +: 32] = 32'b0;
            m_sel[m*4 +: 4] = 4'hf;  m_dst[m*4 +: 4] = decode(adr);  m_lock[m] = 1'b0;
            words = 128'b0;  n = 0;  e = 1'b0;
            fin = 1'b0;
            while (!fin) begin
                @(posedge clk);
                if (m_err[m]) begin
                    e = 1'b1;  fin = 1'b1;
                end else if (m_ack[m]) begin
                    words[n*32 +: 32] = m_dat_r[m*32 +: 32];
                    n = n + 1;
                    if (n == 4) fin = 1'b1;
                end
            end
            #1;
            m_stb[m] = 1'b0;  m_cyc[m] = 1'b0;  m_burst[m] = 1'b0;
        end
    endtask

    // Master m's private words: index 2 + 2*k + m, k < 100, in either slave.
    reg [31:0] ref0 [0:1][0:255];   // [slave][word], master 0's view
    reg [31:0] ref1 [0:1][0:255];
    function [31:0] waddr(input integer sl, input integer idx);
        waddr = (sl << 12) | (idx << 2);
    endfunction

    integer ops_done [0:1];
    integer maxwait = 0;

    task automatic worker(input integer m, input integer n);
        integer i, sl, k, idx, gap, t0, t1;
        reg [31:0] rd, want, nd, old;
        reg e;
        reg [3:0] sel;
        integer seed;
        begin
            seed = 100 + m;
            for (i = 0; i < n; i = i + 1) begin
                sl  = $random(seed) & 1;
                k   = ($random(seed) & 32'h7fffffff) % 100;
                idx = 2 + 2 * k + m;
                gap = ($random(seed) & 32'h7fffffff) % 4;     // 0 = back to back
                repeat (gap) @(posedge clk);
                if (gap != 0) #1;
                t0 = $time;
                if (($random(seed) & 3) == 0) begin
                    // write, random byte enables
                    nd  = $random(seed);
                    sel = $random(seed);
                    xfer(m, 1'b1, waddr(sl, idx), nd, sel, 1'b0, rd, e);
                    old = (m == 0) ? ref0[sl][idx] : ref1[sl][idx];
                    want = old;
                    if (sel[0]) want[7:0]   = nd[7:0];
                    if (sel[1]) want[15:8]  = nd[15:8];
                    if (sel[2]) want[23:16] = nd[23:16];
                    if (sel[3]) want[31:24] = nd[31:24];
                    if (m == 0) ref0[sl][idx] = want; else ref1[sl][idx] = want;
                    if (e) fail("write returned an error");
                end else begin
                    xfer(m, 1'b0, waddr(sl, idx), 32'b0, 4'hf, 1'b0, rd, e);
                    want = (m == 0) ? ref0[sl][idx] : ref1[sl][idx];
                    if (e) fail("read returned an error");
                    else if (rd !== want) begin
                        fail("read data wrong");
                        $display("    master %0d slave %0d word %0d: got %08h want %08h", m, sl, idx, rd, want);
                    end
                end
                t1 = ($time - t0) / 40;
                if (t1 > maxwait) maxwait = t1;
                ops_done[m] = ops_done[m] + 1;
            end
        end
    endtask

    // Locked increments of the shared word (slave 1 word 0).
    task automatic incrementer(input integer m, input integer n);
        integer i, gap, seed;
        reg [31:0] rd, dummy;
        reg e;
        begin
            seed = 500 + m;
            for (i = 0; i < n; i = i + 1) begin
                gap = ($random(seed) & 32'h7fffffff) % 3;
                repeat (gap) @(posedge clk);
                #1;
                xfer(m, 1'b0, waddr(1, 0), 32'b0, 4'hf, 1'b1, rd, e);        // read, lock
                repeat (($random(seed) & 32'h7fffffff) % 3) @(posedge clk);
                #1;
                xfer(m, 1'b1, waddr(1, 0), rd + 1, 4'hf, 1'b0, dummy, e);    // write, release
            end
        end
    endtask

    // an error ends a transaction: the packet that carries one is the last
    integer mi;
    always @(posedge clk) if (!rst)
        for (mi = 0; mi < NS; mi = mi + 1)
            if (sr_valid[mi] && sr_pkt[mi*82 + 1] && !sr_pkt[mi*82 + 81])
                fail("an error response was not marked last");

    // cyc held across the two phases, as the slave sees it
    integer gap_cyc_seen = 0;
    always @(posedge clk) if (!rst && s_cyc[1] && !s_stb[1]) gap_cyc_seen = gap_cyc_seen + 1;

    integer r, w, c;
    reg [31:0] rdv, dmy;
    reg [127:0] bw;
    integer bn, bursts_ok;
    reg ev;
    reg done0 = 0, done1 = 0;

    initial begin
        for (w = 0; w < 256; w = w + 1) begin
            ref0[0][w] = 0; ref0[1][w] = 0; ref1[0][w] = 0; ref1[1][w] = 0;
        end
        ops_done[0] = 0; ops_done[1] = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // ---- A1: random mixed traffic from both masters at once
        fork
            begin worker(0, 600); done0 = 1; end
            begin worker(1, 600); done1 = 1; end
        join
        $display("  A1: %0d + %0d ops, worst transfer %0d cycles", ops_done[0], ops_done[1], maxwait);
        if (!(done0 && done1)) fail("workers did not finish");

        // final state of every private word, read back through the network
        for (c = 0; c < 2; c = c + 1)
            for (r = 0; r < 2; r = r + 1)
                for (w = 0; w < 100; w = w + 1) begin
                    xfer(0, 1'b0, waddr(r, 2 + 2 * w + c), 32'b0, 4'hf, 1'b0, rdv, ev);
                    if (rdv !== (c == 0 ? ref0[r][2 + 2 * w + c] : ref1[r][2 + 2 * w + c]))
                        fail("final contents wrong");
                end

        // ---- A1b: burst reads of a four-word line, while the other master
        // does ordinary traffic. Lines at words 240 and 244 of each slave.
        for (r = 0; r < 2; r = r + 1)
            for (w = 0; w < 8; w = w + 1)
                xfer(0, 1'b1, waddr(r, 240 + w), 32'hb000_0000 + (r << 8) + w, 4'hf, 1'b0, dmy, ev);
        bursts_ok = 0;
        fork
            begin : burster
                for (c = 0; c < 60; c = c + 1) begin
                    repeat (c % 3) @(posedge clk);
                    #1;
                    r = c & 1;
                    burst_rd(0, waddr(r, 240 + 4 * ((c >> 1) & 1)), bw, bn, ev);
                    if (ev || bn != 4) fail("burst did not return four words");
                    else begin
                        for (w = 0; w < 4; w = w + 1)
                            if (bw[w*32 +: 32] !== 32'hb000_0000 + (r << 8) + 4 * ((c >> 1) & 1) + w)
                                fail("burst word wrong or out of order");
                        bursts_ok = bursts_ok + 1;
                    end
                end
            end
            begin worker(1, 200); end
        join
        $display("  A1b: %0d bursts returned four words in order while master 1 did 200 ordinary ops", bursts_ok);
        // a burst that ends in a slave error, and one to an unmapped address
        xfer(0, 1'b1, waddr(0, 3), 32'hfeed0003, 4'hf, 1'b0, dmy, ev);
        burst_rd(0, waddr(1, 252), bw, bn, ev);
        if (!ev || bn != 2) fail("burst error not returned after two words");
        burst_rd(1, 32'h8000_0010, bw, bn, ev);
        if (!ev || bn != 0) fail("unmapped burst not answered with an error");
        xfer(0, 1'b0, waddr(0, 3), 32'b0, 4'hf, 1'b0, rdv, ev);
        if (ev || rdv !== 32'hfeed0003) fail("network wedged or confused after a failed burst");

        // ---- A2: an error from a slave, and an unmapped address
        xfer(0, 1'b0, waddr(1, 254), 32'b0, 4'hf, 1'b0, rdv, ev);
        if (!ev) fail("slave error not returned");
        xfer(1, 1'b1, waddr(0, 3), 32'hdead0001, 4'hf, 1'b0, rdv, ev);
        if (ev) fail("a good write after an error was refused");
        xfer(1, 1'b0, 32'h8000_0010, 32'b0, 4'hf, 1'b0, rdv, ev);
        if (!ev) fail("unmapped address not answered with an error");
        xfer(0, 1'b0, waddr(0, 3), 32'b0, 4'hf, 1'b0, rdv, ev);
        if (rdv !== 32'hdead0001 || ev) fail("network wedged after an unmapped access");

        // ---- A3: locked read-modify-write from both masters
        xfer(0, 1'b1, waddr(1, 0), 32'd0, 4'hf, 1'b0, dmy, ev);
        fork
            incrementer(0, 80);
            incrementer(1, 80);
        join
        xfer(0, 1'b0, waddr(1, 0), 32'b0, 4'hf, 1'b0, rdv, ev);
        $display("  A3: shared counter = %0d (want 160), slave saw cyc held with stb low %0d cycles",
                 rdv, gap_cyc_seen);
        if (rdv !== 32'd160) fail("locked read-modify-write lost an update");
        if (gap_cyc_seen == 0) fail("slave never saw cyc held across a locked pair");

        // ---- Part B
        partb_go = 1;
        wait (partb_done);

        if (failures == 0) $display("\nNOC NI TEST PASSED");
        else               $display("\nNOC NI TEST FAILED (%0d)", failures);
        $finish;
    end

    // ---------------------------------------------------------------- Part B
    reg        b_cyc = 0, b_stb = 0, b_we = 0, b_burst = 0;
    reg [31:0] b_adr = 0, b_dat_w = 0;
    reg [3:0]  b_sel = 0;
    wire [31:0] b_dat_r;
    wire        b_ack, b_err;
    wire        bq_valid, bq_ready;      // master interface <-> channel
    wire [81:0] bq_pkt;
    wire        bs_valid, bs_ready;      // channel <-> slave interface
    wire        sp_valid, sp_ready;      // slave interface -> channel (response)
    wire [81:0] sp_pkt;
    wire        bt_valid, bt_ready;      // channel -> master interface (response)
    wire        w_cyc, w_stb, w_we, w_ack, w_err, w_burst;
    wire [31:0] w_adr, w_dat_w, w_dat_r;
    wire [3:0]  w_sel;

    reg allow_q = 1, allow_r = 1;
    integer bseed = 9;
    always @(negedge clk) begin
        allow_q <= (($random(bseed) & 3) != 0) ? ($random(bseed) & 1) : 1'b1;
        allow_r <= (($random(bseed) & 3) != 0) ? ($random(bseed) & 1) : 1'b1;
    end

    // each channel passes a transfer only in cycles where it allows
    assign bs_valid = bq_valid && allow_q;
    assign bq_ready = bs_ready && allow_q;
    assign bt_valid = sp_valid && allow_r;
    assign sp_ready = bt_ready && allow_r;

    noc_ni_master #(.ID(0)) BNIM (
        .clk(clk), .rst(rst),
        .wb_cyc(b_cyc), .wb_stb(b_stb), .wb_we(b_we), .wb_adr(b_adr), .wb_dat_w(b_dat_w),
        .wb_sel(b_sel), .wb_dst(4'd0), .wb_qos(2'd2), .wb_lock(1'b0), .wb_burst(b_burst),
        .wb_dat_r(b_dat_r), .wb_ack(b_ack), .wb_err(b_err),
        .req_valid(bq_valid), .req_pkt(bq_pkt), .req_ready(bq_ready),
        .rsp_valid(bt_valid), .rsp_pkt(sp_pkt), .rsp_ready(bt_ready));
    noc_ni_slave #(.ID(0)) BNIS (
        .clk(clk), .rst(rst),
        .req_valid(bs_valid), .req_pkt(bq_pkt), .req_ready(bs_ready),
        .rsp_valid(sp_valid), .rsp_pkt(sp_pkt), .rsp_ready(sp_ready),
        .wb_cyc(w_cyc), .wb_stb(w_stb), .wb_we(w_we), .wb_adr(w_adr), .wb_dat_w(w_dat_w),
        .wb_sel(w_sel), .wb_burst(w_burst), .wb_dat_r(w_dat_r), .wb_ack(w_ack), .wb_err(w_err));
    wb_memmodel #(.SEED(31), .ERR_WORD(-1)) BMEM (
        .clk(clk), .cyc(w_cyc), .stb(w_stb), .we(w_we), .adr(w_adr), .dat_w(w_dat_w),
        .sel(w_sel), .burst(w_burst), .dat_r(w_dat_r), .ack(w_ack), .err(w_err));

    // while a request is offered and not taken, it must not change
    reg        q_pend = 0;
    reg [81:0] q_prev;
    always @(posedge clk) begin
        if (q_pend && bq_valid && bq_pkt !== q_prev) fail("request packet changed while waiting");
        q_pend <= bq_valid && !bq_ready;
        q_prev <= bq_pkt;
    end
    reg        r_pend = 0;
    reg [81:0] r_prev;
    always @(posedge clk) begin
        if (r_pend && sp_valid && sp_pkt !== r_prev) fail("response packet changed while waiting");
        r_pend <= sp_valid && !sp_ready;
        r_prev <= sp_pkt;
    end

    // ready means ready: the slave interface must not offer to take a request
    // while it is still performing or answering the last one, and the master
    // interface must not take a response when nothing is outstanding
    always @(posedge clk) if (!rst) begin
        if (bs_ready && (w_stb || sp_valid)) fail("slave interface ready while busy");
        if (bt_ready && !(b_cyc && b_stb))    fail("master interface took an unsolicited response");
    end

    reg [31:0] bref [0:255];
    integer bi, bwn, bseed2, bk, bk2, bnb;
    reg [31:0] brd, bwant;
    reg be;
    integer sawstall = 0;
    always @(posedge clk) if (bq_valid && !bq_ready) sawstall = sawstall + 1;

    initial begin
        for (bk = 0; bk < 256; bk = bk + 1) bref[bk] = 0;
        wait (partb_go);
        bseed2 = 77;
        for (bi = 0; bi < 800; bi = bi + 1) begin
            bwn = ($random(bseed2) & 32'h7fffffff) % 64;
            @(posedge clk); #1;
            bk2 = $random(bseed2) & 3;
            if (bk2 < 2) begin
                brd = $random(bseed2);
                b_cyc = 1; b_stb = 1; b_we = 1; b_adr = bwn << 2; b_dat_w = brd; b_sel = 4'hf;
                begin : wa
                    forever begin @(posedge clk); if (b_ack || b_err) disable wa; end
                end
                #1 b_stb = 0; b_cyc = 0;
                bref[bwn] = brd;
            end else if (bk2 == 3) begin
                // burst read of the line holding word bwn
                bwn = bwn & ~3;
                b_cyc = 1; b_stb = 1; b_we = 0; b_burst = 1; b_adr = bwn << 2; b_sel = 4'hf;
                bnb = 0;
                while (bnb < 4) begin
                    @(posedge clk);
                    if (b_err) begin fail("part B burst errored"); bnb = 4; end
                    else if (b_ack) begin
                        if (b_dat_r !== bref[bwn + bnb]) begin
                            fail("part B burst word wrong");
                            $display("    word %0d: got %08h want %08h", bwn + bnb, b_dat_r, bref[bwn + bnb]);
                        end
                        bnb = bnb + 1;
                    end
                end
                #1 b_stb = 0; b_cyc = 0; b_burst = 0;
            end else begin
                b_cyc = 1; b_stb = 1; b_we = 0; b_adr = bwn << 2; b_sel = 4'hf;
                begin : wb
                    forever begin @(posedge clk);
                        if (b_ack || b_err) begin brd = b_dat_r; be = b_err; disable wb; end
                    end
                end
                #1 b_stb = 0; b_cyc = 0;
                if (be || brd !== bref[bwn]) begin
                    fail("part B read wrong");
                    $display("    word %0d: got %08h want %08h err %b", bwn, brd, bref[bwn], be);
                end
            end
        end
        $display("  B: 800 transfers (writes, reads and bursts) through a randomly stalling channel; request refused in %0d cycles", sawstall);
        partb_done = 1;
    end

    initial begin
        #200_000_000;
        $display("\nNOC NI TEST FAILED (timeout)");
        $finish;
    end
endmodule

// Wishbone slave memory: 256 words, random wait states, byte enables,
// optionally an error response at one word. A burst read answers four acks,
// the words of the line from `adr` on, a couple of cycles apart (the SDRAM
// controller's pattern); the error word ends it early.
module wb_memmodel #(parameter SEED = 1, parameter integer ERR_WORD = -1) (
    input  wire        clk,
    input  wire        cyc, stb, we,
    input  wire [31:0] adr, dat_w,
    input  wire [3:0]  sel,
    input  wire        burst,
    output reg  [31:0] dat_r,
    output reg         ack,
    output reg         err
);
    reg [31:0] mem [0:255];
    integer    waits, seed, k;
    reg [1:0]  bcnt;
    reg [7:0]  widx;
    initial begin
        seed = SEED;
        waits = 0;
        bcnt = 0;
        ack = 0; err = 0; dat_r = 0;
        for (k = 0; k < 256; k = k + 1) mem[k] = 0;
    end
    always @(posedge clk) begin
        ack <= 1'b0;
        err <= 1'b0;
        if (!(cyc && stb)) bcnt <= 2'd0;     // a burst ends when the request does
        if (cyc && stb && !ack && !err) begin
            if (waits > 0) waits <= waits - 1;
            else begin
                widx = adr[9:2] + (burst ? {6'b0, bcnt} : 8'd0);
                if (widx == ERR_WORD) begin
                    err  <= 1'b1;
                    bcnt <= 2'd0;
                end else begin
                    ack <= 1'b1;
                    if (we) begin
                        if (sel[0]) mem[widx][7:0]   <= dat_w[7:0];
                        if (sel[1]) mem[widx][15:8]  <= dat_w[15:8];
                        if (sel[2]) mem[widx][23:16] <= dat_w[23:16];
                        if (sel[3]) mem[widx][31:24] <= dat_w[31:24];
                    end else dat_r <= mem[widx];
                    bcnt <= burst ? bcnt + 2'd1 : 2'd0;
                end
                waits <= ($random(seed) & 32'h7fffffff) % 4;
            end
        end
    end
endmodule
