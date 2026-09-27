// Wishbone B4 classic slave in front of rtl/soc/ddr3_ecp5_top.v - Phase 9
// Stage 2, Part 1 (docs/roadmap.md).
//
// ---- The maintainer's own decision, now made: 16-byte burst, not
// byte-granular ----
//
// Every DDR3-side transaction moves a full, real 16-byte-aligned block -
// the same unit a real x16 BL8 burst would move in hardware, whether or not
// the CPU access that triggered it wanted all 16 bytes - not a single word.
// One block is held open at a time (the same "one open row, not four"
// simplification `rtl/soc/wb_sdram.v`'s own header already uses and
// reasons about, applied one level down: one open *block* here, not one
// open row - `rtl/soc/ddr3_ecp5_top.v` itself already tracks row/bank state
// per Part 14).
//
// ---- Why this needed no change to rtl/soc/ddr3_ecp5_top.v at all ----
//
// sim/ddr3_dq_model.v's own `find(bank,row,col)` is a plain, linear,
// arbitrary lookup: each (bank,row,col) is one independent byte-wide
// location, and a single `write_req`/`read_req` to the existing controller
// already reads or writes exactly one such location - automatically
// protecting its own "neighbour" column (`col^4`, the real BL8 wrap
// position) via DM, unconditionally, regardless of how many separate calls
// are issued at different columns (Part 22 already proved this; re-used
// here, not re-proven). So a 16-byte block is realized as up to 16
// independent single-byte controller calls, in sequence - this module adds
// no new PHY/serdes primitive and touches no file from Stage 1.
//
// ---- What this does not establish ----
//
// The real, still-open "data path is not yet hardware-faithful" Known
// Defect (`docs/roadmap.md`) is unchanged by this: a real x16 BL8 burst
// moves 16 real, distinct bytes in one electrical transaction, and this
// design still moves them as 16 separate ACT+WR/RD command sequences -
// correct, and now genuinely block-granular from the Wishbone side, but
// not a claim of hardware-faithful burst timing. That gap stays open,
// named, and orthogonal to this stage's own "Done when" bar (a CPU
// executing real code from DDR in simulation), which does not require it.
//
// Lane 1 does not carry real data yet (Part 24/25: calibration only), so
// this module's own real capacity is lane 0 alone: 8 banks x 32768 rows x
// 1024 columns x 1 byte = 256MB, not the real part's full 512MB. Wiring
// lane 1 for real data transfer, doubling this to 512MB, is separate,
// later work - not attempted here.
//
// Not wired into rtl/soc/soc_top.v yet - proven standalone first, the same
// "narrow proof first" discipline every part in Stage 1 already used.
//
// ---- Address mapping (256MB, byte-addressed) ----
//
//   wb_adr[27:4]   block index (24 bits) - which 16-byte block
//   wb_adr[3:0]    byte offset within the block (0-15)
//
//   block index[5:0]    -> col[9:4]   (64 blocks per row: 64 x 16B = 1KB)
//   block index[8:6]    -> bank[2:0]  (8 banks)
//   block index[23:9]   -> row[14:0]  (32768 rows)
//
// Chosen for the same locality reason `wb_sdram.v`'s own mapping is:
// consecutive blocks stay in the same row, so a real streaming access
// pattern (the common case) does not thrash rows. Not independently
// measured against a real access-pattern trace - reasoned, the same
// "reasoned, not yet measured" honesty this file's own precedent already
// uses for timing constants it has not benchmarked.
module wb_ddr (
    input  wire        clk,
    input  wire        rst,

    // ---- Wishbone B4 classic slave, matching rtl/soc/wb_ram.v's own port
    // names exactly ----
    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    input  wire [3:0]  wb_sel,
    output wire [31:0] wb_dat_r,
    output wire        wb_ack,

    // ---- real DDR3 pins - straight through to the ddr3_ecp5_top.v
    // instance this module wraps ----
    output wire        ddr3_ck, ddr3_ck_n,
    output wire        ddr3_cs_n, ddr3_ras_n, ddr3_cas_n, ddr3_we_n,
    output wire [2:0]  ddr3_ba,
    output wire [15:0] ddr3_a,
    output wire        ddr3_cke, ddr3_reset_n, ddr3_odt,
    inout  wire [7:0]  ddr3_dq,
    inout  wire        ddr3_dqs,
    output wire        ddr3_dm,
    inout  wire [7:0]  ddr3_dqu,
    inout  wire        ddr3_udqs,
    output wire        ddr3_udm,

    // ---- observability, matching every Stage 1 testbench's own
    // convention ----
    output wire        pll_locked,
    output wire        dll_locked,
    output wire        init_ready,
    output wire        calib_done,
    output wire [2:0]  calib_readclksel,
    output wire        calib_error,
    output wire        calib1_done,
    output wire [2:0]  calib1_readclksel,
    output wire        calib1_error,
    output wire        refresh_busy
);
    // ---- the block currently held open ----
    reg [23:0] block_tag;
    reg        block_valid;
    reg [7:0]  block_buf [0:15];

    wire [23:0] req_block  = wb_adr[27:4];
    wire [3:0]  req_offset = wb_adr[3:0];
    wire        req_hit    = block_valid && (block_tag == req_block);

    // block index -> (bank, row, col[9:4]) - see header
    wire [2:0]  req_bank = req_block[8:6];
    wire [14:0] req_row  = req_block[23:9];
    wire [5:0]  req_colh = req_block[5:0];

    // ---- the existing, unchanged Stage 1 controller ----
    reg         write_req;
    reg  [2:0]  write_bank;
    reg  [15:0] write_row;
    reg  [15:0] write_col;
    reg  [7:0]  write_data;
    wire        write_busy;

    reg         read_req;
    reg  [2:0]  read_bank;
    reg  [15:0] read_row;
    reg  [15:0] read_col;
    wire        read_busy;
    wire [7:0]  read_data;
    wire        read_data_valid;

    ddr3_ecp5_top DDR (
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n),
        .ddr3_cs_n(ddr3_cs_n), .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .write_req(write_req), .write_bank(write_bank), .write_row(write_row),
        .write_col(write_col), .write_data(write_data), .write_busy(write_busy),
        .read_req(read_req), .read_bank(read_bank), .read_row(read_row),
        .read_col(read_col), .read_busy(read_busy), .read_data(read_data),
        .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked), .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error),
        .calib1_done(calib1_done), .calib1_readclksel(calib1_readclksel),
        .calib1_error(calib1_error)
    );

    // ---- the sequencer: turns one Wishbone access into up to 16 real
    // single-byte controller calls (a miss) or up to 4 (a store, one per
    // set wb_sel bit) - one at a time, the controller accepts nothing
    // else ----
    // Each real controller call is accept-pulse-then-busy: `write_req`/
    // `read_req` is a single-cycle pulse, and `write_busy`/`read_busy`
    // itself only rises the cycle after - so a state that just checked
    // "!busy" right after issuing the pulse would see the *old*, still-low
    // busy and (wrongly) think the call was already done. Every call here
    // explicitly waits for busy to rise, then waits for it to fall again -
    // the same two-phase wait sim/tb_ddr3_cmd_seq.v's own testbench
    // stimulus already uses driving this exact interface by hand.
    localparam [2:0]
        S_IDLE       = 3'd0,
        S_FILL_ISS   = 3'd1,   // issue read_req for the current fill offset
        S_FILL_RISE  = 3'd2,   // wait for read_busy to assert
        S_FILL_WAIT  = 3'd3,   // wait for read_busy to drop, then next offset
        S_STORE_ISS  = 3'd4,   // issue write_req for the current byte
        S_STORE_RISE = 3'd5,   // wait for write_busy to assert
        S_STORE_WAIT = 3'd6,   // wait for write_busy to drop, then next byte
        S_ACK        = 3'd7;

    reg [2:0] state;
    reg [3:0] fill_off;    // 0-15, which byte of the block is being fetched
    reg [1:0] store_idx;   // 0-3, which wb_sel byte is being written

    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_IDLE;
            block_valid <= 1'b0;
            block_tag   <= 24'b0;
            write_req   <= 1'b0;
            read_req    <= 1'b0;
            fill_off    <= 4'b0;
            store_idx   <= 2'b0;
            for (i = 0; i < 16; i = i + 1) block_buf[i] <= 8'b0;
        end else begin
            write_req <= 1'b0;
            read_req  <= 1'b0;

            // read_data_valid is a pulse tied to the PHY's own read-active
            // window, not guaranteed to land on the same cycle read_busy
            // itself falls (Part 18's own header has the full reasoning) -
            // captured unconditionally here rather than folded into the
            // busy-based transitions below, so the two can drift by a
            // cycle without losing data.
            if (read_data_valid) block_buf[fill_off] <= read_data;

            case (state)
                S_IDLE: begin
                    if (wb_cyc && wb_stb) begin
                        if (wb_we) begin
                            // Write-through: correct regardless of whether
                            // the block is resident (Part 22's DM masking
                            // means a lone byte write never disturbs any
                            // other real location), so a store never needs
                            // a fill first.
                            store_idx <= 2'b0;
                            state     <= S_STORE_ISS;
                        end else if (req_hit) begin
                            state    <= S_ACK;
                        end else begin
                            fill_off <= 4'b0;
                            state    <= S_FILL_ISS;
                        end
                    end
                end

                // ---- read miss: fetch all 16 real bytes of the block ----
                S_FILL_ISS: begin
                    if (!read_busy) begin
                        read_req  <= 1'b1;
                        read_bank <= req_bank;
                        read_row  <= {1'b0, req_row};
                        read_col  <= {6'b0, req_colh, fill_off};
                        state     <= S_FILL_RISE;
                    end
                end
                S_FILL_RISE: if (read_busy) state <= S_FILL_WAIT;
                S_FILL_WAIT: begin
                    if (!read_busy) begin
                        if (fill_off == 4'd15) begin
                            block_valid <= 1'b1;
                            block_tag   <= req_block;
                            state       <= S_ACK;
                        end else begin
                            fill_off <= fill_off + 4'd1;
                            state    <= S_FILL_ISS;
                        end
                    end
                end

                // ---- store: write through each selected byte ----
                S_STORE_ISS: begin
                    if (!write_busy) begin
                        if (wb_sel[store_idx]) begin
                            write_req  <= 1'b1;
                            write_bank <= req_bank;
                            write_row  <= {1'b0, req_row};
                            write_col  <= {6'b0, req_colh, req_offset[3:2], store_idx};
                            write_data <= wb_dat_w[8*store_idx +: 8];
                            state      <= S_STORE_RISE;
                        end else if (store_idx == 2'd3) begin
                            state <= S_ACK;
                        end else begin
                            store_idx <= store_idx + 2'd1;
                        end
                    end
                end
                S_STORE_RISE: if (write_busy) state <= S_STORE_WAIT;
                S_STORE_WAIT: begin
                    if (!write_busy) begin
                        // Keep the open block's own cached copy coherent,
                        // so a later read of this same block does not
                        // return stale data without a re-fill.
                        if (block_valid && block_tag == req_block)
                            block_buf[{req_offset[3:2], store_idx}] <=
                                wb_dat_w[8*store_idx +: 8];
                        if (store_idx == 2'd3) begin
                            state <= S_ACK;
                        end else begin
                            store_idx <= store_idx + 2'd1;
                            state     <= S_STORE_ISS;
                        end
                    end
                end

                S_ACK: begin
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // req_offset[3:2] selects which of the block's 4 words the Wishbone
    // access wants; block_buf is addressed byte-wise, little-endian,
    // matching rtl/soc/wb_ram.v's own wb_dat_r byte lane convention.
    assign wb_dat_r = { block_buf[{req_offset[3:2], 2'd3}],
                        block_buf[{req_offset[3:2], 2'd2}],
                        block_buf[{req_offset[3:2], 2'd1}],
                        block_buf[{req_offset[3:2], 2'd0}] };
    assign wb_ack = (state == S_ACK);

endmodule
