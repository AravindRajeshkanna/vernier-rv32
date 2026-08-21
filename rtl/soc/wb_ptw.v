// The two Sv32 page-table walkers, arbitrated into one Wishbone master.
//
// ---- Why this exists ----
//
// The walkers used to read PTEs through a second port on wb_ram.v's block
// RAM. That worked, and it permanently limited where page tables could live:
// block RAM and nowhere else. An SDRAM has one port, so no amount of wiring
// would have reached one, and Linux puts page tables in DRAM.
//
// So the walkers become a bus master and can read a PTE from any slave the
// interconnect decodes. What they cost for it is that a walk now contends
// with fetch and data traffic instead of running beside it on a dedicated
// port. That is the right trade: a walk only happens on a TLB miss, and the
// pipeline is stalled while it does.
//
// ---- The walker contract is unchanged ----
//
// rtl/mmu.v's port is a request/grant handshake:
//
//   - assert `req` with `addr` and hold both until `gnt`;
//   - `rdata` is valid in the cycle *after* the one where `gnt` was
//     asserted, and only in that cycle.
//
// That contract was written for a synchronous block RAM, where the data
// arrives exactly one cycle after the address is accepted. A bus takes as
// long as the slave takes - eight cycles for an SDRAM row miss, one for a
// peripheral - so "one cycle after" is no longer a property of the memory.
//
// It is still a property of *this module*, which is what lets mmu.v stay
// exactly as it was, and with it both cores and rtl/top.v's flat design.
// The trick is which cycle `gnt` is asserted in: not when the request is
// accepted onto the bus, but when the bus answers. `gnt` is asserted in the
// ack cycle and the returning word is registered on the same edge, so it is
// on `rdata` in the following cycle. The walker cannot tell the difference
// between that and a block RAM; it just waits longer for the grant.
//
// The alternative was to widen the contract to "data valid with a separate
// valid strobe" and update mmu.v, both cores, and the flat design. This is
// three registers instead.
//
// ---- Arbitration between the two walkers ----
//
// Fixed priority, data walker first, unchanged from the arbiter this
// replaces in wb_ram.v. No starvation: a walk is a finite number of reads
// and then it is over, so the instruction walker always gets in eventually -
// and while the data walker is walking, the pipeline is frozen anyway.
//
// Unlike the block RAM version, the choice is *latched* for the duration of
// the bus transaction. It has to be: the grant now lands many cycles after
// the request was taken, and a combinational choice would hand the answer to
// whichever walker happened to be asking when it arrived.
module wb_ptw (
    input  wire        clk,
    input  wire        rst,

    // ---- data-side walker (mmu.v in cpu_core's MEM path) ----
    input  wire        ptw_req,
    input  wire [31:0] ptw_addr,
    output wire        ptw_gnt,
    output wire [31:0] ptw_rdata,

    // ---- instruction-side walker (the ITLB's own mmu.v) ----
    input  wire        iptw_req,
    input  wire [31:0] iptw_addr,
    output wire        iptw_gnt,
    output wire [31:0] iptw_rdata,

    // ---- Wishbone master, read-only ----
    output wire        wb_cyc,
    output wire        wb_stb,
    output wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_r,
    input  wire        wb_ack
);
    reg        busy;        // a bus transaction is outstanding
    reg        owner_i;     // and it belongs to the instruction walker
    reg [31:0] adr_r;
    reg [31:0] q;

    // Who would start a transaction this cycle. Only consulted while idle.
    wire start_d = !busy && ptw_req;
    wire start_i = !busy && iptw_req && !ptw_req;
    wire start   = start_d || start_i;

    // cyc and stb are tied together, which the interconnect's arbiter
    // requires: it grants on `cyc` alone, so a master that asserted `cyc`
    // without `stb` would take the bus and never strobe. The formal
    // properties in formal/fv_interconnect.v assume this of every master
    // rather than leaving it as folklore.
    assign wb_cyc = busy || start;
    assign wb_stb = wb_cyc;
    assign wb_adr = busy ? adr_r : (start_d ? ptw_addr : iptw_addr);

    // The grant lands in the ack cycle; `q` is written on the same edge, so
    // the data is on rdata in the cycle after the grant - which is the
    // contract mmu.v was written against. Both walkers read the same
    // register, which is safe because each samples it exactly one cycle
    // after its own grant and only one of the two is ever granted.
    //
    // `ack_now` deliberately includes the cycle the transaction *starts* in,
    // because a Wishbone slave may ack combinationally and one of them
    // certainly does: wb_interconnect.v acks an address matching no slave
    // immediately, on purpose, so a stray pointer surfaces as garbage rather
    // than a hung core. A walker reads whatever physical address a PTE names,
    // and a garbage `satp` or a half-built page table names unmapped ones -
    // so this is a reachable case, not a theoretical one. Gating the ack on
    // `busy` alone would drop that ack and then re-issue the same read
    // forever, turning the very case the interconnect goes out of its way to
    // make survivable into the hang it was avoiding.
    wire active      = busy || start;
    wire ack_now     = active && wb_ack;
    wire owner_i_now = busy ? owner_i : start_i;

    assign ptw_gnt   = ack_now && !owner_i_now;
    assign iptw_gnt  = ack_now &&  owner_i_now;
    assign ptw_rdata  = q;
    assign iptw_rdata = q;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            busy    <= 1'b0;
            owner_i <= 1'b0;
            adr_r   <= 32'b0;
            q       <= 32'b0;
        end else if (ack_now) begin
            busy <= 1'b0;
            q    <= wb_dat_r;
        end else if (start) begin
            busy    <= 1'b1;
            owner_i <= start_i;
            adr_r   <= start_d ? ptw_addr : iptw_addr;
        end
    end
endmodule
