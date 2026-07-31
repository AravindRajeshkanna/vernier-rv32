# Vivado batch synthesis + implementation for the SoC.
#
# !! NEVER EXECUTED !!  Vivado is not available on macOS and was not present
# in the environment this was written in, so this script has not been run.
# See fpga/README.md.
#
# Usage:
#   make soc                        # produces sim/bootrom.hex (a synthesis input)
#   vivado -mode batch -source fpga/synth/vivado.tcl -tclargs xc7a35ticsg324-1L
#
# Before running, fill in real pins in fpga/constraints/generic.xdc and set
# CLK_HZ in fpga/soc_fpga.v to your board's oscillator.

set part [lindex $argv 0]
if {$part eq ""} { set part "xc7a35ticsg324-1L" }

set root  [file normalize [file join [file dirname [info script]] .. ..]]
set build [file join $root fpga build]
file mkdir $build
cd $build

if {![file exists [file join $root sim bootrom.hex]]} {
    puts "ERROR: sim/bootrom.hex missing - run 'make soc' first"
    exit 1
}
# wb_rom.v $readmemh's this at elaboration time, relative to the working
# directory, so it has to be here - it is a synthesis input, not merely a
# simulation one.
file copy -force [file join $root sim bootrom.hex] [file join $build bootrom.hex]

create_project -in_memory -part $part

foreach f {
    rtl/regfile.v rtl/csr_file.v rtl/muldiv_div.v rtl/clint.v rtl/plic.v
    rtl/uart.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v
    rtl/soc/wb_interconnect.v rtl/soc/cpu_wb.v rtl/soc/wb_ram.v
    rtl/soc/wb_rom.v rtl/soc/wb_periph_bridge.v rtl/soc/wb_gpio.v
    rtl/soc/wb_spi.v rtl/soc/soc_top.v fpga/soc_fpga.v
} {
    read_verilog [file join $root $f]
}

read_xdc [file join $root fpga constraints generic.xdc]

synth_design -top soc_fpga -part $part
opt_design
place_design
phys_opt_design
route_design

report_utilization -file utilization.rpt
report_timing_summary -file timing.rpt

write_bitstream -force soc_fpga.bit

# Fail loudly on a negative slack rather than shipping a bitstream that
# happens to have been built - an unmet timing constraint here means the
# design may work on the bench and then fail on a warm day.
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "=== worst negative slack: $wns ns ==="
if {$wns < 0} {
    puts "ERROR: timing not met. See timing.rpt."
    puts "Usual first suspects in this design: the combinational path through"
    puts "wb_interconnect.v's address decode and response mux, and cpu_core.v's"
    puts "EX stage. See fpga/README.md."
    exit 1
}
puts "bitstream: [file join $build soc_fpga.bit]"
