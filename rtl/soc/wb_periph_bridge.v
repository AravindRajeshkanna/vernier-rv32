// Adapts the existing rtl/clint.v, rtl/plic.v and rtl/uart.v - all of which
// share the same simple `addr/wdata/we/re/rdata` convention from before this
// SoC existed - onto a Wishbone B4 classic slave port. Instantiated once per
// peripheral so those three modules needed no changes at all to join the bus.
//
// One wait state, and it is a timing fix rather than a convenience.
//
// This used to be `assign wb_ack = wb_cyc && wb_stb` - zero wait states,
// matching the peripherals, which all answer combinationally. That made a CPU
// data access to MMIO a single combinational round trip: arbitration, address
// decode, the peripheral, the ack, back into `dbus_wait`, into
// `ex_busy_stall`, into `id_ex_stall`, and out to every pipeline register's
// enable. nextpnr put that chain in the critical path of every one of six
// placement seeds, worth about 22 ns of a 42.8 ns path - see 'Both shapes
// share a tail' in fpga/README.md.
//
// Registering the ack cuts the chain at the peripheral. The cost is one extra
// cycle per MMIO access, which is not on any hot path: CLINT, PLIC and the
// UART are read by trap handlers and drivers, not by loops that matter.
// rtl/soc/wb_ram.v has used the same `ack_r <= active && !ack_r` shape since
// before this, so the interconnect and rtl/soc/cpu_wb.v already handle a
// multi-cycle ack - this adds no new case to either.
//
// ---- what the extra cycle would have broken, and how it does not ----
//
// `wb_stb` stays asserted for both cycles, so anything derived straight from
// it now fires twice. For `p_we` that would repeat a write; for `p_re` it
// would claim two interrupts or eat two received bytes. Both strobes are
// therefore gated on `first` - the cycle before the ack - so each still
// pulses exactly once per access.
//
// The read *data* needs the same care for a subtler reason. `p_rdata` is
// combinational from the peripheral's current state, and a read side effect
// lands on the clock edge at the end of `first`. So in the second cycle the
// PLIC's claim register already reads zero, and returning `p_rdata` then
// would hand the CPU the value *after* its own read. `rdata_r` captures it on
// the edge that ends `first`, which is the last moment it is still the
// pre-side-effect value.
//
// `re` is the subtle part. Two of these peripherals have a *read side
// effect*: the PLIC's claim register claims an interrupt when read, and the
// UART's RXDATA clears the received-byte flag. So `re` must mean "a real
// load instruction is reading this register right now", not merely "this
// address is on the bus". Two things gate it here:
//
//  - `data_master`, from the interconnect, so a stray instruction fetch that
//    lands in MMIO space can't claim an interrupt or eat a received byte.
//  - `!wb_we`, so the read strobe never fires during a write.
//
// This is the same hazard the peripherals' own headers already warn about,
// just enforced at the bus boundary now that fetches share the bus.
//
// ---- this shipped once, broke Linux, and was reverted for the wrong reason
//
// The first version of this change (#49) closed timing and was reverted
// (#51) because supervisor-external interrupts went from 50 to 87,339 in
// one Linux boot. The claim/complete handshake above was not the cause: a
// bus trace of the failing boot shows it working correctly throughout - 24
// clean claim/complete pairs, then 87,339 claims of zero. The actual bug was
// in rtl/csr_file.v, not here - an mip CSRRS/CSRRC computed its write-back
// from the OR of the software and hardware SEIP halves, so an RMW that
// landed while this bridge's extra cycle left the PLIC's line high for
// slightly longer latched that line into the software half permanently.
// Fixed there, with software/soc/plictest.c section 3b as the regression;
// see docs/practices.md §45. This bridge was an innocent bystander that
// happened to change the boot's timing enough to make a pre-existing race
// land differently - which is also why four earlier, unrelated attempts at
// the fetch path produced a similar-looking symptom and were reverted too.
module wb_periph_bridge (
    input  wire        clk,
    input  wire        rst,
    input  wire        wb_cyc,
    input  wire        wb_stb,
    input  wire        wb_we,
    input  wire [31:0] wb_adr,
    input  wire [31:0] wb_dat_w,
    output wire [31:0] wb_dat_r,
    output wire        wb_ack,
    input  wire        data_master,

    output wire [31:0] p_addr,
    output wire [31:0] p_wdata,
    output wire        p_we,
    output wire        p_re,
    input  wire [31:0] p_rdata
);
    wire active = wb_cyc && wb_stb;

    reg ack_r;
    always @(posedge clk) begin
        if (rst) ack_r <= 1'b0;
        else     ack_r <= active && !ack_r;
    end
    assign wb_ack = ack_r;

    // The first cycle of an access, and only the first. Everything with a
    // side effect hangs off this rather than off `active`.
    wire first = active && !ack_r;

    assign p_addr  = wb_adr;
    assign p_wdata = wb_dat_w;
    assign p_we    = first &&  wb_we;
    assign p_re    = first && !wb_we && data_master;

    reg [31:0] rdata_r;
    always @(posedge clk) if (first) rdata_r <= p_rdata;
    assign wb_dat_r = rdata_r;
endmodule
