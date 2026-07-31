// Simulation top: wires the CPU core to instruction/data memory, the
// CLINT peripheral, and the PLIC. `dmem_addr` is address-decoded here
// (not inside cpu_core.v, which stays peripheral-agnostic): a 64KB
// window at 0x0200_0000 routes to the CLINT (msip/mtimecmp/mtime), a
// 64KB window at 0x0300_0000 routes to the PLIC (priority/pending/
// enable/threshold/claim-complete), everything else is ordinary dmem
// RAM. The data and instruction MMUs' page-table walkers each get their
// own direct read-only port into dmem (bypassing this decode - both are
// assumed to only ever walk into plain RAM, not MMIO space).
module top #(
    parameter IMEM_WORDS      = 1024,
    parameter DMEM_BYTES      = 32768,
    parameter INIT_FILE       = "program.hex",
    parameter NUM_IRQ_SOURCES = 8
)(
    input wire clk,
    input wire rst,
    input wire [NUM_IRQ_SOURCES-1:0] irq_sources
);
    localparam CLINT_BASE_HI = 16'h0200; // addresses 0x0200_0000-0x0200_FFFF
    localparam PLIC_BASE_HI  = 16'h0300; // addresses 0x0300_0000-0x0300_FFFF

    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire        dmem_we, dmem_re;
    wire [1:0]  dmem_size;
    wire        trap;

    wire [31:0] ptw_addr, ptw_rdata;
    wire [31:0] iptw_addr, iptw_rdata;
    wire        mtip, msip, meip;

    wire is_clint = (dmem_addr[31:16] == CLINT_BASE_HI);
    wire is_plic  = (dmem_addr[31:16] == PLIC_BASE_HI);
    wire [31:0] dmem_rdata_raw, clint_rdata, plic_rdata;
    assign dmem_rdata = is_clint ? clint_rdata : (is_plic ? plic_rdata : dmem_rdata_raw);

    cpu_core CPU (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_size(dmem_size), .dmem_rdata(dmem_rdata),
        .ptw_addr(ptw_addr), .ptw_rdata(ptw_rdata),
        .iptw_addr(iptw_addr), .iptw_rdata(iptw_rdata),
        .mtip(mtip), .msip_in(msip), .meip(meip),
        .trap(trap)
    );

    imem #(.MEM_WORDS(IMEM_WORDS), .INIT_FILE(INIT_FILE)) IMEM (
        .addr(imem_addr), .rdata(imem_rdata)
    );

    dmem #(.MEM_BYTES(DMEM_BYTES)) DMEM (
        .clk(clk), .addr(dmem_addr), .wdata(dmem_wdata),
        .we(dmem_we && !is_clint && !is_plic), .size(dmem_size), .rdata(dmem_rdata_raw),
        .addr2(ptw_addr), .rdata2(ptw_rdata),
        .addr3(iptw_addr), .rdata3(iptw_rdata)
    );

    clint CLINT (
        .clk(clk), .rst(rst),
        .addr(dmem_addr), .wdata(dmem_wdata), .we(dmem_we && is_clint),
        .rdata(clint_rdata),
        .mtip(mtip), .msip_out(msip)
    );

    plic #(.NUM_SOURCES(NUM_IRQ_SOURCES)) PLIC (
        .clk(clk), .rst(rst),
        .addr(dmem_addr), .wdata(dmem_wdata),
        .we(dmem_we && is_plic), .re(dmem_re && is_plic),
        .rdata(plic_rdata),
        .irq_sources(irq_sources),
        .eip(meip)
    );
endmodule
