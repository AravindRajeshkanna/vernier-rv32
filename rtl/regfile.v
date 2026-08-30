// 32 x 32-bit RISC-V register file. x0 is hardwired to zero.
//
// Includes an explicit same-cycle write-to-read bypass (`we && rd==rsN`):
// without it, a producer exactly 3 instructions ahead of its consumer
// falls into a gap neither EX/MEM nor MEM/WB forwarding covers (those
// handle 1 and 2 instructions ahead) and that's one cycle too soon for
// the synchronous-write/combinational-read array by itself (that only
// resolves a producer for free once it's >=4 instructions ahead - the
// write's non-blocking assignment takes effect at the edge *ending* the
// producer's WB cycle, so a plain array read doesn't see it until the
// cycle after). This bypass is what actually closes that gap.
module regfile (
    input  wire        clk,
    input  wire        we,
    input  wire [4:0]  rs1,
    input  wire [4:0]  rs2,
    input  wire [4:0]  rd,
    input  wire [31:0] wdata,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2,
    // Debug read port (rtl/debug/dm.v, via cpu_core.v's dbg_reg_* mux).
    // Combinational, unbypassed: unlike rdata1/rdata2, it is only ever
    // meaningful while the core is genuinely halted (cpu_core.v gates
    // dbg_reg_valid on that), so there is nothing in flight for it to race
    // and no same-cycle write to bypass around.
    input  wire [4:0]  dbg_rs,
    output wire [31:0] dbg_rdata
);
    reg [31:0] regs [0:31];
    integer i;

    initial begin
        for (i = 0; i < 32; i = i + 1)
            regs[i] = 32'b0;
    end

    wire bypass1 = we && (rd != 5'd0) && (rd == rs1);
    wire bypass2 = we && (rd != 5'd0) && (rd == rs2);

    assign rdata1 = (rs1 == 5'd0) ? 32'b0 : (bypass1 ? wdata : regs[rs1]);
    assign rdata2 = (rs2 == 5'd0) ? 32'b0 : (bypass2 ? wdata : regs[rs2]);
    assign dbg_rdata = (dbg_rs == 5'd0) ? 32'b0 : regs[dbg_rs];

    always @(posedge clk) begin
        if (we && rd != 5'd0)
            regs[rd] <= wdata;
    end
endmodule
