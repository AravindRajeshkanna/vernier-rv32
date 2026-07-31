// Wishbone B4 classic GPIO: bidirectional pins with per-pin direction, plus
// rising-edge interrupt detection wired out to the PLIC.
//
// Register map (word accesses):
//   0x00 OUT    (RW) - value driven on pins configured as outputs
//   0x04 IN     (RO) - synchronized pin state
//   0x08 DIR    (RW) - 1 = drive the pin, 0 = input (reset: all inputs, so
//                      nothing is driven until firmware says so)
//   0x0C IE     (RW) - per-pin interrupt enable
//   0x10 IP     (RW) - per-pin interrupt pending, set on a rising edge;
//                      write a 1 to a bit to clear it (write-1-to-clear)
//
// Zero wait states.
//
// Inputs go through a 2-flop synchronizer before anything looks at them -
// these are genuinely asynchronous pins, and feeding a raw pin into the edge
// detector would let metastability set a spurious interrupt.
module wb_gpio #(
    parameter WIDTH = 16
)(
    input  wire        clk,
    input  wire        rst,

    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    output reg  [31:0] wb_dat_r,
    output wire        wb_ack,

    input  wire [WIDTH-1:0] gpio_in,
    output wire [WIDTH-1:0] gpio_out,
    output wire [WIDTH-1:0] gpio_dir,  // 1 = drive

    output wire        irq
);
    localparam [15:0] OFF_OUT = 16'h0000;
    localparam [15:0] OFF_IN  = 16'h0004;
    localparam [15:0] OFF_DIR = 16'h0008;
    localparam [15:0] OFF_IE  = 16'h000C;
    localparam [15:0] OFF_IP  = 16'h0010;

    wire [15:0] a      = wb_adr[15:0];
    wire        active = wb_cyc && wb_stb;
    wire        wr     = active && wb_we;

    reg [WIDTH-1:0] out_r, dir_r, ie_r, ip_r;

    // 2-flop synchronizer for the asynchronous input pins.
    reg [WIDTH-1:0] in_sync1, in_sync2, in_prev;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            in_sync1 <= {WIDTH{1'b0}};
            in_sync2 <= {WIDTH{1'b0}};
            in_prev  <= {WIDTH{1'b0}};
        end else begin
            in_sync1 <= gpio_in;
            in_sync2 <= in_sync1;
            in_prev  <= in_sync2;
        end
    end

    wire [WIDTH-1:0] rising = in_sync2 & ~in_prev;

    assign gpio_out = out_r;
    assign gpio_dir = dir_r;
    assign irq      = |(ip_r & ie_r);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out_r <= {WIDTH{1'b0}};
            dir_r <= {WIDTH{1'b0}};   // everything an input until told otherwise
            ie_r  <= {WIDTH{1'b0}};
            ip_r  <= {WIDTH{1'b0}};
        end else begin
            if (wr) begin
                case (a)
                    OFF_OUT: out_r <= wb_dat_w[WIDTH-1:0];
                    OFF_DIR: dir_r <= wb_dat_w[WIDTH-1:0];
                    OFF_IE:  ie_r  <= wb_dat_w[WIDTH-1:0];
                    default: ;
                endcase
            end
            // A new rising edge always wins over a same-cycle write-1-to-clear,
            // so an edge that happens exactly as software acknowledges the
            // previous one isn't lost.
            if (wr && (a == OFF_IP)) ip_r <= (ip_r & ~wb_dat_w[WIDTH-1:0]) | rising;
            else                      ip_r <= ip_r | rising;
        end
    end

    always @(*) begin
        case (a)
            OFF_OUT: wb_dat_r = {{(32-WIDTH){1'b0}}, out_r};
            OFF_IN:  wb_dat_r = {{(32-WIDTH){1'b0}}, in_sync2};
            OFF_DIR: wb_dat_r = {{(32-WIDTH){1'b0}}, dir_r};
            OFF_IE:  wb_dat_r = {{(32-WIDTH){1'b0}}, ie_r};
            OFF_IP:  wb_dat_r = {{(32-WIDTH){1'b0}}, ip_r};
            default: wb_dat_r = 32'b0;
        endcase
    end

    assign wb_ack = active;
endmodule
