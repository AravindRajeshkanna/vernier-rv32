// Word-addressable instruction memory, loaded from a hex file at elaboration
// time. This is a ROM in practice (no write port) - programs are baked in
// at synthesis/simulation time via $readmemh.
module imem #(
    parameter MEM_WORDS = 1024,
    parameter INIT_FILE = ""
)(
    input  wire [31:0] addr,   // byte address (must be word-aligned)
    output wire [31:0] rdata
);
    localparam AW = $clog2(MEM_WORDS);

    reg [31:0] mem [0:MEM_WORDS-1];

    initial begin
        for (integer i = 0; i < MEM_WORDS; i = i + 1)
            mem[i] = 32'b0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    assign rdata = mem[addr[AW+1:2]];
endmodule
