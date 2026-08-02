// Wishbone B4 classic SPI master, mode 0 (CPOL=0, CPHA=0), 8 bits per
// transfer, MSB first. Enough to talk to an SD card in SPI mode, which is
// what software/soc/ uses it for.
//
// Register map (word accesses):
//   0x00 CTRL   (RW) - bit0     = assert chip select (1 drives cs_n low)
//                      bits15:8 = clock divider; SCK half-period is
//                                 (div+1) system clocks, so SCK =
//                                 f_clk / (2*(div+1))
//   0x04 DATA   (RW) - write: shift this byte out (and simultaneously in);
//                             **this access blocks** - see below
//                      read:  the byte shifted in by the last transfer
//   0x08 STATUS (RO) - bit0 = busy
//
// **A DATA write is a blocking bus access**: the slave withholds `ack` until
// all 8 bits have been shifted, so the CPU sits in its MEM stage for the
// whole transfer. That is a deliberate design choice, for two reasons.
// First, it makes the driver trivial - no poll loop, a byte exchange is a
// single store followed by a load. Second, and more usefully for this
// project, it is the one slave in the SoC with real multi-cycle wait states,
// so it is what actually exercises cpu_core.v's `dbus_wait` path end to end;
// every other slave acks combinationally and would leave that logic
// unverified.
//
// The cost is that the CPU is frozen for the duration and the fetch master
// is starved (the data master outranks it and holds `cyc` throughout). At
// SD-card clock rates that is real but acceptable, and it is honest: a
// blocking peripheral genuinely does stall an in-order core.
//
// Because the write access is held for many cycles, `stb`/`we` stay asserted
// the whole time - so the transfer must be started exactly once, hence the
// `busy`/`done_q` handshake rather than starting on every strobed cycle.
module wb_spi (
    input  wire        clk,
    input  wire        rst,

    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    output reg  [31:0] wb_dat_r,
    output wire        wb_ack,

    output wire        spi_sck,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n
);
    localparam [15:0] OFF_CTRL   = 16'h0000;
    localparam [15:0] OFF_DATA   = 16'h0004;
    localparam [15:0] OFF_STATUS = 16'h0008;

    wire [15:0] a      = wb_adr[15:0];
    wire        active = wb_cyc && wb_stb;
    wire        wr     = active && wb_we;

    reg [15:0] ctrl;
    wire [7:0] clkdiv = ctrl[15:8];
    assign spi_cs_n = ~ctrl[0];

    reg [7:0]  txreg;     // shifts out, MSB first
    reg [7:0]  rxreg;     // shifts in
    reg [3:0]  bitcnt;
    reg        sck_r;
    reg        busy;
    reg [7:0]  div_cnt;
    reg        done_q;

    assign spi_sck  = sck_r;
    assign spi_mosi = txreg[7];

    wire data_write = wr && (a == OFF_DATA);
    wire start      = data_write && !busy && !done_q;
    wire tick       = (div_cnt == clkdiv);

    // ---- MISO synchronizer ----
    // `spi_miso` is a pin driven by another device on its own clock, so it is
    // asynchronous to this one. Sampling it straight into `rxreg` - which is
    // what this module used to do - is a metastability hazard on every bit
    // received, and the failure mode on hardware is intermittently corrupt
    // data with no clean way to reproduce it. rtl/uart.v and rtl/soc/wb_gpio.v
    // both already synchronize their asynchronous inputs; this is the same
    // 2-flop treatment.
    //
    // Simulation cannot show the problem: sim/sd_card_model.v advances MISO on
    // the SCK falling edge, so in a testbench it is always perfectly
    // synchronous to the sampling point.
    //
    // Reset high because MISO idles high (the card's pull-up).
    //
    // **This costs two clocks of latency, which constrains `clkdiv`.** The
    // shift register samples at the SCK rising edge, and the card drove that
    // bit at the falling edge - one half period, or (clkdiv+1) system clocks,
    // earlier. For the synchronized value to have caught up by then,
    // clkdiv+1 must exceed the synchronizer's 2 cycles, so **clkdiv >= 2** is
    // required and anything less samples the previous bit. See the check
    // below, and SD_FAST_DIV in software/soc/soc.h.
    reg miso_sync1, miso_sync2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            miso_sync1 <= 1'b1;
            miso_sync2 <= 1'b1;
        end else begin
            miso_sync1 <= spi_miso;
            miso_sync2 <= miso_sync1;
        end
    end
    wire miso = miso_sync2;

`ifndef SYNTHESIS
    // The clkdiv >= 2 requirement above is a real constraint on firmware and
    // there is no way for it to fail loudly on hardware - it just returns
    // wrong bytes. So fail loudly here instead, at the moment a transfer is
    // started with a divider that cannot work.
    always @(posedge clk) begin
        if (!rst && start && (clkdiv < 8'd2)) begin
            $display("ERROR: %m started an SPI transfer with clkdiv=%0d.", clkdiv);
            $display("       clkdiv must be >= 2 - the MISO synchronizer adds two");
            $display("       cycles of latency, so a shorter half period samples the");
            $display("       previous bit. See rtl/soc/wb_spi.v and soc.h's SD_FAST_DIV.");
            $fatal(1);
        end
    end
`endif

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ctrl    <= 16'b0;
            txreg   <= 8'b0;
            rxreg   <= 8'b0;
            bitcnt  <= 4'b0;
            sck_r   <= 1'b0;
            busy    <= 1'b0;
            div_cnt <= 8'b0;
            done_q  <= 1'b0;
        end else begin
            if (wr && (a == OFF_CTRL)) ctrl <= wb_dat_w[15:0];

            // Clear the completion flag once the CPU has moved off this
            // access, so the next DATA write starts a fresh transfer.
            if (!data_write) done_q <= 1'b0;

            if (start) begin
                txreg   <= wb_dat_w[7:0];
                rxreg   <= 8'b0;
                bitcnt  <= 4'd8;
                sck_r   <= 1'b0;
                div_cnt <= 8'b0;
                busy    <= 1'b1;
            end else if (busy) begin
                if (!tick) begin
                    div_cnt <= div_cnt + 8'd1;
                end else begin
                    div_cnt <= 8'b0;
                    if (!sck_r) begin
                        // Rising edge: the slave has had a half period to set
                        // up MISO, so sample it here (mode 0). `miso` is the
                        // synchronized copy, two clocks behind the pin - which
                        // is why clkdiv >= 2 is required.
                        sck_r <= 1'b1;
                        rxreg <= {rxreg[6:0], miso};
                    end else begin
                        // Falling edge: advance MOSI to the next bit.
                        sck_r  <= 1'b0;
                        txreg  <= {txreg[6:0], 1'b0};
                        bitcnt <= bitcnt - 4'd1;
                        if (bitcnt == 4'd1) begin
                            busy   <= 1'b0;
                            done_q <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    always @(*) begin
        case (a)
            OFF_CTRL:   wb_dat_r = {16'b0, ctrl};
            OFF_DATA:   wb_dat_r = {24'b0, rxreg};
            OFF_STATUS: wb_dat_r = {31'b0, busy};
            default:    wb_dat_r = 32'b0;
        endcase
    end

    // Everything acks combinationally except a DATA write, which is held off
    // until the byte has actually gone out.
    assign wb_ack = data_write ? done_q : active;
endmodule
