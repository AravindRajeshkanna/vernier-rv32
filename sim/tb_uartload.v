`timescale 1ns/1ps
// The boot ROM's UART loader, end to end: a host sends a program over the
// serial line, the ROM writes it into external SDRAM, and the program runs.
//
// This is the last link in docs/roadmap.md Phase 2. `make sim_sdramboot`
// proves a program *executing* from SDRAM by having the testbench preload the
// model, which is a machine no board is - a bitstream initialises block RAM
// at FPGA configuration time and SDRAM comes up holding nothing. This proves
// the path that actually exists on hardware, and it is the same protocol,
// byte for byte, that software/soc/uartload.py speaks.
//
// The testbench plays the host: it knocks, sends a header with a real CRC32
// over the payload, and waits for an acknowledgement after every chunk -
// which is what lets it run at four clocks per bit without outrunning a
// receiver that also has to compute that CRC. See soc.h.
module tb_uartload;
    localparam CLK_PERIOD   = 40;              // 25 MHz, matching CLK_HZ
    localparam CLKS_PER_BIT = 4;               // must match soc_top's divisor
    localparam BIT_NS       = CLK_PERIOD * CLKS_PER_BIT;
    localparam ROW_BITS     = 13;
    localparam COL_BITS     = 9;
    localparam BA_BITS      = 2;
    localparam MEM_WORDS    = (1 << 21);

    // Protocol, from software/soc/soc.h.
    localparam [31:0] UARTLOAD_MAGIC = 32'h55434F53;
    // Must match software/soc/soc.h. ACK and NAK are ASCII control codes
    // because the console shares this wire: they were 'K' and 'E', and "KB" -
    // which every program in this repository prints - put the old ACK byte
    // into ordinary console text. docs/practices.md section 36.
    localparam [7:0]  PROBE = 8'h55, ACK = 8'h06, NAK = 8'h15;

    localparam [31:0] LOAD_ADDR = 32'h9000_0000;

    reg clk = 0;
    reg rst = 1;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg  host_tx = 1'b1;                        // idle high
    wire uart_tx;

    wire spi_sck, spi_mosi, spi_cs_n;
    wire [15:0] gpio_out, gpio_dir;
    wire        trap;
    wire [15:0] gpio_in = (gpio_out & gpio_dir) | (16'hxxxx & ~gpio_dir);
    wire        spi_miso = 1'b1;                // no card in the slot

    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [ROW_BITS-1:0] sd_a;
    wire [BA_BITS-1:0]  sd_ba;
    wire [1:0]  sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;
    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    soc_top #(
        .ROM_WORDS(4096),
        .RAM_BYTES(65536),                      // the board's block RAM
        .ROM_INIT_FILE("bootrom.hex"),
        .RAM_INIT_FILE(""),                     // nothing preloaded anywhere
        .UART_CLKS_PER_BIT(CLKS_PER_BIT),
        .GPIO_WIDTH(16),
        .CLK_HZ(25_000_000),
        .SDRAM_ROW_BITS(ROW_BITS),
        .SDRAM_COL_BITS(COL_BITS),
        .SDRAM_BA_BITS(BA_BITS)
    ) DUT (
        .clk(clk), .rst(rst),
        // No debug host in this testbench. TCK parked low means the TAP's
        // state machine never advances and the Debug Module stays in reset,
        // which is exactly what a board with no debug cable does.
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(host_tx),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .spi_cs_n(spi_cs_n),
        .vid_r(), .vid_g(), .vid_b(),
        .vid_de(), .vid_hsync(), .vid_vsync(),
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n),
        .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
        .trap(trap)
    );

    // Clocked 180 degrees out, as fpga/sdram_clk_out.v arranges on the board.
    sdram_model #(
        .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .BA_BITS(BA_BITS),
        .MEM_WORDS(MEM_WORDS)
    ) MEM (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );

    // ---- the image the host is going to send ----
    localparam integer MAX_IMAGE = 262144;
    reg [7:0] image [0:MAX_IMAGE-1];
    integer   image_len;

    // ---- host UART ----
    // Bit periods are counted in *clock edges*, not in nanoseconds.
    //
    // `#(CLK_PERIOD*CLKS_PER_BIT)` from an arbitrary starting instant looks
    // equivalent and is not: it leaves the frame at whatever phase the
    // testbench happened to be at, and rtl/uart.v's receiver synchronises the
    // line through two flops before its half-bit centring, so at four clocks
    // per bit there is very little of the bit left to be wrong about. Driving
    // on the negative edge puts every transition half a clock away from the
    // edge that samples it.
    task host_send(input [7:0] b);
        integer i;
        begin
            @(negedge clk); host_tx = 1'b0;                 // start bit
            repeat (CLKS_PER_BIT - 1) @(negedge clk);
            for (i = 0; i < 8; i = i + 1) begin
                @(negedge clk); host_tx = b[i];
                repeat (CLKS_PER_BIT - 1) @(negedge clk);
            end
            @(negedge clk); host_tx = 1'b1;                 // stop bit
            repeat (CLKS_PER_BIT - 1) @(negedge clk);
        end
    endtask

    // Receive one byte from the board. Waits for a start bit, so it blocks
    // until the board says something.
    task host_recv(output [7:0] b);
        integer i;
        begin
            @(negedge uart_tx);
            #(BIT_NS * 3 / 2);                  // into the middle of bit 0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = uart_tx;
                #BIT_NS;
            end
        end
    endtask

    // The board's console, printed as it arrives - except while a transfer is
    // in flight, when the ROM emits nothing but acknowledgements and this
    // process must not steal them. See software/soc/bootrom.c.
    reg       transfer_active = 1'b0;
    reg [7:0] con_byte;
    initial begin
        forever begin
            if (transfer_active) begin
                @(negedge transfer_active);
            end else begin
                fork : con
                    begin host_recv(con_byte); $write("%c", con_byte); $fflush; end
                    begin @(posedge transfer_active); end
                join_any
                disable con;
            end
        end
    end

    // ---- CRC32, the ordinary reflected one, to match the ROM ----
    function [31:0] crc32_step(input [31:0] crc, input [7:0] b);
        integer k;
        reg [31:0] c;
        begin
            c = crc ^ {24'b0, b};
            for (k = 0; k < 8; k = k + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            crc32_step = c;
        end
    endfunction

    integer errors = 0;
    reg [7:0]  r;
    integer    i, sent, n;
    integer    knocked;
    reg [31:0] crc;

    // A reply that is not an acknowledgement ends the run.
    //
    // Carrying on is worse than useless: the ROM stops on any rejection, so
    // every later `host_recv` waits on a line nobody is driving and the test
    // sits there until the global timeout. The first version did exactly that
    // and turned a two-second failure into a fifteen-minute one.
    task expect_ack(input [1023:0] what);
        begin
            host_recv(r);
            if (r !== ACK) begin
                $display("\n  FAIL: reply 0x%02x ('%c') after %0s - wanted ACK",
                         r, r, what);
                errors = errors + 1;
                disable protocol;
            end
        end
    endtask

    wire [31:0] result_word = DUT.RAM.mem[0];
    localparam [31:0] RESULT_PASS = 32'h50415353;  // "PASS"
    localparam [31:0] RESULT_FAIL = 32'h4641494C;  // "FAIL"

    integer cycles = 0;
    always @(posedge clk) cycles = cycles + 1;

    initial begin
    // Waveforms are opt-in: run with `+dump`, or `make <target> DUMP=1`.
    //
    // This used to be unconditional, and the cost scales with how long the
    // run is - which for the SoC-level tests is millions of cycles over a
    // whole SoC. `make sim_sdramboot` alone wrote a **6.2 GB** VCD, and
    // `make sim_uartload` an **18 GB** one, so a single `make verify` filled
    // a 228 GB disk to 100% and took the machine down with it. Nobody looks
    // at these files unless they are debugging, and when they are, one
    // plusarg is not a hardship.
        if ($test$plusargs("dump")) begin
            $dumpfile("wave_uartload.vcd");
            $dumpvars(0, tb_uartload);
        end
        for (i = 0; i < MAX_IMAGE; i = i + 1) image[i] = 8'h00;
        #1;
        $readmemh("uartimage.hex", image);
        image_len = 0;
        for (i = MAX_IMAGE - 1; i >= 0 && image_len == 0; i = i - 1)
            if (image[i] !== 8'h00) image_len = i + 1;
        // Round up to a word: the image is a .bin and its tail may be zeros
        // that belong to it. Being generous is safe - the ROM copies exactly
        // what it is told and the CRC is computed over the same bytes.
        image_len = ((image_len + 3) / 4) * 4;

        $display("=== boot ROM UART loader ===");
        $display("host has %0d bytes to send to 0x%08x", image_len, LOAD_ADDR); $fflush;

        repeat (4) @(posedge clk);
        rst = 0;

        begin : protocol
        // ---- knock ----
        // The ROM's window opens at reset and is short, so this has to be
        // banging on the door already. Exactly as the host script does it.
        transfer_active = 1'b1;
        knocked = 0;
        while (!knocked) begin
            // A whole probe, then a bounded wait for a reply. Never a
            // `disable` part-way through a transmission: that would leave a
            // half-formed frame on the wire and a garbage byte in the ROM,
            // which is a testbench artefact rather than anything a host does.
            host_send(PROBE);
            fork : waiting
                begin
                    host_recv(r);
                    if (r === ACK) knocked = 1;
                end
                begin repeat (CLKS_PER_BIT * 40) @(negedge clk); end
            join_any
            disable waiting;
        end
        host_tx = 1'b1;
        $display("  ROM answered the knock"); $fflush;

        // ---- header: magic, address, length, CRC32 ----
        crc = 32'hFFFFFFFF;
        for (i = 0; i < image_len; i = i + 1)
            crc = crc32_step(crc, image[i]);
        crc = crc ^ 32'hFFFFFFFF;
        $display("  CRC32 of the payload: 0x%08x", crc); $fflush;

        for (i = 0; i < 4; i = i + 1) host_send(UARTLOAD_MAGIC[8*i +: 8]);
        for (i = 0; i < 4; i = i + 1) host_send(LOAD_ADDR[8*i +: 8]);
        for (i = 0; i < 4; i = i + 1) host_send(image_len[8*i +: 8]);
        for (i = 0; i < 4; i = i + 1) host_send(crc[8*i +: 8]);
        expect_ack("header");
        $display("  header accepted"); $fflush;

        // ---- the image, a byte at a time ----
        // Stop-and-wait: rtl/uart.v's receiver is one byte deep, so the
        // acknowledgement is the only thing stopping this testbench - which
        // drives the line 1.8x faster than the ROM can empty it at four
        // clocks per bit - from overwriting a byte the ROM has not read yet.
        // See soc.h; an earlier version sent 256 at a time and stalled inside
        // the first chunk.
        for (sent = 0; sent < image_len; sent = sent + 1) begin
            host_send(image[sent]);
            expect_ack("a byte");
            if (sent % 1024 == 0 && sent != 0) begin
                $display("  %0d/%0d bytes", sent, image_len); $fflush;
            end
        end
        $display("  %0d bytes sent", sent); $fflush;

        expect_ack("the CRC check");
        $display("  CRC accepted - the board is running it\n"); $fflush;
        end   // protocol
        transfer_active = 1'b0;

        // ---- the program's own verdict ----
        // Only if the transfer actually finished. If it did not, the board is
        // sitting in an error loop and there is no verdict coming; waiting for
        // one just hides the reply that already said so.
        if (errors == 0) begin
            while (result_word !== RESULT_PASS && result_word !== RESULT_FAIL &&
                   cycles < 4_000_000)
                @(posedge clk);
        end
        repeat (200 * CLKS_PER_BIT * 10) @(posedge clk);

        $display("\n---------------------------------------------");
        $display("cycles: %0d", cycles);
        $display("result word (expect \"PASS\"): 0x%08x", result_word);
        if (errors == 0 && result_word === RESULT_PASS)
            $display("UARTLOAD TEST PASSED");
        else if (result_word === RESULT_FAIL)
            $display("UARTLOAD TEST FAILED (the loaded program reported failure)");
        else
            $display("UARTLOAD TEST FAILED (%0d protocol errors, result 0x%08x)",
                     errors, result_word);
        $display("---------------------------------------------");
        $finish;
    end

    // A hang is a failure with a name, not a run that never ends. The
    // protocol has two places it can wedge - a knock nobody answers, and an
    // acknowledgement that never comes - and both would otherwise sit here
    // sending probes forever.
    initial begin
        #200_000_000;
        $display("\nUARTLOAD TEST FAILED (timeout: the board stopped talking)");
        $display("  last state: transfer_active=%b, bytes sent=%0d of %0d",
                 transfer_active, sent, image_len);
        $finish;
    end
endmodule
