// Directed test for rtl/cpu_core.v's Phase 13 reservation-exposure ports
// (resv_valid, resv_addr, store_fire, store_addr, resv_invalidate_ext) -
// the ports stage 7 added so rtl/soc/reservation_monitor.v (stage 6) will
// eventually have a real core to connect to. No monitor and no second hart
// exist yet; this test drives resv_invalidate_ext directly, the same way a
// future reservation_monitor.v instance would, and checks the one thing
// that actually matters: does asserting it from *outside* cpu_core.v really
// clear an in-flight LR/SC reservation and make the next SC fail, not just
// that the port exists and compiles.
//
// The DUT runs a real hand-assembled program (encodings verified against
// riscv64-unknown-elf-as, not hand-trusted) that attempts the same LR/SC
// pair on the same address twice:
//   attempt 1: reservation left alone -> SC must succeed (rd=0)
//   attempt 2: resv_invalidate_ext pulsed while the reservation is held,
//              before the SC executes -> SC must fail (rd=1)
// Success/failure is read back from the real architectural register file
// (CPU.RF.regs[]), not inferred from timing, and store_fire/store_addr are
// checked directly against the one real memory write attempt 1 makes -
// attempt 2's SC must produce no write at all, since a failed SC does not
// touch memory (rtl/cpu_core.v's own amo_writes = ex_mem_is_amo_rmw ||
// sc_success).
`timescale 1ns / 1ps

module tb_cpu_resv_ports;
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
        .resv_valid(resv_valid), .resv_addr(resv_addr),
        .store_fire(store_fire), .store_addr(store_addr),
        .resv_invalidate_ext(resv_invalidate_ext),
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

    localparam [31:0] RESV_ADDR = 32'h40;

    initial begin
        // x1 = 0x40 (target address)
        IMEM.mem[0]  = 32'h04000093;  // addi x1, x0, 64
        // attempt 1: no external invalidation -> SC must succeed
        IMEM.mem[1]  = 32'h00A00313;  // addi x6, x0, 10   (store data)
        IMEM.mem[2]  = 32'h1000A12F;  // lr.w  x2, (x1)
        IMEM.mem[3]  = 32'h01400213;  // addi x4, x0, 20   (delay counter)
        IMEM.mem[4]  = 32'hFFF20213;  // addi x4, x4, -1   <- loop target
        IMEM.mem[5]  = 32'hFE021EE3;  // bne  x4, x0, -4
        IMEM.mem[6]  = 32'h1860A2AF;  // sc.w  x5, x6, (x1) -> x5 = 0 expected
        // attempt 2: resv_invalidate_ext pulsed mid-window -> SC must fail
        IMEM.mem[7]  = 32'h00B00313;  // addi x6, x0, 11   (store data)
        IMEM.mem[8]  = 32'h1000A12F;  // lr.w  x2, (x1)
        IMEM.mem[9]  = 32'h01400213;  // addi x4, x0, 20   (delay counter)
        IMEM.mem[10] = 32'hFFF20213;  // addi x4, x4, -1   <- loop target
        IMEM.mem[11] = 32'hFE021EE3;  // bne  x4, x0, -4
        IMEM.mem[12] = 32'h1860A3AF;  // sc.w  x7, x6, (x1) -> x7 = 1 expected
        IMEM.mem[13] = 32'h0000006F;  // jal   x0, 0       (self-loop, halt)
    end

    integer failures = 0;
    task check(input [1023:0] name, input ok);
        begin
            $write("  %0s", name);
            $write("%0s\n", ok ? " ok" : " FAILED");
            if (!ok) failures = failures + 1;
        end
    endtask

    // one pulse of store_fire is expected for attempt 1's successful SC;
    // none at all for attempt 2's failed one.
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
        check("attempt 1's SC reports success (rd=0)", CPU.RF.regs[5] == 32'd0);

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

        // let attempt 2's SC actually execute
        repeat (100) @(posedge clk);
        check("no store_fire pulse from attempt 2's failed SC (still just one total)",
              store_fire_count == 1);
        check("attempt 2's SC reports failure (rd=1) after external invalidation",
              CPU.RF.regs[7] == 32'd1);

        if (failures == 0) $display("\nCPU-RESV-PORTS-TEST: PASS");
        else                $display("\nCPU-RESV-PORTS-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #200000;
        $display("\nCPU-RESV-PORTS-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
