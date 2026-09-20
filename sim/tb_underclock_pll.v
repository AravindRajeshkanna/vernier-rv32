// Checks fpga/underclock_pll.v's simulation-mode fallback, not the real
// EHXPLLL hardware primitive - that has no Icarus model and is checked
// instead by an actual nextpnr-ecp5 run (docs/roadmap.md's "CORE=ooo has
// no Fmax" entry records whether that closed timing). What this proves:
// the fallback's own divider gives the real 5:1 input-to-output ratio the
// eventual board test depends on, and `locked` behaves like a real PLL's
// - low at reset, rising later, not simply tied high.
`timescale 1ns/1ps
module tb_underclock_pll;
    reg clk_25mhz = 0;
    always #20 clk_25mhz = ~clk_25mhz;   // 25 MHz, this SoC's real input clock

    wire clk_soc, locked;

    underclock_pll UUT (
        .clk_25mhz(clk_25mhz),
        .clk_soc(clk_soc),
        .locked(locked)
    );

    integer errors = 0;

    // ---- locked starts low, and rises within a bounded number of cycles ----
    initial begin
        if (locked !== 1'b0) begin
            $display("  FAIL: locked was already high at time 0");
            errors = errors + 1;
        end
    end

    // ---- clk_soc period is exactly 5x clk_25mhz's period ----
    real s_edge0, s_edge1, soc_period;
    initial begin
        @(posedge clk_soc); s_edge0 = $realtime;
        @(posedge clk_soc); s_edge1 = $realtime;
        soc_period = s_edge1 - s_edge0;
        // 5 x 40 ns = 200 ns exactly, in a fallback with no jitter to allow for.
        if (soc_period < 199.9 || soc_period > 200.1) begin
            $display("  FAIL: clk_soc period %0.2f ns, expected 200.0 ns (5x clk_25mhz, 5 MHz)",
                     soc_period);
            errors = errors + 1;
        end else begin
            $display("  ok   clk_soc period %0.2f ns (5x clk_25mhz, ~5 MHz)", soc_period);
        end
    end

    // ---- locked eventually rises ----
    initial begin
        #2000;
        if (locked !== 1'b1) begin
            $display("  FAIL: locked never rose within 2000 ns");
            errors = errors + 1;
        end else begin
            $display("  ok   locked rose");
        end

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("UNDERCLOCK-PLL-TEST: PASS");
        else             $display("UNDERCLOCK-PLL-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the underclock PLL test never completed");
        $finish;
    end
endmodule
