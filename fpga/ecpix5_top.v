// Board wrapper for the ECPIX-5 (LambdaConcept), LFE5UM5G-45F or -85F.
//
// Stage 0 only (docs/roadmap/phase-09-ddr.md's Phase 9 entry) - board bring-up, no DDR
// controller yet. This file has NOT been run on a board: no ECPIX-5 is
// attached to this project's own development session, unlike
// fpga/ulx3s_top.v, which has. Every pin/frequency claim traces to a
// cited source in fpga/constraints/ecpix5.lpf's own header, not to
// silicon - that distinction stays true until a real board confirms it,
// the same honesty fpga/README.md already holds every other claim to.
//
// fpga/soc_fpga.v is deliberately board-agnostic - it asks for `clk`, an
// active-low `rst_n`, a UART pair, four SPI wires, GPIO, a PWM output,
// JTAG, an SDRAM interface, and four LEDs. Stage 0 only has real, cited
// pins for the clock, reset, UART, and one LED - so every other port is
// tied off safely here rather than wired to a guessed pin, exactly the
// same "do not invent a pin" discipline this whole investigation has
// held synthesis claims to.
//
// With -DDDR3_ENABLE (BOARD=ecpix5-ddr3 in fpga/synth/synth_ecp5.sh) this also
// carries the DDR3 interface of rtl/soc/wb_ddr.v: the controller and the
// Wishbone slave at 0xA0000000 are in the build, and the board's DDR3 pins are
// ports. Fifteen address bits, three bank bits, the command strobes, CKE, ODT,
// CK, both byte lanes' DQ, DQS and mask: every one has a pin in
// fpga/constraints/ecpix5_ddr3.lpf, and nothing else is a port. The DRAM's CS# is
// tied low on this board and its RESET# is the board's reset circuit's, CK# is the
// negative pad of CK's pair and the part has no A15 (schematic R02, sheets 7, 3 and 5),
// so the controller has none of the four any more (Phase 9 Stage 1, Part 27), where it had
// them as ports on throwaway pins through Stage 2, Part 15. Not on a board, not
// simulated against a real chip: the behavioural DDR3 model is all there is.
//
// Also with -DDDR3_ENABLE, the board's status LEDs (fpga/ecpix5_ddr3_leds.v has what the colours say): the controller's
// clocks and initialisation on LED0, byte lane 0's calibration on LED1 and lane 1's on LED3; LED2's green stays the CPU's
// heartbeat. The LEDs are RGB, common anode through a resistor each to 3V3, and a 74HC244 sinks them (schematic R02,
// sheet 17): a pin LOW lights a channel, which is what the _n in their names says. Every channel that has no meaning is
// driven HIGH, dark, and not left floating into the buffer's input: that is LED2's red and blue. The pins are in
// fpga/constraints/ecpix5_ddr3.lpf.
module ecpix5_top #(
    // 25 MHz reaches soc_fpga.v, not the board's own 100 MHz oscillator -
    // see fpga/ecpix5_clk_pll.v's own header for why. Same default as
    // fpga/ulx3s_top.v, so nothing downstream (UART baud math, timing
    // loops) needs retuning for a new number.
    parameter CLK_HZ     = 25_000_000,
    parameter GPIO_WIDTH = 16
)(
    input  wire clk_sys,   // 100 MHz board oscillator - see K23 in the LPF
    input  wire rst_n,     // board's own debounced system reset (N5)

    output wire uart_tx,
    input  wire uart_rx,

    output wire led2_g     // soc_fpga.v's led[2] (heartbeat[24]) only
`ifdef DDR3_ENABLE
    ,
    // The other eleven channels of the four RGB LEDs, active low (see the header). LED2's green is led2_g, above.
    output wire        led0_r_n, led0_g_n, led0_b_n,
    output wire        led1_r_n, led1_g_n, led1_b_n,
    output wire        led2_r_n, led2_b_n,
    output wire        led3_r_n, led3_g_n, led3_b_n,
    // Names and widths are rtl/soc/soc_top.v's; the pins are fpga/constraints/ecpix5_ddr3.lpf's.
    output wire        ddr3_ck,
    output wire        ddr3_ras_n, ddr3_cas_n, ddr3_we_n,
    output wire [2:0]  ddr3_ba,
    output wire [14:0] ddr3_a,
    output wire        ddr3_cke, ddr3_odt,
    inout  wire [7:0]  ddr3_dq,
    inout  wire        ddr3_dqs,
    output wire        ddr3_dm,
    inout  wire [7:0]  ddr3_dqu,
    inout  wire        ddr3_udqs,
    output wire        ddr3_udm
`endif
);
    // ---- the SoC's own clock ----
    // Derived from the board's real 100 MHz oscillator - see
    // fpga/ecpix5_clk_pll.v's own header for why the SoC cannot run
    // directly off clk_sys (this design's own measured Fmax is nowhere
    // near 100 MHz). No `locked` gating, matching this project's
    // established convention for every other clock primitive.
    wire soc_clk;
    ecpix5_clk_pll SOC_PLL (
        .clk_sys(clk_sys), .clk_soc(soc_clk), .locked()
    );

    // ---- ports Stage 0 does not yet have real pins for ----
    // Tied off safely rather than wired to a guessed site. Each of
    // these becomes a real board connection in a later stage, once a
    // real pin is found and cited the same way clk_sys/rst_n/uart_*/
    // led2_g already are.
    wire        spi_miso = 1'b1;   // safe idle level, matching an unused pull-up
    wire [15:0] sdram_dq_i = 16'b0;

    wire [GPIO_WIDTH-1:0] gpio;    // left floating - no GPIO header pin claimed yet
    wire [3:0] led;
`ifdef DDR3_ENABLE
    wire [7:0] ddr3_status;        // the controller's, for the LEDs below
`endif

    soc_fpga #(
        .CLK_HZ(CLK_HZ),
        .BAUD_RATE(115_200),
        .GPIO_WIDTH(GPIO_WIDTH),
        // Same 64 KB every other board target defaults to - see
        // fpga/README.md's device table before changing this.
        .RAM_BYTES(65536)
    ) SOC (
        .clk(soc_clk),
        .rst_n(rst_n),
        .uart_tx(uart_tx),
        .uart_rx(uart_rx),

        // No JTAG debug header claimed yet - tied the same safe way
        // fpga/ulx3s_top.v's own header explains for an unconnected
        // TCK: 0 means "no clock", not a floating input free to
        // oscillate into the debug module's own state machine.
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),

        .spi_sck(), .spi_mosi(), .spi_miso(spi_miso), .spi_cs_n(),

        .gpio(gpio),
        .pwm_out(),

        .vid_r(), .vid_g(), .vid_b(),
        .vid_de(), .vid_hsync(), .vid_vsync(),

        .sdram_cke(), .sdram_cs_n(), .sdram_ras_n(), .sdram_cas_n(),
        .sdram_we_n(), .sdram_a(), .sdram_ba(), .sdram_dqm(),
        .sdram_dq_o(), .sdram_dq_oe(), .sdram_dq_i(sdram_dq_i),

        .led(led)
`ifdef DDR3_ENABLE
        ,
        .ddr3_ck(ddr3_ck),
        .ddr3_ras_n(ddr3_ras_n),
        .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .ddr3_dqu(ddr3_dqu), .ddr3_udqs(ddr3_udqs), .ddr3_udm(ddr3_udm),
        .ddr3_status(ddr3_status)
`endif
    );

    // led[2] is heartbeat[24] - see fpga/soc_fpga.v's own
    // `assign led = {trap_seen, heartbeat[24], gpio_out[1:0]}`, read
    // directly rather than assumed. led[3]/led[1:0] have no real pin
    // yet (led[1:0] carries GPIO state, which Stage 0 has none of).
    assign led2_g = led[2];

`ifdef DDR3_ENABLE
    // ---- the controller's status on the board's RGB LEDs ----
    // {blue, green, red}, 1 = lit, from the decoder; the board's LEDs are active low, so the pin is the complement.
    wire [2:0] led_ctl_rgb, led_l0_rgb, led_l1_rgb;
    ecpix5_ddr3_leds LEDS (
        .ddr3_status(ddr3_status),
        .led_ctl_rgb(led_ctl_rgb), .led_l0_rgb(led_l0_rgb), .led_l1_rgb(led_l1_rgb)
    );
    assign {led0_b_n, led0_g_n, led0_r_n} = ~led_ctl_rgb;
    assign {led1_b_n, led1_g_n, led1_r_n} = ~led_l0_rgb;
    assign {led3_b_n, led3_g_n, led3_r_n} = ~led_l1_rgb;
    // LED2's red and blue have no meaning here: driven dark, not left floating.
    assign led2_r_n = 1'b1;
    assign led2_b_n = 1'b1;
`endif

    wire _unused_ok = &{1'b0, led[3], led[1:0], 1'b0};
endmodule
