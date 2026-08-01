// A property that must FAIL.
//
// This is not a test of the design - it is a test of the flow. A formal
// setup that silently proves nothing looks exactly like one that proves
// everything: both print PASSED. That is not hypothetical here. The first
// version of formal/run.sh reported every property as passing because yosys
// was discarding the assertions entirely (they need `read_verilog -sv`, and
// newer yosys emits `$check` cells that have to be lowered with
// `async2sync; chformal -lower` before write_smt2 will emit them).
//
// So run.sh checks this file first and refuses to run anything else unless
// the solver reports FAILED here. A green board is only meaningful if the
// board can go red.
module fv_selftest (
    input wire clk,
    input wire [3:0] a
);
    reg [3:0] s;
    always @(posedge clk) s <= a;
    always @(posedge clk) assert (s != 4'd7);
endmodule
