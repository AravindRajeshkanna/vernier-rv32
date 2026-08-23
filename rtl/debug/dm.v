// A RISC-V Debug Module, System Bus Access only.
//
// The host reaches this through rtl/debug/jtag_tap.v and rtl/debug/dmi_cdc.v.
// What it provides is a **memory port that does not go through the CPU**: any
// address the interconnect decodes can be read or written from a debugger
// while the core is running, spinning, or wedged.
//
// ---- Why this half and not the other ----
//
// The RISC-V External Debug Support specification describes two ways for a
// debugger to touch memory. Abstract commands and the program buffer make the
// *hart* do it, which means halting it, which means debug mode, `dcsr`,
// `dpc`, `dret`, and a debug ROM the core vectors into. System Bus Access
// does it with a bus master that has nothing to do with the hart at all.
//
// This implements the second. Not as a stepping stone - it is the half that
// answers the questions this project has actually been stuck on. "OpenSBI
// hangs before its console comes up" and "the boot ROM prints nothing" are
// both *the memory is fine and I cannot see it* problems, and none of them
// needed the hart stopped.
//
// The other half is deliberately deferred, and the reason is measurable
// rather than aesthetic: halt/resume lands on the fetch redirect and the
// register file write port of a design where two of six placement seeds
// already fail to close 25 MHz (fpga/README.md). Adding to that path before
// the margin is fixed would turn an intermittent build failure into a
// permanent one. This module touches the CPU nowhere - it is a fourth
// Wishbone master and one reset term.
//
// ---- What a host can do with it ----
//
//   * read and write SDRAM, block RAM, and every peripheral register
//   * dump a device tree, a page table, or a kernel's log buffer out of a
//     machine that is not talking
//   * load a program without the boot ROM's serial loader and its 22 minutes
//   * assert `ndmreset` to restart the SoC without touching the board
//
// ---- What it cannot ----
//
//   * halt, resume, or single-step the hart
//   * read or write CPU registers or CSRs
//   * set a breakpoint
//
// `dmstatus` reports all of that honestly - `allrunning` is hardwired 1 and
// `haltreq` is accepted and ignored - so a debugger that tries to halt gets a
// hart that never halts rather than a lie. OpenOCD will not drive this as a
// normal RISC-V target for that reason; fpga/openocd/README.md says what it
// is good for instead.
module dm (
    input  wire        clk,
    input  wire        rst,

    // ---- DMI, already in this clock domain ----
    input  wire        dmi_valid,
    input  wire [6:0]  dmi_addr,
    input  wire [31:0] dmi_wdata,
    input  wire [1:0]  dmi_op,       // 1 = read, 2 = write
    output reg         dmi_done,
    output reg  [31:0] dmi_rdata,
    output reg  [1:0]  dmi_resp,     // 0 = ok, 2 = failed

    // ---- Wishbone master ----
    output reg         wb_cyc,
    output reg         wb_stb,
    output reg         wb_we,
    output reg  [31:0] wb_adr,
    output reg  [31:0] wb_dat_w,
    output wire [3:0]  wb_sel,
    input  wire [31:0] wb_dat_r,
    input  wire        wb_ack,

    // Resets everything in the SoC *except* this module and the TAP, which is
    // the spec's rule and the only sensible one: a reset that took the debug
    // path down with it would end the session that asked for it.
    output wire        ndmreset,
    // Cleared by the host writing dmcontrol.dmactive = 0. Nothing here needs
    // it, but a host uses the read-back to tell a Debug Module that exists
    // from a DMI that acks everything.
    output wire        dmactive
);
    // ---- DMI address map ----
    localparam [6:0] A_DMCONTROL  = 7'h10,
                     A_DMSTATUS   = 7'h11,
                     A_HARTINFO   = 7'h12,
                     A_SBCS       = 7'h38,
                     A_SBADDRESS0 = 7'h39,
                     A_SBDATA0    = 7'h3C;

    // ---- dmcontrol ----
    reg dmactive_r, ndmreset_r;
    assign dmactive = dmactive_r;
    // Gated by dmactive: the spec says everything in the DM stays reset while
    // dmactive is 0, and a stray ndmreset from a module the host has not
    // enabled would reset the SoC out from under a running program.
    assign ndmreset = ndmreset_r && dmactive_r;

    // ---- sbcs ----
    //
    // 32-bit accesses only. The bus is word-organised and every sub-word
    // shift in this SoC lives in rtl/soc/cpu_wb.v, on the CPU's side of the
    // interconnect - so a byte access here would need that logic duplicated,
    // and duplicating a shifter to debug the shifter is the wrong direction.
    // sbaccess8/16 read back as unsupported and a host asking for one gets
    // sberror = 4, which is the spec's "requested size not supported".
    localparam [2:0] SBERR_NONE    = 3'd0,
                     SBERR_TIMEOUT = 3'd1,
                     SBERR_BADADDR = 3'd2,
                     SBERR_BADSIZE = 3'd4;

    reg [2:0] sberror;
    reg       sbbusyerror;
    reg       sbreadonaddr, sbreadondata, sbautoincrement;
    reg [2:0] sbaccess;
    reg [31:0] sbaddress;
    reg [31:0] sbdata;

    reg sbbusy;

    wire [31:0] sbcs_value = {
        3'd1,            // [31:29] sbversion = 1, this spec's numbering
        6'b0,            // [28:23]
        sbbusyerror,     // [22]
        sbbusy,          // [21]
        sbreadonaddr,    // [20]
        sbaccess,        // [19:17]
        sbautoincrement, // [16]
        sbreadondata,    // [15]
        sberror,         // [14:12]
        7'd32,           // [11:5] sbasize - 32-bit addresses
        1'b0,            // [4] sbaccess128
        1'b0,            // [3] sbaccess64
        1'b1,            // [2] sbaccess32
        1'b0,            // [1] sbaccess16
        1'b0             // [0] sbaccess8
    };

    // ---- dmstatus ----
    //
    // Every "halted" bit is 0 and every "running" bit is 1, permanently,
    // because there is no hart control here. A host reads this and knows.
    // Written as explicit bit assignments rather than one concatenation,
    // because the first version of this was a 34-bit concatenation whose
    // comments named bit positions that did not match the vector it built.
    // A field in the wrong place here is a host that reads a plausible
    // wrong answer about whether the hart is running.
    //
    //   [3:0]  version = 2 (debug spec 0.13)
    //   [4]    confstrptrvalid      [5]  hasresethaltreq
    //   [6]    authenticated        [7]  authbusy
    //   [8]    anyhalted            [9]  allhalted
    //   [10]   anyrunning           [11] allrunning
    //   [12]   anyunavail           [13] allunavail
    //   [14]   anynonexistent       [15] allnonexistent
    //   [16]   anyresumeack         [17] allresumeack
    //   [18]   anyhavereset         [19] allhavereset
    // Built by named bit position rather than as one concatenation, because
    // the first version of this *was* a concatenation - 34 bits wide, with
    // comments naming positions that did not match the vector it built. A
    // field in the wrong place here is a host reading a plausible wrong
    // answer about whether the hart is running.
    localparam [31:0] DMSTATUS =
          (32'd2      <<  0) |   // [3:0]   version = 2, debug spec 0.13
          (32'd0      <<  4) |   // [4]     confstrptrvalid - no config string
          (32'd0      <<  5) |   // [5]     hasresethaltreq - cannot halt at all
          (32'd1      <<  6) |   // [6]     authenticated - nothing to authenticate
          (32'd0      <<  7) |   // [7]     authbusy
          (32'd0      <<  8) |   // [9:8]   any/allhalted - no hart control
          (32'd3      << 10) |   // [11:10] any/allrunning - always, for the same reason
          (32'd0      << 12) |   // [13:12] any/allunavail
          (32'd0      << 14) |   // [15:14] any/allnonexistent - the hart exists
          (32'd3      << 16) |   // [17:16] any/allresumeack - nothing to resume
          (32'd0      << 18);    // [19:18] any/allhavereset

    // ---- the bus side ----
    //
    // One access at a time, no pipelining, no posted writes. `sbbusy` is the
    // host's view of it and the host is told to poll: a DMI transaction is
    // ~41 TCK cycles, which at any plausible TCK is far longer than a
    // Wishbone access at 25 MHz, so in practice it is never busy by the time
    // anybody looks.
    localparam [1:0] S_IDLE = 2'd0, S_ACCESS = 2'd1;
    reg [1:0] sb_state;
    reg       sb_we_pending;

    assign wb_sel = 4'b1111;

    // Start a bus access. Address is whatever `sbaddress` holds *now*, which
    // is the spec's rule and the one that makes autoincrement work: the
    // increment happens when the access finishes, so a burst of reads walks
    // upward without the host writing an address each time.
    reg        sb_start;
    reg        sb_start_we;
    reg [31:0] sb_start_data;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sb_state      <= S_IDLE;
            sbbusy        <= 1'b0;
            wb_cyc        <= 1'b0;
            wb_stb        <= 1'b0;
            wb_we         <= 1'b0;
            wb_adr        <= 32'b0;
            wb_dat_w      <= 32'b0;
            sb_we_pending <= 1'b0;
        end else if (!dmactive_r || ndmreset_r) begin
            // Held idle while the module is disabled, and while the host is
            // asserting ndmreset: rtl/soc/soc_top.v resets the interconnect
            // along with everything else, so an access started here would be
            // waiting for an ack from a bus that has just been reset.
            sb_state <= S_IDLE;
            sbbusy   <= 1'b0;
            wb_cyc   <= 1'b0;
            wb_stb   <= 1'b0;
        end else begin
            case (sb_state)
                S_IDLE: begin
                    if (sb_start) begin
                        wb_cyc        <= 1'b1;
                        wb_stb        <= 1'b1;
                        wb_we         <= sb_start_we;
                        wb_adr        <= sbaddress;
                        wb_dat_w      <= sb_start_data;
                        sb_we_pending <= sb_start_we;
                        sbbusy        <= 1'b1;
                        sb_state      <= S_ACCESS;
                    end
                end
                S_ACCESS: begin
                    if (wb_ack) begin
                        wb_cyc   <= 1'b0;
                        wb_stb   <= 1'b0;
                        sbbusy   <= 1'b0;
                        sb_state <= S_IDLE;
                    end
                end
                default: sb_state <= S_IDLE;
            endcase
        end
    end

    // Capture and autoincrement on the completing edge, outside the state
    // machine so the read data lands whether or not anything else changes.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sbdata    <= 32'b0;
            sbaddress <= 32'b0;
        end else begin
            if ((sb_state == S_ACCESS) && wb_ack) begin
                if (!sb_we_pending) sbdata <= wb_dat_r;
                if (sbautoincrement) sbaddress <= sbaddress + 32'd4;
            end
            // A host write to sbaddress0 wins over an autoincrement in the
            // same cycle; it is the more recent instruction.
            if (dmi_valid && (dmi_op == 2'd2) && (dmi_addr == A_SBADDRESS0))
                sbaddress <= dmi_wdata;
            if (dmi_valid && (dmi_op == 2'd2) && (dmi_addr == A_SBDATA0))
                sbdata <= dmi_wdata;
        end
    end

    // ---- DMI register access ----
    //
    // Always answers in one cycle. A DMI transaction never waits for the bus:
    // reading sbdata0 returns the value the *previous* access fetched and
    // optionally starts the next one, which is the spec's model and the
    // reason a host can pipeline reads at full JTAG rate.
    reg [31:0] rd;
    always @(*) begin
        case (dmi_addr)
            A_DMCONTROL:  rd = {30'b0, ndmreset_r, dmactive_r};
            A_DMSTATUS:   rd = DMSTATUS;
            A_HARTINFO:   rd = 32'b0;
            A_SBCS:       rd = sbcs_value;
            A_SBADDRESS0: rd = sbaddress;
            A_SBDATA0:    rd = sbdata;
            default:      rd = 32'b0;
        endcase
    end

    wire size_ok = (sbaccess == 3'd2);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dmi_done        <= 1'b0;
            dmi_rdata       <= 32'b0;
            dmi_resp        <= 2'b0;
            dmactive_r      <= 1'b0;
            ndmreset_r      <= 1'b0;
            sberror         <= SBERR_NONE;
            sbbusyerror     <= 1'b0;
            sbreadonaddr    <= 1'b0;
            sbreadondata    <= 1'b0;
            sbautoincrement <= 1'b0;
            sbaccess        <= 3'd2;    // 32-bit, the only one supported
            sb_start        <= 1'b0;
            sb_start_we     <= 1'b0;
            sb_start_data   <= 32'b0;
        end else begin
            sb_start <= 1'b0;
            dmi_done <= 1'b0;

            if (dmi_valid) begin
                dmi_done  <= 1'b1;
                dmi_rdata <= rd;
                dmi_resp  <= 2'd0;

                if (dmi_op == 2'd2) begin           // ---- write ----
                    case (dmi_addr)
                        A_DMCONTROL: begin
                            dmactive_r <= dmi_wdata[0];
                            ndmreset_r <= dmi_wdata[1];
                            // Everything in the DM holds reset while
                            // dmactive is low, which is what lets a host
                            // recover a wedged Debug Module without a power
                            // cycle.
                            if (!dmi_wdata[0]) begin
                                sberror         <= SBERR_NONE;
                                sbbusyerror     <= 1'b0;
                                sbreadonaddr    <= 1'b0;
                                sbreadondata    <= 1'b0;
                                sbautoincrement <= 1'b0;
                                sbaccess        <= 3'd2;
                            end
                        end
                        A_SBCS: begin
                            // W1C on the two error fields, per the spec.
                            if (dmi_wdata[14:12] != 3'd0) sberror <= SBERR_NONE;
                            if (dmi_wdata[22])            sbbusyerror <= 1'b0;
                            sbreadonaddr    <= dmi_wdata[20];
                            sbaccess        <= dmi_wdata[19:17];
                            sbautoincrement <= dmi_wdata[16];
                            sbreadondata    <= dmi_wdata[15];
                        end
                        A_SBADDRESS0: begin
                            // Writing the address triggers a read when
                            // sbreadonaddr is set - the idiom a host uses to
                            // dump a region.
                            if (sbbusy) sbbusyerror <= 1'b1;
                            else if (sbreadonaddr) begin
                                if (!size_ok) sberror <= SBERR_BADSIZE;
                                else begin
                                    sb_start      <= 1'b1;
                                    sb_start_we   <= 1'b0;
                                end
                            end
                        end
                        A_SBDATA0: begin
                            if (sbbusy) sbbusyerror <= 1'b1;
                            else if (!size_ok) sberror <= SBERR_BADSIZE;
                            else begin
                                sb_start      <= 1'b1;
                                sb_start_we   <= 1'b1;
                                sb_start_data <= dmi_wdata;
                            end
                        end
                        default: ;
                    endcase
                end else if (dmi_op == 2'd1) begin  // ---- read ----
                    if (dmi_addr == A_SBDATA0) begin
                        if (sbbusy) sbbusyerror <= 1'b1;
                        else if (sbreadondata) begin
                            if (!size_ok) sberror <= SBERR_BADSIZE;
                            else begin
                                sb_start    <= 1'b1;
                                sb_start_we <= 1'b0;
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
