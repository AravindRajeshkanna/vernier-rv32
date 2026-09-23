// DDR3 PHY, ECP5 - Phase 9 Stage 1, Part 1 (docs/roadmap.md). Command/
// address/clock generation only - no DQ/DQS data path yet, that is a
// later, separate slice.
//
// ---- Why DLL-off, and what that buys this design ----
//
// DDR3's own DLL (delay-locked loop, inside the DRAM itself) exists to
// align the part's own output data edges to the input clock at the high
// clock rates DDR3 is rated for (300 MHz+). Running the DLL off is a
// real, JEDEC-documented mode, not a hack: it fixes CAS Latency and CAS
// Write Latency at 6 each, caps the DRAM clock at 125 MHz, and -
// confirmed against two independent real, working ECP5 implementations
// this round's own research read directly (AngeloJacobo/UberDDR3,
// GPL-3.0, and ultraembedded/core_ddr3_controller, license-less and
// stale - studied for architecture only, no code copied from either) -
// removes the need for read/write leveling entirely on a single-rank,
// short-trace, point-to-point topology, which is exactly what ECPIX-5's
// one on-board DDR3L chip is. This project's own design runs nowhere
// near 125 MHz, so the cap costs nothing real.
//
// ---- Command/address is single-data-rate; only CK/DQ/DQS are not ----
// A real, worth-stating-plainly DDR3 fact: CS_n/RAS_n/CAS_n/WE_n/BA/A
// are sampled once per full clock, not double-pumped - only the
// differential clock itself (CK/CK#) and the DQ/DQS data lines run at
// twice the command rate. This is why this file needs only one DDR
// primitive (`ODDRX1F`, for CK/CK# generation) rather than the wider
// set (`IDDRX1F`/`DELAYG`/DQS capture) a later, data-path slice will
// need - a real, deliberate scope boundary, not an oversight.
//
// ---- CK/CK# phase ----
// Mirrors fpga/sdram_clk_out.v's own real, hardware-confirmed reasoning
// for the existing SDR SDRAM controller almost exactly: an edge-aligned
// clock gives the DRAM essentially no setup/hold margin, because the
// data and the clock both leave the FPGA at the same internal edge.
// `ODDRX1F` with D0=0/D1=1 moves CK's own rising edge to the internal
// clock's falling edge - a real 180 degree shift, generated in the I/O
// logic where the delay is fixed and known, not through general fabric
// routing. CK# is simply CK's own logical inversion (D0=1/D1=0),
// generated the same way rather than as an inverted net, so both halves
// of the differential pair share the same I/O-logic-fixed delay.
//
// ---- What is not yet verified ----
// No ECPIX-5 is attached to this session. This file has not been
// synthesized against real DDR3 pins yet - Part 1's own scope is the
// controller logic and its simulation model, verified in simulation
// only; real pins and a real board top-level are later, separate work,
// the same "board bring-up is its own stage" split Stage 0 already
// used.
module ddr3_phy_ecp5 (
    input  wire        clk,        // controller-rate clock (same rate as command/address)
    input  wire        rst,

    // ---- command interface from rtl/soc/ddr3_init_seq.v (or, later,
    // a full controller) ----
    input  wire        cmd_valid,
    input  wire [2:0]  cmd_cs_ras_cas_we,  // {cs_n, ras_n, cas_n, we_n} - see note below
    input  wire [2:0]  cmd_ba,
    input  wire [15:0] cmd_addr,
    input  wire        cmd_cke,
    input  wire        cmd_reset_n,
    input  wire        cmd_odt,

    // ---- real DDR3 pins ----
    output wire        ddr3_ck,
    output wire        ddr3_ck_n,
    output reg         ddr3_cs_n,
    output reg         ddr3_ras_n,
    output reg         ddr3_cas_n,
    output reg         ddr3_we_n,
    output reg  [2:0]  ddr3_ba,
    output reg  [15:0] ddr3_a,
    output reg         ddr3_cke,
    output reg         ddr3_reset_n,
    output reg         ddr3_odt
);
    // cmd_cs_ras_cas_we is 3 bits, not 4 - cs_n is carried separately by
    // cmd_valid (cmd_valid=0 means "no command," i.e. cs_n=1 - a NOP -
    // exactly like this project's own wb_sdram.v treats its own idle
    // state) so callers never have to spell out cs_n themselves. Ties
    // the two together at exactly one place rather than trusting every
    // caller to keep cmd_valid and an explicit cs_n bit in agreement.
    wire cs_n_eff = !cmd_valid;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ddr3_cs_n    <= 1'b1;
            ddr3_ras_n   <= 1'b1;
            ddr3_cas_n   <= 1'b1;
            ddr3_we_n    <= 1'b1;
            ddr3_ba      <= 3'b0;
            ddr3_a       <= 16'b0;
            ddr3_cke     <= 1'b0;
            ddr3_reset_n <= 1'b0;
            ddr3_odt     <= 1'b0;
        end else begin
            ddr3_cs_n    <= cs_n_eff;
            ddr3_ras_n   <= cmd_cs_ras_cas_we[2];
            ddr3_cas_n   <= cmd_cs_ras_cas_we[1];
            ddr3_we_n    <= cmd_cs_ras_cas_we[0];
            ddr3_ba      <= cmd_ba;
            ddr3_a       <= cmd_addr;
            ddr3_cke     <= cmd_cke;
            ddr3_reset_n <= cmd_reset_n;
            ddr3_odt     <= cmd_odt;
        end
    end

`ifdef SYNTHESIS
    ODDRX1F CK_P (
        .SCLK(clk), .RST(1'b0), .D0(1'b0), .D1(1'b1), .Q(ddr3_ck)
    );
    ODDRX1F CK_N (
        .SCLK(clk), .RST(1'b0), .D0(1'b1), .D1(1'b0), .Q(ddr3_ck_n)
    );
`else
    // Simulation. ODDRX1F has no behavioral model in this toolchain
    // (confirmed by reading share/yosys/ecp5/cells_sim.v directly -
    // it contains exactly one module, DP16KD, and no DDR-I/O
    // primitives at all) - what a testbench needs is the real phase
    // relationship, matching fpga/sdram_clk_out.v's own identical
    // simulation substitute exactly.
    assign ddr3_ck   = ~clk;
    assign ddr3_ck_n = clk;
`endif
endmodule
