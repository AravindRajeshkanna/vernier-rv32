// FPGA top level for the SoC (rtl/soc/soc_top.v).
//
// !! NOT VERIFIED ON HARDWARE !!  No synthesis toolchain was available in
// the environment this was written in (no yosys/nextpnr, no Vivado, no
// Quartus) and no board was attached, so this file has been elaborated and
// linted but never synthesized, placed, routed, timed, or run. Treat it as a
// careful starting point, not a known-good design. See fpga/README.md for
// what specifically still needs proving.
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
    // CLK_HZ MUST be changed to your board's actual oscillator frequency -
    // it is what the UART bit period is derived from, so getting it wrong
    // produces a console that emits pure garbage. See fpga/README.md.
    parameter CLK_HZ    = 50_000_000,
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

    // Cheap liveness indicator: a heartbeat plus the trap line, so a board
    // with no serial cable attached still shows whether the CPU is running
    // and whether it is taking traps.
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

    assign led = {trap_seen, heartbeat[24], heartbeat[23], heartbeat[22]};
endmodule
