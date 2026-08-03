`timescale 1ns/1ps
// Testbench for the official RISC-V architectural tests (riscv-tests).
//
// Compiled once, then re-run per test image via plusargs, because building a
// separate simulation binary for ~80 tests would dominate the runtime:
//
//   vvp sim_isa.out +hex=<image> +tohost=<offset> [+maxcycles=N] [+trace=<file>]
//
// The device under test is the real SoC (rtl/soc/soc_top.v), not a stripped
// harness - same core, same Wishbone interconnect, same wait states. The only
// concession to the test suite is RESET_PC: riscv-tests link at 0x8000_0000
// and expect to start there, so the boot ROM is bypassed rather than being
// taught to chain-load a test image. Everything downstream of the first fetch
// is the system exactly as it ships.
//
// Pass/fail comes from the suite's own `tohost` protocol: a test stores 1 to
// signal success, or (testnum << 1) | 1 to name the sub-test that failed. The
// tohost address is supplied per image by tests/build.sh (read out of the ELF
// with nm) instead of being hardcoded, so a linker-script change upstream
// cannot silently turn every test into a timeout.
module tb_isa;
    // Big enough for every image in the suite; a single divide-heavy test is
    // still only a few thousand instructions.
    localparam RAM_BYTES = 262144;

    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire [15:0] gpio_out, gpio_dir;
    wire spi_sck, spi_mosi, spi_cs_n;
    wire trap;

    soc_top #(
        .RAM_BYTES(RAM_BYTES),
        .RESET_PC(32'h8000_0000)
    ) DUT (
        .clk(clk), .rst(rst),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(16'b0), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(1'b1), .spi_cs_n(spi_cs_n),
        .trap(trap)
    );

    always #5 clk = ~clk;

    // ---- retire tracer, for co-simulation against Spike ----
    // Wired by hierarchical reference rather than by adding six ports to
    // cpu_core and soc_top: the trace is a debug observer, and threading it
    // through the synthesizable module hierarchy would put simulation-only
    // signals in the FPGA wrapper's port list for no benefit. Only writes a
    // file when +trace= is given.
    tracer TRACE (
        .clk(clk), .rst(rst),
        .valid(DUT.CPU.trace_valid),
        .pc(DUT.CPU.trace_pc),
        .instr(DUT.CPU.trace_instr),
        .rd_we(DUT.CPU.trace_rd_we),
        .rd(DUT.CPU.trace_rd),
        .rd_data(DUT.CPU.trace_rd_data)
    );

    // ---- configuration from the command line ----
    reg [1023:0] hexfile;
    reg [31:0]   tohost_off;
    reg [31:0]   maxcycles;

    // ---- the tohost word, read straight out of the RAM array ----
    // wb_ram is a 32-bit word array, so `tohost_off` is a word index (see
    // tests/build.sh). Only the low 32 bits matter: riscv-tests' verdict
    // encoding fits there, and the environment explicitly zeroes the high
    // word.
    wire [31:0] tohost = DUT.RAM.mem[tohost_off];

    integer cycles = 0;
    always @(posedge clk) if (!rst) cycles = cycles + 1;

    initial begin
        if (!$value$plusargs("hex=%s", hexfile)) begin
            $display("ISA-FAIL no +hex= given");
            $finish;
        end
        if (!$value$plusargs("tohost=%h", tohost_off)) begin
            $display("ISA-FAIL no +tohost= given");
            $finish;
        end
        if (!$value$plusargs("maxcycles=%d", maxcycles))
            maxcycles = 32'd2_000_000;

        // Deliberately after time 0: wb_ram's own initial block zero-fills the
        // array, and Verilog does not order initial blocks against each other.
        // Loading a delta later makes the sequence unambiguous, and reset is
        // still asserted for several cycles after this point.
        #1;
        $readmemh(hexfile, DUT.RAM.mem);

        // Prove the image actually arrived before starting the clock.
        //
        // This exists because of a failure that has been seen twice and never
        // reproduced: a handful of otherwise-reliable tests reporting
        // ISA-TIMEOUT at the full 2,000,000 cycles, when they normally finish
        // in about a thousand. Running 2000x long means the core was executing
        // something that never reaches `tohost` - and an unloaded RAM is zeros,
        // which decodes as an illegal instruction and traps forever.
        //
        // `$readmemh` reports a failed open on stderr, and tests/run.sh filters
        // vvp's output down to the ISA- verdict line, so that diagnosis was
        // being thrown away. Checking here converts a silent 2,000,000-cycle
        // timeout into a one-line statement of what went wrong.
        //
        // RESET_PC is 0x8000_0000, the base of RAM, so word 0 is the entry
        // point. Every riscv-tests image starts with a jump there; zero or X
        // means nothing was loaded.
        if (DUT.RAM.mem[0] === 32'h0000_0000 || ^DUT.RAM.mem[0] === 1'bx) begin
            $display("ISA-LOADFAIL first word of %0s is 0x%08x - image not loaded",
                     hexfile, DUT.RAM.mem[0]);
            $finish;
        end

        repeat (4) @(posedge clk);
        rst = 0;

        while (tohost[0] !== 1'b1 && cycles < maxcycles)
            @(posedge clk);

        if (tohost === 32'd1)
            $display("ISA-PASS cycles=%0d", cycles);
        else if (tohost[0] === 1'b1)
            // The suite numbers its sub-tests; recovering that number is the
            // difference between "this test failed" and a usable bug report.
            $display("ISA-FAIL subtest=%0d tohost=0x%08x cycles=%0d",
                     tohost >> 1, tohost, cycles);
        else
            $display("ISA-TIMEOUT cycles=%0d", cycles);

        $finish;
    end
endmodule
