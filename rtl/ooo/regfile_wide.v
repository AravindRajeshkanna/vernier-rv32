// 32 x 32-bit RISC-V register file with four read ports and two write ports.
//
// The register file a two-wide machine needs: two instructions issued in the
// same cycle read up to four source registers and retire up to two results.
// rtl/regfile.v (2R/1W) is unchanged and still serves the in-order core.
//
// ---- The two things that are not just "more ports" ----
//
// **Same-cycle bypass, from both write ports.** rtl/regfile.v's header
// explains why the bypass exists at all: it closes a forwarding gap for a
// producer exactly three instructions ahead of its consumer, which neither
// EX/MEM nor MEM/WB forwarding covers and which a plain synchronous-write
// array does not resolve until a cycle too late. With two write ports every
// read has to consider both, so each read port is a two-deep priority mux
// rather than a single comparison.
//
// **Write port priority.** Two writes to the same architectural register in
// one cycle is not a hazard to be avoided by the issue logic - it is a case
// that has to have a defined answer, because a dual-issue pair may legally
// contain two instructions with the same rd (`addi a0,..` ; `addi a0,..`).
// Port 1 is the younger instruction and wins, both in the array and in the
// bypass. An issue rule that forbade the pair instead would silently lose
// throughput on a common idiom, and a file that let the older one win would
// be wrong rather than slow.
//
// x0 stays hardwired to zero on every port, in both the array write and the
// bypass - the failure mode rtl/regfile.v's formal properties exist to catch,
// and which doubling the ports doubles the opportunities for.
module regfile_wide (
    input  wire        clk,

    // Read ports: 0/1 are slot A's operands, 2/3 are slot B's.
    input  wire [4:0]  rs1_a,
    input  wire [4:0]  rs2_a,
    input  wire [4:0]  rs1_b,
    input  wire [4:0]  rs2_b,
    output wire [31:0] rdata1_a,
    output wire [31:0] rdata2_a,
    output wire [31:0] rdata1_b,
    output wire [31:0] rdata2_b,

    // Write ports. Port 1 is the younger instruction and takes priority.
    input  wire        we0,
    input  wire [4:0]  rd0,
    input  wire [31:0] wdata0,
    input  wire        we1,
    input  wire [4:0]  rd1,
    input  wire [31:0] wdata1
);
    reg [31:0] regs [0:31];
    integer i;

    initial begin
        for (i = 0; i < 32; i = i + 1)
            regs[i] = 32'b0;
    end

    // A write is only real if it is enabled and not to x0.
    wire w0 = we0 && (rd0 != 5'd0);
    wire w1 = we1 && (rd1 != 5'd0);

    // One read port: x0 first, then the younger write, then the older, then
    // the array. The order of the two bypass terms is the write priority.
    //
    // Written out per port rather than as a `rd_port(a)` function, and that
    // is a correctness requirement rather than a style preference. A function
    // called from a continuous assignment is only guaranteed to re-evaluate
    // when its *arguments* change; the signals it reads out of the enclosing
    // module - here `regs`, `w0/w1`, `rd0/rd1`, `wdata0/wdata1` - need not be
    // in the assignment's sensitivity list at all. The function version
    // simulated as a register file whose outputs only moved when a read
    // address changed, which is wrong every time a write lands under a
    // steady address.
    //
    // The formal proofs in formal/fv_regfile_wide.v passed against the
    // function version, and would pass against it again: yosys elaborates the
    // function into the combinational logic that was meant, so the property
    // being proved was about a netlist the simulator never built. Two
    // different tools disagreeing about the same source is exactly the gap
    // co-simulation exists to sit in - it found this, on the SoC, as a CSR
    // write that the very next trap could not see.
    wire byp1a_1 = w1 && (rd1 == rs1_a);
    wire byp1a_0 = w0 && (rd0 == rs1_a);
    wire byp2a_1 = w1 && (rd1 == rs2_a);
    wire byp2a_0 = w0 && (rd0 == rs2_a);
    wire byp1b_1 = w1 && (rd1 == rs1_b);
    wire byp1b_0 = w0 && (rd0 == rs1_b);
    wire byp2b_1 = w1 && (rd1 == rs2_b);
    wire byp2b_0 = w0 && (rd0 == rs2_b);

    assign rdata1_a = (rs1_a == 5'd0) ? 32'b0 :
                      byp1a_1 ? wdata1 : byp1a_0 ? wdata0 : regs[rs1_a];
    assign rdata2_a = (rs2_a == 5'd0) ? 32'b0 :
                      byp2a_1 ? wdata1 : byp2a_0 ? wdata0 : regs[rs2_a];
    assign rdata1_b = (rs1_b == 5'd0) ? 32'b0 :
                      byp1b_1 ? wdata1 : byp1b_0 ? wdata0 : regs[rs1_b];
    assign rdata2_b = (rs2_b == 5'd0) ? 32'b0 :
                      byp2b_1 ? wdata1 : byp2b_0 ? wdata0 : regs[rs2_b];

    // Same priority in the array: apply the older write first so the younger
    // one overwrites it when both target the same register.
    always @(posedge clk) begin
        if (w0) regs[rd0] <= wdata0;
        if (w1) regs[rd1] <= wdata1;
    end
endmodule
