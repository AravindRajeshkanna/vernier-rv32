// DDR3 read-calibration sweep - Phase 9 Stage 1, Part 2
// (docs/roadmap.md). A real, bounded, one-shot boot-time sweep of
// `READCLKSEL[2:0]` (8 discrete tap positions), matching Lattice's own
// documented "READ Pulse Positioning" mechanism (FPGA-TN-02035) and
// LiteDRAM's own real, proven use of it - not a continuous closed
// loop, the same real precedent `rtl/soc/ddr3_dqs_ecp5.v`'s own header
// already cites.
//
// Writes a known test pattern once, then tries each of the 8 possible
// `READCLKSEL` values in turn: issue a real read, check `datavalid`
// AND that the captured data actually matches the pattern written
// (not `datavalid` alone - a real DQSBUFM could plausibly assert
// `datavalid` at a tap that is "valid" by its own internal timing
// definition but still samples the wrong data cycle; checking the
// data itself is the real, load-bearing test, matching this whole
// slice's own reason for existing rather than trusting a status bit at
// face value). The first tap that matches is latched as the real,
// calibrated value; `calib_error` is asserted, not silently ignored,
// if every tap fails.
module ddr3_read_calib #(
    parameter [7:0] TEST_PATTERN = 8'hA5   // an arbitrary, non-trivial bit pattern - not all-0s/all-1s, which a stuck-at fault could pass by accident
)(
    input  wire        clk,   // sclk-domain - this module issues no eclk-rate signals of its own
    input  wire        rst,

    // ---- drives the byte lane under test ----
    output reg  [7:0]  wr_d0,
    output reg         wr_en,
    output reg         read_active,
    output reg  [2:0]  readclksel,

    input  wire        datavalid,
    input  wire [7:0]  rd_q0,

    output reg         calib_done,
    output reg  [2:0]  calib_readclksel,   // the real, found-working tap - only meaningful once calib_done
    output reg         calib_error         // every one of the 8 taps failed
);
    localparam [3:0]
        S_WRITE      = 4'd0,
        S_WRITE_WAIT = 4'd1,
        S_TRY_START  = 4'd2,
        S_TRY_READ   = 4'd3,
        S_TRY_CHECK  = 4'd4,
        S_TRY_NEXT   = 4'd5,
        S_DONE       = 4'd6,
        S_ERROR      = 4'd7;

    reg [3:0]  state;
    reg [2:0]  tap;
    reg [3:0]  settle_cnt;

    // A real read needs a few real cycles for the write to land and
    // for a read attempt's own datavalid/data to settle - not
    // asserted as instantaneous, the same "real timing, not an
    // idealized same-cycle response" discipline this whole
    // investigation has held every other module to.
    localparam SETTLE_CYC = 4;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= S_WRITE;
            tap              <= 3'd0;
            settle_cnt       <= 0;
            wr_d0            <= 8'b0;
            wr_en            <= 1'b0;
            read_active      <= 1'b0;
            readclksel       <= 3'd0;
            calib_done       <= 1'b0;
            calib_readclksel <= 3'd0;
            calib_error      <= 1'b0;
        end else begin
            wr_en       <= 1'b0;
            read_active <= 1'b0;

            case (state)
                S_WRITE: begin
                    wr_d0    <= TEST_PATTERN;
                    wr_en    <= 1'b1;
                    settle_cnt <= SETTLE_CYC;
                    state    <= S_WRITE_WAIT;
                end
                S_WRITE_WAIT: begin
                    if (settle_cnt == 0) state <= S_TRY_START;
                    else                 settle_cnt <= settle_cnt - 1;
                end

                S_TRY_START: begin
                    readclksel <= tap;
                    settle_cnt <= SETTLE_CYC;
                    state      <= S_TRY_READ;
                end
                S_TRY_READ: begin
                    read_active <= 1'b1;
                    if (settle_cnt == 0) state <= S_TRY_CHECK;
                    else                 settle_cnt <= settle_cnt - 1;
                end
                S_TRY_CHECK: begin
                    if (datavalid && rd_q0 == TEST_PATTERN) begin
                        calib_readclksel <= tap;
                        calib_done       <= 1'b1;
                        state            <= S_DONE;
                    end else begin
                        state <= S_TRY_NEXT;
                    end
                end
                S_TRY_NEXT: begin
                    if (tap == 3'd7) begin
                        calib_error <= 1'b1;
                        state       <= S_ERROR;
                    end else begin
                        tap   <= tap + 3'd1;
                        state <= S_TRY_START;
                    end
                end

                S_DONE:  ; // stays here - a real caller reads calib_done/calib_readclksel once and moves on
                S_ERROR: ; // stays here - a real caller reads calib_error and decides what to do; this module does not retry on its own
                default: state <= S_WRITE;
            endcase
        end
    end
endmodule
