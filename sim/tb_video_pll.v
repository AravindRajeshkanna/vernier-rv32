// Checks fpga/video_pll.v's simulation-mode fallback, not the real EHXPLLL
// hardware primitive - that has no Icarus model and is checked instead by
// an actual nextpnr-ecp5 run (fpga/README.md records whether that stayed
// clean). What this proves: the fallback's own divider logic gives the 5:1
// bit-clock-to-pixel-clock ratio the eventual TMDS serializer depends on,
// and `locked` behaves like a real PLL's - low at reset, rising later, not
// simply tied high.
`timescale 1ns/1ps
module tb_video_pll;
    reg clk_25mhz = 0;
    always #20 clk_25mhz = ~clk_25mhz;   // 25 MHz, this SoC's real input clock

    wire clk_bit, clk_pixel, locked;

    video_pll UUT (
        .clk_25mhz(clk_25mhz),
        .clk_bit(clk_bit),
        .clk_pixel(clk_pixel),
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

    // ---- bit-clock period, measured directly ----
    real t_edge0, t_edge1, bit_period;
    initial begin
        @(posedge clk_bit); t_edge0 = $realtime;
        @(posedge clk_bit); t_edge1 = $realtime;
        bit_period = t_edge1 - t_edge0;
        if (bit_period < 7.9 || bit_period > 8.1) begin
            $display("  FAIL: clk_bit period %0.2f ns, expected ~8.0 ns (125 MHz)", bit_period);
            errors = errors + 1;
        end else begin
            $display("  ok   clk_bit period %0.2f ns (~125 MHz)", bit_period);
        end
    end

    // ---- pixel-clock period is exactly 5x the bit-clock period ----
    real p_edge0, p_edge1, pixel_period;
    initial begin
        @(posedge clk_pixel); p_edge0 = $realtime;
        @(posedge clk_pixel); p_edge1 = $realtime;
        pixel_period = p_edge1 - p_edge0;
        // 5 x 8 ns = 40 ns exactly, in a fallback with no jitter to allow for.
        if (pixel_period < 39.9 || pixel_period > 40.1) begin
            $display("  FAIL: clk_pixel period %0.2f ns, expected 40.0 ns (5x clk_bit)",
                     pixel_period);
            errors = errors + 1;
        end else begin
            $display("  ok   clk_pixel period %0.2f ns (5x clk_bit, ~25 MHz)", pixel_period);
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
        if (errors == 0) $display("VIDEO-PLL-TEST: PASS");
        else             $display("VIDEO-PLL-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the video PLL test never completed");
        $finish;
    end
endmodule
