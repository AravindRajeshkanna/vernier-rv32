// SoC top level: the CPU core on a Wishbone B4 interconnect with boot ROM,
// RAM, and the full peripheral set.
//
// This exists *alongside* rtl/top.v rather than replacing it. rtl/top.v is
// the original flat, Harvard, zero-latency wiring that sim/tb_top.v's
// hand-assembled regression test runs against, and it is deliberately left
// untouched so that test keeps proving exactly what it always proved. This
// file is the "real system" build: one unified address space, a bus, a boot
// ROM, and storage.
//
// ---- Memory map (decoded on addr[31:24]) ----
//   0x0000_0000  Boot ROM   (reset vector; first-stage loader)
//   0x0200_0000  CLINT      (msip / mtimecmp / mtime)
//   0x0300_0000  PLIC       (priority / pending / enable / threshold / claim)
//   0x0400_0000  UART       (txdata / rxdata / status)
//   0x0500_0000  GPIO       (out / in / dir / ie / ip)
//   0x0600_0000  SPI        (ctrl / data / status)
//   0x8000_0000  Main RAM   (the conventional RISC-V DRAM base)
//
// The CLINT/PLIC/UART bases are inherited unchanged from rtl/top.v so the
// existing drivers in software/ keep working; RAM sits at 0x8000_0000 the
// way essentially every real RISC-V platform puts it, which is also what
// makes the device tree in dts/ look like a normal one.
//
// ---- Harvard split, resolved ----
// The old two-address-spaces-both-based-at-zero arrangement (documented as a
// wart in docs/ARCHITECTURE.md) is gone here: there is a single physical address
// space, instructions and data are just different regions of it, and a PTE's
// PPN now means one unambiguous thing. Instruction fetch and data access are
// separate *bus masters*, not separate address spaces.
//
// ---- PLIC interrupt source assignment ----
//   1 = UART (unused for now: the UART is polled)
//   2 = GPIO
//   3..8 = spare, tied low
module soc_top #(
    parameter ROM_WORDS       = 4096,      // 16 KB boot ROM
    parameter RAM_BYTES       = 262144,    // 256 KB main RAM
    parameter ROM_INIT_FILE   = "",
    parameter RAM_INIT_FILE   = "",
    parameter UART_CLKS_PER_BIT = 4,
    parameter GPIO_WIDTH      = 16,
    parameter RESET_PC        = 32'h0000_0000
)(
    input  wire clk,
    input  wire rst,

    output wire uart_tx,
    input  wire uart_rx,

    input  wire [GPIO_WIDTH-1:0] gpio_in,
    output wire [GPIO_WIDTH-1:0] gpio_out,
    output wire [GPIO_WIDTH-1:0] gpio_dir,

    output wire spi_sck,
    output wire spi_mosi,
    input  wire spi_miso,
    output wire spi_cs_n,

    output wire trap
);
    localparam NUM_SLAVES = 7;

    // Slave index assignment (also the bit position in the vectors below).
    localparam S_ROM = 0, S_CLINT = 1, S_PLIC = 2, S_UART = 3,
               S_GPIO = 4, S_SPI = 5, S_RAM = 6;

    // addr[31:24] each slave answers to, packed 8 bits per slave.
    wire [NUM_SLAVES*8-1:0] s_base = {
        8'h80, // S_RAM
        8'h06, // S_SPI
        8'h05, // S_GPIO
        8'h04, // S_UART
        8'h03, // S_PLIC
        8'h02, // S_CLINT
        8'h00  // S_ROM
    };

    // ---- CPU native ports ----
    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire        dmem_we, dmem_re, dmem_is_amo, dmem_rvalid;
    wire [1:0]  dmem_size;
    wire        ibus_wait, dbus_wait;
    wire        ptw_req, ptw_gnt, iptw_req, iptw_gnt;
    wire [31:0] ptw_addr, ptw_rdata, iptw_addr, iptw_rdata;
    wire        mtip, msip, meip;
    wire [63:0] mtime;
    wire        fence_i;

    // ---- Wishbone masters ----
    wire        iwb_cyc, iwb_stb, iwb_ack;
    wire [31:0] iwb_adr, iwb_dat_r;
    wire        dwb_cyc, dwb_stb, dwb_we, dwb_ack;
    wire [31:0] dwb_adr, dwb_dat_w, dwb_dat_r;
    wire [3:0]  dwb_sel;

    // ---- shared slave bus ----
    wire                     s_cyc, s_we, s_data_master;
    wire [NUM_SLAVES-1:0]    s_stb;
    wire [31:0]              s_adr, s_dat_w;
    wire [3:0]               s_sel;
    wire [NUM_SLAVES*32-1:0] s_dat_r;
    wire [NUM_SLAVES-1:0]    s_ack;

    cpu_core #(.RESET_PC(RESET_PC)) CPU (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_size(dmem_size),
        .dmem_rdata(dmem_rdata), .dmem_rvalid(dmem_rvalid), .dmem_is_amo(dmem_is_amo),
        .ibus_wait(ibus_wait), .dbus_wait(dbus_wait),
        .ptw_req(ptw_req), .ptw_addr(ptw_addr),
        .ptw_gnt(ptw_gnt), .ptw_rdata(ptw_rdata),
        .iptw_req(iptw_req), .iptw_addr(iptw_addr),
        .iptw_gnt(iptw_gnt), .iptw_rdata(iptw_rdata),
        .mtip(mtip), .msip_in(msip), .meip(meip), .mtime_in(mtime),
        .fence_i(fence_i), .trap(trap)
    );

    cpu_wb BUSADAPT (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata), .ibus_wait(ibus_wait),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_is_amo(dmem_is_amo),
        .dmem_size(dmem_size), .dmem_rdata(dmem_rdata),
        .dmem_rvalid(dmem_rvalid), .dbus_wait(dbus_wait),
        .fence_i(fence_i),
        .iwb_cyc(iwb_cyc), .iwb_stb(iwb_stb), .iwb_adr(iwb_adr),
        .iwb_dat_r(iwb_dat_r), .iwb_ack(iwb_ack),
        .dwb_cyc(dwb_cyc), .dwb_stb(dwb_stb), .dwb_we(dwb_we),
        .dwb_adr(dwb_adr), .dwb_dat_w(dwb_dat_w), .dwb_sel(dwb_sel),
        .dwb_dat_r(dwb_dat_r), .dwb_ack(dwb_ack)
    );

    wb_interconnect #(.NUM_SLAVES(NUM_SLAVES)) BUS (
        .clk(clk), .rst(rst),
        .m0_cyc(iwb_cyc), .m0_stb(iwb_stb), .m0_adr(iwb_adr),
        .m0_dat_r(iwb_dat_r), .m0_ack(iwb_ack),
        .m1_cyc(dwb_cyc), .m1_stb(dwb_stb), .m1_we(dwb_we), .m1_adr(dwb_adr),
        .m1_dat_w(dwb_dat_w), .m1_sel(dwb_sel),
        .m1_dat_r(dwb_dat_r), .m1_ack(dwb_ack),
        .s_base(s_base),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
        .s_dat_r(s_dat_r), .s_ack(s_ack),
        .s_data_master(s_data_master)
    );

    // =====================================================================
    // Slaves
    // =====================================================================
    wb_rom #(.MEM_WORDS(ROM_WORDS), .INIT_FILE(ROM_INIT_FILE)) ROM (
        .clk(clk), .rst(rst),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_ROM]), .wb_we(s_we), .wb_adr(s_adr),
        .wb_dat_r(s_dat_r[32*S_ROM +: 32]), .wb_ack(s_ack[S_ROM])
    );

    wb_ram #(.MEM_BYTES(RAM_BYTES), .INIT_FILE(RAM_INIT_FILE)) RAM (
        .clk(clk), .rst(rst),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_RAM]), .wb_we(s_we), .wb_adr(s_adr),
        .wb_dat_w(s_dat_w), .wb_sel(s_sel),
        .wb_dat_r(s_dat_r[32*S_RAM +: 32]), .wb_ack(s_ack[S_RAM]),
        .ptw_req(ptw_req),   .ptw_addr(ptw_addr),
        .ptw_gnt(ptw_gnt),   .ptw_rdata(ptw_rdata),
        .iptw_req(iptw_req), .iptw_addr(iptw_addr),
        .iptw_gnt(iptw_gnt), .iptw_rdata(iptw_rdata)
    );

    // ---- CLINT behind a bridge ----
    wire [31:0] clint_addr, clint_wdata, clint_rdata;
    wire        clint_we, clint_re;
    wb_periph_bridge CLINT_BR (
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_CLINT]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_CLINT +: 32]), .wb_ack(s_ack[S_CLINT]),
        .data_master(s_data_master),
        .p_addr(clint_addr), .p_wdata(clint_wdata),
        .p_we(clint_we), .p_re(clint_re), .p_rdata(clint_rdata)
    );
    clint CLINT (
        .clk(clk), .rst(rst),
        .addr(clint_addr), .wdata(clint_wdata), .we(clint_we),
        .rdata(clint_rdata), .mtip(mtip), .msip_out(msip), .mtime_out(mtime)
    );

    // ---- PLIC behind a bridge ----
    localparam NUM_IRQ = 8;
    wire        gpio_irq;
    wire [NUM_IRQ-1:0] irq_sources = {5'b0, 1'b0, gpio_irq, 1'b0};
    //                                spare  src3  src2      src1(UART, polled)

    wire [31:0] plic_addr, plic_wdata, plic_rdata;
    wire        plic_we, plic_re;
    wb_periph_bridge PLIC_BR (
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_PLIC]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_PLIC +: 32]), .wb_ack(s_ack[S_PLIC]),
        .data_master(s_data_master),
        .p_addr(plic_addr), .p_wdata(plic_wdata),
        .p_we(plic_we), .p_re(plic_re), .p_rdata(plic_rdata)
    );
    plic #(.NUM_SOURCES(NUM_IRQ)) PLIC (
        .clk(clk), .rst(rst),
        .addr(plic_addr), .wdata(plic_wdata), .we(plic_we), .re(plic_re),
        .rdata(plic_rdata), .irq_sources(irq_sources), .eip(meip)
    );

    // ---- UART behind a bridge ----
    wire [31:0] uart_addr, uart_wdata, uart_rdata;
    wire        uart_we, uart_re;
    wb_periph_bridge UART_BR (
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_UART]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_UART +: 32]), .wb_ack(s_ack[S_UART]),
        .data_master(s_data_master),
        .p_addr(uart_addr), .p_wdata(uart_wdata),
        .p_we(uart_we), .p_re(uart_re), .p_rdata(uart_rdata)
    );
    uart #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) UART (
        .clk(clk), .rst(rst),
        .addr(uart_addr), .wdata(uart_wdata), .we(uart_we), .re(uart_re),
        .rdata(uart_rdata), .tx(uart_tx), .rx(uart_rx)
    );

    // ---- native Wishbone peripherals ----
    wb_gpio #(.WIDTH(GPIO_WIDTH)) GPIO (
        .clk(clk), .rst(rst),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_GPIO]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_GPIO +: 32]), .wb_ack(s_ack[S_GPIO]),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .irq(gpio_irq)
    );

    wb_spi SPI (
        .clk(clk), .rst(rst),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_SPI]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_SPI +: 32]), .wb_ack(s_ack[S_SPI]),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n)
    );
endmodule
