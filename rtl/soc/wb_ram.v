// Wishbone B4 classic RAM slave with byte-lane writes, plus two extra
// read-only ports for the CPU's page-table walkers.
//
// Zero wait states: `ack` follows `stb` combinationally and reads are
// combinational, which is what a real FPGA block RAM in "read-first,
// asynchronous read" mode gives you. wb_interconnect.v depends on this for
// any slave the instruction master can reach (see its header).
//
// The two extra ports (`ptw_*` and `iptw_*`) are the same trick rtl/dmem.v
// already used: the data and instruction MMUs' page-table walkers each read
// PTEs directly, bypassing the bus entirely. That is deliberate. Page tables
// are documented as living in plain RAM rather than MMIO, so routing the
// walkers through the interconnect would add arbitration and a stall path
// inside mmu.v (whose FSM latches PTE data assuming it arrives
// combinationally) in exchange for nothing.
//
// This module is also the intended seam for external DRAM. Everything above
// it talks Wishbone and knows only the base address and size, so swapping
// the `mem` array for a LiteDRAM (or any other) controller front-end is a
// change confined to this file plus the wait-state caveat above - see
// ARCHITECTURE.md's SoC section for what that would actually involve.
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

    // page-table walker read ports (byte addresses, word reads)
    input  wire [31:0] ptw_addr,
    output wire [31:0] ptw_rdata,
    input  wire [31:0] iptw_addr,
    output wire [31:0] iptw_rdata
);
    localparam AW = $clog2(MEM_BYTES);

    reg [7:0] mem [0:MEM_BYTES-1];
    integer i;

    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1)
            mem[i] = 8'b0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // Only the in-range address bits index the array; the base-address bits
    // were already consumed by the interconnect's decode.
    wire [AW-1:0] a = wb_adr[AW-1:0];

    assign wb_dat_r = {mem[a+3], mem[a+2], mem[a+1], mem[a]};
    assign wb_ack   = wb_cyc && wb_stb;

    wire [AW-1:0] pa  = ptw_addr[AW-1:0];
    wire [AW-1:0] ipa = iptw_addr[AW-1:0];
    assign ptw_rdata  = {mem[pa+3],  mem[pa+2],  mem[pa+1],  mem[pa]};
    assign iptw_rdata = {mem[ipa+3], mem[ipa+2], mem[ipa+1], mem[ipa]};

    always @(posedge clk) begin
        if (wb_cyc && wb_stb && wb_we) begin
            if (wb_sel[0]) mem[a]   <= wb_dat_w[7:0];
            if (wb_sel[1]) mem[a+1] <= wb_dat_w[15:8];
            if (wb_sel[2]) mem[a+2] <= wb_dat_w[23:16];
            if (wb_sel[3]) mem[a+3] <= wb_dat_w[31:24];
        end
    end
endmodule
