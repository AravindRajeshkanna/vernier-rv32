// Generic FPGA top level. This is intentionally board-agnostic: you must
// add a board-specific constraints file (.xdc for Vivado/Xilinx, .pcf for
// icestorm/iCE40, .lpf for ECP5/trellis, .qsf for Quartus/Intel, etc.)
// that maps clk / rst_n / led to real pins on your board.
//
// What it proves: the CPU is actually executing instructions on real
// silicon - the LEDs will show the program counter's upper bits changing
// as the program runs, then settle once it reaches the infinite loop.
module top_fpga (
    input  wire       clk,     // board oscillator, wire to your board's clock pin
    input  wire       rst_n,   // active-low reset button (invert if your board is active-high)
    output reg  [3:0] led
);
    wire rst = ~rst_n;

    localparam CLINT_BASE_HI = 16'h0200;
    localparam PLIC_BASE_HI  = 16'h0300;
    localparam NUM_IRQ_SOURCES = 8;

    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire        dmem_we, dmem_re;
    wire [1:0]  dmem_size;
    wire        trap;

    wire [31:0] ptw_addr, ptw_rdata;
    wire [31:0] iptw_addr, iptw_rdata;
    wire        mtip, msip, meip;
    // No board-specific external interrupt sources are known here - tie
    // all low. Wire this to button/peripheral IRQ lines for your board if
    // you want to exercise the PLIC on real hardware.
    wire [NUM_IRQ_SOURCES-1:0] irq_sources = {NUM_IRQ_SOURCES{1'b0}};

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

    imem #(.MEM_WORDS(1024), .INIT_FILE("program.hex")) IMEM (
        .addr(imem_addr), .rdata(imem_rdata)
    );

    dmem #(.MEM_BYTES(32768)) DMEM (
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

    always @(posedge clk)
        led <= imem_addr[7:4];
endmodule
