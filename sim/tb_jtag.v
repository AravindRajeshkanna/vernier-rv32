// The JTAG debug path, driven the way a host drives it.
//
// This is a *protocol* testbench: it bit-bangs TCK/TMS/TDI exactly as an
// FT2232 would, and every value it checks is one a real debugger reads. It
// deliberately does not reach into the design - no hierarchical references,
// no peeking at `dr` - because the thing under test is the wire protocol, and
// a testbench that inspects internal state would pass on a TAP that shifts
// the right bits into the wrong register.
//
// The one exception is the memory contents it checks System Bus Access
// against, which have to come from somewhere.
//
// What each stage buys, in the order a host does them:
//
//   1. IDCODE after a test-logic reset. The only thing a host can do knowing
//      nothing at all, and the first thing every scan-chain probe tries.
//   2. BYPASS. One bit, and it proves the IR actually selects registers
//      rather than always presenting the same one - a TAP that ignores its
//      instruction register passes the IDCODE test.
//   3. dtmcs. Says how wide the DMI address is, which a host needs before it
//      can shift a DMI transaction at all.
//   4. DMI register access - dmstatus, sbcs - which proves the clock crossing
//      carries a request out and an answer back.
//   5. System Bus Access reads and writes against block RAM, which is the
//      point of the whole path.
//   6. Autoincrement, because a host dumping a region relies on it and it is
//      the one piece of sequencing this module does on its own.
//   7. A distant address reads its own word - everything above could pass
//      with an SBA that ignored sbaddress and always hit one location.
//   8. Hart control: haltreq/resumereq over the real dmcontrol/dmstatus DMI
//      registers - not register access yet (that's stage 9, below), just
//      proving the DMI protocol layer genuinely starts and stops the same
//      illegal-instruction-trap-forever hart every SBA check above raced,
//      and that SBA still works correctly afterward.
//   9. Abstract Command register access - abstractcs/command/data0, over
//      the real DMI protocol this time rather than sim/tb_cpu_halt.v's
//      direct drive against rtl/cpu_core.v. Needs a real program to halt
//      into: jtagram.hex plants a 2-instruction increment loop at
//      RESET_PC for exactly this (everywhere else keeps the pattern
//      stages 5-7 depend on), because the illegal-instruction-trap-forever
//      pattern every earlier stage uses never writes a GPR, so a
//      before/after register check would pass even if Abstract Command
//      were a complete no-op.
`timescale 1ns / 1ps

module tb_jtag;
    localparam CLKS_PER_BIT = 4;

    // TCK is deliberately *not* a nice ratio of the system clock. 7:2 against
    // a 100 MHz sim clock is about 28 MHz, which is faster than any real
    // debugger and lands the two clocks' edges all over each other - which is
    // the point. A crossing that only works when the edges line up is a
    // crossing that works in simulation and fails on a bench.
    localparam real SYS_HALF = 5.0;
    localparam real TCK_HALF = 17.0;

    reg clk = 0, rst = 1;
    always #(SYS_HALF) clk = ~clk;

    reg tck = 0, tms = 1, tdi = 0;
    wire tdo, tdo_oe;

    wire uart_tx;
    wire [15:0] gpio_out, gpio_dir;
    wire        spi_sck, spi_mosi, spi_cs_n;

    // Block RAM preloaded with a known pattern - word n holds 0xDEAD_00nn -
    // so an SBA read has something to be right about, and every address holds
    // something different. tb_ramboot.v's program image would do for "did a
    // read happen", and nothing at all for "did it read the address I asked
    // for".
    //
    // RESET_PC points into that pattern, so the CPU fetches 0xDEAD_xxxx,
    // takes an illegal-instruction trap, vectors to a zeroed ROM and traps
    // again, forever. That is deliberate: it keeps the fetch master hammering
    // the bus for the whole test, so every SBA access below is arbitrating
    // against a busy machine rather than an idle one. Nothing in the pattern
    // decodes as a store, so the CPU cannot disturb what is being checked.
    soc_top #(
        .RAM_BYTES(65536),
        .ROM_INIT_FILE(""),
        .RAM_INIT_FILE("jtagram.hex"),
        .UART_CLKS_PER_BIT(CLKS_PER_BIT),
        .RESET_PC(32'h8000_1000)
    ) DUT (
        .clk(clk), .rst(rst),
        .jtag_tck(tck), .jtag_tms(tms), .jtag_tdi(tdi),
        .jtag_tdo(tdo), .jtag_tdo_oe(tdo_oe),
        .uart_tx(uart_tx), .uart_rx(1'b1),
        .gpio_in(16'b0), .gpio_out(gpio_out), .gpio_dir(gpio_dir),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi),
        .spi_miso(1'b1), .spi_cs_n(spi_cs_n),
        .vid_r(), .vid_g(), .vid_b(),
        .vid_de(), .vid_hsync(), .vid_vsync(),
        .sdram_cke(), .sdram_cs_n(), .sdram_ras_n(), .sdram_cas_n(),
        .sdram_we_n(), .sdram_a(), .sdram_ba(), .sdram_dqm(),
        .sdram_dq_o(), .sdram_dq_oe(), .sdram_dq_i(16'b0)
    );

    integer failures = 0;

    task check(input [511:0] name, input ok);
        begin
            $write("  %0s", name);
            $write("%0s\n", ok ? " ok" : " FAILED");
            if (!ok) failures = failures + 1;
        end
    endtask

    task check_hex(input [511:0] name, input [63:0] got, input [63:0] want);
        begin
            if (got !== want)
                $display("    got %h want %h", got, want);
            check(name, got === want);
        end
    endtask

    // ---- the four pins, driven as a host drives them ----
    //
    // TMS is set up while TCK is low and sampled by the TAP on the rising
    // edge; TDO is driven by the TAP on the falling edge and sampled here
    // before the next rise. That is the standard's timing and it is the
    // reason this task looks the way it does.
    // TDO is sampled *before* the rising edge, which is what a host does and
    // is not interchangeable with sampling after the falling one. The TAP
    // drives TDO on the falling edge; the host sees it stable across the
    // whole low phase and latches it on the rise that also shifts the next
    // bit. Sampling after the fall instead reads the bit one position early
    // and every value comes back shifted - which is exactly how this
    // testbench first failed, with IDCODE reading 0x2A4ADFFF for
    // 0x15256FFF and an X in bit 0.
    task tick(input v_tms, input v_tdi, output v_tdo);
        begin
            tms = v_tms; tdi = v_tdi;
            #(TCK_HALF);
            v_tdo = tdo;
            tck = 1;
            #(TCK_HALF) tck = 0;
        end
    endtask

    reg bit_out;

    task tms_seq(input [7:0] n, input [7:0] bits);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) tick(bits[i], 1'b0, bit_out);
        end
    endtask

    // Five ones reaches Test-Logic-Reset from any state; one zero lands in
    // Run-Test/Idle.
    task tap_reset;
        begin
            tms_seq(8'd6, 8'b0011111);
        end
    endtask

    // Shift `len` bits of `din` through the currently selected DR and return
    // what came back. Enters from Run-Test/Idle and leaves in Run-Test/Idle.
    task shift_dr(input [7:0] len, input [63:0] din, output [63:0] dout);
        integer i;
        reg b;
        begin
            dout = 64'b0;
            tick(1'b1, 1'b0, b);            // -> Select-DR
            tick(1'b0, 1'b0, b);            // -> Capture-DR
            tick(1'b0, 1'b0, b);            // -> Shift-DR
            // The register does not shift on the edge that *enters* Shift-DR,
            // only on the ones taken while already in it - so the first bit
            // out is sampled on the first edge of this loop, not on the one
            // above. That distinction is the off-by-one.
            for (i = 0; i < len; i = i + 1) begin
                // TMS rises with the last bit, moving Shift-DR -> Exit1-DR on
                // the same edge that shifts it in. The shift still happens:
                // the TAP looks at the state it is in, not the one it is
                // going to.
                tick((i == len - 1), din[i], b);
                dout[i] = b;
            end
            tick(1'b1, 1'b0, b);            // -> Update-DR
            tick(1'b0, 1'b0, b);            // -> Run-Test/Idle
        end
    endtask

    task shift_ir(input [4:0] ins);
        integer i;
        reg b;
        begin
            tick(1'b1, 1'b0, b);            // -> Select-DR
            tick(1'b1, 1'b0, b);            // -> Select-IR
            tick(1'b0, 1'b0, b);            // -> Capture-IR
            tick(1'b0, 1'b0, b);            // -> Shift-IR
            for (i = 0; i < 5; i = i + 1)
                tick((i == 4), ins[i], b);
            tick(1'b1, 1'b0, b);            // -> Update-IR
            tick(1'b0, 1'b0, b);            // -> Run-Test/Idle
        end
    endtask

    // Spend a few cycles in Run-Test/Idle, which is what dtmcs.idle asks a
    // host to do so the system side can finish before the next transaction.
    task idle_cycles(input integer n);
        integer i;
        reg b;
        begin
            for (i = 0; i < n; i = i + 1) tick(1'b0, 1'b0, b);
        end
    endtask

    localparam [4:0] IR_BYPASS = 5'h1F, IR_IDCODE = 5'h01,
                     IR_DTMCS  = 5'h10, IR_DMI    = 5'h11;

    // ---- DMI ----
    reg [63:0] dr_out;

    task dmi_xfer(input [6:0] a, input [31:0] d, input [1:0] op,
                  output [31:0] rdata, output [1:0] resp);
        reg [63:0] din;
        begin
            din = {23'b0, a, d, op};
            shift_dr(8'd41, din, dr_out);
            resp  = dr_out[1:0];
            rdata = dr_out[33:2];
            idle_cycles(6);
        end
    endtask

    reg [31:0] rd;
    reg [1:0]  rsp;

    // A DMI read is two transactions: one that asks, one that collects. This
    // is not a quirk of this implementation - it is how the DMI is defined,
    // and a host pipelines it by overlapping the collect of one read with the
    // request of the next.
    task dmi_read(input [6:0] a, output [31:0] data);
        begin
            dmi_xfer(a, 32'b0, 2'd1, rd, rsp);
            dmi_xfer(7'h00, 32'b0, 2'd0, rd, rsp);
            data = rd;
        end
    endtask

    task dmi_write(input [6:0] a, input [31:0] d);
        begin
            dmi_xfer(a, d, 2'd2, rd, rsp);
            dmi_xfer(7'h00, 32'b0, 2'd0, rd, rsp);
        end
    endtask

    localparam [6:0] A_DMCONTROL = 7'h10, A_DMSTATUS = 7'h11,
                     A_ABSTRACTCS = 7'h16, A_COMMAND = 7'h17, A_DATA0 = 7'h04,
                     A_SBCS = 7'h38, A_SBADDRESS0 = 7'h39, A_SBDATA0 = 7'h3C;

    // Deliberately not RAM_BASE itself: the boot ROM's verdict word lives at
    // the bottom of block RAM and a test that wrote there would be checking
    // its own footprint.
    localparam [31:0] TEST_ADDR = 32'h8000_2000;

    // ---- Abstract Command (stage 9) ----
    //
    // Access Register command encoding, RISC-V Debug Spec 0.13 SS3.7.1.1:
    // cmdtype[31:24]=0, aarsize[22:20], aarpostincrement[19], postexec[18],
    // transfer[17], write[16], regno[15:0]. rtl/debug/dm.v's own header
    // comment documents the same layout; independently re-derived here
    // rather than shared, since this testbench deliberately never reaches
    // into the design under test (see this file's own header).
    function [31:0] cmd_access_reg;
        input        do_write;
        input [2:0]  aarsize;
        input [15:0] regno;
        begin
            cmd_access_reg = {8'd0, 1'b0, aarsize, 1'b0, 1'b0, 1'b1, do_write, regno};
        end
    endfunction

    localparam [15:0] REGNO_X5   = 16'h1005,   // 0x1000 + architectural register number
                      REGNO_DCSR = 16'h07B0,
                      REGNO_DPC  = 16'h07B1,
                      REGNO_BAD  = 16'h2000;   // not a GPR, dcsr, or dpc

    // Bounded the same way wait_halt/wait_resume below are: abstractcs.busy
    // is a single-cycle window by rtl/debug/dm.v's own design (Abstract
    // Command never touches the Wishbone bus), so this never loops more
    // than once or twice in practice - the bound exists so a genuine hang
    // here is a FAILED test, not a wedged simulation.
    task ac_wait_done(output [2:0] cmderr);
        integer n;
        reg [31:0] cs;
        reg        busy;
        begin
            busy = 1'b1;
            for (n = 0; n < 50 && busy; n = n + 1) begin
                dmi_read(A_ABSTRACTCS, cs);
                busy = cs[12];
            end
            check("abstractcs.busy clears within a bounded number of polls", !busy);
            cmderr = cs[10:8];
        end
    endtask

    // W1C, per spec - any nonzero write to the field clears it. A stuck
    // cmderr blocks every subsequent command (rtl/debug/dm.v's own AC_IDLE
    // handling), so each negative-path check below clears it before going
    // on to the next.
    task ac_clear_cmderr;
        begin
            dmi_write(A_ABSTRACTCS, 32'h0000_0700);
        end
    endtask

    task ac_read_reg(input [15:0] regno, output [31:0] data, output [2:0] cmderr);
        begin
            dmi_write(A_COMMAND, cmd_access_reg(1'b0, 3'd2, regno));
            ac_wait_done(cmderr);
            dmi_read(A_DATA0, data);
        end
    endtask

    task ac_write_reg(input [15:0] regno, input [31:0] data, output [2:0] cmderr);
        begin
            dmi_write(A_DATA0, data);
            dmi_write(A_COMMAND, cmd_access_reg(1'b1, 3'd2, regno));
            ac_wait_done(cmderr);
        end
    endtask

    localparam [2:0] CMDERR_NONE = 3'd0, CMDERR_NOTSUP = 3'd2, CMDERR_HALTRESUME = 3'd4;

    reg [31:0] v;
    integer    i;
    reg [2:0]  cerr;
    reg [31:0] sentinel, x5_before;

    initial begin
        $display("\n=== JTAG debug path ===");

        repeat (8) @(posedge clk);
        rst = 0;
        repeat (8) @(posedge clk);

        // ---- 1. IDCODE ----
        tap_reset;
        shift_dr(8'd32, 64'b0, dr_out);
        check_hex("IDCODE after test-logic reset", dr_out[31:0], 32'h1525_6FFF);
        check("IDCODE bit 0 is 1", dr_out[0] === 1'b1);

        // ---- 2. BYPASS ----
        //
        // One flip-flop. Shifting 8 bits in gives them back delayed by one,
        // which is the whole observable behaviour of BYPASS and the cheapest
        // proof that the IR selects anything at all.
        shift_ir(IR_BYPASS);
        shift_dr(8'd8, 64'h5A, dr_out);
        check_hex("BYPASS delays by exactly one bit",
                  dr_out[7:0], 8'hB4);   // 0x5A << 1, truncated to 8 bits

        // ---- 3. dtmcs ----
        shift_ir(IR_DTMCS);
        shift_dr(8'd32, 64'b0, dr_out);
        check_hex("dtmcs.version = 1 (spec 0.13)", dr_out[3:0],  4'd1);
        check_hex("dtmcs.abits   = 7",             dr_out[9:4],  6'd7);
        check_hex("dtmcs.idle    = 5",             dr_out[14:12],3'd5);

        // ---- 4. the Debug Module, through the clock crossing ----
        shift_ir(IR_DMI);

        dmi_read(A_DMSTATUS, v);
        check_hex("dmstatus.version = 2 (spec 0.13)", v[3:0], 4'd2);
        check("dmstatus.authenticated",              v[6] === 1'b1);
        check("dmstatus says the hart is running",   v[11:10] === 2'b11);
        check("dmstatus says nothing is halted",     v[9:8]   === 2'b00);

        // sbcs while the module is still in reset. Its capability fields are
        // hardwired and read back regardless - sbversion, sbasize and which
        // access sizes exist are properties of the silicon, not state - so
        // "reads as zero" would be the wrong assertion here, and was: this
        // check started life expecting 0 and got 0x20040404, which is the
        // correct reset value spelled out.
        dmi_read(A_SBCS, v);
        check("sbcs reports its capabilities even in reset",
              (v[31:29] === 3'd1) && (v[2] === 1'b1));

        // What dmactive actually gates is the bus. A Debug Module nobody has
        // enabled must not be able to touch memory, and that is worth
        // checking rather than assuming, because it is the difference between
        // a debug port and an unguarded second master.
        dmi_write(A_SBADDRESS0, TEST_ADDR + 32'd16);
        dmi_write(A_SBDATA0,    32'hBADD_BADD);     // would be a bus write

        dmi_write(A_DMCONTROL, 32'h0000_0001);      // dmactive = 1

        dmi_write(A_SBCS, 32'h0014_0000);           // sbaccess=32 + readonaddr
        dmi_write(A_SBADDRESS0, TEST_ADDR + 32'd16);
        dmi_read(A_SBDATA0, v);
        check_hex("a disabled Debug Module cannot write memory",
                  v, 32'hDEAD_0804);
        dmi_read(A_DMCONTROL, v);
        check("dmcontrol.dmactive reads back", v[0] === 1'b1);

        dmi_read(A_SBCS, v);
        check_hex("sbcs.sbversion = 1", v[31:29], 3'd1);
        check("sbcs.sbaccess32 supported", v[2] === 1'b1);
        check("sbcs.sbaccess8 not supported", v[0] === 1'b0);
        check_hex("sbcs.sbasize = 32", v[11:5], 7'd32);
        check_hex("sbcs.sberror clear", v[14:12], 3'd0);

        // ---- 5. System Bus Access ----
        //
        // The preloaded pattern is checked first, because a write that
        // appears to work into a RAM that reads back whatever was written is
        // not evidence of an address reaching the bus.
        dmi_write(A_SBCS, 32'h0004_0000);           // sbaccess=32, no auto, no readonaddr
        dmi_write(A_SBADDRESS0, TEST_ADDR);
        dmi_write(A_SBCS, 32'h0014_0000);           // + sbreadonaddr
        dmi_write(A_SBADDRESS0, TEST_ADDR);         // triggers the read
        dmi_read(A_SBDATA0, v);
        check_hex("SBA reads the preloaded word", v, 32'hDEAD_0800);

        dmi_write(A_SBADDRESS0, TEST_ADDR + 32'd4);
        dmi_read(A_SBDATA0, v);
        check_hex("SBA reads the next word too", v, 32'hDEAD_0801);

        // A write, then a read back through the same path.
        dmi_write(A_SBCS, 32'h0004_0000);           // sbreadonaddr off while writing
        dmi_write(A_SBADDRESS0, TEST_ADDR);
        dmi_write(A_SBDATA0, 32'hC0FF_EE00);
        dmi_write(A_SBCS, 32'h0014_0000);
        dmi_write(A_SBADDRESS0, TEST_ADDR);
        dmi_read(A_SBDATA0, v);
        check_hex("SBA writes and reads back", v, 32'hC0FF_EE00);

        // The word above it must be untouched - a write that lands on two
        // addresses passes every single-word test.
        dmi_write(A_SBADDRESS0, TEST_ADDR + 32'd4);
        dmi_read(A_SBDATA0, v);
        check_hex("the next word is undisturbed", v, 32'hDEAD_0801);

        // ---- 6. autoincrement ----
        //
        // What a host uses to dump a region: set the address once, then read
        // sbdata0 repeatedly. sbreadondata makes each read start the next.
        dmi_write(A_SBCS, 32'h0005_0000);           // sbaccess=32, autoincrement
        dmi_write(A_SBADDRESS0, TEST_ADDR + 32'd8);
        dmi_write(A_SBCS, 32'h0015_8000);           // + readonaddr + readondata
        dmi_write(A_SBADDRESS0, TEST_ADDR + 32'd8); // primes the first read

        failures = failures;
        begin : sweep
            integer bad;
            bad = 0;
            for (i = 0; i < 4; i = i + 1) begin
                dmi_read(A_SBDATA0, v);
                if (v !== (32'hDEAD_0802 + i)) begin
                    $display("    word %0d: got %h want %h",
                             i, v, 32'hDEAD_0802 + i);
                    bad = bad + 1;
                end
            end
            check("autoincrement walks four words", bad == 0);
        end

        // ---- 7. the address really reaches the bus ----
        //
        // Everything above could pass with an SBA that ignored sbaddress and
        // always hit one location. This reads two addresses far apart and
        // requires different answers.
        dmi_write(A_SBCS, 32'h0014_0000);
        dmi_write(A_SBADDRESS0, 32'h8000_3000);
        dmi_read(A_SBDATA0, v);
        check_hex("a distant address reads its own word", v, 32'hDEAD_0C00);

        // ---- 8. hart control: halt/resume, over the real DMI protocol ----
        //
        // Register access (sim/tb_cpu_halt.v's job, driven directly against
        // rtl/cpu_core.v) isn't implemented in dm.v yet, so this only proves
        // the dmcontrol/dmstatus half. `allhalted`/`allrunning` are this
        // Debug Module's only externally-visible signal for "is anything
        // actually still executing," so that is what is polled, against the
        // exact same illegal-instruction-trap-forever CPU every SBA check
        // above has been racing.
        //
        // Split by core, because the correct answer genuinely differs:
        // `CORE=inorder` really halts and resumes; `CORE=ooo` has no
        // hart-control ports at all (rtl/soc/soc_top.v ties its `halted`
        // input to 0 - docs/roadmap.md Phase 6) and dmstatus must keep
        // reporting the hart as running, honestly, rather than accept
        // haltreq and silently do nothing - this branch is what proves that
        // honesty rather than assuming it.
`ifdef CORE_OOO
        dmi_read(A_DMSTATUS, v);
        check("dmstatus says running before any haltreq (CORE=ooo)",
              v[11:10] === 2'b11 && v[9:8] === 2'b00);

        dmi_write(A_DMCONTROL, 32'h8000_0001);  // haltreq=1, dmactive=1
        idle_cycles(30);
        dmi_read(A_DMSTATUS, v);
        check("CORE=ooo: haltreq is accepted but ignored - still running",
              v[11:10] === 2'b11 && v[9:8] === 2'b00);

        dmi_write(A_DMCONTROL, 32'h0000_0001);  // haltreq=0, dmactive=1
`else
        dmi_read(A_DMSTATUS, v);
        check("dmstatus says running before any haltreq",
              v[11:10] === 2'b11 && v[9:8] === 2'b00);

        dmi_write(A_DMCONTROL, 32'h8000_0001);  // haltreq=1, dmactive=1
        begin : wait_halt
            integer n;
            reg     halted;
            halted = 1'b0;
            for (n = 0; n < 50 && !halted; n = n + 1) begin
                dmi_read(A_DMSTATUS, v);
                halted = (v[9:8] === 2'b11);
            end
            check("dmstatus reports halted within a bounded number of polls", halted);
        end
        dmi_read(A_DMSTATUS, v);
        check("dmstatus says nothing is running while halted", v[11:10] === 2'b00);

        // haltreq is sticky (rtl/debug/dm.v's own dmcontrol handling) - it
        // has to be cleared here, in the same write as resumereq, or the
        // hart re-halts on its very next cycle. sim/tb_cpu_halt.v's own
        // dbg_resume task comment has the full reasoning; same rule, same
        // protocol, from the DMI side this time.
        dmi_write(A_DMCONTROL, 32'h4000_0001);  // resumereq=1, haltreq=0, dmactive=1
        begin : wait_resume
            integer n;
            reg     running;
            running = 1'b0;
            for (n = 0; n < 50 && !running; n = n + 1) begin
                dmi_read(A_DMSTATUS, v);
                running = (v[11:10] === 2'b11);
            end
            check("dmstatus reports running again within a bounded number of polls", running);
        end
        dmi_read(A_DMSTATUS, v);
        check("dmstatus says nothing is halted after resume", v[9:8] === 2'b00);
`endif

        // SBA still has to work after a halt/resume cycle - proves the two
        // paths (System Bus Access, hart control) genuinely don't interfere
        // with each other, not just that each works in isolation. TEST_ADDR
        // itself now holds section 5's write (0xC0FF_EE00), not the
        // preloaded pattern - re-reading the word above it instead, which
        // section 5 already established is undisturbed.
        dmi_write(A_SBCS, 32'h0014_0000);
        dmi_write(A_SBADDRESS0, TEST_ADDR + 32'd4);
        dmi_read(A_SBDATA0, v);
        check_hex("SBA reads correctly after a halt/resume cycle", v, 32'hDEAD_0801);

        // ---- 9. Abstract Command register access ----
        //
        // The hart is running again after stage 8's resume - which is
        // exactly the state a register access has to be refused from.
`ifdef CORE_OOO
        // CORE=ooo has no hart-control ports at all, so `halted` is tied to
        // 0 permanently (rtl/soc/soc_top.v) - dm.v refuses every command
        // with cmderr=haltresume, honestly, rather than fabricating a
        // register value for a hart it was never wired to touch.
        ac_read_reg(REGNO_X5, v, cerr);
        check("CORE=ooo: Abstract Command refused - cmderr=haltresume",
              cerr === CMDERR_HALTRESUME);
        ac_clear_cmderr;
`else
        ac_read_reg(REGNO_X5, v, cerr);
        check("register access refused while running - cmderr=haltresume",
              cerr === CMDERR_HALTRESUME);
        ac_clear_cmderr;

        // ---- halt again, the same protocol sequence stage 8 already proved works ----
        dmi_write(A_DMCONTROL, 32'h8000_0001);  // haltreq=1, dmactive=1
        begin : ac_wait_halt
            integer n;
            reg     halted;
            halted = 1'b0;
            for (n = 0; n < 50 && !halted; n = n + 1) begin
                dmi_read(A_DMSTATUS, v);
                halted = (v[9:8] === 2'b11);
            end
            check("halted again for register-access testing", halted);
        end

        // GPR read is stable while genuinely halted - if Abstract Command
        // were a no-op this would still pass on the trap-forever pattern
        // every earlier stage uses, which is exactly why jtagram.hex plants
        // a real increment loop at RESET_PC instead (see this file's header).
        ac_read_reg(REGNO_X5, x5_before, cerr);
        check("x5 read while halted: cmderr=none", cerr === CMDERR_NONE);
        repeat (20) @(posedge clk);
        ac_read_reg(REGNO_X5, v, cerr);
        check_hex("x5 unchanged across idle cycles while halted", v, x5_before);

        // dcsr/dpc - same fields sim/tb_cpu_halt.v checks directly against
        // rtl/cpu_core.v, now read over the real DMI Abstract Command path.
        ac_read_reg(REGNO_DCSR, v, cerr);
        check("dcsr.cause == 3 (haltreq)", v[8:6] == 3'd3);
        check("dcsr.prv == PRIV_M (2'b11)", v[1:0] == 2'b11);

        // Unlike sim/tb_cpu_halt.v (RESET_PC=0, so "< 8" is the whole
        // check), this harness's RESET_PC is 0x8000_1000 - the loop's two
        // instructions live at that address and the one 4 bytes past it.
        ac_read_reg(REGNO_DPC, v, cerr);
        check("dpc points inside the 2-instruction loop (RESET_PC or +4)",
              (v == 32'h8000_1000) || (v == 32'h8000_1004));

        // ---- negative paths: unsupported aarsize, unrecognized regno ----
        dmi_write(A_COMMAND, cmd_access_reg(1'b0, 3'd1, REGNO_X5));  // aarsize=1 (16-bit)
        ac_wait_done(cerr);
        check("16-bit access rejected - cmderr=not supported", cerr === CMDERR_NOTSUP);
        ac_clear_cmderr;

        ac_read_reg(REGNO_BAD, v, cerr);
        check("unrecognized regno rejected - cmderr=not supported", cerr === CMDERR_NOTSUP);
        ac_clear_cmderr;

        // ---- write x5, read it back, still halted ----
        sentinel = 32'hCAFE_F00D;
        ac_write_reg(REGNO_X5, sentinel, cerr);
        check("x5 write while halted: cmderr=none", cerr === CMDERR_NONE);
        ac_read_reg(REGNO_X5, v, cerr);
        check_hex("x5 reads back the debug write", v, sentinel);

        // ---- resume: the write must be what the hart picks up and moves past ----
        dmi_write(A_DMCONTROL, 32'h4000_0001);  // resumereq=1, haltreq=0, dmactive=1
        begin : ac_wait_resume
            integer n;
            reg     running;
            running = 1'b0;
            for (n = 0; n < 50 && !running; n = n + 1) begin
                dmi_read(A_DMSTATUS, v);
                running = (v[11:10] === 2'b11);
            end
            check("running again after resume", running);
        end

        repeat (30) @(posedge clk);

        dmi_write(A_DMCONTROL, 32'h8000_0001);  // haltreq=1, dmactive=1
        begin : ac_wait_rehalt
            integer n;
            reg     halted;
            halted = 1'b0;
            for (n = 0; n < 50 && !halted; n = n + 1) begin
                dmi_read(A_DMSTATUS, v);
                halted = (v[9:8] === 2'b11);
            end
            check("halted a third time to confirm execution resumed", halted);
        end
        ac_read_reg(REGNO_X5, v, cerr);
        check("x5 advanced past the debug-written sentinel after resume",
              v > sentinel);

        // Cleanup, not a check - leaves the hart running rather than ending
        // the test with it wedged halted, the same way stage 8 and
        // sim/tb_cpu_halt.v's own final dbg_resume do.
        dmi_write(A_DMCONTROL, 32'h4000_0001);
`endif

        $display("");
        if (failures == 0) $display("JTAG TEST PASSED");
        else               $display("JTAG TEST FAILED (%0d)", failures);
        $display("");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("\nJTAG TEST FAILED - timeout");
        $finish;
    end
endmodule
