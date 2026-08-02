// Wishbone B4 classic boot ROM: word-addressed, read-only, contents baked in
// at elaboration time via $readmemh.
//
// One wait state, for the same reason wb_ram.v has one: the read is
// synchronous so this can be a block RAM. An asynchronous read forces
// synthesis to build the array out of LUTs, which for 16 KB is wasteful
// rather than impossible - but there is no reason to spend it, and keeping
// both memories on the same timing contract means the interconnect only has
// one case to be correct about.
//
// This is what the CPU's reset vector points at. It holds the first-stage
// loader (software/soc/bootrom.c), whose job is to bring up the console,
// pull the real program image in from SPI/SD, drop it in RAM and jump to it.
//
// Writes are silently ignored rather than acked-with-error: a Wishbone
// `err` response would need error plumbing all the way back into the core's
// trap logic, which this SoC doesn't have. A write here is a firmware bug,
// and the honest place to catch it is the firmware, not a bus response the
// CPU can't act on.
module wb_rom #(
    parameter MEM_WORDS = 4096,
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    output wire [31:0] wb_dat_r,
    output wire        wb_ack
);
    localparam AW = $clog2(MEM_WORDS);

    reg [31:0] mem [0:MEM_WORDS-1];
    integer i;

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
        for (i = 0; i < MEM_WORDS; i = i + 1)
            mem[i] = 32'b0;
`endif
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    wire en = wb_cyc && wb_stb;

    reg        ack_r;
    reg [31:0] q;

    always @(posedge clk or posedge rst) begin
        if (rst) ack_r <= 1'b0;
        else     ack_r <= en && !ack_r;
    end

    always @(posedge clk) q <= mem[wb_adr[AW+1:2]];

    assign wb_dat_r = q;
    assign wb_ack   = ack_r;

    // Writes are accepted and discarded (see the header): `wb_we` is simply
    // never consulted.
    wire _unused_we = wb_we;
endmodule
