// Board wrapper for the ULX3S (Radiona/emard), LFE5U-45F, CABGA381.
//
// fpga/soc_fpga.v is deliberately board-agnostic - it asks for `clk`, an
// active-low `rst_n`, a UART pair, four SPI wires, GPIO and four LEDs. This
// file is the only place that knows what those are actually called on a
// ULX3S, which way round its buttons read, and what has to be driven to stop
// the board interfering with itself.
//
// !! STILL NEVER RUN ON HARDWARE !!  The pin assignments here are real - they
// come from the official ulx3s_v20.lpf and are cross-checked against
// litex-boards' platform file - but no board has been attached. The claim
// this file supports is "the pinout is no longer fictional", which is a
// smaller claim than "this works".
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
    inout  wire [13:0] gn
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
    // claimed and constrained without being driven.
    assign gn[13:2] = 12'bz;

    soc_fpga #(
        .CLK_HZ(CLK_HZ),
        .BAUD_RATE(115_200),
        .GPIO_WIDTH(GPIO_WIDTH),
        // 64 KB fits an LFE5U-45F at 62% block RAM. See fpga/README.md's table
        // before changing this - it is what decides which ECP5 the design fits.
        .RAM_BYTES(65536)
    ) SOC (
        .clk(clk_25mhz),
        .rst_n(rst_n),
        .uart_tx(ftdi_rxd),     // FPGA transmits into the FTDI's receiver
        .uart_rx(ftdi_txd),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .gpio({gn[1:0], gp[13:0]}),
        .led(led[3:0])
    );

    // soc_fpga.v drives four LEDs; the ULX3S has eight. The top nibble is
    // parked rather than left floating so an unlit LED means "unused" instead
    // of "undriven".
    assign led[7:4] = 4'b0000;

    // Card detect is brought out so the pin is claimed and constrained, but
    // the boot ROM does not consult it - it finds out whether a card is there
    // by trying to talk to one, which is what it has to do anyway.
    wire _unused_ok = &{1'b0, sd_cdn, btn[6:2], btn[0], 1'b0};
endmodule
