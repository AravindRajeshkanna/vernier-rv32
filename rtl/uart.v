// A minimal memory-mapped UART: TX and RX, both polled (no interrupt -
// matches this project's existing CLINT-style "software polls a status
// bit" convention rather than adding another interrupt source). `addr`
// is expected pre-decoded by the caller (top.v) to be relative to the
// UART's base address, same convention as clint.v/plic.v.
//
// Register map:
//   0x00 TXDATA  (W)  - writing a byte starts transmitting it (ignored
//                       while busy - software is expected to poll
//                       STATUS.tx_busy first)
//   0x04 RXDATA  (R)  - the last received byte; reading it clears
//                       STATUS.rx_valid
//   0x08 STATUS  (RO) - bit0 = tx_busy, bit1 = rx_valid
//
// `CLKS_PER_BIT` sets the bit period (clock cycles per bit) - a fixed
// module parameter, not a runtime baud-rate register, since this project
// has no need to reconfigure it at runtime. `top.v` (simulation) uses a
// small value for fast sim; `fpga/top_fpga.v` should use a realistic
// value for its actual board clock.
//
// `re` must be asserted only on a cycle where a real load instruction is
// reading this address (not just "the address happens to be on the
// bus") - reading RXDATA has a side effect (clearing rx_valid), and
// cpu_core.v's dmem address bus is driven combinationally from EX every
// cycle regardless of instruction type, so an unqualified address match
// would spuriously clear rx_valid on unrelated instructions (the same
// pitfall plic.v's claim register has to avoid).
//
// Simplification, documented rather than silently assumed: the RX state
// machine doesn't enforce a minimum idle-high gap before re-arming for a
// new start bit, so a transmitter sending frames back-to-back with zero
// gap between the stop bit and the next start bit could shift the
// sampling point within that next byte. This core's own TX never does
// that (there's always at least one idle cycle, and in practice many
// more from software's own poll-loop overhead, between transmissions).
module uart #(
    parameter CLKS_PER_BIT = 4
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    input  wire        re,
    output reg  [31:0] rdata,

    output wire        tx,
    input  wire        rx
);
    localparam [15:0] OFF_TXDATA = 16'h0000;
    localparam [15:0] OFF_RXDATA = 16'h0004;
    localparam [15:0] OFF_STATUS = 16'h0008;

    wire [15:0] a = addr[15:0];
    wire read_rxdata = re && (a == OFF_RXDATA);

    // ---- TX ----
    localparam [1:0] TX_IDLE = 2'd0, TX_START = 2'd1, TX_DATA = 2'd2, TX_STOP = 2'd3;
    reg [1:0]  tx_state;
    reg [31:0] tx_clk_count;
    reg [2:0]  tx_bit_idx;
    reg [7:0]  tx_shift;
    reg        tx_line;
    assign tx = tx_line;
    wire tx_busy = (tx_state != TX_IDLE);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_state     <= TX_IDLE;
            tx_line      <= 1'b1;
            tx_clk_count <= 32'b0;
            tx_bit_idx   <= 3'b0;
        end else begin
            case (tx_state)
                TX_IDLE: begin
                    tx_line <= 1'b1;
                    if (we && (a == OFF_TXDATA) && !tx_busy) begin
                        tx_shift     <= wdata[7:0];
                        tx_clk_count <= 32'b0;
                        tx_state     <= TX_START;
                    end
                end
                TX_START: begin
                    tx_line <= 1'b0;
                    if (tx_clk_count == CLKS_PER_BIT - 1) begin
                        tx_clk_count <= 32'b0;
                        tx_bit_idx   <= 3'b0;
                        tx_state     <= TX_DATA;
                    end else tx_clk_count <= tx_clk_count + 32'd1;
                end
                TX_DATA: begin
                    tx_line <= tx_shift[tx_bit_idx];
                    if (tx_clk_count == CLKS_PER_BIT - 1) begin
                        tx_clk_count <= 32'b0;
                        if (tx_bit_idx == 3'd7) tx_state <= TX_STOP;
                        else tx_bit_idx <= tx_bit_idx + 3'd1;
                    end else tx_clk_count <= tx_clk_count + 32'd1;
                end
                TX_STOP: begin
                    tx_line <= 1'b1;
                    if (tx_clk_count == CLKS_PER_BIT - 1) begin
                        tx_clk_count <= 32'b0;
                        tx_state     <= TX_IDLE;
                    end else tx_clk_count <= tx_clk_count + 32'd1;
                end
                default: tx_state <= TX_IDLE;
            endcase
        end
    end

    // ---- RX ----
    // 2-FF synchronizer for the asynchronous rx input.
    reg rx_sync1, rx_sync2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end else begin
            rx_sync1 <= rx;
            rx_sync2 <= rx_sync1;
        end
    end
    wire rx_line = rx_sync2;

    localparam [1:0] RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;
    reg [1:0]  rx_state;
    reg [31:0] rx_clk_count;
    reg [2:0]  rx_bit_idx;
    reg [7:0]  rx_shift;
    reg [7:0]  rx_data_reg;
    reg        rx_valid_reg;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_state     <= RX_IDLE;
            rx_clk_count <= 32'b0;
            rx_bit_idx   <= 3'b0;
            rx_valid_reg <= 1'b0;
            rx_data_reg  <= 8'b0;
        end else begin
            // Scheduled first so a same-cycle new-byte arrival (below)
            // overrides it - clearing on read must never lose a byte
            // that completes on the very same cycle it's read.
            if (read_rxdata) rx_valid_reg <= 1'b0;

            case (rx_state)
                RX_IDLE: begin
                    if (!rx_line) begin
                        rx_state     <= RX_START;
                        rx_clk_count <= 32'b0;
                    end
                end
                RX_START: begin
                    if (rx_clk_count == (CLKS_PER_BIT / 2)) begin
                        rx_clk_count <= 32'b0;
                        rx_bit_idx   <= 3'b0;
                        rx_state     <= rx_line ? RX_IDLE : RX_DATA; // glitch check
                    end else rx_clk_count <= rx_clk_count + 32'd1;
                end
                RX_DATA: begin
                    if (rx_clk_count == CLKS_PER_BIT - 1) begin
                        rx_clk_count         <= 32'b0;
                        rx_shift[rx_bit_idx]  <= rx_line;
                        if (rx_bit_idx == 3'd7) rx_state <= RX_STOP;
                        else rx_bit_idx <= rx_bit_idx + 3'd1;
                    end else rx_clk_count <= rx_clk_count + 32'd1;
                end
                RX_STOP: begin
                    if (rx_clk_count == CLKS_PER_BIT - 1) begin
                        rx_data_reg  <= rx_shift;
                        rx_valid_reg <= 1'b1;
                        rx_state     <= RX_IDLE;
                    end else rx_clk_count <= rx_clk_count + 32'd1;
                end
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    always @(*) begin
        case (a)
            OFF_TXDATA: rdata = 32'b0;
            OFF_RXDATA: rdata = {24'b0, rx_data_reg};
            OFF_STATUS: rdata = {30'b0, rx_valid_reg, tx_busy};
            default:    rdata = 32'b0;
        endcase
    end
endmodule
