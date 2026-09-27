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
// spend its whole depth inside the 200 us reset wait and never see a request.
//
// So the two power-up modules are replaced by what they hold for the rest of time:
//   - ddr3_init_seq: `ready` high, no command, CKE and RESET# high - exactly its
//     S_READY state, which never reassigns them;
//   - ddr3_read_calib: `calib_done` high, no error, nothing driven - its idle state.
// The claim this makes is therefore "after initialisation and calibration", which is
// the only time the request ports do anything (`rst_cmd` holds the sequencers in
// reset until then), and the proof says so wherever it is quoted.
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
    output wire        cmd_valid,
    output wire [2:0]  cmd_cs_ras_cas_we,
    output wire [2:0]  cmd_ba,
    output wire [15:0] cmd_addr,
    output wire        cmd_cke,
    output wire        cmd_reset_n,
    output wire        cmd_odt,
    output wire        ready
);
    assign cmd_valid         = 1'b0;
    assign cmd_cs_ras_cas_we = 3'b111;
    assign cmd_ba            = 3'b0;
    assign cmd_addr          = 16'b0;
    assign cmd_cke           = 1'b1;
    assign cmd_reset_n       = 1'b1;
    assign cmd_odt           = 1'b0;
    assign ready             = 1'b1;
    wire _unused_ok = &{1'b0, clk, rst, 1'b0};
endmodule

module ddr3_read_calib #(
    parameter [7:0] TEST_PATTERN = 8'hA5
)(
    input  wire       clk,
    input  wire       rst,
    output wire [7:0] wr_d0,
    output wire       wr_en,
    output wire       read_active,
    output wire [2:0] readclksel,
    input  wire       datavalid,
    input  wire [7:0] rd_q0,
    output wire       calib_done,
    output wire [2:0] calib_readclksel,
    output wire       calib_error
);
    assign wr_d0             = 8'b0;
    assign wr_en             = 1'b0;
    assign read_active       = 1'b0;
    assign readclksel        = 3'b0;
    assign calib_done        = 1'b1;
    assign calib_readclksel  = 3'b0;
    assign calib_error       = 1'b0;
    wire _unused_ok = &{1'b0, clk, rst, datavalid, rd_q0, 1'b0};
endmodule

module ddr3_phy_ecp5 (
    input  wire        clk,
    input  wire        eclk,
    input  wire        rst,
    input  wire        cmd_valid,
    input  wire [2:0]  cmd_cs_ras_cas_we,
    input  wire [2:0]  cmd_ba,
    input  wire [15:0] cmd_addr,
    input  wire        cmd_cke,
    input  wire        cmd_reset_n,
    input  wire        cmd_odt,
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
    output wire        ddr3_odt
);
    assign ddr3_ck      = 1'b0;
    assign ddr3_ck_n    = 1'b1;
    assign ddr3_cs_n    = 1'b1;
    assign ddr3_ras_n   = 1'b1;
    assign ddr3_cas_n   = 1'b1;
    assign ddr3_we_n    = 1'b1;
    assign ddr3_ba      = 3'b0;
    assign ddr3_a       = 16'b0;
    assign ddr3_cke     = 1'b0;
    assign ddr3_reset_n = 1'b0;
    assign ddr3_odt     = 1'b0;
    wire _unused_ok = &{1'b0, clk, eclk, rst, cmd_valid, cmd_cs_ras_cas_we, cmd_ba,
                        cmd_addr, cmd_cke, cmd_reset_n, cmd_odt, 1'b0};
endmodule

module ddr3_dqs_ecp5 (
    input  wire       eclk,
    input  wire       sclk,
    input  wire       rst,
    input  wire       dqs_pad_i,
    input  wire       read_active,
    input  wire [2:0] readclksel,
    output wire       dqsr90,
    output wire       dqsw,
    output wire       dqsw270,
    output wire       datavalid,
    output wire       burstdet,
    output wire       dll_locked
);
    assign dqsr90     = 1'b0;
    assign dqsw       = 1'b0;
    assign dqsw270    = 1'b0;
    assign datavalid  = 1'b0;
    assign burstdet   = 1'b0;
    assign dll_locked = 1'b1;
    wire _unused_ok = &{1'b0, eclk, sclk, rst, dqs_pad_i, read_active, readclksel, 1'b0};
endmodule

module ddr3_dqs_write_ecp5 (
    input  wire sclk,
    input  wire eclk,
    input  wire dqsw,
    input  wire rst,
    input  wire write_start,
    output wire dqs_o,
    output wire dqs_oe,
    output wire burst_active
);
    assign dqs_o        = 1'b0;
    assign dqs_oe       = 1'b0;
    assign burst_active = 1'b0;
    wire _unused_ok = &{1'b0, sclk, eclk, dqsw, rst, write_start, 1'b0};
endmodule

module ddr3_dq_serdes_ecp5 #(
    parameter DQ_WIDTH = 8
)(
    input  wire                  sclk,
    input  wire                  eclk,
    input  wire                  rst,
    input  wire                  dqsr90,
    input  wire                  dqsw270,
    input  wire [DQ_WIDTH-1:0]   wr_d3, wr_d2, wr_d1, wr_d0,
    input  wire                  wr_en,
    output wire [DQ_WIDTH-1:0]   rd_q3, rd_q2, rd_q1, rd_q0,
    output wire [DQ_WIDTH-1:0]   dq_o,
    output wire [DQ_WIDTH-1:0]   dq_oe,
    input  wire [DQ_WIDTH-1:0]   dq_i
);
    assign rd_q3 = {DQ_WIDTH{1'b0}};
    assign rd_q2 = {DQ_WIDTH{1'b0}};
    assign rd_q1 = {DQ_WIDTH{1'b0}};
    assign rd_q0 = {DQ_WIDTH{1'b0}};
    assign dq_o  = {DQ_WIDTH{1'b0}};
    assign dq_oe = {DQ_WIDTH{1'b0}};
    wire _unused_ok = &{1'b0, sclk, eclk, rst, dqsr90, dqsw270, wr_d3, wr_d2, wr_d1,
                        wr_d0, wr_en, dq_i, 1'b0};
endmodule
