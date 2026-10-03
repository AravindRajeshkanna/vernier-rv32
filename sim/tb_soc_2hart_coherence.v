`timescale 1ns/1ps
// Data-cache coherence between two harts (Phase 8, the first lever Stage 0
// named). Each hart's data cache is write-through, and nothing before this
// kept one hart's cached copy right when the other hart wrote the same word,
// which is why rtl/soc/soc_top.v turned the cache off whenever NUM_HARTS > 1.
//
// sim/gen_soc2hart_coh.py's program makes six words cross between the
// harts, each already resident in the reader's cache, three each way: a start
// flag, a data word and a done flag one way, then a data word and a go flag
// the other. With a stale cache the run hangs (a poll never sees the
// other hart's write) or reads the old value, so this fails whenever a hart's
// cache keeps serving a line the other hart has overwritten.
`ifndef COH_HEX
`define COH_HEX "soc2hart_coh.hex"
`endif
module tb_soc_2hart_coherence;
    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire spi_sck, spi_mosi, spi_miso, spi_cs_n;
    wire [15:0] gpio_out, gpio_dir;
    wire        pwm_out;
    wire        trap;
    wire [15:0] gpio_in = 16'b0;

`ifdef SDRAM_DATA
    // The shared words live in the SDRAM window (generator argument 0x90000),
    // so this is the same program with the data cache covering SDRAM; code
    // still runs from block RAM. The model's array starts as X, and a poll on
    // an X flag would prove nothing, so the words the program uses are zeroed.
    wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [12:0] sd_a;
    wire [1:0]  sd_ba, sd_dqm;
    wire [15:0] sd_dq_o;
    wire        sd_dq_oe;
    wire [15:0] dq;
    assign dq = sd_dq_oe ? sd_dq_o : 16'bz;

    sdram_model #(.MEM_WORDS(1 << 20)) SDRAMCHIP (
        .clk(~clk), .rst(rst), .cke(sd_cke), .cs_n(sd_cs_n),
        .ras_n(sd_ras_n), .cas_n(sd_cas_n), .we_n(sd_we_n),
        .a(sd_a), .ba(sd_ba), .dqm(sd_dqm), .dq(dq)
    );
    integer k;
    initial for (k = 0; k < 4096; k = k + 1) SDRAMCHIP.mem[k] = 16'h0000;
`endif

    soc_top #(
        .NUM_HARTS(2),
        .RESET_PC(32'h8000_0000),
        .RAM_BYTES(1024),
        .RAM_INIT_FILE(`COH_HEX)
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(1'b0), .jtag_tms(1'b0), .jtag_tdi(1'b0),
        .jtag_tdo(), .jtag_tdo_oe(),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
        .pwm_out(pwm_out),
`ifdef SDRAM_DATA
        .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n),
        .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n), .sdram_we_n(sd_we_n),
        .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm),
        .sdram_dq_o(sd_dq_o), .sdram_dq_oe(sd_dq_oe), .sdram_dq_i(dq),
`else
        // No SDRAM traffic in this variant - the shared words are in block RAM.
        .sdram_dq_i(16'b0),
`endif
        .trap(trap)
    );

    localparam CLK_PERIOD = 40;  // 25 MHz, matching soc_top's own CLK_HZ default
    always #(CLK_PERIOD / 2) clk = ~clk;

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
        repeat (4) @(posedge clk);
        rst = 0;

        // The program is a few dozen instructions; this is far more than a
        // coherent pair needs, and a stale pair never finishes at all.
        repeat (6000) @(posedge clk);

        // What each hart observed, mirrored into block RAM at 0x8000_0300..
        // (word 192 on): the same four words whichever window the shared data
        // lives in.
        check("hart 0 finished",                           DUT.RAM.mem[194], 32'hAAAA1000);
        check("hart 1 finished",                           DUT.RAM.mem[195], 32'hBBBB1000);
        check("hart 0 re-read X and got the new value",    DUT.RAM.mem[192], 32'h22222000);
        check("hart 1 re-read Z and got the new value",    DUT.RAM.mem[193], 32'h33333000);
        check("neither hart trapped", {31'b0, trap}, 32'b0);

        if (failures == 0) $display("\nSOC-2HART-COHERENCE-TEST: PASS");
        else               $display("\nSOC-2HART-COHERENCE-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("\nSOC-2HART-COHERENCE-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
