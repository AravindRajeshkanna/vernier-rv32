// The one crossing between JTAG's clock and the SoC's.
//
// TCK is driven by the host: asynchronous to `clk`, typically slower, and it
// stops entirely between transactions - a debugger can sit idle for minutes
// with TCK parked. So this cannot be a FIFO with a free-running pointer, and
// it must not depend on TCK ticking to make progress on the system side or
// the other way round.
//
// It is a four-phase handshake on two toggles, which is the standard answer
// and is chosen here for a specific reason: **only two single-bit signals
// actually cross.** The payload - address, data, op, and the response - never
// crosses as such. It is written in one domain, held still, and read in the
// other only after a toggle has proved it has been still for at least two
// destination clocks. Synchronising 41 bits individually would be the
// classic way to get this wrong: each bit resolves on its own, so a word can
// be sampled half-old and half-new, and the failure is data-dependent and
// arrives once a week.
//
//   TCK side              SYS side
//   --------              --------
//   latch payload
//   flip req_tog   --->   2FF sync, edge detect
//                         payload is stable, read it
//                         do the access
//                         latch response
//   2FF sync       <---   flip ack_tog
//   edge detect
//   read response
//
// `busy` is set on the TCK side between those two edges, and the TAP reports
// it to the host as DMI status 3. A host that shifts a new operation in while
// busy gets that status and knows to retry - which is exactly what the `idle`
// field in `dtmcs` exists to make rare.
//
// Reset: the system side has one, the TCK side does not (JTAG's reset is
// TMS-high, and it reaches the TAP's state machine rather than this). The
// toggles are therefore initialised rather than reset, and the edge detectors
// compare against a synchronised copy - so whatever state the two sides power
// up in, the first real toggle is still seen as exactly one edge.
module dmi_cdc (
    // ---- TCK domain ----
    input  wire        tck,
    input  wire        req,          // one TCK pulse
    input  wire [6:0]  req_addr,
    input  wire [31:0] req_wdata,
    input  wire [1:0]  req_op,
    output reg  [31:0] rsp_rdata,
    output reg  [1:0]  rsp_op,
    output wire        busy,

    // ---- system domain ----
    input  wire        clk,
    input  wire        rst,
    output reg         sys_valid,    // one clk pulse
    output reg  [6:0]  sys_addr,
    output reg  [31:0] sys_wdata,
    output reg  [1:0]  sys_op,
    input  wire        sys_done,     // one clk pulse, any time after
    input  wire [31:0] sys_rdata,
    input  wire [1:0]  sys_resp
);
    // ---- payload, written on TCK and read on clk ----
    //
    // Deliberately not synchronised. It is written only when `busy` is low
    // and read only after the request toggle has crossed, so by the time the
    // system side looks at it, it has been unchanged for at least two `clk`
    // edges. That is the whole argument for this structure.
    reg [6:0]  p_addr;
    reg [31:0] p_wdata;
    reg [1:0]  p_op;

    reg req_tog;
    initial req_tog = 1'b0;

    // ---- response payload, written on clk and read on TCK ----
    reg [31:0] r_data;
    reg [1:0]  r_op;
    reg        ack_tog;

    // ---- TCK -> system ----
    reg [2:0] req_sync;
    always @(posedge clk or posedge rst) begin
        if (rst) req_sync <= 3'b0;
        else     req_sync <= {req_sync[1:0], req_tog};
    end
    wire req_edge = req_sync[2] ^ req_sync[1];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sys_valid <= 1'b0;
            sys_addr  <= 7'b0;
            sys_wdata <= 32'b0;
            sys_op    <= 2'b0;
        end else begin
            sys_valid <= req_edge;
            if (req_edge) begin
                sys_addr  <= p_addr;
                sys_wdata <= p_wdata;
                sys_op    <= p_op;
            end
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ack_tog <= 1'b0;
            r_data  <= 32'b0;
            r_op    <= 2'b0;
        end else if (sys_done) begin
            r_data  <= sys_rdata;
            r_op    <= sys_resp;
            ack_tog <= ~ack_tog;
        end
    end

    // ---- system -> TCK ----
    reg [2:0] ack_sync;
    initial ack_sync = 3'b0;
    always @(posedge tck) ack_sync <= {ack_sync[1:0], ack_tog};
    wire ack_edge = ack_sync[2] ^ ack_sync[1];

    reg busy_r;
    initial busy_r = 1'b0;
    assign busy = busy_r;

    always @(posedge tck) begin
        if (req && !busy_r) begin
            p_addr  <= req_addr;
            p_wdata <= req_wdata;
            p_op    <= req_op;
            req_tog <= ~req_tog;
            busy_r  <= 1'b1;
        end else if (ack_edge) begin
            rsp_rdata <= r_data;
            rsp_op    <= r_op;
            busy_r    <= 1'b0;
        end
    end
endmodule
