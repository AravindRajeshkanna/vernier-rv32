// An ns16550-compatible UART: TX, RX, and the register map every 8250/16550
// driver in existence already knows.
//
// ---- Why the map changed ----
//
// This was three registers of this project's own design - TXDATA, RXDATA and
// a two-bit STATUS - and for firmware written against this SoC that was
// perfectly good. It is unusable for anything else. OpenSBI's console and
// Linux's 8250 driver both drive an ns16550; giving them one is cheaper than
// writing and maintaining a driver for a UART nobody else has, and it is the
// difference between "the console works" and "the console works for software
// this project did not write".
//
// ---- Register map (reg-shift = 2, so register n is at offset 4n) ----
//
//   0x00  RBR (R) / THR (W)   data       | DLL when LCR.DLAB
//   0x04  IER                 interrupts | DLM when LCR.DLAB
//   0x08  IIR (R) / FCR (W)   interrupt ident / FIFO control
//   0x0C  LCR                 line control; bit 7 is DLAB
//   0x10  MCR                 modem control
//   0x14  LSR (R)             line status; bit 0 = DR, bit 5 = THRE
//   0x18  MSR (R)             modem status
//   0x1C  SCR                 scratch
//
// The 4-byte stride is what `reg-shift = <2>` in dts/soc.dts declares, and it
// is what this bus wants anyway: every other slave here is word-addressed.
//
// ---- The baud divisor, and one deliberate deviation ----
//
// A real 16550 divides its input clock by 16*divisor. This does too, with one
// exception that is load-bearing for simulation: **divisor 0 means "keep
// CLKS_PER_BIT"**, the module parameter. Zero is not a legal divisor on real
// silicon - the datasheet reserves it - so nothing correct can be relying on
// it, and it buys something worth having: the testbenches run this UART at
// four clocks per bit, and the smallest divisor a spec-compliant part accepts
// is 16. Without the carve-out every SoC simulation that prints anything
// would get four times slower, and `make sim_uartload` is already two and a
// half minutes.
//
// So: reset leaves the divisor at 0 and the rate at CLKS_PER_BIT, and any
// driver that programs a real divisor gets 16*divisor as the spec says.
//
// The bit-period comparisons below are `>=`, not `==`, and that is not
// defensive tidiness. `clks_per_bit` is now a *runtime* value: writing a
// smaller divisor while a character is in flight can leave the counter
// already past the new terminal count, and an equality test would then never
// match again - the transmitter sticks, THRE never comes back, and every
// put_char in the system spins forever. A wedged console is the worst
// possible failure mode for the device you would use to debug it.
//
// software/soc/uarttest.c found this by reprogramming the divisor without
// draining the transmitter first. That is careless of the driver, and real
// silicon garbles the character in flight rather than dying - so garbling is
// what this does now.
//
// ---- Simplifications, stated rather than assumed ----
//
//  * **No FIFOs.** One byte each way, as before. FCR writes are accepted and
//    IIR reports bits 7:6 = 00, which is how a 16450 identifies itself; a
//    driver that checks will simply not use FIFO mode.
//  * **THRE's interrupt is a level, not a latch.** A real 16550 clears the
//    transmitter-empty interrupt when IIR is read; here it follows LSR.THRE
//    directly. Drivers enable ETBEI only while they have something to send,
//    and the PLIC this feeds is level-triggered regardless.
//  * **MSR is a constant** (CTS/DSR/DCD asserted). There are no modem pins on
//    this board, and a driver that waits for CTS would otherwise wait
//    forever.
//  * The RX state machine does not enforce a minimum idle-high gap before
//    re-arming for a new start bit, so a transmitter sending frames with zero
//    gap could shift the sampling point within the next byte. This core's own
//    TX never does that.
//
// `addr` is expected pre-decoded by the caller to be relative to the UART's
// base address, same convention as clint.v/plic.v.
//
// `re` must be asserted only on a cycle where a real load instruction is
// reading this address (not just "the address happens to be on the bus") -
// reading RBR has a side effect (clearing DR), and cpu_core.v's dmem address
// bus is driven combinationally from EX every cycle regardless of instruction
// type, so an unqualified address match would spuriously consume a received
// byte (the same pitfall plic.v's claim register has to avoid).
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
    input  wire        rx,

    // To the PLIC. Source 1 in soc_top.v, which was reserved for the UART and
    // tied low for as long as this had no interrupt to raise.
    output wire        irq
);
    localparam [15:0] OFF_RBR = 16'h0000;   // THR on write, DLL when DLAB
    localparam [15:0] OFF_IER = 16'h0004;   // DLM when DLAB
    localparam [15:0] OFF_IIR = 16'h0008;   // FCR on write
    localparam [15:0] OFF_LCR = 16'h000C;
    localparam [15:0] OFF_MCR = 16'h0010;
    localparam [15:0] OFF_LSR = 16'h0014;
    localparam [15:0] OFF_MSR = 16'h0018;
    localparam [15:0] OFF_SCR = 16'h001C;

    wire [15:0] a = addr[15:0];

    reg [7:0]  lcr_r, mcr_r, scr_r;
    reg [3:0]  ier_r;
    reg [15:0] divisor_r;
    wire       dlab = lcr_r[7];

    // Divisor 0 keeps the parameter; see the header for why that carve-out
    // exists and why nothing correct can depend on the value it displaces.
    wire [31:0] clks_per_bit = (divisor_r == 16'd0) ? CLKS_PER_BIT
                                                     : {12'b0, divisor_r, 4'b0};

    // Only a read of the data register when DLAB is clear consumes a byte. A
    // driver reading DLL while probing the divisor must not eat the input.
    wire read_rxdata = re && (a == OFF_RBR) && !dlab;
    wire write_thr   = we && (a == OFF_RBR) && !dlab;

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
                    if (write_thr && !tx_busy) begin
                        tx_shift     <= wdata[7:0];
                        tx_clk_count <= 32'b0;
                        tx_state     <= TX_START;
                    end
                end
                TX_START: begin
                    tx_line <= 1'b0;
                    if (tx_clk_count >= clks_per_bit - 32'd1) begin
                        tx_clk_count <= 32'b0;
                        tx_bit_idx   <= 3'b0;
                        tx_state     <= TX_DATA;
                    end else tx_clk_count <= tx_clk_count + 32'd1;
                end
                TX_DATA: begin
                    tx_line <= tx_shift[tx_bit_idx];
                    if (tx_clk_count >= clks_per_bit - 32'd1) begin
                        tx_clk_count <= 32'b0;
                        if (tx_bit_idx == 3'd7) tx_state <= TX_STOP;
                        else tx_bit_idx <= tx_bit_idx + 3'd1;
                    end else tx_clk_count <= tx_clk_count + 32'd1;
                end
                TX_STOP: begin
                    tx_line <= 1'b1;
                    if (tx_clk_count >= clks_per_bit - 32'd1) begin
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
                    if (rx_clk_count >= (clks_per_bit >> 1)) begin
                        rx_clk_count <= 32'b0;
                        rx_bit_idx   <= 3'b0;
                        rx_state     <= rx_line ? RX_IDLE : RX_DATA; // glitch check
                    end else rx_clk_count <= rx_clk_count + 32'd1;
                end
                RX_DATA: begin
                    if (rx_clk_count >= clks_per_bit - 32'd1) begin
                        rx_clk_count         <= 32'b0;
                        rx_shift[rx_bit_idx]  <= rx_line;
                        if (rx_bit_idx == 3'd7) rx_state <= RX_STOP;
                        else rx_bit_idx <= rx_bit_idx + 3'd1;
                    end else rx_clk_count <= rx_clk_count + 32'd1;
                end
                RX_STOP: begin
                    if (rx_clk_count >= clks_per_bit - 32'd1) begin
                        rx_data_reg  <= rx_shift;
                        rx_valid_reg <= 1'b1;
                        rx_state     <= RX_IDLE;
                    end else rx_clk_count <= rx_clk_count + 32'd1;
                end
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    // ---- overrun ----
    // Set when a byte completes while the previous one is still unread, which
    // is a real error a driver checks for and this design can genuinely
    // produce: the receiver is one byte deep. Cleared by reading LSR, as the
    // datasheet says.
    reg overrun_r;
    always @(posedge clk or posedge rst) begin
        if (rst) overrun_r <= 1'b0;
        else if (re && (a == OFF_LSR)) overrun_r <= 1'b0;
        else if ((rx_state == RX_STOP) && (rx_clk_count >= clks_per_bit - 32'd1)
                 && rx_valid_reg && !read_rxdata)
            overrun_r <= 1'b1;
    end

    // ---- the writable registers ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lcr_r     <= 8'h00;
            mcr_r     <= 8'h00;
            scr_r     <= 8'h00;
            ier_r     <= 4'h0;
            divisor_r <= 16'd0;
        end else if (we) begin
            case (a)
                OFF_RBR: if (dlab) divisor_r[7:0]  <= wdata[7:0];
                OFF_IER: if (dlab) divisor_r[15:8] <= wdata[7:0];
                         else      ier_r           <= wdata[3:0];
                OFF_LCR: lcr_r <= wdata[7:0];
                OFF_MCR: mcr_r <= wdata[7:0];
                OFF_SCR: scr_r <= wdata[7:0];
                default: ; // FCR: accepted and discarded, there is no FIFO
            endcase
        end
    end

    // ---- status and interrupts ----
    wire dr   = rx_valid_reg;
    wire thre = !tx_busy;

    // LSR: FIFOERR TEMT THRE BI FE PE OE DR. TEMT and THRE are the same signal
    // here because there is no FIFO between them - with one byte in flight,
    // "holding register empty" and "transmitter empty" coincide.
    wire [7:0] lsr = {1'b0, thre, thre, 1'b0, 1'b0, 1'b0, overrun_r, dr};

    // IIR: bit 0 low means an interrupt is pending; bits 3:1 name it. Bits 7:6
    // are 00, which is how a part without FIFOs identifies itself.
    wire int_rx   = ier_r[0] && dr;
    wire int_thre = ier_r[1] && thre;
    wire [7:0] iir = int_rx   ? 8'h04 :
                     int_thre ? 8'h02 : 8'h01;

    assign irq = int_rx || int_thre;

    always @(*) begin
        case (a)
            OFF_RBR: rdata = dlab ? {24'b0, divisor_r[7:0]}
                                  : {24'b0, rx_data_reg};
            OFF_IER: rdata = dlab ? {24'b0, divisor_r[15:8]}
                                  : {28'b0, ier_r};
            OFF_IIR: rdata = {24'b0, iir};
            OFF_LCR: rdata = {24'b0, lcr_r};
            OFF_MCR: rdata = {24'b0, mcr_r};
            OFF_LSR: rdata = {24'b0, lsr};
            // No modem pins on this board. Reporting CTS, DSR and DCD
            // asserted (and their delta bits clear) is what stops a driver
            // that waits for carrier from waiting forever.
            OFF_MSR: rdata = 32'h0000_00B0;
            OFF_SCR: rdata = {24'b0, scr_r};
            default: rdata = 32'b0;
        endcase
    end
endmodule
