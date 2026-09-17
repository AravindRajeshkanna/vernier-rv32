`timescale 1ns/1ps
// Throwaway diagnostic (Phase 15 Stage 5 investigation) - NOT part of the
// shipped test suite. Two core_ooo.v harts hammer amoswap.w on one shared
// RAM word in a tight loop, each counting how many times it "won". If
// cross-hart AMO atomicity holds, wins0+wins1 should equal the total number
// of attempts and neither hart should ever spin forever.
module tb_ooo_amo_race_debug;
    reg clk = 0;
    reg rst = 1;
    wire uart_tx;
    wire [15:0] gpio_out, gpio_dir;
    wire spi_sck, spi_mosi, spi_cs_n;
    wire trap;

    soc_top #(
        .NUM_HARTS(2),
        .RESET_PC(32'h8000_0000),
        .RAM_BYTES(4096),
        .RAM_INIT_FILE("ooo_amo_race.hex")
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(16'b0), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(1'b1), .spi_cs_n(spi_cs_n),
        .pwm_out(),
        .sdram_dq_i(16'b0),
        .trap(trap)
    );

    localparam CLK_PERIOD = 40;
    always #(CLK_PERIOD / 2) clk = ~clk;

    reg [31:0] prev_lock = 32'hFFFFFFFF;
    always @(posedge clk) begin
        if (DUT.RAM.mem[64] !== prev_lock) begin
            $display("t=%0t lock=%0d  h0[amo=%0b wrph=%0b active=%0b sbv=%0b addr=%08h we=%0b wd=%08h]  h1[amo=%0b wrph=%0b active=%0b sbv=%0b addr=%08h we=%0b wd=%08h]",
                $time, DUT.RAM.mem[64],
                DUT.CPU.dmem_is_amo, DUT.CPU.amo_wr_phase, DUT.CPU.amo_active, DUT.CPU.sb_valid,
                DUT.CPU.dmem_addr, DUT.CPU.dmem_we, DUT.CPU.dmem_wdata,
                DUT.g_hart[1].CPU.dmem_is_amo, DUT.g_hart[1].CPU.amo_wr_phase, DUT.g_hart[1].CPU.amo_active, DUT.g_hart[1].CPU.sb_valid,
                DUT.g_hart[1].CPU.dmem_addr, DUT.g_hart[1].CPU.dmem_we, DUT.g_hart[1].CPU.dmem_wdata);
            prev_lock = DUT.RAM.mem[64];
        end
    end

    initial begin
        if ($test$plusargs("dump")) begin
            $dumpfile("wave_ooo_amo_race.vcd");
            $dumpvars(0, tb_ooo_amo_race_debug);
        end
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (50000) @(posedge clk);
        $display("lock word (0x100): %0d", DUT.RAM.mem[64]);
        $display("hart0 wins (0x104): %0d", DUT.RAM.mem[65]);
        $display("hart1 wins (0x108): %0d", DUT.RAM.mem[66]);
        $display("shared counter (0x10C): %0d", DUT.RAM.mem[67]);
        $display("DONE");
        $finish;
    end
endmodule
