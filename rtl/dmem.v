// Byte-addressable data memory with byte/half/word read and write support.
// size: 2'b00 = byte, 2'b01 = halfword, 2'b10 = word.
// Sign/zero extension of loads is handled in the CPU core, not here.
//
// Has two extra read-only, word-only ports (req2/addr2/gnt2/rdata2 and
// req3/addr3/gnt3/rdata3) so the data and instruction MMUs' page-table
// walkers can each read PTEs without contending with the MEM stage's own
// load/store port or with each other - page tables for both code and data
// mappings live in this same array, populated by ordinary `sw` instructions
// through the main port before paging is enabled.
//
// Those two ports speak mmu.v's request/grant protocol, with the read
// registered so the timing matches rtl/soc/wb_ram.v exactly. Here each
// walker has a port to itself so the grant is unconditional - but keeping
// one contract for both memories means mmu.v has a single behavior to be
// correct about, rather than one that silently depends on which top level it
// was instantiated under.
//
// INIT_FILE, if non-empty, preloads the array from a $readmemh file after
// the zero-fill below - used to preload a compiled program's .rodata/
// .data segment (see software/, whose Makefile rule produces this via
// `objcopy -O binary` + software/bin2hex.py --word-size=1, a plain
// sequential byte-per-line file starting at address 0 - not objcopy's
// own `-O verilog` output, which addresses by load address (LMA) rather
// than run address (VMA), the wrong one for a preloaded RAM image with
// no runtime ROM-to-RAM copy step). Left empty (the default), this is
// unchanged from before: an all-zero array, nothing preloaded.
module dmem #(
    parameter MEM_BYTES = 4096,
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    input  wire [1:0]  size,
    output wire [31:0] rdata,

    input  wire        req2,
    input  wire [31:0] addr2,
    output wire        gnt2,
    output reg  [31:0] rdata2,

    input  wire        req3,
    input  wire [31:0] addr3,
    output wire        gnt3,
    output reg  [31:0] rdata3
);
    reg [7:0] mem [0:MEM_BYTES-1];
    integer i;

    // The zero-fill is guarded because it is astonishingly expensive to
    // elaborate: yosys unrolls the loop into one assignment per word, which
    // measured at ~43 seconds for a 1024-word array and does not finish in
    // any useful time at 65536. That single loop - not the memory structure -
    // is what made full-SoC synthesis appear to hang. With it guarded out the
    // same 32 KB array elaborates and maps to block RAM in 1.3 seconds.
    //
    // Simulation still needs it: Verilog leaves an unwritten array X, and
    // several testbenches load an image far smaller than the memory and
    // expect the remainder to read as zero. $readmemh itself is cheap either
    // way - yosys turns it straight into a memory init attribute - so only
    // the loop is conditional.
    initial begin
`ifndef SYNTHESIS
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = 8'b0;
`endif
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    wire [31:0] a = addr;

    // Combinational read of the full word at 'a'; the CPU extracts the
    // relevant byte/halfword and sign/zero-extends as needed.
    assign rdata = {mem[a+3], mem[a+2], mem[a+1], mem[a]};

    // Dedicated ports, so a request is always accepted and the data lands the
    // cycle after. This is the flat design's answer to the walker handshake;
    // the SoC's is rtl/soc/wb_ptw.v, which puts both walkers on the bus so a
    // page table can live in SDRAM. Same contract either way - mmu.v cannot
    // tell them apart, which is the point of it being a handshake.
    wire [31:0] a2 = addr2;
    wire [31:0] a3 = addr3;
    assign gnt2 = req2;
    assign gnt3 = req3;

    always @(posedge clk) begin
        rdata2 <= {mem[a2+3], mem[a2+2], mem[a2+1], mem[a2]};
        rdata3 <= {mem[a3+3], mem[a3+2], mem[a3+1], mem[a3]};
    end

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
