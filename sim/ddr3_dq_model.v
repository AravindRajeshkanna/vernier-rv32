// Behavioral DDR3 data (DQ/DQS) model - Phase 9 Stage 1, Part 2, made
// address-decoded in Part 15 (docs/roadmap/phase-09-ddr.md).
//
// Through Part 14 this stored ONE byte at a fixed test location, so no test
// could see a write land in the wrong bank, row or column: a bug anywhere in
// the address path would have passed every DDR3 test. It now watches the
// same real command pins the protocol checker (sim/ddr3_model.v) watches, to
// learn WHERE data goes: an ACTIVATE records the open row of its bank, and a
// WRITE or READ records (bank, that bank's open row, column). The data phase
// - the write burst a CWL later, the read burst a CL later - then lands in, or comes
// from, that location. Pairing a data phase with the most recent WR/RD
// command is sound because the controller keeps at most one transaction in
// flight (Part 13); this file relies on it.
//
// The address is decoded the way the part decodes it, not the way the
// controller's interface is wide: Micron's own Table 2 for the 256 Meg x 16
// device (32 Meg x 16 x 8 banks) gives row A[14:0], bank BA[2:0] and column
// A[9:0]. So row bit 15 and column bits 10 and up are not part of the
// address (A10 is auto-precharge, A11 and A13-A15 are unused for x16, A12
// is BC#); two requests differing only there hit the same cell, exactly as
// on the real part.
//
// Storage is a small content-addressable table, since Icarus has no usable
// associative arrays. A location never written reads back as `x`, on
// purpose: a read that returns stale data from somewhere else would
// otherwise look like a hit.
//
// Through Phase 9 Stage 2 data written before any command had been seen went to one separate "calibration"
// cell, and a read window opened with no READ was answered from it: that is what the calibration's injected write
// burst and read_active needed, since it issued no DRAM command at all. The calibration is command-driven now
// (rtl/soc/ddr3_read_calib.v, Stage 3): it writes and reads a real column through the controller's own sequencers, so the
// cell is gone, a read window with no READ behind it is answered with nothing, and a strobe outside a WRITE's burst is
// an error whenever it happens, not only after the first command. `read_active` is still an input so the testbenches'
// connection lists stay as they were; it is no longer read.
//
// ---- Part 17: writes are checked against the DRAM's own write latency,
// from the pins ----
// Until Part 17 the write side stored `wr_d0` on an internal `wr_en` tap: it
// never looked at DQ or DQS, so a burst landing anywhere relative to its WRITE
// command was accepted. The Part 14/15 survey measured that DQ was enabled for
// one cycle, one cycle before DQS was enabled and two before its first active
// toggle - and every test passed. It now works from what the DRAM would see: the
// command pins, and the resolved DQ and DQS pins.
//
// For a WRITE sampled in sclk cycle W (Part 16: commands sit in the first
// command slot, so W is the cycle it is driven in), the datasheet's write
// latency is WL = CWL = 6 CK = 3 sclk, so the first DQS rising edge falls 10 ns
// into cycle W+3. At this file's sclk resolution that means, exactly:
//     W+2  preamble    DQS driven low (a full sclk, 2 CK, over the 0.9 tCK minimum)
//     W+3  burst, half 1   DQS active, DQ driven      (beats 0-3)
//     W+4  burst, half 2   DQS active, DQ driven      (beats 4-7)
//     W+5  postamble   DQS driven low
// and DQS must be high-Z in every other cycle once commands have started. A
// burst that lands anywhere else, or DQ not driven while DQS is active, sets
// `dq_error`. Data is stored from the first burst cycle only if that cycle itself
// looked valid, so a burst that never opens validly leaves the cell unwritten
// (x) - which is what made calibration itself fail against the unaligned design.
// A burst shifted by exactly one cycle can still store, since one of its cycles
// lands where the first half was expected: for that case `dq_error` is the
// verdict, which is why every integrated test reads it.
//
// Honest scope: at sclk resolution the pins carry one DQ word per cycle, so
// beat order within a cycle is not visible, and the byte stored is the one on
// the pins in the first half of the burst - beats 1-7 are ignored, as if the
// data mask covered them. That is a stand-in for real BL8 semantics (an
// unmasked burst writes eight columns) and lasts until the data-mask slice.
//
// ---- Part 18: reads are driven at the DRAM's own read latency ----
// Through Part 17 the read side was self-referential: the model drove DQ and DQS
// whenever the DUT said `read_active`, so nothing about the read path depended on
// when a real DRAM would respond - and a wrong CL passed every integrated test.
// For a READ sampled in sclk cycle R the model now schedules the burst itself,
// from the command. In DLL-off mode Micron gives read data "AL + CL - 1 cycles
// after the READ command" (5 CK), with tDQSCK of 1-10 ns after that, so the first
// DQS edge falls 110-120 ns into cycle R: at sclk resolution
//     R+2  preamble        DQS driven low, DQ still high-Z
//     R+3  burst, half 1   DQS high, DQ = beat 0's byte (the addressed column)
//     R+4  burst, half 2   DQS high, DQ = beat 4's byte
//     R+5  postamble       DQS driven low
// Beat 4 is the byte at column {col[9:3], col[2:0] ^ 3'b100}: BL8 in sequential
// order from column c returns columns c, c+1 ... wrapping within the aligned 8, so
// beat 4 is four columns on (wrapping), and the two halves DIFFER unless those two
// columns hold the same byte. That is the point: with both halves equal a capture
// one cycle late would still return the right byte. A neighbour column never
// written returns 00 - unlike the addressed column, which reads x when unwritten
// so that a stale read cannot pass as a hit - because this is a different, defined
// cell content rather than an undriven bus.
// Quantised to whole sclk cycles, the tDQSCK spread (up to 10 ns) is invisible;
// sub-cycle capture alignment is what the READCLKSEL calibration is for.
// (Until Stage 3, calibration's reads issued no READ command and the model answered `read_active` itself while it had
// seen no command; the calibration's reads are real READs now and that is gone: see above.)
//
// What this does and does not catch, measured (Part 18): a READ window at the wrong
// cycle now returns the wrong byte, or an unknown one, so a wrong CL fails the
// integrated tests through the data. The DQSBUFM stand-in in
// rtl/soc/ddr3_dqs_ecp5.v still ignores the DQS pin - its DATAVALID and BURSTDET
// follow the DUT's own `read_active` - and making DATAVALID require DQS high was
// tried and changed no test outcome, so it was left out.
//
// DQS is modeled as a genuinely source-synchronous signal: it is driven only around
// a burst (the preamble, the burst, the postamble) and high-Z otherwise, the
// behavior `rtl/soc/ddr3_dqs_ecp5.v`'s own `READ0`/`READ1` gating depends on, not a
// free-running clock.
//
// ---- Part 22: the data mask, and the hazard it exists to prevent ----
// Through Part 21 nothing drove a data-mask pin at all, and this model's own write side
// only ever stored from the first burst half - the second was "ignored, as if the data
// mask covered them" (Part 17's own words). That was never checked: the model simply
// never modeled the second half touching a column at all, so nothing could show whether
// it actually would. It now does. Real BL8 sequential order from the addressed column c
// wraps within the aligned block of 8, so the second sclk-visible half - at this design's
// own sclk resolution, standing in for the other seven real UI, the same simplification
// Part 18 uses for reads - lands on column {c[9:3], c[2:0]^3'b100}, the same neighbour
// Part 18's read side already names. Measured, before any design change: with the second
// half's DM pin unmasked, that neighbour column receives whatever byte the burst carries -
// a real, previously undemonstrated hazard (`docs/roadmap/phase-09-ddr.md`'s "A caveat on Part 15" had
// named the risk; nothing had shown it happening). `rtl/soc/ddr3_dm_drv_ecp5.v` now drives
// DM low only for the first half and high for the second, and this file's own write-burst
// storage now honors it: the first half stores only if DM is not explicitly high there
// (masking the very beat meant to write is a design defect - the byte is lost, not stored,
// which a correctness check surfaces the same way Part 18's wrong-CL did); the second half
// stores to the NEIGHBOUR column only if DM is explicitly low there (unmasked - the
// corruption case). `dm_pin` left unconnected (`z`, what every testbench predating Part 22
// does) means neither condition is ever true - the first half stores exactly as before, and
// the second still touches nothing, so no existing test's behaviour changes.
//
// This is still not real per-UI BL8 fidelity: only two of the eight real UI have any
// modeled effect, matching every other simplification in this file, and each is honestly
// named rather than silently assumed.
//
// ---- Phase 9 Stage 3: the write side is judged beat by beat ----
// Everything above this section that says "at sclk resolution" about WRITES is history: the write side now samples DQ and
// DM on every DQS edge, as the part does, and it is the strobe that decides what is written. A WRITE sampled on CK's
// rising edge at time t expects its first DQS rising edge at t + CWL x tCK (CWL = 6, the controller's MR2), within
// tDQSS (+-0.25 tCK), and then an edge every half CK: eight edges, rising then falling, one per beat. At each edge the
// byte on DQ and the level on DM are taken as that beat's. When the eighth edge has come the burst is written: beat b goes
// to column {c[9:3], (c[2:0] + b) mod 8} (sequential burst order from the addressed column c, wrapping inside the aligned
// block of 8), if DM was low for it. So a burst whose DM is low on beat 0 and high on the other seven stores one column, and
// one whose DM is low for beats 0 to 3 stores four, which is the hazard the data mask exists to prevent and which the
// earlier two-sample model could not show. A `dm_pin` left unconnected (`z`) means no information: beat 0 stores and the
// others do not, as before.
// DQ and DM must be steady for 2 ns before each strobe edge and 2 ns after it (tDS, tDH: coarse, the part's are a few hundred
// picoseconds; the design launches them half a UI, 5 ns, ahead of the edge, which is what puts the edge in the middle of the beat).
// The strobe's own protocol is checked: it must be driven low for 0.9 tCK or more before the first rising edge and (the
// controller drives it from 2.5 tCK before) no more than 3 tCK, must carry exactly eight edges at the expected times with
// the right polarity, must stay low for 0.4 tCK after the last, and must be high-Z otherwise. DQ must be known at every
// beat DM does not mask.
//
// ---- Phase 9 Stage 3: the read side is driven beat by beat ----
// The Part 18 text above (a strobe held high, DQ with beat 0's byte for one sclk and beat 4's for the next) is history: a READ
// sampled in sclk cycle R still starts its burst at R+3 (the first strobe edge, the rising one, on the sclk edge that begins
// R+3: 10 ns into the READ's own CK edge, five CK of latency, and tDQSCK at the top of its 1 to 10 ns range), but the part now
// answers as a part does. DQS is driven low in R+2 (the preamble), then toggles every half CK: eight edges, the first rising,
// the last falling, 10 ns apart, in R+3 and R+4; it stays low through R+5 (the postamble) and is high-Z after. DQ carries
// beat b from tDQSQ (1 ns) after strobe edge b until the next one, so it is edge-aligned with the strobe, as a DRAM drives it:
// the controller's capture finds the middle of each beat from the strobe's phase, and the stand-in for it (rtl/soc/
// ddr3_dq_serdes_ecp5.v) samples 5 ns after each edge. Beat b is column {c[9:3], (c[2:0] + b) mod 8}, the sequential burst order
// from the addressed column c: the byte stored there, 00 for a column never written, except beat 0 (the addressed column
// itself), which reads as unknown if it was never written, so that a stale read cannot pass as a hit.
`timescale 1ns/1ps
module ddr3_dq_model #(
    parameter DEPTH = 1024,
    parameter real TCK_NS = 20.0,   // CK's period: the controller's eclk, twice sclk
    parameter CWL_CK = 6            // MR2's CWL (rtl/soc/ddr3_init_seq.v)
)(
    input  wire       sclk,
    input  wire       rst,

    // the real DDR3 command pins, watched only to learn where data goes.
    // Commands are sampled on CK's rising edge, as the DRAM does; the data
    // phase below stays on sclk.
    input  wire       ck,
    input  wire       ras_n,
    input  wire       cas_n,
    input  wire       we_n,
    input  wire [2:0] ba,
    input  wire [14:0] a,

    // the resolved DQ and DQS pins - what the DRAM sees when the controller drives.
    // `inout`, though this module never drives them (its own drive is the mem_* outputs
    // below): Verilator rejects a tri-state net connected to an `input` port and accepts
    // it on an `inout`, and reads high-Z correctly through one. Icarus needs a net, not a
    // reg, on the other side of an inout - see sim/tb_ddr3_dq_window_rules.v.
    inout  wire [7:0] dq_pin,
    inout  wire       dqs_pin,
    // Part 22: high = mask (do not write this beat), low = write it, `z` (left
    // unconnected, as in every testbench predating Part 22) = no information - see the
    // header for exactly what each of those three does and does not change.
    // `inout` like the others: the model compares it to `z` now (Phase 9 Stage 3), which Verilator reads correctly
    // through an inout and refuses through an input.
    inout  wire       dm_pin,

    input  wire       read_active,
    output reg  [7:0] mem_dq_o,
    output reg        mem_dq_oe,
    output reg        mem_dqs_oe,    // DQS is driven low in the preamble while DQ is still high-Z
    output reg        mem_dqs_o,

    output reg          dq_error,      // sticky: a write burst broke the DRAM's own timing
    output reg  [511:0] dq_error_msg
);
    // No CS#: the board ties it low (see sim/ddr3_model.v), so these three codes are decoded in
    // every slot, and an idle slot is the NOP (all three high) that none of them matches.
    wire is_act = !ras_n &&  cas_n &&  we_n;
    wire is_wr  =  ras_n && !cas_n && !we_n;
    wire is_rd  =  ras_n && !cas_n &&  we_n;

    // per-bank open row, from ACTIVATE
    reg [14:0] open_row  [0:7];
    reg        row_known [0:7];

    // the location the current/most recent WR or RD command addressed
    reg        cur_valid;
    reg [2:0]  cur_bank;
    reg [14:0] cur_row;
    reg [9:0]  cur_col;

    // content-addressable store
    reg        k_used [0:DEPTH-1];
    reg [2:0]  k_bank [0:DEPTH-1];
    reg [14:0] k_row  [0:DEPTH-1];
    reg [9:0]  k_col  [0:DEPTH-1];
    reg [7:0]  k_data [0:DEPTH-1];
    integer    n_used;
    reg        overflowed;

    integer i;

    // ---- read-burst expectations (Part 18) ----
    // `cyc` counts sclk cycles; a READ sampled in cycle R schedules what the model drives in R+2..R+5 (see the header).
    // Indexed mod 8, consumed as each cycle ends.
    integer    cyc;
    reg [2:0]  rdexp [0:7];  // 0 nothing, 1 preamble, 2 burst half 1, 3 burst half 2, 4 postamble
    reg [2:0]  rd_ph;        // the entry for the cycle that has just begun: what the beat driver below does in it
    localparam real TDQSQ_NS = 1.0;   // DQ is valid this long after the strobe edge it belongs to

    task dq_fail(input [511:0] msg);
        begin
            if (!dq_error) begin
                dq_error     <= 1'b1;
                dq_error_msg <= msg;
            end
        end
    endtask

    // index of a location, or -1
    function integer find(input [2:0] b, input [14:0] r, input [9:0] c);
        integer j;
        begin
            find = -1;
            for (j = 0; j < n_used; j = j + 1)
                if (k_used[j] && k_bank[j] === b && k_row[j] === r && k_col[j] === c)
                    find = j;
        end
    endfunction

    // what a read of the current location returns
    function [7:0] current_value(input dummy);
        integer j;
        begin
            if (!cur_valid) current_value = 8'hxx;
            else begin
                j = find(cur_bank, cur_row, cur_col);
                current_value = (j < 0) ? 8'hxx : k_data[j];
            end
        end
    endfunction

    // beat k of a BL8 read in sequential order from the addressed column: k columns on, wrapping in the aligned 8. The
    // addressed column itself (beat 0) is unknown if it was never written; any other column reads 00 then, a defined cell
    // content rather than an undriven bus.
    function [7:0] read_beat(input integer k);
        integer j;
        begin
            if (k == 0) read_beat = current_value(1'b0);
            else begin
                j = find(cur_bank, cur_row, {cur_col[9:3], cur_col[2:0] + k[2:0]});
                read_beat = (j < 0) ? 8'h00 : k_data[j];
            end
        end
    endfunction

    task store_at(input [2:0] b, input [14:0] r, input [9:0] c, input [7:0] d);
        integer j;
        begin
            j = find(b, r, c);
            if (j < 0) begin
                if (n_used >= DEPTH) begin
                    overflowed = 1'b1;
                    $display("ddr3_dq_model: store full (%0d locations) - raise DEPTH", DEPTH);
                end else begin
                    j = n_used;
                    n_used = n_used + 1;
                    k_used[j] = 1'b1;
                    k_bank[j] = b;
                    k_row[j]  = r;
                    k_col[j]  = c;
                end
            end
            if (j >= 0) k_data[j] = d;
        end
    endtask

    task store_current(input [7:0] d);
        begin
            if (cur_valid) store_at(cur_bank, cur_row, cur_col, d);
        end
    endtask

    // For testbenches: what is stored at a location, given the caller's own
    // (wider) bank/row/column values, decoded the way the part decodes them.
    // `x` if never written.
    function [7:0] peek(input [2:0] b, input [15:0] r, input [15:0] c);
        integer j;
        begin
            j = find(b, r[14:0], c[9:0]);
            peek = (j < 0) ? 8'hxx : k_data[j];
        end
    endfunction

    // ---- the write side's state (Phase 9 Stage 3; the process is below the command capture) ----
    localparam NW = 4;                 // WRITE commands that can be waiting for their burst at once
    localparam real UI_NS  = TCK_NS / 2.0;
    localparam real TOL_NS = TCK_NS / 4.0;      // tDQSS: +-0.25 tCK
    localparam real EPS_NS = 0.01;
    reg        wq_v    [0:NW-1];       // an entry is waiting for / in its burst
    real       wq_t    [0:NW-1];       // when its first DQS rising edge is due
    reg [2:0]  wq_bank [0:NW-1];
    reg [14:0] wq_row  [0:NW-1];
    reg [9:0]  wq_col  [0:NW-1];
    integer    wq_n    [0:NW-1];       // DQS edges seen so far
    real       wq_last [0:NW-1];       // when the last one was
    reg [7:0]  wq_dq   [0:NW*8-1];     // the byte on DQ at each beat
    reg [1:0]  wq_dm   [0:NW*8-1];     // DM at each beat: 0 low (write), 1 high (masked), 2 z (no information), 3 x
    reg        wq_bad  [0:NW*8-1];     // some DQ bit was not driven (z or x) at that beat
    integer    wq_slot;

    reg [1:0]  dqs_s1, dqs_s2;         // DQS at the last two CK rising edges: 0 low, 1 high, 2 z, 3 x
    reg [1:0]  dqs_ev_prev;            // DQS the last time it moved
    real       t_dqdm_change;          // when DQ or DM last changed
    real       t_edge_last;            // when the last accepted write strobe edge fell
    localparam real TDS_NS = 2.0;      // DQ/DM setup before a strobe edge, and hold after it: coarse (the part's are
    localparam real TDH_NS = 2.0;      // hundreds of picoseconds), against a launch half a UI (5 ns) from the edge
    reg        wq_post [0:NW-1];       // the postamble has been checked
    real       t_rd_until;             // the model's own read drive of DQS lasts until here: not the controller's
    real       ev_now, ev_delta;
    integer    ev_e, ev_i, ev_k;
    reg [1:0]  ev_cur;

    initial begin
        overflowed = 1'b0;
        n_used     = 0;
        cur_valid  = 1'b0;
        cur_bank   = 3'b0;
        cur_row    = 15'b0;
        cur_col    = 10'b0;
        for (i = 0; i < 8; i = i + 1) begin
            open_row[i]  = 15'b0;
            row_known[i] = 1'b0;
        end
        for (i = 0; i < DEPTH; i = i + 1) k_used[i] = 1'b0;
        dq_error        = 1'b0;
        dq_error_msg    = "";
        cyc             = 0;
        for (i = 0; i < 8; i = i + 1) rdexp[i] = 3'd0;
        rd_ph           = 3'd0;
        mem_dq_o        = 8'b0;
        mem_dqs_o       = 1'b0;
        for (i = 0; i < NW; i = i + 1) wq_v[i] = 1'b0;
        for (i = 0; i < NW; i = i + 1) wq_post[i] = 1'b0;
        dqs_s1 = 2'd2;
        dqs_s2 = 2'd2;
        dqs_ev_prev = 2'd2;
        t_rd_until = -1.0;
        t_dqdm_change = -1000.0;
        t_edge_last = -1000.0;
    end

    // The cycle-level part of the read drive, at the sclk edge: who drives the pins in the cycle that begins now. What
    // they carry inside the cycle is the beat driver's, below - a separate process, because an assignment made at a clock
    // edge by a process that also waits is applied at once, not at the end of the time step, by the Verilator that CI uses.
    always @(posedge sclk or posedge rst) begin
        if (rst) begin
            mem_dq_oe  <= 1'b0;
            mem_dqs_oe <= 1'b0;
            n_used     = 0;
            cyc        = 0;
            rd_ph      = 3'd0;
            for (i = 0; i < 8; i = i + 1) rdexp[i] = 3'd0;
            for (i = 0; i < DEPTH; i = i + 1) k_used[i] = 1'b0;
        end else begin
            // ---- drive for the NEXT cycle ----
            // A READ scheduled this cycle's successor (see the header); otherwise the model drives nothing.
            rd_ph = rdexp[(cyc + 1) % 8];
            case (rd_ph)
                3'd1:    begin mem_dqs_oe <= 1'b1; mem_dq_oe <= 1'b0; end
                3'd2, 3'd3: begin mem_dqs_oe <= 1'b1; mem_dq_oe <= 1'b1; end
                3'd4:    begin mem_dqs_oe <= 1'b1; mem_dq_oe <= 1'b0; end
                default: begin
                    mem_dq_oe  <= 1'b0;
                    mem_dqs_oe <= 1'b0;
                end
            endcase
            rdexp[(cyc + 1) % 8] = 3'd0;

            cyc = cyc + 1;
        end
    end

    // The beat driver: the strobe and the data inside the cycles of a read burst (the header has the timing). Everything is
    // assigned after a delay, never at the edge itself: the strobe's first rising edge is 1 ps after it.
    always @(posedge sclk) begin : RD_BEATS
        real t_base;
        reg [2:0] ph;
        integer k0;
        t_base = $realtime;
        #0.001 ph = rd_ph;
        if (ph == 3'd1 || ph == 3'd4) begin
            mem_dqs_o <= 1'b0;
        end else if (ph == 3'd2 || ph == 3'd3) begin
            k0 = (ph == 3'd2) ? 0 : 4;
            mem_dqs_o <= 1'b1;                                   // edge k0: rising
            #(t_base + TDQSQ_NS - $realtime) mem_dq_o <= read_beat(k0);
            #(t_base + UI_NS - $realtime)    mem_dqs_o <= 1'b0;  // edge k0 + 1: falling
            #(t_base + UI_NS + TDQSQ_NS - $realtime) mem_dq_o <= read_beat(k0 + 1);
            #(t_base + 2.0 * UI_NS - $realtime) mem_dqs_o <= 1'b1;
            #(t_base + 2.0 * UI_NS + TDQSQ_NS - $realtime) mem_dq_o <= read_beat(k0 + 2);
            #(t_base + 3.0 * UI_NS - $realtime) mem_dqs_o <= 1'b0;
            #(t_base + 3.0 * UI_NS + TDQSQ_NS - $realtime) mem_dq_o <= read_beat(k0 + 3);
        end
    end

    // ---- the write side, beat by beat (Phase 9 Stage 3; see the header) ----
    task commit_write(input integer e);
        integer b;
        reg [1:0] dmc;
        begin
            for (b = 0; b < 8; b = b + 1) begin
                dmc = wq_dm[e * 8 + b];
                if (dmc == 2'd3) dq_fail("write burst: DM unknown at a DQS edge");
                else if (dmc == 2'd0 || (dmc == 2'd2 && b == 0)) begin
                    if (wq_bad[e * 8 + b])
                        dq_fail("write burst: DQ not driven at a beat DM does not mask");
                    else
                        store_at(wq_bank[e], wq_row[e], {wq_col[e][9:3], wq_col[e][2:0] + b[2:0]}, wq_dq[e * 8 + b]);
                end
            end
        end
    endtask

    // The pins, classified the way sim/pin_probe.v classifies them (see that file for why): in combinational logic, on
    // an `inout` port, so that a floating pin reads as high-Z under Verilator as well as under Icarus. 0 low, 1 high, 2 z, 3 x.
    // (Continuous assignments, not an `always @*`: that does not run at time zero in Icarus, and a pin that has never moved
    // would read as unknown instead of high-Z.)
    function [1:0] code_of(input v);
        code_of = (v === 1'b0) ? 2'd0 : (v === 1'b1) ? 2'd1 : (v === 1'bz) ? 2'd2 : 2'd3;
    endfunction
    function bad_of(input [7:0] v);
        integer k;
        begin
            bad_of = 1'b0;
            for (k = 0; k < 8; k = k + 1) if (v[k] !== 1'b0 && v[k] !== 1'b1) bad_of = 1'b1;
        end
    endfunction
    wire [1:0] dqs_code = code_of(dqs_pin);
    wire [1:0] dm_code  = code_of(dm_pin);
    wire       dq_bad_c = bad_of(dq_pin);     // some DQ bit is high-Z or unknown
    wire [7:0] dq_val   = dq_pin;

    // tDH: DQ and DM must not move for TDH_NS after a strobe edge. (Reads move DQ too, but never within TDH_NS of a write edge.)
    always @(dq_pin or dm_pin) begin
        if (!rst) begin
            if ($realtime - t_edge_last < TDH_NS - EPS_NS)
                dq_fail("write burst: DQ or DM changed less than tDH after a DQS edge");
            t_dqdm_change = $realtime;
        end
    end

    // The edges (0 <-> 1) of DQS, wherever they come. Nothing here depends on seeing DQS go to or from high-Z as an event:
    // that is not reported as an event on a net by Verilator, so everything about whether DQS is DRIVEN (the preamble, the
    // postamble, a strobe nobody asked for) is judged from samples taken on CK's rising edge, below, which both simulators read
    // the same.
    always @(dqs_code) begin
        ev_cur = dqs_code;
        ev_now = $realtime;
        // an edge is a move between the two driven levels; the driver appearing (z to a level) is not one, and where a
        // simulator reports that at all it is not a beat
        if (!rst && ev_now > t_rd_until && dqs_ev_prev == 2'd2 && ev_cur == 2'd1) begin
            // the driver appears high: no preamble (where a simulator reports the appearing at all; Verilator does not)
            dq_fail("write preamble: DQS not driven low before its first rising edge");
        end else if (!rst && ev_now > t_rd_until && ev_cur != 2'd2 && (dqs_ev_prev == 2'd3 || ev_cur == 2'd3 || dqs_ev_prev != 2'd2)) begin
            if (ev_cur == 2'd3) begin
                dq_fail("DQS unknown: two drivers on it, or none and a floating net");
            end else begin
                ev_e = -1;
                for (ev_k = 0; ev_k < NW; ev_k = ev_k + 1)
                    if (wq_v[ev_k] && ev_now >= wq_t[ev_k] - TOL_NS - EPS_NS &&
                        ev_now <= wq_t[ev_k] + 7.0 * UI_NS + 2.0 * UI_NS + EPS_NS) ev_e = ev_k;
                if (ev_e < 0) begin
                    dq_fail("DQS toggled outside the burst a WRITE command asked for");
                end else begin
                    // the edge this one should be is the next in order: wq_n; where it should fall, and which way
                    ev_i = wq_n[ev_e];
                    ev_delta = ev_now - wq_t[ev_e] - ev_i * UI_NS;
                    if (ev_i >= 8)
                        dq_fail("write burst: more than eight DQS edges");
                    else if (ev_delta > TOL_NS + EPS_NS || -ev_delta > TOL_NS + EPS_NS)
                        dq_fail("write burst: a DQS edge outside tDQSS of where the WRITE puts it");
                    else begin
                        // DQS low and driven at the last two CK edges before the first rising edge: 0.9 tCK of preamble at least
                        if (ev_i == 0 && (dqs_s1 !== 2'd0 || dqs_s2 !== 2'd0))
                            dq_fail("write preamble: DQS not driven low before its first rising edge");
                        // tDS: DQ and DM must have been steady for TDS_NS before the edge (they are launched half a UI ahead of it)
                        if (ev_now - t_dqdm_change < TDS_NS - EPS_NS)
                            dq_fail("write burst: DQ or DM changed less than tDS before a DQS edge");
                        t_edge_last = ev_now;
                        wq_dq[ev_e * 8 + ev_i] = dq_val;
                        wq_bad[ev_e * 8 + ev_i] = dq_bad_c;
                        wq_dm[ev_e * 8 + ev_i] = dm_code;
                        wq_n[ev_e]    = wq_n[ev_e] + 1;
                        wq_last[ev_e] = ev_now;
                        if (wq_n[ev_e] == 8) commit_write(ev_e);
                    end
                end
            end
        end
        dqs_ev_prev = ev_cur;
    end

    // On CK's rising edge: the strobe is sampled (this runs before the same instant's changes land, so it sees DQS as it was
    // an instant ago), and what only a sample can say is judged. DQS may be driven only around a burst a WRITE asked for, from
    // 3 tCK ahead of its first edge to 3 tCK after its last, low except for its eight edges, and must be low 0.4 tCK after the
    // last edge; a WRITE whose burst never came, or stopped part way, is reported, and an entry is dropped when its window is over.
    always @(posedge ck) begin
        if (rst) begin
            for (ev_k = 0; ev_k < NW; ev_k = ev_k + 1) wq_v[ev_k] = 1'b0;
            dqs_s1 <= 2'd2;
            dqs_s2 <= 2'd2;
        end else begin
            ev_cur = dqs_code;
            ev_now = $realtime;
`ifndef VERILATOR
            // (Verilator reads an undriven strobe as low, so it cannot tell "driven" from "idle": this check, and the
            // preamble and postamble ones, which only ever see a low there, are Icarus's. Everything about the edges is both's.)
            if (ev_cur != 2'd2 && ev_now > t_rd_until) begin
                ev_e = -1;
                for (ev_k = 0; ev_k < NW; ev_k = ev_k + 1)
                    if (wq_v[ev_k] && ev_now >= wq_t[ev_k] - 3.0 * TCK_NS - EPS_NS &&
                        ev_now <= wq_t[ev_k] + 8.0 * UI_NS + 3.0 * TCK_NS + EPS_NS) ev_e = ev_k;
                if (ev_e < 0) dq_fail("DQS driven outside the write burst a WRITE command asked for");
            end
`endif
            for (ev_k = 0; ev_k < NW; ev_k = ev_k + 1)
                if (wq_v[ev_k]) begin
                    if (wq_n[ev_k] == 0 && ev_now > wq_t[ev_k] + 9.0 * UI_NS + 2.0 * TCK_NS) begin
                        dq_fail("a WRITE command without its DQS burst");
                        wq_v[ev_k] = 1'b0;
                    end else if (wq_n[ev_k] > 0 && wq_n[ev_k] < 8 && ev_now > wq_last[ev_k] + 2.0 * UI_NS + 2.0 * TCK_NS) begin
                        dq_fail("write burst: DQS stopped before the eighth beat");
                        wq_v[ev_k] = 1'b0;
                    end else if (wq_n[ev_k] == 8) begin
                        if (!wq_post[ev_k] && ev_now >= wq_last[ev_k] + 0.4 * TCK_NS - EPS_NS) begin
                            wq_post[ev_k] = 1'b1;
                            if (ev_cur != 2'd0) dq_fail("write postamble: DQS not driven low after the burst");
                        end
                        if (ev_now > wq_t[ev_k] + 8.0 * UI_NS + 3.0 * TCK_NS) wq_v[ev_k] = 1'b0;
                    end
                end
            dqs_s2 <= dqs_s1;
            dqs_s1 <= ev_cur;
        end
    end

    // Command capture, on CK. Sampled where the DRAM samples them - in the
    // middle of the command's slot - so a command held for one CK is seen
    // exactly once.
    always @(posedge ck) begin
        if (rst) begin
            cur_valid <= 1'b0;
            for (i = 0; i < 8; i = i + 1) row_known[i] <= 1'b0;
        end else begin
            if (is_act) begin
                open_row[ba]  <= a[14:0];
                row_known[ba] <= 1'b1;
            end
            if (is_wr) begin
                // the write's burst is judged by the strobe's own edges (below): note where it must start
                wq_slot = -1;
                for (i = 0; i < NW; i = i + 1) if (!wq_v[i] && wq_slot < 0) wq_slot = i;
                if (wq_slot < 0) dq_fail("too many WRITE commands in flight for this model");
                else begin
                    wq_v[wq_slot]    = 1'b1;
                    wq_t[wq_slot]    = $realtime + CWL_CK * TCK_NS;
                    wq_bank[wq_slot] = ba;
                    wq_row[wq_slot]  = row_known[ba] ? open_row[ba] : 15'bx;
                    wq_col[wq_slot]  = a[9:0];
                    wq_n[wq_slot]    = 0;
                    wq_last[wq_slot] = 0.0;
                    wq_post[wq_slot] = 1'b0;
                end
            end
            if (is_rd) begin
                t_rd_until = $realtime + 14 * TCK_NS;   // the model drives DQS itself for this long (below): not the controller's
                // read data starts CL - 1 = 5 CK after the READ (DLL-off), so at sclk
                // resolution the preamble is two cycles on and the burst the two after
                rdexp[(cyc + 2) % 8] = 3'd1;
                rdexp[(cyc + 3) % 8] = 3'd2;
                rdexp[(cyc + 4) % 8] = 3'd3;
                rdexp[(cyc + 5) % 8] = 3'd4;
            end
            if (is_wr || is_rd) begin
                cur_valid <= 1'b1;
                cur_bank  <= ba;
                cur_row   <= row_known[ba] ? open_row[ba] : 15'bx;
                cur_col   <= a[9:0];
            end
        end
    end
endmodule

// Lane 1's memory for the testbenches that go through rtl/soc/ddr3_ecp5_top.v and are about something
// else (Phase 9 Stage 1, Part 26, docs/roadmap/phase-09-ddr.md).
//
// The controller does not take a request until BOTH byte lanes have calibrated, and a lane calibrates by
// looping a test pattern back through a DRAM, so every test that sends requests needs something behind lane
// 1's pins as well as lane 0's. This is that: the model above on lane 1's DQ, UDQS and UDM pins, watching the
// same command pins as lane 0's model, with its pins resolved. It also stores whatever lane 1 is asked to
// store, in its own byte plane, which a test about lane 0 simply never looks at. It lives in this file so
// that every build that already compiles the model has it.
//
// A test that is about the two lanes (sim/tb_ddr3_x16.v) instantiates both models itself and looks inside.
module ddr3_lane1_mem #(
    parameter DEPTH = 1024
)(
    input  wire        sclk,
    input  wire        rst,
    input  wire        ck,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [2:0]  ba,
    input  wire [14:0] a,
    inout  wire [7:0]  dqu,
    inout  wire        udqs,
    inout  wire        udm,
    input  wire        read_active,   // the controller's lane-1 read window (DUT.read_active_final_1)
    output wire        dq_error
);
    wire [7:0]   mem_dq_o;
    wire         mem_dq_oe, mem_dqs_oe, mem_dqs_o;
    wire [511:0] dq_error_msg;

    ddr3_dq_model #(.DEPTH(DEPTH)) MEM (
        .sclk(sclk), .rst(rst),
        .ck(ck),
        .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .a(a),
        .dq_pin(dqu), .dqs_pin(udqs), .dm_pin(udm),
        .read_active(read_active),
        .mem_dq_o(mem_dq_o), .mem_dq_oe(mem_dq_oe), .mem_dqs_oe(mem_dqs_oe), .mem_dqs_o(mem_dqs_o),
        .dq_error(dq_error), .dq_error_msg(dq_error_msg)
    );

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : DQU_BUS
            assign dqu[b] = mem_dq_oe ? mem_dq_o[b] : 1'bz;
        end
    endgenerate
    assign udqs = mem_dqs_oe ? mem_dqs_o : 1'bz;
endmodule
