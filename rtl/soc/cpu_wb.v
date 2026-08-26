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
// Both ports are cached here rather than inside the core, for the same
// reason: a cache is about what the *bus* costs, and putting it here means
// one copy serves rtl/cpu_core.v and rtl/ooo/core_ooo.v both, with no core
// change at all. Each is direct-mapped, one word per line, read
// asynchronously so a hit costs no wait state. See the two sections below
// for why one word, and why the data side is write-through.
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
    // High while `imem_addr` is a held address from an in-flight ITLB walk,
    // not a translation of the fetch the core actually wants. See the
    // `fetch_hit`/`iwb_cyc` gating below and rtl/cpu_core.v's `itlb_pa_hold`
    // comment for why this exists.
    input  wire        itlb_wait_stall,

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
    // A direct-mapped instruction cache. On a hit we stop driving the bus
    // entirely, which is what keeps the fetch master from re-requesting the
    // same word every cycle while the pipeline is held up by something else
    // (a data access, a divide, an ITLB walk) - and, more importantly, from
    // holding `cyc` permanently asserted, which would be a lie about there
    // being an outstanding transfer.
    //
    // ---- Why one word per line ----
    //
    // No line fill, no burst, no fill state machine: a miss fetches exactly
    // the word that missed, using the same single-transfer machinery a
    // one-entry buffer used, and remembers it. That buys nothing on
    // straight-line code, where every new word still misses. It buys the
    // whole of a loop, which after the first iteration is served without
    // touching the bus at all.
    //
    // That is the right first shape here because of what the stall counters
    // say. `docs/roadmap.md` records 111,520 cycles of fetch starvation on
    // CoreMark, a benchmark that is almost entirely loops, and a word-granular
    // cache is a few dozen lines against a fill FSM's few hundred. Whether
    // spatial locality is worth adding on top is a question with a number
    // attached once this one is measured, which is the order those two should
    // happen in.
    //
    // ---- Why the arrays are read asynchronously ----
    //
    // `imem_addr` comes straight off the core's PC register and the core
    // expects `imem_rdata` in the same cycle unless `ibus_wait` says
    // otherwise. A synchronous read - which is what an ECP5 block RAM
    // offers - would add a wait state to every fetch including hits, and the
    // core's fetch buffer cannot hide it, because the PC only advances when
    // the fetch is not stalled. So these infer distributed LUT RAM, which is
    // why the cache is sized in hundreds of words rather than thousands:
    // 256 entries is roughly 900 LUT4s for data and tags together, against
    // an 85F's 84k. Making it much bigger means making it synchronous, and
    // that is a different design.
    //
    // Coherence is by invalidation only. RISC-V requires FENCE.I before
    // executing freshly-written code; `fence_i` clears every valid bit.
    localparam IC_ENTRIES  = 256;
    localparam IC_IDX_BITS = 8;                        // clog2(IC_ENTRIES)
    localparam IC_TAG_BITS = 32 - IC_IDX_BITS - 2;

    reg [IC_TAG_BITS-1:0] ic_tag  [0:IC_ENTRIES-1];
    reg [31:0]            ic_data [0:IC_ENTRIES-1];
    // A flat vector rather than an array, so FENCE.I can clear the whole
    // thing in one cycle instead of walking it.
    reg [IC_ENTRIES-1:0]  ic_valid;

    wire [IC_IDX_BITS-1:0] ic_idx     = imem_addr[IC_IDX_BITS+1:2];
    wire [IC_TAG_BITS-1:0] ic_tag_now = imem_addr[31:IC_IDX_BITS+2];

    wire fetch_hit_raw = ic_valid[ic_idx] && (ic_tag[ic_idx] == ic_tag_now);

    // While an ITLB walk is in flight, `imem_addr` is the held address from
    // before the walk started (rtl/cpu_core.v's `itlb_pa_hold`), not a
    // translation of the fetch the core actually wants. That held address
    // happening to already be cached is what has kept the fetch off the bus
    // during a walk so far - convenient, but never enforced by anything.
    // `itlb_wait_stall` makes it explicit instead of accidental: neither a
    // cache hit nor a new bus request (see `iwb_cyc` below) is reported
    // while it's high, so correctness stops depending on which address
    // happens to be sitting in `imem_addr` mid-walk.
    wire fetch_hit = fetch_hit_raw && !itlb_wait_stall;

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

    // `f_busy` alone is enough to keep a transfer already in flight going -
    // it was issued before `itlb_wait_stall` had any say, and Wishbone
    // requires `cyc`/`stb` to stay asserted until the ack regardless of
    // anything that changes about `imem_addr` in the meantime (see
    // `bus_addr` below). Only the decision to issue a *new* request is
    // gated on the walk.
    assign iwb_cyc = f_busy || (!itlb_wait_stall && !fetch_hit_raw);
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

    // Which entry an arriving word belongs in - keyed off `bus_addr`, not
    // `imem_addr`, because the two diverge the moment a branch redirects
    // mid-transfer and the word on its way back is for the old address.
    wire [IC_IDX_BITS-1:0] ic_fill_idx = bus_addr[IC_IDX_BITS+1:2];
    wire [IC_TAG_BITS-1:0] ic_fill_tag = bus_addr[31:IC_IDX_BITS+2];
    wire                   ic_fill     = iwb_ack && !f_poison;

    // Data and tag need no reset: an entry is only ever read when its valid
    // bit is set, and that bit is what reset and FENCE.I clear.
    always @(posedge clk) begin
        if (ic_fill) begin
            ic_data[ic_fill_idx] <= iwb_dat_r;
            ic_tag[ic_fill_idx]  <= ic_fill_tag;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst)            ic_valid <= {IC_ENTRIES{1'b0}};
        else if (fence_i)   ic_valid <= {IC_ENTRIES{1'b0}};
        else if (ic_fill)   ic_valid[ic_fill_idx] <= 1'b1;
    end

    assign imem_rdata = fetch_hit ? ic_data[ic_idx] : iwb_dat_r;
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
    wire want = dmem_re || dmem_we || dmem_is_amo;

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

    // =====================================================================
    // Data cache
    // =====================================================================
    // Same shape as the instruction cache above - direct-mapped, one word per
    // line, asynchronously read so a hit costs nothing - and for the same
    // reason: `docs/roadmap.md` measures 65,069 cycles of *load* bus-wait on
    // CoreMark against a total of 482,674, and this is what reaches them.
    // The other 1,233 cycles of data-bus stall are stores, which the wide
    // core's store buffer already absorbs.
    //
    // ---- Write policy: write-through, allocate only on a full-word store ----
    //
    // Write-through is not the fast policy; it is the policy that makes this
    // cache *provably* coherent with the rest of the system for free, and
    // that matters more here than the stores it doesn't accelerate:
    //
    //   - the MMU's page-table walkers read RAM through `wb_ram.v`'s second
    //     port, not through this bus. A write-back cache could hold a page
    //     table entry that a walker cannot see. Write-through cannot.
    //   - `rtl/soc/wb_framebuffer.v` is scanned out by video logic that never
    //     touches this adapter, so a pixel written into a dirty line would
    //     never appear.
    //   - UART, CLINT, PLIC, SPI and GPIO are not memory at all. Those are
    //     excluded by `dc_cacheable` rather than by policy, but a write-back
    //     cache would have to get *both* right.
    //
    // With every write going to the bus, memory is always the truth and this
    // cache only ever mirrors it. There is nothing to flush, nothing to write
    // back, no dirty bit, and no action on FENCE, SFENCE.VMA or a context
    // switch. (The tags are physical - `dmem_addr` is already translated when
    // it reaches here - so a context switch cannot alias.)
    //
    // Allocating on a full-word store miss is the one piece of extra reach
    // that costs nothing to justify: after the acknowledgement, memory holds
    // exactly `dwb_dat_w` at that address, so caching it needs no read. A
    // *partial* store to a line that isn't resident is left alone, because
    // filling it would need the other bytes, which would need a bus read.
    //
    // ---- What does not hit ----
    //
    // AMOs bypass the cache on the read phase. In a single-master system they
    // could safely be served from it - write-through means a hit is never
    // stale - but an atomic that reads memory is worth keeping literal, and
    // CoreMark contains none, so there is no measurement arguing the other
    // way. Their *write* phase still updates the line, which is what keeps a
    // later load from seeing the pre-AMO value.
    localparam DC_ENTRIES  = 256;
    localparam DC_IDX_BITS = 8;                        // clog2(DC_ENTRIES)
    localparam DC_TAG_BITS = 32 - DC_IDX_BITS - 2;

    reg [DC_TAG_BITS-1:0] dc_tag  [0:DC_ENTRIES-1];
    reg [31:0]            dc_data [0:DC_ENTRIES-1];
    reg [DC_ENTRIES-1:0]  dc_valid;

    // Which addresses may be cached, from the slave table in
    // `rtl/soc/soc_top.v`: RAM at 0x80_000000 and the boot ROM at
    // 0x00_000000. Everything between them is a peripheral, where a read has
    // a side effect or a value that changes without a write - a UART status
    // register, `mtime`. Caching those would not be slow, it would be wrong.
    wire dc_cacheable = (dmem_addr[31:24] == 8'h80) ||
                        (dmem_addr[31:24] == 8'h00);

    wire [DC_IDX_BITS-1:0] dc_idx     = dmem_addr[DC_IDX_BITS+1:2];
    wire [DC_TAG_BITS-1:0] dc_tag_now = dmem_addr[31:DC_IDX_BITS+2];
    wire [31:0]            dc_line    = dc_data[dc_idx];

    wire dc_present = dc_cacheable && dc_valid[dc_idx] &&
                      (dc_tag[dc_idx] == dc_tag_now);

    // A plain load that the cache can answer. `dmem_re` is low for AMO/LR/SC
    // and low while the store buffer owns the port, so neither can produce a
    // hit here.
    wire load_hit = dmem_re && dc_present;

    // The request that actually reaches the bus. A hit stops driving `cyc`
    // entirely, which - exactly as on the fetch side - both avoids a lie
    // about an outstanding transfer and hands the interconnect to the
    // instruction master for that cycle.
    wire req = want && !load_hit;

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

    wire read_ack  = dwb_ack && !dwb_we;
    wire write_ack = dwb_ack &&  dwb_we;

    // The word this entry should hold afterwards. On a returning load it is
    // what memory just gave us; on a store it is the resident word with the
    // written lanes replaced - which for a full-word store is just the store
    // data, so the allocate case needs no separate expression.
    wire [31:0] dc_merged = {
        dwb_sel[3] ? dwb_dat_w[31:24] : dc_line[31:24],
        dwb_sel[2] ? dwb_dat_w[23:16] : dc_line[23:16],
        dwb_sel[1] ? dwb_dat_w[15:8]  : dc_line[15:8],
        dwb_sel[0] ? dwb_dat_w[7:0]   : dc_line[7:0]
    };

    wire dc_fill  = read_ack  && dmem_re && dc_cacheable;
    wire dc_store = write_ack && dc_cacheable &&
                    (dc_present || (dwb_sel == 4'b1111));
    wire dc_update = dc_fill || dc_store;

    wire [31:0] dc_new = dc_fill ? dwb_dat_r : dc_merged;

    // `dmem_addr` is stable for the whole of a transfer - the core holds
    // EX/MEM while `dbus_wait` is high - so unlike the fetch side there is no
    // second copy of the address to keep, and the index that fills is the
    // index that missed.
    always @(posedge clk) begin
        if (dc_update) begin
            dc_data[dc_idx] <= dc_new;
            dc_tag[dc_idx]  <= dc_tag_now;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst)            dc_valid <= {DC_ENTRIES{1'b0}};
        else if (dc_update) dc_valid[dc_idx] <= 1'b1;
    end

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

    wire [31:0] read_word = load_hit ? dc_line
                          : read_ack ? dwb_dat_r
                                     : rdata_q;
    // Shift the addressed lane back down to where the core expects it. AMOs
    // are word accesses so this is a no-op for them.
    assign dmem_rdata  = read_word >> (8 * byte_off);
    assign dmem_rvalid = load_hit || read_ack;

    // A hit completes in the cycle it is asked for, which is the same
    // contract `rtl/dmem.v` offers the flat top level (`dbus_wait` tied low,
    // `dmem_rvalid` tied high). A miss is a single Wishbone transfer, and an
    // AMO's two phases are two separate waits with the core holding itself in
    // MEM across the gap.
    assign dbus_wait = req && !dwb_ack;

    // =====================================================================
    // Observability
    // =====================================================================
    // Nothing in the design reads these; the benchmark testbench does, by
    // hierarchical reference, and synthesis removes them. They exist because
    // "the data cache is worth N cycles" and "the data cache hits M% of the
    // time" are different claims, and only the second one says whether a
    // bigger cache would help or a different policy would.
    reg [31:0] dc_load_hits;
    reg [31:0] dc_load_misses;
    reg [31:0] dc_store_updates;
    reg [31:0] dc_uncached_reqs;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dc_load_hits     <= 32'b0;
            dc_load_misses   <= 32'b0;
            dc_store_updates <= 32'b0;
            dc_uncached_reqs <= 32'b0;
        end else begin
            if (load_hit)                    dc_load_hits     <= dc_load_hits + 32'd1;
            if (dc_fill)                     dc_load_misses   <= dc_load_misses + 32'd1;
            if (dc_store)                    dc_store_updates <= dc_store_updates + 32'd1;
            if (dwb_ack && !dc_cacheable)    dc_uncached_reqs <= dc_uncached_reqs + 32'd1;
        end
    end
endmodule
