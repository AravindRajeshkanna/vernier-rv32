// Hart control (rtl/cpu_core.v's dbg_haltreq/dbg_resumereq/dbg_reg_*),
// driven directly - no DMI, no JTAG. sim/tb_jtag.v covers the same ground
// through the real Abstract Command DMI protocol; this one isolates the
// mechanism itself: does halt actually freeze the pipeline, does resume
// actually un-freeze it, does the debug register port read/write the real
// architectural register file, and - the newest piece - does dcsr.step
// resume for exactly one instruction and land back in halted with
// dcsr.cause=4, not zero and not two.
//
// The DUT is a real 2-instruction increment loop (`addi x5,x5,1` /
// `jal x0,-4`) at the reset vector, not the illegal-instruction-trap-
// forever pattern sim/tb_jtag.v uses for its own (different) purpose. That
// pattern never writes a GPR, so "read a GPR before/after N idle cycles,
// assert unchanged" would pass even if halt were a complete no-op - this
// loop actually has something to prove wrong. Encodings verified against
// riscv64-unknown-elf-as, not hand-trusted:
//   addi x5, x5, 1  -> 00128293
//   jal  x0, -4     -> ffdff06f  (branches back to the reset vector)
`timescale 1ns / 1ps

module tb_cpu_halt;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---- minimal zero-latency harness, mirroring rtl/top.v's wiring for
    // the ports this test actually exercises. No MMU, no interrupts, no
    // peripherals - none of that is what is under test here.
    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire        dmem_we, dmem_re;
    wire [1:0]  dmem_size;
    wire        trap;

    reg         dbg_haltreq = 1'b0, dbg_resumereq = 1'b0;
    wire        dbg_halted;
    reg         dbg_reg_valid = 1'b0, dbg_reg_we = 1'b0;
    reg  [15:0] dbg_reg_num = 16'b0;
    reg  [31:0] dbg_reg_wdata = 32'b0;
    wire [31:0] dbg_reg_rdata;
    wire        dbg_reg_err;

    cpu_core CPU (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .itlb_wait_stall(),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_size(dmem_size),
        .dmem_rdata(dmem_rdata), .dmem_rvalid(1'b1), .dmem_is_amo(),
        .ibus_wait(1'b0), .dbus_wait(1'b0),
        .ptw_req(), .ptw_addr(), .ptw_gnt(1'b0), .ptw_rdata(32'b0),
        .iptw_req(), .iptw_addr(), .iptw_gnt(1'b0), .iptw_rdata(32'b0),
        .mtip(1'b0), .msip_in(1'b0), .meip(1'b0), .seip(1'b0),
        .mtime_in(64'b0),
        .fence_i(), .trap(trap),
        .dbg_haltreq(dbg_haltreq), .dbg_resumereq(dbg_resumereq), .dbg_halted(dbg_halted),
        .dbg_reg_valid(dbg_reg_valid), .dbg_reg_we(dbg_reg_we),
        .dbg_reg_num(dbg_reg_num), .dbg_reg_wdata(dbg_reg_wdata),
        .dbg_reg_rdata(dbg_reg_rdata), .dbg_reg_err(dbg_reg_err)
    );

    imem #(.MEM_WORDS(64)) IMEM (.addr(imem_addr), .rdata(imem_rdata));
    dmem #(.MEM_BYTES(256)) DMEM (
        .clk(clk), .addr(dmem_addr), .wdata(dmem_wdata),
        .we(dmem_we), .size(dmem_size), .rdata(dmem_rdata),
        .req2(1'b0), .addr2(32'b0), .gnt2(), .rdata2(),
        .req3(1'b0), .addr3(32'b0), .gnt3(), .rdata3()
    );

    initial begin
        IMEM.mem[0] = 32'h00128293;  // addi x5, x5, 1
        IMEM.mem[1] = 32'hFFDFF06F;  // jal  x0, -4
    end

    integer failures = 0;
    task check(input [511:0] name, input ok);
        begin
            $write("  %0s", name);
            $write("%0s\n", ok ? " ok" : " FAILED");
            if (!ok) failures = failures + 1;
        end
    endtask

    task check_hex(input [511:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) $display("    got %h want %h", got, want);
            check(name, got === want);
        end
    endtask

    localparam [15:0] REGNO_X5   = 16'h1005;
    localparam [15:0] REGNO_DCSR = 16'h07B0;
    localparam [15:0] REGNO_DPC  = 16'h07B1;
    localparam [15:0] REGNO_BAD  = 16'h2000;  // not a GPR, dcsr, or dpc

    task dbg_read(input [15:0] regno, output [31:0] data);
        begin
            @(negedge clk);
            dbg_reg_num   = regno;
            dbg_reg_we    = 1'b0;
            dbg_reg_valid = 1'b1;
            #1;
            data = dbg_reg_rdata;
            @(negedge clk);
            dbg_reg_valid = 1'b0;
        end
    endtask

    task dbg_write(input [15:0] regno, input [31:0] data);
        begin
            @(negedge clk);
            dbg_reg_num   = regno;
            dbg_reg_we    = 1'b1;
            dbg_reg_wdata = data;
            dbg_reg_valid = 1'b1;
            @(posedge clk);   // the write needs to be present at a real clock edge to latch
            @(negedge clk);
            dbg_reg_valid = 1'b0;
        end
    endtask

    task wait_halted;
        integer n;
        begin
            n = 0;
            while (!dbg_halted && n < 200) begin
                @(posedge clk);
                n = n + 1;
            end
            check("halted within a bounded number of cycles", dbg_halted);
        end
    endtask

    // Same negedge-buffered shape as dbg_write above, and for the same
    // reason: clearing dbg_resumereq immediately after the one
    // `@(posedge clk)` it needs to be sampled on raced the synchronous
    // always block that samples it, depending on process-evaluation order
    // for that same edge (both are triggered by the identical posedge, and
    // the language does not order them) - found by this exact test timing
    // out on resume before the fix. Holding one more negedge past the
    // sampling edge removes the race instead of relying on scheduling luck.
    task dbg_resume;
        begin
            @(negedge clk);
            dbg_haltreq   = 1'b0;
            dbg_resumereq = 1'b1;
            @(posedge clk);
            @(negedge clk);
            dbg_resumereq = 1'b0;
        end
    endtask

    task wait_resumed;
        integer n;
        begin
            n = 0;
            while (dbg_halted && n < 200) begin
                @(posedge clk);
                n = n + 1;
            end
            check("dbg_halted deasserts after resumereq", !dbg_halted);
        end
    endtask

    reg  [31:0] v0, v1, v2, sentinel;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;

        // ---- confirm the loop is alive before touching anything debug-related ----
        repeat (30) @(posedge clk);
        check("x5 advances on its own before any halt request",
              CPU.RF.regs[5] > 32'd1);

        // ---- halt, and prove it is real: GPR stable across idle cycles ----
        dbg_haltreq = 1'b1;
        wait_halted;

        dbg_read(REGNO_X5, v0);
        repeat (20) @(posedge clk);
        dbg_read(REGNO_X5, v1);
        check_hex("x5 unchanged across idle cycles while halted", v1, v0);

        // ---- dcsr/dpc read while halted ----
        dbg_read(REGNO_DCSR, v2);
        check("dcsr.cause == 3 (haltreq)", v2[8:6] == 3'd3);
        check("dcsr.prv == PRIV_M (2'b11) at reset", v2[1:0] == 2'b11);

        dbg_read(REGNO_DPC, v2);
        check("dpc points inside the 2-instruction loop (< 8)", v2 < 32'd8);

        // ---- an unrecognized regno reports err, not a stale/garbage value ----
        @(negedge clk);
        dbg_reg_num   = REGNO_BAD;
        dbg_reg_we    = 1'b0;
        dbg_reg_valid = 1'b1;
        #1;
        check("dbg_reg_err set for an unrecognized regno", dbg_reg_err);
        @(negedge clk);
        dbg_reg_valid = 1'b0;

        // ---- write x5, read it back, still halted ----
        sentinel = 32'hCAFEF00D;
        dbg_write(REGNO_X5, sentinel);
        dbg_read(REGNO_X5, v1);
        check_hex("x5 reads back the debug write", v1, sentinel);

        // ---- resume: the write must be what the hart picks up and moves past ----
        // haltreq is sticky by design (rtl/debug/dm.v's own dmcontrol
        // handling) - a real host clears it before/with resuming, or the
        // hart re-halts on its very next cycle. dbg_resume handles that.
        dbg_resume;
        wait_resumed;

        repeat (30) @(posedge clk);

        // ---- halt again, confirm execution actually continued from the resume ----
        dbg_haltreq = 1'b1;
        wait_halted;
        dbg_read(REGNO_X5, v2);
        check("x5 advanced past the debug-written sentinel after resume",
              v2 > sentinel);

        // ---- single-step: dcsr.step, written through the same debug port ----
        //
        // Two steps, not one, and on purpose: dpc could be sitting on
        // either instruction right now (nothing above pinned that down -
        // it depends on exactly when the pipeline happened to drain), but
        // one full iteration of a 2-instruction loop always executes the
        // addi exactly once and lands dpc back where it started, whichever
        // instruction that was. "x5 up by 1, dpc unchanged" is true either
        // way, so the test does not need to know or care which instruction
        // dpc names at the start.
        dbg_write(REGNO_DCSR, 32'h0000_0004);   // dcsr.step = 1
        dbg_read(REGNO_DCSR, v2);
        check("dcsr.step reads back set", v2[2] == 1'b1);

        dbg_read(REGNO_X5, v0);
        dbg_read(REGNO_DPC, v1);

        dbg_resume;
        wait_halted;
        dbg_read(REGNO_DCSR, v2);
        check("dcsr.cause == 4 (step) after one single-step", v2[8:6] == 3'd4);
        dbg_read(REGNO_DPC, v2);
        // 0 and 4 are the loop's only two instruction addresses, so one
        // step always lands on "the other one" - addi falls through to the
        // jal at +4, and the jal jumps back to the addi at 0.
        check("dpc moved to the loop's other instruction after one step",
              v2 == (v1 ^ 32'd4));

        dbg_resume;
        wait_halted;
        dbg_read(REGNO_DCSR, v2);
        check("dcsr.cause == 4 (step) after the second single-step", v2[8:6] == 3'd4);
        dbg_read(REGNO_DPC, v2);
        check("dpc back where it started after a full stepped loop iteration",
              v2 == v1);
        dbg_read(REGNO_X5, v2);
        check_hex("x5 up by exactly 1 after one full stepped loop iteration",
                  v2, v0 + 32'd1);

        // dcsr.step is sticky by spec - resuming does not clear it, a host
        // wanting an ordinary resume back must write it to 0 first.
        dbg_write(REGNO_DCSR, 32'h0000_0000);
        dbg_read(REGNO_DCSR, v2);
        check("dcsr.step clears on an explicit write back to 0", v2[2] == 1'b0);

        dbg_resume;

        if (failures == 0) $display("\nCPU-HALT-TEST: PASS");
        else                $display("\nCPU-HALT-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #200000;
        $display("\nCPU-HALT-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
