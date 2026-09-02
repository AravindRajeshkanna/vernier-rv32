// Checks fpga/tmds_serialize.v end to end: drive a known, distinct sequence
// of 10-bit words into it on real clk_pixel edges (from fpga/video_pll.v's
// own simulation fallback, not a hand-rolled clock, so the 5:1 ratio under
// test is the same one the DUT itself assumes), continuously capture the
// serialized bit stream, and search it for the sequence rather than trying
// to align the capture to a predicted cycle.
//
// ---- Why a search, not a predicted cycle offset ----
//
// An earlier version of this test tried to align capture to `UUT.px_rise`
// directly and undercounted by one `clk_bit` cycle per word: the edge for
// word N+1 is detected on the *same* cycle as word N's last bit pair is
// still being sampled (5 `clk_bit` cycles per word, and a fixed detection
// latency that lands right on top of the previous word's tail), so a
// linear "detect, then capture five pairs, then look for the next
// detection" loop consumes six cycles for a period that is only five and
// silently drifts out of phase after the first word. Getting every
// interlocking cycle count exactly right by hand is exactly the kind of
// thing worth not depending on: this instead samples continuously, with no
// assumption about which cycle anything starts on, and asks a weaker but
// sufficient question after the fact - does the known sequence appear,
// intact and in order, at some fixed 10-bit stride, anywhere in the
// captured stream. That is what "the serializer transmits the right bits
// in the right order at the right rate" actually means, without needing to
// predict the DUT's internal phase to check it.
`timescale 1ns/1ps
module tb_tmds_serialize;
    reg clk_25mhz = 0;
    always #20 clk_25mhz = ~clk_25mhz;

    wire clk_bit, clk_pixel, pll_locked;
    video_pll PLL (
        .clk_25mhz(clk_25mhz),
        .clk_bit(clk_bit),
        .clk_pixel(clk_pixel),
        .locked(pll_locked)
    );

    reg        rst = 1;
    reg [9:0]  tmds_word = 10'b0;
    wire       tmds_out;

    tmds_serialize UUT (
        .clk_pixel(clk_pixel),
        .clk_bit(clk_bit),
        .rst(rst),
        .tmds_word(tmds_word),
        .tmds_out(tmds_out)
    );

    // ---- a short, distinct sequence: not a repeating pattern, so a
    // misaligned candidate offset could not accidentally look correct ----
    localparam NWORDS = 6;
    reg [9:0] seq [0:NWORDS-1];
    initial begin
        seq[0] = 10'b0111110000;   // 0x1F0 - tmds_encode.v's own 0x10 vector
        seq[1] = 10'b1011110000;   // 0x2F0 - tmds_encode.v's own 0xEF vector
        seq[2] = 10'b0000000001;
        seq[3] = 10'b1000000000;
        seq[4] = 10'b0101010100;   // a control token, incidentally
        seq[5] = 10'b1100110011;
    end

    integer word_idx = 0;
    always @(posedge clk_pixel) begin
        if (!rst) begin
            tmds_word <= seq[word_idx];
            word_idx  <= (word_idx == NWORDS - 1) ? 0 : word_idx + 1;
        end
    end

    // ---- continuous capture: every bit ODDRX1F would have shifted out ----
    localparam NBITS = 400;   // 40 words' worth - many full cycles of seq[]
    reg [NBITS-1:0] stream;
    integer bit_i;

    initial begin
        @(negedge rst);
        repeat (3) @(posedge clk_pixel);   // let the pipeline fill
        // `#1` after *both* edges, and both are needed for different
        // reasons. Posedge: `tmds_out` on the high phase depends on
        // `pos`/`word_r`, updated by non-blocking assignment in
        // fpga/tmds_serialize.v's own `always @(posedge clk_bit)` block
        // reacting to this same edge - reading with no delay would see the
        // *previous* cycle's value (sim/tb_tmds_encode.v hit the identical
        // issue). Negedge: `tmds_out`'s simulation-mode body is a
        // continuous assignment keyed directly on `clk_bit`
        // (`clk_bit ? d0_r : d1_r`), which re-evaluates in response to the
        // same negedge this loop waits on - a genuinely different case from
        // "nothing is sensitive to that edge," and confirmed as the actual
        // bug here, not a precaution: without this second `#1`, every D1
        // sample read the pre-transition value instead of `d1_r`, a
        // same-event race between the continuous assignment's own
        // re-evaluation and this read, not a non-blocking-assignment one.
        bit_i = 0;
        while (bit_i < NBITS) begin
            @(posedge clk_bit); #1; stream[bit_i] = tmds_out; bit_i = bit_i + 1;
            @(negedge clk_bit); #1; stream[bit_i] = tmds_out; bit_i = bit_i + 1;
        end
    end

    // ---- search: does some 10-bit stride reproduce seq[], in order? ----
    integer offset, w, k, start_word;
    reg [9:0] got;
    reg found;
    integer errors;

    initial begin
        wait (bit_i == NBITS);
        errors = 1;   // cleared below only if a full match is found

        for (offset = 0; offset < 10 && errors; offset = offset + 1) begin
            for (start_word = 0; start_word < NWORDS && errors; start_word = start_word + 1) begin
                found = 1;
                // Check NWORDS consecutive words match seq[], starting from
                // whichever seq[] entry the capture happened to begin on -
                // the driver was already free-running before capture
                // started, so there is no reason to expect it to be seq[0].
                for (w = 0; w < NWORDS; w = w + 1) begin
                    for (k = 0; k < 10; k = k + 1)
                        got[k] = stream[offset + w*10 + k];
                    if (got !== seq[(start_word + w) % NWORDS]) found = 0;
                end
                if (found) begin
                    $display("  ok   found intact sequence at bit offset %0d, starting seq[%0d]",
                             offset, start_word);
                    errors = 0;
                end
            end
        end

        if (errors) begin
            $display("  FAIL: no 10-bit stride reproduced the known sequence");
            $display("  captured stream (first 60 bits): %060b", stream[59:0]);
        end

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("TMDS-SERIALIZE-TEST: PASS");
        else             $display("TMDS-SERIALIZE-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        repeat (10) @(posedge clk_25mhz);
        rst = 0;
    end

    initial begin
        #40_000;
        $display("TIMEOUT - the TMDS serializer test never completed");
        $finish;
    end
endmodule
