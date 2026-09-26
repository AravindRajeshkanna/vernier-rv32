// DDR3 real command-level write sequencer - Phase 9 Stage 1, Part 6
// (docs/roadmap.md). Issues a real ACTIVATE then a real WRITE command
// through rtl/soc/ddr3_phy_ecp5.v's own cmd_* interface, with a real
// (if conservative, reasoned-not-primary-datasheet-verified) tRCD gap
// between them, then pulses `write_start` once the real CAS Write
// Latency (CWL) has elapsed from the WRITE command - closing the gap
// every part through Part 5 named explicitly: `rtl/soc/ddr3_read_calib.v`
// drives the DQ/DQS mechanism directly, with no real DDR3 command ever
// issued alongside it.
//
// ---- Scope: this proves real command timing, not a full controller
// yet ----
// One write request at a time (`busy` gates a second `write_req` until
// the current one completes); no bank-state tracking (a real
// controller would remember which banks are already open and skip a
// redundant ACT - deliberately not attempted here), no read
// side (a symmetric `ddr3_read_seq.v` proving ACT+RD with tRCD/CL
// timing is deliberately left for a later part), and this module is
// not wired into `rtl/soc/ddr3_ecp5_top.v` yet - proven standalone
// first, the same "narrow proof first" discipline every part in this
// stage has used before its own later integration.
//
// ---- Part 14: every transaction ends by closing the bank ----
// Micron's datasheet: a row "remains open (or active) for accesses until a
// PRECHARGE command is issued to that bank. A PRECHARGE command must be
// issued before opening a different row in the same bank", and REFRESH
// needs every bank precharged. Until Part 14 this sequencer never issued
// PRECHARGE, so the second transaction to a bank was an ACT to an open
// bank (Part 9's own write-then-read round trip did exactly this - found
// by giving sim/ddr3_model.v per-bank state). After the write data has
// gone out and write recovery has elapsed it now issues PRECHARGE-all
// (A10 high), so whenever this sequencer is idle every bank is closed,
// and a REFRESH granted while it is idle is legal by construction.
// The earliest legal PRECHARGE after a WRITE is WR + CWL + 4 + tWR: write
// recovery starts four clocks after WL for BL8 (note 34), and tWR is "the
// greater of 4CK or 15ns" in DLL-off mode (note 33), which this design
// runs in - 6 + 4 + 4 = 14 CK, which is 7 sclk (Part 16: CK runs at twice
// sclk, and every command is in the first of the two slots per sclk, so a CK
// count converts exactly). WREC_CYC below puts PRECHARGE one sclk (two CK)
// later than that. tRP (13.1-15 ns) is one CK and is covered by the FSM
// itself rather than by a wait state: a request cannot be accepted before
// `busy` drops, and its ACT follows after that - measured in
// sim/tb_ddr3_write_seq.v at 3 sclk (6 CK) from PRECHARGE to the next ACT
// for the fastest possible caller.
//
// ---- Part 16: latencies are counted in CK, commands sit in phase 0 ----
// CK now runs at twice sclk (rtl/soc/ddr3_phy_ecp5.v) and a command is always
// driven in the first of the two CK slots of its sclk cycle. That makes
// CWL = 6 CK exactly 3 sclk, so `CWL_CYC` below is 3, not 6: before Part 16
// the design counted CK as sclk and waited twice as long as MR2 tells the
// DRAM to expect the write data. Odd CK counts cannot be placed (a command
// is only ever in phase 0), so every other spacing here rounds UP to whole
// sclk.
//
// ---- Timing values ----
// tRCD (RAS-to-CAS delay) is speed-grade dependent; commonly ~13.5-15ns
// on a real DDR3 part. At this design's own 25 MHz `sclk` (40ns/cycle),
// even a single real cycle already exceeds that comfortably - `TRCD_CYC`
// below adds one further cycle of real margin on top, the same
// "reasoned conservative margin, not independently checked against the
// primary Micron datasheet" approach `rtl/soc/ddr3_dqs_write_ecp5.v`'s
// own preamble/postamble margin already uses, named plainly again here
// rather than implied precise. CWL=6 is not re-derived - it is the
// exact real value `rtl/soc/ddr3_init_seq.v`'s own MR2 already commits
// this design to under DLL-off, reused directly.
//
// The real ACT-to-WR and WR-to-write_start cycle gaps this FSM
// actually produces were measured directly against
// sim/tb_ddr3_write_seq.v, not assumed correct from hand-derived
// arithmetic - a real, worth-recording example of why: the real
// measured ACT-to-WR gap is 3 cycles (120ns), not the 2 `TRCD_CYC`'s
// own name would suggest, because `S_ACT` itself occupies one real
// cycle before `S_TRCD_WAIT`'s own `TRCD_CYC` cycles even begin - not
// a correctness bug (3 cycles of real margin only exceeds a real
// tRCD requirement further), but a naming precision this header
// corrects rather than leaves standing uncorrected. WR-to-write_start
// measured exactly 3 cycles (Part 16; 6 before it), matching `CWL_CYC`.
module ddr3_write_seq (
    input  wire        clk,
    input  wire        rst,

    // ---- request interface ----
    input  wire        write_req,
    input  wire [2:0]  bank,
    input  wire [15:0] row,
    input  wire [15:0] col,     // A10 (auto-precharge) forced 0 internally - caller need not clear it
    output reg         busy,

    // ---- rtl/soc/ddr3_phy_ecp5.v's own cmd_* interface ----
    output reg         cmd_valid,
    output reg  [2:0]  cmd_cs_ras_cas_we,
    output reg  [2:0]  cmd_ba,
    output reg  [15:0] cmd_addr,

    // ---- triggers the real DQS/DQ write-drive mechanism once CWL has
    // elapsed - the same wr_en-shaped single-cycle pulse
    // rtl/soc/ddr3_read_calib.v's own direct-injection scheme already
    // produces, meant to eventually replace it, not yet wired to do so ----
    output reg         write_start
);
    localparam [2:0] CMD_NOP = 3'b111;
    localparam [2:0] CMD_ACT = 3'b011;   // RAS_n=0, CAS_n=1, WE_n=1
    localparam [2:0] CMD_WR  = 3'b100;   // RAS_n=1, CAS_n=0, WE_n=0
    localparam [2:0] CMD_PRE = 3'b010;   // RAS_n=0, CAS_n=1, WE_n=0 (A10 high = all banks)

    localparam TRCD_CYC = 2;   // see header
    localparam CWL_CYC  = 3;   // CWL = 6 CK (ddr3_init_seq.v's own MR2) = 3 sclk; see header
    // Cycles from the write_start pulse to PRECHARGE being issued. PRE is
    // visible on the pins at WR + CWL_CYC + 1 + WREC_CYC: 8 sclk (16 CK) with
    // WREC_CYC = 4, one sclk over the 7-sclk (14 CK) datasheet minimum.
    localparam WREC_CYC = 4;

    localparam [2:0]
        S_IDLE      = 3'd0,
        S_ACT       = 3'd1,
        S_TRCD_WAIT = 3'd2,
        S_WR        = 3'd3,
        S_CWL_WAIT  = 3'd4,
        S_WREC_WAIT = 3'd5,
        S_PRE       = 3'd6;

    reg [2:0]  state;
    reg [3:0]  wait_cnt;
    reg [2:0]  bank_r;
    reg [15:0] row_r, col_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state             <= S_IDLE;
            busy              <= 1'b0;
            cmd_valid         <= 1'b0;
            cmd_cs_ras_cas_we <= CMD_NOP;
            cmd_ba            <= 3'b0;
            cmd_addr          <= 16'b0;
            write_start       <= 1'b0;
            wait_cnt          <= 4'b0;
            bank_r            <= 3'b0;
            row_r             <= 16'b0;
            col_r             <= 16'b0;
        end else begin
            cmd_valid   <= 1'b0;
            write_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (write_req) begin
                        bank_r <= bank;
                        row_r  <= row;
                        col_r  <= col;
                        busy   <= 1'b1;
                        state  <= S_ACT;
                    end
                end
                S_ACT: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_ACT;
                    cmd_ba            <= bank_r;
                    cmd_addr          <= row_r;
                    wait_cnt          <= TRCD_CYC - 1;
                    state             <= S_TRCD_WAIT;
                end
                S_TRCD_WAIT: begin
                    if (wait_cnt == 0) state <= S_WR;
                    else               wait_cnt <= wait_cnt - 1;
                end
                S_WR: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_WR;
                    cmd_ba            <= bank_r;
                    cmd_addr          <= {col_r[15:11], 1'b0, col_r[9:0]};
                    wait_cnt          <= CWL_CYC - 1;
                    state             <= S_CWL_WAIT;
                end
                S_CWL_WAIT: begin
                    if (wait_cnt == 0) begin
                        write_start <= 1'b1;
                        wait_cnt    <= WREC_CYC - 1;
                        state       <= S_WREC_WAIT;
                    end else begin
                        wait_cnt <= wait_cnt - 1;
                    end
                end
                S_WREC_WAIT: begin
                    if (wait_cnt == 0) state <= S_PRE;
                    else               wait_cnt <= wait_cnt - 1;
                end
                S_PRE: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_PRE;
                    cmd_ba            <= bank_r;
                    cmd_addr          <= 16'h0400;   // A10 high: all banks
                    state             <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
