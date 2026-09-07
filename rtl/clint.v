// A tiny SiFive-CLINT-style memory-mapped peripheral: msip (software
// interrupt, 1 bit used), mtimecmp (64-bit), and a free-running mtime
// (64-bit, incrementing every clock - a simplification vs. a real
// separate reference clock). `addr` is expected pre-decoded by the
// caller (top.v) to be relative to the CLINT's base address.
//
// Only word-sized accesses are meaningful here (`size`/byte-lane
// granularity isn't modeled) - software reads/writes each 64-bit
// register as two 32-bit words, same as a real CLINT.
//
// NUM_HARTS parameterizes msip/mtimecmp into the standard per-hart-strided
// arrays a real CLINT uses (msip for hart h at 0x0000 + 4*h, mtimecmp for
// hart h at 0x4000 + 8*h) - mtime stays a single counter shared by every
// hart, same as a real CLINT. NUM_HARTS=1 (the default, and every
// instantiation in this tree today) collapses this back to exactly the
// fixed offsets this module used to hardcode; nothing outside this module
// has been asked to instantiate more than one hart yet - see
// docs/roadmap.md's Phase 13 entry.
module clint #(
    parameter NUM_HARTS = 1
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire        we,
    output reg  [31:0] rdata,

    output wire [NUM_HARTS-1:0] mtip,
    output wire [NUM_HARTS-1:0] msip_out,
    // The architectural `time` CSR must read this same counter - see
    // csr_file.v's mtime_in.
    output wire [63:0]  mtime_out
);
    localparam OFF_MTIME_LO = 16'hBFF8;
    localparam OFF_MTIME_HI = 16'hBFFC;

    // Wide enough to index the harts and no wider, so the array indices
    // below do not need truncating - same convention as rtl/plic.v's own
    // CTXW. $clog2(1) is 0, so NUM_HARTS=1 is special-cased to 1 rather
    // than a zero-width index.
    localparam HIDXW = (NUM_HARTS <= 1) ? 1 : $clog2(NUM_HARTS);

    wire [13:0]       word_idx = addr[15:2];
    wire              is_msip  = (addr[15:0] < 16'h4000);
    wire              msip_ok  = is_msip && (word_idx < NUM_HARTS);
    wire [HIDXW-1:0]  msip_idx = word_idx[HIDXW-1:0];

    // mtimecmp region starts at word 0x1000 (byte 0x4000); each hart takes
    // two words (lo, hi), so bit 0 of the in-region word offset selects
    // hi/lo and the rest is the hart index.
    wire [13:0]       mtimecmp_word = word_idx - 14'd4096;
    wire              is_mtimecmp   = (addr[15:0] >= 16'h4000) && (addr[15:0] < OFF_MTIME_LO);
    wire              mtimecmp_hi   = mtimecmp_word[0];
    wire [13:0]       mtimecmp_hart = mtimecmp_word >> 1;
    wire              mtimecmp_ok   = is_mtimecmp && (mtimecmp_hart < NUM_HARTS);
    wire [HIDXW-1:0]  mtimecmp_idx  = mtimecmp_hart[HIDXW-1:0];

    reg [63:0] mtime;
    reg [63:0] mtimecmp [0:NUM_HARTS-1];
    reg        msip_bit [0:NUM_HARTS-1];

    integer h;

    genvar g;
    generate
        for (g = 0; g < NUM_HARTS; g = g + 1) begin : g_hart
            assign mtip[g]     = (mtime >= mtimecmp[g]);
            assign msip_out[g] = msip_bit[g];
        end
    endgenerate

    assign mtime_out = mtime;

    always @(*) begin
        if (msip_ok)
            rdata = {31'b0, msip_bit[msip_idx]};
        else if (mtimecmp_ok)
            rdata = mtimecmp_hi ? mtimecmp[mtimecmp_idx][63:32]
                                 : mtimecmp[mtimecmp_idx][31:0];
        else if (addr[15:0] == OFF_MTIME_LO)
            rdata = mtime[31:0];
        else if (addr[15:0] == OFF_MTIME_HI)
            rdata = mtime[63:32];
        else
            rdata = 32'b0;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mtime <= 64'b0;
            for (h = 0; h < NUM_HARTS; h = h + 1) begin
                mtimecmp[h] <= 64'hFFFF_FFFF_FFFF_FFFF; // far future - no spurious interrupt right after reset
                msip_bit[h] <= 1'b0;
            end
        end else begin
            mtime <= mtime + 64'd1;
            if (we) begin
                if (msip_ok)
                    msip_bit[msip_idx] <= wdata[0];
                else if (mtimecmp_ok) begin
                    if (mtimecmp_hi) mtimecmp[mtimecmp_idx][63:32] <= wdata;
                    else             mtimecmp[mtimecmp_idx][31:0] <= wdata;
                end else if (addr[15:0] == OFF_MTIME_LO) mtime[31:0]  <= wdata;
                else if (addr[15:0] == OFF_MTIME_HI)     mtime[63:32] <= wdata;
            end
        end
    end
endmodule
