// DDR3 shared DLL, ECP5 - Phase 9 Stage 1, Part 24 (docs/roadmap/phase-09-ddr.md).
//
// One `DDRDLLA` per FPGA side, not one per byte lane: its `DDRDEL` output fans out to
// every `DQSBUFM` in that half of the device, confirmed directly against LiteDRAM's own
// real, shipping ECP5 PHY (`litedram/phy/ecp5ddrphy.py`) - a single `DDRDLLA` instance,
// its `DDRDEL` wired identically to each lane's own `DQSBUFM`. `rtl/soc/ddr3_dqs_ecp5.v`
// originally instantiated its own `DDRDLLA` internally (Part 2, when a single byte lane
// was this whole slice's scope, so the distinction did not yet matter); factored out here
// so that adding lane 1 (Part 24) does not silently double a primitive real hardware has
// exactly one of. The one-shot `FREEZE`/`UDDCNTLN` sequencing this file uses in place of
// `DDRDLLA`'s own real multi-step timeline is `rtl/soc/ddr3_dqs_ecp5.v`'s own header's
// reasoning (Part 2), unaffected by which module the instance now lives in.
module ddr3_ddrdlla_ecp5 (
    input  wire        eclk,       // pin-rate edge clock, from ddr3_eclk_pll
    input  wire        rst,

    output wire        ddrdel,     // fans out to every byte lane's own DQSBUFM
    output wire        dll_locked
);
`ifdef SYNTHESIS
    DDRDLLA #(
        .FORCE_MAX_DELAY("NO")
    ) DLL (
        .CLK(eclk), .RST(rst), .UDDCNTLN(1'b1), .FREEZE(1'b0),
        .DDRDEL(ddrdel), .LOCK(dll_locked)
    );
`else
    // Simulation. No behavioral model in this toolchain (the same real gap every other
    // DDR-I/O primitive in this stage already found). Nothing reads a real delay code in
    // simulation (rtl/soc/ddr3_dqs_ecp5.v's own simulation body derives its DQSBUFM
    // stand-in from sclk/eclk directly, not from ddrdel), so ddrdel is driven only so it
    // is not left floating - the same stand-in Part 2 originally used inside
    // ddr3_dqs_ecp5.v itself.
    reg dll_locked_r = 1'b0;
    initial begin
        repeat (8) @(posedge eclk);
        dll_locked_r = 1'b1;
    end
    assign dll_locked = dll_locked_r;
    assign ddrdel     = 1'b0;

    wire _unused_ok = &{1'b0, rst, 1'b0};
`endif
endmodule
