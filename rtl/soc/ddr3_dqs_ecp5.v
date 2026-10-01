// DDR3 DQS tracking, ECP5 - Phase 9 Stage 1, Part 2 (docs/roadmap/phase-09-ddr.md).
// `DDRDLLA` + one `DQSBUFM` per byte lane (one lane, matching this
// slice's own narrow scope). Real hardware DQS tracking, not
// UberDDR3's simpler fixed-delay scheme - see docs/roadmap/phase-09-ddr.md's own
// Stage 1 Part 2 account for the real research and the user's own
// decision behind this choice.
//
// ---- Wiring matches LiteDRAM's own real, proven code (read for
// architecture only - BSD, and this file is independently written
// either way, not a derivative) ----
// `RDLOADN=0/RDMOVE=0/RDDIRECTION=1` and the write-side equivalents
// tied off exactly the way LiteDRAM's own real, shipping ECP5 PHY
// does - confirmed directly against its own source
// (`litedram/phy/ecp5ddrphy.py`), not assumed: `DQSBUFM`'s own
// internal dynamic margin-control engine (what those six ports
// control) is real, documented in Lattice's own technical notes, and
// deliberately not used - real calibration instead happens through
// `READCLKSEL`, driven externally by `rtl/soc/ddr3_read_calib.v`, the
// same "READ Pulse Positioning" mechanism Lattice's own documentation
// (FPGA-TN-02035) describes and LiteDRAM's own real code actually
// exercises via a one-shot boot-time sweep, not a continuous loop.
//
// ---- DDRDLLA: shared, one per FPGA side - not instantiated here ----
// Through Part 23 this file instantiated its own `DDRDLLA`, correct only because a single
// byte lane was this whole slice's own scope (Part 2) and the distinction never came up.
// Real hardware has one `DDRDLLA` per FPGA side, its `DDRDEL` output fanned out to every
// lane's own `DQSBUFM` - confirmed directly against LiteDRAM's own real, shipping ECP5 PHY
// - so instantiating a second copy of this file for a second lane would silently double a
// primitive real hardware has exactly one of. `rtl/soc/ddr3_ddrdlla_ecp5.v` (Part 24) now
// owns it; this file takes `ddrdel` as an input instead, and a real caller instantiates
// the DLL once, whatever the real lane count.
//
// ---- DDRDLLA's own one-shot, not continuous, sequencing ----
// Confirmed directly against LiteDRAM's own real source: `FREEZE`/`UDDCNTLN` are pulsed
// through a fixed sequence exactly once, at reset, triggered by `DDRDLLA`'s own `LOCK`
// output - not re-run per transaction. `ddr3_ddrdlla_ecp5.v` follows the same real shape,
// reduced to what a single always block can express cleanly rather than LiteDRAM's own
// multi-step timeline (this project's own `DDR3_ECLK_HZ` runs at a comfortably low,
// DLL-off-appropriate rate throughout - see `rtl/soc/ddr3_eclk_pll.v` - so the tight
// timing LiteDRAM's own multi-step sequence protects against at much higher real DDR3
// clock rates has real margin here too).
module ddr3_dqs_ecp5 (
    input  wire        eclk,      // pin-rate edge clock, from ddr3_eclk_pll
    input  wire        sclk,      // fabric-rate clock, from ddr3_eclk_pll
    input  wire        rst,

    input  wire        dqs_pad_i, // the real DQS pin, input direction
    input  wire        read_active,  // this design's own read-burst-active signal (matches LiteDRAM's own dqs_re)
    input  wire [2:0]  readclksel,   // driven by rtl/soc/ddr3_read_calib.v's own sweep
    // From the one, shared rtl/soc/ddr3_ddrdlla_ecp5.v instance (Part 24) - not generated
    // here any more.
    input  wire        ddrdel,

    output wire        dqsr90,    // clocks IDDRX2DQA's own read capture
    output wire        dqsw,      // clocks ODDRX2DQSB's own DQS write drive
    output wire        dqsw270,   // clocks ODDRX2DQA's own DQ write drive
    output wire        datavalid, // real DQSBUFM output - the calibration sweep's own pass/fail signal
    output wire        burstdet,  // real DQSBUFM output - confirms a real strobe transition was seen

    // The read FIFO's pointers. Every IDDRX2DQA in the byte lane must take its RDPNTR and
    // WRPNTR from this DQSBUFM (nextpnr: "Port RDPNTR2 of cell ... must be driven by port
    // RDPNTR2 of a DQSBUFM" - Part 21). Constant in simulation, which has no FIFO.
    output wire [2:0]  rdpntr,
    output wire [2:0]  wrpntr
);
`ifdef SYNTHESIS
    DQSBUFM #(
        .DQS_LI_DEL_VAL(4), .DQS_LO_DEL_VAL(0)
    ) DQSBUF (
        .DQSI(dqs_pad_i), .READ1(read_active), .READ0(read_active),
        .READCLKSEL2(readclksel[2]), .READCLKSEL1(readclksel[1]),
        .READCLKSEL0(readclksel[0]),
        .DDRDEL(ddrdel), .ECLK(eclk), .SCLK(sclk), .RST(rst),
        .DYNDELAY7(1'b0), .DYNDELAY6(1'b0), .DYNDELAY5(1'b0),
        .DYNDELAY4(1'b0), .DYNDELAY3(1'b0), .DYNDELAY2(1'b0),
        .DYNDELAY1(1'b0), .DYNDELAY0(1'b0),
        .PAUSE(1'b0),
        .RDLOADN(1'b0), .RDMOVE(1'b0), .RDDIRECTION(1'b1),
        .WRLOADN(1'b0), .WRMOVE(1'b0), .WRDIRECTION(1'b1),
        .DQSR90(dqsr90), .DQSW(dqsw), .DQSW270(dqsw270),
        .RDPNTR2(rdpntr[2]), .RDPNTR1(rdpntr[1]), .RDPNTR0(rdpntr[0]),
        .WRPNTR2(wrpntr[2]), .WRPNTR1(wrpntr[1]), .WRPNTR0(wrpntr[0]),
        .DATAVALID(datavalid), .BURSTDET(burstdet),
        .RDCFLAG(), .WRCFLAG()
    );
`else
    // Simulation. Neither DDRDLLA nor DQSBUFM has a behavioral model
    // in this toolchain (confirmed by reading share/yosys/ecp5/
    // cells_sim.v directly - the same real gap Part 1 already found
    // for the simpler primitives). A real, phase-accurate DQSBUFM
    // model is not meaningfully achievable in plain Verilog - what
    // this stands in for instead is the real, testable *behavior* the
    // calibration sweep depends on: a bounded "correct" READCLKSEL
    // window (matching a real capture window existing somewhere in a
    // real sweep range, not everywhere), so rtl/soc/ddr3_read_calib.v's
    // own sweep has a genuine search problem to solve rather than
    // trivially passing at every tap. `READCLKSEL_GOOD_LO/HI` are this
    // model's own parameters, not a real hardware constant - a
    // different simulated DQS timing would move them, the same
    // "explicit rather than hidden" honesty this file's header keeps
    // to throughout.
    localparam [2:0] READCLKSEL_GOOD_LO = 3'd2;
    localparam [2:0] READCLKSEL_GOOD_HI = 3'd5;

    // dqsr90/dqsw/dqsw270: real DQSBUFM derives these from a captured,
    // phase-shifted DQS; this model derives them from sclk/eclk
    // instead (an honest, documented approximation, not a claim of
    // real DQS-referenced phase-shifting) - close enough for this
    // slice's own functional (not timing-accurate) simulation.
    assign rdpntr  = 3'b0;
    assign wrpntr  = 3'b0;
    assign dqsr90  = sclk;
    assign dqsw    = eclk;
    assign dqsw270 = ~eclk;

    assign burstdet  = read_active;
    assign datavalid = read_active &&
                        (readclksel >= READCLKSEL_GOOD_LO) &&
                        (readclksel <= READCLKSEL_GOOD_HI);

    // `ddrdel` (from the shared rtl/soc/ddr3_ddrdlla_ecp5.v) is a real hardware delay
    // code this simulation stand-in has no use for - it derives dqsr90/dqsw/dqsw270 from
    // sclk/eclk directly, not from a delay line - so it is read only to keep it a genuine
    // input rather than an unused one.
    wire _unused_ok = &{1'b0, dqs_pad_i, ddrdel, 1'b0};
`endif
endmodule
