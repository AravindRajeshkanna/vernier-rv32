`timescale 1ns/1ps
// Directed test for Phase 13 stage 12: software/soc/crt0_rom.S's hart-park
// mailbox and software/soc/bootrom.c's a0=hartid/a1=dtb hand-off, exercised
// through the *real* boot ROM path - not sim/tb_soc_2hart.v's RESET_PC-into-
// RAM shortcut (Phase 13, Stage 8), and not software/opensbi/sbi_stub.S's
// own hardcoded-address stand-in (Stage 10) either. Both of those bypass
// the boot ROM entirely; this is the first Phase 13 test that boots through
// it with two harts.
//
// Modeled on sim/tb_ramboot.v (the preloaded-RAM boot path at the board's
// real 64 KB), with `NUM_HARTS(2)` added. The boot ROM's own "RAM already
// holds a program" fast path is what gets exercised: hart 0 runs the real
// ROM (SPI/UART untouched by hart 1, which parks in crt0_rom.S before any
// of that), finds the preloaded payload, and jumps - releasing hart 1 to
// the same address at the same time.
//
// The payload (sim/ramimage2hart.hex, generated the same field-packing way
// sim/jtagram.hex is) reads a0 directly - not `csrr a0, mhartid` itself,
// since the point is to prove bootrom.c's own hand-off, not that mhartid
// exists - and writes a hart-specific sentinel to a hart-specific RAM word:
//
//   addr 0x80000000 (PROGRAM_LOAD_ADDR - 0x1000): TEST_RESULT_ADDR, the
//     same magic-word convention sim_ramboot's own acceptance test uses
//   addr 0x80000100 / 0x80000104: hart 0's / hart 1's own sentinel
//
// Hart 0 waits for hart 1's sentinel before writing the final PASS word -
// proving hart 1 genuinely ran, not just that hart 0's own path still
// works. Hart 1 needs no wait of its own: by the time it is released, hart
// 0 has already finished its entire boot-ROM sequence (that is what
// releasing it means), so there is nothing left for hart 1 to race.
//
// CORE-aware since Phase 15, stage 3: bootrom.c/crt0_rom.S are plain C/asm
// with no per-hart-type behavior, so the same payload and the same mailbox
// also prove the real boot-ROM path under CORE=hetero - hart 0 (cpu_core.v)
// running the ROM, loading the preloaded payload and releasing hart 1
// (core_ooo.v) to it, the first time this exact mechanism has been
// exercised with the parked hart a genuinely different microarchitecture
// from the one that parked and released it.
`ifndef RAM_IMAGE
`define RAM_IMAGE "ramimage2hart.hex"
`endif

// $(CORE)-suffixed by the Makefile - see sim/tb_ramboot.v's own comment for
// why a fixed "bootrom.hex" name is no longer safe now that the boot ROM's
// embedded device tree varies with $(CORE).
`ifndef ROM_IMAGE
`define ROM_IMAGE "bootrom.hex"
`endif

`ifndef SDRAM_WORDS
`define SDRAM_WORDS (1 << 20)
`endif

module tb_ramboot_2hart;
    localparam CLKS_PER_BIT = 4;
    localparam RAM_BYTES = 65536;

    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire spi_sck, spi_mosi, spi_miso, spi_cs_n;
    wire [15:0] gpio_out, gpio_dir;
    wire        trap;

    wire [15:0] gpio_in = (gpio_out & gpio_dir) | (16'hxxxx & ~gpio_dir);

    // No SD card - if either hart ever fell through to the card path
    // (park failed, or the RAM-preload check failed), it fails there
    // rather than appearing to work.
    assign spi_miso = 1'b1;

    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [12:0] sd_a;
    wire [1:0]  sd_ba, sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;
    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    sdram_model #(.MEM_WORDS(`SDRAM_WORDS)) SDRAMCHIP (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );

    soc_top #(
        .NUM_HARTS(2),
        .RAM_BYTES(RAM_BYTES),
        .ROM_INIT_FILE(`ROM_IMAGE),
        .RAM_INIT_FILE(`RAM_IMAGE),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT)
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .pwm_out(),
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n),
        .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
        .trap(trap)
    );

    localparam CLK_PERIOD = 40;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // ---- UART receiver: decode the TX line back into characters ----
    // If hart 1 were not genuinely parked, it would run the boot ROM's own
    // banner/print sequence concurrently with hart 0 and this would decode
    // as garbage - the same tell tb_ramboot.v's own receiver would give for
    // a corrupted single-hart boot.
    integer i;
    reg [7:0] rx_byte;
    initial begin
        forever begin
            @(negedge uart_tx);
            #(CLK_PERIOD * CLKS_PER_BIT / 2);
            for (i = 0; i < 8; i = i + 1) begin
                #(CLK_PERIOD * CLKS_PER_BIT);
                rx_byte[i] = uart_tx;
            end
            #(CLK_PERIOD * CLKS_PER_BIT);
            $write("%c", rx_byte);
            $fflush;
        end
    end

    wire [31:0] result_word = DUT.RAM.mem[0];
    localparam [31:0] RESULT_PASS = 32'h50415353;  // "PASS"
    localparam [31:0] RESULT_FAIL = 32'h4641494C;  // "FAIL"

    integer failures = 0;
    task check(input [511:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %08h expected %08h", name, got, want);
                failures = failures + 1;
            end else begin
                $display("  ok   %0s: %08h", name, got);
            end
        end
    endtask

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("wave_ramboot_2hart.vcd");
            $dumpvars(0, tb_ramboot_2hart);
        end
        $display("=== preloaded-RAM boot, two harts: %s into %0d KB ===",
                 `RAM_IMAGE, RAM_BYTES / 1024);

        rst = 1;
        repeat (4) @(posedge clk);
        rst = 0;

        while (result_word !== RESULT_PASS && result_word !== RESULT_FAIL)
            @(posedge clk);

        repeat (200 * CLKS_PER_BIT * 10) @(posedge clk);

        $display("\n---------------------------------------------");
        $display("result word (expect \"PASS\"): 0x%08x", result_word);

        check("hart 0's sentinel at 0x8000_0100", DUT.RAM.mem[64],  32'h000000A0);
        check("hart 1's sentinel at 0x8000_0104", DUT.RAM.mem[65],  32'h000000A1);
        check("result word", result_word, RESULT_PASS);

`ifdef CORE_HETERO
        // Phase 15, stage 3: this is the first test to exercise the real
        // boot-ROM mailbox (software/soc/crt0_rom.S's park_hart,
        // software/soc/bootrom.c's hart_release_addr) with the parked hart
        // (hart 1) a genuinely different microarchitecture from the one
        // that released it (hart 0). Same rob_count-based proof
        // sim/tb_soc_2hart.v's own stage 1 check introduced: a hard
        // Icarus compile error against the wrong module if the generate
        // loop's own CORE_HETERO arm ever mis-selected, not a silent pass.
        check("hart 1 is genuinely core_ooo.v - its own rob_count resolves and is defined",
              {31'b0, ^DUT.g_hart[1].CPU.rob_count !== 1'bx}, 32'b1);
`endif

        if (failures == 0) $display("RAMBOOT-2HART TEST PASSED");
        else                $display("RAMBOOT-2HART TEST FAILED (%0d)", failures);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #400_000_000;
        $display("\n---------------------------------------------");
        $display("TIMEOUT - no result word was written");
        $display("last result word: 0x%08x", result_word);
        $display("RAMBOOT-2HART TEST FAILED");
        $display("---------------------------------------------");
        $finish;
    end
endmodule
