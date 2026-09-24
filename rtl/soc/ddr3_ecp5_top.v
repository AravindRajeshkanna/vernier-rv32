// DDR3 PHY integration, ECP5 - Phase 9 Stage 1, Parts 3-5
// (docs/roadmap.md). Wires Part 1 (rtl/soc/ddr3_init_seq.v +
// rtl/soc/ddr3_phy_ecp5.v, the real JEDEC power-up sequence and SDR
// command/address/CK generation), Part 2 (rtl/soc/ddr3_eclk_pll.v +
// rtl/soc/ddr3_dqs_ecp5.v + rtl/soc/ddr3_dq_serdes_ecp5.v +
// rtl/soc/ddr3_read_calib.v, one byte lane's own DQSBUFM-based DQ/DQS
// data path), and Part 4 (rtl/soc/ddr3_dqs_write_ecp5.v, the real DQS
// write-drive primitive) onto one real, shared clock tree - each was
// proven independently first, against its own free-running testbench
// clock or its own standalone test, not against the others.
//
// ---- Why this is real, not cosmetic ----
// Part 1's own `ddr3_phy_ecp5.v` generates `CK`/`CK#` (and every
// command/address edge) from whatever `clk` its caller supplies. Part
// 2's own `ddr3_dqs_ecp5.v`/`ddr3_dq_serdes_ecp5.v` need `SCLK` and
// `ECLK` from one real PLL (`ddr3_eclk_pll.v`) in a fixed 1:2 phase
// relationship - `DQSR90`/`DQSW270`, and every DQ capture/drive edge,
// are defined relative to that PLL's own internal VCO, not to an
// independent clock net. Two independently free-running clocks at the
// same nominal frequency drift in phase against each other on real
// silicon (different oscillators, different routing, no shared PLL) -
// only equal *frequency*, both testbenches already used 25 MHz, was
// ever actually shared before this file. Driving `ddr3_phy_ecp5.v` and
// `ddr3_init_seq.v` from this same PLL's own `sclk` output, instead of
// a second, separate clock, is the real fix - not a naming exercise.
//
// ---- Reset sequencing ----
// `rst_all` stays asserted until `pll_locked` - releasing any
// downstream reset before the PLL's own outputs are stable would let
// `ddr3_phy_ecp5.v` start toggling `CK`/`CK#` off a not-yet-locked
// clock, a real hardware hazard, not just a simulation nicety.
// `ddr3_read_calib.v`'s own reset is held for longer still - until
// `init_ready` - so this byte lane's own read-calibration sweep is
// real, correct sequencing, not started before the DRAM
// itself is out of its own power-up sequence. That said: this module
// does not yet make `ddr3_read_calib.v`'s "write"/"read" issue real
// ACT/WR/RD commands through `ddr3_phy_ecp5.v` - it still directly
// drives the DQ serdes the same simplified way Part 2's own narrow
// proof did. Gating on `init_ready` is the real, correct sequencing
// decision either way; it does not by itself close that gap - see
// docs/roadmap.md's own account of what this integration does not
// establish.
//
// ---- DQS write-drive, Part 5 ----
// `rtl/soc/ddr3_dqs_write_ecp5.v` (Part 4) is wired in here for the
// first time - `ddr3_dqs` is genuinely `inout` now, tristate-arbitrated
// the same way `ddr3_dq` already was. Its own `write_start` is driven
// directly from `ddr3_read_calib.v`'s own `wr_en` pulse - the same
// single-cycle signal that already marks "a write is happening now"
// for the DQ side, reused rather than duplicated. This proves the real
// wiring (the write-drive primitive fires exactly when a write
// happens, and the shared `ddr3_dqs` pin is never driven from both
// sides at once) - it does not yet prove a real DRAM would sample the
// right data from it: `sim/ddr3_dq_model.v` still stores whatever
// `wr_en`/`wr_d0` say directly, not by watching real DQS edges, and
// `ddr3_read_calib.v` still does not issue real ACT/WR/RD commands
// through `ddr3_phy_ecp5.v`. Both remain later, separate work, along
// with the second DQ byte lane and real hardware bring-up.
module ddr3_ecp5_top (
    input  wire        clk,        // board-rate input, same as every other file in this stage (25 MHz)
    input  wire        rst,

    // ---- real DDR3 pins - command/address/CK, from Part 1 ----
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
    output wire        ddr3_odt,

    // ---- real DDR3 pins - one byte lane's own DQ/DQS, from Parts 2/4 ----
    inout  wire [7:0]  ddr3_dq,
    inout  wire        ddr3_dqs,

    // ---- observability, matching this stage's own testbenches ----
    output wire        pll_locked,
    output wire        dll_locked,
    output wire        init_ready,
    output wire        calib_done,
    output wire [2:0]  calib_readclksel,
    output wire        calib_error
);
    wire eclk, sclk;
    ddr3_eclk_pll PLL (
        .clk(clk), .eclk(eclk), .sclk(sclk), .locked(pll_locked)
    );

    // Held until the PLL's own outputs are real and stable - see header.
    wire rst_all = rst || !pll_locked;

    wire        cmd_valid;
    wire [2:0]  cmd_cs_ras_cas_we;
    wire [2:0]  cmd_ba;
    wire [15:0] cmd_addr;
    wire        cmd_cke, cmd_reset_n, cmd_odt;

    ddr3_init_seq SEQ (
        .clk(sclk), .rst(rst_all),
        .cmd_valid(cmd_valid), .cmd_cs_ras_cas_we(cmd_cs_ras_cas_we),
        .cmd_ba(cmd_ba), .cmd_addr(cmd_addr),
        .cmd_cke(cmd_cke), .cmd_reset_n(cmd_reset_n), .cmd_odt(cmd_odt),
        .ready(init_ready)
    );

    ddr3_phy_ecp5 PHY (
        .clk(sclk), .rst(rst_all),
        .cmd_valid(cmd_valid), .cmd_cs_ras_cas_we(cmd_cs_ras_cas_we),
        .cmd_ba(cmd_ba), .cmd_addr(cmd_addr),
        .cmd_cke(cmd_cke), .cmd_reset_n(cmd_reset_n), .cmd_odt(cmd_odt),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt)
    );

    // Held until init_ready too - see header: a real controller would
    // not start read-timing calibration against a DRAM that has not
    // finished its own power-up sequence yet.
    wire rst_calib = rst_all || !init_ready;

    wire [7:0] wr_d0, rd_q0;
    wire       wr_en, read_active;
    wire [2:0] readclksel;
    wire       datavalid;

    ddr3_read_calib CALIB (
        .clk(sclk), .rst(rst_calib),
        .wr_d0(wr_d0), .wr_en(wr_en),
        .read_active(read_active), .readclksel(readclksel),
        .datavalid(datavalid), .rd_q0(rd_q0),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    wire dqsr90, dqsw, dqsw270, burstdet;

    ddr3_dqs_ecp5 DQS (
        .eclk(eclk), .sclk(sclk), .rst(rst_all),
        .dqs_pad_i(ddr3_dqs), .read_active(read_active), .readclksel(readclksel),
        .dqsr90(dqsr90), .dqsw(dqsw), .dqsw270(dqsw270),
        .datavalid(datavalid), .burstdet(burstdet), .dll_locked(dll_locked)
    );

    // Part 5: real DQS write-drive, triggered directly from the same
    // wr_en pulse that already marks a write on the DQ side - see
    // header.
    wire dqs_wr_o, dqs_wr_oe;

    ddr3_dqs_write_ecp5 DQS_WR (
        .sclk(sclk), .eclk(eclk), .dqsw(dqsw), .rst(rst_all),
        .write_start(wr_en),
        .dqs_o(dqs_wr_o), .dqs_oe(dqs_wr_oe)
    );

    assign ddr3_dqs = dqs_wr_oe ? dqs_wr_o : 1'bz;

    wire [7:0] dq_o, dq_oe, dq_i;
    wire [7:0] rd_q3, rd_q2, rd_q1;

    ddr3_dq_serdes_ecp5 #(.DQ_WIDTH(8)) SERDES (
        .sclk(sclk), .eclk(eclk), .rst(rst_all),
        .dqsr90(dqsr90), .dqsw270(dqsw270),
        .wr_d3(wr_d0), .wr_d2(wr_d0), .wr_d1(wr_d0), .wr_d0(wr_d0),
        .wr_en(wr_en),
        .rd_q3(rd_q3), .rd_q2(rd_q2), .rd_q1(rd_q1), .rd_q0(rd_q0),
        .dq_o(dq_o), .dq_oe(dq_oe), .dq_i(dq_i)
    );

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : DQ_PIN
            assign ddr3_dq[i] = dq_oe[i] ? dq_o[i] : 1'bz;
            assign dq_i[i]    = ddr3_dq[i];
        end
    endgenerate
endmodule
