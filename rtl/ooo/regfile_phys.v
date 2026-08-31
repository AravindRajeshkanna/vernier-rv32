// Physical register file for stage 1d's renamed backend: 64 physical
// registers (indices 0-63), 2 read ports (dispatch reads one instruction's
// two sources) and 3 write ports (one per completion source: the
// serializing/in-order execute path, the out-of-order ALU, and the
// out-of-order load port).
//
// This is not rtl/ooo/regfile_wide.v with more rows. regfile_wide holds
// *architectural* state directly and is addressed by architectural register
// number; this file holds *physical* register state; the mapping from
// architectural to physical lives in the RAT in rtl/ooo/core_ooo.v.
// Physical register 0 is reserved for x0 and is permanently zero - the RAT
// never maps an architectural register onto it and dispatch never requests a
// fresh physical register for a write to x0, so the hardwired-zero read
// below is belt-and-braces against a renaming bug rather than something the
// steady state depends on.
//
// Same-cycle write-to-read bypass is *not* done here, unlike
// regfile_wide.v/regfile.v - deliberately, and not an oversight. It used to
// be: each read port was a three-deep priority mux over the three write
// ports, wired the same way. But `rdata1_a`/`rdata2_a` have exactly one
// caller in this codebase - `dispatch_r1_val`/`dispatch_r2_val` in
// core_ooo.v - and that caller already performs the identical bypass
// itself, one level up, against the same three CDBs, before ever reading
// these ports: it only falls through to `rdata1_a`/`rdata2_a` once it has
// already established that none of cdbS/cdbB/cdbL currently match the
// register being read. At that point this module re-running the exact same
// comparison could never produce a different answer - not "usually
// correct", structurally incapable of differing, since the two checks
// share their inputs. That redundant copy was also part of a combinational
// loop `nextpnr` could not analyze (docs/roadmap.md's "CORE=ooo has no
// Fmax" entry, round 4): `wdata1`/`wdata2` here are `cdbB_val`/`cdbL_val`
// directly, and removing the arms that read them here is what a real
// synthesis run confirmed actually changes the netlist's cycle structure.
//
// This is a property of *this module having exactly one caller that
// already does its own bypass*, not a general fact about physical register
// files. A second caller that reads `rdata1_a`/`rdata2_a` without doing
// the same same-cycle check itself would see a real hazard - a plain
// synchronous array returns the pre-write value one cycle late - and the
// bypass documented above would need to come back, at least for that
// caller.
module regfile_phys #(
    parameter PREGS = 64,
    parameter PW    = 6      // clog2(PREGS)
)(
    input  wire        clk,

    input  wire [PW-1:0] rs1_a,
    input  wire [PW-1:0] rs2_a,
    output wire [31:0]   rdata1_a,
    output wire [31:0]   rdata2_a,

    // Write port 0: the serializing (Class S) execute path - branches'
    // link register, CSR old-value, MUL/DIV result, AMO/LR result.
    input  wire          we0,
    input  wire [PW-1:0] rd0,
    input  wire [31:0]   wdata0,
    // Write port 1: the out-of-order ALU (Class B).
    input  wire          we1,
    input  wire [PW-1:0] rd1,
    input  wire [31:0]   wdata1,
    // Write port 2: the out-of-order load port (Class B2).
    input  wire          we2,
    input  wire [PW-1:0] rd2,
    input  wire [31:0]   wdata2
);
    reg [31:0] regs [0:PREGS-1];
    integer i;

    initial begin
        for (i = 0; i < PREGS; i = i + 1)
            regs[i] = 32'b0;
    end

    wire w0 = we0 && (rd0 != {PW{1'b0}});
    wire w1 = we1 && (rd1 != {PW{1'b0}});
    wire w2 = we2 && (rd2 != {PW{1'b0}});

    assign rdata1_a = (rs1_a == {PW{1'b0}}) ? 32'b0 : regs[rs1_a];
    assign rdata2_a = (rs2_a == {PW{1'b0}}) ? 32'b0 : regs[rs2_a];

    always @(posedge clk) begin
        if (w0) regs[rd0] <= wdata0;
        if (w1) regs[rd1] <= wdata1;
        if (w2) regs[rd2] <= wdata2;
    end
endmodule
