// Board wrapper for the ULX3S (Radiona/emard), CABGA381.
//
// Works unchanged on the LFE5U-45F and LFE5U-85F - same board, same pinout,
// only the chip differs. Pick with `BOARD=ulx3s` or `BOARD=ulx3s85`; the
// bitstream is device-specific and will not load on the other. The 12F and
// 25F variants of this board do *not* fit the design at the default 64 KB of
// on-chip RAM - see fpga/README.md's device table for the measured failure.
//
// fpga/soc_fpga.v is deliberately board-agnostic - it asks for `clk`, an
// active-low `rst_n`, a UART pair, four SPI wires, GPIO and four LEDs. This
// file is the only place that knows what those are actually called on a
// ULX3S, which way round its buttons read, and what has to be driven to stop
// the board interfering with itself.
//
// This file has been run on a board. The pin assignments come from the
// official ulx3s_v20.lpf, cross-checked against litex-boards' platform file,
// and an LFE5U-85F configured with them boots and passes the SoC acceptance
// test. Reset polarity, the ESP32 hold-off, the FTDI console and the GPIO
// header are all confirmed on silicon rather than argued from a datasheet.
//
// The SD pins are the exception: they are wired per the v2.0/v3.0 table
// below, and a 64 GB SDXC card in that slot never answers CMD0. That has not
// been distinguished from a wiring fault, because no card under 32 GB has
// been tried yet. fpga/ulx3s_cmd0.v is the four-second test for it.
//
// ---- Board revision matters, and gets this wrong silently ----
// The four SD pins used for SPI mode are wired **differently on v1.7**:
//
//              v2.0 / v3.0        v1.7
//   sck        H2                 J1
//   mosi       J1                 J3
//   miso       J3                 K2
//   cs_n       K2                 H1
//
// This file and fpga/constraints/ulx3s.lpf are for **v2.0 and v3.0**. On a
// v1.7 board the design will build, load, and fail to find the card, because
// every one of those four signals lands on the wrong pin. Check the silkscreen
// before blaming the boot ROM.
module ulx3s_top #(
    // The ULX3S oscillator. soc_fpga.v's CLK_HZ and software/soc/soc.h's
    // CPU_HZ both have to agree with this; at 25 MHz no PLL is needed, since
    // the design's measured Fmax is ~30 MHz.
    parameter CLK_HZ     = 25_000_000,
    parameter GPIO_WIDTH = 16
)(
    input  wire        clk_25mhz,

    // FTDI FT231X. Named from the FTDI's point of view, which is the opposite
    // of the CPU's: `ftdi_rxd` is an FPGA *output*.
    output wire        ftdi_rxd,
    input  wire        ftdi_txd,

    // microSD, used in SPI mode.
    output wire        sd_clk,
    output wire        sd_cmd,     // MOSI
    inout  wire [3:0]  sd_d,       // d[0] = MISO, d[3] = CS
    input  wire        sd_cdn,     // card detect, active low (unused)

    // Buttons. Active *high* with pull-downs, so reset needs inverting.
    input  wire [6:0]  btn,

    output wire [7:0]  led,

    // ESP32 boot-mode pin. See below - this is not optional.
    output wire        wifi_gpio0,

    // General-purpose header, carrying the SoC's GPIO.
    inout  wire [13:0] gp,
    inout  wire [13:0] gn,

    // ---- external SDRAM ----
    // 32 MB, 16-bit SDR, driven by rtl/soc/wb_sdram.v at 0x9000_0000. Names
    // match fpga/constraints/ulx3s.lpf, which in turn matches the official
    // ulx3s_v20.lpf verbatim - so the sites are copied rather than
    // transcribed, and no bit index has to be re-derived anywhere.
    //
    // Confirmed on silicon alongside every other pin in this file: 256 KB of
    // external SDRAM read and written through them on a v3.1.8 / 85F. See
    // fpga/README.md - the first run failed one word in a thousand, and it
    // was the clock phase rather than any of these.
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_csn,
    output wire        sdram_wen,
    output wire        sdram_rasn,
    output wire        sdram_casn,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_ba,
    output wire [1:0]  sdram_dqm,
    inout  wire [15:0] sdram_d

    // ---- GPDI (video out), opt-in - see the `WITH_VIDEO` note below ----
    // Only "_p" - see fpga/video_out.v's header and
    // fpga/constraints/ulx3s.lpf for why "_n" is not a port anywhere in
    // this design.
`ifdef WITH_VIDEO
    , output wire [3:0] gpdi_dp
`endif
);
    // ---- ESP32 hold-off ----
    // On a ULX3S the ESP32 shares the board's power control. Leaving this pin
    // undriven lets the ESP32 fall into a state where it can reset or power
    // down the board underneath a running design - a failure that looks
    // exactly like an FPGA bug. The official LPF gives the pin a pull-up and
    // most ULX3S designs additionally drive it high; doing both costs one pin
    // and removes a whole class of confusing bring-up symptom.
    assign wifi_gpio0 = 1'b1;

    // ---- reset ----
    // btn[0] is the power button and is pulled *up*; btn[1] ("FIRE1") is a
    // normal button pulled *down*, so it reads 1 while pressed. soc_fpga.v
    // wants active-low, hence the inversion. The synchronizer lives in
    // soc_fpga.v, so a raw button is fine here.
    wire rst_n = ~btn[1];

    // ---- SD in SPI mode ----
    // Only two of the four data lines are used as data: d[0] is MISO and d[3]
    // is chip select. d[1] and d[2] are unused in SPI mode but must not float
    // - a card samples them, and a floating input can put it into 4-bit mode
    // or leave it refusing to answer. The LPF pulls them up; driving them
    // high makes it explicit and independent of pull-up strength.
    wire spi_sck, spi_mosi, spi_miso, spi_cs_n;

    assign sd_clk  = spi_sck;
    assign sd_cmd  = spi_mosi;
    assign sd_d[3] = spi_cs_n;
    assign sd_d[2] = 1'b1;
    assign sd_d[1] = 1'b1;
    assign sd_d[0] = 1'bz;      // MISO: input, so leave the pin undriven
    assign spi_miso = sd_d[0];

    // ---- SDRAM ----
    // The one tristate in the whole design. Everything below this file works
    // in out/enable/in form so that no module beneath a board wrapper has to
    // contain one - the same split rtl/soc/wb_gpio.v uses, and the reason
    // rtl/soc/cpu_wb.v and soc_top.v are free of them.
    wire [15:0] sdram_dq_o;
    wire        sdram_dq_oe;
    assign sdram_d = sdram_dq_oe ? sdram_dq_o : 16'bz;

    // The SDRAM clock. **Not** driven straight from the oscillator any more -
    // that is what the board rejected. See fpga/sdram_clk_out.v for the
    // measurement and the reasoning; `SDRAM_CLK=aligned` restores the old
    // behaviour for anyone who wants to reproduce it.
    sdram_clk_out SDCLK (.clk(clk_25mhz), .sdram_clk(sdram_clk));

    // ---- GPIO ----
    // The SoC's 16 bidirectional pins go to the header: gpio[13:0] to
    // gp[13:0], gpio[15:14] to gn[1:0].
    //
    // These are wired by connecting the pins *directly* to soc_fpga.v's inout
    // port below, not through an intermediate wire. That distinction is the
    // whole thing: a continuous assignment is one-directional, so
    // `assign gp = gpio;` would carry outputs to the header and silently drop
    // every input on the floor - a pin driven externally could never reach
    // the SoC. Tying the pins to the port makes them one shared net, which is
    // what a bidirectional connection has to be.
    //
    // The rest of the gn header is parked at high-impedance so those pins are
    // claimed and constrained without being driven - except gn[5:2], which
    // are the JTAG debug header (below).
    assign gn[13:6] = 8'bz;

    // ---- JTAG debug header ----
    //
    // gn[2] TCK   gn[3] TMS   gn[4] TDI   gn[5] TDO
    //
    // **Not the ECP5's own JTAG.** That TAP belongs to the configuration
    // engine and is what `openFPGALoader` talks to; borrowing it would mean
    // sharing a chain with the thing that loads the bitstream. These are four
    // ordinary header pins and any FT2232-style adapter drives them.
    //
    // The three inputs are pulled *down* in the LPF, and that is not
    // tidiness. An unconnected CMOS input floats, and a floating TCK on a
    // board with no debug cable attached is an oscillator: it would clock the
    // TAP's state machine through a random walk, and a random walk that
    // reaches Update-DR with the DMI instruction selected issues a bus write
    // with whatever bits happened to shift in. A pulldown makes "no cable"
    // mean "no clock", which is the only safe reading of an absent host.
    //
    // TDO is driven continuously rather than gated by `tdo_oe`. There is one
    // TAP on this header, so nothing else can be driving the pin, and a
    // permanently-driven output is easier to probe than one that floats
    // between shifts.
    wire jtag_tdo;
    assign gn[5] = jtag_tdo;

    soc_fpga #(
        .CLK_HZ(CLK_HZ),
        .BAUD_RATE(115_200),
        .GPIO_WIDTH(GPIO_WIDTH),
        // 64 KB costs 67 block RAMs: 62% of an LFE5U-45F, 32% of an 85F.
        // See fpga/README.md's device table before changing this - it is what
        // decides which ECP5 the design fits on at all. Raising it also means
        // changing RAM_SIZE in software/soc/soc.h and link_ram.ld to match;
        // nothing checks that the three agree.
        .RAM_BYTES(65536)
    ) SOC (
        .clk(clk_25mhz),
        .rst_n(rst_n),
        .uart_tx(ftdi_rxd),     // FPGA transmits into the FTDI's receiver
        .uart_rx(ftdi_txd),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .gpio({gn[1:0], gp[13:0]}),

        .jtag_tck(gn[2]), .jtag_tms(gn[3]), .jtag_tdi(gn[4]),
        .jtag_tdo(jtag_tdo), .jtag_tdo_oe(),

        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_csn),
        .sdram_ras_n(sdram_rasn), .sdram_cas_n(sdram_casn),
        .sdram_we_n(sdram_wen),
        .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dqm(sdram_dqm),
        .sdram_dq_o(sdram_dq_o), .sdram_dq_oe(sdram_dq_oe),
        .sdram_dq_i(sdram_d),
        .led(led[3:0])
`ifdef WITH_VIDEO
        ,
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_de(vid_de), .vid_hsync(vid_hsync), .vid_vsync(vid_vsync)
`endif
    );

    // soc_fpga.v drives four LEDs; the ULX3S has eight. The top nibble is
    // parked rather than left floating so an unlit LED means "unused" instead
    // of "undriven".
    assign led[7:4] = 4'b0000;

`ifdef WITH_VIDEO
    // ---- video out ----
    //
    // Opt-in, not built by the plain `ulx3s`/`ulx3s85` targets - see
    // `BOARD=ulx3s85-video` in fpga/synth/synth_ecp5.sh. Measured cost:
    // 0 of 16 placement seeds close 25 MHz with this wired in unconditionally
    // (was 1 of 6 without it, and every one of the 16 seeds routed lower than
    // every seed in that baseline - not seed-to-seed noise, a real shift).
    // docs/roadmap.md has the full measurement. video_out.v's own logic is
    // nowhere on the resulting critical path - it is still the same
    // dc_tag-sourced chain this file's Phase 3 history already describes -
    // so this is ordinary added-die-area routing congestion, not a new
    // logical bottleneck, but the cost is real either way and this project's
    // primary board target should not pay it by default.
    //
    // `~rst_n`: the same raw, button-derived reset soc_fpga.v's own
    // internal synchronizer starts from, not a synchronized signal shared
    // with wb_framebuffer.v - that synchronized reset lives inside
    // soc_fpga.v/soc_top.v and is not exposed as a port. A less-synchronized
    // reset costs a frame or two of garbage right after power-on at worst,
    // not the persistent, silent picture defect the clocking choice in
    // fpga/video_out.v's own header exists to avoid.
    wire [7:0] vid_r, vid_g, vid_b;
    wire       vid_de, vid_hsync, vid_vsync;

    video_out VIDEO (
        .clk(clk_25mhz), .clk_25mhz(clk_25mhz), .rst(~rst_n),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_de(vid_de), .vid_hsync(vid_hsync), .vid_vsync(vid_vsync),
        .gpdi_dp(gpdi_dp)
    );
`endif

    // Card detect is brought out so the pin is claimed and constrained, but
    // the boot ROM does not consult it - it finds out whether a card is there
    // by trying to talk to one, which is what it has to do anyway.
    wire _unused_ok = &{1'b0, sd_cdn, btn[6:2], btn[0], 1'b0};
endmodule
