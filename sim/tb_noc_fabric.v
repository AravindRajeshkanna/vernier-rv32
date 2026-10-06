`timescale 1ns/1ps
// The Phase 8 network fabric against the bus it stands in for (Stage 1's
// Done-when: the same functional behaviour as the bus).
//
// Two copies of one small system run the same random traffic: one around
// wb_interconnect, one around wb_noc_fabric. Each has two harts' data, walker
// and fetch masters, the debug master and the NPU's, and three slaves of the
// kinds the SoC has - a burst-capable RAM with wait states, a one-wait RAM,
// and a device that acks in the cycle it is addressed - plus an address range
// nothing decodes. Every master follows a script drawn from its own seeded
// generator, so both copies see the identical request sequence, and each
// master logs every value it reads.
//
// What has to agree: every master's log, word for word; every slave's final
// contents; and the AMO counters, which two harts increment with the bus's
// real protocol (read, raise d_amo_wrphase with the ack, write, drop it) and
// which come out exact only if no other master falls into the gap. Timing is
// allowed to differ - the fabric takes more cycles - and is not compared.
//
// The masters write only words of their own and read other words only from a
// region nothing writes, so there is exactly one right answer whatever the
// interleaving, and a mismatch is a real difference.
module eq_slaves (
    input  wire        clk,
    input  wire        s_cyc,
    input  wire [2:0]  s_stb,
    input  wire        s_we,
    input  wire [31:0] s_adr,
    input  wire [31:0] s_dat_w,
    input  wire [3:0]  s_sel,
    input  wire        s_burst,
    output wire [95:0] s_dat_r,
    output wire [2:0]  s_ack
);
    reg [31:0] m0 [0:4095];
    reg [31:0] m1 [0:4095];
    reg [31:0] m2 [0:15];
    integer k;
    initial begin
        for (k = 0; k < 4096; k = k + 1) begin
            // the read-only region (words below 0x100) holds a pattern; the rest starts at zero
            m0[k] = (k < 256) ? (32'ha5000000 + k) : 32'b0;
            m1[k] = (k < 256) ? (32'h5a000000 + k) : 32'b0;
        end
        for (k = 0; k < 16; k = k + 1) m2[k] = 32'b0;
    end

    // slave 0: random waits, and a four-word burst when asked
    reg        ack0 = 0;
    reg [31:0] dat0 = 0;
    integer    w0 = 0, sd0 = 11;
    reg [1:0]  b0 = 0;
    wire [11:0] i0 = s_adr[13:2] + (s_burst ? {10'b0, b0} : 12'd0);
    always @(posedge clk) begin
        ack0 <= 1'b0;
        if (!(s_cyc && s_stb[0])) b0 <= 2'd0;
        if (s_cyc && s_stb[0] && !ack0) begin
            if (w0 > 0) w0 <= w0 - 1;
            else begin
                ack0 <= 1'b1;
                if (s_we) begin
                    if (s_sel[0]) m0[i0][7:0]   <= s_dat_w[7:0];
                    if (s_sel[1]) m0[i0][15:8]  <= s_dat_w[15:8];
                    if (s_sel[2]) m0[i0][23:16] <= s_dat_w[23:16];
                    if (s_sel[3]) m0[i0][31:24] <= s_dat_w[31:24];
                end else dat0 <= m0[i0];
                b0 <= s_burst ? b0 + 2'd1 : 2'd0;
                w0 <= ($random(sd0) & 32'h7fffffff) % 3;
            end
        end
    end

    // slave 1: one wait state
    reg        ack1 = 0;
    reg [31:0] dat1 = 0;
    always @(posedge clk) begin
        ack1 <= s_cyc && s_stb[1] && !ack1;
        if (s_cyc && s_stb[1] && !ack1) begin
            if (s_we) begin
                if (s_sel[0]) m1[s_adr[13:2]][7:0]   <= s_dat_w[7:0];
                if (s_sel[1]) m1[s_adr[13:2]][15:8]  <= s_dat_w[15:8];
                if (s_sel[2]) m1[s_adr[13:2]][23:16] <= s_dat_w[23:16];
                if (s_sel[3]) m1[s_adr[13:2]][31:24] <= s_dat_w[31:24];
            end else dat1 <= m1[s_adr[13:2]];
        end
    end

    // slave 2: a device, acks in the cycle it is addressed
    wire ack2 = s_cyc && s_stb[2];
    always @(posedge clk) if (ack2 && s_we) begin
        if (s_sel[0]) m2[s_adr[5:2]][7:0]   <= s_dat_w[7:0];
        if (s_sel[1]) m2[s_adr[5:2]][15:8]  <= s_dat_w[15:8];
        if (s_sel[2]) m2[s_adr[5:2]][23:16] <= s_dat_w[23:16];
        if (s_sel[3]) m2[s_adr[5:2]][31:24] <= s_dat_w[31:24];
    end

    assign s_ack   = {ack2, ack1, ack0};
    assign s_dat_r = {m2[s_adr[5:2]], dat1, dat0};
endmodule

// One copy of the system. FABRIC=0 builds the bus, FABRIC=1 the network.
module eq_side #(parameter FABRIC = 0, parameter N = 300, parameter AMOS = 40) (
    input  wire clk,
    input  wire rst,
    output reg  done
);
    localparam NH = 2, NS = 3;

    reg  [NH-1:0]    f_cyc = 0, f_stb = 0, f_burst = 0;
    reg  [NH*32-1:0] f_adr = 0;
    wire [NH*32-1:0] f_dat_r;
    wire [NH-1:0]    f_ack;
    reg  [NH-1:0]    d_cyc = 0, d_stb = 0, d_we = 0, d_wr = 0;
    reg  [NH*32-1:0] d_adr = 0, d_dat_w = 0;
    reg  [NH*4-1:0]  d_sel = 0;
    wire [NH*32-1:0] d_dat_r;
    wire [NH-1:0]    d_ack;
    reg  [NH-1:0]    w_cyc = 0, w_stb = 0;
    reg  [NH*32-1:0] w_adr = 0;
    wire [NH*32-1:0] w_dat_r;
    wire [NH-1:0]    w_ack;
    reg              dbg_cyc = 0, dbg_stb = 0, dbg_we = 0;
    reg  [31:0]      dbg_adr = 0, dbg_dat_w = 0;
    reg  [3:0]       dbg_sel = 0;
    wire [31:0]      dbg_dat_r;
    wire             dbg_ack;
    reg              n_cyc = 0, n_stb = 0;
    reg  [31:0]      n_adr = 0;
    wire [31:0]      n_dat_r;
    wire             n_ack;

    wire             s_cyc, s_we, s_burst, s_data_master;
    wire [NS-1:0]    s_stb, s_ack;
    wire [31:0]      s_adr, s_dat_w;
    wire [3:0]       s_sel;
    wire [NS*32-1:0] s_dat_r;
    wire             snoop_wr;
    wire [31:0]      snoop_adr;
    wire [NH-1:0]    snoop_src_d;

    localparam [NS*8-1:0] BASES = {8'h02, 8'h90, 8'h80};
    localparam [NS*8-1:0] MASKS = {8'hFF, 8'hFF, 8'hFF};

    generate
        if (FABRIC == 0) begin : g_bus
            wb_interconnect #(.NUM_SLAVES(NS), .NUM_HARTS(NH), .BURST_SLAVES(1)) IC (
                .clk(clk), .rst(rst),
                .f_cyc(f_cyc), .f_stb(f_stb), .f_adr(f_adr), .f_burst(f_burst), .f_dat_r(f_dat_r), .f_ack(f_ack),
                .d_cyc(d_cyc), .d_stb(d_stb), .d_we(d_we), .d_adr(d_adr), .d_dat_w(d_dat_w), .d_sel(d_sel),
                .d_dat_r(d_dat_r), .d_ack(d_ack), .d_amo_wrphase(d_wr),
                .w_cyc(w_cyc), .w_stb(w_stb), .w_adr(w_adr), .w_dat_r(w_dat_r), .w_ack(w_ack),
                .dbg_cyc(dbg_cyc), .dbg_stb(dbg_stb), .dbg_we(dbg_we), .dbg_adr(dbg_adr),
                .dbg_dat_w(dbg_dat_w), .dbg_sel(dbg_sel), .dbg_dat_r(dbg_dat_r), .dbg_ack(dbg_ack),
                .n_cyc(n_cyc), .n_stb(n_stb), .n_adr(n_adr), .n_dat_r(n_dat_r), .n_ack(n_ack),
                .s_base(BASES), .s_mask(MASKS),
                .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
                .s_dat_r(s_dat_r), .s_ack(s_ack), .s_data_master(s_data_master), .s_burst(s_burst),
                .snoop_wr(snoop_wr), .snoop_adr(snoop_adr), .snoop_src_d(snoop_src_d));
        end else begin : g_noc
            wb_noc_fabric #(.NUM_SLAVES(NS), .NUM_HARTS(NH), .BURST_SLAVES(1)) IC (
                .clk(clk), .rst(rst),
                .f_cyc(f_cyc), .f_stb(f_stb), .f_adr(f_adr), .f_burst(f_burst), .f_dat_r(f_dat_r), .f_ack(f_ack),
                .d_cyc(d_cyc), .d_stb(d_stb), .d_we(d_we), .d_adr(d_adr), .d_dat_w(d_dat_w), .d_sel(d_sel),
                .d_dat_r(d_dat_r), .d_ack(d_ack), .d_amo_wrphase(d_wr),
                .w_cyc(w_cyc), .w_stb(w_stb), .w_adr(w_adr), .w_dat_r(w_dat_r), .w_ack(w_ack),
                .dbg_cyc(dbg_cyc), .dbg_stb(dbg_stb), .dbg_we(dbg_we), .dbg_adr(dbg_adr),
                .dbg_dat_w(dbg_dat_w), .dbg_sel(dbg_sel), .dbg_dat_r(dbg_dat_r), .dbg_ack(dbg_ack),
                .n_cyc(n_cyc), .n_stb(n_stb), .n_adr(n_adr), .n_dat_r(n_dat_r), .n_ack(n_ack),
                .s_base(BASES), .s_mask(MASKS),
                .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
                .s_dat_r(s_dat_r), .s_ack(s_ack), .s_data_master(s_data_master), .s_burst(s_burst),
                .snoop_wr(snoop_wr), .snoop_adr(snoop_adr), .snoop_src_d(snoop_src_d));
        end
    endgenerate

    eq_slaves SL (.clk(clk), .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr),
                  .s_dat_w(s_dat_w), .s_sel(s_sel), .s_burst(s_burst), .s_dat_r(s_dat_r), .s_ack(s_ack));

    // ---- the bus's side outputs, tallied: who wrote what, and which
    // transfers a data master made. Order differs between the two copies;
    // counts and sums do not.
    integer sn_cnt [0:2];
    reg [31:0] sn_sum [0:2];
    integer dm_cnt = 0, amo_done = 0, sh;
    initial for (sh = 0; sh < 3; sh = sh + 1) begin sn_cnt[sh] = 0; sn_sum[sh] = 0; end
    always @(posedge clk) if (!rst) begin
        // (a write to an address nothing decodes is acked by both, but only the bus
        // reports it to the snoopers; it changes no memory, so it is left out)
        if (snoop_wr && snoop_adr[31:28] != 4'h3) begin
            sh = snoop_src_d[0] ? 0 : snoop_src_d[1] ? 1 : 2;
            sn_cnt[sh] = sn_cnt[sh] + 1;
            sn_sum[sh] = sn_sum[sh] + snoop_adr;
        end
        if (s_data_master && s_cyc && (|(s_stb & s_ack))) dm_cnt = dm_cnt + 1;
    end

    // ---- what every master saw ----
    reg [31:0] log [0:8*1024-1];
    integer    lc [0:7];
    integer    li;
    initial for (li = 0; li < 8; li = li + 1) lc[li] = 0;
    task automatic put(input integer m, input [31:0] v);
        begin log[m*1024 + lc[m]] = v; lc[m] = lc[m] + 1; end
    endtask

    // ---- addresses ----
    // slave sel: 0 -> 0x8000_0000, 1 -> 0x9000_0000, 2 -> 0x0200_0000, 3 -> unmapped 0x3000_0000
    function [31:0] base_of(input integer sl);
        base_of = (sl == 0) ? 32'h8000_0000 : (sl == 1) ? 32'h9000_0000 :
                  (sl == 2) ? 32'h0200_0000 : 32'h3000_0000;
    endfunction
    // a word only master m writes: words 0x400 + 0x100*m + k in the RAMs, register m*2 in the device
    function [31:0] own_adr(input integer m, input integer sl, input integer k);
        own_adr = base_of(sl) + ((sl == 2) ? ((m & 7) * 2 + (k & 1)) * 4 :
                                 (32'h400 + 32'h100 * m + (k & 63)) * 4);
    endfunction
    // the shared AMO counters: word 0x800 of RAMs 0 and 1
    function [31:0] amo_adr(input integer which);
        amo_adr = base_of(which) + 32'h800 * 4;
    endfunction

    // ---- masters ----
    // All of them: drive just after a rising edge, hold until acked, read the
    // ack at the next rising edge.
    task automatic gap(input integer seedv, input integer mx);
        integer g;
        begin
            g = ($random(seedv) & 32'h7fffffff) % mx;
            repeat (g) @(posedge clk);
            #1;
        end
    endtask

    // data master h
    task automatic d_xfer(input integer h, input we, input [31:0] a, input [31:0] dat,
                          input [3:0] sel, output [31:0] rd);
        begin
            d_cyc[h] = 1'b1; d_stb[h] = 1'b1; d_we[h] = we;
            d_adr[32*h +: 32] = a; d_dat_w[32*h +: 32] = dat; d_sel[4*h +: 4] = sel;
            @(posedge clk);
            while (!d_ack[h]) @(posedge clk);
            rd = d_dat_r[32*h +: 32];
            #1;
            d_stb[h] = 1'b0; d_we[h] = 1'b0; d_cyc[h] = 1'b0;
        end
    endtask

    task automatic d_script(input integer h);
        integer i, sd, op, sl, k, c;
        reg [31:0] rd, v, ctr;
        reg [3:0]  sel;
        begin
            sd = 1000 + h;
            for (i = 0; i < N; i = i + 1) begin
                gap(sd, 4);
                op = ($random(sd) & 32'h7fffffff) % 10;
                sl = ($random(sd) & 32'h7fffffff) % 4;
                k  = ($random(sd) & 32'h7fffffff) % 64;
                if (op < 3) begin                        // write own word, random byte lanes
                    v = $random(sd); sel = $random(sd);
                    d_xfer(h, 1'b1, own_adr(h, sl, k), v, sel, rd);
                end else if (op < 6) begin               // read own word
                    d_xfer(h, 1'b0, own_adr(h, sl, k), 32'b0, 4'hf, rd);
                    put(h, rd);
                end else if (op < 8) begin               // read the read-only pattern
                    sl = sl % 2;
                    d_xfer(h, 1'b0, base_of(sl) + (k * 4), 32'b0, 4'hf, rd);
                    put(h, rd);
                end else if (op == 8) begin              // an unmapped read
                    d_xfer(h, 1'b0, base_of(3) + (k * 4), 32'b0, 4'hf, rd);
                    put(h, rd);
                end else begin                           // an AMO increment, the bus's own protocol
                    c = ($random(sd) & 1);
                    d_cyc[h] = 1'b1; d_stb[h] = 1'b1; d_we[h] = 1'b0;
                    d_adr[32*h +: 32] = amo_adr(c); d_sel[4*h +: 4] = 4'hf;
                    @(posedge clk);
                    while (!d_ack[h]) @(posedge clk);
                    ctr = d_dat_r[32*h +: 32];
                    #1;
                    d_wr[h] = 1'b1; d_stb[h] = 1'b0;     // the core raises this as the read is acked
                    @(posedge clk); #1;                  // and its decode bubble
                    d_stb[h] = 1'b1; d_we[h] = 1'b1; d_dat_w[32*h +: 32] = ctr + 1;
                    @(posedge clk);
                    while (!d_ack[h]) @(posedge clk);
                    #1;
                    d_stb[h] = 1'b0; d_we[h] = 1'b0; d_cyc[h] = 1'b0; d_wr[h] = 1'b0;
                    amo_done = amo_done + 1;
                end
            end
        end
    endtask

    // fetch master h: single reads and bursts (bursts only where the slave streams them)
    task automatic f_script(input integer h);
        integer i, sd, sl, k, n, want;
        begin
            sd = 2000 + h;
            for (i = 0; i < N; i = i + 1) begin
                gap(sd, 5);
                sl = ($random(sd) & 32'h7fffffff) % 2;
                k  = (($random(sd) & 32'h7fffffff) % 60) * 4;     // line aligned
                f_cyc[h] = 1'b1; f_stb[h] = 1'b1;
                f_adr[32*h +: 32] = base_of(sl) + k * 4;
                f_burst[h] = ($random(sd) & 1);
                want = (f_burst[h] && sl == 0) ? 4 : 1;           // the bus streams only slave 0
                n = 0;
                while (n < want) begin
                    @(posedge clk);
                    if (f_ack[h]) begin put(2 + h, f_dat_r[32*h +: 32]); n = n + 1; end
                    #1;
                end
                f_cyc[h] = 1'b0; f_stb[h] = 1'b0; f_burst[h] = 1'b0;
            end
        end
    endtask

    // walker h: single reads
    task automatic w_script(input integer h);
        integer i, sd, sl, k;
        begin
            sd = 3000 + h;
            for (i = 0; i < N; i = i + 1) begin
                gap(sd, 6);
                sl = ($random(sd) & 32'h7fffffff) % 2;
                k  = ($random(sd) & 32'h7fffffff) % 200;
                w_cyc[h] = 1'b1; w_stb[h] = 1'b1; w_adr[32*h +: 32] = base_of(sl) + k * 4;
                @(posedge clk);
                while (!w_ack[h]) @(posedge clk);
                put(4 + h, w_dat_r[32*h +: 32]);
                #1;
                w_cyc[h] = 1'b0; w_stb[h] = 1'b0;
            end
        end
    endtask

    // debug master: writes and reads of its own words (the code is its own master number, 6)
    task automatic dbg_script;
        integer i, sd, sl, k;
        reg [31:0] v;
        begin
            sd = 4000;
            for (i = 0; i < N; i = i + 1) begin
                gap(sd, 7);
                sl = ($random(sd) & 32'h7fffffff) % 3;
                k  = ($random(sd) & 32'h7fffffff) % 64;
                dbg_cyc = 1'b1; dbg_stb = 1'b1; dbg_sel = 4'hf;
                dbg_adr = own_adr(6, sl, k);
                dbg_we  = ($random(sd) & 1);
                v = $random(sd); dbg_dat_w = v;
                @(posedge clk);
                while (!dbg_ack) @(posedge clk);
                if (!dbg_we) put(6, dbg_dat_r);
                #1;
                dbg_cyc = 1'b0; dbg_stb = 1'b0; dbg_we = 1'b0;
            end
        end
    endtask

    // NPU DMA master: reads
    task automatic n_script;
        integer i, sd, sl, k;
        begin
            sd = 5000;
            for (i = 0; i < N; i = i + 1) begin
                gap(sd, 8);
                sl = ($random(sd) & 32'h7fffffff) % 2;
                k  = ($random(sd) & 32'h7fffffff) % 200;
                n_cyc = 1'b1; n_stb = 1'b1; n_adr = base_of(sl) + k * 4;
                @(posedge clk);
                while (!n_ack) @(posedge clk);
                put(7, n_dat_r);
                #1;
                n_cyc = 1'b0; n_stb = 1'b0;
            end
        end
    endtask

    reg [7:0] fin = 0;
    initial begin
        done = 1'b0;
        wait (!rst);
        repeat (4) @(posedge clk);
        #1;
        fork
            begin d_script(0); fin[0] = 1; end
            begin d_script(1); fin[1] = 1; end
            begin f_script(0); fin[2] = 1; end
            begin f_script(1); fin[3] = 1; end
            begin w_script(0); fin[4] = 1; end
            begin w_script(1); fin[5] = 1; end
            begin dbg_script;  fin[6] = 1; end
            begin n_script;    fin[7] = 1; end
        join
        repeat (20) @(posedge clk);
        done = 1'b1;
    end
endmodule

module tb_noc_fabric;
    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;

    wire done_bus, done_noc;
    eq_side #(.FABRIC(0)) BUS (.clk(clk), .rst(rst), .done(done_bus));
    eq_side #(.FABRIC(1)) NOC (.clk(clk), .rst(rst), .done(done_noc));

    integer failures = 0;
    integer m, i, bad;
    initial begin
        repeat (4) @(posedge clk);
        #1 rst = 0;
        wait (done_bus && done_noc);

        // every master saw the same values, in the same order
        for (m = 0; m < 8; m = m + 1) begin
            bad = 0;
            if (BUS.lc[m] != NOC.lc[m]) begin
                $display("  FAIL master %0d logged %0d reads on the bus, %0d on the fabric", m, BUS.lc[m], NOC.lc[m]);
                failures = failures + 1;
            end
            for (i = 0; i < BUS.lc[m] && i < NOC.lc[m]; i = i + 1)
                if (BUS.log[m*1024 + i] !== NOC.log[m*1024 + i]) begin
                    if (bad < 3)
                        $display("  FAIL master %0d read %0d: bus %08h fabric %08h", m, i,
                                 BUS.log[m*1024 + i], NOC.log[m*1024 + i]);
                    bad = bad + 1;
                end
            if (bad != 0) failures = failures + 1;
            $display("  master %0d: %0d reads compared, %0d differ", m, BUS.lc[m], bad);
        end

        // every slave ended in the same state
        bad = 0;
        for (i = 0; i < 4096; i = i + 1) begin
            if (BUS.SL.m0[i] !== NOC.SL.m0[i]) bad = bad + 1;
            if (BUS.SL.m1[i] !== NOC.SL.m1[i]) bad = bad + 1;
        end
        for (i = 0; i < 16; i = i + 1)
            if (BUS.SL.m2[i] !== NOC.SL.m2[i]) bad = bad + 1;
        if (bad != 0) begin
            $display("  FAIL %0d slave words differ at the end", bad);
            failures = failures + 1;
        end else $display("  all slave contents identical");

        // the AMO counters add up to the increments the harts made: exact
        // only if nobody fell into an AMO's gap
        $display("  AMO increments made: bus %0d fabric %0d; counters: bus %0d + %0d, fabric %0d + %0d",
                 BUS.amo_done, NOC.amo_done, BUS.SL.m0[12'h800], BUS.SL.m1[12'h800],
                 NOC.SL.m0[12'h800], NOC.SL.m1[12'h800]);
        if (BUS.amo_done == 0) begin
            $display("  FAIL no AMO ran");
            failures = failures + 1;
        end
        if (BUS.SL.m0[12'h800] + BUS.SL.m1[12'h800] != BUS.amo_done) begin
            $display("  FAIL the bus lost an AMO update (the test's own reference)");
            failures = failures + 1;
        end
        if (NOC.SL.m0[12'h800] + NOC.SL.m1[12'h800] != NOC.amo_done) begin
            $display("  FAIL the fabric lost an AMO update");
            failures = failures + 1;
        end

        // snooping and the data-master flag
        for (i = 0; i < 3; i = i + 1)
            if (BUS.sn_cnt[i] != NOC.sn_cnt[i] || BUS.sn_sum[i] !== NOC.sn_sum[i]) begin
                $display("  FAIL snoop tally %0d: bus %0d/%08h fabric %0d/%08h", i,
                         BUS.sn_cnt[i], BUS.sn_sum[i], NOC.sn_cnt[i], NOC.sn_sum[i]);
                failures = failures + 1;
            end
        $display("  snooped writes (hart 0, hart 1, other): %0d %0d %0d; data-master transfers %0d",
                 NOC.sn_cnt[0], NOC.sn_cnt[1], NOC.sn_cnt[2], NOC.dm_cnt);
        if (BUS.dm_cnt != NOC.dm_cnt) begin
            $display("  FAIL data-master transfers: bus %0d fabric %0d", BUS.dm_cnt, NOC.dm_cnt);
            failures = failures + 1;
        end

        if (failures == 0) $display("\nNOC FABRIC TEST PASSED");
        else               $display("\nNOC FABRIC TEST FAILED (%0d)", failures);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("  finished masters (bit per master): bus %b, fabric %b", BUS.fin, NOC.fin);
        $display("\nNOC FABRIC TEST FAILED (timeout)");
        $finish;
    end
endmodule
