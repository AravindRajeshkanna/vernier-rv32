# Xilinx (Vivado) constraints TEMPLATE for fpga/soc_fpga.v.
#
# !! EVERY PACKAGE PIN BELOW IS A PLACEHOLDER !!  These are not real pin
# assignments for any board. Replace each one with the pin from your board's
# master constraints file (Digilent, for example, publishes an XDC per board)
# before running this. Left as-is, implementation will either fail or produce
# a bitstream wired to the wrong pins.
#
# This file has never been run through Vivado - no Xilinx toolchain was
# available where it was written. See fpga/README.md.

# ---------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------
# Adjust the period to your board's oscillator, and keep soc_fpga.v's CLK_HZ
# parameter in step with it - the UART baud divisor is derived from CLK_HZ,
# so a mismatch produces a console that emits garbage even though timing
# closes cleanly.
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk -period 20.00 -waveform {0 10} [get_ports { clk }]

# ---------------------------------------------------------------------
# Reset (active low)
# ---------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports { rst_n }]

# The reset button is asynchronous; soc_fpga.v synchronizes it internally.
# Telling the timing engine that means it stops trying to close a path that
# is intentionally asynchronous.
set_false_path -from [get_ports { rst_n }]

# ---------------------------------------------------------------------
# UART console
# ---------------------------------------------------------------------
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports { uart_tx }]
set_property -dict { PACKAGE_PIN A9  IOSTANDARD LVCMOS33 } [get_ports { uart_rx }]

# ---------------------------------------------------------------------
# SD card (SPI mode)
# ---------------------------------------------------------------------
set_property -dict { PACKAGE_PIN B1  IOSTANDARD LVCMOS33 } [get_ports { spi_sck }]
set_property -dict { PACKAGE_PIN C1  IOSTANDARD LVCMOS33 } [get_ports { spi_mosi }]
set_property -dict { PACKAGE_PIN C2  IOSTANDARD LVCMOS33 } [get_ports { spi_miso }]
set_property -dict { PACKAGE_PIN D2  IOSTANDARD LVCMOS33 } [get_ports { spi_cs_n }]

# MISO comes back from the card with no relationship to our clock at the
# speeds this runs at; constrain it properly if you push SCK high.
set_false_path -from [get_ports { spi_miso }]

# ---------------------------------------------------------------------
# GPIO (16 bidirectional pins)
# ---------------------------------------------------------------------
set_property -dict { PACKAGE_PIN G13 IOSTANDARD LVCMOS33 } [get_ports { gpio[0] }]
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports { gpio[1] }]
set_property -dict { PACKAGE_PIN A11 IOSTANDARD LVCMOS33 } [get_ports { gpio[2] }]
set_property -dict { PACKAGE_PIN D12 IOSTANDARD LVCMOS33 } [get_ports { gpio[3] }]
set_property -dict { PACKAGE_PIN D13 IOSTANDARD LVCMOS33 } [get_ports { gpio[4] }]
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports { gpio[5] }]
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports { gpio[6] }]
set_property -dict { PACKAGE_PIN K16 IOSTANDARD LVCMOS33 } [get_ports { gpio[7] }]
set_property -dict { PACKAGE_PIN E15 IOSTANDARD LVCMOS33 } [get_ports { gpio[8] }]
set_property -dict { PACKAGE_PIN E16 IOSTANDARD LVCMOS33 } [get_ports { gpio[9] }]
set_property -dict { PACKAGE_PIN D15 IOSTANDARD LVCMOS33 } [get_ports { gpio[10] }]
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS33 } [get_ports { gpio[11] }]
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports { gpio[12] }]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports { gpio[13] }]
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { gpio[14] }]
set_property -dict { PACKAGE_PIN J15 IOSTANDARD LVCMOS33 } [get_ports { gpio[15] }]

# ---------------------------------------------------------------------
# Status LEDs
# ---------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

# ---------------------------------------------------------------------
# Bitstream
# ---------------------------------------------------------------------
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
