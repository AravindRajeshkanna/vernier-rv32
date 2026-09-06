// Wishbone B4 classic general-purpose timer, with a PWM output built from
// the same counter/compare datapath - not a second peripheral. See
// docs/roadmap.md's Phase 12 entry for why this is a genuinely separate
// need from rtl/clint.v's own mtime: CLINT is one hart's fixed-purpose
// scheduling clock, entirely spoken for by OpenSBI/Linux, and repurposing
// it for anything else means fighting the kernel's own tick for a
// resource it doesn't share.
//
// Register map (word accesses):
//   0x00 CTRL    (RW) - bit0 EN (counter runs), bit1 PWM_EN (pwm_out
//                       reflects the compare logic; when clear, pwm_out
//                       is held low regardless of COUNT/COMPARE)
//   0x04 COUNT   (RW) - free-running counter, 0..PERIOD-1; a write loads
//                       it directly, for restarting a period on demand
//                       without waiting for a wraparound
//   0x08 PERIOD  (RW) - counter wraps to 0 the cycle after reaching
//                       PERIOD-1 (PERIOD=0 disables wraparound/PWM
//                       entirely - a free count with no period, which is
//                       a legitimate use: a plain elapsed-cycles counter)
//   0x0C COMPARE (RW) - duty-cycle threshold: pwm_out is high while
//                       COUNT < COMPARE, low otherwise. COMPARE >=
//                       PERIOD is 100% duty (never goes low); COMPARE=0
//                       is 0% duty (never goes high)
//   0x10 IE      (RW) - wraparound interrupt enable
//   0x14 IP      (RW) - wraparound interrupt pending; write a 1 to clear
//                       (write-1-to-clear, matching wb_gpio.v's own
//                       convention)
//
// Zero wait states.
//
// One channel, deliberately - docs/roadmap.md's Phase 12 entry names
// "how many channels" as the real open question this stage answers, and
// a single channel is enough to prove the mechanism (counter, period,
// compare, wraparound interrupt, PWM output) without the added
// complexity of arbitrating multiple simultaneous outputs or the pin
// budget that would need. A second channel is an instantiation of this
// same module away, not a redesign, if a real need for one shows up.
module wb_timer (
    input  wire        clk,
    input  wire        rst,

    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    output reg  [31:0] wb_dat_r,
    output wire        wb_ack,

    output wire        pwm_out,
    output wire        irq
);
    localparam [15:0] OFF_CTRL    = 16'h0000;
    localparam [15:0] OFF_COUNT   = 16'h0004;
    localparam [15:0] OFF_PERIOD  = 16'h0008;
    localparam [15:0] OFF_COMPARE = 16'h000C;
    localparam [15:0] OFF_IE      = 16'h0010;
    localparam [15:0] OFF_IP      = 16'h0014;

    wire [15:0] a      = wb_adr[15:0];
    wire        active = wb_cyc && wb_stb;
    wire        wr     = active && wb_we;

    reg        ctrl_en_r, ctrl_pwmen_r;
    reg [31:0] count_r, period_r, compare_r;
    reg        ie_r, ip_r;

    wire       wraps_this_cycle = ctrl_en_r && (period_r != 32'b0) &&
                                   (count_r == period_r - 32'd1);

    // The compare/wraparound logic is combinational off `count_r`'s
    // *current* value, matching every other peripheral's own read-side
    // discipline in this file set (wb_gpio.v's `in_sync2`, not a
    // registered copy of it) - pwm_out and the wraparound event both
    // reflect the real count, not a cycle-stale one.
    assign pwm_out = ctrl_pwmen_r && (count_r < compare_r);
    assign irq     = ip_r && ie_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ctrl_en_r    <= 1'b0;
            ctrl_pwmen_r <= 1'b0;
            count_r      <= 32'b0;
            period_r     <= 32'b0;
            compare_r    <= 32'b0;
            ie_r         <= 1'b0;
            ip_r         <= 1'b0;
        end else begin
            if (wr) begin
                case (a)
                    OFF_CTRL:    {ctrl_pwmen_r, ctrl_en_r} <= wb_dat_w[1:0];
                    OFF_COUNT:   count_r   <= wb_dat_w;
                    OFF_PERIOD:  period_r  <= wb_dat_w;
                    OFF_COMPARE: compare_r <= wb_dat_w;
                    OFF_IE:      ie_r      <= wb_dat_w[0];
                    default: ;
                endcase
            end

            // A same-cycle COUNT write and a wraparound both target
            // `count_r`; the write wins; explicit priority below rather
            // than relying on `case`/`if` ordering elsewhere to imply
            // it. Software reloading COUNT on the exact cycle it would
            // have wrapped is not a case worth making more well-defined
            // than "the write happened" - the same standard wb_gpio.v
            // holds writing DIR and OUT the same cycle to.
            if (wr && (a == OFF_COUNT)) begin
                // count_r already takes wb_dat_w via the case above.
            end else if (ctrl_en_r) begin
                count_r <= wraps_this_cycle ? 32'b0 : count_r + 32'd1;
            end

            // Same write-1-to-clear discipline as wb_gpio.v's IP: a new
            // wraparound always wins over a same-cycle clear, so a
            // period ending exactly as software acknowledges the
            // previous one isn't lost.
            if (wr && (a == OFF_IP)) ip_r <= (ip_r && !wb_dat_w[0]) || wraps_this_cycle;
            else                      ip_r <= ip_r || wraps_this_cycle;
        end
    end

    always @(*) begin
        case (a)
            OFF_CTRL:    wb_dat_r = {30'b0, ctrl_pwmen_r, ctrl_en_r};
            OFF_COUNT:   wb_dat_r = count_r;
            OFF_PERIOD:  wb_dat_r = period_r;
            OFF_COMPARE: wb_dat_r = compare_r;
            OFF_IE:      wb_dat_r = {31'b0, ie_r};
            OFF_IP:      wb_dat_r = {31'b0, ip_r};
            default:     wb_dat_r = 32'b0;
        endcase
    end

    assign wb_ack = active;
endmodule
