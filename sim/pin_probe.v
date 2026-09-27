// A pin monitor for the DDR3 testbenches that reads DQS and DQ the same way
// under Icarus Verilog and under Verilator. Sim only; nothing in rtl/ uses it.
//
// The DQ and DQS pins are tri-state nets: whoever is driving them, the DRAM
// model or the PHY, is decided by output enables, and "nobody is driving" is a
// state the DRAM's own timing rules are written about. Icarus resolves such a
// net to z wherever it is read. Verilator is two-state, and resolves it to 0 in
// the module that owns the drivers - so a testbench reading `ddr3_dqs === 1'bz`
// in its own scope sees a low strobe where the pin is in fact floating, and a
// monitor that logs it reports a preamble in every cycle the strobe is idle.
// Read through an `inout` port instead, the z is preserved in both.
//
// The classification is per bit rather than a reduction: `^dq === 1'bx` is the
// natural way to ask "is any bit not driven?" in Icarus, but it is exactly the
// kind of x-propagation a two-state simulator cannot reproduce.
module pin_probe (
    inout  wire       dqs,
    inout  wire [7:0] dq,
    output reg  [1:0] dqs_class,   // 0 low, 1 high, 2 high-Z, 3 unknown
    output reg        dq_bad,      // some DQ bit is high-Z or unknown
    output reg  [7:0] dq_value     // the DQ bus, meaningful when dq_bad is 0
);
    integer i;
    always @* begin
        dqs_class = (dqs === 1'b0) ? 2'd0 : (dqs === 1'b1) ? 2'd1 :
                    (dqs === 1'bz) ? 2'd2 : 2'd3;
        dq_bad = 1'b0;
        for (i = 0; i < 8; i = i + 1)
            if (dq[i] !== 1'b0 && dq[i] !== 1'b1) dq_bad = 1'b1;
        dq_value = dq;
    end
endmodule
