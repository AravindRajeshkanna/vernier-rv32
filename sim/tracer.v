`timescale 1ns/1ps
// Retired-instruction tracer. Simulation only.
//
// Watches the core's retire trace (cpu_core.v's trace_* registers, hooked up
// by the testbench with hierarchical references) and writes one line per
// retired instruction:
//
//   <pc> <instruction> <rd> <write-data>
//
// with `-` in the last two columns for an instruction that writes no
// register. That is deliberately the same information Spike's
// `--log-commits` reports, so tests/cosim.py can diff the two directly
// without either side needing to understand the other's disassembly.
//
// The file is only opened if the testbench was given +trace=<path>, so the
// normal test runs pay nothing for this existing.
//
// Why this lives in sim/ and not rtl/: it is a $fdisplay-based observer, not
// a trace buffer that could ever exist on an FPGA. Real on-chip tracing
// (compressed branch trace out a pin) is a different piece of hardware, and
// pretending this is that would overstate what the project has.
// ---- two slots ----
//
// A dual-issue core retires two instructions in one cycle, and the trace has
// to contain both, in program order, or co-simulation silently stops checking
// half the machine. Slot 0 is the older instruction and its line is written
// first. Cores that issue one at a time tie slot 1's `valid1` low and the
// second half of this module never fires - which is how the in-order core is
// wired (see sim/tb_isa.v).
//
// Both lines come out of one `always` block on purpose: two `tracer`
// instances writing the same file would interleave in whatever order the
// simulator happened to schedule them, and a trace that is out of order
// against Spike is indistinguishable from a core that is.
module tracer (
    input wire        clk,
    input wire        rst,
    input wire        valid,
    input wire [31:0] pc,
    input wire [31:0] instr,
    input wire        rd_we,
    input wire [4:0]  rd,
    input wire [31:0] rd_data,

    input wire        valid1,
    input wire [31:0] pc1,
    input wire [31:0] instr1,
    input wire        rd_we1,
    input wire [4:0]  rd1,
    input wire [31:0] rd_data1
);
    integer      fd = 0;
    reg [1023:0] path;
    integer      retired = 0;
    // Counted separately, and reported in the trailer, because a trace that
    // matches Spike says nothing about *how much of the machine* produced it.
    // Across the whole riscv-tests corpus the wide core retires 63
    // instructions here out of 28,262 - so "82/82 traces match" was a
    // statement about a core running almost entirely in single issue.
    // tests/cosim.py reads this number and holds a floor on it.
    integer      retired1 = 0;

    initial begin
        if ($value$plusargs("trace=%s", path)) begin
            fd = $fopen(path, "w");
            if (fd == 0) $display("tracer: could not open trace file");
        end
    end

    always @(posedge clk) begin
        if (!rst && fd != 0) begin
            if (valid) begin
                retired = retired + 1;
                // x0 is filtered here rather than in the core: the pipeline
                // happily "writes" x0 for instructions whose result is discarded
                // (rd=x0), the register file drops it, and Spike does not log it.
                if (rd_we && rd != 5'd0)
                    $fdisplay(fd, "%08x %08x x%0d %08x", pc, instr, rd, rd_data);
                else
                    $fdisplay(fd, "%08x %08x - -", pc, instr);
            end
            if (valid1) begin
                retired = retired + 1;
                retired1 = retired1 + 1;
                if (rd_we1 && rd1 != 5'd0)
                    $fdisplay(fd, "%08x %08x x%0d %08x", pc1, instr1, rd1, rd_data1);
                else
                    $fdisplay(fd, "%08x %08x - -", pc1, instr1);
            end
        end
    end

    // Flush on exit; $finish alone does not guarantee the file is closed.
    final if (fd != 0) begin
        $fdisplay(fd, "# retired %0d instructions (slot1 %0d)",
                  retired, retired1);
        $fclose(fd);
    end
endmodule
