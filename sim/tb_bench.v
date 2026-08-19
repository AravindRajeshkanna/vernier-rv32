`timescale 1ns/1ps
// Testbench for bare-metal benchmark images (CoreMark).
//
//   vvp sim_bench.out +hex=<image> [+maxcycles=N]
//
// Same SoC as everywhere else, with two differences from sim/tb_soc.v, both
// about measurement rather than convenience:
//
//  - The image is loaded straight into the RAM array instead of being pulled
//    off the simulated SD card. Shifting ~30 KB through the bit-banged SPI
//    path costs roughly a million cycles before the first benchmark
//    instruction runs, which would swamp the number being measured. The boot
//    path is still covered by `make sim_soc`.
//  - The run ends on CoreMark's own verdict rather than a fixed cycle
//    budget. CoreMark recomputes CRCs over its results and states whether it
//    validated; matching that statement in the UART stream means the
//    pass/fail here is the benchmark's own conclusion, not a second opinion
//    invented in the testbench.
//
// The cycle count reported at the end is measured with the same `cycle` CSR
// the benchmark itself reads, so the two numbers are directly comparable.
module tb_bench;
    localparam CLKS_PER_BIT = 4;

    reg clk = 0;
    reg rst = 1;

    wire uart_tx;
    wire [15:0] gpio_out, gpio_dir;
    wire spi_sck, spi_mosi, spi_cs_n;
    wire trap;

    soc_top #(
        .RAM_BYTES(262144),
        .RESET_PC(32'h8000_0000),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT)
    ) DUT (
        .clk(clk), .rst(rst),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(16'b0), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(1'b1), .spi_cs_n(spi_cs_n),
        .trap(trap)
    );

    always #5 clk = ~clk;

    integer cycles = 0;
    always @(posedge clk) if (!rst) cycles = cycles + 1;

    // ---- console ----
    // Decodes rtl/uart.v's TX line back into characters, and keeps a rolling
    // window of the last 32 so the benchmark's verdict can be recognized as
    // it arrives.
    localparam WINDOW = 32;
    reg [8*WINDOW-1:0] window = 0;
    reg validated = 0;
    reg errors    = 0;

    // "Correct operation validated" and "Errors detected" are CoreMark's own
    // strings, from core_main.c.
    localparam [8*27-1:0] S_OK  = "Correct operation validated";
    localparam [8*15-1:0] S_ERR = "Errors detected";

    integer i;
    reg [7:0] rx_byte;
    initial begin
        forever begin
            @(negedge uart_tx);                    // start bit
            #(5 * CLKS_PER_BIT * 10 / 10);         // align to mid-bit
            for (i = 0; i < 8; i = i + 1) begin
                #(10 * CLKS_PER_BIT);
                rx_byte[i] = uart_tx;
            end
            #(10 * CLKS_PER_BIT);                  // stop bit
            $write("%c", rx_byte);
            $fflush;
            window = {window[8*(WINDOW-1)-1:0], rx_byte};
            if (window[8*27-1:0] == S_OK)  validated = 1;
            if (window[8*15-1:0] == S_ERR) errors    = 1;
        end
    end

    reg [1023:0] hexfile;
    reg [31:0]   maxcycles;

    initial begin
        if (!$value$plusargs("hex=%s", hexfile)) begin
            $display("BENCH-FAIL no +hex= given");
            $finish;
        end
        if (!$value$plusargs("maxcycles=%d", maxcycles))
            maxcycles = 32'd400_000_000;

        // After time 0, so the load is ordered after wb_ram's own zero-fill
        // initial block (Verilog does not order initial blocks).
        #1;
        $readmemh(hexfile, DUT.RAM.mem);

        repeat (4) @(posedge clk);
        rst = 0;

        while (!validated && !errors && cycles < maxcycles)
            @(posedge clk);

        // Let the tail of the console output drain.
        repeat (400 * CLKS_PER_BIT * 10) @(posedge clk);

        $display("\n---------------------------------------------");
        $display("total cycles (including startup and console I/O): %0d", cycles);
`ifdef CORE_OOO
        // How many instructions retired in slot 1 - i.e. how many dual-issue
        // pairs actually formed on a real workload. Reported next to the
        // cycle count rather than instead of it: a pair rate without a cycle
        // count says nothing about whether the pairing was worth having.
        $display("dual-issue pairs (slot 1 retirements): %0d", DUT.CPU.dual_issue_count);
        $display("  ...out of %0d cycles that offered a second instruction", DUT.CPU.pair_window_count);
        $display("  windows that did not pair, by cause:");
        $display("    slot 0 out of class / predicted taken: %0d", DUT.CPU.pair_blk_slot0);
        $display("    slot 1 out of class:                   %0d", DUT.CPU.pair_blk_class);
        $display("    slot 1 reads slot 0's result:          %0d", DUT.CPU.pair_blk_raw);
        $display("    slot 1 reads a load still in EX:       %0d", DUT.CPU.pair_blk_loaduse);
        $display("stall cycles by cause:");
        $display("  divide        %0d", DUT.CPU.stall_div_count);
        $display("  MMU walk      %0d", DUT.CPU.stall_mmu_count);
        $display("  data bus      %0d  in %0d waits", DUT.CPU.stall_dbus_count, DUT.CPU.dbus_event_count);
        $display("  load-use      %0d", DUT.CPU.stall_loaduse_count);
        $display("  fetch empty   %0d", DUT.CPU.stall_ifetch_count);
        $display("stores handed to the store buffer: %0d", DUT.CPU.store_buffered_count);
        $display("load bus-wait cycles: %0d, of which recoverable by a", DUT.CPU.load_wait_count);
        $display("  load-completion buffer: %0d (taken: %0d)",
                 DUT.CPU.defer_candidate_count, DUT.CPU.defer_taken_count);
        $display("  missed - successor depends on the load: %0d", DUT.CPU.defer_blk_dep);
        $display("  missed - slot 1's pipeline in use:      %0d", DUT.CPU.defer_blk_slot1);
        $display("load-use stall cycles with an independent instruction in the");
        $display("  fetch buffer - the ceiling on out-of-order issue:");
        $display("    an ALU op was available:            %0d", DUT.CPU.loaduse_oo_alu);
        $display("    only a load/store/branch was:       %0d", DUT.CPU.loaduse_oo_any);
        $display("    nothing independent was available:  %0d", DUT.CPU.loaduse_oo_none);
        $display("  window behind the stall: %0d entries summed over %0d stalls, full %0d times",
                 DUT.CPU.loaduse_window_sum, DUT.CPU.stall_loaduse_count,
                 DUT.CPU.loaduse_window_full);
`endif
        // The bus adapter's caches. Reported for both cores, because
        // rtl/soc/cpu_wb.v is shared and neither cache is a core feature.
        $display("data cache: %0d load hits, %0d load misses (%0d.%0d%% hit)",
                 DUT.BUSADAPT.dc_load_hits, DUT.BUSADAPT.dc_load_misses,
                 (100 * DUT.BUSADAPT.dc_load_hits) /
                     (DUT.BUSADAPT.dc_load_hits + DUT.BUSADAPT.dc_load_misses),
                 ((1000 * DUT.BUSADAPT.dc_load_hits) /
                     (DUT.BUSADAPT.dc_load_hits + DUT.BUSADAPT.dc_load_misses)) % 10);
        $display("  store lines updated: %0d, uncached accesses: %0d",
                 DUT.BUSADAPT.dc_store_updates, DUT.BUSADAPT.dc_uncached_reqs);
        if (validated)   $display("BENCHMARK PASSED (CoreMark validated its own results)");
        else if (errors) $display("BENCHMARK FAILED (CoreMark reported errors)");
        else             $display("BENCHMARK FAILED (timed out after %0d cycles)", cycles);
        $display("---------------------------------------------");
        $finish;
    end
endmodule
