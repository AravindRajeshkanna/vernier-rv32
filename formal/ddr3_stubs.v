// Stand-ins for the parts of rtl/soc/ddr3_ecp5_top.v that the control-plane proof
// does not need, and that the formal flow cannot follow. Formal only: nothing else
// reads this file.
//
// What the proof looks at is the controller between the request ports and the
// command pins - the request gating, the two command sequencers, the refresh
// scheduler, the read-burst extender and the command mux. Everything here either
// sits outside that (the PHY, the DQ/DQS data path) or is the long, one-off
// power-up behaviour that has already finished by the time a request can be made
// (initialisation, and calibration): a bounded proof that started from reset would
// spend its whole depth inside the 500 us wait before CKE and never see a request.
//
// So the two power-up modules are replaced by what they hold for the rest of time:
//   - ddr3_init_seq: `ready` high, no command, CKE high - exactly its
//     S_READY state, which never reassigns them;
//   - ddr3_read_calib: both lanes done, no error, no request of its own, the request port not its (`active` low) -
//     its state once the sweep is over and kept.
// The claim this makes is therefore "after initialisation and calibration", which is
// the only time a caller's request ports do anything (`calib_ok` and the sequencers' own
// reset hold them until then), and the proof says so wherever it is quoted.
//
// The rest have tri-state nets, delays or `===` in their simulation bodies, none of
// which yosys's SMT back end accepts, and none of which the properties depend on.
module ddr3_eclk_pll #(
    parameter CLK_PERIOD_NS = 40
)(
    input  wire clk,
    output wire eclk,
    output wire sclk,
    output wire locked
);
    assign eclk   = clk;
    assign sclk   = clk;
    assign locked = 1'b1;
endmodule

module ddr3_init_seq #(
    parameter CLK_HZ = 25_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        por,
    output wire        cmd_valid,
    output wire [2:0]  cmd_ras_cas_we,
    output wire [2:0]  cmd_ba,
    output wire [15:0] cmd_addr,
    output wire        cmd_cke,
    output wire        cmd_odt,
    output wire        ready
);
    assign cmd_valid         = 1'b0;
    assign cmd_ras_cas_we = 3'b111;
    assign cmd_ba            = 3'b0;
    assign cmd_addr          = 16'b0;
    assign cmd_cke           = 1'b1;
    assign cmd_odt           = 1'b0;
    assign ready             = 1'b1;
    wire _unused_ok = &{1'b0, clk, rst, por, 1'b0};
endmodule

module ddr3_read_calib #(
    parameter [7:0]  PATTERN0    = 8'hA5,
    parameter [7:0]  PATTERN1    = 8'h3C,
    parameter [2:0]  BANK        = 3'd7,
    parameter [15:0] ROW         = 16'h7FFF,
    parameter [15:0] COL         = 16'h03F8,
    parameter        TIMEOUT_CYC = 64
)(
    input  wire        clk,
    input  wire        por,
    input  wire        rst,
    input  wire        busy,
    output wire        write_req,
    output wire        read_req,
    output wire [2:0]  bank,
    output wire [15:0] row,
    output wire [15:0] col,
    output wire [15:0] write_data,
    output wire [1:0]  write_be,
    output wire        active,
    input  wire        rd_done,
    input  wire        valid0,
    input  wire        valid1,
    input  wire [7:0]  q0,
    input  wire [7:0]  q1,
    output wire [2:0]  readclksel0,
    output wire [2:0]  readclksel1,
    output wire        calib_done,
    output wire [2:0]  calib_readclksel,
    output wire        calib_error,
    output wire        calib1_done,
    output wire [2:0]  calib1_readclksel,
    output wire        calib1_error
);
    assign write_req         = 1'b0;
    assign read_req          = 1'b0;
    assign bank              = 3'b0;
    assign row               = 16'b0;
    assign col               = 16'b0;
    assign write_data        = 16'b0;
    assign write_be          = 2'b00;
    assign active            = 1'b0;
    assign readclksel0       = 3'b0;
    assign readclksel1       = 3'b0;
    assign calib_done        = 1'b1;
    assign calib_readclksel  = 3'b0;
    assign calib_error       = 1'b0;
    assign calib1_done       = 1'b1;
    assign calib1_readclksel = 3'b0;
    assign calib1_error      = 1'b0;
    wire _unused_ok = &{1'b0, clk, por, rst, busy, rd_done, valid0, valid1, q0, q1, 1'b0};
endmodule

module ddr3_phy_ecp5 (
    input  wire        clk,
    input  wire        eclk,
    input  wire        rst,
    input  wire        por,
    input  wire        cmd_valid,
    input  wire [2:0]  cmd_ras_cas_we,
    input  wire [2:0]  cmd_ba,
    input  wire [14:0] cmd_addr,
    input  wire        cmd_cke,
    input  wire        cmd_odt,
    output wire        ddr3_ck,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire [2:0]  ddr3_ba,
    output wire [14:0] ddr3_a,
    output wire        ddr3_cke,
    output wire        ddr3_odt
);
    assign ddr3_ck      = 1'b0;
    assign ddr3_ras_n   = 1'b1;
    assign ddr3_cas_n   = 1'b1;
    assign ddr3_we_n    = 1'b1;
    assign ddr3_ba      = 3'b0;
    assign ddr3_a       = 15'b0;
    assign ddr3_cke     = 1'b0;
    assign ddr3_odt     = 1'b0;
    wire _unused_ok = &{1'b0, clk, eclk, rst, por, cmd_valid, cmd_ras_cas_we, cmd_ba,
                        cmd_addr, cmd_cke, cmd_odt, 1'b0};
endmodule

module ddr3_dqs_ecp5 (
    input  wire       eclk,
    input  wire       sclk,
    input  wire       rst,
    input  wire       dqs_pad_i,
    input  wire       read_active,
    input  wire [2:0] readclksel,
    input  wire       ddrdel,
    output wire       dqsr90,
    output wire       dqsw,
    output wire       dqsw270,
    output wire       datavalid,
    output wire       burstdet,
    output wire [2:0] rdpntr,
    output wire [2:0] wrpntr
);
    assign rdpntr     = 3'b0;
    assign wrpntr     = 3'b0;
    assign dqsr90     = 1'b0;
    assign dqsw       = 1'b0;
    assign dqsw270    = 1'b0;
    assign datavalid  = 1'b0;
    assign burstdet   = 1'b0;
    wire _unused_ok = &{1'b0, eclk, sclk, rst, dqs_pad_i, read_active, readclksel, ddrdel, 1'b0};
endmodule

module ddr3_ddrdlla_ecp5 (
    input  wire eclk,
    input  wire rst,
    output wire ddrdel,
    output wire dll_locked
);
    assign ddrdel     = 1'b0;
    assign dll_locked = 1'b1;
    wire _unused_ok = &{1'b0, eclk, rst, 1'b0};
endmodule

module ddr3_dqs_write_ecp5 (
    input  wire sclk,
    input  wire eclk,
    input  wire dqsw,
    input  wire rst,
    input  wire write_start,
    output wire dqs_o,
    output wire dqs_oe,
    output wire dqs_t,
    output wire burst_active,
    output wire active0
);
    assign dqs_o        = 1'b0;
    assign dqs_oe       = 1'b0;
    assign dqs_t        = 1'b1;
    assign burst_active = 1'b0;
    assign active0       = 1'b0;
    wire _unused_ok = &{1'b0, sclk, eclk, dqsw, rst, write_start, 1'b0};
endmodule

module ddr3_dm_drv_ecp5 (
    input  wire sclk,
    input  wire eclk,
    input  wire rst,
    input  wire dqsw270,
    input  wire [3:0] dm_mask,
    output wire dm_o
);
    assign dm_o = 1'b1;
    wire _unused_ok = &{1'b0, sclk, eclk, rst, dqsw270, dm_mask, 1'b0};
endmodule

module ddr3_dq_serdes_ecp5 #(
    parameter DQ_WIDTH = 8
)(
    input  wire                  sclk,
    input  wire                  eclk,
    input  wire                  rst,
    input  wire                  dqsr90,
    input  wire                  dqsw270,
    input  wire [2:0]            rdpntr,
    input  wire [2:0]            wrpntr,
    input  wire [DQ_WIDTH-1:0]   wr_d3, wr_d2, wr_d1, wr_d0,
    input  wire                  wr_en,
    output wire [DQ_WIDTH-1:0]   rd_q3, rd_q2, rd_q1, rd_q0,
    output wire [DQ_WIDTH-1:0]   dq_o,
    output wire [DQ_WIDTH-1:0]   dq_oe,
    output wire [DQ_WIDTH-1:0]   dq_t,
    input  wire [DQ_WIDTH-1:0]   dq_i
);
    assign rd_q3 = {DQ_WIDTH{1'b0}};
    assign rd_q2 = {DQ_WIDTH{1'b0}};
    assign rd_q1 = {DQ_WIDTH{1'b0}};
    assign rd_q0 = {DQ_WIDTH{1'b0}};
    assign dq_o  = {DQ_WIDTH{1'b0}};
    assign dq_oe = {DQ_WIDTH{1'b0}};
    assign dq_t  = {DQ_WIDTH{1'b1}};
    wire _unused_ok = &{1'b0, sclk, eclk, rst, dqsr90, dqsw270, wr_d3, wr_d2, wr_d1,
                        wr_d0, wr_en, dq_i, rdpntr, wrpntr, 1'b0};
endmodule
