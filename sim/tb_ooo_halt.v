// Hart control for rtl/ooo/core_ooo.v (dbg_haltreq/dbg_resumereq/dbg_reg_*),
// driven directly - no DMI, no JTAG (sim/tb_jtag.v covers that protocol
// layer once these ports are wired for real). Modeled on
// sim/tb_cpu_halt.v's own proof for rtl/cpu_core.v: does halt actually
// freeze the pipeline, does resume actually un-freeze it, does the debug
// register port read/write the real architectural register state, and does
// dcsr.step resume for exactly one instruction and land back in halted with
// dcsr.cause=4 - plus one check neither cpu_core.v nor its own test needs.
//
// This core retires a plain store into a one-entry store buffer (sb_valid)
// before its write actually reaches the bus - rob_empty/fb_empty can both
// be true while a write this hart already reported as retired is still
// physically draining. dbg_pipeline_quiescent's own `!sb_valid` term
// exists specifically to close that gap; check 0 below proves it is
// load-bearing, not decorative.
//
// Check 0 runs against its OWN small, isolated program (addi/sw/self-jump),
// not the shared increment loop the rest of the checks use, and for a
// specific reason found empirically, not assumed: fetch/dispatch race far
// ahead of a store's own bus completion (confirmed by direct trace - by
// the time a store even starts its bus request, several iterations of an
// ordinary loop are already dispatched), so reusing the increment loop for
// this check would let a backlog build up that keeps rob_empty/fb_empty
// from ever coinciding with sb_valid still being set, making the check
// vacuous regardless of dbg_pipeline_quiescent's own correctness - this
// was caught by the mutation test itself (dropping `!sb_valid` produced no
// observable failure) before being fixed to the design below. A self-jump
// after the one store has nothing further to admit once fetch is blocked,
// so the backlog in flight at that point is minimal and rob_empty/fb_empty
// reliably coincide with sb_valid still being 1 for a real, observed
// multi-cycle window.
//
// A real hardware reset separates the two programs - core_ooo.v has no
// mechanism to swap programs otherwise. Results for checks 1+ are read via
// CPU.RF.regs[CPU.rat[N]] - regfile_phys has no architectural index of its
// own, matching sim/tb_ooo_resv_ports.v's and sim/tb_ooo_csr_hazard.v's own
// established idiom for this core.
//
// Encodings verified against riscv64-unknown-elf-as, not hand-trusted:
//   addi x1, x0, 0x40   -> 04000093   (check 0's scratch store address)
//   sw   x0, 0(x1)      -> 0000a023   (check 0's one-time store)
//   jal  x0, 0          -> 0000006f   (check 0's self-jump, offset 0)
//   addi x5, x5, 1      -> 00128293   <- checks 1+'s loop, same as tb_cpu_halt.v's own
//   jal  x0, -4         -> ffdff06f   <- back to the addi
`timescale 1ns / 1ps

module tb_ooo_halt;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire        dmem_we, dmem_re;
    wire [1:0]  dmem_size;
    wire        trap;

    wire        resv_valid;
    wire [31:0] resv_addr;
    wire        store_fire;
    wire [31:0] store_addr;

    reg         dbg_haltreq = 1'b0, dbg_resumereq = 1'b0;
    wire        dbg_halted;
    reg         dbg_reg_valid = 1'b0, dbg_reg_we = 1'b0;
    reg  [15:0] dbg_reg_num = 16'b0;
    reg  [31:0] dbg_reg_wdata = 32'b0;
    wire [31:0] dbg_reg_rdata;
    wire        dbg_reg_err;

    // ---- wait-state injector, copied from sim/tb_ooo_resv_ports.v -------
    // Needed so the one store in check 0's own program actually gets
    // absorbed into the store buffer (head_store_absorbed requires
    // dbus_wait) rather than completing same-cycle, which would never
    // exercise sb_valid at all.
    localparam WAIT_CYCLES = 3;

    reg        xfer_active = 1'b0;
    reg [3:0]  wait_left   = 4'd0;
    wire       req_now     = dmem_we || dmem_re;
    wire       dbus_wait_w = xfer_active ? (wait_left != 0)
                                          : (req_now && (WAIT_CYCLES != 0));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            xfer_active <= 1'b0;
            wait_left   <= 4'd0;
        end else if (!xfer_active) begin
            if (req_now && (WAIT_CYCLES != 0)) begin
                xfer_active <= 1'b1;
                wait_left   <= WAIT_CYCLES[3:0] - 4'd1;
            end
        end else if (wait_left == 0) begin
            xfer_active <= 1'b0;
        end else begin
            wait_left <= wait_left - 4'd1;
        end
    end

    core_ooo CPU (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .itlb_wait_stall(),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_size(dmem_size),
        .dmem_rdata(dmem_rdata), .dmem_rvalid(!dbus_wait_w), .dmem_is_amo(),
        .ibus_wait(1'b0), .dbus_wait(dbus_wait_w),
        .ptw_req(), .ptw_addr(), .ptw_gnt(1'b0), .ptw_rdata(32'b0),
        .iptw_req(), .iptw_addr(), .iptw_gnt(1'b0), .iptw_rdata(32'b0),
        .mtip(1'b0), .msip_in(1'b0), .meip(1'b0), .seip(1'b0),
        .mtime_in(64'b0),
        .fence_i(), .trap(trap),
        .resv_valid(resv_valid), .resv_addr(resv_addr),
        .store_fire(store_fire), .store_addr(store_addr),
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

    integer failures = 0;
    task check(input [1023:0] name, input ok);
        begin
            $write("  %0s", name);
            $write("%0s\n", ok ? " ok" : " FAILED");
            if (!ok) failures = failures + 1;
        end
    endtask

    task check_hex(input [1023:0] name, input [31:0] got, input [31:0] want);
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

    // Same negedge-buffered shape sim/tb_cpu_halt.v already uses, and for
    // the same documented reason (a same-edge race between clearing
    // dbg_resumereq and the always block that samples it).
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

    reg [31:0] v0, v1, v2, sentinel;
    integer n;
    reg sb_race_ok;

    initial begin
        // ==================================================================
        // Check 0: halt requested while a store is still draining must not
        // take effect until the store buffer clears - its own isolated
        // program (see the file header for why the shared loop below
        // cannot be reused for this one).
        // ==================================================================
        IMEM.mem[0] = 32'h04000093;  // addi x1, x0, 64
        IMEM.mem[1] = 32'h0000A023;  // sw   x0, 0(x1)
        IMEM.mem[2] = 32'h0000006F;  // jal  x0, 0     <- self-jump

        repeat (4) @(posedge clk);
        rst = 0;

        n = 0;
        while (!dmem_we && n < 200) begin
            @(posedge clk);
            n = n + 1;
        end
        check("the one store begins its own bus request within a bounded number of cycles",
              dmem_we);
        dbg_haltreq = 1'b1;

        // Wait for the store to actually be absorbed into the one-entry
        // store buffer (head_store_absorbed requires a real dbus_wait, one
        // cycle behind dmem_we first asserting - confirmed by direct trace,
        // not assumed).
        n = 0;
        while (!CPU.sb_valid && n < 200) begin
            @(posedge clk);
            n = n + 1;
        end
        check("store buffer becomes valid within a bounded number of cycles", CPU.sb_valid);

        // Now poll every cycle while it continues draining - not a single
        // check at the instant quiescence-except-sb_valid is first
        // observed, which would pass regardless of the mutation below
        // (dbg_halted_r is registered, so there is always at least a
        // one-cycle lag between a condition becoming true and dbg_halted
        // reflecting it - checking only once, right at that instant, could
        // never distinguish "delayed one more cycle for the usual
        // registered-output reason" from "delayed several more cycles
        // because sb_valid is part of the gate," which is the actual
        // property under test). Continuous polling catches the real
        // multi-cycle window a direct trace already confirmed exists.
        sb_race_ok = 1'b1;
        n = 0;
        while (CPU.sb_valid && n < 200) begin
            if (dbg_halted) sb_race_ok = 1'b0;
            @(posedge clk);
            n = n + 1;
        end
        check("store buffer drains within a bounded number of cycles", !CPU.sb_valid);
        check("dbg_halted never asserted on any cycle the store buffer was still draining",
              sb_race_ok);

        wait_halted;
        dbg_resume;
        wait_resumed;

        // ==================================================================
        // Checks 1+: halt/resume/register-access/single-step, mirroring
        // sim/tb_cpu_halt.v's own sequence exactly, on a fresh reset with
        // the shared 2-instruction increment loop.
        // ==================================================================
        rst = 1;
        dbg_haltreq = 1'b0;
        repeat (4) @(posedge clk);
        IMEM.mem[0] = 32'h00128293;  // addi x5, x5, 1   <- loop
        IMEM.mem[1] = 32'hFFDFF06F;  // jal  x0, -4
        IMEM.mem[2] = 32'h00000000;
        rst = 0;

        // ---- confirm the loop is alive before touching anything debug-related ----
        repeat (30) @(posedge clk);
        check("x5 advances on its own before any halt request",
              CPU.RF.regs[CPU.rat[5]] > 32'd1);

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
        // step always lands on "the other one."
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

        dbg_write(REGNO_DCSR, 32'h0000_0000);
        dbg_read(REGNO_DCSR, v2);
        check("dcsr.step clears on an explicit write back to 0", v2[2] == 1'b0);

        dbg_resume;

        if (failures == 0) $display("\nOOO-HALT-TEST: PASS");
        else                $display("\nOOO-HALT-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #200000;
        $display("\nOOO-HALT-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
