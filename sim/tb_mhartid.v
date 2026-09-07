// Directed test for csr_file.v's new HARTID parameter (Phase 13 stage 2,
// docs/roadmap.md) - proves mhartid (CSR 0xF14) actually varies with the
// parameter instead of trusting the one-line diff by inspection. Two
// instances, HARTID=0 (what every real instantiation in this tree builds
// today - cpu_core.v, core_ooo.v, and this test's own DUT0 all default to
// it) and HARTID=3 (an arbitrary distinct value, chosen only to rule out
// "always reads back 0" or "always reads back 1" as an accidental pass),
// read side by side so a wiring mistake that swapped which instance got
// which parameter would show up as a mismatch, not silently cancel out.
//
// Driven directly against csr_file.v's addr/we/wdata port, same convention
// as sim/tb_pmp_csr.v.
`timescale 1ns/1ps
module tb_mhartid;
    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    reg  [11:0] addr = 12'hF14;
    wire [31:0] rdata0, rdata3;

    csr_file #(.HARTID(32'h0)) DUT0 (
        .clk(clk), .rst(rst),
        .addr(addr), .we(1'b0), .wdata(32'b0), .rdata(rdata0), .rdata_rmw(),
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

    csr_file #(.HARTID(32'h3)) DUT3 (
        .clk(clk), .rst(rst),
        .addr(addr), .we(1'b0), .wdata(32'b0), .rdata(rdata3), .rdata_rmw(),
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

    initial begin
        @(posedge clk); @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        check("HARTID=0 instance reads mhartid=0 (today's only real value)", rdata0, 32'h0);
        check("HARTID=3 instance reads mhartid=3, not 0 and not swapped with DUT0", rdata3, 32'h3);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("MHARTID-TEST: PASS");
        else             $display("MHARTID-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the mhartid test never completed");
        $finish;
    end
endmodule
