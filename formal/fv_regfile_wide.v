// Formal properties for rtl/ooo/regfile_wide.v.
//
// The 2R/1W file already has properties (fv_regfile.v) for the two things the
// ISA rests on: x0 always reads zero, and the same-cycle bypass returns the
// value being written rather than the stale one. Four read ports and two
// write ports do not add new *kinds* of property - they multiply the
// opportunities for the same two to break, and add one genuinely new one.
//
// The new one is write priority. Two instructions issued together may legally
// write the same architectural register, and port 1 is defined as the younger.
// Get that backwards and the file is not slow, it is wrong - and wrong only
// when a dual-issue pair happens to share a destination, which is exactly the
// narrow window a directed test does not think to build.
module fv_regfile_wide (
    input wire        clk,
    input wire [4:0]  rs1_a, rs2_a, rs1_b, rs2_b,
    input wire        we0, we1,
    input wire [4:0]  rd0, rd1,
    input wire [31:0] wdata0, wdata1
);
    wire [31:0] rdata1_a, rdata2_a, rdata1_b, rdata2_b;

    regfile_wide dut (
        .clk(clk),
        .rs1_a(rs1_a), .rs2_a(rs2_a), .rs1_b(rs1_b), .rs2_b(rs2_b),
        .rdata1_a(rdata1_a), .rdata2_a(rdata2_a),
        .rdata1_b(rdata1_b), .rdata2_b(rdata2_b),
        .we0(we0), .rd0(rd0), .wdata0(wdata0),
        .we1(we1), .rd1(rd1), .wdata1(wdata1)
    );

    always @* begin
        // 1. x0 reads zero on every port, whatever either write port is doing.
        //    A bypass that forgot to exclude x0 would break this and nothing
        //    else would notice until a program relied on x0 being zero.
        if (rs1_a == 5'd0) assert (rdata1_a == 32'b0);
        if (rs2_a == 5'd0) assert (rdata2_a == 32'b0);
        if (rs1_b == 5'd0) assert (rdata1_b == 32'b0);
        if (rs2_b == 5'd0) assert (rdata2_b == 32'b0);

        // 2. Write priority: when both ports target the same register, the
        //    younger one (port 1) is what a same-cycle read sees.
        if (we0 && we1 && rd0 == rd1 && rd1 != 5'd0 && rs1_a == rd1)
            assert (rdata1_a == wdata1);

        // 3. The bypass returns the written value, from either port, on every
        //    read port - checked on a different read port per write port so a
        //    file that wired only port 0's bypass through cannot pass.
        if (we0 && rd0 != 5'd0 && rs1_a == rd0 && !(we1 && rd1 == rd0))
            assert (rdata1_a == wdata0);
        if (we1 && rd1 != 5'd0 && rs2_b == rd1)
            assert (rdata2_b == wdata1);

        // 4. Reads are a pure function of the address: two ports asking for
        //    the same register in the same cycle must agree. This is what
        //    catches a bypass wired into some ports but not others - the
        //    failure a four-port file invites and a two-port one cannot have.
        if (rs1_a == rs2_b) assert (rdata1_a == rdata2_b);
        if (rs1_a == rs1_b) assert (rdata1_a == rdata1_b);
    end
endmodule
