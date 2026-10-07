`timescale 1ns/1ps
// The data cache's snoop against a slow ack (Phase 8 Stage 2).
//
// cpu_wb.v's write-through, snooping data cache was argued correct on the
// shared bus because "a write cannot complete while this hart's own fill is in
// flight": the bus serves one transfer at a time, and a transfer that has begun
// holds it until its ack. A fabric with routers breaks the premise. A slave
// completes an access, and the ack - and with it the data of a read - takes a
// few more cycles to reach the hart; another hart's write to the same word can
// complete at the slave, and invalidate this hart's line, in that gap. When the
// late ack then lands it would fill (or update) the cache with a value that is
// already out of date.
//
// Here the slave completes an access when it is strobed (a read latches its data,
// a write lands in memory) and acks `delay` cycles later, and between the two a
// foreign write is poked into memory and snooped, exactly what a second hart's
// write completing in the gap would do.
//   Race 1, a store: our write completes, then the foreign write, then our ack.
//     The cache must not take our (now older) data: the next load has to see the
//     foreign value.
//   Race 2, a load fill: our read returns the old word, the foreign write lands,
//     then our ack delivers the old word. The cache must not keep it.
// The shared bus cannot produce either, so this passes there by construction.
`ifndef SNOOP_PORT2
`define SNOOP_PORT2 0
`endif
module tb_cpu_wb_snoop_race;
    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    reg  [31:0] dmem_addr = 0, dmem_wdata = 0;
    reg         dmem_we = 0, dmem_re = 0;
    reg         snoop_wr = 0;
    reg  [31:0] snoop_adr = 0;
    wire [31:0] dmem_rdata;
    wire        dbus_wait;
    wire        dwb_cyc, dwb_stb, dwb_we;
    wire [31:0] dwb_adr, dwb_dat_w;
    wire [3:0]  dwb_sel;
    reg  [31:0] dwb_dat_r = 0;
    reg         dwb_ack = 0;

    cpu_wb #(.DCACHE_ENABLE(1), .SNOOP_LATE_ACK(1)) DUT (
        .clk(clk), .rst(rst),
        .imem_addr(32'h0000_1000), .imem_rdata(), .ibus_wait(), .itlb_wait_stall(1'b0),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_we(dmem_we),
        .dmem_re(dmem_re), .dmem_is_amo(1'b0), .dmem_size(2'b10),
        .dmem_rdata(dmem_rdata), .dmem_rvalid(), .dbus_wait(dbus_wait),
        .fence_i(1'b0),
`ifdef HAS_SNOOP2
        .snoop_wr(1'b0), .snoop_adr(32'b0),
        .snoop2_wr(snoop_wr), .snoop2_adr(snoop_adr),
`else
        .snoop_wr(snoop_wr), .snoop_adr(snoop_adr), .snoop2_wr(1'b0), .snoop2_adr(32'b0),
`endif
        .iwb_cyc(), .iwb_stb(), .iwb_adr(), .iwb_burst(), .iwb_dat_r(32'b0), .iwb_ack(1'b0),
        .dwb_cyc(dwb_cyc), .dwb_stb(dwb_stb), .dwb_we(dwb_we),
        .dwb_adr(dwb_adr), .dwb_dat_w(dwb_dat_w), .dwb_sel(dwb_sel),
        .dwb_dat_r(dwb_dat_r), .dwb_ack(dwb_ack));

    // ---- the slow slave: completes at the strobe, acks `delay` cycles later ----
    reg [31:0] mem;
    integer    delay = 1, cnt = 0;
    reg        waiting = 0;
    always @(posedge clk) begin
        dwb_ack <= 1'b0;
        if (!waiting) begin
            if (dwb_cyc && dwb_stb && !dwb_ack) begin
                if (dwb_we) mem <= dwb_dat_w; else dwb_dat_r <= mem;
                cnt <= delay;
                waiting <= 1'b1;
            end
        end else begin
            if (cnt <= 1) begin dwb_ack <= 1'b1; waiting <= 1'b0; end
            cnt <= cnt - 1;
        end
    end

    integer errors = 0;
    task check(input [1023:0] name, input [31:0] got, input [31:0] expected);
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: got %08h expected %08h", name, got, expected);
                errors = errors + 1;
            end else $display("  ok   %0s: %08h", name, got);
        end
    endtask

    task do_store(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); #1;
            dmem_addr = a; dmem_wdata = d; dmem_we = 1'b1; dmem_re = 1'b0;
            @(posedge clk);
            while (dbus_wait) @(posedge clk);
            @(posedge clk); #1;
            dmem_we = 1'b0;
        end
    endtask
    task do_load(input [31:0] a);
        begin
            @(posedge clk); #1;
            dmem_addr = a; dmem_we = 1'b0; dmem_re = 1'b1;
            @(posedge clk);
            while (dbus_wait) @(posedge clk);
            #1;
            dmem_re = 1'b0;
        end
    endtask
    // another hart's write to `a` completing now: memory changes and the snoop fires
    task foreign_write(input [31:0] a, input [31:0] d);
        begin
            #1;
            mem = d;
            snoop_wr = 1'b1; snoop_adr = a;
            @(posedge clk); #1;
            snoop_wr = 1'b0;
        end
    endtask

    localparam [31:0] W = 32'h8000_0040;
    initial begin
        @(posedge clk); @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        // prime: W holds 0xAAAA0001 in memory and in the cache
        delay = 1;
        do_store(W, 32'hAAAA_0001);
        do_load(W);
        check("primed: the cache holds the word", dmem_rdata, 32'hAAAA_0001);

        // ---- Race 1: a store whose ack is slow ----
        delay = 8;
        fork
            do_store(W, 32'h1111_1111);                 // completes at the slave, acks 8 cycles on
            begin @(posedge dwb_stb); repeat (3) @(posedge clk); foreign_write(W, 32'h2222_2222); end
        join
        delay = 1;
        // the foreign write dropped the line; the store's late ack must not bring it back
        check("race 1: a store acked after a foreign write does not put its older data back in the cache",
              {31'b0, DUT.dc_valid[DUT.dc_idx]}, 32'h0);
        do_load(W);
        check("race 1: the next load sees the foreign write", dmem_rdata, 32'h2222_2222);

        // ---- Race 2: a load fill whose ack is slow ----
        // make sure the line is gone, then let the read return the old word
        mem = 32'h3333_3333;
        snoop_wr = 1'b1; snoop_adr = W; @(posedge clk); #1; snoop_wr = 1'b0;
        delay = 8;
        fork
            do_load(W);                                  // reads 0x33333333, delivered 8 cycles on
            begin @(posedge dwb_stb); repeat (3) @(posedge clk); foreign_write(W, 32'h4444_4444); end
        join
        delay = 1;
        do_load(W);
        check("race 2: a fill acked after a foreign write does not keep the older word",
              dmem_rdata, 32'h4444_4444);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("CPU-WB-SNOOP-RACE-TEST: PASS");
        else             $display("CPU-WB-SNOOP-RACE-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #50_000;
        $display("TIMEOUT - the snoop race test never completed");
        $finish;
    end
endmodule
