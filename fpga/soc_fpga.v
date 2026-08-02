// FPGA top level for the SoC (rtl/soc/soc_top.v).
//
// !! NEVER RUN ON HARDWARE !!  This builds all the way through - yosys,
// nextpnr-ecp5 and ecppack all complete - and via fpga/ulx3s_top.v it does so
// against a **real pinout**, closing timing at 25 MHz with a measured Fmax of
// 29.37 MHz on an LFE5U-45F. What has *not* happened is any of it running on
// a board, because there is no board.
//
// Synthesized, placed, routed and timed against real pins: yes. Executed: no.
// See fpga/README.md for exactly which claims have evidence behind them.
//
// This file stays board-agnostic on purpose: it asks for a clock, an
// active-low reset, a UART pair, four SPI wires, GPIO and four LEDs, and
// knows nothing about what they are called on any particular board. That
// mapping lives in a wrapper - fpga/ulx3s_top.v is the worked example.
//
// Differences from fpga/top_fpga.v (which wraps the older flat, pre-bus
// rtl/top.v and is left alone): this instantiates the full Wishbone SoC, so
// it also brings out SPI and GPIO pins, and it boots from ROM rather than
// having a program baked into instruction memory.
//
// Two things here exist for real hardware and have no simulation equivalent:
//   - a reset synchronizer, because a button is asynchronous to the clock
//     and releasing reset on different flops in different cycles is a
//     genuinely common cause of "works in simulation, hangs on the board"
//   - tristate drivers on the GPIO pins, since simulation used separate
//     in/out/dir vectors but a physical pin is bidirectional
module soc_fpga #(
    // CLK_HZ MUST match the clock actually arriving on `clk` - it is what the
    // UART bit period is derived from, so getting it wrong produces a console
    // that emits pure garbage even when timing closes. See fpga/README.md.
    //
    // Two things to keep in step with this:
    //   - software/soc/soc.h's CPU_HZ, which derives the SD initialization
    //     clock from it. Nothing checks the two agree.
    //   - the design's measured Fmax, currently ~30 MHz. This default used to
    //     be 50 MHz, which is a clock this design cannot run at - a build that
    //     took it at face value would miss timing and misbehave rather than
    //     fail cleanly. 25 MHz is both achievable with margin and the ULX3S
    //     oscillator frequency, so it needs no PLL there.
    //
    // A board whose oscillator is faster than about 30 MHz needs a PLL to
    // divide it down; there is deliberately none here, because the target
    // board does not need one. `ecppll -i <osc> -o 25 -n pll --file pll.v`
    // generates one for the ECP5 if yours does.
    parameter CLK_HZ    = 25_000_000,
    parameter BAUD_RATE = 115_200,
    parameter GPIO_WIDTH = 16,

    // On-chip RAM size. This is the parameter that decides which FPGA the
    // design fits on, so it is exposed here rather than buried in the
    // soc_top instantiation - see fpga/README.md for measured block-RAM cost
    // per size. It is *not* a free knob: the software's linker scripts and
    // software/soc/soc.h's RAM_SIZE have to agree with it.
    parameter RAM_BYTES  = 65536
)(
    input  wire clk,        // board oscillator
    input  wire rst_n,      // active-low reset button (invert if yours is active-high)

    output wire uart_tx,    // to your USB-serial adapter's RX
    input  wire uart_rx,    // from your USB-serial adapter's TX

    // SD card in SPI mode
    output wire spi_sck,
    output wire spi_mosi,
    input  wire spi_miso,
    output wire spi_cs_n,

    inout  wire [GPIO_WIDTH-1:0] gpio,

    output wire [3:0] led
);
    localparam UART_CLKS_PER_BIT = CLK_HZ / BAUD_RATE;

    // ---- reset synchronizer ----
    // Asynchronous assert, synchronous release. The button can change at any
    // point relative to the clock; without this, different flops can come
    // out of reset on different cycles and the pipeline starts in a state it
    // was never designed to be in.
    //
    // The SYNCASYNCNET lint warning fires here because this register is both
    // asynchronously reset and synchronously shifted. That combination
    // usually *is* a bug - it is also precisely what a reset synchronizer
    // is, and the reason this one exists, so it's suppressed narrowly rather
    // than project-wide.
    /* verilator lint_off SYNCASYNCNET */
    reg [2:0] rst_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_sync <= 3'b111;
        else        rst_sync <= {rst_sync[1:0], 1'b0};
    end
    /* verilator lint_on SYNCASYNCNET */
    wire rst = rst_sync[2];

    wire [GPIO_WIDTH-1:0] gpio_in, gpio_out, gpio_dir;
    wire trap;

    // ---- tristate GPIO ----
    // `gpio_dir` bit set = drive the pin. Synthesis tools infer an IOBUF
    // from this pattern; if yours doesn't, instantiate the vendor primitive
    // here instead.
    genvar i;
    generate
        for (i = 0; i < GPIO_WIDTH; i = i + 1) begin : g_gpio
            assign gpio[i]    = gpio_dir[i] ? gpio_out[i] : 1'bz;
            assign gpio_in[i] = gpio[i];
        end
    endgenerate

    soc_top #(
        .ROM_WORDS(4096),
        .RAM_BYTES(RAM_BYTES),
        .ROM_INIT_FILE("bootrom.hex"),
        .UART_CLKS_PER_BIT(UART_CLKS_PER_BIT),
        .GPIO_WIDTH(GPIO_WIDTH)
    ) SOC (
        .clk(clk), .rst(rst),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .trap(trap)
    );

    // ---- board-level status LEDs ----
    // Four bits, split between what the fabric knows and what the firmware
    // knows, because those fail in different ways:
    //
    //   led[3] trap_seen   sticky - the CPU has taken a trap at least once
    //   led[2] heartbeat   ~0.75 Hz at 25 MHz. Driven from a free-running
    //                      counter, so it keeps blinking even if the CPU is
    //                      wedged: it proves the clock arrived, the
    //                      bitstream loaded and the fabric is alive, and it
    //                      says nothing at all about software.
    //   led[1:0]           boot stage, driven by firmware through GPIO_OUT's
    //                      low two bits. See software/soc/bootrom.c's
    //                      BOOT_STAGE_* codes.
    //
    // The firmware bits are mirrored from `gpio_out` rather than given their
    // own peripheral, so no new hardware was needed for them. They read back
    // regardless of `gpio_dir` - firmware writes GPIO_OUT and the LEDs
    // follow, without having to configure the pins as outputs first - and
    // GPIO pins 1:0 happen to mirror the same two bits, which is harmless.
    //
    // Why this exists: every failure path in the boot ROM prints to the UART
    // and then stops. With no serial cable attached, a board that failed to
    // find its SD card and a board that booted perfectly look identical -
    // both just sit there with the heartbeat blinking. These two bits are
    // what makes first bring-up diagnosable before the serial side works.
    reg [24:0] heartbeat;
    always @(posedge clk or posedge rst) begin
        if (rst) heartbeat <= 25'b0;
        else     heartbeat <= heartbeat + 25'd1;
    end

    reg trap_seen;
    always @(posedge clk or posedge rst) begin
        if (rst)       trap_seen <= 1'b0;
        else if (trap) trap_seen <= 1'b1;
    end

    assign led = {trap_seen, heartbeat[24], gpio_out[1:0]};
endmodule
