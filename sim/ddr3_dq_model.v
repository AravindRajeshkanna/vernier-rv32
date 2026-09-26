// Behavioral DDR3 data (DQ/DQS) model - Phase 9 Stage 1, Part 2, made
// address-decoded in Part 15 (docs/roadmap.md).
//
// Through Part 14 this stored ONE byte at a fixed test location, so no test
// could see a write land in the wrong bank, row or column: a bug anywhere in
// the address path would have passed every DDR3 test. It now watches the
// same real command pins the protocol checker (sim/ddr3_model.v) watches, to
// learn WHERE data goes: an ACTIVATE records the open row of its bank, and a
// WRITE or READ records (bank, that bank's open row, column). The data phase
// - `wr_en` a CWL later, `read_active` a CL later - then lands in, or comes
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
// wr_en/read_active injection needs (it issues no DRAM commands at all).
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

    // the real DDR3 command pins, watched only to learn where data goes
    input  wire       cs_n,
    input  wire       ras_n,
    input  wire       cas_n,
    input  wire       we_n,
    input  wire [2:0] ba,
    input  wire [15:0] a,

    input  wire [7:0] wr_d0,
    input  wire       wr_en,

    input  wire       read_active,
    output reg  [7:0] mem_dq_o,
    output reg        mem_dq_oe,
    output reg        mem_dqs_o
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
    end

    always @(posedge sclk or posedge rst) begin
        if (rst) begin
            mem_dq_o   <= 8'b0;
            mem_dq_oe  <= 1'b0;
            mem_dqs_o  <= 1'b0;
            n_used     = 0;
            calib_data = 8'b0;
            cur_valid  <= 1'b0;
            for (i = 0; i < 8; i = i + 1) row_known[i] <= 1'b0;
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

            if (wr_en) store_current(wr_d0);

            // command capture takes effect from the next cycle
            if (is_act) begin
                open_row[ba]  <= a[14:0];
                row_known[ba] <= 1'b1;
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
