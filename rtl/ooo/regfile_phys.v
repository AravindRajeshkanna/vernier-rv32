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
// Same same-cycle-bypass reasoning as regfile_wide.v: a completion and a
// dispatch reading the register it just produced can land in the same
// cycle (the CDB broadcasts to the reservation stations and to this file's
// write ports simultaneously), and a plain synchronous array would return
// the pre-write value one cycle late. Three write sources can be live at
// once, so each read port is a three-deep priority mux over the write
// ports, oldest-issuing-first - there is no meaningful "younger/older"
// relationship between three independent completion sources the way there
// is between regfile_wide's two write ports (a dual-issued pair), so the
// priority order here is arbitrary but fixed, and no two of these ports can
// legally target the same physical register in the same cycle (each
// physical register has exactly one producer, assigned at rename time).
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

    assign rdata1_a = (rs1_a == {PW{1'b0}}) ? 32'b0 :
                      (w0 && (rd0 == rs1_a)) ? wdata0 :
                      (w1 && (rd1 == rs1_a)) ? wdata1 :
                      (w2 && (rd2 == rs1_a)) ? wdata2 :
                      regs[rs1_a];
    assign rdata2_a = (rs2_a == {PW{1'b0}}) ? 32'b0 :
                      (w0 && (rd0 == rs2_a)) ? wdata0 :
                      (w1 && (rd1 == rs2_a)) ? wdata1 :
                      (w2 && (rd2 == rs2_a)) ? wdata2 :
                      regs[rs2_a];

    always @(posedge clk) begin
        if (w0) regs[rd0] <= wdata0;
        if (w1) regs[rd1] <= wdata1;
        if (w2) regs[rd2] <= wdata2;
    end
endmodule
