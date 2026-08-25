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
//   0x0700_0000  Framebuffer (320x240, 8bpp RRRGGGBB - see wb_framebuffer.v)
//   0x8000_0000  Main RAM   (the conventional RISC-V DRAM base)
//
// The CLINT/PLIC/UART bases are inherited unchanged from rtl/top.v so the
// existing drivers in software/ keep working; RAM sits at 0x8000_0000 the
// way essentially every real RISC-V platform puts it, which is also what
// makes the device tree in dts/ look like a normal one.
//
// ---- Harvard split, resolved ----
// The old two-address-spaces-both-based-at-zero arrangement (documented as a
// wart in docs/architecture.md) is gone here: there is a single physical address
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
    parameter RESET_PC        = 32'h0000_0000,

    // The clock actually driving `clk`, in Hz. Only the SDRAM controller
    // reads it - the UART takes a divisor instead, because every testbench
    // here runs the UART far faster than a real one to keep simulations
    // short, and SDRAM has no equivalent freedom: its intervals are physics.
    // Too low is safe (it refreshes more often than needed); too high loses
    // data, so the safe direction of error is downward.
    parameter CLK_HZ          = 25_000_000,
    parameter SDRAM_ROW_BITS  = 13,
    parameter SDRAM_COL_BITS  = 9,
    parameter SDRAM_BA_BITS   = 2,

    // Framebuffer geometry. This is what decides the block-RAM cost of the
    // video subsystem, and therefore which ECP5 the whole design still fits
    // on - see fpga/README.md's device table.
    parameter FB_WIDTH        = 320,
    parameter FB_HEIGHT       = 240
)(
    input  wire clk,
    input  wire rst,

    // ---- JTAG, for rtl/debug ----
    //
    // Four pins in the host's own clock domain. Tie tck/tms/tdi to 0 and
    // leave tdo unconnected on a target with no debug header: the TAP's state
    // machine only advances on a TCK edge, so a parked TCK costs exactly
    // nothing and the Debug Module never leaves reset.
    input  wire jtag_tck,
    input  wire jtag_tms,
    input  wire jtag_tdi,
    output wire jtag_tdo,
    output wire jtag_tdo_oe,

    output wire uart_tx,
    input  wire uart_rx,

    input  wire [GPIO_WIDTH-1:0] gpio_in,
    output wire [GPIO_WIDTH-1:0] gpio_out,
    output wire [GPIO_WIDTH-1:0] gpio_dir,

    output wire spi_sck,
    output wire spi_mosi,
    input  wire spi_miso,
    output wire spi_cs_n,

    // ---- video scan-out ----
    // A pixel stream, not a display interface: syncs, data-enable and RGB888,
    // all in this module's own clock domain. Driving a real monitor means
    // adding a pixel-clock PLL and a TMDS serializer above this, which is
    // deliberately not here yet - see rtl/soc/video_timing.v.
    output wire [7:0]  vid_r,
    output wire [7:0]  vid_g,
    output wire [7:0]  vid_b,
    output wire        vid_de,
    output wire        vid_hsync,
    output wire        vid_vsync,

    // ---- external SDRAM ----
    // Split rather than `inout`, so nothing below the board wrapper needs a
    // tristate: fpga/ulx3s_top.v is the only place a real IO buffer appears,
    // exactly as it is for the GPIO header. A simulation that does not model
    // SDRAM leaves the outputs unconnected and ties `sdram_dq_i` low.
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [SDRAM_ROW_BITS-1:0] sdram_a,
    output wire [SDRAM_BA_BITS-1:0]  sdram_ba,
    output wire [1:0]  sdram_dqm,
    output wire [15:0] sdram_dq_o,
    output wire        sdram_dq_oe,
    input  wire [15:0] sdram_dq_i,

    output wire trap
);
    localparam NUM_SLAVES = 9;

    // Slave index assignment (also the bit position in the vectors below).
    localparam S_ROM = 0, S_CLINT = 1, S_PLIC = 2, S_UART = 3,
               S_GPIO = 4, S_SPI = 5, S_FB = 6, S_RAM = 7, S_SDRAM = 8;

    // addr[31:24] each slave answers to, and which of those bits are
    // compared, packed 8 bits per slave. A mask of 0xFF is one 16 MB window.
    //
    // SDRAM sits at 0x90 rather than replacing block RAM at 0x80, which is a
    // staging decision: keeping both memories meant external DRAM landed as
    // an addition that could not regress anything. See docs/roadmap.md
    // Phase 2.
    //
    // Its window is **32 MB**, which is the size of the part actually on the
    // board. It used to be 16 MB because the decode was a bare equality on
    // addr[31:24], so one base byte bought exactly one 16 MB slave and the
    // top half of the chip was unreachable. Mask 0xFE ignores bit 24, so the
    // controller answers to 0x90 and 0x91 alike - and it always could
    // address that far, since wb_sdram.v takes its row from wb_adr[24:12].
    // Widening the global decode instead would have shrunk every peripheral
    // window to buy this one slave more room.
    wire [NUM_SLAVES*8-1:0] s_base = {
        8'h90, // S_SDRAM
        8'h80, // S_RAM
        8'h07, // S_FB
        8'h06, // S_SPI
        8'h05, // S_GPIO
        8'h04, // S_UART
        8'h03, // S_PLIC
        8'h02, // S_CLINT
        8'h00  // S_ROM
    };
    wire [NUM_SLAVES*8-1:0] s_mask = {
        8'hFE, // S_SDRAM  0x90-0x91, 32 MB
        8'hFF, // S_RAM
        8'hFF, // S_FB
        8'hFF, // S_SPI
        8'hFF, // S_GPIO
        8'hFF, // S_UART
        8'hFF, // S_PLIC
        8'hFF, // S_CLINT
        8'hFF  // S_ROM
    };

    // ---- CPU native ports ----
    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire        dmem_we, dmem_re, dmem_is_amo, dmem_rvalid;
    wire [1:0]  dmem_size;
    wire        ibus_wait, dbus_wait;
    wire        ptw_req, ptw_gnt, iptw_req, iptw_gnt;
    wire [31:0] ptw_addr, ptw_rdata, iptw_addr, iptw_rdata;
    wire        mtip, msip;
    wire [1:0]  plic_eip;   // [0] M-mode context, [1] S-mode context
    wire [63:0] mtime;
    wire        fence_i;

    // ---- Wishbone masters ----
    wire        iwb_cyc, iwb_stb, iwb_ack;
    wire [31:0] iwb_adr, iwb_dat_r;
    wire        dwb_cyc, dwb_stb, dwb_we, dwb_ack;
    wire [31:0] dwb_adr, dwb_dat_w, dwb_dat_r;
    wire [3:0]  dwb_sel;
    wire        pwb_cyc, pwb_stb, pwb_ack;
    wire [31:0] pwb_adr, pwb_dat_r;

    // ---- shared slave bus ----
    wire                     s_cyc, s_we, s_data_master;
    wire [NUM_SLAVES-1:0]    s_stb;
    wire [31:0]              s_adr, s_dat_w;
    wire [3:0]               s_sel;
    wire [NUM_SLAVES*32-1:0] s_dat_r;
    wire [NUM_SLAVES-1:0]    s_ack;

    // Which core. Both have the identical port list; -DCORE_OOO picks the
    // wide/out-of-order one in rtl/ooo/. See docs/roadmap.md Phase 1 - the
    // in-order core stays the proven default, and `make verify CORE=ooo`
    // runs the whole suite against the other one.
`ifdef CORE_OOO
    core_ooo #(.RESET_PC(RESET_PC)) CPU (
`else
    cpu_core #(.RESET_PC(RESET_PC)) CPU (
`endif
        .clk(clk), .rst(rst_soc),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
        .dmem_we(dmem_we), .dmem_re(dmem_re), .dmem_size(dmem_size),
        .dmem_rdata(dmem_rdata), .dmem_rvalid(dmem_rvalid), .dmem_is_amo(dmem_is_amo),
        .ibus_wait(ibus_wait), .dbus_wait(dbus_wait),
        .ptw_req(ptw_req), .ptw_addr(ptw_addr),
        .ptw_gnt(ptw_gnt), .ptw_rdata(ptw_rdata),
        .iptw_req(iptw_req), .iptw_addr(iptw_addr),
        .iptw_gnt(iptw_gnt), .iptw_rdata(iptw_rdata),
        .mtip(mtip), .msip_in(msip), .meip(plic_eip[0]), .seip(plic_eip[1]),
        .mtime_in(mtime),
        .fence_i(fence_i), .trap(trap)
    );

    cpu_wb BUSADAPT (
        .clk(clk), .rst(rst_soc),
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

    // ---- the debug path: four pins to a bus master ----
    //
    // rtl/debug/jtag_tap.v (TCK domain) -> rtl/debug/dmi_cdc.v (the one
    // crossing) -> rtl/debug/dm.v (this clock domain, and a fourth master on
    // the interconnect below).
    //
    // None of it touches the CPU. `ndmreset` is the single wire that runs the
    // other way, and it resets everything *except* the debug path itself.
    wire        dbg_cyc, dbg_stb, dbg_we, dbg_ack;
    wire [31:0] dbg_adr, dbg_dat_w, dbg_dat_r;
    wire [3:0]  dbg_sel;
    wire        dbg_ndmreset;

    // Everything except the debug path resets when the host asks for it, or
    // when the board does. The TAP, the crossing and the Debug Module use
    // bare `rst`, which is the spec's rule and the only sensible one: a reset
    // that took the debug path down with it would end the session that asked
    // for it.
    //
    // The interconnect is included. It has to be - a bus lock held by a
    // master that has just been reset is never released, and the debugger
    // that issued the reset would find the bus wedged. rtl/debug/dm.v holds
    // its own bus access off while `ndmreset` is asserted so there is nothing
    // in flight to lose.
    wire rst_soc = rst || dbg_ndmreset;

    wire [6:0]  tck_dmi_addr;
    wire [31:0] tck_dmi_wdata, tck_dmi_rdata;
    wire [1:0]  tck_dmi_op, tck_dmi_resp;
    wire        tck_dmi_req, tck_dmi_busy;

    wire        dmi_valid, dmi_done;
    wire [6:0]  dmi_addr;
    wire [31:0] dmi_wdata, dmi_rdata;
    wire [1:0]  dmi_op, dmi_resp;

    jtag_tap TAP (
        .tck(jtag_tck), .tms(jtag_tms), .tdi(jtag_tdi),
        .tdo(jtag_tdo), .tdo_oe(jtag_tdo_oe),
        .dmi_addr(tck_dmi_addr), .dmi_wdata(tck_dmi_wdata),
        .dmi_op(tck_dmi_op), .dmi_req(tck_dmi_req),
        .dmi_rdata(tck_dmi_rdata), .dmi_resp(tck_dmi_resp),
        .dmi_busy(tck_dmi_busy)
    );

    dmi_cdc DMI_CDC (
        .tck(jtag_tck),
        .req(tck_dmi_req), .req_addr(tck_dmi_addr),
        .req_wdata(tck_dmi_wdata), .req_op(tck_dmi_op),
        .rsp_rdata(tck_dmi_rdata), .rsp_op(tck_dmi_resp),
        .busy(tck_dmi_busy),
        .clk(clk), .rst(rst),
        .sys_valid(dmi_valid), .sys_addr(dmi_addr),
        .sys_wdata(dmi_wdata), .sys_op(dmi_op),
        .sys_done(dmi_done), .sys_rdata(dmi_rdata), .sys_resp(dmi_resp)
    );

    dm DM (
        .clk(clk), .rst(rst),
        .dmi_valid(dmi_valid), .dmi_addr(dmi_addr),
        .dmi_wdata(dmi_wdata), .dmi_op(dmi_op),
        .dmi_done(dmi_done), .dmi_rdata(dmi_rdata), .dmi_resp(dmi_resp),
        .wb_cyc(dbg_cyc), .wb_stb(dbg_stb), .wb_we(dbg_we),
        .wb_adr(dbg_adr), .wb_dat_w(dbg_dat_w), .wb_sel(dbg_sel),
        .wb_dat_r(dbg_dat_r), .wb_ack(dbg_ack),
        .ndmreset(dbg_ndmreset), .dmactive()
    );

    wb_interconnect #(.NUM_SLAVES(NUM_SLAVES)) BUS (
        .clk(clk), .rst(rst_soc),
        .m0_cyc(iwb_cyc), .m0_stb(iwb_stb), .m0_adr(iwb_adr),
        .m0_dat_r(iwb_dat_r), .m0_ack(iwb_ack),
        .m1_cyc(dwb_cyc), .m1_stb(dwb_stb), .m1_we(dwb_we), .m1_adr(dwb_adr),
        .m1_dat_w(dwb_dat_w), .m1_sel(dwb_sel),
        .m1_dat_r(dwb_dat_r), .m1_ack(dwb_ack),
        .m2_cyc(pwb_cyc), .m2_stb(pwb_stb), .m2_adr(pwb_adr),
        .m2_dat_r(pwb_dat_r), .m2_ack(pwb_ack),
        .m3_cyc(dbg_cyc), .m3_stb(dbg_stb), .m3_we(dbg_we), .m3_adr(dbg_adr),
        .m3_dat_w(dbg_dat_w), .m3_sel(dbg_sel),
        .m3_dat_r(dbg_dat_r), .m3_ack(dbg_ack),
        .s_base(s_base), .s_mask(s_mask),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
        .s_dat_r(s_dat_r), .s_ack(s_ack),
        .s_data_master(s_data_master)
    );

    // The page-table walkers, as a bus master rather than a private port on
    // block RAM. This is what lets page tables live in SDRAM - see
    // rtl/soc/wb_ptw.v for why mmu.v did not have to change for it.
    wb_ptw PTW (
        .clk(clk), .rst(rst_soc),
        .ptw_req(ptw_req),   .ptw_addr(ptw_addr),
        .ptw_gnt(ptw_gnt),   .ptw_rdata(ptw_rdata),
        .iptw_req(iptw_req), .iptw_addr(iptw_addr),
        .iptw_gnt(iptw_gnt), .iptw_rdata(iptw_rdata),
        .wb_cyc(pwb_cyc), .wb_stb(pwb_stb), .wb_adr(pwb_adr),
        .wb_dat_r(pwb_dat_r), .wb_ack(pwb_ack)
    );

    // =====================================================================
    // Slaves
    // =====================================================================
    wb_rom #(.MEM_WORDS(ROM_WORDS), .INIT_FILE(ROM_INIT_FILE)) ROM (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_ROM]), .wb_we(s_we), .wb_adr(s_adr),
        .wb_dat_r(s_dat_r[32*S_ROM +: 32]), .wb_ack(s_ack[S_ROM])
    );

    wb_ram #(.MEM_BYTES(RAM_BYTES), .INIT_FILE(RAM_INIT_FILE)) RAM (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_RAM]), .wb_we(s_we), .wb_adr(s_adr),
        .wb_dat_w(s_dat_w), .wb_sel(s_sel),
        .wb_dat_r(s_dat_r[32*S_RAM +: 32]), .wb_ack(s_ack[S_RAM])
    );

    wb_sdram #(
        .CLK_HZ(CLK_HZ),
        .ROW_BITS(SDRAM_ROW_BITS),
        .COL_BITS(SDRAM_COL_BITS),
        .BA_BITS(SDRAM_BA_BITS)
    ) SDRAM (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_SDRAM]), .wb_we(s_we), .wb_adr(s_adr),
        .wb_dat_w(s_dat_w), .wb_sel(s_sel),
        .wb_dat_r(s_dat_r[32*S_SDRAM +: 32]), .wb_ack(s_ack[S_SDRAM]),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n),
        .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dqm(sdram_dqm),
        .sdram_dq_o(sdram_dq_o), .sdram_dq_oe(sdram_dq_oe),
        .sdram_dq_i(sdram_dq_i),
        .sdram_ready()
    );

    // ---- CLINT behind a bridge ----
    wire [31:0] clint_addr, clint_wdata, clint_rdata;
    wire        clint_we, clint_re;
    wb_periph_bridge CLINT_BR (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_CLINT]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_CLINT +: 32]), .wb_ack(s_ack[S_CLINT]),
        .data_master(s_data_master),
        .p_addr(clint_addr), .p_wdata(clint_wdata),
        .p_we(clint_we), .p_re(clint_re), .p_rdata(clint_rdata)
    );
    clint CLINT (
        .clk(clk), .rst(rst_soc),
        .addr(clint_addr), .wdata(clint_wdata), .we(clint_we),
        .rdata(clint_rdata), .mtip(mtip), .msip_out(msip), .mtime_out(mtime)
    );

    // ---- PLIC behind a bridge ----
    localparam NUM_IRQ = 8;
    wire        gpio_irq;
    wire        uart_irq;
    wire [NUM_IRQ-1:0] irq_sources = {5'b0, 1'b0, gpio_irq, uart_irq};
    //                                spare  src3  src2      src1
    // Source 1 was reserved for the UART and tied low for as long as the UART
    // had no interrupt to raise. rtl/uart.v is an ns16550 now and does.

    wire [31:0] plic_addr, plic_wdata, plic_rdata;
    wire        plic_we, plic_re;
    wb_periph_bridge PLIC_BR (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_PLIC]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_PLIC +: 32]), .wb_ack(s_ack[S_PLIC]),
        .data_master(s_data_master),
        .p_addr(plic_addr), .p_wdata(plic_wdata),
        .p_we(plic_we), .p_re(plic_re), .p_rdata(plic_rdata)
    );
    // Two contexts: 0 is hart 0 M-mode, 1 is hart 0 S-mode, which is what
    // dts/soc.dts declares in `interrupts-extended` and what every stock
    // PLIC driver assumes.
    plic #(.NUM_SOURCES(NUM_IRQ), .NUM_CONTEXTS(2)) PLIC (
        .clk(clk), .rst(rst_soc),
        .addr(plic_addr), .wdata(plic_wdata), .we(plic_we), .re(plic_re),
        .rdata(plic_rdata), .irq_sources(irq_sources), .eip(plic_eip)
    );

    // ---- UART behind a bridge ----
    wire [31:0] uart_addr, uart_wdata, uart_rdata;
    wire        uart_we, uart_re;
    wb_periph_bridge UART_BR (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_UART]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_UART +: 32]), .wb_ack(s_ack[S_UART]),
        .data_master(s_data_master),
        .p_addr(uart_addr), .p_wdata(uart_wdata),
        .p_we(uart_we), .p_re(uart_re), .p_rdata(uart_rdata)
    );
    uart #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) UART (
        .clk(clk), .rst(rst_soc),
        .addr(uart_addr), .wdata(uart_wdata), .we(uart_we), .re(uart_re),
        .rdata(uart_rdata), .tx(uart_tx), .rx(uart_rx), .irq(uart_irq)
    );

    // ---- native Wishbone peripherals ----
    wb_gpio #(.WIDTH(GPIO_WIDTH)) GPIO (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_GPIO]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_GPIO +: 32]), .wb_ack(s_ack[S_GPIO]),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .irq(gpio_irq)
    );

    // ---- framebuffer + raster timing ----
    wire [11:0] raster_x, raster_y;
    wire        raster_de, raster_hsync, raster_vsync, raster_frame_start;

    video_timing VTIMING (
        .clk(clk), .rst(rst_soc),
        .x(raster_x), .y(raster_y), .de(raster_de),
        .hsync(raster_hsync), .vsync(raster_vsync),
        .frame_start(raster_frame_start)
    );

    wb_framebuffer #(
        .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT), .PIXEL_DOUBLE(1)
    ) FB (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_FB]), .wb_we(s_we), .wb_adr(s_adr),
        .wb_dat_w(s_dat_w), .wb_sel(s_sel),
        .wb_dat_r(s_dat_r[32*S_FB +: 32]), .wb_ack(s_ack[S_FB]),
        .vid_x(raster_x), .vid_y(raster_y), .vid_de(raster_de),
        .vid_hsync(raster_hsync), .vid_vsync(raster_vsync),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_de_out(vid_de),
        .vid_hsync_out(vid_hsync), .vid_vsync_out(vid_vsync)
    );

    wb_spi SPI (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_SPI]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_SPI +: 32]), .wb_ack(s_ack[S_SPI]),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n)
    );
endmodule
