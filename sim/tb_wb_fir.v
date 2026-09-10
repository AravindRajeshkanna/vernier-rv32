`timescale 1ns/1ps
// Directed test for rtl/soc/wb_fir.v (Phase 11): loads real filter
// coefficients, streams a sequence of samples through the register
// interface, and checks each output against a sliding-window convolution
// tracked independently in this testbench (its own shift-register model,
// not a copy of the RTL's own hist_mem/acc_r) - the same role
// sim/tb_wb_npu.v's own procedural reference plays for wb_npu.v, extended
// here across many samples rather than one dot product, since a streaming
// filter's correctness depends on the window actually sliding, not just
// on one MAC being right.
//
// Also proves the one genuinely new failure mode this module has that
// wb_npu.v's own bounded int8 dot product never could: saturation. Two
// directed cases push the accumulator's true (unsaturated) sum well past
// both INT32_MAX and INT32_MIN and check the output clamps to exactly
// those bounds rather than wrapping - the reference for both is computed
// in a 64-bit testbench register, wide enough that the comparison itself
// cannot be the thing that overflows.
module tb_wb_fir;
    localparam N_TAPS = 8;
    localparam [7:0] OFF_CTRL   = 8'h00;
    localparam [7:0] OFF_STATUS = 8'h04;
    localparam [7:0] OFF_COEF0  = 8'h08;
    localparam [7:0] OFF_INPUT  = 8'h28;
    localparam [7:0] OFF_OUTPUT = 8'h2C;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         wb_cyc = 0, wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr = 0, wb_dat_w = 0;
    wire [31:0] wb_dat_r;
    wire        wb_ack;

    wb_fir #(.N_TAPS(N_TAPS)) DUT (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack)
    );

    task wb_write(input [31:0] addr, input [31:0] data);
        begin
            wb_cyc = 1; wb_stb = 1; wb_we = 1;
            wb_adr = addr; wb_dat_w = data;
            @(posedge clk);
            #1;
            wb_cyc = 0; wb_stb = 0; wb_we = 0;
        end
    endtask

    task wb_read(input [31:0] addr, output [31:0] data);
        begin
            wb_cyc = 1; wb_stb = 1; wb_we = 0;
            wb_adr = addr;
            #1;
            data = wb_dat_r;
            @(posedge clk);
            #1;
            wb_cyc = 0; wb_stb = 0;
        end
    endtask

    task poll_done;
        begin : poll
            integer n;
            reg [31:0] st;
            n = 0;
            st = 32'h1;
            while (st[0] && n < 64) begin
                wb_read(OFF_STATUS, st);
                n = n + 1;
            end
            check("BUSY clears within N_TAPS-ish cycles", (n < 64), 1'b1);
        end
    endtask

    integer failures = 0;
    task check(input [511:0] name, input got, input want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %0d expected %0d", name, got, want);
                failures = failures + 1;
            end else begin
                $display("  ok   %0s", name);
            end
        end
    endtask
    task check32(input [511:0] name, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("  FAIL %0s: got %08h expected %08h", name, got, want);
                failures = failures + 1;
            end else begin
                $display("  ok   %0s: %08h", name, got);
            end
        end
    endtask

    // ---- testbench's own sliding-window reference model ----
    // Independent of rtl/soc/wb_fir.v's own hist_mem/acc_r: a plain
    // shift-register array plus a widened (64-bit) accumulator, so the
    // saturation cases below cannot overflow the *reference* itself.
    reg signed [15:0] h_model    [0:N_TAPS-1];
    reg signed [15:0] hist_model [0:N_TAPS-1];
    integer k;

    // A task-local loop variable is deliberate, not incidental: this task
    // is called from inside `for (k = ...)` loops below (the saturation
    // sections push N_TAPS-1 samples that way), and this task's own
    // internal loops used to reuse the shared module-level `k` - which
    // left it clobbered on return, silently truncating the caller's own
    // loop to one iteration instead of seven. Caught only by noticing the
    // printed saturation values did not match hand-computed arithmetic;
    // a task-local `j` makes the bug structurally impossible instead of
    // merely fixed once.
    task push_and_check(input signed [15:0] sample, input [511:0] name);
        integer j;
        reg signed [63:0] raw;
        reg signed [31:0] want;
        reg [31:0] got;
        begin
            for (j = N_TAPS - 1; j > 0; j = j - 1)
                hist_model[j] = hist_model[j-1];
            hist_model[0] = sample;

            raw = 64'sd0;
            for (j = 0; j < N_TAPS; j = j + 1)
                raw = raw + ($signed(h_model[j]) * $signed(hist_model[j]));

            if (raw > 64'sd2147483647)       want = 32'sh7FFFFFFF;
            else if (raw < -64'sd2147483648) want = 32'sh80000000;
            else                              want = raw[31:0];

            wb_write(OFF_INPUT, {16'b0, sample});
            poll_done;
            wb_read(OFF_OUTPUT, got);
            check32(name, got, want);
        end
    endtask

    initial begin
        h_model[0]=16'sd1;  h_model[1]=-16'sd2; h_model[2]=16'sd3;  h_model[3]=-16'sd4;
        h_model[4]=16'sd5;  h_model[5]=-16'sd6; h_model[6]=16'sd7;  h_model[7]=-16'sd8;
        for (k = 0; k < N_TAPS; k = k + 1) hist_model[k] = 16'sd0;
    end

    reg [31:0] rdata;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // ---- load and read back coefficients ----
        for (k = 0; k < N_TAPS; k = k + 1)
            wb_write(OFF_COEF0 + 4*k, {16'b0, h_model[k]});
        wb_read(OFF_COEF0, rdata);
        check32("COEF0 reads back what was written", rdata, {{16{h_model[0][15]}}, h_model[0]});
        wb_read(OFF_COEF0 + 4*7, rdata);
        check32("COEF7 reads back what was written", rdata, {{16{h_model[7][15]}}, h_model[7]});

        // ---- stream 12 samples through a window of depth 8: covers both
        // the window still filling from a zero history (samples 1-7) and
        // the window genuinely sliding, dropping its oldest entry (8-12) ----
        push_and_check(16'sd10,   "sample 1 (window filling)");
        push_and_check(16'sd20,   "sample 2 (window filling)");
        push_and_check(-16'sd30,  "sample 3 (window filling)");
        push_and_check(16'sd40,   "sample 4 (window filling)");
        push_and_check(-16'sd50,  "sample 5 (window filling)");
        push_and_check(16'sd60,   "sample 6 (window filling)");
        push_and_check(-16'sd70,  "sample 7 (window filling)");
        push_and_check(16'sd80,   "sample 8 (window just filled)");
        push_and_check(-16'sd90,  "sample 9 (window sliding, oldest dropped)");
        push_and_check(16'sd100,  "sample 10 (window sliding)");
        push_and_check(-16'sd110, "sample 11 (window sliding)");
        push_and_check(16'sd120,  "sample 12 (window sliding)");

        // ---- disruption: a write attempted mid-MAC must be ignored, not
        // just "the ordinary path works" ----
        wb_write(OFF_INPUT, {16'b0, 16'sd999});
        for (k = N_TAPS - 1; k > 0; k = k - 1) hist_model[k] = hist_model[k-1];
        hist_model[0] = 16'sd999;
        wb_read(OFF_STATUS, rdata);
        check32("BUSY set immediately after a push", rdata, 32'h1);
        wb_write(OFF_INPUT, 32'h0000_1234);   // disruptive re-push attempt
        wb_write(OFF_COEF0, 32'h0000_5678);   // disruptive coefficient overwrite
        begin
            reg signed [63:0] raw;
            reg signed [31:0] want;
            raw = 64'sd0;
            for (k = 0; k < N_TAPS; k = k + 1)
                raw = raw + ($signed(h_model[k]) * $signed(hist_model[k]));
            want = raw[31:0];   // this case does not approach saturation
            poll_done;
            wb_read(OFF_OUTPUT, rdata);
            check32("output undisturbed by the mid-MAC writes", rdata, want);
        end
        wb_read(OFF_COEF0, rdata);
        check32("COEF0 unchanged by the disruptive write attempted mid-MAC",
                rdata, {{16{h_model[0][15]}}, h_model[0]});

        // ---- reset clears history, coefficients untouched ----
        wb_write(OFF_CTRL, 32'h1);
        wb_read(OFF_STATUS, rdata);
        check32("reset does not itself raise BUSY", rdata, 32'h0);
        for (k = 0; k < N_TAPS; k = k + 1) hist_model[k] = 16'sd0;
        push_and_check(16'sd1000, "post-reset sample sees only itself (h[0]*1000)");

        // ---- positive saturation: max coefficients, max-positive samples,
        // window fully replaced so all N_TAPS terms contribute the same
        // large product - true sum is ~4x INT32_MAX ----
        for (k = 0; k < N_TAPS; k = k + 1) begin
            h_model[k] = 16'sd32767;
            wb_write(OFF_COEF0 + 4*k, {16'b0, h_model[k]});
        end
        wb_write(OFF_CTRL, 32'h1);
        for (k = 0; k < N_TAPS; k = k + 1) hist_model[k] = 16'sd0;
        for (k = 0; k < N_TAPS - 1; k = k + 1)
            push_and_check(16'sd32767, "positive saturation, filling window");
        push_and_check(16'sd32767, "positive saturation: clamped to INT32_MAX");

        // ---- negative saturation: same max-positive coefficients against
        // max-negative samples - true sum is well below INT32_MIN ----
        wb_write(OFF_CTRL, 32'h1);
        for (k = 0; k < N_TAPS; k = k + 1) hist_model[k] = 16'sd0;
        for (k = 0; k < N_TAPS - 1; k = k + 1)
            push_and_check(-16'sd32768, "negative saturation, filling window");
        push_and_check(-16'sd32768, "negative saturation: clamped to INT32_MIN");

        if (failures == 0) $display("\nWB-FIR-TEST: PASS");
        else                $display("\nWB-FIR-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #200000;
        $display("\nWB-FIR-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
