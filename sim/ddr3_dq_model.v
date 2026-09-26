// Behavioral DDR3 data (DQ/DQS) model - Phase 9 Stage 1, Part 2, made
// address-decoded in Part 15 (docs/roadmap.md).
//
// Through Part 14 this stored ONE byte at a fixed test location, so no test
// could see a write land in the wrong bank, row or column: a bug anywhere in
// the address path would have passed every DDR3 test. It now watches the
// same real command pins the protocol checker (sim/ddr3_model.v) watches, to
// learn WHERE data goes: an ACTIVATE records the open row of its bank, and a
// WRITE or READ records (bank, that bank's open row, column). The data phase
// - the write burst a CWL later, `read_active` a CL later - then lands in, or comes
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
// Data written before any command has been seen goes to one separate
// "calibration" cell, which is what rtl/soc/ddr3_read_calib.v's direct
// write burst and read_active injection needs (it issues no DRAM commands at all).
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
// DQS is modeled as a genuinely source-synchronous signal - it only
// toggles while `read_active` is high, staying idle otherwise - the
// real behavior `rtl/soc/ddr3_dqs_ecp5.v`'s own `READ0`/`READ1` gating
// depends on, not a free-running clock.
module ddr3_dq_model #(
    parameter DEPTH = 1024
)(
    input  wire       sclk,
    input  wire       rst,

    // the real DDR3 command pins, watched only to learn where data goes.
    // Commands are sampled on CK's rising edge, as the DRAM does; the data
    // phase below stays on sclk.
    input  wire       ck,
    input  wire       cs_n,
    input  wire       ras_n,
    input  wire       cas_n,
    input  wire       we_n,
    input  wire [2:0] ba,
    input  wire [15:0] a,

    // the resolved DQ and DQS pins - what the DRAM sees when the controller drives
    input  wire [7:0] dq_pin,
    input  wire       dqs_pin,

    input  wire       read_active,
    output reg  [7:0] mem_dq_o,
    output reg        mem_dq_oe,
    output reg        mem_dqs_o,

    output reg          dq_error,      // sticky: a write burst broke the DRAM's own timing
    output reg  [511:0] dq_error_msg
);
    wire is_act = !cs_n && !ras_n &&  cas_n &&  we_n;
    wire is_wr  = !cs_n &&  ras_n && !cas_n && !we_n;
    wire is_rd  = !cs_n &&  ras_n && !cas_n &&  we_n;

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

    reg [7:0]  calib_data;   // written before any command has been seen

    integer i;

    // ---- write-burst expectations (Part 17) ----
    // `cyc` counts sclk cycles; a WRITE sampled in cycle W schedules what the
    // pins must show in W+2..W+5 (see the header). Indexed mod 8, consumed as
    // each cycle ends.
    integer    cyc;
    reg [2:0]  wexp [0:7];   // 0 nothing expected, 1 preamble, 2 burst half 1, 3 burst half 2, 4 postamble
    reg        cmd_seen;     // a WRITE or READ has been seen: calibration is over
    reg        cal_active_prev;

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
            if (!cur_valid) current_value = calib_data;
            else begin
                j = find(cur_bank, cur_row, cur_col);
                current_value = (j < 0) ? 8'hxx : k_data[j];
            end
        end
    endfunction

    task store_current(input [7:0] d);
        integer j;
        begin
            if (!cur_valid) calib_data = d;
            else begin
                j = find(cur_bank, cur_row, cur_col);
                if (j < 0) begin
                    if (n_used >= DEPTH) begin
                        overflowed = 1'b1;
                        $display("ddr3_dq_model: store full (%0d locations) - raise DEPTH", DEPTH);
                    end else begin
                        j = n_used;
                        n_used = n_used + 1;
                        k_used[j] = 1'b1;
                        k_bank[j] = cur_bank;
                        k_row[j]  = cur_row;
                        k_col[j]  = cur_col;
                    end
                end
                if (j >= 0) k_data[j] = d;
            end
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

    initial begin
        overflowed = 1'b0;
        n_used     = 0;
        calib_data = 8'b0;
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
        cmd_seen        = 1'b0;
        cal_active_prev = 1'b0;
        for (i = 0; i < 8; i = i + 1) wexp[i] = 3'd0;
    end

    always @(posedge sclk or posedge rst) begin
        if (rst) begin
            mem_dq_o   <= 8'b0;
            mem_dq_oe  <= 1'b0;
            mem_dqs_o  <= 1'b0;
            n_used     = 0;
            calib_data = 8'b0;
            cyc        = 0;
            cal_active_prev = 1'b0;
            for (i = 0; i < 8; i = i + 1) wexp[i] = 3'd0;
            for (i = 0; i < DEPTH; i = i + 1) k_used[i] = 1'b0;
        end else begin
            // Drive first: the registered value is the one held BEFORE this
            // edge's write lands, the same one-cycle lag the single-cell
            // model had.
            mem_dq_o  <= current_value(1'b0);
            mem_dq_oe <= read_active;
            // Real DQS behavior: idle when no read is happening, a
            // real toggle only while one is - `mem_dqs_o` here is a
            // simplified, sclk-rate toggle (matching
            // rtl/soc/ddr3_dq_serdes_ecp5.v's own honest sclk-rate,
            // not eclk-rate, simulation approximation), not a claim of
            // real DQS bit-timing.
            mem_dqs_o <= read_active ? ~mem_dqs_o : 1'b0;

            // ---- the write burst, judged from the pins for the cycle that just
            // ended ----
            // The model's own read drive is on the same bus; skip while it drives.
            if (!mem_dq_oe) begin
                case (wexp[cyc % 8])
                    3'd1: if (dqs_pin !== 1'b0)
                              dq_fail("write preamble: DQS not driven low the cycle before the burst");
                    3'd2, 3'd3: begin
                        if (dqs_pin !== 1'b1)
                            dq_fail("write burst: DQS not active in an expected burst cycle");
                        else if ((^dq_pin) === 1'bx)
                            dq_fail("write burst: DQ not driven while DQS is active");
                        else if (wexp[cyc % 8] == 3'd2 && cur_valid)
                            store_current(dq_pin);   // beats 4-7 (half 2) are ignored, see the header
                    end
                    3'd4: if (dqs_pin !== 1'b0)
                              dq_fail("write postamble: DQS not driven low after the burst");
                    default: begin
                        if (cmd_seen && dqs_pin !== 1'bz)
                            dq_fail("DQS driven outside the write burst a WRITE command asked for");
                    end
                endcase
                // Calibration writes issue no command: capture the first active cycle.
                if (!cmd_seen) begin
                    if (dqs_pin === 1'b1 && !cal_active_prev && (^dq_pin) !== 1'bx) calib_data = dq_pin;
                    cal_active_prev = (dqs_pin === 1'b1);
                end
            end
            wexp[cyc % 8] = 3'd0;
            cyc = cyc + 1;
        end
    end

    // Command capture, on CK. Sampled where the DRAM samples them - in the
    // middle of the command's slot - so a command held for one CK is seen
    // exactly once.
    always @(posedge ck) begin
        if (rst) begin
            cur_valid <= 1'b0;
            cmd_seen  <= 1'b0;
            for (i = 0; i < 8; i = i + 1) row_known[i] <= 1'b0;
        end else begin
            if (is_act) begin
                open_row[ba]  <= a[14:0];
                row_known[ba] <= 1'b1;
            end
            if (is_wr) begin
                // WL = 6 CK = 3 sclk after the cycle this WRITE was driven in
                wexp[(cyc + 2) % 8] = 3'd1;
                wexp[(cyc + 3) % 8] = 3'd2;
                wexp[(cyc + 4) % 8] = 3'd3;
                wexp[(cyc + 5) % 8] = 3'd4;
            end
            if (is_wr || is_rd) begin
                cmd_seen  <= 1'b1;
                cur_valid <= 1'b1;
                cur_bank  <= ba;
                cur_row   <= row_known[ba] ? open_row[ba] : 15'bx;
                cur_col   <= a[9:0];
            end
        end
    end
endmodule
