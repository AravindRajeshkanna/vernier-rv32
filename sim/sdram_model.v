`timescale 1ns/1ps
// Behavioural model of a 16-bit SDR SDRAM, for rtl/soc/wb_sdram.v to be
// tested against. Defaults describe the ULX3S's 32 MB part: 4 banks x 8192
// rows x 512 columns x 16 bits.
//
// ---- This model exists to say no ----
//
// A permissive memory model would let almost any controller pass. Every
// interesting SDRAM bug is a *protocol* bug - a read issued before tRCD, a
// refresh that never comes, a burst that walks off the end of a row, a
// column address with A[10] set so the part auto-precharges a row the
// controller still thinks is open - and none of those corrupt data in a way
// a write-then-read test would notice, on this timescale, in simulation.
// They corrupt data on a board, at temperature, weeks later.
//
// So this model checks, and stops the simulation with a message naming the
// rule rather than returning x and letting the failure surface somewhere
// else:
//
//   * no command at all until 100 us of NOP has elapsed since reset
//   * ACTIVE -> READ/WRITE no sooner than tRCD
//   * ACTIVE -> PRECHARGE no sooner than tRAS
//   * last write data -> PRECHARGE no sooner than tWR
//   * PRECHARGE -> ACTIVE no sooner than tRP
//   * ACTIVE -> ACTIVE on the same bank no sooner than tRC
//   * AUTO REFRESH -> anything no sooner than tRFC
//   * AUTO REFRESH only with every bank precharged
//   * READ/WRITE only to a bank with a row open
//   * ACTIVE only to a bank with no row open
//   * no gap between refreshes longer than twice tREFI
//   * a burst may not cross a row boundary
//   * CAS latency and burst length are taken from the mode register the
//     controller actually programmed, not from what this file would prefer
//
// The last one is the one that matters most: a controller that programs
// CL=3 and reads at CL=2 gets shifted data here, exactly as it would on
// silicon, rather than getting away with it because the model was written
// to match the controller.
//
// ---- Timing is in nanoseconds, not cycles ----
//
// So that running the same controller at a different clock is a real test
// rather than a rescaling of both sides of the same assumption.
//
// ---- Storage ----
//
// MEM_WORDS backs only the low part of the address space, and an access
// beyond it is an error rather than an alias. wb_ram.v aliases, and
// sim/tb_ramboot.v's header explains at length how much trouble that hid;
// there is no reason to reproduce it here.
module sdram_model #(
    parameter ROW_BITS  = 13,
    parameter COL_BITS  = 9,
    parameter BA_BITS   = 2,
    // 16-bit words actually backed by storage. 1 M words = 2 MB, which is
    // 32x what fits in block RAM and enough for any program this SoC runs in
    // simulation. Raising it costs simulator memory and nothing else.
    parameter MEM_WORDS = (1 << 20),
    // Timing, nanoseconds. Winbond W9825G6KH-6 / equivalent -6 speed grade.
    parameter real T_RCD_NS  = 18.0,
    parameter real T_RP_NS   = 18.0,
    parameter real T_RC_NS   = 60.0,
    parameter real T_RFC_NS  = 60.0,
    parameter real T_MRD_NS  = 12.0,
    parameter real T_RAS_NS  = 42.0,   // ACTIVE to PRECHARGE, same bank
    parameter real T_WR_NS   = 15.0,   // last write data to PRECHARGE
    parameter real T_INIT_NS = 100_000.0,
    parameter real T_REFI_NS = 7812.5,
    // Access time from the clock: how long after its own clock edge the part
    // actually drives read data onto the bus.
    //
    // Not decoration. Without it this model drives read data *at* its clock
    // edge, which is only indistinguishable from silicon while the part and
    // the controller share a clock edge. The moment fpga/sdram_clk_out.v
    // moved the part's clock 180 degrees - which is the fix for a real
    // hardware failure, see fpga/README.md - a zero-delay model put the data
    // a full controller-cycle early and reported a working design as broken.
    // A model that cannot represent the configuration being shipped is not a
    // check, so this is here and it is the datasheet's number.
    parameter real T_AC_NS   = 5.4
)(
    input  wire                clk,
    // A real SDRAM has no reset pin - you re-run the initialisation sequence
    // instead. This model has one anyway, because it models a part *in a
    // system*, and the system's reset is the only way it can be told that the
    // 100 us power-up is about to happen again. Without it the refresh-gap
    // check below fires part-way through every re-initialisation, which is
    // exactly what `make sim_rerun` does on purpose.
    input  wire                rst,
    input  wire                cke,
    input  wire                cs_n,
    input  wire                ras_n,
    input  wire                cas_n,
    input  wire                we_n,
    input  wire [ROW_BITS-1:0] a,
    input  wire [BA_BITS-1:0]  ba,
    input  wire [1:0]          dqm,
    inout  wire [15:0]         dq
);
    localparam NBANKS = (1 << BA_BITS);
    localparam NCOLS  = (1 << COL_BITS);

    // ---- storage ----
    reg [15:0] mem [0:MEM_WORDS-1];

    // ---- per-bank state ----
    reg                 bank_active [0:NBANKS-1];
    reg [ROW_BITS-1:0]  bank_row    [0:NBANKS-1];
    real                t_active    [0:NBANKS-1];  // when this bank went ACTIVE
    real                t_precharge [0:NBANKS-1];  // when it was last closed
    real                t_write_end [0:NBANKS-1];  // last write data accepted

    // ---- mode register, as programmed ----
    reg [2:0] mr_burst_code;
    reg       mr_burst_type;
    reg [2:0] mr_cas;
    reg       mr_programmed;
    integer   cl;
    integer   bl;

    // ---- housekeeping ----
    real    t_last_refresh;
    real    t_refresh_done;
    real    t_mrs_done;
    integer refresh_count;
    integer i;

    // ---- read return pipeline ----
    // Loaded at the edge a READ is registered, at index cl-1 and cl, and
    // shifted down one place per clock, so a word loaded at cl-1 is on the
    // bus T_AC_NS after the following edge and stays for one period.
    //
    // This indexing was changed to cl/cl+1 while chasing the hardware failure
    // in fpga/README.md, on the reasoning that CAS latency means the data is
    // *launched* cl edges after the command. That made the configuration the
    // board actually ran fail catastrophically in simulation - and the board
    // did not fail catastrophically, it failed one word in a thousand. The
    // bench is the ground truth and the change was reverted. What the bench
    // could not have told us, and T_AC_NS below could, is how little margin
    // that pairing has.
    localparam PIPE = 8;
    reg [15:0] pipe_d [0:PIPE-1];
    reg        pipe_v [0:PIPE-1];

    // ---- write burst in progress ----
    integer            wr_left;
    reg [BA_BITS-1:0]  wr_bank;
    reg [COL_BITS-1:0] wr_col;

    // ---- read burst bookkeeping, for the row-crossing check ----
    integer rd_col_check;

    assign #T_AC_NS dq = pipe_v[0] ? pipe_d[0] : 16'bzzzz_zzzz_zzzz_zzzz;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101,
                     C_WR  = 4'b0100, C_PRE = 4'b0010, C_REF = 4'b0001,
                     C_MRS = 4'b0000, C_BST = 4'b0110;

    // Deselect: cs_n high, whatever the rest of the bus is doing.
    wire selected = !cs_n;

    task fail(input [1023:0] why);
        begin
            $display("");
            $display("SDRAM PROTOCOL ERROR at %0t ns: %0s", $time, why);
            $display("  bank states: %0d %0d %0d %0d  refreshes so far: %0d",
                     bank_active[0], bank_active[1], bank_active[2],
                     bank_active[3], refresh_count);
            $fatal(1);
        end
    endtask

    function [31:0] flat_addr(input [BA_BITS-1:0] b,
                              input [ROW_BITS-1:0] r,
                              input [COL_BITS-1:0] c);
        // Must be the inverse of the mapping in rtl/soc/wb_sdram.v. Written
        // out rather than shared, so that a change on one side shows up as a
        // failing test instead of following the other side silently.
        flat_addr = ({19'b0, r} << (COL_BITS + BA_BITS)) |
                    ({30'b0, b} << COL_BITS) |
                    {23'b0, c};
    endfunction

    initial begin
        for (i = 0; i < NBANKS; i = i + 1) begin
            bank_active[i] = 1'b0;
            bank_row[i]    = {ROW_BITS{1'b0}};
            t_active[i]    = 0.0;
            t_precharge[i] = 0.0;
            t_write_end[i] = 0.0;
        end
        for (i = 0; i < PIPE; i = i + 1) begin
            pipe_v[i] = 1'b0;
            pipe_d[i] = 16'b0;
        end
        mr_programmed  = 1'b0;
        cl             = 0;
        bl             = 0;
        t_last_refresh = 0.0;
        t_refresh_done = 0.0;
        t_mrs_done     = 0.0;
        refresh_count  = 0;
        wr_left        = 0;
        wr_bank        = {BA_BITS{1'b0}};
        wr_col         = {COL_BITS{1'b0}};
        rd_col_check   = 0;
    end

    // Re-initialisation. Storage survives, as it does on a board; the
    // protocol state does not, because the controller is about to redo the
    // power-up sequence and everything it programmed is gone. `refresh_count`
    // is deliberately cumulative - it is a statistic the testbenches print,
    // not part of the protocol.
    always @(posedge rst) begin
        for (i = 0; i < NBANKS; i = i + 1) begin
            bank_active[i] = 1'b0;
            t_precharge[i] = $realtime;
            t_active[i]    = 0.0;
            t_write_end[i] = 0.0;
        end
        for (i = 0; i < PIPE; i = i + 1) pipe_v[i] = 1'b0;
        mr_programmed  = 1'b0;
        wr_left        = 0;
        t_last_refresh = $realtime;
        t_refresh_done = 0.0;
        t_mrs_done     = 0.0;
    end

    // A row that is never refreshed keeps its contents forever in a model and
    // loses them on a board, so the gap is checked here instead. Twice tREFI
    // rather than exactly tREFI, because a refresh legitimately waits for an
    // in-flight burst to finish; ten times would not catch a controller that
    // refreshes an order of magnitude too slowly, which is the bug worth
    // catching.
    always @(posedge clk) begin
        if (mr_programmed && ($realtime - t_last_refresh) > (2.0 * T_REFI_NS))
            fail("no AUTO REFRESH within 2x tREFI - rows are losing data");
    end

    integer bidx;
    integer cidx;
    integer widx;

    always @(posedge clk) begin
        // ---- read pipeline shifts every cycle ----
        for (i = 0; i < PIPE-1; i = i + 1) begin
            pipe_v[i] <= pipe_v[i+1];
            pipe_d[i] <= pipe_d[i+1];
        end
        pipe_v[PIPE-1] <= 1'b0;

        // ---- a write burst already under way takes the bus data ----
        if (wr_left > 0) begin
            widx = flat_addr(wr_bank, bank_row[wr_bank], wr_col);
            if (widx >= MEM_WORDS)
                fail("write beyond the modelled storage - raise MEM_WORDS");
            if (!dqm[0]) mem[widx][7:0]  <= dq[7:0];
            if (!dqm[1]) mem[widx][15:8] <= dq[15:8];
            wr_left <= wr_left - 1;
            t_write_end[wr_bank] = $realtime;
            if (wr_col == (NCOLS-1) && wr_left > 1)
                fail("write burst crossed a row boundary");
            wr_col <= wr_col + 1'b1;
        end

        if (cke && selected && cmd != C_NOP) begin
            // ---- nothing at all before the power-up interval ----
            if (($realtime < T_INIT_NS) && (cmd != C_NOP))
                fail("command issued before the 100 us power-up interval");

            case (cmd)
            // -----------------------------------------------------------
            C_MRS: begin
                if (bank_active[0] || bank_active[1] ||
                    bank_active[2] || bank_active[3])
                    fail("LOAD MODE REGISTER with a bank still active");
                mr_burst_code = a[2:0];
                mr_burst_type = a[3];
                mr_cas        = a[6:4];
                if (a[10] !== 1'b0 || a[9] !== 1'b0)
                    fail("LOAD MODE REGISTER with reserved bits set");
                case (mr_burst_code)
                    3'b000: bl = 1;
                    3'b001: bl = 2;
                    3'b010: bl = 4;
                    3'b011: bl = 8;
                    default: fail("mode register: reserved burst length");
                endcase
                if (mr_cas != 3'd2 && mr_cas != 3'd3)
                    fail("mode register: CAS latency must be 2 or 3");
                cl            = mr_cas;
                mr_programmed = 1'b1;
                t_mrs_done    = $realtime + T_MRD_NS;
                $display("SDRAM: mode register programmed - CL=%0d BL=%0d %s",
                         cl, bl, mr_burst_type ? "interleaved" : "sequential");
            end
            // -----------------------------------------------------------
            C_ACT: begin
                if (!mr_programmed) fail("ACTIVE before the mode register was set");
                if ($realtime < t_mrs_done) fail("ACTIVE within tMRD of LOAD MODE REGISTER");
                if ($realtime < t_refresh_done) fail("ACTIVE within tRFC of AUTO REFRESH");
                if (bank_active[ba]) fail("ACTIVE to a bank that already has a row open");
                if ($realtime < (t_precharge[ba] + T_RP_NS))
                    fail("ACTIVE within tRP of the PRECHARGE that closed this bank");
                if ($realtime < (t_active[ba] + T_RC_NS))
                    fail("ACTIVE within tRC of the previous ACTIVE on this bank");
                bank_active[ba] = 1'b1;
                bank_row[ba]    = a;
                t_active[ba]    = $realtime;
            end
            // -----------------------------------------------------------
            C_RD: begin
                if (!bank_active[ba]) fail("READ to a bank with no row open");
                if ($realtime < (t_active[ba] + T_RCD_NS))
                    fail("READ within tRCD of ACTIVE");
                if (a[10] !== 1'b0)
                    fail("READ with A[10] set: that is read auto-precharge, and this controller believes the row stays open");
                bidx = flat_addr(ba, bank_row[ba], a[COL_BITS-1:0]);
                if ((bidx + bl) > MEM_WORDS)
                    fail("read beyond the modelled storage - raise MEM_WORDS");
                if ((a[COL_BITS-1:0] + bl) > NCOLS)
                    fail("read burst would cross a row boundary");
                for (i = 0; i < bl; i = i + 1) begin
                    pipe_v[cl - 1 + i] <= 1'b1;
                    pipe_d[cl - 1 + i] <= mem[bidx + i];
                end
            end
            // -----------------------------------------------------------
            C_WR: begin
                if (!bank_active[ba]) fail("WRITE to a bank with no row open");
                if ($realtime < (t_active[ba] + T_RCD_NS))
                    fail("WRITE within tRCD of ACTIVE");
                if (a[10] !== 1'b0)
                    fail("WRITE with A[10] set - that is write auto-precharge");
                cidx = flat_addr(ba, bank_row[ba], a[COL_BITS-1:0]);
                if ((cidx + bl) > MEM_WORDS)
                    fail("write beyond the modelled storage - raise MEM_WORDS");
                if ((a[COL_BITS-1:0] + bl) > NCOLS)
                    fail("write burst would cross a row boundary");
                // The first word of a write burst is on the bus in the same
                // cycle as the command, which is what makes writes and reads
                // asymmetric and is a classic off-by-one in a controller.
                if (!dqm[0]) mem[cidx][7:0]  <= dq[7:0];
                if (!dqm[1]) mem[cidx][15:8] <= dq[15:8];
                t_write_end[ba] = $realtime;
                wr_bank <= ba;
                wr_col  <= a[COL_BITS-1:0] + 1'b1;
                wr_left <= bl - 1;
            end
            // -----------------------------------------------------------
            C_PRE: begin
                // tRAS and tWR are the two intervals a controller gets wrong
                // by closing a row as soon as it has what it wanted. Neither
                // shows up as bad data in simulation; tRAS violated on a board
                // is a row that was never fully restored, and tWR violated is
                // a write that was still in flight.
                if (a[10]) begin
                    for (i = 0; i < NBANKS; i = i + 1) begin
                        if (bank_active[i]) begin
                            if ($realtime < (t_active[i] + T_RAS_NS))
                                fail("PRECHARGE ALL within tRAS of an ACTIVE");
                            if ($realtime < (t_write_end[i] + T_WR_NS))
                                fail("PRECHARGE ALL within tWR of a write");
                            t_precharge[i] = $realtime;
                        end
                        bank_active[i] = 1'b0;
                    end
                end else begin
                    if (bank_active[ba]) begin
                        if ($realtime < (t_active[ba] + T_RAS_NS))
                            fail("PRECHARGE within tRAS of the ACTIVE on this bank");
                        if ($realtime < (t_write_end[ba] + T_WR_NS))
                            fail("PRECHARGE within tWR of a write to this bank");
                        t_precharge[ba] = $realtime;
                    end
                    bank_active[ba] = 1'b0;
                end
            end
            // -----------------------------------------------------------
            C_REF: begin
                if (bank_active[0] || bank_active[1] ||
                    bank_active[2] || bank_active[3])
                    fail("AUTO REFRESH with a bank still active");
                if ($realtime < t_refresh_done)
                    fail("AUTO REFRESH within tRFC of the previous one");
                refresh_count  = refresh_count + 1;
                t_last_refresh = $realtime;
                t_refresh_done = $realtime + T_RFC_NS;
            end
            // -----------------------------------------------------------
            C_BST: ;   // burst terminate: legal, and this controller never uses it
            default: fail("unrecognised command on the SDRAM bus");
            endcase
        end
    end

    // `refresh_count` is read by the testbench through a hierarchical
    // reference, so "the controller refreshed" is reported as a number rather
    // than as an absence of complaints.
endmodule
