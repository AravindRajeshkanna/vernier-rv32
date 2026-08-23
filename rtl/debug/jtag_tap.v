// An IEEE 1149.1 TAP carrying the RISC-V Debug Transport Module.
//
// This is the wire end of the debug path: four pins, a sixteen-state machine
// that has not changed since 1990, and two registers on top of it that the
// RISC-V External Debug Support specification defines - `dtmcs` and `dmi`.
// Everything a host can do here reduces to "shift 41 bits in, shift 41 bits
// out", and the Debug Module on the other side turns that into a bus access.
//
// ---- What this is for ----
//
// Until now debugging this SoC on hardware has been `printf` and the loud
// trap handler in `software/soc/trap.h`, and both need the machine to be well
// enough to print. The failures that have actually cost time here were not:
// OpenSBI hanging before its console came up, a boot ROM stopping with no
// output, a Linux kernel dying between `earlycon` and `ttyS0`. In every one
// of those the interesting state was sitting in memory and there was no way
// to look at it.
//
// A TAP does not care whether the CPU is running, halted, or wedged in a
// `wfi` loop. `docs/practices.md` section 27 is the general form of this -
// when the firmware owns the console, instrument the machine instead - and
// this is the largest instrument available.
//
// ---- What it deliberately is not ----
//
// **There is no hart control here.** The Debug Module behind this implements
// System Bus Access and nothing else: a host can read and write any address
// the interconnect decodes, and cannot halt the hart, single-step it, or read
// its registers. That is the invasive half of a Debug Module - it needs debug
// mode, `dcsr`, `dpc`, `dret`, and a debug ROM the core traps into - and it
// lands on the fetch and writeback paths of a design whose timing margin is
// currently about 2%. See rtl/debug/dm.v and fpga/README.md.
//
// Splitting it this way is not a hedge: the memory port is the half that
// answers "what is in the device tree the firmware just read", and it costs
// the CPU nothing but one bus arbitration slot.
//
// ---- The clock ----
//
// TCK is driven by the host and is asynchronous to everything else here. It
// is also *slow* - 1 to 10 MHz typically, against a 25 MHz system clock - and
// it can stop for minutes between transactions. Nothing in this file may
// assume it runs at all.
//
// Every register below is therefore clocked by TCK, and the single crossing
// into the system clock domain is rtl/debug/dmi_cdc.v, which does it once, in
// one place, with a handshake rather than a synchroniser on each bit.
module jtag_tap #(
    // The JTAG IDCODE this TAP answers with. Bit 0 must be 1 - that is how a
    // host distinguishes an IDCODE register from a BYPASS one after a
    // test-logic reset, and it is the first thing any scan chain probe
    // checks.
    //
    //   [31:28] version    0x1
    //   [27:12] part       0x5256 - "RV"
    //   [11:1]  manufacturer id, 11 bits. 0x7FF is the JEDEC "unassigned"
    //           code, which is the honest answer for a project with no JEDEC
    //           membership. Anything else would be claiming somebody's ID.
    //   [0]     always 1
    parameter [31:0] IDCODE = 32'h1525_6FFF
)(
    // ---- the four pins ----
    input  wire        tck,
    input  wire        tms,
    input  wire        tdi,
    output reg         tdo,
    output wire        tdo_oe,     // drive TDO only while shifting, per spec

    // ---- DMI, in the TCK domain ----
    //
    // Raised for one TCK cycle in Update-DR when the host has shifted in a
    // read or a write. The payload is held stable from then until `dmi_done`
    // comes back, which is what makes the crossing safe.
    output wire [6:0]  dmi_addr,
    output wire [31:0] dmi_wdata,
    output wire [1:0]  dmi_op,     // 1 = read, 2 = write
    output reg         dmi_req,
    input  wire [31:0] dmi_rdata,
    input  wire [1:0]  dmi_resp,   // 0 = ok, 2 = fail, 3 = busy
    input  wire        dmi_busy
);
    // ---- TAP state machine ----
    //
    // The encoding is arbitrary; the transitions are not. Every one of these
    // is from the standard's state diagram, and the reason this is written
    // out longhand rather than compressed is that a wrong edge here produces
    // a TAP that answers IDCODE correctly and then fails at something subtle
    // twenty transactions later.
    localparam [3:0]
        TEST_LOGIC_RESET = 4'h0, RUN_TEST_IDLE = 4'h1,
        SELECT_DR        = 4'h2, CAPTURE_DR    = 4'h3,
        SHIFT_DR         = 4'h4, EXIT1_DR      = 4'h5,
        PAUSE_DR         = 4'h6, EXIT2_DR      = 4'h7,
        UPDATE_DR        = 4'h8,
        SELECT_IR        = 4'h9, CAPTURE_IR    = 4'hA,
        SHIFT_IR         = 4'hB, EXIT1_IR      = 4'hC,
        PAUSE_IR         = 4'hD, EXIT2_IR      = 4'hE,
        UPDATE_IR        = 4'hF;

    reg [3:0] state, next;

    always @(*) begin
        case (state)
            TEST_LOGIC_RESET: next = tms ? TEST_LOGIC_RESET : RUN_TEST_IDLE;
            RUN_TEST_IDLE:    next = tms ? SELECT_DR        : RUN_TEST_IDLE;
            SELECT_DR:        next = tms ? SELECT_IR        : CAPTURE_DR;
            CAPTURE_DR:       next = tms ? EXIT1_DR         : SHIFT_DR;
            SHIFT_DR:         next = tms ? EXIT1_DR         : SHIFT_DR;
            EXIT1_DR:         next = tms ? UPDATE_DR        : PAUSE_DR;
            PAUSE_DR:         next = tms ? EXIT2_DR         : PAUSE_DR;
            EXIT2_DR:         next = tms ? UPDATE_DR        : SHIFT_DR;
            UPDATE_DR:        next = tms ? SELECT_DR        : RUN_TEST_IDLE;
            SELECT_IR:        next = tms ? TEST_LOGIC_RESET : CAPTURE_IR;
            CAPTURE_IR:       next = tms ? EXIT1_IR         : SHIFT_IR;
            SHIFT_IR:         next = tms ? EXIT1_IR         : SHIFT_IR;
            EXIT1_IR:         next = tms ? UPDATE_IR        : PAUSE_IR;
            PAUSE_IR:         next = tms ? EXIT2_IR         : PAUSE_IR;
            EXIT2_IR:         next = tms ? UPDATE_IR        : SHIFT_IR;
            UPDATE_IR:        next = tms ? SELECT_DR        : RUN_TEST_IDLE;
            default:          next = TEST_LOGIC_RESET;
        endcase
    end

    // No reset pin. JTAG's reset is five TCK cycles with TMS high, which the
    // state machine above reaches from anywhere - that is what the four
    // self-loops on TEST_LOGIC_RESET are for. TRST is optional in the
    // standard and this design does not wire one, so `state` powers up
    // wherever it powers up and the host's first act is always five ones.
    initial state = TEST_LOGIC_RESET;
    always @(posedge tck) state <= next;

    // ---- instruction register ----
    localparam [4:0] IR_BYPASS = 5'h1F,
                     IR_IDCODE = 5'h01,
                     IR_DTMCS  = 5'h10,
                     IR_DMI    = 5'h11;

    reg [4:0] ir_shift, ir;
    initial ir = IR_IDCODE;

    always @(posedge tck) begin
        if (state == TEST_LOGIC_RESET) begin
            // The standard requires IDCODE (or BYPASS) to be selected after a
            // test-logic reset. IDCODE, so that a host that knows nothing
            // about this chip can identify it by scanning DR immediately.
            ir <= IR_IDCODE;
        end else if (state == CAPTURE_IR) begin
            // The two low bits must capture as 01. Hosts check it to detect a
            // broken chain.
            ir_shift <= 5'b00001;
        end else if (state == SHIFT_IR) begin
            ir_shift <= {tdi, ir_shift[4:1]};
        end else if (state == UPDATE_IR) begin
            ir <= ir_shift;
        end
    end

    // ---- dtmcs ----
    //
    // Read-only here except for the two control bits, neither of which has
    // anything to reset in this implementation:
    //
    //   [3:0]   version    1 = debug spec 0.13
    //   [9:4]   abits      7 address bits on the DMI
    //   [11:10] dmistat    the last DMI operation's status, sticky
    //   [14:12] idle       cycles the host should spend in Run-Test/Idle
    //                      after a DMI access. 5 is generous for a 25 MHz
    //                      system clock against a 10 MHz TCK and costs a host
    //                      nothing; too small and every access reports busy.
    //   [16]    dmireset   write 1 to clear a sticky error
    //   [17]    dmihardreset
    localparam [3:0] DTMCS_VERSION = 4'd1;
    localparam [5:0] DTMCS_ABITS   = 6'd7;
    localparam [2:0] DTMCS_IDLE    = 3'd5;

    reg [1:0] dmistat;          // sticky, cleared by dmireset

    // 17 + 3 + 2 + 6 + 4 = 32. This said 14'b0 and therefore built a 29-bit
    // value, which was assigned to a 32-bit wire and zero-extended into the
    // right answer - correct by accident, and only visible because Verilator
    // counts. Icarus and the JTAG testbench were both perfectly happy.
    wire [31:0] dtmcs_value = {17'b0, DTMCS_IDLE, dmistat,
                               DTMCS_ABITS, DTMCS_VERSION};

    // ---- the data registers ----
    //
    // One shift register, 41 bits, wide enough for the widest of them. The
    // narrower registers use the low bits and the host shifts exactly as many
    // as it needs - which is what makes a chain of mixed-width TAPs work at
    // all.
    localparam integer DMI_BITS = 41;   // 7 address + 32 data + 2 op

    reg [DMI_BITS-1:0] dr;

    // What Capture-DR loads, by instruction.
    reg [DMI_BITS-1:0] dr_capture;
    always @(*) begin
        case (ir)
            IR_IDCODE: dr_capture = {9'b0, IDCODE};
            IR_DTMCS:  dr_capture = {9'b0, dtmcs_value};
            // A read's data arrives here on the *next* transaction, which is
            // how the DMI works: the host shifts a read in, waits, and shifts
            // the result out with its next access. `dmi_busy` reports that it
            // was not ready.
            IR_DMI:    dr_capture = {dmi_addr_r, dmi_rdata,
                                     dmi_busy ? 2'd3 : dmi_resp};
            default:   dr_capture = {DMI_BITS{1'b0}};   // BYPASS: one 0 bit
        endcase
    end

    // How many bits of `dr` actually shift, by instruction. Getting this
    // wrong shifts a host's data into the wrong bit positions and looks like
    // a chip that answers plausible nonsense.
    reg [5:0] dr_len;
    always @(*) begin
        case (ir)
            IR_IDCODE: dr_len = 6'd32;
            IR_DTMCS:  dr_len = 6'd32;
            // Part-select rather than a bare integer localparam, which is
            // 32 bits wide and truncates into this 6-bit reg.
            IR_DMI:    dr_len = DMI_BITS[5:0];
            default:   dr_len = 6'd1;    // BYPASS
        endcase
    end

    reg [6:0] dmi_addr_r;

    always @(posedge tck) begin
        if (state == TEST_LOGIC_RESET) begin
            dmistat <= 2'b00;
        end else if (state == CAPTURE_DR) begin
            dr <= dr_capture;
        end else if (state == SHIFT_DR) begin
            // Shift right through the *selected width*, so the bit leaving
            // TDO is always dr[0] and the bit entering lands at dr[len-1].
            dr <= (dr >> 1) | ({{(DMI_BITS-1){1'b0}}, tdi} << (dr_len - 1));
        end else if (state == UPDATE_DR) begin
            if (ir == IR_DTMCS) begin
                // dmireset (bit 16) clears the sticky status. dmihardreset
                // (bit 17) would abort an in-flight operation; there is
                // nothing here that can be in flight from this side, so it is
                // accepted and does the same thing.
                if (dr[16] || dr[17]) dmistat <= 2'b00;
            end else if (ir == IR_DMI) begin
                dmi_addr_r <= dr[40:34];
                // Sticky: once an access has failed or been missed, every
                // later read reports it until the host clears it. That is
                // what stops a host silently believing a value it never got.
                if (dmi_busy)               dmistat <= 2'd3;
                else if (dmi_resp != 2'd0)  dmistat <= dmi_resp;
            end
        end
    end

    assign dmi_addr  = dr[40:34];
    assign dmi_wdata = dr[33:2];
    assign dmi_op    = dr[1:0];

    // A request is one TCK pulse in Update-DR, and only for a real operation.
    // op 0 is the nop the host shifts to collect a previous result, and
    // issuing a bus access for it would double every read.
    always @(posedge tck) begin
        dmi_req <= (state == EXIT1_DR) && (ir == IR_DMI) &&
                   (dr[1:0] != 2'd0) && !dmi_busy;
    end

    // ---- TDO ----
    //
    // Changes on the falling edge of TCK so the host, which samples on the
    // rising edge, sees a bit that has been stable for half a period. This is
    // the one place in the file where the *other* edge is used, and it is not
    // optional - a TAP that drives TDO from the rising edge works on a bench
    // cable and fails on a long one.
    always @(negedge tck) begin
        tdo <= (state == SHIFT_IR) ? ir_shift[0] : dr[0];
    end

    // Undriven except while shifting, so several TAPs can share a chain.
    assign tdo_oe = (state == SHIFT_IR) || (state == SHIFT_DR);
endmodule
