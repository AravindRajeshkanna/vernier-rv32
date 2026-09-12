`timescale 1ns/1ps
// Directed test for rtl/soc/wb_npu.v (Phase 14): loads a real int8
// activation/weight vector pair through the register interface, triggers
// the MAC engine, and checks the accumulated result against a reference
// dot product computed independently in this testbench (a plain
// procedural sum of products, not a copy of the RTL's own arithmetic) -
// the same role Spike plays for the integer ISA, applied to this
// peripheral's own arithmetic instead.
module tb_wb_npu;
    localparam VEC_LEN = 16;
    localparam [7:0] OFF_CTRL   = 8'h00;
    localparam [7:0] OFF_STATUS = 8'h04;
    localparam [7:0] OFF_A0     = 8'h08;
    localparam [7:0] OFF_W0     = 8'h18;
    localparam [7:0] OFF_RESULT = 8'h28;
    localparam [7:0] OFF_A_ADDR = 8'h30;
    localparam [7:0] OFF_W_ADDR = 8'h34;
    localparam [7:0] OFF_LEN    = 8'h38;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         wb_cyc = 0, wb_stb = 0, wb_we = 0;
    reg  [31:0] wb_adr = 0, wb_dat_w = 0;
    wire [31:0] wb_dat_r;
    wire        wb_ack;

    wire        m_cyc, m_stb, m_ack;
    wire [31:0] m_adr, m_dat_r;

    // A_CACHE_LEN matches the DMA test's own 32-element vectors below,
    // deliberately small rather than the RTL's own 128-element default -
    // proving the cache actually engages/declines at its own boundary
    // needs a boundary this test can afford to cross with a modest
    // memory model, not the default's own real-workload size.
    localparam A_CACHE_LEN = 32;

    wb_npu #(.VEC_LEN(VEC_LEN), .A_CACHE_LEN(A_CACHE_LEN)) DUT (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_adr(m_adr),
        .m_dat_r(m_dat_r), .m_ack(m_ack)
    );

    // Small 1-wait-state behavioral memory model for the DMA master port -
    // the same timing shape as rtl/soc/wb_ram.v (address in one cycle, ack
    // and data the next), so the DMA test below cannot pass merely because
    // reads happen to resolve in zero cycles - the real interconnect never
    // gives it that, and rtl/soc/wb_ptw.v's own two walkers already depend
    // on a master that can wait. Sized with room for the oversized-vector
    // cache test below (which deliberately exceeds A_CACHE_LEN), not just
    // the 32-element DMA test.
    reg [31:0] dma_mem [0:63];
    reg        m_ack_r;
    always @(posedge clk or posedge rst) begin
        if (rst) m_ack_r <= 1'b0;
        else     m_ack_r <= m_cyc && m_stb && !m_ack_r;
    end
    assign m_ack   = m_ack_r;
    assign m_dat_r = dma_mem[m_adr[6:2]];

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

    // ---- reference activation/weight vectors ----
    // A real mix of positive and negative int8 values, so a sign bug in
    // either operand or in the accumulator would show up as a wrong
    // result rather than passing by coincidence (an all-positive vector
    // cannot distinguish signed multiply from unsigned).
    reg signed [7:0] a_ref [0:VEC_LEN-1];
    reg signed [7:0] w_ref [0:VEC_LEN-1];
    integer k;
    reg signed [31:0] expected;

    initial begin
        a_ref[0]=8'sd1;   a_ref[1]=-8'sd2;  a_ref[2]=8'sd3;   a_ref[3]=-8'sd4;
        a_ref[4]=8'sd5;   a_ref[5]=-8'sd6;  a_ref[6]=8'sd7;   a_ref[7]=-8'sd8;
        a_ref[8]=8'sd9;   a_ref[9]=-8'sd10; a_ref[10]=8'sd11; a_ref[11]=-8'sd12;
        a_ref[12]=8'sd13; a_ref[13]=-8'sd14;a_ref[14]=8'sd15; a_ref[15]=-8'sd16;

        w_ref[0]=-8'sd16; w_ref[1]=8'sd15;  w_ref[2]=-8'sd14; w_ref[3]=8'sd13;
        w_ref[4]=-8'sd12; w_ref[5]=8'sd11;  w_ref[6]=-8'sd10; w_ref[7]=8'sd9;
        w_ref[8]=-8'sd8;  w_ref[9]=8'sd7;   w_ref[10]=-8'sd6; w_ref[11]=8'sd5;
        w_ref[12]=-8'sd4; w_ref[13]=8'sd3;  w_ref[14]=-8'sd2; w_ref[15]=8'sd1;
    end

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

    reg [31:0] rdata;

    initial begin
        // Independently computed reference: a plain sum of products over
        // the same two arrays, expressed as its own loop rather than
        // reusing wb_npu.v's own accumulation logic.
        expected = 32'sd0;
        for (k = 0; k < VEC_LEN; k = k + 1)
            expected = expected + (a_ref[k] * w_ref[k]);

        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // Load the operand vectors, 4 int8 lanes per word.
        for (k = 0; k < VEC_LEN/4; k = k + 1) begin
            wb_write(OFF_A0 + 4*k,
                     {a_ref[4*k+3][7:0], a_ref[4*k+2][7:0], a_ref[4*k+1][7:0], a_ref[4*k+0][7:0]});
            wb_write(OFF_W0 + 4*k,
                     {w_ref[4*k+3][7:0], w_ref[4*k+2][7:0], w_ref[4*k+1][7:0], w_ref[4*k+0][7:0]});
        end

        // Read back one word of each before starting, proving the load
        // itself lands correctly rather than only checking it indirectly
        // through the final dot product.
        wb_read(OFF_A0, rdata);
        check("A0 reads back what was written",
              rdata, {a_ref[3][7:0], a_ref[2][7:0], a_ref[1][7:0], a_ref[0][7:0]});
        wb_read(OFF_W0, rdata);
        check("W0 reads back what was written",
              rdata, {w_ref[3][7:0], w_ref[2][7:0], w_ref[1][7:0], w_ref[0][7:0]});

        // Trigger, then immediately try to disrupt it: a second start and
        // an operand overwrite, both while genuinely busy. If either were
        // honored instead of ignored, the final result below would be
        // wrong - this is what actually proves "ignored while busy",
        // not just that the ordinary path works.
        wb_write(OFF_CTRL, 32'h1);
        wb_read(OFF_STATUS, rdata);
        check("BUSY set immediately after start", rdata, 32'h1);
        wb_write(OFF_CTRL, 32'h1);                    // disruptive re-start attempt
        wb_write(OFF_A0, 32'hDEADBEEF);                // disruptive operand overwrite

        begin : poll
            integer n;
            n = 0;
            rdata = 32'h1;
            while (rdata[0] && n < 64) begin
                wb_read(OFF_STATUS, rdata);
                n = n + 1;
            end
            check("BUSY clears within VEC_LEN-ish cycles", (n < 64), 1'b1);
        end

        wb_read(OFF_RESULT, rdata);
        check("dot product matches the independent reference", rdata, expected);

        wb_read(OFF_A0, rdata);
        check("A0 unchanged by the disruptive write attempted mid-MAC",
              rdata, {a_ref[3][7:0], a_ref[2][7:0], a_ref[1][7:0], a_ref[0][7:0]});

        wb_read(OFF_STATUS, rdata);
        check("A_CACHE_VALID starts clear, before any DMA run",
              rdata, 32'h0);

        // ---- DMA mode: a 32-element vector, twice VEC_LEN's own fixed
        // MMIO-mode depth - the actual point of this stage. Populated
        // directly into dma_mem (the behavioral memory the DUT's own bus-
        // master port reads from), never through an MMIO register at all,
        // and checked against a reference computed independently of both
        // the RTL and the MMIO-mode test above. ----
        begin : dma_test
            integer m;
            reg signed [7:0] a_dma, w_dma;
            reg signed [31:0] dma_expected;
            reg [31:0] rd;

            dma_expected = 32'sd0;
            for (m = 0; m < 32; m = m + 1) begin
                a_dma = (m % 2 == 0) ? (m[7:0] + 8'sd1)  : -(m[7:0] + 8'sd1);
                w_dma = (m % 2 == 0) ? -(m[7:0] + 8'sd2) : (m[7:0] + 8'sd2);
                dma_mem[(m>>2)][8*(m&3) +: 8]      = a_dma;   // A vector: words 0-7
                dma_mem[8 + (m>>2)][8*(m&3) +: 8]  = w_dma;   // W vector: words 8-15
                dma_expected = dma_expected + ($signed(a_dma) * $signed(w_dma));
            end

            wb_write(OFF_A_ADDR, 32'h0000_0000);
            wb_write(OFF_W_ADDR, 32'h0000_0020);   // word 8 * 4 bytes
            wb_write(OFF_LEN,    32'd32);

            wb_read(OFF_A_ADDR, rd);
            check("A_ADDR reads back what was written", rd, 32'h0000_0000);
            wb_read(OFF_LEN, rd);
            check("LEN reads back what was written", rd, 32'd32);

            wb_write(OFF_CTRL, 32'h2);   // bit1: start DMA mode
            wb_read(OFF_STATUS, rd);
            check("BUSY set immediately after a DMA start", rd, 32'h1);

            // Disruptive writes attempted mid-DMA: both must be ignored,
            // the same "ignored while busy" contract the MMIO path above
            // already proved, now checked for the DMA-specific registers.
            wb_write(OFF_LEN, 32'd1);
            wb_write(OFF_A_ADDR, 32'hDEAD_BEEF);

            begin : dma_poll
                integer n;
                n = 0;
                rd = 32'h1;
                while (rd[0] && n < 256) begin
                    wb_read(OFF_STATUS, rd);
                    n = n + 1;
                end
                check("DMA BUSY clears within a bounded number of polls", (n < 256), 1'b1);
            end

            wb_read(OFF_RESULT, rd);
            check("DMA dot product (LEN=32) matches the independent reference",
                  rd, dma_expected);
            wb_read(OFF_LEN, rd);
            check("LEN unchanged by the disruptive write attempted mid-DMA",
                  rd, 32'd32);
        end

        // ---- the activation-vector cache: a bit-2 (reuse) start actually
        // reuses on-chip state instead of RAM, and declines gracefully
        // when it cannot. dma_test above already left the cache populated
        // (LEN=32 fits A_CACHE_LEN=32 here) - this continues from there. ----
        begin : cache_test
            integer m;
            reg signed [7:0] a_dma, w2_dma;
            reg signed [31:0] cache_expected;
            reg [31:0] rd;

            wb_read(OFF_STATUS, rd);
            check("A_CACHE_VALID set after a fresh DMA run that fits",
                  rd, 32'h2);

            // A second, different weight vector, at a fresh RAM location -
            // the same activation vector (a_dma, unchanged) against it is
            // an independent computation from dma_test's own reference.
            cache_expected = 32'sd0;
            for (m = 0; m < 32; m = m + 1) begin
                a_dma  = (m % 2 == 0) ? (m[7:0] + 8'sd1) : -(m[7:0] + 8'sd1);
                w2_dma = (m % 2 == 0) ? (m[7:0] + 8'sd3) : -(m[7:0] + 8'sd3);
                dma_mem[16 + (m>>2)][8*(m&3) +: 8] = w2_dma;  // fresh W: words 16-23
                cache_expected = cache_expected + ($signed(a_dma) * $signed(w2_dma));
            end

            // Corrupt the A region in RAM now that it is (supposedly)
            // cached on-chip - if the reuse path quietly re-read RAM
            // instead of the cache, this is what would make that visible:
            // the result below would reflect garbage, not a_dma.
            for (m = 0; m < 8; m = m + 1) dma_mem[m] = 32'hDEAD_DEAD;

            wb_write(OFF_W_ADDR, 32'h0000_0040);  // word 16 * 4 bytes
            // LEN is already 32 from dma_test above - a reuse start needs
            // it to still match, not to be rewritten.
            wb_write(OFF_CTRL, 32'h4);            // bit2: start DMA, reuse cached A

            begin : reuse_poll
                integer n;
                n = 0;
                rd = 32'h1;
                while (rd[0] && n < 256) begin
                    wb_read(OFF_STATUS, rd);
                    n = n + 1;
                end
                check("reuse-mode BUSY clears within a bounded number of polls",
                      (n < 256), 1'b1);
            end

            wb_read(OFF_RESULT, rd);
            check("reuse-mode result uses the cached A, not the now-corrupted RAM",
                  rd, cache_expected);

            // A reuse start whose own LEN does not match what is cached
            // must be a well-defined no-op, not a wrong answer - checked
            // by confirming BUSY never even rises, and RESULT is left
            // exactly as the previous check already found it.
            wb_write(OFF_LEN, 32'd16);
            wb_write(OFF_CTRL, 32'h4);
            wb_read(OFF_STATUS, rd);
            check("mismatched-LEN reuse start is ignored (BUSY stays clear)",
                  rd[0], 1'b0);
            wb_read(OFF_RESULT, rd);
            check("RESULT undisturbed by the ignored mismatched-LEN reuse start",
                  rd, cache_expected);

            // Restore LEN to what the oversized test below expects to set
            // itself, and put A back so nothing downstream trips over the
            // deliberate corruption above.
            for (m = 0; m < 32; m = m + 1) begin
                a_dma = (m % 2 == 0) ? (m[7:0] + 8'sd1) : -(m[7:0] + 8'sd1);
                dma_mem[(m>>2)][8*(m&3) +: 8] = a_dma;
            end
        end

        // ---- a vector too large for the cache: A_CACHE_VALID must clear
        // rather than silently cache a truncated vector. ----
        begin : oversized_test
            integer m;
            reg signed [7:0] a48, w48;
            reg [31:0] rd;

            for (m = 0; m < 48; m = m + 1) begin
                a48 = (m % 2 == 0) ? (m[7:0] + 8'sd1) : -(m[7:0] + 8'sd1);
                w48 = (m % 2 == 0) ? -(m[7:0] + 8'sd2) : (m[7:0] + 8'sd2);
                dma_mem[32 + (m>>2)][8*(m&3) +: 8] = a48;  // words 32-43
                dma_mem[44 + (m>>2)][8*(m&3) +: 8] = w48;  // words 44-55
            end

            wb_write(OFF_A_ADDR, 32'h0000_0080);  // word 32 * 4 bytes
            wb_write(OFF_W_ADDR, 32'h0000_00B0);  // word 44 * 4 bytes
            wb_write(OFF_LEN,    32'd48);
            wb_write(OFF_CTRL,   32'h2);           // bit1: fresh fetch, does not fit the cache

            begin : oversized_poll
                integer n;
                n = 0;
                rd = 32'h1;
                while (rd[0] && n < 256) begin
                    wb_read(OFF_STATUS, rd);
                    n = n + 1;
                end
                check("oversized-run BUSY clears within a bounded number of polls",
                      (n < 256), 1'b1);
            end

            wb_read(OFF_STATUS, rd);
            check("A_CACHE_VALID clears after a run whose LEN exceeds A_CACHE_LEN",
                  rd, 32'h0);
        end

        if (failures == 0) $display("\nWB-NPU-TEST: PASS");
        else                $display("\nWB-NPU-TEST: FAIL (%0d)", failures);
        $finish;
    end

    initial begin
        #100000;
        $display("\nWB-NPU-TEST: FAIL (timeout)");
        $finish;
    end
endmodule
