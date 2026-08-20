// Hardware SDRAM probe: exercises rtl/soc/wb_sdram.v against the board's real
// memory chip, with no CPU, no bus, no boot ROM and no software anywhere.
//
// This exists for the same reason fpga/ulx3s_cmd0.v does. If the first thing
// you flash after wiring the SDRAM is the full SoC, then "it does not work"
// covers the pinout, the clock phase, the controller, the interconnect, the
// caches, the boot ROM and the firmware at once, and every one of those is a
// plausible suspect. This narrows it to one question: **does the controller
// talk to this chip?**
//
// It runs forever, so the LEDs are a live display rather than a single
// verdict. Each stage flag means "passed on the most recent attempt", so a
// working part shows **five steady LEDs plus the heartbeat**, and a marginal
// one shows the same display with a flicker in it - which is a distinction a
// single-shot verdict cannot make.
//
// ---- Reading the LEDs ----
//
// The first five are cumulative - each stage only runs if the one before it
// passed, so you read off how far it got:
//
//   led[0]  the controller finished its power-up sequence. Proves the state
//           machine is running and the clock is reaching it. This one comes
//           on ~100 us after reset and stays on even if everything else
//           fails.
//   led[1]  one word written and read back correctly.
//   led[2]  all 32 data bits proved individually (walking ones). A stuck or
//           swapped DQ line fails here and passes led[1] about half the time.
//   led[3]  one address per address bit, from 0 up to the top of a 32 MB
//           part, read back correctly. An address line stuck, swapped or
//           unconnected makes two of them collide and fails here.
//   led[4]  the same 16 addresses still correct after an idle period with no
//           accesses at all. **This is the one that proves refresh**, and it
//           is the only check here that cannot be faked by a controller that
//           merely echoes what it was given.
//   led[7]  heartbeat, ~1.5 Hz. If this is not blinking the design is not
//           running and nothing else on the display means anything.
//
// led[7] is the *only* one that should be blinking on a working board. An
// earlier version cleared every flag on each restart, which made led[4]
// strobe at 3 Hz on hardware that was entirely fine, because it could not
// re-light until the next 100 ms idle test had finished. That cost a bench
// session's worth of doubt - see S_DONE.
//
// ---- What each failure looks like ----
//
//   nothing lit, no heartbeat     bitstream not loaded, or clk/reset wrong
//   heartbeat only                the controller never came out of power-up.
//                                 Check sdram_clk actually reaches the pin.
//   led[0] only                   commands land, data does not come back.
//                                 **This is the clock-phase symptom** - see
//                                 the sdram_clk comment in ulx3s_top.v.
//   led[0..1], not led[2]         a DQ line is stuck or two are swapped
//   led[0..2], not led[3]         an address or bank line is wrong
//   led[0..3], not led[4]         refresh is not reaching the part
//   led[0..4] steady, led[7] only
//     blinking                    the memory works. Move on to the SoC.
//   any of led[1..4] flickering   it mostly works. That is a margin, not a
//                                 wiring fault, and the SoC check below is
//                                 what quantifies it.
module ulx3s_sdram #(
    parameter CLK_HZ = 25_000_000,
    // How long to sit idle before re-reading, in cycles. On a board this is
    // ~100 ms: long enough that a part which was never refreshed has
    // certainly lost its rows, since the whole array must be refreshed every
    // 64 ms. The testbench overrides it, because 2.5 M cycles of simulation
    // to prove a counter is not a good trade.
    parameter IDLE_CYCLES = 2_500_000
)(
    input  wire        clk_25mhz,
    input  wire [6:0]  btn,
    output wire [7:0]  led,
    output wire        wifi_gpio0,

    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_csn,
    output wire        sdram_wen,
    output wire        sdram_rasn,
    output wire        sdram_casn,
    output wire [12:0] sdram_a,
    output wire [1:0]  sdram_ba,
    output wire [1:0]  sdram_dqm,
    inout  wire [15:0] sdram_d
);
    // See ulx3s_top.v: the ESP32 shares the board's power control and an
    // undriven boot-mode pin lets it reset the board underneath a running
    // design.
    assign wifi_gpio0 = 1'b1;

    wire clk = clk_25mhz;

    // btn[1] ("FIRE1") is pulled down and reads 1 while pressed, so this is
    // an active-high reset that also lets you restart the probe by hand.
    reg [2:0] rst_sync = 3'b111;
    always @(posedge clk) rst_sync <= {rst_sync[1:0], btn[1]};
    wire rst = rst_sync[2];

    // ---- the controller under test, wired exactly as the SoC wires it ----
    wire [15:0] dq_o;
    wire        dq_oe;
    assign sdram_d   = dq_oe ? dq_o : 16'bz;

    // Same clock output as the SoC uses, from the same module on purpose: a
    // probe that clocked the part differently would pass and prove nothing
    // about the design it exists to de-risk.
    sdram_clk_out SDCLK (.clk(clk), .sdram_clk(sdram_clk));

    reg  [31:0] wb_adr;
    reg  [31:0] wb_dat_w;
    reg         wb_we;
    reg         wb_cyc;
    reg         wb_stb;
    wire [31:0] wb_dat_r;
    wire        wb_ack;
    wire        ready;

    wb_sdram #(.CLK_HZ(CLK_HZ)) DUT (
        .clk(clk), .rst(rst),
        .wb_cyc(wb_cyc), .wb_stb(wb_stb), .wb_we(wb_we),
        .wb_adr(wb_adr), .wb_dat_w(wb_dat_w), .wb_sel(4'b1111),
        .wb_dat_r(wb_dat_r), .wb_ack(wb_ack),
        .sdram_cke(sdram_cke), .sdram_cs_n(sdram_csn),
        .sdram_ras_n(sdram_rasn), .sdram_cas_n(sdram_casn),
        .sdram_we_n(sdram_wen),
        .sdram_a(sdram_a), .sdram_ba(sdram_ba), .sdram_dqm(sdram_dqm),
        .sdram_dq_o(dq_o), .sdram_dq_oe(dq_oe), .sdram_dq_i(sdram_d),
        .sdram_ready(ready)
    );

    // ---- test addresses: one per address bit ----
    //
    // A walking one over the *address*, not a block of nearby locations. The
    // first version of this used sixteen addresses 1 KB apart, which covers
    // all four banks and four rows and looks thorough - and it is not. Every
    // one of those addresses lives in the low 24 KB, so bits 15 and up never
    // change, and an unconnected high address line passes. That was found by
    // deliberately dropping the top row bit in rtl/soc/wb_sdram.v and watching
    // this probe report success, which is exactly the failure a bring-up
    // instrument must not have.
    //
    // So: index 0 is address 0, and index i covers address bit i+1, up to bit
    // 24 - the top of a 32 MB part. Every address line the controller drives
    // is now the only difference between at least one pair of entries, so a
    // line stuck, swapped or unconnected makes two of them collide and the
    // readback finds it.
    localparam SPREAD = 24;
    function [31:0] addr_of(input [4:0] i);
        addr_of = (i == 5'd0) ? 32'd0 : (32'd1 << (i + 5'd1));
    endfunction
    // Every bit of the index reaches the data, so a swapped address line
    // produces a value that belongs to a different index rather than one that
    // happens to look plausible.
    function [31:0] data_of(input [4:0] i);
        data_of = {~i, 3'b101, i, 3'b010, i, 3'b110, i, 1'b1};
    endfunction

    localparam [31:0] SINGLE_ADDR = 32'h0000_0000;
    localparam [31:0] SINGLE_DATA = 32'hDEAD_BEEF;
    localparam [31:0] WALK_ADDR   = 32'h0000_0100;

    // ---- pass flags, shown on the LEDs ----
    reg ok_ready, ok_single, ok_walk, ok_spread, ok_refresh;

    reg [7:0]  led_r;
    reg [23:0] hb;
    always @(posedge clk) hb <= hb + 1'b1;
    assign led = led_r;

    // ---- probe sequence ----
    localparam [3:0] S_WAIT   = 4'd0,  S_SINGLE_W = 4'd1,  S_SINGLE_R = 4'd2,
                     S_WALK_W = 4'd3,  S_WALK_R   = 4'd4,
                     S_SPR_W  = 4'd5,  S_SPR_R    = 4'd6,
                     S_IDLE   = 4'd7,  S_RECHK    = 4'd8,
                     S_DONE   = 4'd9,  S_ISSUE    = 4'd10;

    reg [3:0]  state, ret;
    reg [5:0]  idx;             // 0..32, indexes both the walk and the spread
    reg [31:0] idle_ctr;
    reg [31:0] expect_dat;
    reg        cmp_fail;

    // One transaction, issued from S_ISSUE and returning to `ret`. Folding it
    // into a single state rather than repeating the handshake at seven call
    // sites is what keeps this readable - and the handshake is the part that
    // has to be right, so it is worth having exactly one copy of it.
    task start_op(input [31:0] a, input [31:0] d, input we, input [3:0] next);
        begin
            wb_adr   <= a;
            wb_dat_w <= d;
            wb_we    <= we;
            wb_cyc   <= 1'b1;
            wb_stb   <= 1'b1;
            ret      <= next;
            state    <= S_ISSUE;
        end
    endtask

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state      <= S_WAIT;
            ret        <= S_WAIT;
            idx        <= 6'd0;
            idle_ctr   <= 32'd0;
            wb_cyc     <= 1'b0;
            wb_stb     <= 1'b0;
            wb_we      <= 1'b0;
            wb_adr     <= 32'b0;
            wb_dat_w   <= 32'b0;
            expect_dat <= 32'b0;
            cmp_fail   <= 1'b0;
            ok_ready   <= 1'b0;
            ok_single  <= 1'b0;
            ok_walk    <= 1'b0;
            ok_spread  <= 1'b0;
            ok_refresh <= 1'b0;
        end else begin
            case (state)
            S_WAIT: begin
                if (ready) begin
                    ok_ready <= 1'b1;
                    start_op(SINGLE_ADDR, SINGLE_DATA, 1'b1, S_SINGLE_W);
                end
            end

            // The transaction state: hold cyc/stb until ack, then drop them
            // and hand the result to whoever asked. Dropping them in the ack
            // cycle is what stops the controller seeing a second request.
            S_ISSUE: begin
                if (wb_ack) begin
                    wb_cyc <= 1'b0;
                    wb_stb <= 1'b0;
                    wb_we  <= 1'b0;
                    state  <= ret;
                end
            end

            S_SINGLE_W: start_op(SINGLE_ADDR, 32'b0, 1'b0, S_SINGLE_R);
            S_SINGLE_R: begin
                if (wb_dat_r == SINGLE_DATA) begin
                    ok_single <= 1'b1;
                    idx       <= 6'd0;
                    start_op(WALK_ADDR, 32'd1, 1'b1, S_WALK_W);
                end else begin
                    ok_single  <= 1'b0;
                    ok_walk    <= 1'b0;
                    ok_spread  <= 1'b0;
                    ok_refresh <= 1'b0;
                    state      <= S_DONE;
                end
            end

            // Walking ones: one bit at a time, written and read back before
            // the next. A DQ line stuck low fails on its own bit and on
            // nothing else, which is what makes the LED useful.
            S_WALK_W: start_op(WALK_ADDR, 32'b0, 1'b0, S_WALK_R);
            S_WALK_R: begin
                if (wb_dat_r != (32'd1 << idx[4:0])) begin
                    ok_walk    <= 1'b0;
                    ok_spread  <= 1'b0;
                    ok_refresh <= 1'b0;
                    state      <= S_DONE;
                end else if (idx == 6'd31) begin
                    ok_walk <= 1'b1;
                    idx     <= 6'd0;
                    start_op(addr_of(5'd0), data_of(5'd0), 1'b1, S_SPR_W);
                end else begin
                    idx <= idx + 1'b1;
                    start_op(WALK_ADDR, 32'd1 << (idx[4:0] + 1'b1), 1'b1, S_WALK_W);
                end
            end

            // Spread: write all sixteen first, then read all sixteen. Written
            // and checked one at a time would pass even if every address
            // aliased onto the same location.
            S_SPR_W: begin
                if (idx == SPREAD - 1) begin
                    idx <= 6'd0;
                    start_op(addr_of(5'd0), 32'b0, 1'b0, S_SPR_R);
                end else begin
                    idx <= idx + 1'b1;
                    start_op(addr_of(idx[4:0] + 1'b1),
                             data_of(idx[4:0] + 1'b1), 1'b1, S_SPR_W);
                end
            end
            S_SPR_R: begin
                if (wb_dat_r != data_of(idx[4:0])) begin
                    ok_spread  <= 1'b0;
                    ok_refresh <= 1'b0;
                    state      <= S_DONE;
                end else if (idx == SPREAD - 1) begin
                    ok_spread <= 1'b1;
                    idle_ctr  <= 32'd0;
                    state     <= S_IDLE;
                end else begin
                    idx <= idx + 1'b1;
                    start_op(addr_of(idx[4:0] + 1'b1), 32'b0, 1'b0, S_SPR_R);
                end
            end

            // Nothing on the bus at all. The controller should still be
            // issuing AUTO REFRESH throughout; if it is not, the sixteen
            // words below will have decayed.
            S_IDLE: begin
                if (idle_ctr >= IDLE_CYCLES) begin
                    idx <= 6'd0;
                    start_op(addr_of(5'd0), 32'b0, 1'b0, S_RECHK);
                end else begin
                    idle_ctr <= idle_ctr + 1'b1;
                end
            end
            S_RECHK: begin
                if (wb_dat_r != data_of(idx[4:0])) begin
                    ok_refresh <= 1'b0;
                    state      <= S_DONE;
                end else if (idx == SPREAD - 1) begin
                    ok_refresh <= 1'b1;
                    state      <= S_DONE;
                end else begin
                    idx <= idx + 1'b1;
                    start_op(addr_of(idx[4:0] + 1'b1), 32'b0, 1'b0, S_RECHK);
                end
            end

            // Hold for a moment, then start over. Restarting is what turns a
            // marginal setup into a visible flicker rather than a stable wrong
            // answer that looks like a definite verdict.
            //
            // **The flags are not cleared here**, and that is the whole point
            // of them. Each one means "passed on the most recent attempt": set
            // on success above, cleared by the failure path that skipped it.
            // Clearing them all on restart is what this used to do, and it
            // made a *passing* board look broken - led[1..3] came back within
            // microseconds and read as steady, but led[4] could not re-light
            // until the next 100 ms idle test finished, so it strobed at 3 Hz
            // on a machine where everything worked. The table at the top of
            // this file promised "all five lit" for a working part and that
            // state was unreachable.
            S_DONE: begin
                idle_ctr <= idle_ctr + 1'b1;
                if (idle_ctr[23]) begin
                    idle_ctr <= 32'd0;
                    state    <= S_WAIT;
                end
            end

            default: state <= S_WAIT;
            endcase
        end
    end

    always @(*) begin
        led_r    = 8'b0;
        led_r[0] = ok_ready;
        led_r[1] = ok_single;
        led_r[2] = ok_walk;
        led_r[3] = ok_spread;
        led_r[4] = ok_refresh;
        led_r[7] = hb[23];
    end
endmodule
