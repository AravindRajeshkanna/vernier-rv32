// Directed test for rtl/ooo/core_ooo.v's Phase 13 reservation-exposure
// ports (resv_valid, resv_addr, store_fire, store_addr,
// resv_invalidate_ext) - the OOO analog of sim/tb_cpu_resv_ports.v's own
// proof for rtl/cpu_core.v. Same two checks that test already makes
// (external invalidation clears an in-flight reservation and makes the
// next SC fail; store_fire/store_addr track this hart's own real write),
// plus a third, genuinely OOO-specific one neither cpu_core.v nor the
// original test needs: rtl/ooo/core_ooo.v retires a plain store into a
// one-entry store buffer before its write actually reaches the bus, so by
// the time that buffered write lands, `rob_head` has already advanced to a
// different, younger instruction - `store_addr` must still report the
// buffered write's OWN address (the store buffer's own `sb_addr`), not
// whatever address the ROB head happens to be sitting on by then.
//
// sim/tb_cpu_resv_ports.v's own zero-latency memory model (dmem_rvalid
// tied to 1, dbus_wait tied to 0) cannot exercise this at all: a plain
// store is only ever absorbed into the store buffer when its own write has
// to wait (`head_store_absorbed` requires `dbus_wait`), so this test
// injects a real, small, fixed number of wait states on every dmem access
// instead - the same role wb_ram.v/wb_sdram.v play for the real SoC, just
// small and self-contained for "prove the hard piece in isolation"
// (matching sim/tb_reservation_monitor.v's own precedent).
//
// The DUT runs a real hand-assembled program (encodings verified against
// riscv64-unknown-elf-as/objdump, not hand-derived) doing three things in
// sequence:
//   1. LR.W/SC.W on RESV_ADDR, no interference -> SC succeeds (rd=0)
//   2. LR.W/SC.W on RESV_ADDR again, resv_invalidate_ext pulsed mid-window
//      -> SC fails (rd=1)
//   3. a plain SW to a DIFFERENT address (OTHER_ADDR), followed by three
//      filler ALU instructions so rob_head genuinely advances past the
//      store while its buffered write is still draining - store_fire must
//      pulse exactly once more, with store_addr == OTHER_ADDR, not
//      RESV_ADDR and not whatever the ROB head's own address is by the
//      time the pulse actually happens.
// Results are read back from the real architectural register file via the
// RAT (regfile_phys has no architectural index of its own - core_ooo.v's
// own `rat[]` says which physical register each x-register currently maps
// to), the same pattern sim/tb_ooo_csr_hazard.v already uses.
`timescale 1ns / 1ps

module tb_ooo_resv_ports;
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
    reg         resv_invalidate_ext = 1'b0;

    // ---- A small, fixed wait-state injector -----------------------------
    // core_ooo.v holds dmem_we/dmem_re/dmem_addr/dmem_wdata steady across a
    // stall (rtl/soc/cpu_wb.v's own header comment: "requests are issued
    // combinationally... against a zero-wait-state slave a transfer
    // completes in the cycle it starts" - the core relies on that same
    // contract regardless of who is on the other end). WAIT_CYCLES extra
    // cycles of dbus_wait follow every dmem_we/dmem_re assertion before the
    // transaction is allowed to complete; the underlying dmem.v model
    // itself stays zero-latency underneath (a write is idempotent if
    // re-presented identically across the extra wait cycles, a read's
    // combinational data is simply not looked at until the ack cycle).
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
        .resv_invalidate_ext(resv_invalidate_ext),
        // This test is about the reservation ports only - hart control is
        // sim/tb_ooo_halt.v's own job. Tied off explicitly, not omitted,
        // for the same X-poisoning reason every other tie-off in this tree
        // is (an omitted input floats/reads as X in Icarus/Verilator).
        .dbg_haltreq(1'b0), .dbg_resumereq(1'b0), .dbg_halted(),
        .dbg_reg_valid(1'b0), .dbg_reg_we(1'b0),
        .dbg_reg_num(16'b0), .dbg_reg_wdata(32'b0),
        .dbg_reg_rdata(), .dbg_reg_err()
    );

    imem #(.MEM_WORDS(64)) IMEM (.addr(imem_addr), .rdata(imem_rdata));
    dmem #(.MEM_BYTES(256)) DMEM (
        .clk(clk), .addr(dmem_addr), .wdata(dmem_wdata),
        .we(dmem_we), .size(dmem_size), .rdata(dmem_rdata),
        .req2(1'b0), .addr2(32'b0), .gnt2(), .rdata2(),
        .req3(1'b0), .addr3(32'b0), .gnt3(), .rdata3()
    );

    localparam [31:0] RESV_ADDR  = 32'h40;
    localparam [31:0] OTHER_ADDR = 32'h80;

    // addi x1,x0,64 / addi x9,x0,128 / attempt 1 / attempt 2 / check 3 /
    // halt - encodings verified against riscv64-unknown-elf-as/objdump,
    // not hand-derived.
    initial begin
        IMEM.mem[0]  = 32'h04000093;  // addi x1, x0, 64     (RESV_ADDR)
        IMEM.mem[1]  = 32'h08000493;  // addi x9, x0, 128    (OTHER_ADDR)
        // attempt 1: no external invalidation -> SC must succeed
        IMEM.mem[2]  = 32'h00a00313;  // addi x6, x0, 10     (store data)
        IMEM.mem[3]  = 32'h1000a12f;  // lr.w  x2, (x1)
        IMEM.mem[4]  = 32'h01400213;  // addi x4, x0, 20     (delay counter)
        IMEM.mem[5]  = 32'hfff20213;  // addi x4, x4, -1     <- delay1
        IMEM.mem[6]  = 32'hfe021ee3;  // bne  x4, x0, -4
        IMEM.mem[7]  = 32'h1860a2af;  // sc.w  x5, x6, (x1)  -> x5 = 0 expected
        // attempt 2: resv_invalidate_ext pulsed mid-window -> SC must fail
        IMEM.mem[8]  = 32'h00b00313;  // addi x6, x0, 11
        IMEM.mem[9]  = 32'h1000a12f;  // lr.w  x2, (x1)
        IMEM.mem[10] = 32'h01400213;  // addi x4, x0, 20
        IMEM.mem[11] = 32'hfff20213;  // addi x4, x4, -1     <- delay2
        IMEM.mem[12] = 32'hfe021ee3;  // bne  x4, x0, -4
        IMEM.mem[13] = 32'h1860a3af;  // sc.w  x7, x6, (x1)  -> x7 = 1 expected
        // check 3: a plain store to a DIFFERENT address, then filler ALU
        // instructions so rob_head advances past it before its buffered
        // write drains
        IMEM.mem[14] = 32'h06300313;  // addi x6, x0, 99
        IMEM.mem[15] = 32'h0064a023;  // sw   x6, 0(x9)
        IMEM.mem[16] = 32'h00100513;  // addi x10, x0, 1
        IMEM.mem[17] = 32'h00200593;  // addi x11, x0, 2
        IMEM.mem[18] = 32'h00300613;  // addi x12, x0, 3
        IMEM.mem[19] = 32'h0000006f;  // jal   x0, 0         <- halt (self-loop)
    end

    integer failures = 0;
    task check(input [1023:0] name, input ok);
        begin
            $write("  %0s", name);
            $write("%0s\n", ok ? " ok" : " FAILED");
            if (!ok) failures = failures + 1;
        end
    endtask

    integer store_fire_count = 0;
    reg [31:0] last_store_addr = 32'b0;
    always @(posedge clk) begin
        if (store_fire) begin
            store_fire_count = store_fire_count + 1;
            last_store_addr = store_addr;
        end
    end

    task wait_resv_valid_high;
        integer n;
        begin
            n = 0;
            while (!resv_valid && n < 500) begin
                @(posedge clk);
                n = n + 1;
            end
            check("reservation becomes valid within a bounded number of cycles", resv_valid);
        end
    endtask

    task wait_resv_valid_low;
        integer n;
        begin
            n = 0;
            while (resv_valid && n < 500) begin
                @(posedge clk);
                n = n + 1;
            end
            check("reservation clears within a bounded number of cycles", !resv_valid);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;

        // ---- attempt 1: reservation set, left alone, SC succeeds ----
        wait_resv_valid_high;
        check("resv_addr reports the reserved address", resv_addr == RESV_ADDR);

        wait_resv_valid_low;  // the successful SC clears it locally
        check("exactly one store_fire pulse after attempt 1's successful SC",
              store_fire_count == 1);
        check("store_addr matched the reserved address on that pulse",
              last_store_addr == RESV_ADDR);
        check("attempt 1's SC reports success (rd=0)",
              CPU.RF.regs[CPU.rat[5]] == 32'd0);

        // ---- attempt 2: reservation set again, invalidated externally
        // before the SC executes, SC must fail ----
        wait_resv_valid_high;
        check("resv_addr reports the reserved address again", resv_addr == RESV_ADDR);

        @(negedge clk);
        resv_invalidate_ext = 1'b1;
        @(posedge clk);
        @(negedge clk);
        resv_invalidate_ext = 1'b0;
        check("resv_valid deasserts on the cycle after resv_invalidate_ext pulses",
              !resv_valid);

        // Nothing blocks the program between attempt 2's SC and check 3's
        // own store (unlike sim/tb_soc_2hart_lrsc.v's cross-hart handshake,
        // there is only one hart here to synchronize with) - by the time
        // any fixed cycle budget generous enough for attempt 2's SC to
        // retire has elapsed, check 3's SW has very likely already retired
        // too. So there is no reliable intermediate point to check "still
        // just one total" at; both of attempt 2's own claims (no spurious
        // write, correct failure result) are instead checked against the
        // final, settled state below, alongside check 3's own.
        repeat (200) @(posedge clk);
        check("attempt 2's SC reports failure (rd=1) after external invalidation",
              CPU.RF.regs[CPU.rat[7]] == 32'd1);

        // ---- check 3: the buffered-store address case ----
        // Exactly two store_fire pulses total across the whole program:
        // attempt 1's successful SC, and check 3's plain store - attempt
        // 2's failed SC must not have contributed a third.
        check("exactly two store_fire pulses total (attempt 1 + check 3, none from attempt 2)",
              store_fire_count == 2);
        check("the second pulse's store_addr is the store's own address, not the reservation's",
              last_store_addr == OTHER_ADDR);

        if (failures == 0) $display("\nOOO-RESV-PORTS-TEST: PASS");
        else                $display("\nOOO-RESV-PORTS-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #200000;
        $display("\nOOO-RESV-PORTS-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
