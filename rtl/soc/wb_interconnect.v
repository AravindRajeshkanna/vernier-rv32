// Wishbone B4 "classic" shared-bus interconnect: NUM_HARTS (fetch, data)
// master pairs, one page-table-walk master per hart, one debug master
// shared by all harts, one NPU DMA master (also shared, regardless of hart
// count), NUM_SLAVES slaves, fixed-priority arbitration and a masked
// addr[31:24] address decode.
//
// ---- NUM_HARTS: generalized from a fixed 4-master shape ----
//
// Every hart gets its own fetch master, data master and page-table-walk
// master - the same three roles `rtl/cpu_core.v`/`rtl/ooo/core_ooo.v` and
// `rtl/soc/wb_ptw.v` already have today, just replicated per hart rather
// than named once. `NUM_HARTS=1` (the default, and every instantiation in
// this tree today - `rtl/soc/soc_top.v`) collapses every array below to
// exactly one element per role, and the arbitration reduces to precisely
// the original fixed order: debug > data > walker > fetch. Nothing has
// been asked to instantiate a second hart yet - see docs/roadmap.md's
// Phase 13 entry.
//
// ---- The third master role: page-table walks ----
//
// Each hart's own `rtl/soc/wb_ptw.v` arbitrates that hart's two Sv32
// walkers (icache, dcache) into one bus master port. They used to read
// PTEs through a second port on wb_ram.v's block RAM, which meant page
// tables could only live in block RAM - and an SDRAM has no second port,
// so that arrangement could never reach one. Linux puts page tables in
// DRAM, so the walkers had to become bus masters.
//
// ---- Priority: debug > data (by hart) > walker (by hart) > fetch (by hart)
// > NPU DMA ----
//
// Not the obvious order, and each comparison is load-bearing - unchanged
// in kind from the original 4-master version, just replicated per hart for
// the three per-hart roles. Within a tier that now has more than one
// candidate (two harts' data masters, say), the lowest hart index wins -
// a plain, provable tie-break, not round-robin fairness. That is safe for
// the same reason the original order does not starve fetch: every
// candidate's own access is one bounded transaction that then completes
// (cpu_wb.v/core_ooo.v freeze the issuing hart's own pipeline while it is
// outstanding), so losing arbitration costs whoever else wants the bus a
// few extra cycles' wait per access, never an unbounded one.
//
// **Data still outranks the walker**, which looks wrong for a requester
// everything else is waiting on, and is what keeps atomics atomic. Each
// hart's own core holds `cyc` across both phases of an AMO's
// read-modify-write and relies on that hart's own data master always
// winning against *any* walker (its own, or another hart's) to keep
// anyone else out of the gap. A walker that could preempt would break
// that - and it genuinely could ask during the gap, because instruction
// fetch carries on translating while the MEM stage sits in an AMO.
//
// This cannot deadlock, for the same reason it could not with one hart: a
// data access reaches the bus only from EX/MEM, by which point its address
// is already translated, so a hart's own data master is never waiting on
// a walker while holding the bus. It also cannot deadlock *across* harts -
// no hart's progress depends on another hart's walker completing.
//
// **The walker outranks fetch**, because fetch is nearly continuous and a
// walk that lost to it could be starved indefinitely. The reverse cannot
// happen: a walk is two reads and then it is over.
//
// **The NPU's own DMA master (`rtl/soc/wb_npu.v`) outranks nothing and
// starves nothing** - the opposite reasoning from every tier above it.
// Every other master's own priority is justified by what would go wrong if
// it lost: a stalled pipeline, a broken atomic, an indefinitely-delayed
// walk. Losing arbitration costs the NPU DMA master only its own wall-clock
// time - no hart's forward progress, and no correctness property, depends
// on it winning promptly, or at all. Placing it lowest is therefore not a
// judgment about its importance, only an acknowledgment that it is the one
// master here with nothing to lose by waiting.
//
// ---- Decode: base and mask ----
//
// `hit[i] = (adr[31:24] & mask[i]) == (base[i] & mask[i])`. A mask of 0xFF
// is one 16 MB region, which is what every slave had when the decode was a
// bare equality. The SDRAM's mask is 0xFE so it answers to two adjacent
// bases - 32 MB, which is the size of the part actually on the board. The
// alternative, decoding more address bits globally, would have shrunk every
// peripheral window to buy one slave more room.
//
// Shared bus, not a crossbar: exactly one master owns the bus at a time, so
// `adr`/`dat_w`/`we`/`sel` are a single broadcast copy and only `stb` is
// decoded per slave. A crossbar would let two masters to *different* slaves
// proceed in the same cycle; this doesn't, so a fetch behind a data access
// (or, now, behind another hart's access) costs a cycle. That's the classic
// single-port-memory SoC tradeoff, taken deliberately here for a much
// smaller and more obviously-correct interconnect.
//
// Arbitration is fixed priority and is *combinational while the bus is idle
// but latched for the duration of a transfer*. Both halves of that matter:
//
//  - **Combinational when idle** means starting a transfer costs nothing. A
//    registered "go to GRANT state" arbiter would add a cycle to every single
//    bus access, fetches included.
//  - **Latched once a transfer is under way** is what makes a multi-cycle
//    slave safe. Now that the memories are synchronous block RAMs with a wait
//    state (see wb_ram.v), a purely combinational grant would let a higher-
//    priority master take the bus in the middle of another master's read -
//    and then the RAM's ack, which belongs to that other master's address,
//    would be delivered along with that other master's data. Silent
//    corruption, not a hang.
//
// **Atomics** are safe because a data master's own lock stays held across
// an AMO's two phases, not because priority happens to re-win it. Each
// hart's core holds its own `dmem_is_amo` (and so `cyc`) for an AMO's
// entire read-then-write duration, one instruction the whole way through;
// on that master's own ack, this file re-locks to it rather than
// releasing, whenever `cyc` is still up for *that specific hart* (see
// `d_continuing`, below - specific to each hart's own data master,
// deliberately not a general "whoever still wants it keeps it" rule, and
// deliberately per-hart rather than "any data master" so hart A's
// follow-up phase cannot be satisfied by hart B happening to also be
// asking). Priority alone used to be given as the reason this was safe
// with a single data master ("master 1 immediately wins re-arbitration for
// the write phase"), which was true only as long as nothing else with
// equal-or-higher priority could also want the bus that same cycle - the
// debug module always could, rarely enough in practice not to matter, but
// a second *data* master would not be rare. Re-locking closes both cases
// the same way, without needing to reason about who else might be asking.
//
// **Every master must tie `stb` to `cyc`.** Arbitration grants on `cyc`
// alone, so a master that asserted `cyc` without `stb` - legal Wishbone, a
// master holding the bus between transfers - would take the bus and never
// strobe, blocking everyone else until it let go. Every core drives each
// pair from a single expression, so this holds by construction; the formal
// properties in formal/fv_interconnect.v assume it explicitly rather than
// leaving it as folklore.
//
// An access that decodes to no slave is acknowledged immediately with zero
// data rather than left hanging. A bus that never acks would wedge the
// issuing hart forever (its pipeline is frozen waiting on `ack`), turning a
// stray pointer into a silent hang instead of something the running
// program can survive.
module wb_interconnect #(
    parameter NUM_SLAVES = 7,
    parameter NUM_HARTS  = 1
)(
    input  wire        clk,
    input  wire        rst,

    // ---- per-hart instruction fetch masters (read-only) ----
    // Hart h's signals occupy bit/word h of each vector below.
    input  wire [NUM_HARTS-1:0]      f_cyc,
    input  wire [NUM_HARTS-1:0]      f_stb,
    input  wire [NUM_HARTS*32-1:0]   f_adr,
    output wire [NUM_HARTS*32-1:0]   f_dat_r,
    output wire [NUM_HARTS-1:0]      f_ack,

    // ---- per-hart data masters ----
    input  wire [NUM_HARTS-1:0]      d_cyc,
    input  wire [NUM_HARTS-1:0]      d_stb,
    input  wire [NUM_HARTS-1:0]      d_we,
    input  wire [NUM_HARTS*32-1:0]   d_adr,
    input  wire [NUM_HARTS*32-1:0]   d_dat_w,
    input  wire [NUM_HARTS*4-1:0]    d_sel,
    output wire [NUM_HARTS*32-1:0]   d_dat_r,
    output wire [NUM_HARTS-1:0]      d_ack,

    // ---- per-hart page-table-walk masters (read-only) ----
    input  wire [NUM_HARTS-1:0]      w_cyc,
    input  wire [NUM_HARTS-1:0]      w_stb,
    input  wire [NUM_HARTS*32-1:0]   w_adr,
    output wire [NUM_HARTS*32-1:0]   w_dat_r,
    output wire [NUM_HARTS-1:0]      w_ack,

    // ---- the debug module (rtl/debug/dm.v): one, regardless of hart count ----
    //
    // **Highest priority**, which is the opposite of what "a debugger should
    // not disturb the machine" suggests, and is deliberate.
    //
    // It issues at most one access at a time, and only when a host has
    // shifted a DMI transaction through the TAP - 41 TCK cycles, microseconds
    // apart at any plausible TCK against a 25 MHz system clock. So the
    // interference is one arbitration slot per access and is unmeasurable.
    //
    // The alternative starves it. A fetch master asserts `cyc` almost
    // continuously, so anything placed below it waits for a cache miss to
    // coincide with an idle data port, and a debugger reading a wedged
    // machine's memory is exactly the case where a hart is hammering the bus
    // in a loop. A debug port that works only when the machine is healthy is
    // not a debug port.
    input  wire        dbg_cyc,
    input  wire        dbg_stb,
    input  wire        dbg_we,
    input  wire [31:0] dbg_adr,
    input  wire [31:0] dbg_dat_w,
    input  wire [3:0]  dbg_sel,
    output wire [31:0] dbg_dat_r,
    output wire        dbg_ack,

    // ---- the NPU's own DMA master (rtl/soc/wb_npu.v): one, regardless of
    // hart count, the same shape the debug module above has ----
    //
    // **Lowest priority**, the opposite end of the scale from the debug
    // module and for a correspondingly opposite reason: nothing in this SoC
    // is waiting on this master to make progress. It has no forward-progress
    // dependency the way a page-table walker's own stalled pipeline does,
    // and no atomicity property depends on it winning arbitration promptly -
    // it can only ever be starved of the bus, never cause anything else to
    // be. Read-only, matching rtl/soc/wb_ptw.v's own master port shape - no
    // `n_we`/`n_dat_w`/`n_sel`, since this master never writes memory.
    input  wire        n_cyc,
    input  wire        n_stb,
    input  wire [31:0] n_adr,
    output wire [31:0] n_dat_r,
    output wire        n_ack,

    // ---- shared slave bus ----
    // `s_base` is the addr[31:24] value each slave answers to and `s_mask`
    // which of those bits are compared, both packed 8 bits per slave (slave i
    // occupies bits [8*i +: 8]). mask 0xFF is a 16 MB window; 0xFE is 32 MB.
    input  wire [NUM_SLAVES*8-1:0]  s_base,
    input  wire [NUM_SLAVES*8-1:0]  s_mask,
    output wire                      s_cyc,
    output wire [NUM_SLAVES-1:0]     s_stb,
    output wire                      s_we,
    output wire [31:0]               s_adr,
    output wire [31:0]               s_dat_w,
    output wire [3:0]                s_sel,
    input  wire [NUM_SLAVES*32-1:0]  s_dat_r,
    input  wire [NUM_SLAVES-1:0]     s_ack,

    // High when *some* hart's data master owns the bus. Peripherals with a
    // read side effect (the PLIC's claim register, the UART's RXDATA) gate
    // their read strobe on this, so a stray instruction fetch (or a walker
    // read) into MMIO space can't silently claim an interrupt or eat a
    // received byte. Which hart does not matter to a peripheral - only
    // whether this is a real data access, as opposed to fetch, a walker, or
    // the debug module (see `dbg_ack`'s own property in
    // formal/fv_interconnect.v for why debug must never assert this).
    output wire                      s_data_master
);
    // ---- per-hart AMO-follow-up detection, generalized from stage 1 ----
    //
    // Registered: did hart h's own data master ack *last* cycle, checked
    // against *this* cycle's d_cyc[h] - not the same-cycle d_ack[h], which
    // is trivially true for every transaction the instant it completes
    // (Wishbone cyc does not drop until the master reacts to seeing the
    // ack, one cycle later, so it is high at the ack cycle for an ordinary
    // access exactly as much as for an AMO) and so cannot tell a genuine
    // follow-up phase from an unrelated one just starting. This can: only a
    // master that immediately re-asserts cyc with nothing in between looks
    // like this, which is exactly what an AMO's read phase immediately
    // followed by its write phase does.
    reg  [NUM_HARTS-1:0] d_acked_prev;
    always @(posedge clk or posedge rst) begin
        if (rst) d_acked_prev <= {NUM_HARTS{1'b0}};
        else     d_acked_prev <= d_ack;
    end

    // Per-hart, deliberately: hart A's follow-up phase must not be
    // satisfiable by hart B merely also asking. Each hart's own immediate
    // follow-up wins arbitration unconditionally, ahead of even the debug
    // module - deliberately narrow (one cycle, specific to that hart's data
    // master), not a general "whoever still wants the bus keeps it" rule;
    // see this signal's own use below for why applying it to fetch or the
    // walker would be actively wrong (both can hold cyc continuously across
    // their own back-to-back but *unrelated* transactions, where losing
    // arbitration between them is correct, not a bug).
    wire [NUM_HARTS-1:0] d_continuing = d_acked_prev & d_cyc;
    wire                 any_continuing = |d_continuing;

    // At most one hart can be "continuing" in any reachable cycle (only the
    // hart that was actually granted the bus last cycle could have just
    // acked), but arbitration still needs a defined single winner for the
    // solver to reason about every input combination, reachable or not -
    // lowest hart index wins, same tie-break as every other tier below.
    wire [NUM_HARTS-1:0] continuing_win = d_continuing &
                                          ~(d_continuing - 1'b1);

    // ---- per-tier "lowest asking hart wins" priority encode ----
    //
    // want_T[h] is true only if hart h's own tier-T request is asking AND
    // no lower-indexed hart's tier-T request is also asking - a
    // combinational priority encoder, generalizing the original file's
    // single named bit per role to NUM_HARTS bits per role. NUM_HARTS=1
    // reduces each of these to a bare `cyc`, exactly as before.
    wire [NUM_HARTS-1:0] want_d_tier = d_cyc & ~(d_cyc - 1'b1);
    wire [NUM_HARTS-1:0] want_w_tier = w_cyc & ~(w_cyc - 1'b1);
    wire [NUM_HARTS-1:0] want_f_tier = f_cyc & ~(f_cyc - 1'b1);

    wire any_d_asking = |d_cyc;

    // ---- top-level tiers, in fixed priority order ----
    wire        want_dbg = dbg_cyc && !any_continuing;
    wire [NUM_HARTS-1:0] want_d = want_d_tier &
                                  {NUM_HARTS{!any_continuing && !dbg_cyc}};
    wire [NUM_HARTS-1:0] want_w = want_w_tier &
                                  {NUM_HARTS{!any_continuing && !dbg_cyc &&
                                              !any_d_asking}};
    wire [NUM_HARTS-1:0] want_f = want_f_tier &
                                  {NUM_HARTS{!any_continuing && !dbg_cyc &&
                                              !any_d_asking && !(|w_cyc)}};
    // Lowest of all: wins only when literally nothing else - debug, any
    // hart's data/walker/fetch master - wants the bus this cycle.
    wire        want_n = n_cyc &&
                         !any_continuing && !dbg_cyc && !any_d_asking &&
                         !(|w_cyc) && !(|f_cyc);

    reg        lock;
    reg        lock_dbg;
    reg  [NUM_HARTS-1:0] lock_d, lock_w, lock_f;
    reg        lock_n;

    // Only lock_d/lock_w/lock_f/lock_dbg/lock_n need to survive into the
    // lock - the mux below only ever asks "which master is selected", never
    // "was this cycle's selection the continuing override or the ordinary
    // tier-2 winner", so that distinction does not need its own storage.
    wire        sel_dbg        = lock ? lock_dbg        : want_dbg;
    wire [NUM_HARTS-1:0] sel_d = lock ? lock_d : (any_continuing ? continuing_win : want_d);
    wire [NUM_HARTS-1:0] sel_w = lock ? lock_w : want_w;
    wire [NUM_HARTS-1:0] sel_f = lock ? lock_f : want_f;
    wire        sel_n          = lock ? lock_n          : want_n;

    // A data master is selected either because it is genuinely the winning
    // tier-2 request, or because it is the one continuing a locked-in AMO -
    // `sel_d` already covers both (the ternary above), so this is just "any
    // hart's data master is the granted master."
    wire any_d_sel = |sel_d;

    assign s_data_master = any_d_sel;

    // ---- response mux over the selected master ----
    //
    // Built by OR-reducing each hart's contribution rather than a single
    // flat priority chain, since at most one of sel_dbg/any_d_sel/sel_w/
    // sel_f (and, within sel_d/sel_w/sel_f, at most one hart) is ever true -
    // guaranteed by construction above, not assumed.
    reg [31:0] cur_adr, cur_dat_w;
    reg [3:0]  cur_sel;
    reg        cur_we, cur_stb;
    integer h;
    always @(*) begin
        cur_adr   = 32'b0;
        cur_dat_w = 32'b0;
        cur_sel   = 4'b0;
        cur_we    = 1'b0;
        cur_stb   = 1'b0;
        if (sel_dbg) begin
            cur_adr = dbg_adr; cur_dat_w = dbg_dat_w; cur_sel = dbg_sel;
            cur_we  = dbg_we;  cur_stb   = dbg_stb;
        end
        for (h = 0; h < NUM_HARTS; h = h + 1) begin
            if (sel_d[h]) begin
                cur_adr = d_adr[32*h +: 32]; cur_dat_w = d_dat_w[32*h +: 32];
                cur_sel = d_sel[4*h +: 4];   cur_we    = d_we[h];
                cur_stb = d_stb[h];
            end
            if (sel_w[h]) begin
                cur_adr = w_adr[32*h +: 32]; cur_stb = w_stb[h];
            end
            if (sel_f[h]) begin
                cur_adr = f_adr[32*h +: 32]; cur_stb = f_stb[h];
            end
        end
        if (sel_n) begin
            cur_adr = n_adr; cur_stb = n_stb;
        end
    end

    assign s_cyc   = sel_dbg || any_d_sel || (|sel_w) || (|sel_f) || sel_n;
    assign s_we    = cur_we;
    assign s_adr   = cur_adr;
    assign s_dat_w = cur_dat_w;
    assign s_sel   = cur_sel;

    // ---- address decode ----
    reg  [NUM_SLAVES-1:0] hit;
    integer i;
    always @(*) begin
        for (i = 0; i < NUM_SLAVES; i = i + 1)
            hit[i] = ((s_adr[31:24] & s_mask[8*i +: 8]) ==
                      (s_base[8*i +: 8] & s_mask[8*i +: 8]));
    end

    assign s_stb = {NUM_SLAVES{cur_stb}} & hit;

    wire decoded = |hit;

    // ---- response mux ----
    reg [31:0] rsp_dat;
    reg        rsp_ack;
    always @(*) begin
        rsp_dat = 32'b0;
        rsp_ack = 1'b0;
        for (i = 0; i < NUM_SLAVES; i = i + 1) begin
            if (hit[i]) begin
                rsp_dat = s_dat_r[32*i +: 32];
                rsp_ack = s_ack[i];
            end
        end
    end

    // Unmapped address: ack straight away so a bad access surfaces as garbage
    // data rather than a hung core (see the header note).
    wire        fin_ack = cur_stb && (decoded ? rsp_ack : 1'b1);
    wire [31:0] fin_dat = decoded ? rsp_dat : 32'b0;

    genvar g;
    generate
        for (g = 0; g < NUM_HARTS; g = g + 1) begin : g_hart_resp
            assign f_dat_r[32*g +: 32] = fin_dat;
            assign d_dat_r[32*g +: 32] = fin_dat;
            assign w_dat_r[32*g +: 32] = fin_dat;
            assign f_ack[g] = sel_f[g] && fin_ack;
            assign d_ack[g] = sel_d[g] && fin_ack;
            assign w_ack[g] = sel_w[g] && fin_ack;
        end
    endgenerate
    assign dbg_dat_r = fin_dat;
    assign dbg_ack   = sel_dbg && fin_ack;
    assign n_dat_r   = fin_dat;
    assign n_ack     = sel_n && fin_ack;

    // Take the lock only when a transfer actually starts and does *not*
    // complete in its first cycle, so zero-wait-state slaves (the peripheral
    // bridges, and an unmapped address) behave exactly as they did before
    // this existed and never touch the lock at all. This mechanism is
    // unchanged by the continuing-override above - that one protects the
    // one-cycle *gap* between an ack and a possible same-hart follow-up,
    // entirely through the want_*/sel_* computation; this one protects an
    // already-granted multi-cycle transfer from being preempted mid-wait, a
    // different moment for a different reason. They compose rather than
    // interact: whichever master is decided by combinational priority (now
    // including the continuing override) is what gets locked in here if its
    // own transfer takes more than one cycle.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lock     <= 1'b0;
            lock_dbg <= 1'b0;
            lock_d   <= {NUM_HARTS{1'b0}};
            lock_w   <= {NUM_HARTS{1'b0}};
            lock_f   <= {NUM_HARTS{1'b0}};
            lock_n   <= 1'b0;
        end else if (!lock) begin
            if (cur_stb && !fin_ack) begin
                lock     <= 1'b1;
                lock_dbg <= sel_dbg;
                lock_d   <= sel_d;
                lock_w   <= sel_w;
                lock_f          <= sel_f;
                lock_n   <= sel_n;
            end
        end else if (fin_ack) begin
            lock <= 1'b0;
        end
    end
endmodule
