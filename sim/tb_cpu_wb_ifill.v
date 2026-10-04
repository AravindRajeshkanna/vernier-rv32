`timescale 1ns/1ps
// rtl/soc/cpu_wb.v's instruction-cache line fills (Phase 8 Part 9, step 2b).
//
// A miss in the SDRAM window (0x90-0x91) fetches the whole 16-byte-aligned
// line as four acks and caches all four words; anywhere else a miss is one
// word. The "core" here is a driver that presents an address and takes the
// word on the cycle `ibus_wait` drops, the way rtl/cpu_core.v does, against a
// bus slave that can burst and a monitor that checks the protocol the
// interconnect and the SDRAM controller rely on: the request, burst flag and
// address held steady until the last ack, a burst's address 16-byte aligned,
// and exactly four acks to a burst and one to anything else.
module tb_cpu_wb_ifill;
    reg clk = 0;
    reg rst = 1;
    always #20 clk = ~clk;

    reg  [31:0] imem_addr = 0;
    wire [31:0] imem_rdata;
    wire        ibus_wait;
    reg         fence_i = 0;

    wire        iwb_cyc, iwb_stb, iwb_burst;
    wire [31:0] iwb_adr;
    reg  [31:0] iwb_dat_r = 0;
    reg         iwb_ack = 0;

    cpu_wb #(.DCACHE_ENABLE(0)) DUT (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(imem_rdata), .ibus_wait(ibus_wait),
        .itlb_wait_stall(1'b0),
        .dmem_addr(32'b0), .dmem_wdata(32'b0), .dmem_we(1'b0), .dmem_re(1'b0),
        .dmem_is_amo(1'b0), .dmem_size(2'b10),
        .dmem_rdata(), .dmem_rvalid(), .dbus_wait(),
        .fence_i(fence_i), .snoop_wr(1'b0), .snoop_adr(32'b0),
        .iwb_cyc(iwb_cyc), .iwb_stb(iwb_stb), .iwb_adr(iwb_adr), .iwb_burst(iwb_burst),
        .iwb_dat_r(iwb_dat_r), .iwb_ack(iwb_ack),
        .dwb_cyc(), .dwb_stb(), .dwb_we(), .dwb_adr(), .dwb_dat_w(), .dwb_sel(),
        .dwb_dat_r(32'b0), .dwb_ack(1'b0)
    );

    // ---- the memory behind the bus: a word is a function of its address and
    // an epoch the test bumps to stand in for "the code was rewritten" ----
    integer epoch = 0;
    function [31:0] mem(input [31:0] a, input integer e);
        mem = {a[15:0] ^ 16'hA5A5, ~a[15:0]} ^ (32'h0101_0101 * e);
    endfunction

    // ---- the slave: LAT cycles to the first ack, GAP idle cycles between the
    // acks of a burst. The memory is read when the transfer starts, as a
    // pipelined controller reads it at the READ command, so a burst in flight
    // across a rewrite delivers the old words. ----
    integer LAT = 4, GAP = 1;
    integer n_single = 0, n_burst = 0, n_acks = 0;
    integer n_b400 = 0, n_b500 = 0;     // bursts to the two lines the FENCE.I tests watch
    integer errors = 0;
    task fail(input [1023:0] msg);
        begin $display("  FAIL: %0s", msg); errors = errors + 1; end
    endtask

    reg        sl_busy = 0, sl_burst = 0;
    reg [31:0] sl_base = 0;
    integer    sl_wait = 0, sl_idx = 0, sl_ep = 0;
    // The protocol monitor's copy of the request as it started.
    reg [31:0] m_adr; reg m_burst;
    integer    m_acks = 0;
    always @(posedge clk) begin
        iwb_ack <= 1'b0;
        if (!rst) begin
            if (!sl_busy) begin
                // Not while an ack is on the bus: the master still holds the
                // request through the edge that sees it (wb_sdram.v's
                // `req = cyc && stb && !ack_r`).
                if (iwb_cyc && iwb_stb && !iwb_ack) begin
                    sl_busy <= 1; sl_burst <= iwb_burst; sl_base <= iwb_adr;
                    sl_wait <= LAT; sl_idx <= 0; sl_ep = epoch;
                    m_adr = iwb_adr; m_burst = iwb_burst; m_acks = 0;
                    if (iwb_burst) begin
                        n_burst = n_burst + 1;
                        if (iwb_adr == 32'h9000_0400) n_b400 = n_b400 + 1;
                        if (iwb_adr == 32'h9000_0500) n_b500 = n_b500 + 1;
                        if (iwb_adr[3:0] != 4'b0) fail("a burst at an address that is not 16-byte aligned");
                        if (iwb_adr[31:25] != 7'h48) fail("a burst outside the SDRAM window");
                    end else n_single = n_single + 1;
                end
            end else begin
                // A request in flight is held, unchanged, to its last ack.
                if (!(iwb_cyc && iwb_stb)) fail("cyc/stb dropped before the last ack");
                if (iwb_adr !== m_adr)     fail("address changed during a transfer");
                if (iwb_burst !== m_burst) fail("burst flag changed during a transfer");
                if (sl_wait > 0) sl_wait <= sl_wait - 1;
                else begin
                    iwb_ack   <= 1'b1;
                    iwb_dat_r <= mem(sl_burst ? sl_base + 4*sl_idx : sl_base, sl_ep);
                    n_acks    = n_acks + 1;
                    m_acks    = m_acks + 1;
                    if (!sl_burst || sl_idx == 3) sl_busy <= 0;
                    else begin sl_idx <= sl_idx + 1; sl_wait <= GAP; end
                end
            end
        end
    end
    // An ack when nothing was asked for, or a request after the last ack in
    // the same cycle it should have dropped, would be a protocol bug.
    always @(posedge clk) if (!rst && iwb_ack && !sl_busy && m_acks == 0) fail("ack with no transfer");

    // ---- the "core" ----
    // Drives just after a rising edge (#1), reads at the rising edge, like a
    // registered master: the word is taken at the edge where ibus_wait is low.
    reg [31:0] got;
    task fetch(input [31:0] a);
        begin
            imem_addr = a;
            @(posedge clk);
            while (ibus_wait) @(posedge clk);
            got = imem_rdata;
            #1;
        end
    endtask
    task expect_word(input [31:0] a, input integer e, input [1023:0] what);
        begin
            fetch(a);
            if (got !== mem(a, e)) begin
                $display("  FAIL %0s: [%08h] = %08h, expected %08h", what, a, got, mem(a, e));
                errors = errors + 1;
            end
        end
    endtask
    task idle(input integer n); begin repeat (n) @(posedge clk); #1; end endtask
    task drain; begin idle(40); end endtask   // let any burst in flight finish

    integer i, b0, s0, a0;
    integer errs_before;
    task check(input [1023:0] name);
        begin
            $write("  %-46s", name);
            $display("%0s", (errors == errs_before) ? "ok" : "FAILED");
            errs_before = errors;
        end
    endtask

    initial begin
        errs_before = 0;
        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk); #1;
        $display("");
        $display("=== instruction-cache line fill test ===");

        // ---- T1: 16 sequential words are four line fills ----
        // (The core's reset address, 0, is a boot-ROM miss: one single-word
        // fetch before the test starts, so count from here.)
        drain;
        b0 = n_burst; s0 = n_single; a0 = n_acks;
        for (i = 0; i < 16; i = i + 1) expect_word(32'h9000_0000 + i*4, 0, "sequential");
        drain;
        if (n_burst - b0 != 4 || n_single - s0 != 0 || n_acks - a0 != 16) begin
            $display("  FAIL: 16 sequential words took %0d bursts, %0d singles, %0d acks (want 4, 0, 16)",
                     n_burst - b0, n_single - s0, n_acks - a0);
            errors = errors + 1;
        end
        check("16 words in SDRAM: four bursts, 16 acks");

        // ---- T2: and they are all cached afterwards ----
        b0 = n_burst; s0 = n_single; a0 = n_acks;
        for (i = 0; i < 16; i = i + 1) expect_word(32'h9000_0000 + i*4, 0, "refetch");
        if (n_burst != b0 || n_single != s0 || n_acks != a0) begin
            $display("  FAIL: refetching cached words went to the bus");
            errors = errors + 1;
        end
        check("the filled lines hit: no bus traffic");

        // ---- T3: starting in the middle of a line still fills the whole line ----
        b0 = n_burst;
        for (i = 0; i < 6; i = i + 1) expect_word(32'h9000_0108 + i*4, 0, "mid-line start");
        drain;
        if (n_burst != b0 + 2) begin
            $display("  FAIL: words 0x108..0x11C took %0d bursts, want 2", n_burst - b0);
            errors = errors + 1;
        end
        // The words before the start, in the same line, are cached too.
        b0 = n_burst;
        expect_word(32'h9000_0100, 0, "word before the start");
        expect_word(32'h9000_0104, 0, "word before the start");
        if (n_burst != b0) begin $display("  FAIL: the line's earlier words were not cached"); errors = errors + 1; end
        check("a mid-line miss fills the whole line");

        // ---- T4: outside the SDRAM window a miss is one word ----
        b0 = n_burst; s0 = n_single;
        for (i = 0; i < 4; i = i + 1) expect_word(32'h8000_0000 + i*4, 0, "block RAM");
        expect_word(32'h0000_0040, 0, "boot ROM");
        expect_word(32'hA000_0000, 0, "DDR3 window");
        drain;
        if (n_burst != b0 || n_single != s0 + 6) begin
            $display("  FAIL: non-SDRAM fetches: %0d bursts, %0d singles (want 0, 6)", n_burst - b0, n_single - s0);
            errors = errors + 1;
        end
        check("block RAM, ROM and DDR3 stay single-word");

        // ---- T5: the core moves on before the burst ends; and a redirect
        // before the first ack ----
        b0 = n_burst;
        imem_addr = 32'h9000_0200;          // miss: a burst starts
        idle(2);                             // not yet acked (LAT = 4)
        imem_addr = 32'h9000_0300;          // redirect to another line
        fetch(32'h9000_0300);
        if (got !== mem(32'h9000_0300, 0)) begin $display("  FAIL: word after a redirect"); errors = errors + 1; end
        drain;
        // The abandoned line was filled anyway and is correct.
        a0 = n_acks;
        for (i = 0; i < 4; i = i + 1) expect_word(32'h9000_0200 + i*4, 0, "abandoned line");
        for (i = 0; i < 4; i = i + 1) expect_word(32'h9000_0300 + i*4, 0, "redirect target line");
        if (n_burst != b0 + 2 || n_acks != a0) begin
            $display("  FAIL: redirect: %0d bursts (want 2), refetch added %0d acks (want 0)", n_burst - b0, n_acks - a0);
            errors = errors + 1;
        end
        check("redirect mid-burst: both lines whole and right");

        // ---- T6: FENCE.I during a burst poisons the whole line ----
        b0 = n_b400;
        epoch = 1;
        imem_addr = 32'h9000_0400;          // a burst starts, memory is epoch 1
        idle(2);
        fence_i = 1; idle(1); fence_i = 0;   // the fence lands before the first ack
        fetch(32'h9000_0400);               // the core still gets its (old) word
        imem_addr = 32'h9000_0010;          // and moves on, to a cached word
        drain;
        epoch = 2;                           // "the code was rewritten"
        for (i = 0; i < 4; i = i + 1) expect_word(32'h9000_0400 + i*4, 2, "after FENCE.I");
        if (n_b400 != b0 + 2) begin
            $display("  FAIL: after FENCE.I the line was not refetched (%0d bursts to it, want 2)", n_b400 - b0);
            errors = errors + 1;
        end
        check("FENCE.I mid-burst: nothing stale is kept");

        // ---- T6b: FENCE.I on the very cycle of an ack, words still to come ----
        // The core takes word 0 and moves on; the code is rewritten and FENCE.I
        // lands on the edge that sees the second ack (acks are two cycles apart,
        // GAP = 1), with two words of the old data still on their way. A fence
        // on an ack cycle clears the valid bits but would not by itself stop
        // those two words being cached after it.
        epoch = 3;
        b0 = n_b500;
        imem_addr = 32'h9000_0500;
        @(posedge clk);
        while (!iwb_ack) @(posedge clk);
        #1; imem_addr = 32'h9000_0010;       // moves on after its word
        @(posedge clk); #1;
        epoch = 4; fence_i = 1;              // rewritten, then fenced
        @(posedge clk); #1; fence_i = 0;
        drain;
        for (i = 2; i < 4; i = i + 1) expect_word(32'h9000_0500 + i*4, 4, "after FENCE.I on an ack");
        if (n_b500 < b0 + 2) begin
            $display("  FAIL: words arriving after a same-cycle FENCE.I were cached");
            errors = errors + 1;
        end
        check("FENCE.I on an ack cycle: later words dropped too");

        // ---- T7: a slower slave with gaps between the acks ----
        LAT = 7; GAP = 3; epoch = 0;
        b0 = n_burst;
        for (i = 0; i < 16; i = i + 1) expect_word(32'h9000_0800 + i*4, 0, "slow slave");
        drain;
        if (n_burst != b0 + 4) begin $display("  FAIL: slow slave: %0d bursts, want 4", n_burst - b0); errors = errors + 1; end
        check("gapped acks (latency 7, gap 3)");
        LAT = 4; GAP = 1;

        // ---- T8: every ack of every transfer was accounted for ----
        drain;
        if (n_acks != 4 * n_burst + n_single) begin
            $display("  FAIL: %0d acks for %0d bursts and %0d singles", n_acks, n_burst, n_single);
            errors = errors + 1;
        end
        check("acks = 4 per burst + 1 per single");

        $display("");
        $display("  bursts %0d, singles %0d, acks %0d", n_burst, n_single, n_acks);
        if (errors == 0) $display("CPU_WB IFILL TEST PASSED");
        else             $display("CPU_WB IFILL TEST FAILED (%0d)", errors);
        $display("");
        $finish;
    end
    initial begin
        #20_000_000;
        $display("CPU_WB IFILL TEST FAILED (timeout)");
        $finish;
    end
endmodule
