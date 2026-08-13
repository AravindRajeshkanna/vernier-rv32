// Hardware CMD0 probe: sends the SD card's reset command and shows what came
// back, with no CPU, no bus, no boot ROM and no software anywhere.
//
// fpga/ulx3s_diag.v answers "is a card there and is the clock reaching it".
// This answers the question that actually matters: **does the card reply?**
// It does not depend on the card-detect switch, which is not populated on
// every ULX3S and so cannot be trusted to mean anything.
//
// The sequence is exactly what software/soc/bootrom.c does, reduced to a
// state machine:
//
//   1. CS high, 16 bytes of 0xFF   - 128 wake-up clocks (spec minimum is 74)
//   2. CS low, send CMD0           - 40 00 00 00 00 95, with its real CRC7
//   3. CS low, clock in up to 16 bytes, looking for one with bit 7 clear
//   4. show the result, wait, repeat
//
// SCK is ~350 kHz throughout, inside the SD spec's 100-400 kHz window.
//
// ---- Reading the LEDs ----
// led[7:0] shows the **response byte**, and all eight blank for a moment
// between attempts so you can see it retrying rather than wondering whether
// it has hung.
//
//   all eight lit  = 0xFF = no response at all. The card never drove MISO.
//                    Either nothing is in the slot, or the card does not
//                    implement SPI mode (permitted above 32 GB), or MISO is
//                    not connected.
//
//   only led[0]    = 0x01 = **the card answered and is idle. This is what
//                    success looks like.** Wiring and card are both fine, and
//                    any remaining problem is above this level.
//
//   anything else  = the card is talking but unhappy; the bits are R1 error
//                    flags (bit2 illegal command, bit3 CRC error, ...).
//
// Because it retries continuously, a card can be inserted while it runs and
// the display will change within a second. That is the intended way to use
// it: watch the LEDs and push the card in.
module ulx3s_cmd0 (
    input  wire        clk_25mhz,
    input  wire [6:0]  btn,
    output wire [7:0]  led,
    output wire        wifi_gpio0,

    output wire        sd_clk,
    output wire        sd_cmd,
    inout  wire [3:0]  sd_d,
    input  wire        sd_cdn
);
    assign wifi_gpio0 = 1'b1;

    /* verilator lint_off PROCASSINIT */

    // ---- SPI bit clock: 25 MHz / (2*36) = 347 kHz ----
    localparam HALF = 6'd35;
    reg [5:0] halfcnt = 6'd0;
    reg       tick    = 1'b0;
    always @(posedge clk_25mhz) begin
        if (halfcnt == HALF) begin halfcnt <= 6'd0;          tick <= 1'b1; end
        else                 begin halfcnt <= halfcnt + 6'd1; tick <= 1'b0; end
    end

    // ---- MISO synchronizer ----
    // Same reason as rtl/soc/wb_spi.v: this is an asynchronous pin, and the
    // two flops here are why the sampled value is trustworthy. The half
    // period is 36 clocks, so two cycles of latency is nothing.
    wire miso_pin = sd_d[0];
    reg  m1 = 1'b1, m2 = 1'b1;
    always @(posedge clk_25mhz) begin m1 <= miso_pin; m2 <= m1; end

    // ---- byte-level SPI engine, mode 0 ----
    // MOSI advances on the falling edge, MISO is sampled on the rising edge.
    reg        sck       = 1'b0;
    reg  [7:0] shift_out = 8'hFF;
    reg  [7:0] shift_in  = 8'h00;
    reg  [3:0] bitcnt    = 4'd0;
    reg        busy      = 1'b0;
    reg        start     = 1'b0;
    reg  [7:0] tx_byte   = 8'hFF;
    reg        cs_n      = 1'b1;

    always @(posedge clk_25mhz) begin
        if (start && !busy) begin
            shift_out <= tx_byte;
            bitcnt    <= 4'd0;
            sck       <= 1'b0;
            busy      <= 1'b1;
        end else if (busy && tick) begin
            if (!sck) begin
                sck      <= 1'b1;                       // rising: sample
                shift_in <= {shift_in[6:0], m2};
            end else begin
                sck       <= 1'b0;                      // falling: advance
                shift_out <= {shift_out[6:0], 1'b1};
                bitcnt    <= bitcnt + 4'd1;
                if (bitcnt == 4'd7) busy <= 1'b0;
            end
        end
    end

    assign sd_clk  = sck;
    assign sd_cmd  = shift_out[7];
    assign sd_d[3] = cs_n;
    assign sd_d[2] = 1'b1;      // unused in SPI mode, must not float
    assign sd_d[1] = 1'b1;
    assign sd_d[0] = 1'bz;      // MISO

    // ---- CMD0 frame ----
    function [7:0] cmd_byte(input [2:0] i);
        case (i)
            3'd0:    cmd_byte = 8'h40;   // CMD0
            3'd5:    cmd_byte = 8'h95;   // real CRC7, required before CRC is off
            default: cmd_byte = 8'h00;   // 32-bit argument, all zero
        endcase
    endfunction

    // ---- sequencer ----
    localparam S_WAKE = 3'd0, S_CMD = 3'd1, S_RESP = 3'd2,
               S_HOLD = 3'd3, S_GAP  = 3'd4;

    reg [2:0]  state   = S_WAKE;
    reg [4:0]  idx     = 5'd0;
    reg [7:0]  result  = 8'hFF;
    reg [23:0] holdcnt = 24'd0;

    always @(posedge clk_25mhz) begin
        start <= 1'b0;

        case (state)
        // 16 bytes with CS high, so the card wakes up before being addressed.
        S_WAKE: begin
            cs_n <= 1'b1;
            // The state change happens only once the last byte has
            // *finished*, never in the same breath as starting one. Getting
            // that wrong is what the first version did: it moved to S_CMD
            // while issuing the 16th wake byte, so CS dropped low midway
            // through it and the card counted that byte's remaining bits as
            // the start of a new one. Every command after was misaligned by a
            // few bits, the card never saw a valid CMD0, and the probe
            // reported 0xFF - indistinguishable from an empty slot.
            // sim/tb_cmd0.v caught it.
            if (!busy && !start) begin
                if (idx == 5'd16) begin
                    idx   <= 5'd0;
                    state <= S_CMD;
                end else begin
                    tx_byte <= 8'hFF;
                    start   <= 1'b1;
                    idx     <= idx + 5'd1;
                end
            end
        end

        // Six command bytes with CS asserted. Same discipline: CS must not
        // change while a byte is in flight.
        S_CMD: begin
            cs_n <= 1'b0;
            if (!busy && !start) begin
                if (idx == 5'd6) begin
                    idx   <= 5'd0;
                    state <= S_RESP;
                end else begin
                    tx_byte <= cmd_byte(idx[2:0]);
                    start   <= 1'b1;
                    idx     <= idx + 5'd1;
                end
            end
        end

        // Poll for a byte with bit 7 clear - that is R1. Give up after 16,
        // which is well past the spec's NCR window.
        S_RESP: begin
            if (!busy && !start) begin
                if (idx != 5'd0 && shift_in[7] == 1'b0) begin
                    result <= shift_in;         // a real response
                    state  <= S_HOLD;
                    idx    <= 5'd0;
                end else if (idx == 5'd16) begin
                    result <= 8'hFF;            // nothing ever answered
                    state  <= S_HOLD;
                    idx    <= 5'd0;
                end else begin
                    tx_byte <= 8'hFF;
                    start   <= 1'b1;
                    idx     <= idx + 5'd1;
                end
            end
        end

        // Show the result for ~0.5 s, then blank briefly and try again, so a
        // card inserted while this runs is picked up without re-flashing.
        S_HOLD: begin
            cs_n <= 1'b1;
            if (holdcnt == 24'd12_000_000) begin holdcnt <= 24'd0; state <= S_GAP; end
            else                                holdcnt <= holdcnt + 24'd1;
        end

        S_GAP: begin
            if (holdcnt == 24'd2_000_000) begin
                holdcnt <= 24'd0;
                idx     <= 5'd0;
                state   <= S_WAKE;
            end else begin
                holdcnt <= holdcnt + 24'd1;
            end
        end

        default: state <= S_WAKE;
        endcase
    end

    // Blank during the gap so a steady display is distinguishable from a
    // wedged one.
    assign led = (state == S_GAP) ? 8'h00 : result;

    /* verilator lint_on PROCASSINIT */

    wire _unused_ok = &{1'b0, btn, sd_cdn, 1'b0};
endmodule
