// Directed test for csr_file.v's pmpcfg0-3/pmpaddr0-15 WARL/lock semantics -
// specifically the one behavior riscv-tests' own rv32mi-p-pmpaddr does not
// touch at all (it only exercises NAPOT mode on entry 0): the "TOR-couples-
// previous-pmpaddr" lock rule, where locking entry i as TOR also freezes
// entry i-1's pmpaddr, because that's the register TOR uses as its own
// range's bottom boundary.
//
// rv32mi-p-pmpaddr (make isa, tests/riscv-tests/isa/rv32mi/pmpaddr.S) and
// tests/cosim.py already cover ordinary lock persistence, the read-modify-
// write path (CSRS/CSRC), and NAPOT's grain-detection trick against a real
// reference model (Spike) - trace for trace, not just a local assertion.
// This file exists for the one corner nothing else reaches.
//
// Driven directly against csr_file.v's addr/we/wdata port, bypassing
// cpu_core.v's decode entirely - matching this module's own documented
// contract ("this module just stores and serves whatever address it's
// given"), the same way formal/fv_regfile.v drives regfile.v directly.
`timescale 1ns/1ps
module tb_pmp_csr;
    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    reg  [11:0] addr = 12'b0;
    reg         we = 1'b0;
    reg  [31:0] wdata = 32'b0;
    wire [31:0] rdata;

    csr_file CSR (
        .clk(clk), .rst(rst),
        .addr(addr), .we(we), .wdata(wdata), .rdata(rdata), .rdata_rmw(),
        .trap_en(1'b0), .trap_pc(32'b0), .trap_cause(32'b0), .trap_val(32'b0),
        .mtvec_out(), .stvec_out(), .trap_to_s_out(),
        .mret_en(1'b0), .mepc_out(), .sret_en(1'b0), .sepc_out(),
        .mtip(1'b0), .msip_in(1'b0), .meip_in(1'b0), .seip_in(1'b0),
        .mie_out(), .mip_out(), .mideleg_out(),
        .mstatus_mie_out(), .sstatus_sie_out(), .current_priv_out(),
        .mtime_in(64'b0), .instret_inc(2'b0),
        .mcounteren_out(), .scounteren_out(),
        .satp_mode_out(), .satp_ppn_out(),
        .mstatus_mprv_out(), .mstatus_mpp_out(),
        .mstatus_sum_out(), .mstatus_mxr_out(),
        .mstatus_tvm_out(), .mstatus_tw_out(), .mstatus_tsr_out()
    );

    integer errors = 0;

    task check(input [599:0] name, input [31:0] got, input [31:0] expected);
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: got %08h expected %08h", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: %08h", name, got);
            end
        end
    endtask

    // `#1` before driving new stimulus, not just after reading results: the
    // DUT's own clocked always block reacts to the identical posedge this
    // task's first wait unblocks on, so setting addr/wdata/we in direct,
    // undelayed response to that edge races the DUT's evaluation of it -
    // which process runs first, for two separate processes triggered by the
    // same event, is simulator-defined (the general Verilog race, not
    // specific to this file - see rtl/pmp.v and this project's ISA-TIMEOUT
    // writeup). Confirmed as the actual bug here, not a precaution: without
    // the first #1, a write's wdata could land tagged with the *previous*
    // write's address.
    task wr(input [11:0] a, input [31:0] d);
        begin
            @(posedge clk); #1;
            addr = a; wdata = d; we = 1'b1;
            @(posedge clk); #1;
            we = 1'b0;
        end
    endtask

    task rd(input [11:0] a);
        begin
            addr = a;
            #1;
        end
    endtask

    initial begin
        // Two edges held in reset, then deassert, then a settled edge before
        // any use - matching sim/tb_tmds_encode.v's established pattern.
        // Deasserting on the same edge that first samples rst=1 races the
        // DUT's own async-reset block for that edge (which process runs
        // first, for two separate processes triggered by the same event, is
        // simulator-defined) - found by hitting it, not by caution: an
        // earlier version of this file did exactly that and left every new
        // register permanently X.
        @(posedge clk); @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        // pmpaddr4/pmpaddr5 start unlocked: both writable.
        wr(12'h3B4, 32'h1000_0000);
        rd(12'h3B4); check("pmpaddr4 writable before any lock", rdata, 32'h1000_0000);
        wr(12'h3B5, 32'h2000_0000);
        rd(12'h3B5); check("pmpaddr5 writable before any lock", rdata, 32'h2000_0000);

        // Lock entry 5 (pmpcfg1 byte 1, global index 4*1+1=5) as TOR, R/W/X=0.
        // pmpcfg1 covers entries 4-7: byte0=entry4, byte1=entry5, ... - the
        // concatenation below is {byte3, byte2, byte1, byte0}, MSB-first.
        wr(12'h3A1, {8'b0, 8'b0, {1'b1, 2'b00, 2'b01, 3'b000}, 8'b0}); // byte1 = L=1,A=TOR
        rd(12'h3A1); check("entry5 cfg landed locked+TOR",
              rdata & 32'h0000_FF00, 32'h0000_8800);

        // Entry 5's own pmpaddr is now directly locked: write must be a no-op.
        wr(12'h3B5, 32'h3333_3333);
        rd(12'h3B5); check("pmpaddr5 write ignored (directly locked)", rdata, 32'h2000_0000);

        // Entry 4's pmpaddr feeds entry5's TOR base and must also freeze,
        // even though entry 4's own cfg byte (byte0 of pmpcfg1) is still 0
        // (OFF, unlocked) - the couples-previous rule is about entry 5's
        // mode, not entry 4's own lock bit.
        wr(12'h3B4, 32'h4444_4444);
        rd(12'h3B4); check("pmpaddr4 write ignored (feeds a locked TOR entry)", rdata, 32'h1000_0000);

        // An unrelated, unlocked entry (6) is unaffected by either lock.
        wr(12'h3B6, 32'h5555_5555);
        rd(12'h3B6); check("pmpaddr6 unaffected by entry4/5's locks", rdata, 32'h5555_5555);

        // Entry 5's whole cfg byte is frozen, not just L: try to clear L
        // and switch to NAPOT with full permissions - must not take.
        wr(12'h3A1, {8'b0, 8'b0, {1'b0, 2'b00, 2'b11, 3'b111}, 8'b0});
        rd(12'h3A1); check("entry5 cfg byte frozen entirely, not just L",
              rdata & 32'h0000_FF00, 32'h0000_8800);

        // WPRI bits [6:5] of every pmpcfg byte always read back zero,
        // locked or not - checked on an unlocked entry (7, byte3 of
        // pmpcfg1) so this is isolated from the lock behavior above.
        wr(12'h3A1, {{1'b0, 2'b11, 2'b00, 3'b101}, 24'b0}); // byte3: WPRI bits set in the write
        rd(12'h3A1); check("WPRI bits[6:5] forced to zero on readback",
              rdata & 32'hFF00_0000, 32'h0500_0000);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("PMP-CSR-TEST: PASS");
        else             $display("PMP-CSR-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the PMP CSR test never completed");
        $finish;
    end
endmodule
