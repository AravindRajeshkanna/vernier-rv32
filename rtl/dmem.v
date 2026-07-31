// Byte-addressable data memory with byte/half/word read and write support.
// size: 2'b00 = byte, 2'b01 = halfword, 2'b10 = word.
// Sign/zero extension of loads is handled in the CPU core, not here.
//
// Has two extra read-only, word-only combinational ports (addr2/rdata2
// and addr3/rdata3) so the data and instruction MMUs' page-table walkers
// can each read PTEs without contending with the MEM stage's own
// load/store port or with each other - page tables for both code and
// data mappings live in this same array, populated by ordinary `sw`
// instructions through the main port before paging is enabled. Real
// block RAMs commonly support this (true/simple multi-port); this is the
// same "just add another read" trick real FPGA memories use.
module dmem #(
    parameter MEM_BYTES = 4096
)(
    input  wire        clk,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    input  wire [1:0]  size,
    output wire [31:0] rdata,

    input  wire [31:0] addr2,
    output wire [31:0] rdata2,

    input  wire [31:0] addr3,
    output wire [31:0] rdata3
);
    reg [7:0] mem [0:MEM_BYTES-1];
    integer i;

    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = 8'b0;
    end

    wire [31:0] a = addr;

    // Combinational read of the full word at 'a'; the CPU extracts the
    // relevant byte/halfword and sign/zero-extends as needed.
    assign rdata = {mem[a+3], mem[a+2], mem[a+1], mem[a]};

    wire [31:0] a2 = addr2;
    assign rdata2 = {mem[a2+3], mem[a2+2], mem[a2+1], mem[a2]};

    wire [31:0] a3 = addr3;
    assign rdata3 = {mem[a3+3], mem[a3+2], mem[a3+1], mem[a3]};

    always @(posedge clk) begin
        if (we) begin
            case (size)
                2'b00: begin
                    mem[a] <= wdata[7:0];
                end
                2'b01: begin
                    mem[a]   <= wdata[7:0];
                    mem[a+1] <= wdata[15:8];
                end
                2'b10: begin
                    mem[a]   <= wdata[7:0];
                    mem[a+1] <= wdata[15:8];
                    mem[a+2] <= wdata[23:16];
                    mem[a+3] <= wdata[31:24];
                end
                default: ;
            endcase
        end
    end
endmodule
