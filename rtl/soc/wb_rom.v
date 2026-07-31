// Wishbone B4 classic boot ROM: word-addressed, read-only, contents baked in
// at elaboration time via $readmemh. Zero wait states, same as wb_ram.v.
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

    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1)
            mem[i] = 32'b0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    assign wb_dat_r = mem[wb_adr[AW+1:2]];
    assign wb_ack   = wb_cyc && wb_stb;
endmodule
