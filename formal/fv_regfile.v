// Formal properties for rtl/regfile.v.
//
// Small, but two of these are properties the whole ISA rests on, and both
// have a plausible way to break: x0 reading nonzero (if the write path
// forgot to exclude it, or the same-cycle bypass fired for rd=x0), and the
// write-to-read bypass returning stale data. The bypass exists to close a
// specific forwarding gap described in regfile.v's header, and a bug there
// would show up as a wrong result only for a producer exactly three
// instructions ahead of its consumer - which is exactly the kind of narrow
// window a directed test misses.
module fv_regfile (
    input wire        clk,
    input wire        we,
    input wire [4:0]  rs1, rs2, rd,
    input wire [31:0] wdata
);
    wire [31:0] rdata1, rdata2;

    regfile DUT (
        .clk(clk), .we(we), .rs1(rs1), .rs2(rs2), .rd(rd),
        .wdata(wdata), .rdata1(rdata1), .rdata2(rdata2)
    );

    always @(*) begin
        // 1. x0 always reads zero, no matter what is being written. Note
        //    this must hold even when we && rd==0 && rs1==0, which is the
        //    case a naive bypass gets wrong.
        if (rs1 == 5'd0) assert (rdata1 == 32'b0);
        if (rs2 == 5'd0) assert (rdata2 == 32'b0);

        // 2. A write in flight to a register being read this cycle is seen
        //    immediately (the write-to-read bypass), for both read ports.
        if (we && rd != 5'd0 && rs1 == rd) assert (rdata1 == wdata);
        if (we && rd != 5'd0 && rs2 == rd) assert (rdata2 == wdata);

        // 3. Both read ports agree when they name the same register. They
        //    are separate combinational paths, so this is not free.
        if (rs1 == rs2) assert (rdata1 == rdata2);
    end

    // 4. The write path never touches x0's storage.
    //
    // Phrased as "never changes" rather than "is always zero" on purpose.
    // Yosys does not carry the `initial` block that zeroes the array into
    // the formal model, so x0's storage starts unconstrained and asserting
    // it equals zero fails on a state no real device can be in. What the
    // hardware actually has to guarantee is that a write with rd=x0 is
    // discarded, and that is exactly what this says - independent of what
    // the array powers up holding.
    reg [31:0] prev_r0;
    reg        armed = 1'b0;
    always @(posedge clk) begin
        prev_r0 <= DUT.regs[0];
        armed   <= 1'b1;
        if (armed) assert (DUT.regs[0] == prev_r0);
    end
endmodule
