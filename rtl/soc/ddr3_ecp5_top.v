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
// ---- Part 11: real refresh, wired in and arbitrated one way, not
// both ----
// `rtl/soc/ddr3_refresh_ctrl.v` (Part 10) is wired into the same
// command mux, gated on `!write_busy && !read_busy` - a real refresh
// only starts once neither command sequencer has an in-flight
// transaction, so its own real REFRESH command never contends with a
// real ACT/WR/RD for the shared `cmd_*` bus. Part 11 built only that
// direction; the reverse (a new `write_req`/`read_req` starting while a
// refresh is pending or mid-tRFC) is Part 12, below.
//
// ---- Part 12: the reverse direction - new requests are held off while
// a refresh is pending or running ----
// Micron's own MT41K256M16 datasheet (Figure 40, note 5): "Only NOP and
// DES commands are allowed after a REFRESH command and until tRFC (MIN)
// is satisfied." Part 11 left this unenforced. The design decision it
// named - gate the request (risking a caller's own pulse being silently
// missed) or queue it - is resolved here by a third option that needs
// neither: the caller-visible `write_busy`/`read_busy` rise one cycle
// BEFORE the request gate actually closes.
//   refresh_hold   = refresh_req | refresh_busy  (contiguous from the
//                    first cycle a refresh is due to one cycle past the
//                    end of tRFC, since refresh_req falls exactly as
//                    refresh_busy rises)
//   refresh_hold_d = refresh_hold, registered - this is what actually
//                    gates `write_req`/`read_req` at the sequencers
//   write_busy     = write sequencer busy | refresh_hold   (likewise read)
// A caller that respects `busy` decides in cycle t-1 and presents its
// request in cycle t; it is only ever ignored if `refresh_hold_d` is high
// in cycle t, which means `refresh_hold` was high in cycle t-1, which
// means the caller saw `busy` and never presented. Not dropped, not
// queued. A caller that ignores `busy` entirely is simply ignored while
// the gate is closed - the ordinary ready/valid contract, stated here
// rather than left implied.
// `refresh_grant` gains one term for the same reason: it requires
// `refresh_hold_d`, i.e. the gate is already closed in the cycle grant is
// given. Without it, a request accepted in the very cycle `refresh_req`
// first appears would start a transaction in the same cycle refresh
// commits - the exact tRFC violation this part exists to close.
// The sequencers' own `busy` (not the caller-visible one) still feeds
// `refresh_grant`: the caller-visible one includes `refresh_hold`, which
// refresh itself raises, so using it would deadlock refresh against its
// own request.
// `write_data_latch` must use the same gated accept condition the
// sequencer does; if it used the caller-visible `write_busy` instead, a
// request accepted in that first boundary cycle would leave the latch
// holding stale data.
//
// ---- Part 13: at most one transaction in flight ----
// Part 12's probe found that a write and a read in flight together
// collide silently. Every request is now either fully accepted or fully
// ignored: a request is accepted only if neither sequencer is busy and no
// refresh holds the bus, and in the same cycle a write beats a read.
//   wseq_write_req = write_req & ~refresh_hold_d & ~wseq_busy & ~rseq_busy
//   rseq_read_req  = read_req  & ~refresh_hold_d & ~wseq_busy & ~rseq_busy
//                             & ~wseq_write_req
// `write_busy` and `read_busy` are now the same value (either sequencer
// busy, or a refresh holding the bus), so a caller waiting on its own
// direction's busy is safe against the other. Callers still present one
// request at a time; a blind caller is ignored while the gate is closed.
// The sweep that proved this also found a latent bug from Part 6: a
// sequencer is back in S_IDLE one cycle before its `busy` drops, and a
// request presented in that cycle was accepted while `write_data_latch`
// kept the previous write's data - stale data written to memory. Gating on
// the sequencer's own busy closes it.
//
// ---- Part 14: every transaction closes its bank ----
// Micron's datasheet: a row "remains open (or active) for accesses until a
// PRECHARGE command is issued to that bank. A PRECHARGE command must be
// issued before opening a different row in the same bank", its state
// diagram (Figure 2) has ACT leaving only the Idle state, and REFRESH
// needs every bank precharged (Figure 40: PRECHARGE-all, then tRP, then
// REFRESH). Until Part 14 nothing here ever issued PRECHARGE: Part 9's own
// write-then-read round trip opened a bank and then activated it again.
// Nothing in simulation could see that until sim/ddr3_model.v grew per-bank
// state (sim/tb_ddr3_model_banks.v proves each of its rules can fire).
// ddr3_write_seq.v and ddr3_read_seq.v now each end by issuing
// PRECHARGE-all after the data phase, at the datasheet minimum plus one
// cycle, and hold `busy` through it. The result is an invariant this file
// relies on: whenever both sequencers are idle, every bank is closed - so
// a REFRESH granted while they are idle is legal by construction, with no
// change to the refresh path. tRP is under one cycle at this clock and is
// covered by the FSMs themselves (measured 3 cycles PRECHARGE-to-ACT for
// the fastest possible caller); it has no wait state of its own.
//
// ---- Part 16: CK at the edge-clock rate, two command phases per sclk ----
// The Part 14/15 survey measured that CK rose once per sclk while the DQ
// serdes moves four UI per sclk. Lattice's own reference DDR3 write side
// (FPGA-TN-02035, Figure 6.10) generates CK at the edge-clock rate - twice
// sclk - and address/command with two values per sclk, one per CK cycle.
// This design now does the same (see rtl/soc/ddr3_phy_ecp5.v): `eclk` is
// passed to the PHY, CK runs at 50 MHz here, and every command is driven in
// the first of the two slots of its sclk cycle. The controller still issues
// at most one command per sclk, so nothing above the PHY changes shape; what
// changes is that a CK-counted latency converts exactly (CL = CWL = 6 CK is
// 3 sclk, not 6), so CL_CYC and CWL_CYC in the two sequencers, and the
// PRECHARGE spacings that follow from them, are recounted. The protocol
// model and the memory model now sample commands on CK's rising edge.
// The simulation-model gap that survey named is NOT closed here: the memory
// model still drives read data when told rather than at the DRAM's own read
// latency, so a wrong CL or CWL is caught only by the standalone sequencer
// tests, not by the integrated ones.
//
// Still not attempted: bank-state tracking in the controller (this design
// still opens and closes a bank around every access rather than
// exploiting open rows), the second DQ byte lane, and real hardware
// bring-up - see docs/roadmap.md's own Part 9/10/11/12/13/14 accounts for
// the full list of what this does not establish.
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

    // ---- Part 10: real refresh, observability only - see header ----
    output wire        refresh_busy,

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

    // Part 12: see header. Declared ahead of the sequencers, which they
    // gate, and the refresh scheduler below, which drives them.
    wire refresh_req;
    wire refresh_hold = refresh_req | refresh_busy;
    reg  refresh_hold_d;
    always @(posedge sclk or posedge rst_cmd) begin
        if (rst_cmd) refresh_hold_d <= 1'b0;
        else         refresh_hold_d <= refresh_hold;
    end

    // Part 13: at most one transaction in flight. A request is accepted
    // only if neither sequencer is busy and no refresh holds the bus, and
    // in the same cycle a write beats a read. Gating on the sequencer's
    // OWN busy too (not just the other's) closes a latent stale-data
    // hazard: a sequencer is back in S_IDLE one cycle before its `busy`
    // drops, and a request presented in that cycle used to be accepted
    // while `write_data_latch` (which only captured when not busy) kept
    // the previous write's data.
    wire wseq_busy, rseq_busy;
    wire wseq_write_req = write_req & ~refresh_hold_d & ~wseq_busy & ~rseq_busy;
    wire rseq_read_req  = read_req  & ~refresh_hold_d & ~wseq_busy & ~rseq_busy & ~wseq_write_req;
    // Both ports carry the same value on purpose: a caller waiting on its
    // own direction's busy must be safe against the other direction too.
    assign write_busy = wseq_busy | rseq_busy | refresh_hold;
    assign read_busy  = wseq_busy | rseq_busy | refresh_hold;

    wire        wseq_cmd_valid;
    wire [2:0]  wseq_cmd_cs_ras_cas_we;
    wire [2:0]  wseq_cmd_ba;
    wire [15:0] wseq_cmd_addr;
    wire        wseq_write_start;

    ddr3_write_seq WSEQ (
        .clk(sclk), .rst(rst_cmd),
        .write_req(wseq_write_req), .bank(write_bank), .row(write_row), .col(write_col),
        .busy(wseq_busy),
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
        .read_req(rseq_read_req), .bank(read_bank), .row(read_row), .col(read_col),
        .busy(rseq_busy),
        .cmd_valid(rseq_cmd_valid), .cmd_cs_ras_cas_we(rseq_cmd_cs_ras_cas_we),
        .cmd_ba(rseq_cmd_ba), .cmd_addr(rseq_cmd_addr),
        .read_start(rseq_read_start)
    );

    wire real_read_active;
    ddr3_read_burst_ext RDACT (
        .clk(sclk), .rst(rst_cmd),
        .read_start(rseq_read_start), .read_active(real_read_active)
    );

    // Part 11/12: real refresh scheduling - see header for the real,
    // two-directional arbitration this integration provides. Grant uses
    // the sequencers' own busy (not the caller-visible one, which
    // includes refresh_hold and would deadlock) and requires the request
    // gate to already be closed.
    wire        refresh_grant = !wseq_busy && !rseq_busy && refresh_hold_d;
    wire        refresh_cmd_valid;
    wire [2:0]  refresh_cmd_cs_ras_cas_we;
    wire [2:0]  refresh_cmd_ba;
    wire [15:0] refresh_cmd_addr;

    ddr3_refresh_ctrl REFRESH (
        .clk(sclk), .rst(rst_cmd),
        .refresh_grant(refresh_grant),
        .refresh_req(refresh_req), .busy(refresh_busy),
        .cmd_valid(refresh_cmd_valid), .cmd_cs_ras_cas_we(refresh_cmd_cs_ras_cas_we),
        .cmd_ba(refresh_cmd_ba), .cmd_addr(refresh_cmd_addr)
    );

    // Real command mux into ddr3_phy_ecp5.v - mutually exclusive by
    // construction, not by an added arbitration state machine: SEQ only
    // asserts cmd_valid before init_ready, WSEQ/RSEQ only start after
    // calib_done, which cannot happen before init_ready, and REFRESH
    // only asserts cmd_valid once granted, which only happens when
    // neither WSEQ nor RSEQ is busy.
    //
    // That holds for every pair: SEQ vs the rest, REFRESH vs WSEQ/RSEQ
    // (Part 11/12), and - since Part 13 - WSEQ vs RSEQ, which the gate
    // above keeps from ever being in flight together. Before Part 13 it
    // did not hold for that last pair and the fixed priority below hid it
    // rather than catching it: a `write_req` and `read_req` presented in
    // the same cycle ran in lockstep, the pins carried only the write's
    // ACT and WR, the read's never reached the DRAM yet its `read_start`
    // still pulsed and `read_data` came back `z`, with the protocol
    // checker silent because the pins looked legal.
    //
    // cmd_cke/cmd_reset_n/cmd_odt need
    // no muxing - none of WSEQ/RSEQ/REFRESH drive them at all, and
    // SEQ's own registers already hold their correct real post-init
    // steady-state values forever (ddr3_init_seq.v's own S_READY state
    // never reassigns them).
    wire        phy_cmd_valid = seq_cmd_valid | wseq_cmd_valid | rseq_cmd_valid | refresh_cmd_valid;
    wire [2:0]  phy_cmd_cs_ras_cas_we = seq_cmd_valid     ? seq_cmd_cs_ras_cas_we :
                                         wseq_cmd_valid    ? wseq_cmd_cs_ras_cas_we :
                                         rseq_cmd_valid    ? rseq_cmd_cs_ras_cas_we :
                                                              refresh_cmd_cs_ras_cas_we;
    wire [2:0]  phy_cmd_ba   = seq_cmd_valid  ? seq_cmd_ba   :
                                wseq_cmd_valid ? wseq_cmd_ba  :
                                rseq_cmd_valid ? rseq_cmd_ba  : refresh_cmd_ba;
    wire [15:0] phy_cmd_addr = seq_cmd_valid  ? seq_cmd_addr :
                                wseq_cmd_valid ? wseq_cmd_addr :
                                rseq_cmd_valid ? rseq_cmd_addr : refresh_cmd_addr;

    ddr3_phy_ecp5 PHY (
        .clk(sclk), .eclk(eclk), .rst(rst_all),
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
        else if (wseq_write_req) write_data_latch <= write_data;
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
