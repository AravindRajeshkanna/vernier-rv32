// A debugger and a wfi that waits (Phase 8 Stage 4, Part 38). A hart parked at a wfi is not running anything, and the
// pipeline is not empty (a parked wfi holds decode in rtl/cpu_core.v and the head of the reorder buffer in
// rtl/ooo/core_ooo.v), so a halt, which waits for the pipeline to drain, would never finish if the wait did not
// let go of the debugger's request. Two things are checked, driven through the hart-control port directly as
// sim/tb_cpu_halt.v does:
//   A  a halt request halts a hart that is waiting at a wfi, and resuming it carries on past the wfi
//   B  single-stepping onto a wfi steps it (it completes) instead of waiting for an interrupt that never comes
// The program is five instructions at the reset vector (encodings from riscv64-unknown-elf-as):
//   addi x5, x0, 1     00100293    x5 = 1, the mark of the code before the wfi
//   addi x6, x0, 0     00000313
//   wfi                10500073    the 3rd instruction, at 8
//   addi x5, x5, 1     00128293    x5 = 2, the mark of the code after it
//   jal  x0, 0         0000006f
// Every interrupt input is tied low and mie is zero, so nothing ever ends the wait but the debugger.
//
// DUT: `CORE_OOO_DUT defined builds core_ooo, otherwise cpu_core. WAIT is the core's WFI_WAIT; the Makefile also builds
// WAIT=0, where part A must fail (instructions keep retiring: the wfi did not wait), which keeps the test honest.
//
// What a halt leaves behind differs between the cores and is not asserted: the in-order core stops admitting at once and
// halts with dpc at the instruction after the wfi (x5 = 1), where the wide core retires what it had already dispatched
// behind the parked wfi first (x5 = 2, dpc at the jal), as it does for any halt. That the wfi waited is read from the
// count of retired instructions instead, which both cores keep.
`timescale 1ns / 1ps

module tb_wfi_dbg;
    parameter WAIT = 1;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

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

`ifdef CORE_OOO_DUT
    core_ooo #(.WFI_WAIT(WAIT)) CPU (
`else
    cpu_core #(.WFI_WAIT(WAIT)) CPU (
`endif
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
        .resv_valid(), .resv_addr(), .store_fire(), .store_addr(),
        .resv_invalidate_ext(1'b0),
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
        IMEM.mem[0] = 32'h00100293;  // addi x5, x0, 1
        IMEM.mem[1] = 32'h00000313;  // addi x6, x0, 0
        IMEM.mem[2] = 32'h10500073;  // wfi
        IMEM.mem[3] = 32'h00128293;  // addi x5, x5, 1
        IMEM.mem[4] = 32'h0000006F;  // jal  x0, 0
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
            @(posedge clk);
            @(negedge clk);
            dbg_reg_valid = 1'b0;
        end
    endtask

    task wait_halted(input [511:0] what);
        integer n;
        begin
            n = 0;
            while (!dbg_halted && n < 400) begin
                @(posedge clk);
                n = n + 1;
            end
            check(what, dbg_halted);
        end
    endtask

    // The same negedge-buffered shape as sim/tb_cpu_halt.v's dbg_resume, for the same reason.
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
            while (dbg_halted && n < 400) begin
                @(posedge clk);
                n = n + 1;
            end
            check("dbg_halted deasserts after resumereq", !dbg_halted);
        end
    endtask

    reg [31:0] v, d;
    integer i, r0, r1;

    // Instructions retired since reset (instret_retire is a wire of both cores).
    integer retired = 0;
    always @(posedge clk) if (!rst && CPU.instret_retire) retired = retired + 1;

    initial begin
        $display("WFI-DBG config: WFI_WAIT=%0d", WAIT);
        repeat (4) @(posedge clk);
        rst = 0;

        // ---- A: halt a hart that is waiting at the wfi ----
        repeat (300) @(posedge clk);
        r0 = retired;
        repeat (100) @(posedge clk);
        r1 = retired;
        $display("  retired: %0d at 300 cycles, %0d at 400", r0, r1);
        check_hex("only the 2 addi retired in 400 cycles: parked at the wfi", {r1[15:0], r0[15:0]}, {16'd2, 16'd2});

        dbg_haltreq = 1'b1;
        wait_halted("a hart waiting at a wfi halts on request");
        dbg_read(REGNO_X5, v);
        $display("  x5 at the halt: %0d", v);
        check("x5 is 1 or 2 (the wide core retires what it dispatched)", v == 32'd1 || v == 32'd2);
        dbg_read(REGNO_DCSR, d);
        check("dcsr.cause == 3 (haltreq)", d[8:6] == 3'd3);
        dbg_read(REGNO_DPC, d);
        $display("  dpc after halting at the wfi: %08h", d);
        check("dpc is past the wfi (the wfi has completed)", d >= 32'h0000000C);

        dbg_resume;
        wait_resumed;
        repeat (60) @(posedge clk);
        dbg_haltreq = 1'b1;
        wait_halted("it halts again");
        dbg_read(REGNO_X5, v);
        check_hex("resuming carries on past the wfi: x5 is 2", v, 32'd2);
        dbg_resume;                                        // and leaves it running, so that reset below finds it spinning

        // ---- B: single-step onto the wfi ----
        @(negedge clk);
        rst = 1'b1;
        dbg_haltreq = 1'b1;                                // halt at the reset vector, before anything runs
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        wait_halted("halted at the reset vector");
        dbg_read(REGNO_DPC, d);
        check_hex("dpc is the reset vector", d, 32'h0);

        dbg_write(REGNO_DCSR, 32'h0000_0004);              // dcsr.step
        for (i = 0; i < 2; i = i + 1) begin                // the two addi
            dbg_resume;
            wait_halted("a step halts");
        end
        dbg_read(REGNO_DPC, d);
        check_hex("two steps in: dpc is the wfi", d, 32'h00000008);

        dbg_resume;                                        // the wfi: must complete
        wait_halted("a step onto a wfi halts (it does not wait for one)");
        dbg_read(REGNO_DCSR, d);
        check("dcsr.cause == 4 (step)", d[8:6] == 3'd4);
        dbg_read(REGNO_DPC, d);
        check_hex("dpc is the instruction after the wfi", d, 32'h0000000C);
        dbg_read(REGNO_X5, v);
        check_hex("x5 is still 1 (the step took the wfi and nothing else)", v, 32'd1);

        dbg_resume;
        wait_halted("the next step halts");
        dbg_read(REGNO_X5, v);
        check_hex("x5 is 2 after stepping the addi after the wfi", v, 32'd2);

        dbg_write(REGNO_DCSR, 32'h0000_0000);
        dbg_resume;

        if (failures == 0) $display("\nWFI-DBG-TEST: PASS");
        else               $display("\nWFI-DBG-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #400000;
        $display("\nWFI-DBG-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
