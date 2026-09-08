// Directed test for rtl/soc/cpu_wb.v's new DCACHE_ENABLE parameter (Phase
// 13, docs/roadmap.md's coherence gap) - proves the actual scenario the
// parameter exists to close, not just "the knob doesn't crash anything":
// a foreign write to the backing memory - standing in for a second hart's
// own store to the same physical address, bypassing this adapter's cache
// entirely, exactly the case docs/roadmap.md names as unsafe - is served
// stale with DCACHE_ENABLE=1 (the default, correct for today's genuinely
// single-master SoC) and correctly seen fresh with DCACHE_ENABLE=0.
//
// A real, word-addressable RAM slave on the data Wishbone port (1-cycle
// ack, matching wb_ram.v's own timing), writable both through the DUT's
// native side (a normal store) and directly (the "foreign write" a second
// hart's own bus master would produce) - proving this needs an actual
// backing store a write can reach two different ways, not just internal
// DUT state.
`timescale 1ns/1ps
module tb_cpu_wb_dcache_bypass;
    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    // ---- DUT signals, instantiated twice below (enabled, disabled) ----
    reg  [31:0] imem_addr = 32'h0000_1000; // fixed; this test never fetches
    reg  [31:0] dmem_addr;
    reg  [31:0] dmem_wdata;
    reg         dmem_we, dmem_re;
    reg  [1:0]  dmem_size = 2'b10; // word

    // ---- shared task-style stimulus, applied to whichever DUT is selected ----
    // Two full instantiations rather than one reconfigurable one: the point
    // is comparing DCACHE_ENABLE=1 against DCACHE_ENABLE=0 against the
    // *same* stimulus and the *same* foreign write, side by side.
    wire [31:0] dmem_rdata_en, dmem_rdata_dis;
    wire        dmem_rvalid_en, dmem_rvalid_dis;
    wire        dbus_wait_en, dbus_wait_dis;
    wire        dwb_cyc_en, dwb_stb_en, dwb_we_en;
    wire [31:0] dwb_adr_en, dwb_dat_w_en;
    wire [3:0]  dwb_sel_en;
    wire        dwb_cyc_dis, dwb_stb_dis, dwb_we_dis;
    wire [31:0] dwb_adr_dis, dwb_dat_w_dis;
    wire [3:0]  dwb_sel_dis;
    wire [31:0] dwb_dat_r_en, dwb_dat_r_dis;
    wire        dwb_ack_en, dwb_ack_dis;

    cpu_wb #(.DCACHE_ENABLE(1)) DUT_EN (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(), .ibus_wait(), .itlb_wait_stall(1'b0),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_we(dmem_we),
        .dmem_re(dmem_re), .dmem_is_amo(1'b0), .dmem_size(dmem_size),
        .dmem_rdata(dmem_rdata_en), .dmem_rvalid(dmem_rvalid_en), .dbus_wait(dbus_wait_en),
        .fence_i(1'b0),
        .iwb_cyc(), .iwb_stb(), .iwb_adr(), .iwb_dat_r(32'b0), .iwb_ack(1'b0),
        .dwb_cyc(dwb_cyc_en), .dwb_stb(dwb_stb_en), .dwb_we(dwb_we_en),
        .dwb_adr(dwb_adr_en), .dwb_dat_w(dwb_dat_w_en), .dwb_sel(dwb_sel_en),
        .dwb_dat_r(dwb_dat_r_en), .dwb_ack(dwb_ack_en)
    );

    cpu_wb #(.DCACHE_ENABLE(0)) DUT_DIS (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_rdata(), .ibus_wait(), .itlb_wait_stall(1'b0),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_we(dmem_we),
        .dmem_re(dmem_re), .dmem_is_amo(1'b0), .dmem_size(dmem_size),
        .dmem_rdata(dmem_rdata_dis), .dmem_rvalid(dmem_rvalid_dis), .dbus_wait(dbus_wait_dis),
        .fence_i(1'b0),
        .iwb_cyc(), .iwb_stb(), .iwb_adr(), .iwb_dat_r(32'b0), .iwb_ack(1'b0),
        .dwb_cyc(dwb_cyc_dis), .dwb_stb(dwb_stb_dis), .dwb_we(dwb_we_dis),
        .dwb_adr(dwb_adr_dis), .dwb_dat_w(dwb_dat_w_dis), .dwb_sel(dwb_sel_dis),
        .dwb_dat_r(dwb_dat_r_dis), .dwb_ack(dwb_ack_dis)
    );

    // One-word-deep backing memory per DUT, cacheable (RAM_BASE = 0x80xxxxxx
    // per cpu_wb.v's own dc_cacheable check), 1-wait-state ack matching
    // wb_ram.v. "Foreign write" pokes this array directly, standing in for a
    // second hart's own store reaching the same physical memory through a
    // different bus master entirely - never through this adapter, which is
    // exactly why its cache cannot know about it.
    reg [31:0] mem_en, mem_dis;
    reg        ack_r_en, ack_r_dis;
    always @(posedge clk or posedge rst) begin
        if (rst) ack_r_en <= 1'b0;
        else     ack_r_en <= dwb_cyc_en && !ack_r_en;
    end
    always @(posedge clk or posedge rst) begin
        if (rst) ack_r_dis <= 1'b0;
        else     ack_r_dis <= dwb_cyc_dis && !ack_r_dis;
    end
    always @(posedge clk) if (dwb_cyc_en && dwb_we_en && !ack_r_en)   mem_en  <= dwb_dat_w_en;
    always @(posedge clk) if (dwb_cyc_dis && dwb_we_dis && !ack_r_dis) mem_dis <= dwb_dat_w_dis;
    assign dwb_ack_en   = ack_r_en;
    assign dwb_dat_r_en = mem_en;
    assign dwb_ack_dis   = ack_r_dis;
    assign dwb_dat_r_dis = mem_dis;

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

    // Issues one store or load through the native port and waits for
    // dbus_wait to drop, matching cpu_core.v's own contract (address/data
    // held until the access completes).
    // The extra `@(posedge clk)` after `dbus_wait` clears matters and is not
    // just caution: this testbench's own slave-ack register and the DUT's
    // `dc_update` (which fills the cache line on a write's own ack) both
    // update via non-blocking assignment at the *same* edge, so `dc_update`
    // still sees the pre-edge (not-yet-acked) value of `dwb_ack` at the
    // exact cycle `dbus_wait` first reads low. The actual cache write lands
    // one edge later. Returning immediately when `dbus_wait` clears -
    // matching cpu_core.v's own contract, which only cares about that - races
    // ahead of this testbench's own follow-up checks of cache *content*,
    // which need the write to have actually landed. Found by hitting it: an
    // earlier version without this returned from a store claiming success
    // while the line it had just written still read back 0.
    task do_store(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); #1;
            dmem_addr = a; dmem_wdata = d; dmem_we = 1'b1; dmem_re = 1'b0;
            @(posedge clk);
            while (dbus_wait_en || dbus_wait_dis) @(posedge clk);
            @(posedge clk); #1;
            dmem_we = 1'b0;
        end
    endtask

    // No extra settle cycle here, unlike do_store above: a cache hit's own
    // `dmem_rdata` (`hit_deliver ? dc_line : ...`) is driven entirely by the
    // DUT's own already-updated internal registers with no cross-module NBA
    // dependency on this testbench's ack register, and `rdata_q` (the
    // fallback once `hit_deliver` has already passed) is only updated on a
    // genuine bus read, not a hit - so waiting an extra cycle after a hit
    // would read stale leftover data instead of the value just checked.
    task do_load(input [31:0] a);
        begin
            @(posedge clk); #1;
            dmem_addr = a; dmem_we = 1'b0; dmem_re = 1'b1;
            @(posedge clk);
            while (dbus_wait_en || dbus_wait_dis) @(posedge clk);
            #1;
            dmem_re = 1'b0;
        end
    endtask

    initial begin
        dmem_addr = 32'b0; dmem_wdata = 32'b0; dmem_we = 1'b0; dmem_re = 1'b0;
        @(posedge clk); @(posedge clk);
        rst = 1'b0;
        @(posedge clk); #1;

        // Prime both caches: a store, then a load, so RAM and each DUT's own
        // cache line both hold 0xAAAA_AAAA at this address.
        do_store(32'h8000_0000, 32'hAAAA_AAAA);
        do_load(32'h8000_0000);
        check("DUT_EN's own store landed in RAM", mem_en, 32'hAAAA_AAAA);
        check("DUT_DIS's own store landed in RAM", mem_dis, 32'hAAAA_AAAA);
        check("DUT_EN reads its own fresh store back", dmem_rdata_en, 32'hAAAA_AAAA);
        check("DUT_DIS reads its own fresh store back", dmem_rdata_dis, 32'hAAAA_AAAA);

        // Foreign write: poke the backing memory directly, never through
        // either DUT's own Wishbone port - exactly what a second hart's own
        // data master would do to the same physical address.
        mem_en  = 32'h5555_5555;
        mem_dis = 32'h5555_5555;

        // Read the same address again through each DUT.
        do_load(32'h8000_0000);
        check("DCACHE_ENABLE=1 serves the STALE cached value (the coherence gap this stage documents)",
              dmem_rdata_en, 32'hAAAA_AAAA);
        check("DCACHE_ENABLE=0 sees the foreign write correctly - no caching, no staleness",
              dmem_rdata_dis, 32'h5555_5555);

        $display("");
        $display("---------------------------------------------");
        if (errors == 0) $display("CPU-WB-DCACHE-BYPASS-TEST: PASS");
        else             $display("CPU-WB-DCACHE-BYPASS-TEST: FAIL (%0d)", errors);
        $display("---------------------------------------------");
        $finish;
    end

    initial begin
        #10_000;
        $display("TIMEOUT - the cpu_wb dcache bypass test never completed");
        $finish;
    end
endmodule
