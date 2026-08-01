// A tiny SiFive-CLINT-style memory-mapped peripheral: msip (software
// interrupt, 1 bit used), mtimecmp (64-bit), and a free-running mtime
// (64-bit, incrementing every clock - a simplification vs. a real
// separate reference clock). `addr` is expected pre-decoded by the
// caller (top.v) to be relative to the CLINT's base address.
//
// Only word-sized accesses are meaningful here (`size`/byte-lane
// granularity isn't modeled) - software reads/writes each 64-bit
// register as two 32-bit words, same as a real CLINT.
module clint (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    output reg  [31:0] rdata,

    output wire         mtip,
    output wire         msip_out,
    // The architectural `time` CSR must read this same counter - see
    // csr_file.v's mtime_in.
    output wire [63:0]  mtime_out
);
    localparam OFF_MSIP      = 16'h0000;
    localparam OFF_MTIMECMP_LO = 16'h4000;
    localparam OFF_MTIMECMP_HI = 16'h4004;
    localparam OFF_MTIME_LO    = 16'hBFF8;
    localparam OFF_MTIME_HI    = 16'hBFFC;

    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    reg        msip_bit;

    assign mtip     = (mtime >= mtimecmp);
    assign mtime_out = mtime;
    assign msip_out = msip_bit;

    always @(*) begin
        case (addr[15:0])
            OFF_MSIP:        rdata = {31'b0, msip_bit};
            OFF_MTIMECMP_LO: rdata = mtimecmp[31:0];
            OFF_MTIMECMP_HI: rdata = mtimecmp[63:32];
            OFF_MTIME_LO:    rdata = mtime[31:0];
            OFF_MTIME_HI:    rdata = mtime[63:32];
            default:         rdata = 32'b0;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mtime    <= 64'b0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF; // far future - no spurious interrupt right after reset
            msip_bit <= 1'b0;
        end else begin
            mtime <= mtime + 64'd1;
            if (we) begin
                case (addr[15:0])
                    OFF_MSIP:        msip_bit          <= wdata[0];
                    OFF_MTIMECMP_LO: mtimecmp[31:0]    <= wdata;
                    OFF_MTIMECMP_HI: mtimecmp[63:32]   <= wdata;
                    OFF_MTIME_LO:    mtime[31:0]       <= wdata;
                    OFF_MTIME_HI:    mtime[63:32]      <= wdata;
                    default: ;
                endcase
            end
        end
    end
endmodule
