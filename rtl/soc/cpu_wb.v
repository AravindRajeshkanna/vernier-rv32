// Adapts cpu_core.v's two native zero-latency memory ports onto two
// Wishbone B4 classic master interfaces, using the core's `ibus_wait` /
// `dbus_wait` stall inputs to hold the pipeline until each transaction is
// acknowledged.
//
// The core's page-table walker ports are deliberately *not* brought onto the
// bus - they stay wired straight to extra read ports on the RAM (see
// wb_ram.v). Page tables are already documented as living in plain RAM
// rather than MMIO, so putting the walkers on the bus would buy nothing and
// would cost a stall path inside mmu.v, whose FSM latches PTE data assuming
// it arrives combinationally.
//
// Requests are issued *combinationally*: `cyc`/`stb` come straight off the
// core's request signals rather than out of a state register, so against a
// zero-wait-state slave a transfer completes in the cycle it starts and
// memory costs exactly what it did before the bus existed. A registered
// "go to REQUEST state" FSM would have doubled the cost of every access.
//
// Endian/lane note: the core's native convention is that sub-word data sits
// in the *low* lanes with the exact byte address on the bus (that is what
// rtl/dmem.v implements). Wishbone instead wants a word-aligned address plus
// `sel` byte lanes, so this adapter shifts store data up into the addressed
// lane on the way out and shifts load data back down on the way in. That
// conversion assumes naturally-aligned accesses - a halfword on an even
// address, a word on a multiple of four. This core has no misaligned-access
// support to begin with and compilers don't emit misaligned accesses, so
// that assumption is safe, but it is an assumption.
module cpu_wb (
    input  wire        clk,
    input  wire        rst,

    // ---- native side: cpu_core.v ----
    input  wire [31:0] imem_addr,
    output wire [31:0] imem_rdata,
    output wire        ibus_wait,

    input  wire [31:0] dmem_addr,
    input  wire [31:0] dmem_wdata,
    input  wire        dmem_we,
    input  wire        dmem_re,
    input  wire        dmem_is_amo,
    input  wire [1:0]  dmem_size,
    output wire [31:0] dmem_rdata,
    output wire        dbus_wait,

    // FENCE.I: drop the cached fetch word. Without this the buffer can
    // serve a stale instruction for an address that was just written -
    // precisely the case a bootloader hits when it copies a program into
    // RAM and jumps to it.
    input  wire        fence_i,

    // ---- Wishbone master 0: instruction ----
    output wire        iwb_cyc,
    output wire        iwb_stb,
    output wire [31:0] iwb_adr,
    input  wire [31:0] iwb_dat_r,
    input  wire        iwb_ack,

    // ---- Wishbone master 1: data ----
    output wire        dwb_cyc,
    output wire        dwb_stb,
    output wire        dwb_we,
    output wire [31:0] dwb_adr,
    output wire [31:0] dwb_dat_w,
    output wire [3:0]  dwb_sel,
    input  wire [31:0] dwb_dat_r,
    input  wire        dwb_ack
);
    // =====================================================================
    // Instruction bus - always a word read, no lane shuffling.
    // =====================================================================
    // A one-entry fetch buffer: remember the address whose data we already
    // have. On a hit we stop driving the bus entirely, which is what keeps
    // the fetch master from re-requesting the same word every cycle while
    // the pipeline is held up by something else (a data access, a divide, an
    // ITLB walk) - and, more importantly, from holding `cyc` permanently
    // asserted, which would be a lie about there being an outstanding
    // transfer.
    //
    // Serving a cached word is only safe because the entry is tagged with
    // the full address and is a single entry, so it can never return data
    // for an address the core didn't just ask for. It is *not* coherent with
    // writes to that address - RISC-V requires FENCE.I before executing
    // freshly-written code, and this core has no instruction-cache
    // invalidation, so self-modifying code was already out of scope.
    reg [31:0] have_addr;
    reg [31:0] have_dat;
    reg        have_valid;

    wire fetch_hit = have_valid && (have_addr == imem_addr);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            have_valid <= 1'b0;
            have_addr  <= 32'b0;
            have_dat   <= 32'b0;
        end else if (fence_i) begin
            have_valid <= 1'b0;
        end else if (iwb_ack) begin
            have_valid <= 1'b1;
            have_addr  <= imem_addr;
            have_dat   <= iwb_dat_r;
        end
    end

    assign iwb_cyc = !fetch_hit;
    assign iwb_stb = !fetch_hit;
    assign iwb_adr = {imem_addr[31:2], 2'b00};

    assign imem_rdata = fetch_hit ? have_dat : iwb_dat_r;
    assign ibus_wait  = !fetch_hit && !iwb_ack;

    // =====================================================================
    // Data bus
    // =====================================================================
    // An AMO is a read-modify-write and needs two bus phases. `dmem_re` is
    // *not* asserted for AMO/LR/SC (the core doesn't classify them as
    // loads), so `dmem_is_amo` is what tells us a read is needed at all.
    wire req = dmem_re || dmem_we || dmem_is_amo;

    // Phase tracking for the AMO read-modify-write. `amo_wr_phase` only ever
    // goes high after the read has been acknowledged and the core has
    // decided it wants to write.
    reg amo_wr_phase;

    wire [1:0] byte_off = dmem_addr[1:0];

    // Byte lanes from the access size (00=byte, 01=half, 10=word).
    reg [3:0] sel_from_size;
    always @(*) begin
        case (dmem_size)
            2'b00:   sel_from_size = 4'b0001 << byte_off;
            2'b01:   sel_from_size = byte_off[1] ? 4'b1100 : 4'b0011;
            default: sel_from_size = 4'b1111;
        endcase
    end

    // Store data: the core supplies it in the low lanes, the bus wants it in
    // the addressed lane.
    wire [31:0] wdata_shifted = dmem_wdata << (8 * byte_off);

    // AMOs are word-only and word-aligned, so their data never needs
    // shifting - and during the write phase it must come from the *latched*
    // read value, because the core recomputes `dmem_wdata` combinationally
    // from whatever `dmem_rdata` currently shows.
    assign dwb_cyc   = req;
    assign dwb_stb   = req;
    assign dwb_we    = dmem_is_amo ? amo_wr_phase : dmem_we;
    assign dwb_adr   = {dmem_addr[31:2], 2'b00};
    assign dwb_sel   = dmem_is_amo ? 4'b1111 : sel_from_size;
    assign dwb_dat_w = dmem_is_amo ? dmem_wdata : wdata_shifted;

    // Read data latched at ack, so it stays stable for the AMO write phase
    // (the core's AMO ALU reads it to build the new value) and for the final
    // cycle when MEM/WB samples it.
    reg [31:0] rdata_q;
    always @(posedge clk or posedge rst) begin
        if (rst) rdata_q <= 32'b0;
        else if (dwb_ack && !dwb_we) rdata_q <= dwb_dat_r;
    end

    wire [31:0] read_word = (dwb_ack && !dwb_we) ? dwb_dat_r : rdata_q;
    // Shift the addressed lane back down to where the core expects it. AMOs
    // are word accesses so this is a no-op for them.
    assign dmem_rdata = read_word >> (8 * byte_off);

    // Completion. A plain access finishes on its single ack. An AMO finishes
    // on the read ack if the core decided not to write (a failed SC, or an
    // LR, which never writes), otherwise on the write ack.
    wire read_ack  = dwb_ack && !dwb_we;
    wire write_ack = dwb_ack &&  dwb_we;

    wire amo_needs_write = dmem_is_amo && dmem_we;
    wire done = dmem_is_amo ? (amo_wr_phase ? write_ack
                                             : (read_ack && !amo_needs_write))
                             : dwb_ack;

    always @(posedge clk or posedge rst) begin
        if (rst) amo_wr_phase <= 1'b0;
        else if (!req) amo_wr_phase <= 1'b0;
        else if (!amo_wr_phase && read_ack && amo_needs_write) amo_wr_phase <= 1'b1;
        else if (amo_wr_phase && write_ack) amo_wr_phase <= 1'b0;
    end

    assign dbus_wait = req && !done;
endmodule
