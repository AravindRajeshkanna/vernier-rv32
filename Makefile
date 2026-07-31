# Simulation Makefile.
#
# macOS setup (one-time):
#   brew install icarus-verilog gtkwave
#   brew install verilator          # optional, for the verilator target
#
# Usage:
#   make sim         -> run the self-checking testbench with Icarus Verilog
#   make wave         -> run sim, then open the waveform in GTKWave
#   make verilator    -> build and run with Verilator instead
#   make clean

IVERILOG  = iverilog
VVP       = vvp
VERILATOR = verilator

RTL = rtl/regfile.v rtl/imem.v rtl/dmem.v rtl/csr_file.v rtl/muldiv_div.v \
      rtl/clint.v rtl/plic.v rtl/btb.v rtl/mmu.v rtl/cpu_core.v rtl/top.v
TB  = sim/tb_top.v

.PHONY: all sim wave verilator clean

all: sim

sim:
	$(IVERILOG) -g2012 -o sim/sim.out $(TB) $(RTL)
	cd sim && $(VVP) sim.out

wave: sim
	gtkwave sim/wave.vcd &

verilator:
	$(VERILATOR) --cc --exe --build --trace -j 4 --top-module top \
		$(RTL) sim/verilator_main.cpp \
		--Mdir obj_dir
	cd sim && ../obj_dir/Vtop

clean:
	rm -rf sim/sim.out sim/wave.vcd sim/wave_verilator.vcd obj_dir
