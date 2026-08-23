// FPGA top level for the SoC (rtl/soc/soc_top.v).
//
// This runs on hardware. Via fpga/ulx3s_top.v it builds against a **real
// pinout** and has been loaded onto a ULX3S with an LFE5U-85F, where the boot
// ROM comes up on the FTDI console, jumps to the acceptance test in RAM, and
// the test reports SOC-TEST: PASS.
//
// Not everything here is proven by that. The SD card is not - the boot ROM
// reaches CMD0 and gets no answer from a 64 GB SDXC card, so the hardware
// runs are done with RAM preloaded from the bitstream instead. Neither is
// video scan-out, which is left unconnected below. See fpga/README.md for
// which claims have evidence behind them and which do not.
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

    // ---- JTAG debug, on whatever pins the board wrapper has spare ----
    //
    // A board with no debug header ties tck/tms/tdi low and drops tdo: the
    // TAP only advances on a TCK edge, so a parked TCK costs nothing and the
    // Debug Module never leaves reset. `tdo_oe` exists so several TAPs can
    // share one chain; a board driving a single TAP can ignore it.
    input  wire jtag_tck,
    input  wire jtag_tms,
    input  wire jtag_tdi,
    output wire jtag_tdo,
    output wire jtag_tdo_oe,

    output wire uart_tx,    // to your USB-serial adapter's RX
    input  wire uart_rx,    // from your USB-serial adapter's TX

    // SD card in SPI mode
    output wire spi_sck,
    output wire spi_mosi,
    input  wire spi_miso,
    output wire spi_cs_n,

    inout  wire [GPIO_WIDTH-1:0] gpio,

    // ---- video scan-out ----
    // Brought out so a board wrapper can route it, but nothing does yet: a
    // real display needs a 25.175 MHz pixel clock from a PLL and a TMDS
    // serializer, neither of which exists. Left unconnected, synthesis
    // strips the scan-out path and the framebuffer costs only its block RAM
    // - which is the intent for a first bring-up bitstream. See
    // fpga/README.md.
    output wire [7:0] vid_r,
    output wire [7:0] vid_g,
    output wire [7:0] vid_b,
    output wire       vid_de,
    output wire       vid_hsync,
    output wire       vid_vsync,

    // ---- external SDRAM ----
    // Brought out the same way the video pins are: the controller is inside
    // soc_top and always built, but whether these reach a real part is the
    // board wrapper's business. Left unconnected, synthesis keeps the
    // controller (its Wishbone side is reachable) and drops only the pads.
    //
    // The data bus is split into out/enable/in rather than being an `inout`,
    // so this file stays free of tristates - fpga/ulx3s_top.v instantiates
    // the one IO buffer, exactly as it does for the GPIO header.
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_ba,
    output wire [1:0]  sdram_dqm,
    output wire [15:0] sdram_dq_o,
    output wire        sdram_dq_oe,
    input  wire [15:0] sdram_dq_i,

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

    // Preloading RAM from the bitstream removes the SD card from the boot
    // path entirely: the boot ROM notices a program is already there and
    // jumps straight to it. That is a bring-up aid, not the normal flow -
    // it lets everything downstream of the card be tested on hardware while
    // the card itself is still unproven. Selected with -DPRELOAD_RAM, which
    // `BOARD=ulx3s85-ram` passes.
`ifdef PRELOAD_RAM
    localparam RAM_INIT = "ramimage.hex";
`else
    localparam RAM_INIT = "";
`endif

    soc_top #(
        .ROM_WORDS(4096),
        .RAM_BYTES(RAM_BYTES),
        .ROM_INIT_FILE("bootrom.hex"),
        .RAM_INIT_FILE(RAM_INIT),
        .UART_CLKS_PER_BIT(UART_CLKS_PER_BIT),
        .CLK_HZ(CLK_HZ),
        .GPIO_WIDTH(GPIO_WIDTH)
    ) SOC (
        .clk(clk), .rst(rst),
        .jtag_tck(jtag_tck), .jtag_tms(jtag_tms), .jtag_tdi(jtag_tdi),
        .jtag_tdo(jtag_tdo), .jtag_tdo_oe(jtag_tdo_oe),
        .uart_tx(uart_tx), .uart_rx(uart_rx),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .vid_de(vid_de), .vid_hsync(vid_hsync), .vid_vsync(vid_vsync),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
        .sdram_ras_n(sdram_ras_n), .sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n),
        .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dqm(sdram_dqm),
        .sdram_dq_o(sdram_dq_o), .sdram_dq_oe(sdram_dq_oe),
        .sdram_dq_i(sdram_dq_i),
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
