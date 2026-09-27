// A place-and-route probe, NOT a board top and NOT a bring-up test.
//
// rtl/soc/ddr3_ecp5_top.v has ~150 request, data and status ports that a board top would
// wire to a bring-up engine, not to pins; left as ports they would all become pads, and
// nextpnr would put 3.3 V pads in the 1.5 V DDR banks. This wraps it so that only the DDR3
// pins and three control pins are pads: a shift register feeds every request input, and every
// status output is XOR-reduced into `dout`, so nothing is optimised away.
//
// It does not exercise the controller and proves nothing about behaviour. What it does is
// let synthesis, placement and routing look at the real PHY with the real pins:
// ./fpga/synth/ddr3_pnr_probe.sh. Docs/roadmap.md, Part 21.
module ecpix5_ddr3_probe (
    input  wire        clk,
    input  wire        rst,
    input  wire        din,
    output wire        dout,

    output wire        ddr3_ck,
    output wire        ddr3_ck_n,
    output wire        ddr3_cs_n,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire [2:0]  ddr3_ba,
    output wire [15:0] ddr3_a,
    output wire        ddr3_cke,
    output wire        ddr3_reset_n,
    output wire        ddr3_odt,
    inout  wire [7:0]  ddr3_dq,
    inout  wire        ddr3_dqs,
    output wire        ddr3_dm
);
    reg [127:0] sh;
    always @(posedge clk) sh <= {sh[126:0], din};

    wire        write_busy, read_busy, read_data_valid, refresh_busy;
    wire        pll_locked, dll_locked, init_ready, calib_done, calib_error;
    wire [7:0]  read_data;
    wire [2:0]  calib_readclksel;

    ddr3_ecp5_top TOP (
        .clk(clk), .rst(rst),
        .ddr3_ck(ddr3_ck), .ddr3_ck_n(ddr3_ck_n), .ddr3_cs_n(ddr3_cs_n),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_ba(ddr3_ba), .ddr3_a(ddr3_a),
        .ddr3_cke(ddr3_cke), .ddr3_reset_n(ddr3_reset_n), .ddr3_odt(ddr3_odt),
        .ddr3_dq(ddr3_dq), .ddr3_dqs(ddr3_dqs), .ddr3_dm(ddr3_dm),
        .write_req(sh[0]), .write_bank(sh[3:1]), .write_row(sh[19:4]),
        .write_col(sh[35:20]), .write_data(sh[43:36]), .write_busy(write_busy),
        .read_req(sh[44]), .read_bank(sh[47:45]), .read_row(sh[63:48]),
        .read_col(sh[79:64]), .read_busy(read_busy), .read_data(read_data),
        .read_data_valid(read_data_valid),
        .refresh_busy(refresh_busy),
        .pll_locked(pll_locked), .dll_locked(dll_locked), .init_ready(init_ready),
        .calib_done(calib_done), .calib_readclksel(calib_readclksel),
        .calib_error(calib_error)
    );

    assign dout = ^{write_busy, read_busy, read_data_valid, refresh_busy, pll_locked,
                    dll_locked, init_ready, calib_done, calib_error, read_data,
                    calib_readclksel};
endmodule
