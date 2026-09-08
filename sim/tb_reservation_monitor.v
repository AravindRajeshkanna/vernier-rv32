// Directed test for rtl/soc/reservation_monitor.v (Phase 13, the LR/SC
// cross-hart coherence gap docs/roadmap.md names). Purely combinational
// logic, so this drives inputs and checks outputs each cycle rather than
// exercising any bus timing - what needs proving here is the address
// matching and the self-exclusion rule, not sequencing.
`timescale 1ns/1ps
module tb_reservation_monitor;
    reg clk = 0;
    always #10 clk = ~clk;

    localparam NH = 2;

    reg  [NH-1:0]    resv_valid = 0;
    reg  [NH*32-1:0] resv_addr = 0;
    reg  [NH-1:0]    store_fire = 0;
    reg  [NH*32-1:0] store_addr = 0;
    wire [NH-1:0]    resv_invalidate;

    reservation_monitor #(.NUM_HARTS(NH)) DUT (
        .resv_valid(resv_valid), .resv_addr(resv_addr),
        .store_fire(store_fire), .store_addr(store_addr),
        .resv_invalidate(resv_invalidate)
    );

    integer errors = 0;
    task check(input [1023:0] name, input [31:0] got, input [31:0] expected);
        begin
            if (got !== expected) begin
                $display("  FAIL %0s: got %08h expected %08h", name, got, expected);
                errors = errors + 1;
            end else begin
                $display("  ok   %0s: %08h", name, got);
            end
        end
    endtask

    initial begin
        @(posedge clk); #1;

        // ---- 1: cross-hart hit - hart 1's write lands on hart 0's
        // reservation. ----
        resv_valid = 2'b01; resv_addr[31:0] = 32'h8000_0000;   // hart 0 holds a reservation
        resv_addr[63:32] = 32'h0;                              // hart 1's own field, irrelevant while its resv_valid=0
        store_fire = 2'b10; store_addr[63:32] = 32'h8000_0000; // hart 1 writes the same address
        #1;
        check("cross-hart write invalidates the other hart's reservation",
              {30'b0, resv_invalidate}, {30'b0, 2'b01});

        // ---- 2: cross-hart miss - hart 1 writes a *different* address. ----
        store_addr[63:32] = 32'h8000_0004;
        #1;
        check("a write to a different address does not invalidate",
              {30'b0, resv_invalidate}, {30'b0, 2'b00});

        // ---- 3: self-exclusion - hart 0's own write to its own
        // reservation must NOT be flagged here (already handled locally by
        // each core's own existing logic). ----
        store_fire = 2'b01; store_addr[31:0] = 32'h8000_0000; // hart 0 writes its own reserved address
        #1;
        check("a hart's own write to its own reservation is not flagged (handled locally already)",
              {30'b0, resv_invalidate}, {30'b0, 2'b00});

        // ---- 4: no reservation held - a matching write with resv_valid=0
        // has nothing to invalidate. ----
        resv_valid = 2'b00;
        store_fire = 2'b10; store_addr[63:32] = 32'h8000_0000;
        #1;
        check("no reservation held means nothing to invalidate",
              {30'b0, resv_invalidate}, {30'b0, 2'b00});

        // ---- 5: symmetric case - hart 0 writes hart 1's reserved address;
        // hart 0's own (now absent) reservation must not spuriously fire. ----
        resv_valid = 2'b10; resv_addr[63:32] = 32'hABCD_0000; // hart 1 holds a reservation
        store_fire = 2'b01; store_addr[31:0] = 32'hABCD_0000; // hart 0 writes it
        #1;
        check("symmetric case: hart 0's write invalidates hart 1's reservation",
              {30'b0, resv_invalidate}, {30'b0, 2'b10});

        // ---- 6: both harts writing simultaneously, each to the OTHER's
        // reservation - both invalidate, neither self-triggers. ----
        resv_valid = 2'b11;
        resv_addr[31:0]  = 32'h1000_0000; // hart 0's own reservation
        resv_addr[63:32] = 32'h2000_0000; // hart 1's own reservation
        store_fire = 2'b11;
        store_addr[31:0]  = 32'h2000_0000; // hart 0 writes hart 1's address
        store_addr[63:32] = 32'h1000_0000; // hart 1 writes hart 0's address
        #1;
        check("simultaneous cross-writes invalidate both, symmetrically",
              {30'b0, resv_invalidate}, {30'b0, 2'b11});

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("RESERVATION-MONITOR-TEST: PASS");
        else             $display("RESERVATION-MONITOR-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the reservation monitor test never completed");
        $finish;
    end
endmodule
