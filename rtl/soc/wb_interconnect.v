// Wishbone B4 "classic" shared-bus interconnect: 3 masters, NUM_SLAVES
// slaves, fixed-priority arbitration and a masked addr[31:24] address decode.
//
// ---- The third master: page-table walks ----
//
// Master 2 is rtl/soc/wb_ptw.v, the two Sv32 walkers arbitrated into one
// port. They used to read PTEs through a second port on wb_ram.v's block
// RAM, which meant page tables could only live in block RAM - and an SDRAM
// has no second port, so that arrangement could never reach one. Linux puts
// page tables in DRAM, so the walkers had to become bus masters.
//
// ---- Priority: data > walker > fetch ----
//
// Not the obvious order, and each of the two comparisons is load-bearing.
//
// **Data still outranks the walker**, which looks wrong for a requester
// everything else is waiting on, and is what keeps atomics atomic. cpu_wb.v
// holds `cyc` across both phases of an AMO's read-modify-write and relies on
// the data master always winning to keep anyone else out of the gap. A
// walker that could preempt would break that - and it genuinely could ask
// during the gap, because instruction fetch carries on translating while the
// MEM stage sits in an AMO.
//
// This cannot deadlock. A data access reaches the bus only from EX/MEM, by
// which point its address is already translated: while a data walk is in
// flight the instruction that needs it is still in EX and has issued
// nothing. So the data master is never waiting on the walker while holding
// the bus.
//
// **The walker outranks fetch**, because fetch is nearly continuous and a
// walk that lost to it could be starved indefinitely. The reverse cannot
// happen: a walk is two reads and then it is over.
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
// decoded per slave. A crossbar would let an instruction fetch and a data
// access to *different* slaves proceed in the same cycle; this doesn't, so a
// load/store costs the fetch behind it a cycle. That's the classic
// single-port-memory SoC tradeoff, taken deliberately here for a much
// smaller and more obviously-correct interconnect.
//
// Arbitration is fixed priority - master 1 (data) always outranks master 0
// (instruction) - and is *combinational while the bus is idle but latched for
// the duration of a transfer*. Both halves of that matter:
//
//  - **Combinational when idle** means starting a transfer costs nothing. A
//    registered "go to GRANT state" arbiter would add a cycle to every single
//    bus access, fetches included.
//  - **Latched once a transfer is under way** is what makes a multi-cycle
//    slave safe. Now that the memories are synchronous block RAMs with a wait
//    state (see wb_ram.v), a purely combinational grant would let master 1
//    take the bus in the middle of master 0's read - and then the RAM's ack,
//    which belongs to master 0's address, would be delivered to master 1
//    along with master 0's data. Silent corruption, not a hang.
//
// An earlier version of this file argued that stickiness was unimplementable
// because "stickiness combined with combinational re-arbitration on `ack`
// creates a combinational loop: ack -> grant -> stb -> ack". That is only
// true if the lock is combinational. Registering it breaks the loop: the
// grant depends on `lock`, which is a flip-flop, and `lock`'s next value
// depends on `ack`. Nothing goes round without passing through the register.
//
// **Atomics** were previously safe purely because the data master always
// wins, and they still are - cpu_wb.v holds `cyc` across both phases of an
// AMO's read-modify-write, so priority alone keeps any other master out of
// the gap. The lock does not weaken that: when the read phase's ack releases
// the lock, `m1_cyc` is still asserted, so master 1 immediately wins
// re-arbitration for the write phase.
//
// It also can't starve the fetch path despite always losing: a data access
// is one transaction that then completes, and while it is outstanding
// cpu_wb.v freezes the whole pipeline, so nothing can queue behind it. The
// CPU can only make progress by fetching, so the data master necessarily
// goes idle.
//
// **Both masters must tie `stb` to `cyc`.** Arbitration grants on `cyc`
// alone, so a master that asserted `cyc` without `stb` - legal Wishbone, a
// master holding the bus between transfers - would take the bus and never
// strobe, blocking the other master until it let go. cpu_wb.v drives each
// pair from a single expression, so this holds by construction; the formal
// properties in formal/fv_interconnect.v assume it explicitly rather than
// leaving it as folklore.
//
// An access that decodes to no slave is acknowledged immediately with zero
// data rather than left hanging. A bus that never acks would wedge the CPU
// forever (its pipeline is frozen waiting on `ack`), turning a stray pointer
// into a silent hang instead of something the running program can survive.
module wb_interconnect #(
    parameter NUM_SLAVES = 7
)(
    input  wire        clk,
    input  wire        rst,

    // ---- master 0: instruction fetch ----
    input  wire        m0_cyc,
    input  wire        m0_stb,
    input  wire [31:0] m0_adr,
    output wire [31:0] m0_dat_r,
    output wire        m0_ack,

    // ---- master 1: data ----
    input  wire        m1_cyc,
    input  wire        m1_stb,
    input  wire        m1_we,
    input  wire [31:0] m1_adr,
    input  wire [31:0] m1_dat_w,
    input  wire [3:0]  m1_sel,
    output wire [31:0] m1_dat_r,
    output wire        m1_ack,

    // ---- master 2: page-table walks (read-only) ----
    input  wire        m2_cyc,
    input  wire        m2_stb,
    input  wire [31:0] m2_adr,
    output wire [31:0] m2_dat_r,
    output wire        m2_ack,

    // ---- master 3: the debug module (rtl/debug/dm.v) ----
    //
    // **Highest priority**, which is the opposite of what "a debugger should
    // not disturb the machine" suggests, and is deliberate.
    //
    // It issues at most one access at a time, and only when a host has
    // shifted a DMI transaction through the TAP - 41 TCK cycles, microseconds
    // apart at any plausible TCK against a 25 MHz system clock. So the
    // interference is one arbitration slot per access and is unmeasurable.
    //
    // The alternative starves it. The fetch master asserts `cyc` almost
    // continuously, so anything placed below it waits for a cache miss to
    // coincide with an idle data port, and a debugger reading a wedged
    // machine's memory is exactly the case where the CPU is hammering the bus
    // in a loop. A debug port that works only when the machine is healthy is
    // not a debug port.
    input  wire        m3_cyc,
    input  wire        m3_stb,
    input  wire        m3_we,
    input  wire [31:0] m3_adr,
    input  wire [31:0] m3_dat_w,
    input  wire [3:0]  m3_sel,
    output wire [31:0] m3_dat_r,
    output wire        m3_ack,

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

    // High when the *data* master owns the bus. Peripherals with a
    // read side effect (the PLIC's claim register, the UART's RXDATA) gate
    // their read strobe on this, so a stray instruction fetch into MMIO
    // space can't silently claim an interrupt or eat a received byte.
    output wire                      s_data_master
);
    // ---- arbitration: fixed priority, debug > data > walker > fetch ----
    //
    // `lock_who` is one-hot over {m3, m2, m1, m0} and is only meaningful
    // while `lock` is set. The lock itself works exactly as it always has.
    reg        lock;            // a transfer is in flight and owns the bus
    reg  [3:0] lock_who;        // which master owns it, one-hot

    wire want_m3 = m3_cyc;
    wire want_m1 = m1_cyc && !m3_cyc;
    wire want_m2 = m2_cyc && !m3_cyc && !m1_cyc;
    wire want_m0 = m0_cyc && !m3_cyc && !m1_cyc && !m2_cyc;

    wire sel_m3 = lock ? lock_who[3] : want_m3;
    wire sel_m1 = lock ? lock_who[1] : want_m1;
    wire sel_m2 = lock ? lock_who[2] : want_m2;
    wire sel_m0 = lock ? lock_who[0] : want_m0;

    wire [3:0] sel_who = {sel_m3, sel_m2, sel_m1, sel_m0};

    // Only the *data* master gets this. A peripheral with a read side effect
    // (the PLIC's claim register, the UART's RXDATA) gates its read strobe on
    // it, and a walk is no more entitled to claim an interrupt than a stray
    // instruction fetch is - less so, since a walker address comes from a
    // PTE the program may not even have meant to install.
    // Note what this does *not* include: the debug master. A host reading the
    // UART's RBR or the PLIC's claim register through rtl/debug/dm.v gets the
    // value without the side effect - it does not eat a received byte or
    // claim an interrupt. That is the difference between a debug port and a
    // second CPU, and it is one word of code.
    assign s_data_master = sel_m1;

    assign s_cyc   = sel_m3 ? m3_cyc :
                     (sel_m1 ? m1_cyc : (sel_m2 ? m2_cyc : (sel_m0 ? m0_cyc : 1'b0)));
    wire   cur_stb = sel_m3 ? m3_stb :
                     (sel_m1 ? m1_stb : (sel_m2 ? m2_stb : (sel_m0 ? m0_stb : 1'b0)));
    // Neither the fetch master nor the walker has a write path; the debug
    // module and the data master do.
    assign s_we    = sel_m3 ? m3_we : (sel_m1 ? m1_we : 1'b0);
    assign s_adr   = sel_m3 ? m3_adr :
                     (sel_m1 ? m1_adr : (sel_m2 ? m2_adr : m0_adr));
    assign s_dat_w = sel_m3 ? m3_dat_w : (sel_m1 ? m1_dat_w : 32'b0);
    assign s_sel   = sel_m3 ? m3_sel : (sel_m1 ? m1_sel : 4'b1111);

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

    assign m0_dat_r = fin_dat;
    assign m1_dat_r = fin_dat;
    assign m2_dat_r = fin_dat;
    assign m3_dat_r = fin_dat;
    assign m0_ack   = sel_m0 && fin_ack;
    assign m1_ack   = sel_m1 && fin_ack;
    assign m2_ack   = sel_m2 && fin_ack;
    assign m3_ack   = sel_m3 && fin_ack;

    // Take the lock only when a transfer actually starts and does *not*
    // complete in its first cycle, so zero-wait-state slaves (the peripheral
    // bridges, and an unmapped address) behave exactly as they did before
    // this existed and never touch the lock at all.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lock     <= 1'b0;
            lock_who <= 4'b0;
        end else if (!lock) begin
            if (cur_stb && !fin_ack) begin
                lock     <= 1'b1;
                lock_who <= sel_who;
            end
        end else if (fin_ack) begin
            lock <= 1'b0;
        end
    end
endmodule
