// Adapts cpu_core.v's two native zero-latency memory ports onto two
// Wishbone B4 classic master interfaces, using the core's `ibus_wait` /
// `dbus_wait` stall inputs to hold the pipeline until each transaction is
// acknowledged.
//
// The core's page-table walker ports are deliberately *not* brought onto the
// bus - they stay wired to the RAM's second port (see wb_ram.v). Page tables
// are already documented as living in plain RAM rather than MMIO, so putting
// the walkers on the bus would buy nothing and would cost bus arbitration on
// top of the read-port arbitration they already need.
//
// Requests are issued *combinationally*: `cyc`/`stb` come straight off the
// core's request signals rather than out of a state register, so against a
// zero-wait-state slave a transfer completes in the cycle it starts. A
// registered "go to REQUEST state" FSM would have added a cycle to every
// access, on top of the one the synchronous memories already cost.
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
    output wire        dmem_rvalid,
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

    // ---- the fetch currently on the bus ----
    // Now that memory takes a wait state, a fetch spans more than one cycle,
    // and `imem_addr` can change underneath it: a branch resolving in EX
    // asserts `redirect_valid`, which overrides the PC freeze that
    // `ibus_wait` would otherwise hold. Wishbone requires the address to be
    // stable for the duration of a transfer, and more concretely, the slave
    // has already latched the *old* address - so its ack carries the old
    // word. Freezing the bus address here is what keeps the two in step.
    reg        f_busy;
    reg [31:0] f_addr;
    reg        f_poison;

    wire [31:0] bus_addr = f_busy ? f_addr : imem_addr;

    assign iwb_cyc = f_busy || !fetch_hit;
    assign iwb_stb = iwb_cyc;
    assign iwb_adr = {bus_addr[31:2], 2'b00};

    // The ack only answers the core's *current* question if the transfer it
    // completes was for the address the core is asking about now. After a
    // redirect it is not, and the core has to wait for the next one.
    wire ack_for_current = iwb_ack && (bus_addr[31:2] == imem_addr[31:2]);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            f_busy   <= 1'b0;
            f_addr   <= 32'b0;
            f_poison <= 1'b0;
        end else if (iwb_ack) begin
            f_busy   <= 1'b0;
            f_poison <= 1'b0;
        end else if (iwb_cyc) begin
            f_busy <= 1'b1;
            f_addr <= bus_addr;
            // A FENCE.I retiring while a fetch is in flight poisons that
            // fetch: it was issued before the fence, so its data may predate
            // the writes the fence exists to publish. Dropping the result
            // rather than buffering it keeps a stale word from being cached
            // under a valid tag.
            if (fence_i) f_poison <= 1'b1;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            have_valid <= 1'b0;
            have_addr  <= 32'b0;
            have_dat   <= 32'b0;
        end else if (fence_i) begin
            have_valid <= 1'b0;
        end else if (iwb_ack && !f_poison) begin
            have_valid <= 1'b1;
            have_addr  <= bus_addr;
            have_dat   <= iwb_dat_r;
        end
    end

    assign imem_rdata = fetch_hit ? have_dat : iwb_dat_r;
    assign ibus_wait  = !fetch_hit && !ack_for_current;

    // =====================================================================
    // Data bus
    // =====================================================================
    // An AMO is a read-modify-write and needs two bus phases, but this
    // adapter no longer sequences them - cpu_core.v does, because it had to
    // grow that state anyway to keep the AMO ALU off the memory's read port
    // (see the AMO phase comment in its MEM stage). What arrives here is
    // already phased: `dmem_we` low for the read, high for the write. All
    // this side has to do is report, via `dmem_rvalid`, which acknowledgement
    // carried read data.
    //
    // `dmem_re` is *not* asserted for AMO/LR/SC (the core doesn't classify
    // them as loads), and during an AMO's read phase `dmem_we` is low too -
    // so `dmem_is_amo` is what tells us there is a request here at all.
    wire req = dmem_re || dmem_we || dmem_is_amo;

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
    // shifting. The write phase's data comes out of a register in the core,
    // which is the whole point of the split: nothing on this net traces back
    // combinationally to `dwb_dat_r`.
    assign dwb_cyc   = req;
    assign dwb_stb   = req;
    assign dwb_we    = dmem_we;
    assign dwb_adr   = {dmem_addr[31:2], 2'b00};
    assign dwb_sel   = dmem_is_amo ? 4'b1111 : sel_from_size;
    assign dwb_dat_w = dmem_is_amo ? dmem_wdata : wdata_shifted;

    wire read_ack = dwb_ack && !dwb_we;

    // Read data latched at ack so it stays stable past the ack cycle. The
    // core samples `dmem_rdata` in the cycle `dmem_rvalid` is high, which is
    // the ack cycle itself and is served by the bypass below - but an AMO's
    // read phase is followed by a write phase during which the core is still
    // in MEM, and holding the value costs one register.
    reg [31:0] rdata_q;
    always @(posedge clk or posedge rst) begin
        if (rst) rdata_q <= 32'b0;
        else if (read_ack) rdata_q <= dwb_dat_r;
    end

    wire [31:0] read_word = read_ack ? dwb_dat_r : rdata_q;
    // Shift the addressed lane back down to where the core expects it. AMOs
    // are word accesses so this is a no-op for them.
    assign dmem_rdata  = read_word >> (8 * byte_off);
    assign dmem_rvalid = read_ack;

    // Every phase is a single Wishbone transfer now, so completion is just
    // the acknowledgement. An AMO's two phases are two separate waits, and
    // the core holds itself in MEM across the gap between them.
    assign dbus_wait = req && !dwb_ack;
endmodule
