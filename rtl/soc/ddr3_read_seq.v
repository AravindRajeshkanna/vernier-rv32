// DDR3 real command-level read sequencer - Phase 9 Stage 1, Part 7
// (docs/roadmap.md). Issues a real ACTIVATE then a real READ command
// through rtl/soc/ddr3_phy_ecp5.v's own cmd_* interface, with a real
// tRCD gap and a real CAS Latency (CL) wait before signaling that data
// should be valid - the read-side twin of
// rtl/soc/ddr3_write_seq.v's own ACT+WR+CWL sequencer (Part 6), same
// FSM shape, same real command-address interface, same
// "narrow proof first" scope boundary.
//
// ---- Scope: this proves real command timing, not a full controller,
// and not yet reconciled with the existing capture mechanism ----
// One read request at a time (`busy` gates a second `read_req`), no
// bank-state tracking, no PRECHARGE - the same real, deliberate limits
// rtl/soc/ddr3_write_seq.v's own header already names for the write
// side. This module is not wired into rtl/soc/ddr3_ecp5_top.v, and its
// own `read_start` output (a single-cycle pulse, matching
// `write_start`'s own shape exactly) is NOT the same signal as
// rtl/soc/ddr3_dqs_ecp5.v's own `read_active` input, which that file's
// real `DQSBUFM` wiring needs held HIGH for the whole real capture
// window, not pulsed once - reconciling the two is real, later,
// separate work, named here rather than assumed already compatible.
//
// ---- Timing values ----
// TRCD_CYC/the real measured ACT-to-RD gap match
// rtl/soc/ddr3_write_seq.v's own ACT-to-WR gap exactly (same real
// tRCD requirement, same conservative reasoning - see that file's own
// header). CL=6 is not re-derived - it is the exact real value
// rtl/soc/ddr3_init_seq.v's own MR0 already commits this design to
// under DLL-off, reused directly. CL and CWL happen to share the same
// real value (6) in this specific design, but are named as distinct
// constants here (`CL_CYC`, not a shared `CWL_CYC` reused from the
// write sequencer) - real DDR3 parts can run CL and CWL at different
// values in general, and this design's own current equality is a
// property of its own DLL-off MR encoding, not a fact to bake into a
// shared name.
//
// The real ACT-to-RD and RD-to-read_start cycle gaps this FSM
// actually produces were measured directly against
// sim/tb_ddr3_read_seq.v, not assumed correct from hand-derived
// arithmetic - matching rtl/soc/ddr3_write_seq.v's own header, whose
// arithmetic undercounted the real ACT-to-WR gap by one cycle until a
// real test caught it.
module ddr3_read_seq (
    input  wire        clk,
    input  wire        rst,

    // ---- request interface ----
    input  wire        read_req,
    input  wire [2:0]  bank,
    input  wire [15:0] row,
    input  wire [15:0] col,     // A10 (auto-precharge) forced 0 internally - caller need not clear it
    output reg         busy,

    // ---- rtl/soc/ddr3_phy_ecp5.v's own cmd_* interface ----
    output reg         cmd_valid,
    output reg  [2:0]  cmd_cs_ras_cas_we,
    output reg  [2:0]  cmd_ba,
    output reg  [15:0] cmd_addr,

    // ---- pulses once, CL-aligned - see header for why this is not
    // yet the same signal as rtl/soc/ddr3_dqs_ecp5.v's own
    // read_active ----
    output reg         read_start
);
    localparam [2:0] CMD_NOP = 3'b111;
    localparam [2:0] CMD_ACT = 3'b011;   // RAS_n=0, CAS_n=1, WE_n=1
    localparam [2:0] CMD_RD  = 3'b101;   // RAS_n=1, CAS_n=0, WE_n=1

    localparam TRCD_CYC = 2;   // see header - matches ddr3_write_seq.v's own value
    localparam CL_CYC   = 6;   // see header - matches ddr3_init_seq.v's own MR0

    localparam [2:0]
        S_IDLE      = 3'd0,
        S_ACT       = 3'd1,
        S_TRCD_WAIT = 3'd2,
        S_RD        = 3'd3,
        S_CL_WAIT   = 3'd4;

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
            read_start        <= 1'b0;
            wait_cnt          <= 4'b0;
            bank_r            <= 3'b0;
            row_r             <= 16'b0;
            col_r             <= 16'b0;
        end else begin
            cmd_valid  <= 1'b0;
            read_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (read_req) begin
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
                    if (wait_cnt == 0) state <= S_RD;
                    else               wait_cnt <= wait_cnt - 1;
                end
                S_RD: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_RD;
                    cmd_ba            <= bank_r;
                    cmd_addr          <= {col_r[15:11], 1'b0, col_r[9:0]};
                    wait_cnt          <= CL_CYC - 1;
                    state             <= S_CL_WAIT;
                end
                S_CL_WAIT: begin
                    if (wait_cnt == 0) begin
                        read_start <= 1'b1;
                        state      <= S_IDLE;
                    end else begin
                        wait_cnt <= wait_cnt - 1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
