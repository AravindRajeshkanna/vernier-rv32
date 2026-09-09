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
//   1 = UART - the line Linux's tty path waits on: the kernel console is
//       polled, but /init writing to /dev/console blocks on this interrupt
//   2 = GPIO
//   3..8 = spare, tied low
module soc_top #(
    // Number of harts sharing this bus. Defaults to 1 - today's exact
    // single-hart shape, and every board/synthesis build's own value.
    // `NUM_HARTS=2` is exercised only by sim/tb_soc_2hart.v and
    // sim/tb_soc_2hart_lrsc.v so far: hart 1's hardware (its own
    // cpu_core/cpu_wb/wb_ptw, HARTID=1, its own CLINT timer/PLIC contexts)
    // exists and runs, and rtl/soc/reservation_monitor.v is wired to both
    // harts' reservation ports, so cross-hart LR/SC is coherent - but hart
    // 1 gets no debug access at all (rtl/debug/dm.v stays hart-0-only - see
    // the tie-off where hart control is wired below), and neither
    // software/soc/bootrom.c nor dts/soc.dts know a second hart exists yet.
    // See docs/roadmap.md's Phase 13 entry for what is and is not done
    // here.
    parameter NUM_HARTS       = 1,
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

    // ---- general-purpose timer / PWM, rtl/soc/wb_timer.v ----
    output wire pwm_out,

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
    localparam NUM_SLAVES = 10;

    // Slave index assignment (also the bit position in the vectors below).
    localparam S_ROM = 0, S_CLINT = 1, S_PLIC = 2, S_UART = 3,
               S_GPIO = 4, S_SPI = 5, S_FB = 6, S_RAM = 7, S_SDRAM = 8,
               S_TIMER = 9;

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
        8'h08, // S_TIMER
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
        8'hFF, // S_TIMER
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

    // ---- CPU native ports, one slice per hart ----
    // Hart h's signals occupy bit/word h of each vector below (bit 32*h+:32
    // for the 32-bit ones), the same convention
    // rtl/soc/wb_interconnect.v/rtl/soc/reservation_monitor.v already use.
    // `NUM_HARTS=1` collapses every vector to exactly one bit/word, wired to
    // exactly the same single hart these signals have always named.
    wire [NUM_HARTS*32-1:0] imem_addr, imem_rdata;
    wire [NUM_HARTS*32-1:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [NUM_HARTS-1:0]    dmem_we, dmem_re, dmem_is_amo, dmem_rvalid;
    wire [NUM_HARTS*2-1:0]  dmem_size;
    wire [NUM_HARTS-1:0]    ibus_wait, dbus_wait;
    wire [NUM_HARTS-1:0]    itlb_wait_stall;
    wire [NUM_HARTS-1:0]    ptw_req, ptw_gnt, iptw_req, iptw_gnt;
    wire [NUM_HARTS*32-1:0] ptw_addr, ptw_rdata, iptw_addr, iptw_rdata;
    // clint.v's own mtip/msip_out ports are already NUM_HARTS-wide vectors
    // (stage 2) - these wires just carry that shape through.
    wire [NUM_HARTS-1:0]    mtip, msip;
    // Hart h's contexts are plic_eip[2*h] (M-mode) / plic_eip[2*h+1]
    // (S-mode), matching plic.v's own NUM_CONTEXTS=2*NUM_HARTS convention.
    wire [2*NUM_HARTS-1:0]  plic_eip;
    wire [63:0] mtime;   // one shared counter - clint.v's mtime_out is not per-hart
    wire [NUM_HARTS-1:0]    fence_i;

    // ---- cross-hart LR/SC coherence (rtl/soc/reservation_monitor.v,
    // Phase 13 stage 9) ----
    //
    // Every hart's own resv_valid/resv_addr/store_fire/store_addr feeds the
    // monitor; its per-hart resv_invalidate feeds back into that same
    // hart's resv_invalidate_ext. `NUM_HARTS=1` still instantiates the
    // monitor (below) rather than tying resv_invalidate_ext to a literal
    // 0 - with only one hart, the monitor's own self-exclusion rule means
    // it has no "other hart" to ever report, so resv_invalidate[0] is
    // always 0 by construction, not by a special case. CORE_OOO ties these
    // to 0 directly (see the `ifdef CORE_OOO` assign below): core_ooo.v
    // has no resv_valid/store_fire outputs of its own to drive them with.
    wire [NUM_HARTS-1:0]    resv_valid, store_fire, resv_invalidate;
    wire [NUM_HARTS*32-1:0] resv_addr, store_addr;

    // ---- Wishbone masters, one triple per hart ----
    wire [NUM_HARTS-1:0]    iwb_cyc, iwb_stb, iwb_ack;
    wire [NUM_HARTS*32-1:0] iwb_adr, iwb_dat_r;
    wire [NUM_HARTS-1:0]    dwb_cyc, dwb_stb, dwb_we, dwb_ack;
    wire [NUM_HARTS*32-1:0] dwb_adr, dwb_dat_w, dwb_dat_r;
    wire [NUM_HARTS*4-1:0]  dwb_sel;
    wire [NUM_HARTS-1:0]    pwb_cyc, pwb_stb, pwb_ack;
    wire [NUM_HARTS*32-1:0] pwb_adr, pwb_dat_r;

    // ---- shared slave bus ----
    wire                     s_cyc, s_we, s_data_master;
    wire [NUM_SLAVES-1:0]    s_stb;
    wire [31:0]              s_adr, s_dat_w;
    wire [3:0]               s_sel;
    wire [NUM_SLAVES*32-1:0] s_dat_r;
    wire [NUM_SLAVES-1:0]    s_ack;

    // ---- hart control (rtl/debug/dm.v <-> CPU), in-order-core only ----
    //
    // dbg_reg_* carries Abstract Command register access (GPR/dcsr/dpc)
    // between dm.v and cpu_core.v's dedicated debug port - real on
    // CORE=inorder, tied inert for CORE_OOO below (core_ooo.v has no such
    // port at all).
    wire        dbg_haltreq, dbg_resumereq, dbg_halted;
    wire        dbg_reg_valid, dbg_reg_we, dbg_reg_err;
    wire [15:0] dbg_reg_num;
    wire [31:0] dbg_reg_wdata, dbg_reg_rdata;

    // Which core. -DCORE_OOO picks the wide/out-of-order one in rtl/ooo/.
    // See docs/roadmap.md Phase 1 - the in-order core stays the proven
    // default, and `make verify CORE=ooo` runs the whole suite against the
    // other one. The two no longer have an identical port list: hart
    // control (rtl/debug/dm.v's haltreq/resumereq, `dbg_*` below) is
    // in-order-only this round - see the tie-off right after this
    // instantiation for why, and rtl/debug/README.md/docs/roadmap.md
    // Phase 6 for the full reasoning.

    // Correctness-first D-cache bypass (rtl/soc/cpu_wb.v's DCACHE_ENABLE,
    // Phase 13 stage 5): a write-through cache with no snoop path is only
    // correct with one master on the bus. NUM_HARTS=1 keeps today's
    // DCACHE_ENABLE=1 (unaffected); NUM_HARTS>1 forces it off for every
    // hart, since two real masters now genuinely share this memory and
    // nothing here watches for a foreign write into either hart's cache.
    localparam HART_DCACHE_ENABLE = (NUM_HARTS > 1) ? 0 : 1;

    // ---- hart 0 ----
`ifdef CORE_OOO
    core_ooo #(.RESET_PC(RESET_PC), .HARTID(0)) CPU (
`else
    cpu_core #(.RESET_PC(RESET_PC), .HARTID(0)) CPU (
`endif
        .clk(clk), .rst(rst_soc),
        .imem_addr(imem_addr[31:0]), .imem_rdata(imem_rdata[31:0]),
        .itlb_wait_stall(itlb_wait_stall[0]),
        .dmem_addr(dmem_addr[31:0]), .dmem_wdata(dmem_wdata[31:0]),
        .dmem_we(dmem_we[0]), .dmem_re(dmem_re[0]), .dmem_size(dmem_size[1:0]),
        .dmem_rdata(dmem_rdata[31:0]), .dmem_rvalid(dmem_rvalid[0]), .dmem_is_amo(dmem_is_amo[0]),
        .ibus_wait(ibus_wait[0]), .dbus_wait(dbus_wait[0]),
        .ptw_req(ptw_req[0]), .ptw_addr(ptw_addr[31:0]),
        .ptw_gnt(ptw_gnt[0]), .ptw_rdata(ptw_rdata[31:0]),
        .iptw_req(iptw_req[0]), .iptw_addr(iptw_addr[31:0]),
        .iptw_gnt(iptw_gnt[0]), .iptw_rdata(iptw_rdata[31:0]),
        .mtip(mtip[0]), .msip_in(msip[0]), .meip(plic_eip[0]), .seip(plic_eip[1]),
        .mtime_in(mtime),
        .fence_i(fence_i[0]), .trap(trap)
`ifndef CORE_OOO
        // core_ooo.v has no reservation-monitor ports yet - see the
        // `ifdef CORE_OOO` assign below, which ties this hart's own slice
        // of the monitor's inputs to 0 in that build instead.
        , .resv_valid(resv_valid[0]), .resv_addr(resv_addr[31:0]),
        .store_fire(store_fire[0]), .store_addr(store_addr[31:0]),
        .resv_invalidate_ext(resv_invalidate[0]),
        .dbg_haltreq(dbg_haltreq), .dbg_resumereq(dbg_resumereq), .dbg_halted(dbg_halted),
        .dbg_reg_valid(dbg_reg_valid), .dbg_reg_we(dbg_reg_we),
        .dbg_reg_num(dbg_reg_num), .dbg_reg_wdata(dbg_reg_wdata),
        .dbg_reg_rdata(dbg_reg_rdata), .dbg_reg_err(dbg_reg_err)
`endif
    );
`ifdef CORE_OOO
    // core_ooo.v has no hart-control ports at all (see the comment above) -
    // report honestly rather than silently claiming a halt or a successful
    // register access that can never happen, the same rule dm.v's own
    // dmstatus already follows for System Bus Access (rtl/debug/README.md).
    // dm.v itself also refuses any command while !halted (cmderr =
    // halt/resume required), so dbg_reg_err here is a backstop, not the
    // only thing standing between a host and a fabricated register value.
    assign dbg_halted    = 1'b0;
    assign dbg_reg_rdata = 32'b0;
    assign dbg_reg_err   = 1'b1;
    // Same honesty rule for coherence: core_ooo.v has no resv_valid/
    // store_fire outputs to drive the monitor with, so every hart reports
    // "no reservation, no write" rather than leaving these floating.
    // rtl/soc/reservation_monitor.v's own resv_invalidate output is simply
    // unread on this build - there is no resv_invalidate_ext input to feed
    // it into. See docs/roadmap.md's Phase 13 entry: CORE=ooo has no
    // cross-hart LR/SC coherence of any kind yet, same as before this
    // stage, since the gap was cpu_core.v-only from Stage 7 onward.
    assign resv_valid  = {NUM_HARTS{1'b0}};
    assign resv_addr   = {(NUM_HARTS*32){1'b0}};
    assign store_fire  = {NUM_HARTS{1'b0}};
    assign store_addr  = {(NUM_HARTS*32){1'b0}};
`endif

    cpu_wb #(.DCACHE_ENABLE(HART_DCACHE_ENABLE)) BUSADAPT (
        .clk(clk), .rst(rst_soc),
        .imem_addr(imem_addr[31:0]), .imem_rdata(imem_rdata[31:0]), .ibus_wait(ibus_wait[0]),
        .itlb_wait_stall(itlb_wait_stall[0]),
        .dmem_addr(dmem_addr[31:0]), .dmem_wdata(dmem_wdata[31:0]),
        .dmem_we(dmem_we[0]), .dmem_re(dmem_re[0]), .dmem_is_amo(dmem_is_amo[0]),
        .dmem_size(dmem_size[1:0]), .dmem_rdata(dmem_rdata[31:0]),
        .dmem_rvalid(dmem_rvalid[0]), .dbus_wait(dbus_wait[0]),
        .fence_i(fence_i[0]),
        .iwb_cyc(iwb_cyc[0]), .iwb_stb(iwb_stb[0]), .iwb_adr(iwb_adr[31:0]),
        .iwb_dat_r(iwb_dat_r[31:0]), .iwb_ack(iwb_ack[0]),
        .dwb_cyc(dwb_cyc[0]), .dwb_stb(dwb_stb[0]), .dwb_we(dwb_we[0]),
        .dwb_adr(dwb_adr[31:0]), .dwb_dat_w(dwb_dat_w[31:0]), .dwb_sel(dwb_sel[3:0]),
        .dwb_dat_r(dwb_dat_r[31:0]), .dwb_ack(dwb_ack[0])
    );

    // The page-table walker, as a bus master rather than a private port on
    // block RAM. This is what lets page tables live in SDRAM - see
    // rtl/soc/wb_ptw.v for why mmu.v did not have to change for it.
    wb_ptw PTW (
        .clk(clk), .rst(rst_soc),
        .ptw_req(ptw_req[0]),   .ptw_addr(ptw_addr[31:0]),
        .ptw_gnt(ptw_gnt[0]),   .ptw_rdata(ptw_rdata[31:0]),
        .iptw_req(iptw_req[0]), .iptw_addr(iptw_addr[31:0]),
        .iptw_gnt(iptw_gnt[0]), .iptw_rdata(iptw_rdata[31:0]),
        .wb_cyc(pwb_cyc[0]), .wb_stb(pwb_stb[0]), .wb_adr(pwb_adr[31:0]),
        .wb_dat_r(pwb_dat_r[31:0]), .wb_ack(pwb_ack[0])
    );

    // ---- harts 1..NUM_HARTS-1 (empty when NUM_HARTS=1, the default) ----
    //
    // Each additional hart gets its own CPU, bus adapter and page-table
    // walker - the same three-instance shape hart 0 has just above,
    // parameterized on `h` instead of hardcoded. CORE=inorder and CORE=ooo
    // both build this loop (core_ooo.v can be instantiated more than once
    // with no issue of its own), but two things stay hart-0-only
    // regardless: `trap` (a single module-level bit - a second hart's own
    // trap is not yet observable at this module's boundary) and hart
    // control (rtl/debug/dm.v has no per-hart select - see the tie-off
    // below). Every hart's own reservation ports, by contrast, DO connect
    // to rtl/soc/reservation_monitor.v below, hart 0 included - Phase 13
    // stage 9. See docs/roadmap.md's Phase 13 entry for what still isn't
    // done (CORE_OOO's own coherence gap, and hart control past hart 0).
    genvar h;
    generate
        for (h = 1; h < NUM_HARTS; h = h + 1) begin : g_hart
`ifdef CORE_OOO
            core_ooo #(.RESET_PC(RESET_PC), .HARTID(h)) CPU (
`else
            cpu_core #(.RESET_PC(RESET_PC), .HARTID(h)) CPU (
`endif
                .clk(clk), .rst(rst_soc),
                .imem_addr(imem_addr[32*h +: 32]), .imem_rdata(imem_rdata[32*h +: 32]),
                .itlb_wait_stall(itlb_wait_stall[h]),
                .dmem_addr(dmem_addr[32*h +: 32]), .dmem_wdata(dmem_wdata[32*h +: 32]),
                .dmem_we(dmem_we[h]), .dmem_re(dmem_re[h]), .dmem_size(dmem_size[2*h +: 2]),
                .dmem_rdata(dmem_rdata[32*h +: 32]), .dmem_rvalid(dmem_rvalid[h]), .dmem_is_amo(dmem_is_amo[h]),
                .ibus_wait(ibus_wait[h]), .dbus_wait(dbus_wait[h]),
                .ptw_req(ptw_req[h]), .ptw_addr(ptw_addr[32*h +: 32]),
                .ptw_gnt(ptw_gnt[h]), .ptw_rdata(ptw_rdata[32*h +: 32]),
                .iptw_req(iptw_req[h]), .iptw_addr(iptw_addr[32*h +: 32]),
                .iptw_gnt(iptw_gnt[h]), .iptw_rdata(iptw_rdata[32*h +: 32]),
                .mtip(mtip[h]), .msip_in(msip[h]), .meip(plic_eip[2*h]), .seip(plic_eip[2*h+1]),
                .mtime_in(mtime),
                .fence_i(fence_i[h]), .trap()
`ifndef CORE_OOO
                , .resv_valid(resv_valid[h]), .resv_addr(resv_addr[32*h +: 32]),
                .store_fire(store_fire[h]), .store_addr(store_addr[32*h +: 32]),
                .resv_invalidate_ext(resv_invalidate[h]),
                // No per-hart select exists in rtl/debug/dm.v yet (RISC-V
                // debug spec's `hartsel`) - every hart past 0 is simply not
                // reachable from the debug path this round. Tied to explicit
                // constants, not omitted, for the same X-poisoning reason
                // hart 0's own tie-offs elsewhere in this file already are.
                .dbg_haltreq(1'b0), .dbg_resumereq(1'b0), .dbg_halted(),
                .dbg_reg_valid(1'b0), .dbg_reg_we(1'b0),
                .dbg_reg_num(16'b0), .dbg_reg_wdata(32'b0),
                .dbg_reg_rdata(), .dbg_reg_err()
`endif
            );

            cpu_wb #(.DCACHE_ENABLE(HART_DCACHE_ENABLE)) BUSADAPT (
                .clk(clk), .rst(rst_soc),
                .imem_addr(imem_addr[32*h +: 32]), .imem_rdata(imem_rdata[32*h +: 32]),
                .ibus_wait(ibus_wait[h]),
                .itlb_wait_stall(itlb_wait_stall[h]),
                .dmem_addr(dmem_addr[32*h +: 32]), .dmem_wdata(dmem_wdata[32*h +: 32]),
                .dmem_we(dmem_we[h]), .dmem_re(dmem_re[h]), .dmem_is_amo(dmem_is_amo[h]),
                .dmem_size(dmem_size[2*h +: 2]), .dmem_rdata(dmem_rdata[32*h +: 32]),
                .dmem_rvalid(dmem_rvalid[h]), .dbus_wait(dbus_wait[h]),
                .fence_i(fence_i[h]),
                .iwb_cyc(iwb_cyc[h]), .iwb_stb(iwb_stb[h]), .iwb_adr(iwb_adr[32*h +: 32]),
                .iwb_dat_r(iwb_dat_r[32*h +: 32]), .iwb_ack(iwb_ack[h]),
                .dwb_cyc(dwb_cyc[h]), .dwb_stb(dwb_stb[h]), .dwb_we(dwb_we[h]),
                .dwb_adr(dwb_adr[32*h +: 32]), .dwb_dat_w(dwb_dat_w[32*h +: 32]), .dwb_sel(dwb_sel[4*h +: 4]),
                .dwb_dat_r(dwb_dat_r[32*h +: 32]), .dwb_ack(dwb_ack[h])
            );

            wb_ptw PTW (
                .clk(clk), .rst(rst_soc),
                .ptw_req(ptw_req[h]),   .ptw_addr(ptw_addr[32*h +: 32]),
                .ptw_gnt(ptw_gnt[h]),   .ptw_rdata(ptw_rdata[32*h +: 32]),
                .iptw_req(iptw_req[h]), .iptw_addr(iptw_addr[32*h +: 32]),
                .iptw_gnt(iptw_gnt[h]), .iptw_rdata(iptw_rdata[32*h +: 32]),
                .wb_cyc(pwb_cyc[h]), .wb_stb(pwb_stb[h]), .wb_adr(pwb_adr[32*h +: 32]),
                .wb_dat_r(pwb_dat_r[32*h +: 32]), .wb_ack(pwb_ack[h])
            );
        end
    endgenerate

    // Closes the cross-hart LR/SC gap docs/roadmap.md's Phase 13 entry
    // named from Stage 6 onward: every hart's own resv_valid/resv_addr/
    // store_fire/store_addr feeds this, and its per-hart resv_invalidate
    // feeds back into that same hart's own resv_invalidate_ext above.
    // `NUM_HARTS=1` collapses this to the module's own single-hart case -
    // one hart, no "other" hart to ever report, resv_invalidate[0] always
    // 0 - the same "generalize, default preserves today's behavior"
    // pattern every other Phase 13 stage already used.
    reservation_monitor #(.NUM_HARTS(NUM_HARTS)) RESVMON (
        .resv_valid(resv_valid), .resv_addr(resv_addr),
        .store_fire(store_fire), .store_addr(store_addr),
        .resv_invalidate(resv_invalidate)
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
        .ndmreset(dbg_ndmreset), .dmactive(),
        .haltreq(dbg_haltreq), .resumereq(dbg_resumereq), .halted(dbg_halted),
        .dbg_reg_valid(dbg_reg_valid), .dbg_reg_we(dbg_reg_we),
        .dbg_reg_num(dbg_reg_num), .dbg_reg_wdata(dbg_reg_wdata),
        .dbg_reg_rdata(dbg_reg_rdata), .dbg_reg_err(dbg_reg_err)
    );

    // NUM_HARTS=1 (the default) collapses every per-hart vector port below
    // to exactly one bit/word, connected to exactly hart 0's own fetch/
    // data/walker signals - see rtl/soc/wb_interconnect.v's own header for
    // why that is precisely the original 4-master shape, and
    // docs/roadmap.md's Phase 13 entry for hart 1's own instantiation above
    // and what still isn't wired to it.
    wb_interconnect #(.NUM_SLAVES(NUM_SLAVES), .NUM_HARTS(NUM_HARTS)) BUS (
        .clk(clk), .rst(rst_soc),
        .f_cyc(iwb_cyc), .f_stb(iwb_stb), .f_adr(iwb_adr),
        .f_dat_r(iwb_dat_r), .f_ack(iwb_ack),
        .d_cyc(dwb_cyc), .d_stb(dwb_stb), .d_we(dwb_we), .d_adr(dwb_adr),
        .d_dat_w(dwb_dat_w), .d_sel(dwb_sel),
        .d_dat_r(dwb_dat_r), .d_ack(dwb_ack),
        .w_cyc(pwb_cyc), .w_stb(pwb_stb), .w_adr(pwb_adr),
        .w_dat_r(pwb_dat_r), .w_ack(pwb_ack),
        .dbg_cyc(dbg_cyc), .dbg_stb(dbg_stb), .dbg_we(dbg_we), .dbg_adr(dbg_adr),
        .dbg_dat_w(dbg_dat_w), .dbg_sel(dbg_sel),
        .dbg_dat_r(dbg_dat_r), .dbg_ack(dbg_ack),
        .s_base(s_base), .s_mask(s_mask),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we),
        .s_adr(s_adr), .s_dat_w(s_dat_w), .s_sel(s_sel),
        .s_dat_r(s_dat_r), .s_ack(s_ack),
        .s_data_master(s_data_master)
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
    clint #(.NUM_HARTS(NUM_HARTS)) CLINT (
        .clk(clk), .rst(rst_soc),
        .addr(clint_addr), .wdata(clint_wdata), .we(clint_we),
        .rdata(clint_rdata), .mtip(mtip), .msip_out(msip), .mtime_out(mtime)
    );

    // ---- PLIC behind a bridge ----
    localparam NUM_IRQ = 8;
    wire        gpio_irq;
    wire        uart_irq;
    wire        timer_irq;
    wire [NUM_IRQ-1:0] irq_sources = {5'b0, timer_irq, gpio_irq, uart_irq};
    //                                spare  src3        src2      src1
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
    // Two contexts per hart: context 2*h is hart h's M-mode, 2*h+1 its
    // S-mode - hart 0's pair (0, 1) is what dts/soc.dts declares in
    // `interrupts-extended` and what every stock PLIC driver assumes; a
    // second hart's own pair (2, 3) exists in hardware once NUM_HARTS>1 but
    // dts/soc.dts does not describe it yet (docs/roadmap.md's Phase 13
    // entry).
    plic #(.NUM_SOURCES(NUM_IRQ), .NUM_CONTEXTS(2*NUM_HARTS)) PLIC (
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

    wb_timer TIMER (
        .clk(clk), .rst(rst_soc),
        .wb_cyc(s_cyc), .wb_stb(s_stb[S_TIMER]), .wb_we(s_we),
        .wb_adr(s_adr), .wb_dat_w(s_dat_w),
        .wb_dat_r(s_dat_r[32*S_TIMER +: 32]), .wb_ack(s_ack[S_TIMER]),
        .pwm_out(pwm_out), .irq(timer_irq)
    );
endmodule
