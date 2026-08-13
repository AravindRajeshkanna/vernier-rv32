// Hardware diagnostic for the ULX3S SD path. No CPU, no bus, no software -
// about 60 flip-flops of pure logic whose only job is to answer questions the
// full SoC cannot answer when it fails.
//
// This exists because "CMD0 gets no response" has several unrelated causes -
// no card, card not seated, wrong pins, card that does not speak SPI - and
// the boot ROM cannot tell them apart from inside. Each is a different fix.
//
// What the LEDs mean:
//
//   led[0]  heartbeat, ~0.75 Hz   the bitstream loaded and the clock is alive
//   led[1]  CARD DETECT           lit = the slot says a card is present
//   led[2]  MISO level, live      lit = the line is currently high
//   led[3]  MISO WENT LOW         sticky: something drove the line low
//   led[4]  btn[1] pressed        confirms the reset button's polarity
//   led[5]  SCK toggling          proves the clock reaches the card's pin
//   led[7:6] off
//
// How to read the two that matter:
//
//   led[1] OFF -> the board does not see a card at all. Mechanical: not
//     seated, wrong slot, or the card-detect switch. No amount of SPI
//     debugging helps until this is lit.
//
//   led[1] ON, led[3] OFF -> a card is seated but nothing ever pulls MISO
//     low. Either the card is not driving the line (it does not speak SPI,
//     which is permitted for SDXC) or MISO is not reaching the FPGA. That
//     distinction is the one worth having.
//
//   led[1] ON, led[3] ON -> the card is present and actively driving MISO.
//     The signal path works, and the problem is protocol rather than wiring.
//
// SCK runs at ~350 kHz - the same rate the boot ROM initializes at, and
// inside the SD spec's 100-400 kHz window - with CS *deasserted* and MOSI
// idle high. That is the state a card sees during the wake-up clocks before
// CMD0, so a card that is going to respond at all has power and a clock here.
module ulx3s_diag (
    input  wire        clk_25mhz,
    input  wire [6:0]  btn,
    output wire [7:0]  led,
    output wire        wifi_gpio0,

    output wire        sd_clk,
    output wire        sd_cmd,
    inout  wire [3:0]  sd_d,
    input  wire        sd_cdn
);
    // The ESP32 shares this board's power control; leaving it undriven lets
    // it reset the board underneath a running design. Same reason as
    // fpga/ulx3s_top.v.
    assign wifi_gpio0 = 1'b1;

    // Every register here is initialized at declaration and has no reset
    // input, which is deliberate: this design must come up and start
    // measuring the moment the FPGA configures, with no button press. An
    // ECP5 honours flip-flop initial values from the bitstream, so the
    // power-up state is exactly what is written below. Verilator flags the
    // combination of an initial value and a procedural assignment because it
    // is usually a simulation/synthesis mismatch; here it is the intended
    // mechanism, so it is suppressed narrowly rather than project-wide -
    // same treatment as SYNCASYNCNET in fpga/soc_fpga.v.
    /* verilator lint_off PROCASSINIT */

    // ---- heartbeat: the bitstream loaded and the clock is running ----
    reg [24:0] hb = 25'd0;
    always @(posedge clk_25mhz) hb <= hb + 25'd1;

    // ---- ~350 kHz SCK ----
    // 25 MHz / (2 * 36) = 347 kHz, matching soc.h's SD_INIT_DIV.
    reg [5:0] div = 6'd0;
    reg       sck = 1'b0;
    always @(posedge clk_25mhz) begin
        if (div == 6'd35) begin
            div <= 6'd0;
            sck <= ~sck;
        end else begin
            div <= div + 6'd1;
        end
    end

    // ---- SD pins, held in the pre-CMD0 wake-up state ----
    assign sd_clk  = sck;
    assign sd_cmd  = 1'b1;   // MOSI idle high
    assign sd_d[3] = 1'b1;   // CS is active low, so high = not selected
    assign sd_d[2] = 1'b1;   // unused in SPI mode, must not float
    assign sd_d[1] = 1'b1;
    assign sd_d[0] = 1'bz;   // MISO: input, so leave the pin undriven
    wire   miso    = sd_d[0];

    // ---- MISO observation ----
    // Synchronized, because this is an asynchronous pin and the sticky latch
    // below would otherwise be a metastability collector. Both flops start
    // high, matching the pull-up, so the latch does not fire on its own
    // reset value.
    reg m1 = 1'b1, m2 = 1'b1;
    reg miso_went_low = 1'b0;

    // Ignore the first ~40 ms so power-up settling cannot look like a card
    // responding.
    reg [19:0] settle = 20'd0;
    wire settled = &settle;

    always @(posedge clk_25mhz) begin
        m1 <= miso;
        m2 <= m1;
        if (!settled)      settle <= settle + 20'd1;
        else if (m2 == 1'b0) miso_went_low <= 1'b1;
    end

    // ---- SCK activity, slowed to something an eye can see ----
    reg        sck_d     = 1'b0;
    reg [19:0] sck_edges = 20'd0;
    always @(posedge clk_25mhz) begin
        sck_d <= sck;
        if (sck && !sck_d) sck_edges <= sck_edges + 20'd1;
    end

    assign led[0] = hb[24];          // ~0.75 Hz
    assign led[1] = ~sd_cdn;         // card detect is active low
    assign led[2] = m2;              // MISO right now
    assign led[3] = miso_went_low;   // MISO ever driven low (sticky)
    assign led[4] = btn[1];          // buttons read high when pressed
    assign led[5] = sck_edges[18];   // ~0.66 Hz if SCK is toggling
    /* verilator lint_on PROCASSINIT */

    assign led[6] = 1'b0;
    assign led[7] = 1'b0;

    // Claimed so the pins are constrained, but deliberately unused here.
    wire _unused_ok = &{1'b0, btn[6:2], btn[0], 1'b0};
endmodule
