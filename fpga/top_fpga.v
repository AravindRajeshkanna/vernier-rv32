// Generic FPGA top level for the *flat* design (rtl/top.v's module set):
// Harvard, zero-latency memories, no bus, program baked into instruction
// memory at synthesis time. It is the small "is the CPU alive on silicon"
// bitstream. For the real system - one address space, a Wishbone bus, boot
// ROM, SD storage - see fpga/soc_fpga.v, which is what the synthesis scripts
// actually build.
//
// This is intentionally board-agnostic: you must add a board-specific
// constraints file (.xdc for Vivado/Xilinx, .pcf for icestorm/iCE40, .lpf for
// ECP5/trellis, .qsf for Quartus/Intel, etc.) that maps clk / rst_n / led /
// uart_tx / uart_rx to real pins on your board.
//
// What it proves: the CPU is actually executing instructions on real
// silicon - the LEDs will show the program counter's upper bits changing
// as the program runs, then settle once it reaches the infinite loop.
//
// Status: no synthesis script references this file, and unlike
// fpga/soc_fpga.v it has never been synthesized, placed, routed or timed.
// It is kept because rtl/top.v is deliberately preserved (sim/tb_top.v's
// hand-assembled regression runs against it) and this is its hardware
// wrapper - but it is not on the path anything else exercises, which is
// exactly how its page-table-walker ports came to be left unconnected.
module top_fpga (
    input  wire       clk,     // board oscillator, wire to your board's clock pin
    input  wire       rst_n,   // active-low reset button (invert if your board is active-high)
    output reg  [3:0] led,
    output wire       uart_tx, // to your USB-serial adapter's RX pin
    input  wire       uart_rx  // from your USB-serial adapter's TX pin
);
    // ---- reset synchronizer ----
    // Asynchronous assert, synchronous release, matching fpga/soc_fpga.v.
    // A reset button is asynchronous to the clock, and releasing it straight
    // into the fabric lets different flops leave reset on different cycles -
    // which starts the pipeline in a state it was never designed to be in.
    // This file previously did `wire rst = ~rst_n;`, which is that bug.
    /* verilator lint_off SYNCASYNCNET */
    reg [2:0] rst_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 3'b111;
        else        rst_sync <= {rst_sync[1:0], 1'b0};
    end
    /* verilator lint_on SYNCASYNCNET */
    wire rst = rst_sync[2];

    localparam CLINT_BASE_HI = 16'h0200;
    localparam PLIC_BASE_HI  = 16'h0300;
    localparam UART_BASE_HI  = 16'h0400;
    localparam NUM_IRQ_SOURCES = 8;
    // 115200 baud at an assumed 50MHz board clock (50_000_000/115200 ~=
    // 434) - adjust to your board's actual clock frequency and desired
    // baud rate.
    localparam UART_CLKS_PER_BIT = 434;

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
    // No board-specific external interrupt sources are known here - tie
    // all low. Wire this to button/peripheral IRQ lines for your board if
    // you want to exercise the PLIC on real hardware.
    wire [NUM_IRQ_SOURCES-1:0] irq_sources = {NUM_IRQ_SOURCES{1'b0}};

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
        .dmem_is_amo(),
        .dmem_rvalid(1'b1), // zero-latency memory, as in rtl/top.v
        .ibus_wait(1'b0), .dbus_wait(1'b0),
        // The walkers speak a request/grant handshake, so `gnt` is an input
        // to the core. Leaving these unconnected left it floating, which
        // means no page-table walk ever completes and anything that enables
        // paging hangs - see rtl/mmu.v for the contract.
        .ptw_req(ptw_req),   .ptw_addr(ptw_addr),
        .ptw_gnt(ptw_gnt),   .ptw_rdata(ptw_rdata),
        .iptw_req(iptw_req), .iptw_addr(iptw_addr),
        .iptw_gnt(iptw_gnt), .iptw_rdata(iptw_rdata),
        .mtip(mtip), .msip_in(msip), .meip(meip), .mtime_in(mtime),
        .fence_i(), // no instruction buffer on this top level - nothing to flush
        .trap(trap)
    );

    imem #(.MEM_WORDS(1024), .INIT_FILE("program.hex")) IMEM (
        .addr(imem_addr), .rdata(imem_rdata)
    );

    dmem #(.MEM_BYTES(32768)) DMEM (
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

    always @(posedge clk or posedge rst) begin
        if (rst) led <= 4'b0;
        else     led <= imem_addr[7:4];
    end
endmodule
