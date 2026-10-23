// DDR3 read calibration - Phase 9 Stage 1, Part 2, made command-driven in Phase 9 Stage 3
// (docs/roadmap/phase-09-ddr.md). A bounded, one-shot, boot-time sweep of `READCLKSEL[2:0]` (8 discrete tap
// positions) per byte lane, matching Lattice's documented "READ Pulse Positioning" mechanism (FPGA-TN-02035) and
// LiteDRAM's use of it - not a continuous closed loop.
//
// ---- What it does: it is a client of the controller's own sequencers ----
// Through Phase 9 Stage 2 this module injected a pattern onto the lane's DQ and DQS pins and opened a read window,
// and sent the DRAM no command at all (measured: 58 command slots, every one a NOP). The DRAM took no part in a lane's
// `calib_done`, so the tap it picked was not proven for a read the DRAM answers; on the chip the capture needs a strobe
// burst that only a READ makes the DRAM give; and the sweep could not run a second time against a DRAM that had been
// commanded (docs/roadmap/index.md had the record). Now it asks for what the controller itself does for any caller:
//   1. a WRITE of a known pattern to one reserved column, through the write sequencer (ACTIVATE, WRITE, PRECHARGE);
//   2. for each tap in turn, a READ of that column through the read sequencer (ACTIVATE, READ, PRECHARGE), with the
//      tap on `readclksel` for each lane that has not found one, and a look at what came back when the capture
//      window closed: the lane's byte must equal its pattern AND its DQSBUFM must have said `datavalid` in the window
//      (not `datavalid` alone: a tap can be "valid" by the primitive's own timing and still sample the wrong cycle;
//      not the data alone: a stale value could match). A lane takes the first tap that passes and stops sweeping;
//      `calib_error` is raised for a lane whose eight taps all fail, and never silently ignored.
// Both lanes are swept together, one read serving both, and resolve independently (a lane with nothing behind it
// fails while the other calibrates: sim_ecpix5_ddr3_lane1).
//
// ---- It asks politely ----
// A request is presented only while `busy` is low, which is the controller's own contract for a caller (rtl/soc/
// ddr3_ecp5_top.v: a caller that saw `busy` low is never dropped), so a refresh that comes due in the middle of the
// sweep simply goes first. The request is also checked: `busy` must rise within a few cycles, or it is asked again.
// A read whose window never closes is a failed tap, after TIMEOUT_CYC.
//
// ---- The reserved column, and what a restart does ----
// The pattern is written to bank BANK, row ROW, column COL: the last burst of the part (bank 7, row 0x7FFF, column
// 0x3F8), two bytes, the first beat of the burst (the controller stores one 16-bit column per write). The calibration
// overwrites them, and a cold start is the only time it does: the board's reset restarts the DRAM, which keeps nothing
// that can be relied on, and a bitstream loaded over a powered board has no CKE until the controller's own sequence
// brings it up. A warm reset (`rst` without `por`: the debug module's ndmreset, rtl/soc/ddr3_ecp5_top.v) keeps the
// results - the taps are a property of the board's timing, not of the DRAM's state - and does not write anything.
// A software user of the last 16 bytes of the 512 MB should know they are not theirs across a cold start.
//
// ---- What it does not establish ----
// Anything on a board. The sweep's tap choice is "the first that passes" (a window's edge, not its middle): on silicon
// a tap at the edge of the valid window has the least margin, which the hardware bring-up is for. In simulation the
// DQSBUFM is a stand-in with a valid window of taps 2 to 5 that does not look at the DQS pin
// (rtl/soc/ddr3_dqs_ecp5.v), so what a real strobe does to `datavalid` is not shown here.
module ddr3_read_calib #(
    parameter [7:0]  PATTERN0    = 8'hA5,    // lane 0's byte: not all-0s or all-1s, which a stuck-at fault could pass by accident
    parameter [7:0]  PATTERN1    = 8'h3C,    // lane 1's, different, so a crossed lane fails
    parameter [2:0]  BANK        = 3'd7,
    parameter [15:0] ROW         = 16'h7FFF,
    parameter [15:0] COL         = 16'h03F8,
    parameter        TIMEOUT_CYC = 64        // sclk cycles a read may take to close its window
)(
    input  wire        clk,         // sclk
    input  wire        por,         // asynchronous, the cold resets: the results are cleared by this alone
    input  wire        rst,         // synchronous, any other reason to start the sweep over: the results are kept

    // ---- requests into the controller's sequencers (rtl/soc/ddr3_ecp5_top.v muxes them with the caller's) ----
    input  wire        busy,        // the controller is working or a refresh holds it: do not ask
    output reg         write_req,
    output reg         read_req,
    output wire [2:0]  bank,
    output wire [15:0] row,
    output wire [15:0] col,
    output wire [15:0] write_data,  // {lane 1, lane 0}
    output wire [1:0]  write_be,
    output wire        active,      // this module owns the request port: the sweep has not finished

    // ---- the result of a read, as the controller has it when the capture window closes ----
    input  wire        rd_done,     // one cycle: the window just closed
    input  wire        valid0,      // lane 0's DQSBUFM said datavalid in the window
    input  wire        valid1,
    input  wire [7:0]  q0,          // lane 0's captured byte
    input  wire [7:0]  q1,

    // ---- what it decides ----
    output wire [2:0]  readclksel0,
    output wire [2:0]  readclksel1,
    output wire        calib_done,
    output wire [2:0]  calib_readclksel,
    output wire        calib_error,
    output wire        calib1_done,
    output wire [2:0]  calib1_readclksel,
    output wire        calib1_error
);
    assign bank       = BANK;
    assign row        = ROW;
    assign col        = COL;
    assign write_data = {PATTERN1, PATTERN0};
    assign write_be   = 2'b11;

    // ---- the results: kept by a warm reset, cleared by a cold one ----
    reg       done0, err0, done1, err1;
    reg [2:0] sel0, sel1;

    // What the controller is told. Not the results themselves: they are known while the last read's PRECHARGE is still
    // on its way, and a caller told "calibrated" must find the controller idle. So the outputs are raised when the sweep
    // is over and the controller is free (S_DONE), and dropped by any reset, a warm one included, until the sweep has
    // looked at its results again (immediately, after a warm reset, since they are kept): a caller never sees
    // `calib_done` while the controller behind it is held in reset.
    reg       o_done0, o_err0, o_done1, o_err1;
    assign calib_done        = o_done0;
    assign calib_error       = o_err0;
    assign calib_readclksel  = sel0;
    assign calib1_done       = o_done1;
    assign calib1_error      = o_err1;
    assign calib1_readclksel = sel1;

    wire res0 = done0 | err0;
    wire res1 = done1 | err1;
    assign active = !(res0 && res1);

    // ---- the sweep ----
    localparam [3:0]
        S_START  = 4'd0,    // after a reset: nothing to do if both lanes have their answer
        S_W_REQ  = 4'd1,    // wait for the controller to be free, then ask for the write
        S_W_RISE = 4'd2,    // the controller took it: busy rises
        S_W_FALL = 4'd3,    // ... and falls when the write and its PRECHARGE are done
        S_TAP    = 4'd4,    // put the tap on READCLKSEL, let it settle
        S_R_REQ  = 4'd5,    // wait for the controller to be free, then ask for the read
        S_R_RISE = 4'd6,
        S_R_WAIT = 4'd7,    // wait for the capture window to close
        S_R_FALL = 4'd8,    // the read's PRECHARGE is done: next tap or the end
        S_DONE   = 4'd9;
    localparam RISE_CYC   = 6;     // cycles busy may take to rise after a request before it is asked again
    localparam SETTLE_CYC = 2;     // cycles the tap is on READCLKSEL before the read

    reg [3:0] state;
    reg [2:0] tap;
    reg [6:0] cnt;

    // What the pins are told: a lane that found its tap keeps it; one that is still looking is at the tap being tried.
    assign readclksel0 = done0 ? sel0 : tap;
    assign readclksel1 = done1 ? sel1 : tap;

    wire p0 = valid0 && (q0 == PATTERN0);
    wire p1 = valid1 && (q1 == PATTERN1);

    always @(posedge clk or posedge por) begin
        if (por) begin
            done0 <= 1'b0; err0 <= 1'b0; sel0 <= 3'd0;
            done1 <= 1'b0; err1 <= 1'b0; sel1 <= 3'd0;
            o_done0 <= 1'b0; o_err0 <= 1'b0; o_done1 <= 1'b0; o_err1 <= 1'b0;
            state <= S_START; tap <= 3'd0; cnt <= 7'd0;
            write_req <= 1'b0; read_req <= 1'b0;
        end else if (rst) begin
            // Not the results: a warm reset keeps what the sweep found, and starts again only for a lane that has none.
            // What the controller is told is dropped, and comes back at S_DONE.
            o_done0 <= 1'b0; o_err0 <= 1'b0; o_done1 <= 1'b0; o_err1 <= 1'b0;
            state <= S_START; tap <= 3'd0; cnt <= 7'd0;
            write_req <= 1'b0; read_req <= 1'b0;
        end else begin
            write_req <= 1'b0;
            read_req  <= 1'b0;
            case (state)
                S_START: state <= (res0 && res1) ? S_DONE : S_W_REQ;

                S_W_REQ: if (!busy) begin
                    write_req <= 1'b1;
                    cnt       <= RISE_CYC[6:0];
                    state     <= S_W_RISE;
                end
                S_W_RISE: begin
                    if (busy)            state <= S_W_FALL;
                    else if (cnt == 0)   state <= S_W_REQ;          // dropped: ask again
                    else                 cnt   <= cnt - 7'd1;
                end
                S_W_FALL: if (!busy) begin
                    cnt   <= SETTLE_CYC[6:0];
                    state <= S_TAP;
                end

                S_TAP: begin      // `tap` is already on READCLKSEL (it is a register); give it SETTLE_CYC cycles
                    if (cnt == 0) state <= S_R_REQ;
                    else          cnt   <= cnt - 7'd1;
                end
                S_R_REQ: if (!busy) begin
                    read_req <= 1'b1;
                    cnt      <= RISE_CYC[6:0];
                    state    <= S_R_RISE;
                end
                S_R_RISE: begin
                    if (busy) begin
                        cnt   <= TIMEOUT_CYC[6:0];
                        state <= S_R_WAIT;
                    end else if (cnt == 0) state <= S_R_REQ;        // dropped: ask again
                    else                   cnt   <= cnt - 7'd1;
                end
                S_R_WAIT: begin
                    // The window closes with `rd_done`; what it held is judged in that cycle.
                    if (rd_done || cnt == 0) begin
                        if (!res0) begin
                            if (rd_done && p0)    begin done0 <= 1'b1; sel0 <= tap; end
                            else if (tap == 3'd7) err0 <= 1'b1;
                        end
                        if (!res1) begin
                            if (rd_done && p1)    begin done1 <= 1'b1; sel1 <= tap; end
                            else if (tap == 3'd7) err1 <= 1'b1;
                        end
                        state <= S_R_FALL;
                    end else begin
                        cnt <= cnt - 7'd1;
                    end
                end
                S_R_FALL: if (!busy) begin
                    if (res0 && res1)    state <= S_DONE;
                    else begin
                        tap   <= tap + 3'd1;
                        cnt   <= SETTLE_CYC[6:0];
                        state <= S_TAP;
                    end
                end

                S_DONE: begin    // stays here: the results are out, and a warm reset keeps them
                    o_done0 <= done0; o_err0 <= err0;
                    o_done1 <= done1; o_err1 <= err1;
                end
                default: state <= S_START;
            endcase
        end
    end
endmodule
