// Wishbone B4 classic RAM slave: a synchronous, word-organized, true
// dual-port memory. Port A is the bus (read/write with byte lanes); port B is
// a read-only port shared by the two page-table walkers.
//
// ---- Why this is shaped the way it is ----
//
// The previous version was a byte array with *asynchronous* reads on three
// separate ports. That is a perfectly good simulation model and an
// impossible piece of hardware. An FPGA block RAM has a registered read
// port, so yosys cannot map an async read to one; asked to synthesize 256 KB
// that way it falls back to building the array out of flip-flops - two
// million of them - and never finishes. Full-SoC synthesis was measured
// running for over ten minutes on exactly that step before this rewrite.
//
// Three changes make it real hardware:
//
//  1. **Word-organized, not byte-organized.** A 32-bit access has to come out
//     of one port in one cycle, which a byte-wide memory cannot do. Byte
//     writes become per-lane write enables on a 32-bit word, which is
//     natively what block RAMs provide.
//  2. **Synchronous reads.** Data appears the cycle after the address, so
//     this slave now takes one wait state. That is not a regression to
//     apologize for - it is what a block RAM costs, and the pipeline already
//     had `ibus_wait`/`dbus_wait` to absorb it.
//  3. **Two ports, not four.** Block RAMs come with two. The bus gets one;
//     the two walkers share the other through a fixed-priority arbiter
//     below, which is why mmu.v now uses a request/grant handshake instead
//     of assuming its read always lands.
//
// This is still the intended seam for external DRAM: everything above it
// talks Wishbone and knows only the base address and size.
module wb_ram #(
    parameter MEM_BYTES = 65536,
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    input  wire [3:0]  wb_sel,
    output wire [31:0] wb_dat_r,
    output wire        wb_ack,

    // Page-table walker read ports. Assert `req` with `addr` and hold both
    // until `gnt`; the data is on `rdata` in the cycle after `gnt`, and only
    // then. See mmu.v.
    input  wire        ptw_req,
    input  wire [31:0] ptw_addr,
    output wire        ptw_gnt,
    output wire [31:0] ptw_rdata,
    input  wire        iptw_req,
    input  wire [31:0] iptw_addr,
    output wire        iptw_gnt,
    output wire [31:0] iptw_rdata
);
    localparam WORDS = MEM_BYTES / 4;
    localparam AW    = $clog2(WORDS);

    reg [31:0] mem [0:WORDS-1];
    integer i;

    // INIT_FILE is now one 32-bit little-endian word per line
    // (software/bin2hex.py --word-size=4), matching the array. It used to be
    // one byte per line, back when the array was byte-wide.
    // The zero-fill is guarded because it is astonishingly expensive to
    // elaborate: yosys unrolls the loop into one assignment per word, which
    // measured at ~43 seconds for a 1024-word array and does not finish in
    // any useful time at 65536. That single loop - not the memory structure -
    // is what made full-SoC synthesis appear to hang. With it guarded out the
    // same 256 KB array elaborates and maps to block RAM in 1.3 seconds.
    //
    // Simulation still needs it: Verilog leaves an unwritten array X, and
    // several testbenches load an image far smaller than the memory and
    // expect the remainder to read as zero. $readmemh itself is cheap either
    // way - yosys turns it straight into a memory init attribute - so only
    // the loop is conditional.
    initial begin
`ifndef SYNTHESIS
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = 32'b0;
`endif
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // =====================================================================
    // Port A: the Wishbone bus
    // =====================================================================
    // Only the in-range address bits index the array; the base-address bits
    // were already consumed by the interconnect's decode.
    wire [AW-1:0] a_addr = wb_adr[AW+1:2];
    wire          a_en   = wb_cyc && wb_stb;

    reg  ack_r;
    reg [31:0] a_q;

    // One wait state: the address is presented in the first cycle and the
    // data (and the ack) come in the second. `!ack_r` keeps the ack a single
    // cycle, and keeps the write from being applied twice - the master holds
    // stb through the ack cycle, so without it the same word would be written
    // again on the way out. Harmless as it happens (identical data), but only
    // by accident, and not worth relying on.
    always @(posedge clk or posedge rst) begin
        if (rst) ack_r <= 1'b0;
        else     ack_r <= a_en && !ack_r;
    end

    always @(posedge clk) begin
        if (a_en && wb_we && !ack_r) begin
            if (wb_sel[0]) mem[a_addr][7:0]   <= wb_dat_w[7:0];
            if (wb_sel[1]) mem[a_addr][15:8]  <= wb_dat_w[15:8];
            if (wb_sel[2]) mem[a_addr][23:16] <= wb_dat_w[23:16];
            if (wb_sel[3]) mem[a_addr][31:24] <= wb_dat_w[31:24];
        end
        a_q <= mem[a_addr];
    end

    assign wb_dat_r = a_q;
    assign wb_ack   = ack_r;

    // =====================================================================
    // Port B: the two page-table walkers, arbitrated
    // =====================================================================
    // Fixed priority, data walker first. No starvation: a walk is a finite
    // number of reads and then it is over, so the instruction walker always
    // gets in eventually - and while the data walker is walking, the pipeline
    // is frozen anyway.
    wire b_sel_d = ptw_req;
    wire b_sel_i = iptw_req && !ptw_req;

    wire [AW-1:0] b_addr = b_sel_d ? ptw_addr[AW+1:2] : iptw_addr[AW+1:2];

    reg [31:0] b_q;
    reg        b_was_d, b_was_i;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            b_was_d <= 1'b0;
            b_was_i <= 1'b0;
        end else begin
            b_was_d <= b_sel_d;
            b_was_i <= b_sel_i;
        end
    end

    always @(posedge clk) b_q <= mem[b_addr];

    // The grant is combinational (the read starts this cycle); the data lands
    // next cycle. Both walkers read the same register, which is safe because
    // each one samples it exactly one cycle after its own grant, and the
    // arbiter never grants both in the same cycle.
    assign ptw_gnt   = b_sel_d;
    assign iptw_gnt  = b_sel_i;
    assign ptw_rdata  = b_q;
    assign iptw_rdata = b_q;

    // b_was_d/b_was_i exist so a waveform shows which walker owns b_q in any
    // given cycle; the walkers themselves track it from their own grant.
    wire _unused_ok = &{1'b0, b_was_d, b_was_i, 1'b0};
endmodule
