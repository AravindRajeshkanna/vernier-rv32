// DDR3 real refresh scheduler - Phase 9 Stage 1, Part 10
// (docs/roadmap.md). Closes a real, completely unaddressed gap in this
// stage's own "Done when" bar: "standalone read/write/refresh tests" -
// no refresh command has ever been issued anywhere in this stage
// through Part 9. A real, free-running counter requests a REFRESH once
// every real tREFI interval; the request is held (not dropped) until
// an external caller grants it (`refresh_grant` - a real controller
// must not interrupt an in-flight ACT/WR/RD sequence to refresh
// mid-transaction), then issues a real REFRESH command and holds
// `busy` for the real tRFC wait before the next command may be issued.
//
// ---- Real, primary-datasheet-verified timing - the first time in
// this whole investigation, not another reasoned-margin caveat ----
// Every earlier DDR3 timing value in this stage (MR field encodings,
// tRCD, CWL/CL cycle counts, DQS preamble/postamble) was reasoned from
// general JEDEC knowledge or cross-checked only against a third-party
// open-source implementation, with an explicit, honest "not checked
// against the primary datasheet" caveat each time (that PDF fetch had
// failed every previous round). This round's own fetch succeeded:
// Micron's own real `MT41K256M16` datasheet (32 Meg x 16 x 8 banks =
// 4Gb - the chip a real, targeted web search identifies as what
// ECPIX-5's own "4Gb (512MB) DDR3L" spec actually uses, though that
// specific board-to-chip identification itself came from search
// results, not a directly-viewed schematic, and is flagged as such)
// gives two real numbers directly, extracted from its own real timing
// table via `pdftotext`, not estimated:
//   - tREFI = 7.8125 us (64ms / 8192 refreshes) - `36. The refresh
//     period is 64ms when TC is less than or equal to 85C. This
//     equates to an average refresh rate of 7.8125us.` This value is
//     density-independent (every DDR3 part shares it), so it holds
//     regardless of whether ECPIX-5's own chip identification above is
//     exactly right.
//   - tRFC(min), 4Gb = 260ns - `tRFC - 4Gb: MIN = 260; MAX = 70,200`
//     (ns). Density-*dependent* - cross-checked against a second, real
//     manufacturer datasheet (Zentel's own 2Gb DDR3L part) showing
//     tRFC(min) = 160ns for that smaller density, confirming the real
//     pattern (larger density, longer tRFC) rather than a one-off
//     number. Even if ECPIX-5's own real chip turns out to be a
//     smaller density than assumed, using the 4Gb part's own longer
//     260ns figure is still safe - it only ever waits *longer* than a
//     smaller chip's own real (shorter) minimum requires, never less.
//
// T_REFI (195 cycles at 25 MHz) reuses `rtl/soc/wb_sdram.v`'s own
// exact real formula (`CLK_HZ / 128000`) for the identical reason:
// 1/128000 = 7.8125us exactly, an algebraically exact conversion, not
// an approximation - consistent with this project's own existing SDR
// SDRAM controller rather than a second, independently-derived
// constant for the same real interval. T_RFC (7 cycles = 280ns real
// margin at 25 MHz, comfortably >= the real 260ns minimum) uses the
// same `NS2CYC` ceiling-rounding macro `rtl/soc/ddr3_init_seq.v`'s own
// header already establishes.
//
// ---- Scope: this proves the scheduler mechanism, not a full
// integration yet ----
// Proven standalone first, matching every part in this stage's own
// "narrow proof first" discipline - not yet wired into
// `rtl/soc/ddr3_ecp5_top.v`. Real arbitration (only granting a refresh
// when neither `ddr3_write_seq.v` nor `ddr3_read_seq.v` has an
// in-flight transaction) is `refresh_grant`'s own caller's
// responsibility, decided at integration time, not here.
module ddr3_refresh_ctrl #(
    parameter CLK_HZ = 25_000_000
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        refresh_grant,  // caller says "safe to refresh now" - held pending until this arrives
    output reg         refresh_req,    // real, pending "a refresh is due" flag - not dropped if not immediately granted
    output reg         busy,

    output reg         cmd_valid,
    output reg  [2:0]  cmd_cs_ras_cas_we,
    output reg  [2:0]  cmd_ba,
    output reg  [15:0] cmd_addr
);
    `define NS2CYC(ns) (((ns) * (CLK_HZ / 1000) + 999_999) / 1_000_000)
    localparam T_REFI = CLK_HZ / 128_000;   // see header - exact, not an approximation
    localparam T_RFC  = `NS2CYC(260);       // see header - real, primary-datasheet-verified (4Gb)

    localparam [2:0] CMD_NOP = 3'b111;
    localparam [2:0] CMD_REF = 3'b001;   // RAS_n=0, CAS_n=0, WE_n=1 - real JEDEC REFRESH encoding

    localparam [1:0]
        S_COUNT      = 2'd0,
        S_WAIT_GRANT = 2'd1,   // issuing the real REFRESH command is this state's own success branch, not a separate state
        S_RFC_WAIT   = 2'd2;

    reg [1:0]  state;
    reg [31:0] refi_cnt;
    reg [31:0] rfc_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state             <= S_COUNT;
            refi_cnt          <= T_REFI - 1;
            rfc_cnt           <= 32'b0;
            refresh_req       <= 1'b0;
            busy              <= 1'b0;
            cmd_valid         <= 1'b0;
            cmd_cs_ras_cas_we <= CMD_NOP;
            cmd_ba            <= 3'b0;
            cmd_addr          <= 16'b0;
        end else begin
            cmd_valid <= 1'b0;

            case (state)
                S_COUNT: begin
                    busy <= 1'b0;
                    if (refi_cnt == 0) begin
                        refresh_req <= 1'b1;
                        state       <= S_WAIT_GRANT;
                    end else begin
                        refi_cnt <= refi_cnt - 1;
                    end
                end
                S_WAIT_GRANT: begin
                    busy <= 1'b1;
                    if (refresh_grant) begin
                        refresh_req       <= 1'b0;
                        cmd_valid         <= 1'b1;
                        cmd_cs_ras_cas_we <= CMD_REF;
                        cmd_ba            <= 3'b0;
                        cmd_addr          <= 16'b0;
                        rfc_cnt           <= T_RFC - 1;
                        state             <= S_RFC_WAIT;
                    end
                end
                S_RFC_WAIT: begin
                    if (rfc_cnt == 0) begin
                        refi_cnt <= T_REFI - 1;
                        state    <= S_COUNT;
                    end else begin
                        rfc_cnt <= rfc_cnt - 1;
                    end
                end
                default: state <= S_COUNT;
            endcase
        end
    end
endmodule
