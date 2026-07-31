// Adapts the existing rtl/clint.v, rtl/plic.v and rtl/uart.v - all of which
// share the same simple `addr/wdata/we/re/rdata` convention from before this
// SoC existed - onto a Wishbone B4 classic slave port. Instantiated once per
// peripheral so those three modules needed no changes at all to join the bus.
//
// Zero wait states, matching the peripherals themselves (all three answer
// combinationally).
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
module wb_periph_bridge (
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

    assign p_addr  = wb_adr;
    assign p_wdata = wb_dat_w;
    assign p_we    = active &&  wb_we;
    assign p_re    = active && !wb_we && data_master;

    assign wb_dat_r = p_rdata;
    assign wb_ack   = active;
endmodule
