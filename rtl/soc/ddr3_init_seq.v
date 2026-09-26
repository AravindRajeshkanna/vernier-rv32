// DDR3 initialization/mode-register sequence - Phase 9 Stage 1, Part 1
// (docs/roadmap.md). Drives rtl/soc/ddr3_phy_ecp5.v's own command
// interface through the real JEDEC power-up sequence for DLL-off,
// CL=6, CWL=6 operation, then asserts `ready`. No read/write/refresh
// path yet - that is a later, separate slice; this module's only job is
// getting the DRAM from power-up into normal operation.
//
// ---- What is, and is not, independently verified here ----
// The real command ORDER and overall structure (reset/CKE timing, then
// MR2 -> MR3 -> MR1 -> MR0 -> ZQCL, matching JEDEC's own required
// sequence) is well-established and cross-checked against two
// independent real, working ECP5 implementations this round's own
// research read directly. The exact per-field bit VALUES inside each
// mode register below were reasoned field-by-field against general
// JEDEC DDR3 knowledge and cross-checked where possible against
// AngeloJacobo/UberDDR3's own real, working values (GPL-3.0 - read for
// the bit-field POSITIONS and encoding only, no code copied) - but this
// session could not successfully fetch the primary Micron datasheet PDF
// directly (the fetch returned a redirect page, not the document), so
// these values are NOT independently confirmed against the primary
// source the way this project's own practices normally require. Named
// here plainly rather than hidden: a real, open verification gap for
// whoever continues this, not a claim of full certainty.
//
// Every optional DDR3 feature (ODT, additive latency, output-drive
// tuning) is left at its safest, JEDEC-default "disabled/standard"
// setting - correctness first; tuning is real, separate, later work
// once this is confirmed against a real behavioral model.
module ddr3_init_seq #(
    // Real, ns-based JEDEC timing, converted to cycles at elaboration
    // time - the same NS2CYC-style approach rtl/soc/wb_sdram.v already
    // uses for its own SDR SDRAM timing, not a new pattern.
    parameter CLK_HZ = 25_000_000
)(
    input  wire clk,
    input  wire rst,

    output reg         cmd_valid,
    output reg  [2:0]  cmd_cs_ras_cas_we,
    output reg  [2:0]  cmd_ba,
    output reg  [15:0] cmd_addr,
    output reg         cmd_cke,
    output reg         cmd_reset_n,
    output reg         cmd_odt,

    output reg         ready   // 1 once MR0-3 + ZQCL are done and their own waits have elapsed
);
    // ---- ns -> cycle conversion, matching wb_sdram.v's own NS2CYC macro ----
    `define NS2CYC(ns) (((ns) * (CLK_HZ / 1000) + 999_999) / 1_000_000)

    // Real JEDEC power-up timing this sequence must respect:
    localparam RESET_CYC   = `NS2CYC(200_000);  // tRESET, RESET_n low, >=200 us
    localparam XPR_CYC     = `NS2CYC(500);      // wait after CKE high before the first command (conservative - tXPR is one of the values not cross-checked against the primary datasheet, see header)
    localparam MRD_CYC     = 4;                 // tMRD is 4 nCK; counted here in sclk cycles = 8 CK (Part 16: CK is twice sclk) - twice the minimum, conservative, deliberately not recounted
    localparam ZQINIT_CYC  = 512;               // tZQinit/tDLLK is 512 nCK; counted here in sclk cycles = 1024 CK (Part 16) - twice the minimum, conservative, deliberately not recounted. Applies even under DLL-off since ZQCL calibrates independently

    // ---- command encodings, matching rtl/soc/ddr3_phy_ecp5.v's own
    // {ras_n,cas_n,we_n} convention (cs_n handled by cmd_valid there) ----
    localparam [2:0] CMD_MRS  = 3'b000;  // RAS_n=0, CAS_n=0, WE_n=0
    localparam [2:0] CMD_ZQCL = 3'b110;  // RAS_n=1, CAS_n=1, WE_n=0, A10=1 selects "long" (vs. ZQCS)

    // ---- mode register values, field by field - see header for the
    // real verification status of each ----
    // MR0 (BA=000): A[1:0]=BL (00=BL8 fixed), A[2]=CL[0], A[3]=RBT
    // (0=sequential), A[6:4]=CL[3:1], A[7]=TM (0=normal), A[8]=DLL_RST
    // (1 - JEDEC requires this pulse during init MRS0 regardless of
    // DLL-off, since MR1's own DLL-disable is already active by the
    // time MR0 is written, per the MR2->MR3->MR1->MR0 order below),
    // A[11:9]=WR (write recovery; 011=8, a conservative, standard
    // middle value - real margin at this design's own ~25 MHz is
    // enormous either way, since ns-based DDR3 timing only gets safer
    // at a slower clock), A[12]=PPD (0 - slow-exit precharge
    // power-down, the simpler/more conservative of the two options,
    // since this design does not yet use power-down modes).
    // CL=6 encodes as CL[3:0]=4'b0100 (JEDEC: (CL-4) in a specific
    // non-contiguous bit layout - matches AngeloJacobo/UberDDR3's own
    // real `CL = (6-4)*2` derivation exactly).
    localparam [3:0] MR0_CL   = 4'b0100;
    localparam [15:0] MR0_VAL = {3'b000,            // A15:13 unused/reserved
                                  1'b0,               // A12 PPD=0
                                  3'b011,             // A11:9 WR=8
                                  1'b1,               // A8 DLL_RST=1
                                  1'b0,               // A7 TM=0
                                  MR0_CL[3:1],        // A6:4
                                  1'b0,               // A3 RBT=0 (sequential)
                                  MR0_CL[0],          // A2
                                  2'b00};             // A1:0 BL8 fixed

    // MR1 (BA=001): A0=DLL_EN (JEDEC polarity: 1=DLL DISABLED - this
    // is the one bit this whole init sequence exists to set),
    // A1=DIC[0]/A5=DIC[1] (output drive strength, 00=standard 40 ohm),
    // A2=AL (00=additive latency disabled, combined with A3),
    // A3=RTT_NOM[0]/A6=RTT_NOM[1]/A9=RTT_NOM[2] (000=Rtt_Nom disabled -
    // no on-die termination, the standard DLL-off-mode default since
    // ODT's own timing assumptions target the higher DLL-on speed
    // range), A7=TDQS (0=disabled, x16 parts like ECPIX-5's own
    // MT41K256M16 do not use TDQS), A12=QOFF (0=output buffer enabled).
    localparam [15:0] MR1_VAL = {3'b000,            // A15:13 unused/reserved
                                  1'b0,               // A12 QOFF=0 (enabled)
                                  1'b0,               // A11 unused/reserved
                                  1'b0,               // A10 unused/reserved
                                  1'b0,               // A9 RTT_NOM[2]=0
                                  1'b0,               // A8 unused/reserved
                                  1'b0,               // A7 TDQS=0
                                  1'b0,               // A6 RTT_NOM[1]=0
                                  2'b00,              // A5:4 DIC / AL[1] - both 0
                                  1'b0,               // A3 RTT_NOM[0]=0
                                  1'b0,               // A2 AL[0]=0 (AL disabled)
                                  1'b0,               // A1 DIC[0]=0
                                  1'b1};              // A0 DLL disabled

    // MR2 (BA=010): A[5:3]=CWL (001=CWL6, matching
    // AngeloJacobo/UberDDR3's own real `CWL = 6-5` derivation exactly),
    // A6=ASR (0=manual self-refresh reference, the JEDEC default),
    // A7=SRT (0=normal temperature range), A[10:9]=RTT_WR (00=dynamic
    // ODT disabled, consistent with RTT_NOM already disabled above).
    localparam [15:0] MR2_VAL = {5'b00000,           // A15:11 unused/reserved
                                  2'b00,              // A10:9 RTT_WR=disabled
                                  1'b0,               // A8 unused/reserved
                                  1'b0,               // A7 SRT=0 (normal)
                                  1'b0,               // A6 ASR=0 (manual)
                                  3'b001,             // A5:3 CWL=6
                                  3'b000};            // A2:0 PASR=000 (full array)

    // MR3 (BA=011): mostly reserved on this generation - A[1:0]=MPR
    // location (don't-care when MPR disabled), A2=MPR (0=disabled,
    // normal operation - the MPR is a read-only diagnostic pattern
    // register, not needed for a first working implementation).
    localparam [15:0] MR3_VAL = 16'b0;

    // ---- state machine ----
    localparam [3:0]
        S_RESET      = 4'd0,   // RESET_n low, CKE low
        S_CKE_WAIT   = 4'd1,   // RESET_n high, CKE still low - real hold before CKE
        S_XPR_WAIT   = 4'd2,   // CKE high - wait before the first command
        S_MR2        = 4'd3,
        S_MR2_WAIT   = 4'd4,
        S_MR3        = 4'd5,
        S_MR3_WAIT   = 4'd6,
        S_MR1        = 4'd7,
        S_MR1_WAIT   = 4'd8,
        S_MR0        = 4'd9,
        S_MR0_WAIT   = 4'd10,
        S_ZQCL       = 4'd11,
        S_ZQCL_WAIT  = 4'd12,
        S_READY      = 4'd13;

    reg [3:0]  state;
    reg [31:0] wait_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state         <= S_RESET;
            wait_cnt      <= RESET_CYC;
            cmd_valid     <= 1'b0;
            cmd_cs_ras_cas_we <= 3'b111;
            cmd_ba        <= 3'b0;
            cmd_addr      <= 16'b0;
            cmd_cke       <= 1'b0;
            cmd_reset_n   <= 1'b0;
            cmd_odt       <= 1'b0;
            ready         <= 1'b0;
        end else begin
            cmd_valid <= 1'b0;   // default: NOP, each state below overrides when it issues a real command

            case (state)
                S_RESET: begin
                    cmd_reset_n <= 1'b0;
                    cmd_cke     <= 1'b0;
                    if (wait_cnt == 0) begin
                        cmd_reset_n <= 1'b1;
                        wait_cnt    <= XPR_CYC;  // real hold before CKE per real board's own reset-release-to-CKE timing
                        state       <= S_CKE_WAIT;
                    end else begin
                        wait_cnt <= wait_cnt - 1;
                    end
                end

                S_CKE_WAIT: begin
                    if (wait_cnt == 0) begin
                        cmd_cke  <= 1'b1;
                        wait_cnt <= XPR_CYC;
                        state    <= S_XPR_WAIT;
                    end else begin
                        wait_cnt <= wait_cnt - 1;
                    end
                end

                S_XPR_WAIT: begin
                    if (wait_cnt == 0) state <= S_MR2;
                    else               wait_cnt <= wait_cnt - 1;
                end

                S_MR2: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_MRS;
                    cmd_ba            <= 3'b010;
                    cmd_addr          <= MR2_VAL;
                    wait_cnt          <= MRD_CYC - 1;
                    state             <= S_MR2_WAIT;
                end
                S_MR2_WAIT: begin
                    if (wait_cnt == 0) state <= S_MR3;
                    else               wait_cnt <= wait_cnt - 1;
                end

                S_MR3: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_MRS;
                    cmd_ba            <= 3'b011;
                    cmd_addr          <= MR3_VAL;
                    wait_cnt          <= MRD_CYC - 1;
                    state             <= S_MR3_WAIT;
                end
                S_MR3_WAIT: begin
                    if (wait_cnt == 0) state <= S_MR1;
                    else               wait_cnt <= wait_cnt - 1;
                end

                S_MR1: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_MRS;
                    cmd_ba            <= 3'b001;
                    cmd_addr          <= MR1_VAL;
                    wait_cnt          <= MRD_CYC - 1;
                    state             <= S_MR1_WAIT;
                end
                S_MR1_WAIT: begin
                    if (wait_cnt == 0) state <= S_MR0;
                    else               wait_cnt <= wait_cnt - 1;
                end

                S_MR0: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_MRS;
                    cmd_ba            <= 3'b000;
                    cmd_addr          <= MR0_VAL;
                    wait_cnt          <= MRD_CYC - 1;
                    state             <= S_MR0_WAIT;
                end
                S_MR0_WAIT: begin
                    if (wait_cnt == 0) state <= S_ZQCL;
                    else               wait_cnt <= wait_cnt - 1;
                end

                S_ZQCL: begin
                    cmd_valid         <= 1'b1;
                    cmd_cs_ras_cas_we <= CMD_ZQCL;
                    cmd_ba            <= 3'b0;
                    cmd_addr          <= 16'h0400;  // A10=1 selects ZQCL (long), all other bits don't-care
                    wait_cnt          <= ZQINIT_CYC - 1;
                    state             <= S_ZQCL_WAIT;
                end
                S_ZQCL_WAIT: begin
                    if (wait_cnt == 0) state <= S_READY;
                    else               wait_cnt <= wait_cnt - 1;
                end

                S_READY: begin
                    ready <= 1'b1;
                    // Stays here - refresh scheduling and the real
                    // read/write path are later, separate slices.
                end

                default: state <= S_RESET;
            endcase
        end
    end

    `undef NS2CYC
endmodule
