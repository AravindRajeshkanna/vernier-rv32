// Proves fpga/ulx3s_cmd0.v actually works before it goes on hardware.
//
// A diagnostic that reports the wrong thing is worse than no diagnostic - it
// sends you looking in the wrong place with false confidence. So the probe is
// run against sim/sd_card_model.v, which answers CMD0 with 0x01, and against
// nothing at all, which should read back 0xFF.
//
// Both cases matter. The 0xFF case is the one the hardware is currently
// showing, and if the probe could not distinguish "no card" from a bug in
// itself, it would be worthless.
`timescale 1ns/1ps
module tb_cmd0;
    reg clk = 0;
    always #20 clk = ~clk;          // 25 MHz

    wire [7:0] led;
    wire       wifi_gpio0;
    wire       sd_clk, sd_cmd;
    wire [3:0] sd_d;

    // Pull-ups, as the LPF specifies. Without these the undriven MISO line
    // would be X and the test would prove nothing.
    pullup(sd_d[0]);
    pullup(sd_d[1]);
    pullup(sd_d[2]);
    pullup(sd_d[3]);

    reg card_present = 1'b0;

    ulx3s_cmd0 DUT (
        .clk_25mhz(clk), .btn(7'b0), .led(led), .wifi_gpio0(wifi_gpio0),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_d(sd_d), .sd_cdn(1'b1)
    );

    // An absent card is modelled by deselecting it as well as tri-stating
    // MISO. Tri-stating alone is not enough and was a real bug in this
    // testbench: the model went on receiving commands and queueing responses
    // while it was supposed to be absent, so by the time the card was
    // "inserted" its framing and response queue were out of step with the
    // probe, and a perfectly good probe read 0xFF forever. Holding cs_n high
    // makes an absent card ignore the bus entirely, which is what an empty
    // slot actually does.
    wire model_miso;
    sd_card_model #(.CARD_BYTES(65536)) CARD (
        .sck(sd_clk), .mosi(sd_cmd), .miso(model_miso),
        .cs_n(card_present ? sd_d[3] : 1'b1)
    );
    assign sd_d[0] = card_present ? model_miso : 1'bz;

    integer errors = 0;

    task wait_for_result(input [255:0] what, input [7:0] want);
        integer i;
        reg done;
        begin
            done = 0;
            // One full attempt is ~0.6 s of simulated time: a few hundred
            // microseconds of SPI, then a 0.48 s display hold and a 0.08 s
            // blanking gap. Inserting the card part-way through means waiting
            // for the *next* attempt, so this has to cover at least two
            // cycles. It was 400 ms, which could not span even one, and the
            // probe was blamed for what was a too-short timeout.
            for (i = 0; i < 2500 && !done; i = i + 1) begin
                #1_000_000;                       // 1 ms
                if (DUT.state == 3 && DUT.result === want) done = 1;
            end
            if (done) begin
                $display("  ok   %0s -> 0x%02X", what, want);
            end else begin
                $display("  FAIL %0s: wanted 0x%02X, result is 0x%02X",
                         what, want, DUT.result);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("=== hardware CMD0 probe ===");

        // ---- empty slot ----
        card_present = 1'b0;
        wait_for_result("no card responds", 8'hFF);

        // ---- card inserted while it retries ----
        card_present = 1'b1;
        wait_for_result("card answers CMD0 (idle)", 8'h01);

        // ---- removed again: it must go back to 0xFF, not latch ----
        card_present = 1'b0;
        wait_for_result("card removed again", 8'hFF);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("CMD0 PROBE TEST PASSED");
        else             $display("CMD0 PROBE TEST FAILED (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #3_000_000_000;
        $display("TIMEOUT - the probe never produced a result");
        $finish;
    end
endmodule
