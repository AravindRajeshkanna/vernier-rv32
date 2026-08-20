// Wishbone B4 classic slave in front of a 16-bit SDR SDRAM.
//
// This is the module docs/roadmap.md's Phase 2 calls for: `wb_ram.v` is 64 KB
// of block RAM on the board because 256 KB costs 244 ECP5 block RAMs and no
// ECP5 has them, and the ULX3S carries 32 MB of SDRAM that nothing could
// reach. Everything above this speaks Wishbone and knows only a base address
// and a size, which is exactly the seam `wb_ram.v`'s header promised.
//
// ---- Why hand-written rather than LiteDRAM ----
//
// The roadmap named LiteDRAM via LiteX as the well-trodden path, and for DDR
// it would be the only sane one. This is *SDR* SDRAM: no read levelling, no
// write levelling, no calibration, no PHY training - a command truth table
// and six timing numbers. Against that, LiteX is a Python build dependency
// producing a Verilog blob that this repo could not simulate against its own
// SDRAM model, could not run through `make formal`, and could not gate in CI
// without installing a toolchain to generate it. `sim/sdram_model.v` plus
// this file is ~450 lines that the existing verification layers all reach.
//
// ---- The device ----
//
// Parameterised, with defaults for the ULX3S's 32 MB part (Winbond W9825G6KH
// or equivalent): 4 banks x 8192 rows x 512 columns x 16 bits. A 32-bit
// Wishbone word is therefore *two* SDRAM accesses, done as one burst-of-2
// command rather than two commands - which is why the mode register below
// sets BL=2 and why `wb_adr[1]` is not part of the column address.
//
// Address mapping, chosen for locality rather than for looking tidy:
//
//   wb_adr[24:12]  row       consecutive words stay in one row
//   wb_adr[11:10]  bank      banks rotate every 1 KB
//   wb_adr[9:1]    column    512 columns x 2 bytes = 1 KB per row
//
// A 32-bit access is aligned, so `wb_adr[1]` is 0 and the burst's second
// column is `col+1` in the same row and bank. Nothing here has to handle a
// burst crossing a row boundary, and the model asserts that it never does.
//
// ---- Timing ----
//
// Every interval is derived from CLK_HZ rather than written as a cycle count,
// because a cycle count is only correct at one frequency and this design has
// already been run at more than one. At 25 MHz (tCK = 40 ns) most of these
// round to a single cycle, which is what makes an SDR controller at this
// speed tractable: the part is far faster than the bus in front of it.
//
// ---- What this does not do yet, and what it costs ----
//
//   * **One open row, not four.** The controller tracks a single active
//     bank/row and precharges when an access needs a different one. Per-bank
//     open rows are the obvious next step and would remove the precharge from
//     an interleaved access pattern - but `rtl/soc/cpu_wb.v` now holds an
//     instruction cache and a data cache that between them absorb 96.3% of
//     loads and the whole of every loop, so the traffic reaching this module
//     is mostly cache misses, which are mostly sequential. That is an
//     argument for measuring before building, not for assuming.
//   * **One transfer at a time.** No bank pipelining, no posted writes. The
//     Wishbone in front of it is single-transfer classic anyway.
//   * **No ECC, no scrubbing.** Refresh is the only thing keeping data alive.
module wb_sdram #(
    // Must match the clock actually driving `clk`. Getting this too *low*
    // makes the controller refresh more often than needed and violate
    // nothing; too high and rows go unrefreshed and lose data - so the safe
    // direction of error is downward. sim/sdram_model.v checks the interval
    // that actually appears rather than trusting this.
    parameter CLK_HZ   = 25_000_000,
    parameter ROW_BITS = 13,
    parameter COL_BITS = 9,
    parameter BA_BITS  = 2
)(
    input  wire        clk,
    input  wire        rst,

    // ---- Wishbone B4 classic slave ----
    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    input  wire [3:0]  wb_sel,
    output wire [31:0] wb_dat_r,
    output wire        wb_ack,

    // ---- SDRAM pins ----
    // The bidirectional data bus is split into out/in/enable here rather than
    // being an `inout`, so that everything below the board wrapper stays
    // synthesizable without tristates and simulates without a bus-fight
    // model. `fpga/ulx3s_top.v` is the only place a real IO buffer appears -
    // the same split rtl/soc/wb_gpio.v already uses for the GPIO header.
    output wire                 sdram_cke,
    output wire                 sdram_cs_n,
    output wire                 sdram_ras_n,
    output wire                 sdram_cas_n,
    output wire                 sdram_we_n,
    output wire [ROW_BITS-1:0]  sdram_a,
    output wire [BA_BITS-1:0]   sdram_ba,
    output wire [1:0]           sdram_dqm,
    output wire [15:0]          sdram_dq_o,
    output wire                 sdram_dq_oe,
    input  wire [15:0]          sdram_dq_i,

    // High once the power-up sequence has finished. Nothing in the SoC uses
    // it - a request before then simply waits, which is the behaviour the
    // CPU already has machinery for - but it is the one bit of internal state
    // worth bringing out for a testbench to assert on.
    output wire                 sdram_ready
);
    // =====================================================================
    // Command truth table: {cs_n, ras_n, cas_n, we_n}
    // =====================================================================
    localparam [3:0] CMD_INHIBIT = 4'b1111,
                     CMD_NOP     = 4'b0111,
                     CMD_ACTIVE  = 4'b0011,
                     CMD_READ    = 4'b0101,
                     CMD_WRITE   = 4'b0100,
                     CMD_PRE     = 4'b0010,
                     CMD_REFRESH = 4'b0001,
                     CMD_MRS     = 4'b0000;

    // Mode register: burst length 2, sequential, CAS latency 2, standard
    // operation, programmed burst length for writes as well as reads.
    //
    //   A[2:0] = 001   burst length 2
    //   A[3]   = 0     sequential (not interleaved)
    //   A[6:4] = 010   CAS latency 2
    //   A[8:7] = 00    standard operation
    //   A[9]   = 0     burst read and burst write
    //
    // CL=2 rather than 3 because CL=2 is in spec for every SDR part at or
    // below 100 MHz, and this bus runs at 25.
    localparam [12:0] MODE_REG = 13'b0_00_00_010_0_001;

    // =====================================================================
    // Timing, in cycles, from CLK_HZ
    // =====================================================================
    // ceil(ns * MHz / 1000), floored at one cycle - a zero-cycle interval
    // would let two commands land on the same edge.
    localparam integer CLK_MHZ = CLK_HZ / 1_000_000;
    `define NS2CYC(ns) (((((ns) * CLK_MHZ) + 999) / 1000) < 1 ? \
                        1 : ((((ns) * CLK_MHZ) + 999) / 1000))

    localparam integer T_RP  = `NS2CYC(20);   // precharge to next command
    localparam integer T_RCD = `NS2CYC(20);   // active to read/write
    localparam integer T_RFC = `NS2CYC(66);   // refresh to next command
    localparam integer T_MRD = 2;             // mode register set, in tCK
    localparam integer T_WR  = 2;             // write recovery, in tCK
    localparam integer CAS_LATENCY = 2;

    // 100 us of NOPs with CKE high before anything else is allowed. Every SDR
    // datasheet opens with this and it is the one initialisation step that
    // looks safe to skip in simulation and is not: sim/sdram_model.v refuses
    // to answer a command issued before it elapses, so a controller that
    // shortened it here would fail the unit test rather than only the board.
    localparam integer T_INIT = (CLK_HZ / 10000);   // 100 us

    // 8192 rows in 64 ms is one refresh every 7.8 us. Rounded down via 128000
    // rather than up, because refreshing early is free and refreshing late
    // loses data.
    localparam integer T_REFI = (CLK_HZ / 128000);

    localparam integer CNT_BITS = 16;   // holds T_INIT at 100 MHz

    // =====================================================================
    // Address decomposition
    // =====================================================================
    wire [COL_BITS-1:0] a_col  = wb_adr[COL_BITS:1];
    wire [BA_BITS-1:0]  a_bank = wb_adr[COL_BITS+BA_BITS : COL_BITS+1];
    wire [ROW_BITS-1:0] a_row  = wb_adr[COL_BITS+BA_BITS+ROW_BITS :
                                        COL_BITS+BA_BITS+1];

    // The column driven for a READ/WRITE command, from the latched request.
    // A[10] must be 0 or the part reads the command as "auto-precharge",
    // which would close the row this controller is trying to keep open.
    // COL_BITS is 9 so A[10] sits above the column field, and it is zeroed
    // explicitly rather than left to luck.
    wire [ROW_BITS-1:0] col_a_of_req;

    // PRECHARGE with A[10]=1 closes every bank, which is what both the
    // initialisation sequence and refresh want.
    wire [ROW_BITS-1:0] pre_all_a = {{(ROW_BITS-11){1'b0}}, 1'b1, 10'b0};

    // =====================================================================
    // State
    // =====================================================================
    localparam [3:0] S_INIT_WAIT = 4'd0,
                     S_INIT_PRE  = 4'd1,
                     S_INIT_REF  = 4'd2,
                     S_INIT_MRS  = 4'd3,
                     S_IDLE      = 4'd4,
                     S_ACTIVE    = 4'd5,
                     S_READ      = 4'd6,
                     S_READ_LO   = 4'd7,
                     S_READ_HI   = 4'd8,
                     S_WRITE_LO  = 4'd9,
                     S_WRITE_HI  = 4'd10,
                     S_PRECHARGE = 4'd11,
                     S_REFRESH   = 4'd12,
                     S_ACK       = 4'd13;

    reg [3:0]          state;
    reg [CNT_BITS-1:0] tmr;          // cycles left before the state may act
    reg [3:0]          init_refs;    // the 8 refreshes the power-up needs

    reg [3:0]          cmd_r;
    reg [ROW_BITS-1:0] a_r;
    reg [BA_BITS-1:0]  ba_r;
    reg [1:0]          dqm_r;
    reg [15:0]         dq_o_r;
    reg                dq_oe_r;
    reg                cke_r;

    reg                row_open;
    reg [BA_BITS-1:0]  open_bank;
    reg [ROW_BITS-1:0] open_row;

    reg [31:0]         rdata_r;
    reg                ack_r;
    reg                ready_r;

    // Refresh is owed until it is issued, not merely requested: a refresh
    // deferred behind an in-flight transfer is still owed. One outstanding is
    // all this needs, because T_REFI is 195 cycles at 25 MHz and the longest
    // transfer here is under ten.
    //
    // `refresh_taken` exists to settle the one cycle where the interval timer
    // expires *and* a refresh is being issued. Both want to write
    // `refresh_due`, and with the clear living in the state machine below the
    // clear would win - silently dropping the newly-owed refresh. Rolling both
    // into the counter block, with the tick winning, makes that cycle leave
    // one still owed, which is the truth. The window is one cycle in 195 and
    // the model's tREFI check would only catch a systematic version of it.
    reg [CNT_BITS-1:0] refi_ctr;
    reg                refresh_due;

    // Latched request. Wishbone classic holds `cyc`/`stb`/`adr` until `ack`,
    // so this is redundant - and it is here anyway, because "the master holds
    // it" is an assumption about somebody else's module and the cost of not
    // relying on it is three registers.
    reg [ROW_BITS-1:0] req_row;
    reg [BA_BITS-1:0]  req_bank;
    reg [COL_BITS-1:0] req_col;
    reg [31:0]         req_dat;
    reg [3:0]          req_sel;
    reg                req_we;

    wire req = wb_cyc && wb_stb && !ack_r;

    assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} = cmd_r;
    assign sdram_a      = a_r;
    assign sdram_ba     = ba_r;
    assign sdram_dqm    = dqm_r;
    assign sdram_dq_o   = dq_o_r;
    assign sdram_dq_oe  = dq_oe_r;
    assign sdram_cke    = cke_r;
    assign wb_dat_r     = rdata_r;
    assign wb_ack       = ack_r;
    assign sdram_ready  = ready_r;

    // Whether the currently open row is the one the pending request wants.
    wire row_hit = row_open && (open_bank == req_bank) && (open_row == req_row);

    // Exactly the condition under which S_REFRESH's body runs this cycle -
    // that is, the cycle the AUTO REFRESH command is registered. Both terms
    // are registers, so this closes no loop.
    wire refresh_taken = (state == S_REFRESH) && (tmr == 0);

    generate
        if (ROW_BITS > COL_BITS + 1)
            assign col_a_of_req = {{(ROW_BITS-COL_BITS-1){1'b0}}, 1'b0, req_col};
        else
            assign col_a_of_req = req_col[ROW_BITS-1:0];
    endgenerate

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_INIT_WAIT;
            tmr         <= T_INIT[CNT_BITS-1:0];
            init_refs   <= 4'd8;
            cmd_r       <= CMD_INHIBIT;
            a_r         <= {ROW_BITS{1'b0}};
            ba_r        <= {BA_BITS{1'b0}};
            dqm_r       <= 2'b11;
            dq_o_r      <= 16'b0;
            dq_oe_r     <= 1'b0;
            // CKE goes high immediately and stays there. The 100 us wait is
            // measured with the clock running and CKE asserted; the part is
            // in self-refresh only if CKE is taken low, which this controller
            // never does.
            cke_r       <= 1'b1;
            row_open    <= 1'b0;
            open_bank   <= {BA_BITS{1'b0}};
            open_row    <= {ROW_BITS{1'b0}};
            rdata_r     <= 32'b0;
            ack_r       <= 1'b0;
            ready_r     <= 1'b0;
            refi_ctr    <= T_REFI[CNT_BITS-1:0];
            refresh_due <= 1'b0;
            req_row     <= {ROW_BITS{1'b0}};
            req_bank    <= {BA_BITS{1'b0}};
            req_col     <= {COL_BITS{1'b0}};
            req_dat     <= 32'b0;
            req_sel     <= 4'b0;
            req_we      <= 1'b0;
        end else begin
            // Defaults, overridden below. Issuing NOP every cycle a state
            // does not explicitly drive a command is what keeps a command
            // from being held for two cycles by accident - which the part
            // would read as two commands.
            cmd_r   <= CMD_NOP;
            dq_oe_r <= 1'b0;
            ack_r   <= 1'b0;

            // Refresh accounting runs regardless of state, including during
            // initialisation, where it is simply ignored until S_IDLE.
            if (refi_ctr == 0) begin
                refi_ctr    <= T_REFI[CNT_BITS-1:0];
                refresh_due <= 1'b1;
            end else begin
                refi_ctr <= refi_ctr - 1'b1;
                if (refresh_taken) refresh_due <= 1'b0;
            end

            if (tmr != 0) begin
                tmr <= tmr - 1'b1;
            end else begin
                case (state)
                // ---- power-up ------------------------------------------
                S_INIT_WAIT: begin
                    cmd_r <= CMD_PRE;
                    a_r   <= pre_all_a;
                    tmr   <= T_RP[CNT_BITS-1:0] - 1'b1;
                    state <= S_INIT_PRE;
                end
                S_INIT_PRE: begin
                    cmd_r     <= CMD_REFRESH;
                    tmr       <= T_RFC[CNT_BITS-1:0] - 1'b1;
                    init_refs <= init_refs - 1'b1;
                    state     <= S_INIT_REF;
                end
                S_INIT_REF: begin
                    if (init_refs != 0) begin
                        cmd_r     <= CMD_REFRESH;
                        tmr       <= T_RFC[CNT_BITS-1:0] - 1'b1;
                        init_refs <= init_refs - 1'b1;
                    end else begin
                        cmd_r <= CMD_MRS;
                        a_r   <= MODE_REG[ROW_BITS-1:0];
                        ba_r  <= {BA_BITS{1'b0}};
                        tmr   <= T_MRD[CNT_BITS-1:0] - 1'b1;
                        state <= S_INIT_MRS;
                    end
                end
                S_INIT_MRS: begin
                    ready_r <= 1'b1;
                    state   <= S_IDLE;
                end

                // ---- running -------------------------------------------
                S_IDLE: begin
                    if (refresh_due) begin
                        // Close everything, then refresh. A refresh with any
                        // bank open is illegal, and the model says so.
                        if (row_open) begin
                            cmd_r    <= CMD_PRE;
                            a_r      <= pre_all_a;
                            row_open <= 1'b0;
                            tmr      <= T_RP[CNT_BITS-1:0] - 1'b1;
                        end
                        state <= S_REFRESH;
                    end else if (req) begin
                        req_row  <= a_row;
                        req_bank <= a_bank;
                        req_col  <= a_col;
                        req_dat  <= wb_dat_w;
                        req_sel  <= wb_sel;
                        req_we   <= wb_we;
                        state    <= S_ACTIVE;
                    end
                end

                S_REFRESH: begin
                    cmd_r <= CMD_REFRESH;
                    tmr   <= T_RFC[CNT_BITS-1:0] - 1'b1;
                    state <= S_IDLE;   // `refresh_due` is cleared above
                end

                // Decide what the latched request needs: the open row, a
                // different row (precharge first), or no open row at all.
                S_ACTIVE: begin
                    if (row_hit) begin
                        state <= req_we ? S_WRITE_LO : S_READ;
                    end else if (row_open) begin
                        cmd_r    <= CMD_PRE;
                        a_r      <= pre_all_a;
                        row_open <= 1'b0;
                        tmr      <= T_RP[CNT_BITS-1:0] - 1'b1;
                        state    <= S_PRECHARGE;
                    end else begin
                        cmd_r     <= CMD_ACTIVE;
                        a_r       <= req_row;
                        ba_r      <= req_bank;
                        row_open  <= 1'b1;
                        open_bank <= req_bank;
                        open_row  <= req_row;
                        tmr       <= T_RCD[CNT_BITS-1:0] - 1'b1;
                        state     <= req_we ? S_WRITE_LO : S_READ;
                    end
                end

                S_PRECHARGE: begin
                    cmd_r     <= CMD_ACTIVE;
                    a_r       <= req_row;
                    ba_r      <= req_bank;
                    row_open  <= 1'b1;
                    open_bank <= req_bank;
                    open_row  <= req_row;
                    tmr       <= T_RCD[CNT_BITS-1:0] - 1'b1;
                    state     <= req_we ? S_WRITE_LO : S_READ;
                end

                // ---- read: one burst-of-2 command, two words back -------
                //
                // **This assumes the part is clocked 180 degrees from here**,
                // which is what fpga/sdram_clk_out.v arranges. The two are a
                // matched pair and neither is correct without the other.
                //
                // Why, in nanoseconds, at 25 MHz (tCK 40, tAC 5.4). The
                // command is registered here, so it is on the pins for the
                // following cycle and the part latches it on its own next
                // edge - half a cycle later with the shifted clock, a full
                // cycle later without. From there CAS latency applies, and
                // each word sits on the bus for one period:
                //
                //   part clocked from clk, capture at CL     w0 arrives 34.6 ns
                //     before the capture edge and is replaced 5.4 ns after it
                //   part clocked 180 out, capture at CL-1    w0 arrives 14.6 ns
                //     before and is replaced 25.4 ns after
                //
                // The first of those is what shipped, and 5.4 ns of hold is
                // what a board turned into one wrong word in a thousand: any
                // DQ line slower than its neighbours takes the *next* burst
                // word's value, so a bit that differs between the two halves
                // of a word comes back wrong. The failing word in
                // fpga/README.md is exactly that - bit 12 is 1 in the low
                // half and 0 in the high half, and it read back 0.
                //
                // Writes get the same treatment for free: with the part
                // clocked half a period away from the moment this drives new
                // data, it sees 20 ns of setup and 20 ns of hold instead of a
                // full period of setup and none at all.
                S_READ: begin
                    cmd_r <= CMD_READ;
                    a_r   <= col_a_of_req;
                    ba_r  <= req_bank;
                    dqm_r <= 2'b00;
                    tmr   <= CAS_LATENCY[CNT_BITS-1:0] - 1'b1;
                    state <= S_READ_LO;
                end
                S_READ_LO: begin
                    rdata_r[15:0] <= sdram_dq_i;
                    state         <= S_READ_HI;
                end
                S_READ_HI: begin
                    rdata_r[31:16] <= sdram_dq_i;
                    ack_r          <= 1'b1;
                    state          <= S_IDLE;
                end

                // ---- write: same command, data on the two following cycles
                // DQM is the byte mask and is driven *with* the data, not
                // before it: for a write, DQM is sampled in the same cycle as
                // the data it masks. Getting that a cycle early would mask
                // the wrong half of the word, which is the failure the
                // byte-lane case in sim/tb_sdram.v exists to catch.
                S_WRITE_LO: begin
                    cmd_r   <= CMD_WRITE;
                    a_r     <= col_a_of_req;
                    ba_r    <= req_bank;
                    dq_o_r  <= req_dat[15:0];
                    dq_oe_r <= 1'b1;
                    dqm_r   <= ~req_sel[1:0];
                    state   <= S_WRITE_HI;
                end
                S_WRITE_HI: begin
                    dq_o_r  <= req_dat[31:16];
                    dq_oe_r <= 1'b1;
                    dqm_r   <= ~req_sel[3:2];
                    ack_r   <= 1'b1;
                    // Write recovery before the row may be precharged. The
                    // next state that can precharge is S_ACTIVE or a
                    // refresh, and both are reached through S_IDLE, so
                    // spending it here covers every path out.
                    tmr     <= T_WR[CNT_BITS-1:0] - 1'b1;
                    state   <= S_IDLE;
                end

                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
