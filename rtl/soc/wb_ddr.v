// Wishbone B4 classic slave in front of rtl/soc/ddr3_ecp5_top.v - Phase 9
// Stage 2, Part 1 (docs/roadmap/phase-09-ddr.md); x16 and 512 MB since Stage 2, Part 14.
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
// ---- The part is x16, so a column holds two bytes, and this uses both ----
//
// The controller moves a 16-bit word per request (Stage 1, Part 26): lane 0 is
// the even byte of the word and lane 1 the odd one, little-endian like the rest
// of this bus. A 16-byte block is therefore 8 columns, not 16: a fill is 8
// controller reads (it was 16, one per byte) and a 32-bit store is at most 2
// writes (it was at most 4), each carrying the byte enables of its half. Both
// lanes are used, so the capacity is the part's own: 8 banks x 32768 rows x
// 1024 columns x 2 bytes = 512MB.
//
// A request still moves one column, and the controller still masks the
// neighbour column its burst's second half would reach (Part 22), on both
// lanes, so a store of one column never disturbs another.
//
// ---- What this does not establish ----
//
// The real, still-open "data path is not yet hardware-faithful" Known
// Defect (`docs/roadmap/phase-09-ddr.md`) is unchanged by this: a real x16 BL8 burst
// moves 16 real, distinct bytes in one electrical transaction, and this
// design still moves them as 8 separate ACT+WR/RD command sequences -
// correct, and genuinely block-granular from the Wishbone side, but
// not a claim of hardware-faithful burst timing. That gap stays open,
// named, and orthogonal to this stage's own "Done when" bar (a CPU
// executing real code from DDR in simulation), which does not require it.
//
// ---- Address mapping (512MB, byte-addressed) ----
//
//   wb_adr[28:4]   block index (25 bits) - which 16-byte block
//   wb_adr[3:0]    byte offset within the block (0-15): [3:1] which of the
//                  block's 8 columns, [0] which lane (0 even, 1 odd)
//
//   block index[6:0]    -> col[9:3]   (128 blocks per row: 128 x 16B = 2KB, a
//                                      row of 1024 columns x 16 bits)
//   block index[9:7]    -> bank[2:0]  (8 banks)
//   block index[24:10]  -> row[14:0]  (32768 rows)
//
// The decode in rtl/soc/soc_top.v passes 0xA0-0xBF to this slave (mask 0xE0), and
// wb_adr[31:29] are not looked at.
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
    // ---- the block currently held open: 8 columns of 16 bits, lane 1's byte above lane 0's ----
    reg [24:0] block_tag;
    reg        block_valid;
    reg [15:0] block_buf [0:7];

    wire [24:0] req_block  = wb_adr[28:4];
    wire [3:0]  req_offset = wb_adr[3:0];
    wire        req_hit    = block_valid && (block_tag == req_block);

    // block index -> (bank, row, col[9:3]) - see header
    wire [2:0]  req_bank = req_block[9:7];
    wire [14:0] req_row  = req_block[24:10];
    wire [6:0]  req_colh = req_block[6:0];

    // ---- the existing, unchanged Stage 1 controller ----
    reg         write_req;
    reg  [2:0]  write_bank;
    reg  [15:0] write_row;
    reg  [15:0] write_col;
    reg  [15:0] write_data;
    reg  [1:0]  write_be;
    wire        write_busy;

    reg         read_req;
    reg  [2:0]  read_bank;
    reg  [15:0] read_row;
    reg  [15:0] read_col;
    wire        read_busy;
    wire [15:0] read_data;
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
        .write_col(write_col), .write_data(write_data), .write_be(write_be),
        .write_busy(write_busy),
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

    // ---- the sequencer: turns one Wishbone access into up to 8 real
    // 16-bit controller calls (a miss: the block's 8 columns) or up to 2 (a
    // store: one per half of the word that has a wb_sel bit set) - one at a
    // time, the controller accepts nothing else ----
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
    reg [2:0] fill_col;    // 0-7, which column of the block is being fetched
    reg       store_half;  // 0-1, which 16-bit half of the word is being written

    integer i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state       <= S_IDLE;
            block_valid <= 1'b0;
            block_tag   <= 25'b0;
            write_req   <= 1'b0;
            read_req    <= 1'b0;
            fill_col    <= 3'b0;
            store_half  <= 1'b0;
            write_be    <= 2'b00;
            for (i = 0; i < 8; i = i + 1) block_buf[i] <= 16'b0;
        end else begin
            write_req <= 1'b0;
            read_req  <= 1'b0;

            // read_data_valid is a pulse tied to the PHY's own read-active
            // window, not guaranteed to land on the same cycle read_busy
            // itself falls (Part 18's own header has the full reasoning) -
            // captured unconditionally here rather than folded into the
            // busy-based transitions below, so the two can drift by a
            // cycle without losing data.
            if (read_data_valid) block_buf[fill_col] <= read_data;

            case (state)
                S_IDLE: begin
                    // Not before the controller is calibrated: its command
                    // sequencers are held in reset until calib_done, so a
                    // request pulse sent earlier is dropped, while this state
                    // machine would wait on a busy that calibration's own
                    // activity raises and then acknowledge a transfer that
                    // never happened. A boot loader writing DDR3 right after
                    // reset lost the first byte of its image that way. Since
                    // Part 26 the controller waits for lane 1's calibration
                    // too, so this does as well.
                    if (wb_cyc && wb_stb && calib_done && calib1_done) begin
                        if (wb_we) begin
                            // Write-through: correct regardless of whether
                            // the block is resident (Part 22's DM masking
                            // means a lone byte write never disturbs any
                            // other real location, and Part 26's byte enables
                            // mask the lane a write does not store), so a
                            // store never needs a fill first.
                            store_half <= 1'b0;
                            state      <= S_STORE_ISS;
                        end else if (req_hit) begin
                            state    <= S_ACK;
                        end else begin
                            fill_col <= 3'b0;
                            state    <= S_FILL_ISS;
                        end
                    end
                end

                // ---- read miss: fetch the block's 8 columns, 16 real bytes ----
                S_FILL_ISS: begin
                    if (!read_busy) begin
                        read_req  <= 1'b1;
                        read_bank <= req_bank;
                        read_row  <= {1'b0, req_row};
                        read_col  <= {6'b0, req_colh, fill_col};
                        state     <= S_FILL_RISE;
                    end
                end
                S_FILL_RISE: if (read_busy) state <= S_FILL_WAIT;
                S_FILL_WAIT: begin
                    if (!read_busy) begin
                        if (fill_col == 3'd7) begin
                            block_valid <= 1'b1;
                            block_tag   <= req_block;
                            state       <= S_ACK;
                        end else begin
                            fill_col <= fill_col + 3'd1;
                            state    <= S_FILL_ISS;
                        end
                    end
                end

                // ---- store: write through each half of the word that has a byte selected ----
                // The word's low half is the column {offset[3:2], 0} and its high half the
                // column {offset[3:2], 1}; wb_sel's two bits for a half are that column's
                // byte enables, lane 0 first.
                S_STORE_ISS: begin
                    if (!write_busy) begin
                        if (wb_sel[2*store_half +: 2] != 2'b00) begin
                            write_req  <= 1'b1;
                            write_bank <= req_bank;
                            write_row  <= {1'b0, req_row};
                            write_col  <= {6'b0, req_colh, req_offset[3:2], store_half};
                            write_data <= wb_dat_w[16*store_half +: 16];
                            write_be   <= wb_sel[2*store_half +: 2];
                            state      <= S_STORE_RISE;
                        end else if (store_half) begin
                            state <= S_ACK;
                        end else begin
                            store_half <= 1'b1;
                        end
                    end
                end
                S_STORE_RISE: if (write_busy) state <= S_STORE_WAIT;
                S_STORE_WAIT: begin
                    if (!write_busy) begin
                        // Keep the open block's own cached copy coherent,
                        // so a later read of this same block does not
                        // return stale data without a re-fill. Only the
                        // lanes that were stored change.
                        if (block_valid && block_tag == req_block) begin
                            if (write_be[0])
                                block_buf[{req_offset[3:2], store_half}][7:0] <=
                                    write_data[7:0];
                            if (write_be[1])
                                block_buf[{req_offset[3:2], store_half}][15:8] <=
                                    write_data[15:8];
                        end
                        if (store_half) begin
                            state <= S_ACK;
                        end else begin
                            store_half <= 1'b1;
                            state      <= S_STORE_ISS;
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
    // access wants, two columns of it; each column is lane 1's byte over
    // lane 0's, so the word is little-endian, matching rtl/soc/wb_ram.v's
    // own wb_dat_r byte lane convention.
    assign wb_dat_r = { block_buf[{req_offset[3:2], 1'd1}],
                        block_buf[{req_offset[3:2], 1'd0}] };
    assign wb_ack = (state == S_ACK);

endmodule
