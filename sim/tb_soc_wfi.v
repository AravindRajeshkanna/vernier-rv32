`timescale 1ns/1ps
// A wfi that waits (Phase 8 Stage 4, Part 38). The program is software/bench/wfi.S - read its header for what each of its
// six tests does and for the result words this testbench reads back.
//
// WAIT is soc_top's WFI_WAIT: 1 builds the cores whose wfi waits for an enabled interrupt, 0 the cores whose wfi is a
// no-op. The checks below describe the waiting wfi, so the build with WAIT=1 must pass them and the build with WAIT=0
// must fail them (the Makefile requires both: a test that cannot fail on the thing it tests is testing the testbench).
// `make sim_soc_wfi` compiles this twice, with -Ptb_soc_wfi.WAIT=1 and 0.
module tb_soc_wfi;
    parameter WAIT = 1;
    localparam CLKS_PER_BIT = 4;

    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire [15:0] gpio_out, gpio_dir;
    wire spi_sck, spi_mosi, spi_cs_n;
    wire trap;

    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [12:0] sd_a;
    wire [1:0]  sd_ba, sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;
    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    soc_top #(
        .NUM_HARTS(2),
        .RESET_PC(32'h8000_0000),
        .RAM_BYTES(524288),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT),
        .WFI_WAIT(WAIT)
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(16'b0), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(1'b1), .spi_cs_n(spi_cs_n),
        .pwm_out(),
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n),
        .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
        .trap(trap)
    );

    // The SDRAM model, clocked from the opposite edge as on the board (see sim/tb_ramboot.v).
    sdram_model #(.MEM_WORDS(1 << 20)) SDRAMCHIP (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );

    // 25 MHz, which the SDRAM controller's timing (and the model's checks) assume.
    localparam CLK_PERIOD = 40;
    always #(CLK_PERIOD / 2) clk = ~clk;

    integer cycles = 0;
    always @(posedge clk) if (!rst) cycles = cycles + 1;

    // Word indices into DUT.RAM.mem[]: (byte address - 0x8000_0000) / 4, the addresses in wfi.S's header.
    localparam R0 = 576;   // 0x8000_0900, hart 0's results
    localparam R1 = 592;   // 0x8000_0940, hart 1's
    localparam STATUS = 0, T1 = 1, T2 = 2, T3 = 3, T4 = 4, T5 = 5, T5N = 6, T5MEPC = 7, T5WANT = 8, T5H = 9,
               T6CAUSE = 10, T6 = 11, BAD = 12, BADCAUSE = 13;

    integer failures = 0;
    task check(input [511:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %0d (0x%08h), expected %0d", name, got, got, want);
                failures = failures + 1;
            end else begin
                $display("  ok   %0s: %0d", name, got);
            end
        end
    endtask
    // A measurement that must land in [lo, hi].
    task in_range(input [511:0] name, input [31:0] got, input [31:0] lo, input [31:0] hi);
        begin
            if (got < lo || got > hi) begin
                $display("  FAIL %0s: %0d cycles, expected %0d to %0d", name, got, lo, hi);
                failures = failures + 1;
            end else begin
                $display("  ok   %0s: %0d cycles (expected %0d to %0d)", name, got, lo, hi);
            end
        end
    endtask

    reg [31:0] maxcycles;

    initial begin
        if (!$value$plusargs("maxcycles=%d", maxcycles)) maxcycles = 32'd400_000;

        // After time 0, so these are ordered after wb_ram's own zero-fill initial block (Verilog does not order initial blocks).
        #1;
        $readmemh("wfi.hex", DUT.RAM.mem);

        $display("WFI config: WFI_WAIT=%0d", WAIT);
        repeat (4) @(posedge clk);
        rst = 0;

        while (!((DUT.RAM.mem[R0 + STATUS] != 0) && (DUT.RAM.mem[R1 + STATUS] != 0)) && cycles < maxcycles)
            @(posedge clk);

        $display("\n---------------------------------------------");
        $display("WFI total cycles=%0d  hart0 status=%0d  hart1 status=%0d", cycles, DUT.RAM.mem[R0 + STATUS], DUT.RAM.mem[R1 + STATUS]);
        $display("WFI T1=%0d T2=%0d T3=%0d T4=%0d T5=%0d T6=%0d", DUT.RAM.mem[R0 + T1], DUT.RAM.mem[R0 + T2], DUT.RAM.mem[R0 + T3],
                 DUT.RAM.mem[R0 + T4], DUT.RAM.mem[R0 + T5], DUT.RAM.mem[R0 + T6]);
        $display("WFI T5 interrupts=%0d mepc=%08h want=%08h handler at +%0d cycles; T6 cause=%0d; unexpected traps=%0d (cause %0d)",
                 DUT.RAM.mem[R0 + T5N], DUT.RAM.mem[R0 + T5MEPC], DUT.RAM.mem[R0 + T5WANT], DUT.RAM.mem[R0 + T5H],
                 DUT.RAM.mem[R0 + T6CAUSE], DUT.RAM.mem[R0 + BAD], DUT.RAM.mem[R0 + BADCAUSE]);

        check("the run finished before the cycle limit", {31'b0, cycles < maxcycles}, 32'b1);
        check("hart 0 finished", DUT.RAM.mem[R0 + STATUS], 32'd1);
        check("hart 1 finished", DUT.RAM.mem[R1 + STATUS], 32'd1);
        check("no trap other than the ones the tests cause", DUT.RAM.mem[R0 + BAD], 32'd0);

        // T1: the timer 3,000 cycles ahead, interrupts globally off. A wfi that does not wait takes a handful of cycles.
        in_range("T1 wfi lasts until the timer (3,000 cycles)", DUT.RAM.mem[R0 + T1], 2900, 3300);
        // T2: already due. Must not wait; this one is a no-op in both builds.
        in_range("T2 wfi with an interrupt already pending falls through", DUT.RAM.mem[R0 + T2], 0, 100);
        // T3: hart 1's software interrupt after 4,000 cycles.
        in_range("T3 wfi lasts until hart 1's software interrupt (4,000)", DUT.RAM.mem[R0 + T3], 3800, 4600);
        // T4: a pending interrupt that is not enabled does not end the wait (2,000 + 4,000).
        in_range("T4 a pending but not enabled interrupt does not wake it (6,000)", DUT.RAM.mem[R0 + T4], 5800, 6700);
        // T5: interrupts on. Once, after the wfi, with mepc at the instruction after it.
        check("T5 the timer interrupt was taken once", DUT.RAM.mem[R0 + T5N], 32'd1);
        check("T5 mepc is the instruction after the wfi", DUT.RAM.mem[R0 + T5MEPC], DUT.RAM.mem[R0 + T5WANT]);
        in_range("T5 the handler ran when the timer fired (2,500)", DUT.RAM.mem[R0 + T5H], 2400, 2800);
        in_range("T5 the wfi lasted until the interrupt (2,500)", DUT.RAM.mem[R0 + T5], 2400, 2900);
        // T6: a user-mode wfi is illegal and must trap at once, not wait.
        check("T6 the user-mode wfi trapped as an illegal instruction", DUT.RAM.mem[R0 + T6CAUSE], 32'd2);
        in_range("T6 and did not wait", DUT.RAM.mem[R0 + T6], 0, 400);

        if (failures == 0) $display("\nSOC-WFI: PASS");
        else               $display("\nSOC-WFI: FAIL (%0d)", failures);
        $display("---------------------------------------------");
        $finish;
    end
endmodule
