// Wishbone B4 "classic" shared-bus interconnect: 2 masters, NUM_SLAVES
// slaves, fixed-priority arbitration and a flat addr[31:24] address decode.
//
// Shared bus, not a crossbar: exactly one master owns the bus at a time, so
// `adr`/`dat_w`/`we`/`sel` are a single broadcast copy and only `stb` is
// decoded per slave. A crossbar would let an instruction fetch and a data
// access to *different* slaves proceed in the same cycle; this doesn't, so a
// load/store costs the fetch behind it a cycle. That's the classic
// single-port-memory SoC tradeoff, taken deliberately here for a much
// smaller and more obviously-correct interconnect.
//
// Arbitration is pure combinational fixed priority - master 1 (data) always
// outranks master 0 (instruction), with no sticky grant. Two consequences
// worth being explicit about, because both are load-bearing:
//
//  - **Atomics are safe for free.** cpu_wb.v holds `cyc` asserted across
//    both phases of an AMO's read-modify-write. Since the data master is
//    top priority, holding `cyc` means it simply keeps winning, so no other
//    master can slip a write into the gap between the read and the write
//    back. That is the Wishbone locked-cycle idiom, and here it needs no
//    lock signal at all - priority alone implements it. (A *sticky* grant
//    would have been the other way to get this, but stickiness combined
//    with combinational re-arbitration on `ack` creates a combinational
//    loop: ack -> grant -> stb -> ack.)
//  - **The instruction master must only reach zero-wait-state slaves.**
//    Because there is no stickiness, master 0 can lose the bus mid-transfer
//    if master 1 requests. That is harmless only if master 0's transfers
//    complete in the cycle they are granted, which holds as long as it just
//    reaches ROM and RAM (both ack combinationally). Don't map a
//    multi-cycle slave where instructions get fetched from.
//
// It also can't starve the fetch path despite always losing: a data access
// is one transaction that then completes, and while it is outstanding
// cpu_wb.v freezes the whole pipeline, so nothing can queue behind it. The
// CPU can only make progress by fetching, so the data master necessarily
// goes idle.
//
// An access that decodes to no slave is acknowledged immediately with zero
// data rather than left hanging. A bus that never acks would wedge the CPU
// forever (its pipeline is frozen waiting on `ack`), turning a stray pointer
// into a silent hang instead of something the running program can survive.
module wb_interconnect #(
    parameter NUM_SLAVES = 7
)(
    // ---- master 0: instruction fetch ----
    input  wire        m0_cyc,
    input  wire        m0_stb,
    input  wire [31:0] m0_adr,
    output wire [31:0] m0_dat_r,
    output wire        m0_ack,

    // ---- master 1: data ----
    input  wire        m1_cyc,
    input  wire        m1_stb,
    input  wire        m1_we,
    input  wire [31:0] m1_adr,
    input  wire [31:0] m1_dat_w,
    input  wire [3:0]  m1_sel,
    output wire [31:0] m1_dat_r,
    output wire        m1_ack,

    // ---- shared slave bus ----
    // `s_base` is the addr[31:24] value each slave answers to, packed 8 bits
    // per slave (slave i occupies bits [8*i +: 8]).
    input  wire [NUM_SLAVES*8-1:0]  s_base,
    output wire                      s_cyc,
    output wire [NUM_SLAVES-1:0]     s_stb,
    output wire                      s_we,
    output wire [31:0]               s_adr,
    output wire [31:0]               s_dat_w,
    output wire [3:0]                s_sel,
    input  wire [NUM_SLAVES*32-1:0]  s_dat_r,
    input  wire [NUM_SLAVES-1:0]     s_ack,

    // High when the *data* master owns the bus. Peripherals with a
    // read side effect (the PLIC's claim register, the UART's RXDATA) gate
    // their read strobe on this, so a stray instruction fetch into MMIO
    // space can't silently claim an interrupt or eat a received byte.
    output wire                      s_data_master
);
    // ---- arbitration: combinational fixed priority, data over fetch ----
    wire sel_m1 = m1_cyc;
    wire sel_m0 = m0_cyc && !m1_cyc;

    assign s_data_master = sel_m1;

    assign s_cyc   = sel_m1 ? m1_cyc : (sel_m0 ? m0_cyc : 1'b0);
    wire   cur_stb = sel_m1 ? m1_stb : (sel_m0 ? m0_stb : 1'b0);
    assign s_we    = sel_m1 ? m1_we    : 1'b0;      // fetches are always reads
    assign s_adr   = sel_m1 ? m1_adr   : m0_adr;
    assign s_dat_w = sel_m1 ? m1_dat_w : 32'b0;
    assign s_sel   = sel_m1 ? m1_sel   : 4'b1111;

    // ---- address decode ----
    reg  [NUM_SLAVES-1:0] hit;
    integer i;
    always @(*) begin
        for (i = 0; i < NUM_SLAVES; i = i + 1)
            hit[i] = (s_adr[31:24] == s_base[8*i +: 8]);
    end

    assign s_stb = {NUM_SLAVES{cur_stb}} & hit;

    wire decoded = |hit;

    // ---- response mux ----
    reg [31:0] rsp_dat;
    reg        rsp_ack;
    always @(*) begin
        rsp_dat = 32'b0;
        rsp_ack = 1'b0;
        for (i = 0; i < NUM_SLAVES; i = i + 1) begin
            if (hit[i]) begin
                rsp_dat = s_dat_r[32*i +: 32];
                rsp_ack = s_ack[i];
            end
        end
    end

    // Unmapped address: ack straight away so a bad access surfaces as garbage
    // data rather than a hung core (see the header note).
    wire        fin_ack = cur_stb && (decoded ? rsp_ack : 1'b1);
    wire [31:0] fin_dat = decoded ? rsp_dat : 32'b0;

    assign m0_dat_r = fin_dat;
    assign m1_dat_r = fin_dat;
    assign m0_ack   = sel_m0 && fin_ack;
    assign m1_ack   = sel_m1 && fin_ack;
endmodule
