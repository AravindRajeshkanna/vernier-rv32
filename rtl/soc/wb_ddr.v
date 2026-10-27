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
// of this bus. A 16-byte block is therefore 8 columns, not 16, and a 32-bit word is two
// of them (beats 2k and 2k+1 of the block's burst, k = wb_adr[3:2]). Both lanes are used,
// so the capacity is the part's own: 8 banks x 32768 rows x 1024 columns x 2 bytes = 512MB.
//
// ---- A fill is one controller read (Phase 9 Stage 3, 8-beat bursts, part C, read half) ----
//
// A fill used to be eight reads, one per column, each keeping the first beat of the
// burst the DRAM sent and discarding the other seven. It is one read now: the slave asks
// for the block's first column and takes all eight columns from the burst that comes
// back (`read_burst` of rtl/soc/ddr3_ecp5_top.v: beat b is column b, because the
// request is for column 0 of an aligned 8). Measured on rtl/sim/tb_wb_ddr.v, a miss went
// from 8 READ commands and 122 clock cycles to 1 and about a seventh of that.
//
// The fill is over when `read_busy` falls, as before, and the contract this relies on is
// the controller's: a burst it reports arrives no later than the cycle `read_busy` falls
// (measured: in that very cycle; sim/tb_ddr3_burst_read.v checks it for every read, so a
// change to the sequencer that moved it later is caught there, not here). If the
// burst did not arrive by then - the controller rejects a read whose capture window it
// did not see open, and says so by not pulsing `read_burst_valid` - the access is
// acknowledged all the same (a hang would be worse), the block is NOT marked resident,
// and the next access to it fills it again. (Until this change a rejected column was
// simply left stale, and the block marked resident after its eighth read.) What an
// acknowledged access to such a block returns is whatever the buffer held: nothing here
// tells the bus master that the read failed, as before.
//
// ---- A store is one controller write (Phase 9 Stage 3, 8-beat bursts, part C, write half) ----
//
// A 32-bit store used to be up to two controller writes, one per column of the word, each
// storing its first beat and masking the other seven. It is one now: the word goes out as
// one burst to the block's first column, in beats 2k and 2k+1, with the byte selects as
// the mask of those beats (`write_burst_be`: bit 2*b is lane 0's for beat b, bit 2*b+1
// lane 1's) and every other beat masked in both lanes, so a store never disturbs another
// byte of the block. The word is replicated into all four pairs of beats (`{4{wb_dat_w}}`):
// only the pair the mask leaves open is stored, and the others carry data nobody reads.
// A store with no byte selected is acknowledged and sends nothing, as before. The slave
// stays write-through: a store goes to the DRAM whether or not the block is resident, and
// keeps a resident block's copy coherent (the lanes that were stored change).
//
// ---- What this does not establish ----
//
// The real, still-open "data path is not yet hardware-faithful" Known
// Defect (`docs/roadmap/phase-09-ddr.md`) is narrower than it was: a real x16 BL8 burst
// moves 16 real, distinct bytes in one electrical transaction, and a fill does that now.
// A store moves one 32-bit word in a burst whose other 12 bytes are masked; moving a
// whole block in one write (a write-back cache line) needs the block to be held dirty,
// and this slave is write-through. That gap stays open, named, and orthogonal to this
// stage's own "Done when" bar (a CPU executing real code from DDR in simulation), which
// does not require it. Nothing here has run on a board.
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
    input  wire        rst,        // the board's reset (the DRAM is reset with it)
    input  wire        rst_warm,   // the controller and this slave reset, the DRAM not (the debugger's ndmreset); see ddr3_ecp5_top.v

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
    // instance this module wraps (the ECPIX-5's: no CS#, RESET#, CK# or A15, Part 27) ----
    output wire        ddr3_ck,
    output wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n,
    output wire [2:0]  ddr3_ba,
    output wire [14:0] ddr3_a,
    output wire        ddr3_cke, ddr3_odt,
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
    reg  [127:0] write_burst;    // eight beats of {lane 1, lane 0}: the word in all four pairs, only one pair unmasked
    reg  [15:0] write_burst_be;  // bit 2*b: lane 0 stores beat b; bit 2*b+1: lane 1
    wire        write_busy;

    reg         read_req;
    reg  [2:0]  read_bank;
    reg  [15:0] read_row;
    reg  [15:0] read_col;
    wire        read_busy;
    wire [15:0] read_data;
    wire        read_data_valid;
    // The whole 8-beat burst of a read (Phase 9 Stage 3, part B): a fill takes the block from it (part C, read half).
    wire [127:0] read_burst;
    wire        read_burst_valid;

    ddr3_ecp5_top DDR (
        .clk(clk), .rst(rst), .rst_warm(rst_warm),
        .ddr3_ck(ddr3_ck),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .write_req(write_req), .write_bank(write_bank), .write_row(write_row),
        .write_col(write_col), .write_data(16'b0), .write_be(2'b00),
        .write_wide(1'b1), .write_burst(write_burst), .write_burst_be(write_burst_be),
        .write_busy(write_busy),
        .read_req(read_req), .read_bank(read_bank), .read_row(read_row),
        .read_col(read_col), .read_busy(read_busy), .read_data(read_data),
        .read_data_valid(read_data_valid),
        .read_burst(read_burst), .read_burst_valid(read_burst_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked), .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error),
        .calib1_done(calib1_done), .calib1_readclksel(calib1_readclksel),
        .calib1_error(calib1_error)
    );

    // ---- the sequencer: turns one Wishbone access into 1 real controller
    // read (a miss: the block, as one burst) or 1 real write (a store: the
    // word, as one burst, with wb_sel as its mask) - one at a time, the
    // controller accepts nothing else ----
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
        S_FILL_ISS   = 3'd1,   // issue read_req for the block's first column
        S_FILL_RISE  = 3'd2,   // wait for read_busy to assert
        S_FILL_WAIT  = 3'd3,   // wait for read_busy to drop; the burst has arrived by then, or the read was rejected
        S_STORE_ISS  = 3'd4,   // issue write_req for the word
        S_STORE_RISE = 3'd5,   // wait for write_busy to assert
        S_STORE_WAIT = 3'd6,   // wait for write_busy to drop
        S_ACK        = 3'd7;

    reg [2:0] state;
    reg       fill_got;    // the burst of the fill in progress has been taken into block_buf

    integer i;

    wire rst_bus = rst || rst_warm;   // this slave's own state resets on either
    always @(posedge clk or posedge rst_bus) begin
        if (rst_bus) begin
            state       <= S_IDLE;
            block_valid <= 1'b0;
            block_tag   <= 25'b0;
            write_req   <= 1'b0;
            read_req    <= 1'b0;
            fill_got    <= 1'b0;
            write_burst    <= 128'b0;
            write_burst_be <= 16'b0;
            for (i = 0; i < 8; i = i + 1) block_buf[i] <= 16'b0;
        end else begin
            write_req <= 1'b0;
            read_req  <= 1'b0;

            // read_burst_valid is a pulse tied to the PHY's own read-active
            // window, not guaranteed to land on the same cycle read_busy
            // itself falls (Part 18's own header has the full reasoning) -
            // captured unconditionally here rather than folded into the
            // busy-based transitions below, so the two can drift by a
            // cycle without losing data. It comes no later than the cycle read_busy
            // falls (see the header). The eight beats are the block's eight columns in
            // order: the request is for column 0 of an aligned 8.
            if (read_burst_valid) begin
                for (i = 0; i < 8; i = i + 1) block_buf[i] <= read_burst[16*i +: 16];
                fill_got <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    // Not before the controller is calibrated: it does not
                    // take a caller's request until calib_done (the sequencers
                    // are busy with calibration's own requests until then, and
                    // held in reset before that), so a request pulse sent
                    // earlier is dropped, while this state machine would wait
                    // on a busy that calibration's own activity raises and then
                    // acknowledge a transfer that never happened. A boot loader writing DDR3 right after
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
                            state <= S_STORE_ISS;
                        end else if (req_hit) begin
                            state    <= S_ACK;
                        end else begin
                            fill_got <= 1'b0;
                            state    <= S_FILL_ISS;
                        end
                    end
                end

                // ---- read miss: fetch the block, 8 columns, 16 real bytes, as one burst ----
                S_FILL_ISS: begin
                    if (!read_busy) begin
                        read_req  <= 1'b1;
                        read_bank <= req_bank;
                        read_row  <= {1'b0, req_row};
                        read_col  <= {6'b0, req_colh, 3'b000};
                        state     <= S_FILL_RISE;
                    end
                end
                S_FILL_RISE: if (read_busy) state <= S_FILL_WAIT;
                S_FILL_WAIT: begin
                    if (!read_busy) begin
                        // The burst's pulse can be in this very cycle (measured: read_busy falls in the cycle
                        // read_burst_valid pulses), so a burst that has not been taken yet counts too.
                        if (fill_got || read_burst_valid) begin
                            block_valid <= 1'b1;
                            block_tag   <= req_block;
                        end
                        state <= S_ACK;
                    end
                end

                // ---- store: write the word through, as one burst ----
                // The word is columns {offset[3:2], 0} (low half) and {offset[3:2], 1} (high half) of the block: beats
                // 2k and 2k+1 of a burst that starts at the block's first column. wb_sel's four bits are those two
                // columns' byte enables, lane 0 first, so the mask of the burst is wb_sel moved to bit 4k.
                S_STORE_ISS: begin
                    if (!write_busy) begin
                        if (wb_sel != 4'b0000) begin
                            write_req      <= 1'b1;
                            write_bank     <= req_bank;
                            write_row      <= {1'b0, req_row};
                            write_col      <= {6'b0, req_colh, 3'b000};
                            write_burst    <= {4{wb_dat_w}};
                            write_burst_be <= {12'b0, wb_sel} << {req_offset[3:2], 2'b00};
                            state          <= S_STORE_RISE;
                        end else begin
                            state <= S_ACK;
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
                            if (wb_sel[0]) block_buf[{req_offset[3:2], 1'b0}][7:0]  <= wb_dat_w[7:0];
                            if (wb_sel[1]) block_buf[{req_offset[3:2], 1'b0}][15:8] <= wb_dat_w[15:8];
                            if (wb_sel[2]) block_buf[{req_offset[3:2], 1'b1}][7:0]  <= wb_dat_w[23:16];
                            if (wb_sel[3]) block_buf[{req_offset[3:2], 1'b1}][15:8] <= wb_dat_w[31:24];
                        end
                        state <= S_ACK;
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
