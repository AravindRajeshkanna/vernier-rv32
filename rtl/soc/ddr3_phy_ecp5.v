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
// ---- Part 16: CK at the edge-clock rate, two command phases per sclk ----
// Until Part 16 this file generated CK with an ODDRX1F on sclk, so CK ran
// at sclk's own rate - while rtl/soc/ddr3_dq_serdes_ecp5.v moves four UI per
// sclk, a data rate that implies a CK of twice sclk. Measured, not just
// read off two files: CK rose once per sclk (5649 edges against 5649).
//
// Lattice's own reference DDR3 write side (FPGA-TN-02035, Figure 6.10 and
// section 6.3.3) resolves it this way, and this file now follows it:
//   - CK/CK# come from an ODDRX2F on constant inputs 0,1,0,1 - CK runs at
//     the edge clock, twice sclk. Here that is 50 MHz from a 25 MHz sclk,
//     well inside DLL-off mode (Micron gives tCK[DLL_DIS] a minimum, 8 ns,
//     and no maximum).
//   - Address, bank, RAS/CAS/WE, CKE and ODT go out through ODDRX1F taking
//     two values per sclk cycle, and CS_n through OSHX2A likewise - one value
//     per CK cycle, so TWO COMMAND SLOTS per sclk. This design issues at most
//     one command per sclk and always in the first slot (phase 0): the
//     second slot carries CS_n high, a deselect. Placing commands only in
//     phase 0 is what lets every CK-counted timing (CL = CWL = 6 CK, tRTP,
//     write recovery, the datasheet numbers) convert exactly and only ever
//     round up: 6 CK is 3 sclk, 4 CK is 2 sclk.
//   - CK and CS_n each pass through a DELAYG in DQS_CMD_CLK mode, as
//     Lattice's figure does, to centre the command in the CK eye.
// Simulation: eclk is a real 2x square wave whose rising edges fall exactly
// 10 ns after each sclk edge, the centre of each 20 ns command slot
// (rtl/soc/ddr3_eclk_pll.v). CK is that eclk directly, so a command driven
// at an sclk edge is stable across the CK rising edge in the middle of its
// slot. This depends on the testbench generating clk as
// `always #(period/2) clk = ~clk` from time zero, the way every one here does.
//
// ---- What is not verified ----
// No ECPIX-5 is attached, and this file has not been through place-and-route
// against real DDR3 pins. The synthesis branch is checked to ELABORATE
// (`make synth_check_ddr3`: every primitive port name and width resolves
// against yosys's own ECP5 cell library) - that catches wrong wiring, not
// wrong behaviour. Whether the fabric-to-pin latency of ODDRX2F / ODDRX1F /
// OSHX2A puts phase 0 where this file assumes, and what DELAYG's
// DQS_CMD_CLK mode actually delays by, is taken from Lattice's figure and
// unverified on silicon.
//
module ddr3_phy_ecp5 (
    input  wire        clk,        // sclk: the controller-rate clock, one command slot pair per cycle
    input  wire        eclk,       // the edge clock, twice sclk - CK runs on it
    input  wire        rst,

    // ---- command interface from rtl/soc/ddr3_init_seq.v (or, later,
    // a full controller) ----
    input  wire        cmd_valid,
    input  wire [2:0]  cmd_cs_ras_cas_we,  // {ras_n, cas_n, we_n} - see note below
    input  wire [2:0]  cmd_ba,
    input  wire [15:0] cmd_addr,
    input  wire        cmd_cke,
    input  wire        cmd_reset_n,
    input  wire        cmd_odt,

    // ---- real DDR3 pins ----
    output wire        ddr3_ck,
    output wire        ddr3_ck_n,
    output wire        ddr3_cs_n,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire [2:0]  ddr3_ba,
    output wire [15:0] ddr3_a,
    output wire        ddr3_cke,
    output wire        ddr3_reset_n,
    output wire        ddr3_odt
);
    // cmd_cs_ras_cas_we is 3 bits, not 4 - cs_n is carried separately by
    // cmd_valid (cmd_valid=0 means "no command," i.e. cs_n=1 - a NOP -
    // exactly like this project's own wb_sdram.v treats its own idle
    // state) so callers never have to spell out cs_n themselves. Ties
    // the two together at exactly one place rather than trusting every
    // caller to keep cmd_valid and an explicit cs_n bit in agreement.
    wire cs_n_eff = !cmd_valid;

    // The phase-0 values, registered once per sclk. In the synthesis branch
    // these feed the two-value output primitives; in simulation they drive
    // the pins directly.
    reg        cs_n_q, ras_n_q, cas_n_q, we_n_q;
    reg [2:0]  ba_q;
    reg [15:0] a_q;
    reg        cke_q, reset_n_q, odt_q;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cs_n_q    <= 1'b1;
            ras_n_q   <= 1'b1;
            cas_n_q   <= 1'b1;
            we_n_q    <= 1'b1;
            ba_q      <= 3'b0;
            a_q       <= 16'b0;
            cke_q     <= 1'b0;
            reset_n_q <= 1'b0;
            odt_q     <= 1'b0;
        end else begin
            cs_n_q    <= cs_n_eff;
            ras_n_q   <= cmd_cs_ras_cas_we[2];
            cas_n_q   <= cmd_cs_ras_cas_we[1];
            we_n_q    <= cmd_cs_ras_cas_we[0];
            ba_q      <= cmd_ba;
            a_q       <= cmd_addr;
            cke_q     <= cmd_cke;
            reset_n_q <= cmd_reset_n;
            odt_q     <= cmd_odt;
        end
    end

`ifdef SYNTHESIS
    // CK/CK#: ODDRX2F on constants, as Lattice's Figure 6.10 - four values
    // per sclk on the edge clock, alternating, so CK runs at eclk. Both
    // then pass through a DELAYG in DQS_CMD_CLK mode, as the figure does.
    wire ck_raw, ck_n_raw;
    ODDRX2F CK_P (
        .SCLK(clk), .ECLK(eclk), .RST(1'b0),
        .D0(1'b0), .D1(1'b1), .D2(1'b0), .D3(1'b1), .Q(ck_raw)
    );
    ODDRX2F CK_N (
        .SCLK(clk), .ECLK(eclk), .RST(1'b0),
        .D0(1'b1), .D1(1'b0), .D2(1'b1), .D3(1'b0), .Q(ck_n_raw)
    );
    DELAYG #(.DEL_MODE("DQS_CMD_CLK")) CK_P_DLY (.A(ck_raw),   .Z(ddr3_ck));
    DELAYG #(.DEL_MODE("DQS_CMD_CLK")) CK_N_DLY (.A(ck_n_raw), .Z(ddr3_ck_n));

    // CS_n: OSHX2A taking one value per CK - low only in phase 0, and only
    // when a command is present; phase 1 is always a deselect - then DELAYG.
    wire cs_n_raw;
    OSHX2A CS (
        .D0(cs_n_q), .D1(1'b1), .SCLK(clk), .ECLK(eclk), .RST(1'b0), .Q(cs_n_raw)
    );
    DELAYG #(.DEL_MODE("DQS_CMD_CLK")) CS_DLY (.A(cs_n_raw), .Z(ddr3_cs_n));

    // Everything else: ODDRX1F with both slots carrying the same value.
    // CS_n is high in phase 1, so the DRAM ignores whatever else is there.
    ODDRX1F RAS (.SCLK(clk), .RST(1'b0), .D0(ras_n_q),   .D1(ras_n_q),   .Q(ddr3_ras_n));
    ODDRX1F CAS (.SCLK(clk), .RST(1'b0), .D0(cas_n_q),   .D1(cas_n_q),   .Q(ddr3_cas_n));
    ODDRX1F WE  (.SCLK(clk), .RST(1'b0), .D0(we_n_q),    .D1(we_n_q),    .Q(ddr3_we_n));
    ODDRX1F CKE (.SCLK(clk), .RST(1'b0), .D0(cke_q),     .D1(cke_q),     .Q(ddr3_cke));
    ODDRX1F ODT (.SCLK(clk), .RST(1'b0), .D0(odt_q),     .D1(odt_q),     .Q(ddr3_odt));
    genvar gi;
    generate
        for (gi = 0; gi < 3; gi = gi + 1) begin : BA_OUT
            ODDRX1F BA (.SCLK(clk), .RST(1'b0), .D0(ba_q[gi]), .D1(ba_q[gi]), .Q(ddr3_ba[gi]));
        end
        for (gi = 0; gi < 16; gi = gi + 1) begin : A_OUT
            ODDRX1F A  (.SCLK(clk), .RST(1'b0), .D0(a_q[gi]),  .D1(a_q[gi]),  .Q(ddr3_a[gi]));
        end
    endgenerate
    // RESET_n is static across the whole run, not a per-CK signal.
    assign ddr3_reset_n = reset_n_q;
`else
    // Simulation. None of these DDR-I/O primitives has a behavioral model in
    // this toolchain (share/yosys/ecp5/cells_sim.v contains exactly one
    // module, DP16KD, and no DDR-I/O primitives at all), so what a
    // testbench needs is the real phase relationship:
    //   - CK is the eclk itself, a 2x square wave whose rising edges sit
    //     10 ns after each sclk edge, the centre of each command slot.
    //   - Phase 0 is the slot that starts at the sclk rising edge; a command
    //     is driven there. Phase 1 starts at the sclk falling edge and
    //     always carries a deselect.
    assign ddr3_ck   = eclk;
    assign ddr3_ck_n = ~eclk;

    reg cs_n_pin;
    always @(posedge clk or posedge rst) begin
        if (rst) cs_n_pin <= 1'b1;
        else     cs_n_pin <= cs_n_eff;     // phase 0
    end
    always @(negedge clk) begin
        if (!rst) cs_n_pin <= 1'b1;        // phase 1: deselect
    end
    assign ddr3_cs_n    = cs_n_pin;
    assign ddr3_ras_n   = ras_n_q;
    assign ddr3_cas_n   = cas_n_q;
    assign ddr3_we_n    = we_n_q;
    assign ddr3_ba      = ba_q;
    assign ddr3_a       = a_q;
    assign ddr3_cke     = cke_q;
    assign ddr3_reset_n = reset_n_q;
    assign ddr3_odt     = odt_q;
`endif
endmodule
