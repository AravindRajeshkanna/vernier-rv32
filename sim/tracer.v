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
module tracer (
    input wire        clk,
    input wire        rst,
    input wire        valid,
    input wire [31:0] pc,
    input wire [31:0] instr,
    input wire        rd_we,
    input wire [4:0]  rd,
    input wire [31:0] rd_data
);
    integer      fd = 0;
    reg [1023:0] path;
    integer      retired = 0;

    initial begin
        if ($value$plusargs("trace=%s", path)) begin
            fd = $fopen(path, "w");
            if (fd == 0) $display("tracer: could not open trace file");
        end
    end

    always @(posedge clk) begin
        if (!rst && valid && fd != 0) begin
            retired = retired + 1;
            // x0 is filtered here rather than in the core: the pipeline
            // happily "writes" x0 for instructions whose result is discarded
            // (rd=x0), the register file drops it, and Spike does not log it.
            if (rd_we && rd != 5'd0)
                $fdisplay(fd, "%08x %08x x%0d %08x", pc, instr, rd, rd_data);
            else
                $fdisplay(fd, "%08x %08x - -", pc, instr);
        end
    end

    // Flush on exit; $finish alone does not guarantee the file is closed.
    final if (fd != 0) begin
        $fdisplay(fd, "# retired %0d instructions", retired);
        $fclose(fd);
    end
endmodule
