// DDR3 PHY integration, ECP5 - Phase 9 Stage 1, Parts 3-5 and 9
// (docs/roadmap.md). Wires Part 1 (rtl/soc/ddr3_init_seq.v +
// rtl/soc/ddr3_phy_ecp5.v, the real JEDEC power-up sequence and SDR
// command/address/CK generation), Part 2 (rtl/soc/ddr3_eclk_pll.v +
// rtl/soc/ddr3_dqs_ecp5.v + rtl/soc/ddr3_dq_serdes_ecp5.v +
// rtl/soc/ddr3_read_calib.v, one byte lane's own DQSBUFM-based DQ/DQS
// data path), Part 4 (rtl/soc/ddr3_dqs_write_ecp5.v, the real DQS
// write-drive primitive), and Part 9 (rtl/soc/ddr3_write_seq.v +
// rtl/soc/ddr3_read_seq.v + rtl/soc/ddr3_read_burst_ext.v, real
// command-level read/write) onto one real, shared clock tree - each
// was proven independently first, against its own free-running
// testbench clock or its own standalone test, not against the others.
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
// real, correct sequencing, not started before the DRAM itself is out
// of its own power-up sequence. `rtl/soc/ddr3_write_seq.v`/
// `rtl/soc/ddr3_read_seq.v` (Part 9) are held for longer still again -
// until `calib_done` - a real, deliberate safety property: issuing a
// real read/write before calibration has found a working `READCLKSEL`
// tap would sample data at an unproven, possibly-wrong point.
//
// ---- DQS write-drive, Part 5 ----
// `rtl/soc/ddr3_dqs_write_ecp5.v` (Part 4) is wired in here -
// `ddr3_dqs` is genuinely `inout`, tristate-arbitrated the same way
// `ddr3_dq` already was.
//
// ---- Part 9: real command-level read/write, closing the gap every
// part since Part 3 named ----
// `ddr3_read_calib.v`'s own direct-signal-injection scheme (Part 2)
// is kept, not replaced - it still needs its own simple mechanism to
// find a working `READCLKSEL` tap before any command-driven read/write
// can be trusted, and it still runs first, gated on `init_ready` alone.
// Once `calib_done`, `rtl/soc/ddr3_write_seq.v`/`rtl/soc/ddr3_read_seq.v`
// take over as the real, command-driven path: each drives
// `ddr3_phy_ecp5.v`'s own `cmd_*` interface with a real ACT then a real
// WR/RD, muxed with `ddr3_init_seq.v`'s own output on that same
// interface (mutually exclusive by construction - the init sequence
// only ever asserts `cmd_valid` before `ready`, and the two command
// sequencers only ever start after `calib_done`, which itself cannot
// happen before `init_ready`). `ddr3_write_seq.v`'s own `write_start`
// output is OR-combined with `ddr3_read_calib.v`'s own `wr_en` into the
// DQS write-drive's own trigger - mutually exclusive the same way, by
// the same real sequencing. `rtl/soc/ddr3_read_burst_ext.v` (Part 8)
// converts `ddr3_read_seq.v`'s own single-cycle `read_start` into a
// real, held-high window OR-combined into `ddr3_dqs_ecp5.v`'s own
// `read_active` input alongside `ddr3_read_calib.v`'s own signal of the
// same name.
//
// Neither command sequencer carries its own write data - a new
// `write_data_latch` register captures the top-level `write_data` input
// at real request time (`write_req` asserted, matching how
// `ddr3_write_seq.v`'s own `bank`/`row`/`col` inputs are captured), and
// holds it stable through the whole transaction for
// `ddr3_dq_serdes_ecp5.v` to drive. `read_data`/`read_data_valid` are a
// direct, real combinational view of `rd_q0`/`datavalid` gated by the
// real capture window - not registered, the same simple style
// `ddr3_read_calib.v`'s own `rd_q0` port already uses.
//
// Still not attempted: bank-state tracking (no redundant-ACT
// avoidance), PRECHARGE, the second DQ byte lane, and real hardware
// bring-up - see docs/roadmap.md's own Part 9 account for the full
// list of what this does not establish.
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

    // ---- Part 9: real command-level requests ----
    input  wire        write_req,
    input  wire [2:0]  write_bank,
    input  wire [15:0] write_row,
    input  wire [15:0] write_col,
    input  wire [7:0]  write_data,
    output wire        write_busy,

    input  wire        read_req,
    input  wire [2:0]  read_bank,
    input  wire [15:0] read_row,
    input  wire [15:0] read_col,
    output wire        read_busy,
    output wire [7:0]  read_data,
    output wire        read_data_valid,

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

    wire        seq_cmd_valid;
    wire [2:0]  seq_cmd_cs_ras_cas_we;
    wire [2:0]  seq_cmd_ba;
    wire [15:0] seq_cmd_addr;
    wire        seq_cmd_cke, seq_cmd_reset_n, seq_cmd_odt;

    ddr3_init_seq SEQ (
        .clk(sclk), .rst(rst_all),
        .cmd_valid(seq_cmd_valid), .cmd_cs_ras_cas_we(seq_cmd_cs_ras_cas_we),
        .cmd_ba(seq_cmd_ba), .cmd_addr(seq_cmd_addr),
        .cmd_cke(seq_cmd_cke), .cmd_reset_n(seq_cmd_reset_n), .cmd_odt(seq_cmd_odt),
        .ready(init_ready)
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

    // Part 9: held until calib_done - see header. A real read/write
    // before a working READCLKSEL tap is known would sample data at an
    // unproven, possibly-wrong point.
    wire rst_cmd = rst_calib || !calib_done;

    wire        wseq_cmd_valid;
    wire [2:0]  wseq_cmd_cs_ras_cas_we;
    wire [2:0]  wseq_cmd_ba;
    wire [15:0] wseq_cmd_addr;
    wire        wseq_write_start;

    ddr3_write_seq WSEQ (
        .clk(sclk), .rst(rst_cmd),
        .write_req(write_req), .bank(write_bank), .row(write_row), .col(write_col),
        .busy(write_busy),
        .cmd_valid(wseq_cmd_valid), .cmd_cs_ras_cas_we(wseq_cmd_cs_ras_cas_we),
        .cmd_ba(wseq_cmd_ba), .cmd_addr(wseq_cmd_addr),
        .write_start(wseq_write_start)
    );

    wire        rseq_cmd_valid;
    wire [2:0]  rseq_cmd_cs_ras_cas_we;
    wire [2:0]  rseq_cmd_ba;
    wire [15:0] rseq_cmd_addr;
    wire        rseq_read_start;

    ddr3_read_seq RSEQ (
        .clk(sclk), .rst(rst_cmd),
        .read_req(read_req), .bank(read_bank), .row(read_row), .col(read_col),
        .busy(read_busy),
        .cmd_valid(rseq_cmd_valid), .cmd_cs_ras_cas_we(rseq_cmd_cs_ras_cas_we),
        .cmd_ba(rseq_cmd_ba), .cmd_addr(rseq_cmd_addr),
        .read_start(rseq_read_start)
    );

    wire real_read_active;
    ddr3_read_burst_ext RDACT (
        .clk(sclk), .rst(rst_cmd),
        .read_start(rseq_read_start), .read_active(real_read_active)
    );

    // Real command mux into ddr3_phy_ecp5.v - mutually exclusive by
    // construction, not by an added arbitration state machine: SEQ only
    // asserts cmd_valid before init_ready, WSEQ/RSEQ only start after
    // calib_done, which cannot happen before init_ready. cmd_cke/
    // cmd_reset_n/cmd_odt need no muxing - WSEQ/RSEQ don't drive them at
    // all, and SEQ's own registers already hold their correct real
    // post-init steady-state values forever (ddr3_init_seq.v's own
    // S_READY state never reassigns them).
    wire        phy_cmd_valid = seq_cmd_valid | wseq_cmd_valid | rseq_cmd_valid;
    wire [2:0]  phy_cmd_cs_ras_cas_we = seq_cmd_valid  ? seq_cmd_cs_ras_cas_we :
                                         wseq_cmd_valid ? wseq_cmd_cs_ras_cas_we :
                                                           rseq_cmd_cs_ras_cas_we;
    wire [2:0]  phy_cmd_ba   = seq_cmd_valid  ? seq_cmd_ba   :
                                wseq_cmd_valid ? wseq_cmd_ba  : rseq_cmd_ba;
    wire [15:0] phy_cmd_addr = seq_cmd_valid  ? seq_cmd_addr :
                                wseq_cmd_valid ? wseq_cmd_addr : rseq_cmd_addr;

    ddr3_phy_ecp5 PHY (
        .clk(sclk), .rst(rst_all),
        .cmd_valid(phy_cmd_valid), .cmd_cs_ras_cas_we(phy_cmd_cs_ras_cas_we),
        .cmd_ba(phy_cmd_ba), .cmd_addr(phy_cmd_addr),
        .cmd_cke(seq_cmd_cke), .cmd_reset_n(seq_cmd_reset_n), .cmd_odt(seq_cmd_odt),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt)
    );

    // Real write-data capture, at real request time - matching how
    // ddr3_write_seq.v's own bank/row/col inputs only need to be valid
    // for the one cycle write_req pulses, not held throughout. Neither
    // command sequencer carries its own data path.
    reg [7:0] write_data_latch;
    always @(posedge sclk or posedge rst_cmd) begin
        if (rst_cmd) write_data_latch <= 8'b0;
        else if (write_req && !write_busy) write_data_latch <= write_data;
    end

    wire dqsr90, dqsw, dqsw270, burstdet;

    // Real read_active mux - mutually exclusive the same way the
    // command mux above is: CALIB's own read_active only fires during
    // calibration, real_read_active only fires after calib_done.
    wire read_active_final = read_active | real_read_active;

    ddr3_dqs_ecp5 DQS (
        .eclk(eclk), .sclk(sclk), .rst(rst_all),
        .dqs_pad_i(ddr3_dqs), .read_active(read_active_final), .readclksel(readclksel),
        .dqsr90(dqsr90), .dqsw(dqsw), .dqsw270(dqsw270),
        .datavalid(datavalid), .burstdet(burstdet), .dll_locked(dll_locked)
    );

    // Part 5/9: real DQS write-drive, triggered by whichever of
    // CALIB's own wr_en or WSEQ's own write_start fires - mutually
    // exclusive by the same real sequencing (calibration completes
    // before any real command-driven write can start).
    wire dqs_wr_o, dqs_wr_oe;
    wire write_start_final = wr_en | wseq_write_start;

    ddr3_dqs_write_ecp5 DQS_WR (
        .sclk(sclk), .eclk(eclk), .dqsw(dqsw), .rst(rst_all),
        .write_start(write_start_final),
        .dqs_o(dqs_wr_o), .dqs_oe(dqs_wr_oe)
    );

    assign ddr3_dqs = dqs_wr_oe ? dqs_wr_o : 1'bz;

    wire [7:0] dq_o, dq_oe, dq_i;
    wire [7:0] rd_q3, rd_q2, rd_q1;

    // Real write-data mux: CALIB's own wr_d0 during calibration,
    // write_data_latch for a real command-driven write - mutually
    // exclusive the same way write_start_final's own two sources are.
    wire [7:0] wr_data_final = wr_en ? wr_d0 : write_data_latch;

    ddr3_dq_serdes_ecp5 #(.DQ_WIDTH(8)) SERDES (
        .sclk(sclk), .eclk(eclk), .rst(rst_all),
        .dqsr90(dqsr90), .dqsw270(dqsw270),
        .wr_d3(wr_data_final), .wr_d2(wr_data_final),
        .wr_d1(wr_data_final), .wr_d0(wr_data_final),
        .wr_en(write_start_final),
        .rd_q3(rd_q3), .rd_q2(rd_q2), .rd_q1(rd_q1), .rd_q0(rd_q0),
        .dq_o(dq_o), .dq_oe(dq_oe), .dq_i(dq_i)
    );

    // Real read result. `rd_q0` is itself a registered capture of
    // `dq_i` (rtl/soc/ddr3_dq_serdes_ecp5.v's own simulation body) -
    // one real cycle behind `dq_i` becoming valid, which is itself one
    // cycle behind `mem_dq_oe`/`real_read_active` first asserting.
    // `real_read_active`'s own window is 2 real cycles wide
    // (rtl/soc/ddr3_read_burst_ext.v) - a first fix here simply
    // registered `datavalid && real_read_active` by one cycle, which
    // produced a real, observed 2-cycle-wide `read_data_valid` pulse
    // where only its SECOND cycle actually aligned with `rd_q0` being
    // correct (confirmed by tracing a real cycle-by-cycle probe, not
    // assumed) - a test sampling on the first true cycle would still
    // capture stale `z` data. Fixed properly: `read_data_valid` is a
    // real, single-cycle pulse on `real_read_active`'s own falling
    // edge (exactly the cycle `rd_q0` first reflects real, settled
    // data), gated on whether `datavalid` was ever asserted at any
    // point during the window that just closed - re-verified against
    // the same real probe before trusting it.
    reg real_read_active_prev;
    always @(posedge sclk or posedge rst_all) begin
        if (rst_all) real_read_active_prev <= 1'b0;
        else         real_read_active_prev <= real_read_active;
    end
    wire read_active_falling = real_read_active_prev && !real_read_active;

    reg datavalid_seen;
    always @(posedge sclk or posedge rst_all) begin
        if (rst_all)                datavalid_seen <= 1'b0;
        else if (real_read_active)  datavalid_seen <= datavalid_seen | datavalid;
        else                        datavalid_seen <= 1'b0;
    end

    assign read_data       = rd_q0;
    assign read_data_valid = read_active_falling && datavalid_seen;

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : DQ_PIN
            assign ddr3_dq[i] = dq_oe[i] ? dq_o[i] : 1'bz;
            assign dq_i[i]    = ddr3_dq[i];
        end
    endgenerate
endmodule
