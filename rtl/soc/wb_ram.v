// Wishbone B4 classic RAM slave: a synchronous, word-organized memory behind
// a single Wishbone port.
//
// ---- It used to have a second port, for the page-table walkers ----
//
// That port is gone, and its removal is the point of the change that removed
// it. Walking a page table through a private port on *this* memory meant
// page tables could live in block RAM and nowhere else - an SDRAM has one
// port, so no amount of wiring here would have reached one, and Linux puts
// page tables in DRAM. The walkers are now a third Wishbone master
// (rtl/soc/wb_ptw.v) and can read a PTE from any slave the interconnect
// decodes, including the 32 MB part on the board.
//
// What is left is an ordinary single-port RAM. The block RAM's second port
// is simply unused now, which costs nothing: block RAMs come with two either
// way.
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
//  3. **One port, not four.** Block RAMs come with two, and asking for four
//     was what made this unsynthesizable. The walkers had the second for a
//     while (see above) and are now on the bus, so one is all this needs.
//     The request/grant handshake mmu.v gained for that second port is still
//     what it uses, because a bus answers on its own schedule too.
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
    output wire        wb_ack
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

endmodule
