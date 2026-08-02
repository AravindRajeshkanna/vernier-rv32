// Simulation top: wires the CPU core to instruction/data memory, the
// CLINT peripheral, the PLIC, and the UART. `dmem_addr` is address-
// decoded here (not inside cpu_core.v, which stays peripheral-agnostic):
// a 64KB window at 0x0200_0000 routes to the CLINT (msip/mtimecmp/
// mtime), a 64KB window at 0x0300_0000 routes to the PLIC (priority/
// pending/enable/threshold/claim-complete), a 64KB window at 0x0400_0000
// routes to the UART (txdata/rxdata/status), everything else is
// ordinary dmem RAM. The data and instruction MMUs' page-table walkers
// each get their own direct read-only port into dmem (bypassing this
// decode - both are assumed to only ever walk into plain RAM, not MMIO
// space).
//
// `DMEM_INIT_FILE`, if non-empty, preloads dmem with a compiled program's
// .rodata/.data segment (see software/) - the hand-assembled test
// (sim/tb_top.v) leaves this at its default (empty), unaffected.
// `CLKS_PER_BIT` (default small, for fast simulation) sets the UART's
// bit period - see rtl/uart.v.
module top #(
    parameter IMEM_WORDS      = 8192,
    parameter DMEM_BYTES      = 32768,
    parameter INIT_FILE       = "program.hex",
    parameter DMEM_INIT_FILE  = "",
    parameter NUM_IRQ_SOURCES = 8,
    parameter UART_CLKS_PER_BIT = 4
)(
    input wire clk,
    input wire rst,
    input wire [NUM_IRQ_SOURCES-1:0] irq_sources,
    output wire uart_tx,
    input  wire uart_rx
);
    localparam CLINT_BASE_HI = 16'h0200; // addresses 0x0200_0000-0x0200_FFFF
    localparam PLIC_BASE_HI  = 16'h0300; // addresses 0x0300_0000-0x0300_FFFF
    localparam UART_BASE_HI  = 16'h0400; // addresses 0x0400_0000-0x0400_FFFF

    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire        dmem_we, dmem_re;
    wire [1:0]  dmem_size;
    wire        trap;

    wire        ptw_req, ptw_gnt, iptw_req, iptw_gnt;
    wire [31:0] ptw_addr, ptw_rdata;
    wire [31:0] iptw_addr, iptw_rdata;
    wire        mtip, msip, meip;
    wire [63:0] mtime;

    wire is_clint = (dmem_addr[31:16] == CLINT_BASE_HI);
    wire is_plic  = (dmem_addr[31:16] == PLIC_BASE_HI);
    wire is_uart  = (dmem_addr[31:16] == UART_BASE_HI);
    wire [31:0] dmem_rdata_raw, clint_rdata, plic_rdata, uart_rdata;
    assign dmem_rdata = is_clint ? clint_rdata :
                         is_plic  ? plic_rdata  :
                         is_uart  ? uart_rdata  : dmem_rdata_raw;

    cpu_core CPU (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_size(dmem_size), .dmem_rdata(dmem_rdata),
        .dmem_is_amo(), // only a bus adapter needs this (see rtl/soc/cpu_wb.v)
        // This top level's memories are zero-latency, so the core never waits
        // and the read data is valid in the cycle the address is presented.
        // An AMO still takes two MEM cycles here (read, then write) - see
        // cpu_core.v's AMO phase comment.
        .dmem_rvalid(1'b1),
        .ibus_wait(1'b0), .dbus_wait(1'b0),
        .ptw_req(ptw_req), .ptw_addr(ptw_addr),
        .ptw_gnt(ptw_gnt), .ptw_rdata(ptw_rdata),
        .iptw_req(iptw_req), .iptw_addr(iptw_addr),
        .iptw_gnt(iptw_gnt), .iptw_rdata(iptw_rdata),
        .mtip(mtip), .msip_in(msip), .meip(meip), .mtime_in(mtime),
        .fence_i(), // no instruction buffer on this top level - nothing to flush
        .trap(trap)
    );

    imem #(.MEM_WORDS(IMEM_WORDS), .INIT_FILE(INIT_FILE)) IMEM (
        .addr(imem_addr), .rdata(imem_rdata)
    );

    dmem #(.MEM_BYTES(DMEM_BYTES), .INIT_FILE(DMEM_INIT_FILE)) DMEM (
        .clk(clk), .addr(dmem_addr), .wdata(dmem_wdata),
        .we(dmem_we && !is_clint && !is_plic && !is_uart), .size(dmem_size), .rdata(dmem_rdata_raw),
        .req2(ptw_req),  .addr2(ptw_addr),  .gnt2(ptw_gnt),  .rdata2(ptw_rdata),
        .req3(iptw_req), .addr3(iptw_addr), .gnt3(iptw_gnt), .rdata3(iptw_rdata)
    );

    clint CLINT (
        .clk(clk), .rst(rst),
        .addr(dmem_addr), .wdata(dmem_wdata), .we(dmem_we && is_clint),
        .rdata(clint_rdata),
        .mtip(mtip), .msip_out(msip), .mtime_out(mtime)
    );

    plic #(.NUM_SOURCES(NUM_IRQ_SOURCES)) PLIC (
        .clk(clk), .rst(rst),
        .addr(dmem_addr), .wdata(dmem_wdata),
        .we(dmem_we && is_plic), .re(dmem_re && is_plic),
        .rdata(plic_rdata),
        .irq_sources(irq_sources),
        .eip(meip)
    );

    uart #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) UART (
        .clk(clk), .rst(rst),
        .addr(dmem_addr), .wdata(dmem_wdata),
        .we(dmem_we && is_uart), .re(dmem_re && is_uart),
        .rdata(uart_rdata),
        .tx(uart_tx), .rx(uart_rx)
    );
endmodule
